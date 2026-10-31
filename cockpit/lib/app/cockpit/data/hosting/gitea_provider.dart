import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Itens por página no `tea repos ls` (o Gitea limita a 50 por padrão).
const kTeaPerPage = 50;

/// Páginas lidas no máximo (20 × 50 = 1000 repositórios).
const kTeaMaxPages = 20;

/// Campos pedidos ao `tea repos ls --fields`.
const kTeaRepoFields = 'owner,name,description,url,ssh,updated,type';

/// Gitea e Forgejo pelo `tea` (o Forgejo é compatível com a API do Gitea).
/// Cada login do `tea logins` vira uma conta; lista com `tea repos ls` e
/// clona com `git clone` (o `tea` não clona).
class GiteaProvider implements GitHostingProvider {
  GiteaProvider(this._locator, this._runner);

  final CliLocator _locator;
  final CliRunner _runner;

  @override
  GitHostingKind get kind => GitHostingKind.gitea;

  @override
  String get cliName => 'tea';

  Future<String?> _locate() => _locator.locate(
    'tea',
    extraDirs: [
      if (_locator.isWindows)
        for (final base in _locator.windowsProgramDirs())
          _locator.pathContext.join(base, 'tea'),
    ],
  );

  @override
  Future<ProviderStatus> status() async {
    final tea = await _locate();
    if (tea == null) return const ProviderStatus.cliMissing();
    final res = await _runner.run(tea, const [
      'logins',
      'list',
      '--output',
      'json',
    ]);
    final accounts = res.ok
        ? parseTeaLogins(res.stdout) ?? const <HostingAccount>[]
        : const <HostingAccount>[];
    return ProviderStatus(
      state: accounts.isEmpty ? ProviderState.signedOut : ProviderState.ready,
      cliPath: tea,
      accounts: accounts,
    );
  }

  @override
  Future<Result<List<RemoteRepo>, GitHostingError>> listRepos(
    HostingAccount account,
  ) async {
    final tea = await _locate();
    if (tea == null) {
      return const Failure(GitHostingError(GitHostingErrorKind.cliMissing));
    }
    final repos = <RemoteRepo>[];
    for (var page = 1; page <= kTeaMaxPages; page++) {
      final res = await _runner.run(tea, [
        'repos',
        'list',
        '--login',
        account.handle ?? account.host,
        '--output',
        'json',
        '--fields',
        kTeaRepoFields,
        '--limit',
        '$kTeaPerPage',
        '--page',
        '$page',
      ]);
      if (!res.ok) {
        return Failure(
          GitHostingError(
            looksSignedOut(res.message)
                ? GitHostingErrorKind.signedOut
                : GitHostingErrorKind.commandFailed,
            detail: res.message,
          ),
        );
      }
      final parsed = parseTeaRepos(
        res.stdout,
        host: account.host,
        login: account.login,
      );
      if (parsed == null) {
        return Failure(
          GitHostingError(GitHostingErrorKind.badOutput, detail: res.stdout),
        );
      }
      repos.addAll(parsed);
      if (parsed.length < kTeaPerPage) break;
    }
    return Success(repos);
  }

  @override
  CloneSpec cloneSpec(RemoteRepo repo, String targetPath) =>
      GitUrlCloneSpec(repo.cloneUrl);

  @override
  InstallHint installHint() => InstallHint(
    url: 'https://gitea.com/gitea/tea',
    command: switch (_locator.os) {
      HostOs.macos => const CliCommand('brew', ['install', 'tea']),
      HostOs.windows => const CliCommand('winget', [
        'install',
        '--id',
        'Gitea.tea',
      ]),
      HostOs.linux => null,
    },
  );

  @override
  List<CliCommand> connectCommands() => const [
    CliCommand('tea', ['login', 'add']),
  ];
}

/// Valor de [key] num objeto da saída do `tea`, ignorando maiúsculas: o JSON
/// do `tea` usa o cabeçalho da tabela como chave, e o caso mudou entre versões.
Object? _field(Map m, String key) {
  if (m.containsKey(key)) return m[key];
  final lower = key.toLowerCase();
  for (final e in m.entries) {
    if (e.key.toString().toLowerCase() == lower) return e.value;
  }
  return null;
}

String? _string(Map m, String key) {
  final v = _field(m, key);
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

/// Logins de `tea logins list --output json`. O host exibido é o da URL do
/// servidor; o nome do login vai em [HostingAccount.handle] (`--login`).
List<HostingAccount>? parseTeaLogins(String raw) {
  final json = tryDecodeJson(raw);
  if (json is! List) return null;
  final accounts = <HostingAccount>[];
  for (final l in json) {
    if (l is! Map) continue;
    final name = _string(l, 'name');
    final url = _string(l, 'url');
    final user = _string(l, 'user');
    if (name == null || url == null) continue;
    final uri = Uri.tryParse(url);
    final host = uri == null || uri.host.isEmpty
        ? url
        : '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}${uri.path == '/' ? '' : uri.path}';
    accounts.add(HostingAccount(host: host, login: user ?? name, handle: name));
  }
  return accounts;
}

/// Repositórios de `tea repos ls --output json --fields <kTeaRepoFields>`.
/// O `tea` devolve tudo como texto; a URL do clone HTTPS é a página + `.git`.
List<RemoteRepo>? parseTeaRepos(
  String raw, {
  required String host,
  required String login,
}) {
  final json = tryDecodeJson(raw);
  if (json is! List) return null;
  final repos = <RemoteRepo>[];
  for (final r in json) {
    if (r is! Map) continue;
    final name = _string(r, 'name');
    final owner = _string(r, 'owner');
    final url = _string(r, 'url');
    if (name == null || owner == null || url == null) continue;
    final private = _field(r, 'private');
    repos.add(
      RemoteRepo(
        kind: GitHostingKind.gitea,
        host: host,
        owner: owner,
        ownerKind: owner.toLowerCase() == login.toLowerCase()
            ? RepoOwnerKind.user
            : RepoOwnerKind.organization,
        name: name,
        fullName: '$owner/$name',
        description: _string(r, 'description'),
        isPrivate: private == true || private == 'true',
        updatedAt: DateTime.tryParse(_string(r, 'updated') ?? ''),
        cloneUrl: url.endsWith('.git') ? url : '$url.git',
        sshUrl: _string(r, 'ssh'),
      ),
    );
  }
  return repos;
}
