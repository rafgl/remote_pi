import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Itens por página no `glab repo list` (máximo da API do GitLab).
const kGlabPerPage = 100;

/// Páginas lidas no máximo (10 × 100 = 1000 projetos, mesmo teto do `gh`).
const kGlabMaxPages = 10;

/// GitLab e GitLab self-hosted pelo `glab`. Lista com `glab repo list
/// --member` (projetos do usuário e dos grupos dele) e clona com
/// `glab repo clone`. O host vai em `GITLAB_HOST`, pra servir a mais de uma
/// instância logada.
class GitLabProvider implements GitHostingProvider {
  GitLabProvider(this._locator, this._runner);

  final CliLocator _locator;
  final CliRunner _runner;

  @override
  GitHostingKind get kind => GitHostingKind.gitlab;

  @override
  String get cliName => 'glab';

  Future<String?> _locate() => _locator.locate(
    'glab',
    extraDirs: [
      if (_locator.isWindows)
        for (final base in _locator.windowsProgramDirs())
          _locator.pathContext.join(base, 'glab'),
    ],
  );

  @override
  Future<ProviderStatus> status() async {
    final glab = await _locate();
    if (glab == null) return const ProviderStatus.cliMissing();
    // `glab auth status` escreve no stderr e sai ≠ 0 se QUALQUER host falhar;
    // vale o que foi logado.
    final res = await _runner.run(glab, const ['auth', 'status']);
    final accounts = parseGlabAuthStatus('${res.stdout}\n${res.stderr}');
    return ProviderStatus(
      state: accounts.isEmpty ? ProviderState.signedOut : ProviderState.ready,
      cliPath: glab,
      accounts: accounts,
    );
  }

  @override
  Future<Result<List<RemoteRepo>, GitHostingError>> listRepos(
    HostingAccount account,
  ) async {
    final glab = await _locate();
    if (glab == null) {
      return const Failure(GitHostingError(GitHostingErrorKind.cliMissing));
    }
    final repos = <RemoteRepo>[];
    for (var page = 1; page <= kGlabMaxPages; page++) {
      final res = await _runner.run(
        glab,
        [
          'repo',
          'list',
          '--member',
          '--output',
          'json',
          '--per-page',
          '$kGlabPerPage',
          '--page',
          '$page',
          '--order',
          'last_activity_at',
        ],
        env: {'GITLAB_HOST': account.host},
      );
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
      final parsed = parseGlabRepoList(
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
      if (parsed.length < kGlabPerPage) break;
    }
    return Success(repos);
  }

  @override
  CloneSpec cloneSpec(RemoteRepo repo, String targetPath) => CliCloneSpec(
    CliCommand(
      'glab',
      ['repo', 'clone', repo.fullName, targetPath, '--', '--progress'],
      env: {'GITLAB_HOST': repo.host},
    ),
  );

  @override
  InstallHint installHint() => InstallHint(
    url: 'https://gitlab.com/gitlab-org/cli',
    command: switch (_locator.os) {
      HostOs.macos => const CliCommand('brew', ['install', 'glab']),
      HostOs.windows => const CliCommand('winget', [
        'install',
        '--id',
        'GLab.GLab',
      ]),
      HostOs.linux => null,
    },
  );

  @override
  List<CliCommand> connectCommands() => const [
    CliCommand('glab', ['auth', 'login']),
  ];
}

final _glabLoggedIn = RegExp(
  r'Logged in to (\S+) as (\S+)',
  caseSensitive: false,
);

/// Contas do `glab auth status` ("✓ Logged in to gitlab.com as rafgl
/// (keyring)"). Hosts com falha ("has not been authenticated") ficam de fora.
List<HostingAccount> parseGlabAuthStatus(String raw) {
  final byHost = <String, HostingAccount>{};
  for (final m in _glabLoggedIn.allMatches(raw)) {
    final host = m.group(1)!;
    byHost.putIfAbsent(
      host,
      () => HostingAccount(host: host, login: m.group(2)!),
    );
  }
  return byHost.values.toList();
}

/// Projetos de `glab repo list --output json` (objetos da API do GitLab).
/// `null` quando a saída não é uma lista JSON.
List<RemoteRepo>? parseGlabRepoList(
  String raw, {
  required String host,
  required String login,
}) {
  final json = tryDecodeJson(raw);
  if (json is! List) return null;
  final repos = <RemoteRepo>[];
  for (final r in json) {
    if (r is! Map) continue;
    final path = r['path'] as String?;
    final full = r['path_with_namespace'] as String?;
    final http = r['http_url_to_repo'] as String?;
    if (path == null || full == null || http == null) continue;
    final ns = r['namespace'] is Map ? r['namespace'] as Map : const {};
    final owner =
        (ns['full_path'] as String?) ??
        (full.contains('/') ? full.substring(0, full.lastIndexOf('/')) : full);
    final userNs =
        ns['kind'] == 'user' ||
        (ns['kind'] == null && owner.toLowerCase() == login.toLowerCase());
    final description = (r['description'] as String?)?.trim();
    repos.add(
      RemoteRepo(
        kind: GitHostingKind.gitlab,
        host: host,
        owner: owner,
        ownerKind: userNs ? RepoOwnerKind.user : RepoOwnerKind.organization,
        name: path,
        fullName: full,
        description: description == null || description.isEmpty
            ? null
            : description,
        // `internal` também exige login: conta como privado.
        isPrivate: r['visibility'] != 'public',
        updatedAt: DateTime.tryParse(
          (r['last_activity_at'] ?? r['updated_at']) as String? ?? '',
        ),
        cloneUrl: http,
        sshUrl: r['ssh_url_to_repo'] as String?,
      ),
    );
  }
  return repos;
}
