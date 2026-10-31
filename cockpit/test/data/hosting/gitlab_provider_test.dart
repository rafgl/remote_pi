import 'dart:convert';

import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/data/hosting/gitlab_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _status = '''
gitlab.com
  ✓ Logged in to gitlab.com as rafgl (keyring)
  ✓ Git operations for gitlab.com configured to use https protocol.
gitlab.empresa.com
  x gitlab.empresa.com: api call failed: GET https://gitlab.empresa.com/api/v4/user: 401
  ! No token provided in configuration file. has not been authenticated
''';

Map<String, Object?> _project(
  String path, {
  String ns = 'rafgl',
  String kind = 'user',
  String visibility = 'private',
}) => {
  'name': 'Nome $path',
  'path': path,
  'path_with_namespace': '$ns/$path',
  'description': 'desc $path',
  'visibility': visibility,
  'last_activity_at': '2026-10-31T04:46:39.304Z',
  'http_url_to_repo': 'https://gitlab.com/$ns/$path.git',
  'ssh_url_to_repo': 'git@gitlab.com:$ns/$path.git',
  'namespace': {'kind': kind, 'full_path': ns},
};

void main() {
  test('auth status: só hosts logados', () {
    expect(parseGlabAuthStatus(_status), [
      const HostingAccount(host: 'gitlab.com', login: 'rafgl'),
    ]);
  });

  test('repo list: slug como nome, grupo aninhado, internal = privado', () {
    final json = jsonEncode([
      _project('dotfiles'),
      _project(
        'mfm-frontend',
        ns: 'wdi/mfm',
        kind: 'group',
        visibility: 'internal',
      ),
      _project('site', visibility: 'public'),
    ]);
    final repos = parseGlabRepoList(json, host: 'gitlab.com', login: 'rafgl')!;
    expect(repos.map((r) => r.name), ['dotfiles', 'mfm-frontend', 'site']);
    final mfm = repos[1];
    expect(mfm.owner, 'wdi/mfm');
    expect(mfm.fullName, 'wdi/mfm/mfm-frontend');
    expect(mfm.ownerKind, RepoOwnerKind.organization);
    expect(mfm.isPrivate, isTrue);
    expect(mfm.cloneUrl, 'https://gitlab.com/wdi/mfm/mfm-frontend.git');
    expect(repos[0].ownerKind, RepoOwnerKind.user);
    expect(repos[2].isPrivate, isFalse);
    expect(repos[0].updatedAt, DateTime.utc(2026, 10, 31, 4, 46, 39, 304));
  });

  test('repo list não-JSON devolve null', () {
    expect(parseGlabRepoList('oops', host: 'gitlab.com', login: 'x'), isNull);
  });

  group('status', () {
    test('sem glab', () async {
      final p = GitLabProvider(locatorWith({}), FakeCliRunner({}));
      expect((await p.status()).state, ProviderState.cliMissing);
    });

    test('glab sem login (stderr, exit 1)', () async {
      final p = GitLabProvider(
        locatorWith({'/opt/homebrew/bin/glab'}),
        FakeCliRunner({'auth status': err('No GitLab instances configured')}),
      );
      expect((await p.status()).state, ProviderState.signedOut);
    });

    test('glab logado mesmo com outro host falhando', () async {
      final p = GitLabProvider(
        locatorWith({'/usr/local/bin/glab'}),
        FakeCliRunner({'auth status': err(_status)}),
      );
      final st = await p.status();
      expect(st.state, ProviderState.ready);
      expect(st.accounts.single.host, 'gitlab.com');
    });

    test('Windows: Program Files\\glab', () async {
      final p = GitLabProvider(
        locatorWith(
          {r'C:\Program Files (x86)\glab\glab.exe'},
          os: HostOs.windows,
          env: windowsEnv,
        ),
        FakeCliRunner({'auth status': err(_status)}),
      );
      expect(
        (await p.status()).cliPath,
        r'C:\Program Files (x86)\glab\glab.exe',
      );
    });
  });

  test('listRepos pagina até a página incompleta, com GITLAB_HOST', () async {
    var page = 0;
    final runner = _PagingRunner((args) {
      page++;
      final count = page == 1 ? kGlabPerPage : 3;
      return jsonEncode([
        for (var i = 0; i < count; i++) _project('p$page-$i'),
      ]);
    });
    final p = GitLabProvider(locatorWith({'/opt/homebrew/bin/glab'}), runner);
    final res = await p.listRepos(
      const HostingAccount(host: 'gitlab.empresa.com', login: 'rafgl'),
    );
    expect((res as Success).value, hasLength(kGlabPerPage + 3));
    expect(runner.calls, 2);
    expect(runner.lastEnv['GITLAB_HOST'], 'gitlab.empresa.com');
    expect(runner.lastArgs, containsAllInOrder(['--page', '2']));
    expect(runner.lastArgs, contains('--member'));
  });

  test('listRepos: 401 vira signedOut', () async {
    final p = GitLabProvider(
      locatorWith({'/opt/homebrew/bin/glab'}),
      FakeCliRunner({'repo list': err('401 Unauthorized')}),
    );
    final res = await p.listRepos(
      const HostingAccount(host: 'gitlab.com', login: 'rafgl'),
    );
    expect(
      (res as Failure<List<RemoteRepo>, GitHostingError>).error.kind,
      GitHostingErrorKind.signedOut,
    );
  });

  test('clone, instalar e conectar', () {
    final mac = GitLabProvider(locatorWith({}), FakeCliRunner({}));
    final spec =
        mac.cloneSpec(
              const RemoteRepo(
                kind: GitHostingKind.gitlab,
                host: 'gitlab.empresa.com',
                owner: 'wdi/mfm',
                ownerKind: RepoOwnerKind.organization,
                name: 'front',
                fullName: 'wdi/mfm/front',
                cloneUrl: 'https://gitlab.empresa.com/wdi/mfm/front.git',
              ),
              '/p/front',
            )
            as CliCloneSpec;
    expect(
      spec.command.display,
      'glab repo clone wdi/mfm/front /p/front -- --progress',
    );
    expect(spec.command.env['GITLAB_HOST'], 'gitlab.empresa.com');
    expect(mac.installHint().command!.display, 'brew install glab');
    final win = GitLabProvider(
      locatorWith({}, os: HostOs.windows),
      FakeCliRunner({}),
    );
    expect(win.installHint().command!.display, 'winget install --id GLab.GLab');
    expect(mac.connectCommands().single.display, 'glab auth login');
  });
}

/// Runner que responde por função (paginação) e guarda a última chamada.
class _PagingRunner implements CliRunner {
  _PagingRunner(this.page);

  final String Function(List<String> args) page;
  int calls = 0;
  List<String> lastArgs = const [];
  Map<String, String> lastEnv = const {};

  @override
  Future<CliResult> run(
    String executable,
    List<String> args, {
    Map<String, String> env = const {},
  }) async {
    calls++;
    lastArgs = args;
    lastEnv = env;
    return ok(page(args));
  }
}
