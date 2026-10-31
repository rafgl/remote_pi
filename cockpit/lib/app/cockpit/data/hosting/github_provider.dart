import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Campos pedidos ao `gh repo list --json`.
const kGhRepoFields =
    'name,nameWithOwner,owner,description,isPrivate,updatedAt,url,sshUrl';

/// GitHub e GitHub Enterprise pelo `gh`. Lista com `gh repo list` (o usuário
/// e cada organização de `gh api user/orgs`) e clona com `gh repo clone`, que
/// usa o mesmo login: se a lista apareceu, o clone de repo privado funciona.
class GitHubProvider implements GitHostingProvider {
  GitHubProvider(this._locator, this._runner);

  final CliLocator _locator;
  final CliRunner _runner;

  @override
  GitHostingKind get kind => GitHostingKind.github;

  @override
  String get cliName => 'gh';

  /// Windows: o MSI do winget instala em `Program Files\GitHub CLI`; o
  /// instalador por usuário, em `%LOCALAPPDATA%\Programs\GitHub CLI`.
  Future<String?> _locate() => _locator.locate(
    'gh',
    extraDirs: [
      if (_locator.isWindows)
        for (final base in _locator.windowsProgramDirs())
          _locator.pathContext.join(base, 'GitHub CLI'),
    ],
  );

  @override
  Future<ProviderStatus> status() async {
    final gh = await _locate();
    if (gh == null) return const ProviderStatus.cliMissing();
    var res = await _runner.run(gh, const [
      'auth',
      'status',
      '--json',
      'hosts',
    ]);
    var accounts = parseGhAuthStatusJson(res.stdout);
    // gh < 2.71 não tem `--json` no auth status: cai no texto.
    if (accounts == null) {
      res = await _runner.run(gh, const ['auth', 'status']);
      accounts = parseGhAuthStatusText('${res.stdout}\n${res.stderr}');
    }
    return ProviderStatus(
      state: accounts.isEmpty ? ProviderState.signedOut : ProviderState.ready,
      cliPath: gh,
      accounts: accounts,
    );
  }

  @override
  Future<Result<List<RemoteRepo>, GitHostingError>> listRepos(
    HostingAccount account,
  ) async {
    final gh = await _locate();
    if (gh == null) {
      return const Failure(GitHostingError(GitHostingErrorKind.cliMissing));
    }
    final env = {'GH_HOST': account.host};
    Future<CliResult> list([String? owner]) => _runner.run(gh, [
      'repo',
      'list',
      ?owner,
      '--limit',
      '1000',
      '--json',
      kGhRepoFields,
    ], env: env);

    final orgsCall = _runner.run(gh, const [
      'api',
      'user/orgs',
      '--paginate',
      '--jq',
      '.[].login',
    ], env: env);
    final mine = await list();
    if (!mine.ok) return Failure(_error(mine));
    final orgsRes = await orgsCall;
    // Sem `read:org` o gh devolve erro aqui: segue só com os repos do usuário.
    final orgs = orgsRes.ok ? parseLines(orgsRes.stdout) : const <String>[];
    final results = [mine, ...await Future.wait(orgs.map(list))];

    final repos = <RemoteRepo>[];
    final seen = <String>{};
    for (final res in results) {
      if (!res.ok) continue; // uma org com SSO pendente não derruba a lista
      final parsed = parseGhRepoList(
        res.stdout,
        host: account.host,
        login: account.login,
      );
      if (parsed == null) {
        return Failure(
          GitHostingError(GitHostingErrorKind.badOutput, detail: res.stdout),
        );
      }
      for (final r in parsed) {
        if (seen.add(r.fullName)) repos.add(r);
      }
    }
    return Success(repos);
  }

  GitHostingError _error(CliResult res) => GitHostingError(
    looksSignedOut(res.message)
        ? GitHostingErrorKind.signedOut
        : GitHostingErrorKind.commandFailed,
    detail: res.message,
  );

  @override
  CloneSpec cloneSpec(RemoteRepo repo, String targetPath) => CliCloneSpec(
    CliCommand(
      'gh',
      [
        'repo',
        'clone',
        // Fora do github.com o gh precisa do host no nome (HOST/OWNER/REPO).
        if (repo.host == 'github.com')
          repo.fullName
        else
          '${repo.host}/${repo.fullName}',
        targetPath,
        '--',
        '--progress',
      ],
      env: {'GH_HOST': repo.host},
    ),
  );

  @override
  InstallHint installHint() => InstallHint(
    url: 'https://cli.github.com',
    command: switch (_locator.os) {
      HostOs.macos => const CliCommand('brew', ['install', 'gh']),
      HostOs.windows => const CliCommand('winget', [
        'install',
        '--id',
        'GitHub.cli',
      ]),
      HostOs.linux => null,
    },
  );

  @override
  List<CliCommand> connectCommands() => const [
    CliCommand('gh', ['auth', 'login', '--web']),
  ];
}

/// Contas de `gh auth status --json hosts`. `null` quando a saída não é esse
/// JSON (gh antigo). Por host, fica a conta ativa (é a que o `gh repo list`
/// usa); sem conta ativa marcada, a primeira com `state: success`.
List<HostingAccount>? parseGhAuthStatusJson(String raw) {
  final json = tryDecodeJson(raw);
  if (json is! Map || json['hosts'] is! Map) return null;
  final accounts = <HostingAccount>[];
  for (final entry in (json['hosts'] as Map).entries) {
    final list = entry.value;
    if (list is! List) continue;
    final ok = [
      for (final a in list)
        if (a is Map && a['state'] == 'success' && a['login'] is String) a,
    ];
    if (ok.isEmpty) continue;
    final active = ok.firstWhere(
      (a) => a['active'] == true,
      orElse: () => ok.first,
    );
    accounts.add(
      HostingAccount(
        host: (active['host'] as String?) ?? entry.key.toString(),
        login: active['login'] as String,
      ),
    );
  }
  return accounts;
}

final _ghLoggedIn = RegExp(
  r'Logged in to (\S+) (?:account|as) (\S+)',
  caseSensitive: false,
);

/// Contas do `gh auth status` em texto (formato novo "account rafgl" e antigo
/// "as rafgl"). Uma por host: a primeira listada é a ativa.
List<HostingAccount> parseGhAuthStatusText(String raw) {
  final byHost = <String, HostingAccount>{};
  for (final m in _ghLoggedIn.allMatches(raw)) {
    final host = m.group(1)!;
    byHost.putIfAbsent(
      host,
      () => HostingAccount(host: host, login: m.group(2)!),
    );
  }
  return byHost.values.toList();
}

/// Linhas não vazias (saída de `--jq '.[].login'`).
List<String> parseLines(String raw) => [
  for (final l in raw.split(RegExp(r'\r?\n')))
    if (l.trim().isNotEmpty) l.trim(),
];

/// Repositórios de `gh repo list --json <kGhRepoFields>`. `null` quando a
/// saída não é uma lista JSON.
List<RemoteRepo>? parseGhRepoList(
  String raw, {
  required String host,
  required String login,
}) {
  final json = tryDecodeJson(raw);
  if (json is! List) return null;
  return [
    for (final r in json)
      if (r is Map && r['name'] is String) _ghRepo(r, host: host, login: login),
  ];
}

RemoteRepo _ghRepo(Map r, {required String host, required String login}) {
  final name = r['name'] as String;
  final owner = switch (r['owner']) {
    {'login': final String l} => l,
    _ => (r['nameWithOwner'] as String? ?? '').split('/').first,
  };
  final description = (r['description'] as String?)?.trim();
  return RemoteRepo(
    kind: GitHostingKind.github,
    host: host,
    owner: owner,
    ownerKind: owner.toLowerCase() == login.toLowerCase()
        ? RepoOwnerKind.user
        : RepoOwnerKind.organization,
    name: name,
    fullName: r['nameWithOwner'] as String? ?? '$owner/$name',
    description: description == null || description.isEmpty
        ? null
        : description,
    isPrivate: r['isPrivate'] == true,
    updatedAt: DateTime.tryParse(r['updatedAt'] as String? ?? ''),
    cloneUrl: (r['url'] as String?) ?? 'https://$host/$owner/$name',
    sshUrl: r['sshUrl'] as String?,
  );
}
