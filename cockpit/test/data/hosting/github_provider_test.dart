import 'package:cockpit/app/cockpit/data/hosting/github_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _authJson =
    '{"hosts":{"github.com":[{"state":"success","active":true,'
    '"host":"github.com","login":"rafgl","tokenSource":"keyring"},'
    '{"state":"success","active":false,"host":"github.com","login":"other"}],'
    '"ghe.acme.com":[{"state":"error","active":true,"host":"ghe.acme.com",'
    '"login":"broken"}]}}';

const _mineJson =
    '[{"description":"Fork do Remote Pi","isPrivate":false,"name":"remote_pi",'
    '"nameWithOwner":"rafgl/remote_pi","owner":{"id":"x","login":"rafgl"},'
    '"sshUrl":"git@github.com:rafgl/remote_pi.git",'
    '"updatedAt":"2026-10-30T23:43:38Z","url":"https://github.com/rafgl/remote_pi"},'
    '{"description":"","isPrivate":true,"name":"dotfiles",'
    '"nameWithOwner":"rafgl/dotfiles","owner":{"id":"x","login":"rafgl"},'
    '"sshUrl":"git@github.com:rafgl/dotfiles.git",'
    '"updatedAt":"2026-10-21T13:51:21Z","url":"https://github.com/rafgl/dotfiles"}]';

const _orgJson =
    '[{"description":"Cobrança","isPrivate":true,"name":"billing-api",'
    '"nameWithOwner":"acme-labs/billing-api","owner":{"id":"y","login":"acme-labs"},'
    '"sshUrl":"git@github.com:acme-labs/billing-api.git",'
    '"updatedAt":"2026-10-31T10:00:00Z","url":"https://github.com/acme-labs/billing-api"}]';

void main() {
  group('parsers', () {
    test('auth status --json: conta ativa por host, ignora erro', () {
      final accounts = parseGhAuthStatusJson(_authJson)!;
      expect(accounts, [
        const HostingAccount(host: 'github.com', login: 'rafgl'),
      ]);
    });

    test('auth status --json inválido devolve null (gh antigo)', () {
      expect(parseGhAuthStatusJson('unknown flag: --json'), isNull);
    });

    test('auth status em texto: formatos novo e antigo', () {
      const text = '''
github.com
  ✓ Logged in to github.com account rafgl (keyring)
  - Active account: true
ghe.acme.com
  ✓ Logged in to ghe.acme.com as rafael (oauth_token)
''';
      expect(parseGhAuthStatusText(text), [
        const HostingAccount(host: 'github.com', login: 'rafgl'),
        const HostingAccount(host: 'ghe.acme.com', login: 'rafael'),
      ]);
      expect(
        parseGhAuthStatusText('You are not logged into any GitHub hosts'),
        isEmpty,
      );
    });

    test('repo list: campos, dono usuário x organização, descrição vazia', () {
      final repos = parseGhRepoList(
        _mineJson.replaceFirst(RegExp(r'\]$'), ',${_orgJson.substring(1)}'),
        host: 'github.com',
        login: 'rafgl',
      )!;
      expect(repos.map((r) => r.fullName), [
        'rafgl/remote_pi',
        'rafgl/dotfiles',
        'acme-labs/billing-api',
      ]);
      final pi = repos.first;
      expect(pi.ownerKind, RepoOwnerKind.user);
      expect(pi.description, 'Fork do Remote Pi');
      expect(pi.isPrivate, isFalse);
      expect(pi.updatedAt, DateTime.utc(2026, 10, 30, 23, 43, 38));
      expect(pi.cloneUrl, 'https://github.com/rafgl/remote_pi');
      expect(repos[1].description, isNull);
      expect(repos[1].isPrivate, isTrue);
      expect(repos[2].ownerKind, RepoOwnerKind.organization);
      expect(repos[2].owner, 'acme-labs');
    });

    test('repo list não-JSON devolve null', () {
      expect(parseGhRepoList('error', host: 'github.com', login: 'x'), isNull);
    });
  });

  group('status', () {
    test('sem gh', () async {
      final p = GitHubProvider(locatorWith({}), FakeCliRunner({}));
      expect((await p.status()).state, ProviderState.cliMissing);
    });

    test('gh sem login', () async {
      final p = GitHubProvider(
        locatorWith({'/opt/homebrew/bin/gh'}),
        FakeCliRunner({
          'auth status --json hosts': err('not logged', stdout: '{"hosts":{}}'),
        }),
      );
      final st = await p.status();
      expect(st.state, ProviderState.signedOut);
      expect(st.cliPath, '/opt/homebrew/bin/gh');
    });

    test('gh logado', () async {
      final p = GitHubProvider(
        locatorWith({'/usr/local/bin/gh'}),
        FakeCliRunner({'auth status --json hosts': ok(_authJson)}),
      );
      final st = await p.status();
      expect(st.state, ProviderState.ready);
      expect(st.accounts.single.login, 'rafgl');
    });

    test('gh antigo sem --json cai no texto', () async {
      final runner = FakeCliRunner({
        'auth status --json hosts': err('unknown flag: --json'),
        'auth status': err(
          '  ✓ Logged in to github.com as rafgl (oauth_token)',
        ),
      });
      final p = GitHubProvider(locatorWith({'/opt/homebrew/bin/gh'}), runner);
      final st = await p.status();
      expect(st.state, ProviderState.ready);
      expect(runner.calls.length, 2);
    });

    test('Windows: acha em Program Files\\GitHub CLI', () async {
      final p = GitHubProvider(
        locatorWith(
          {r'C:\Program Files\GitHub CLI\gh.exe'},
          os: HostOs.windows,
          env: windowsEnv,
        ),
        FakeCliRunner({'auth status --json hosts': ok(_authJson)}),
      );
      expect((await p.status()).cliPath, r'C:\Program Files\GitHub CLI\gh.exe');
    });
  });

  group('listRepos', () {
    const account = HostingAccount(host: 'github.com', login: 'rafgl');

    test('junta usuário e organizações, com GH_HOST', () async {
      final runner = FakeCliRunner({
        'repo list --limit': ok(_mineJson),
        'api user/orgs': ok('acme-labs\n'),
        'repo list acme-labs': ok(_orgJson),
      });
      final p = GitHubProvider(locatorWith({'/opt/homebrew/bin/gh'}), runner);
      final res = await p.listRepos(account);
      final repos = (res as Success<List<RemoteRepo>, GitHostingError>).value;
      expect(repos.length, 3);
      expect(
        runner.calls.every((c) => c.env['GH_HOST'] == 'github.com'),
        isTrue,
      );
    });

    test('sem read:org segue só com os repos do usuário', () async {
      final p = GitHubProvider(
        locatorWith({'/opt/homebrew/bin/gh'}),
        FakeCliRunner({
          'repo list --limit': ok(_mineJson),
          'api user/orgs': err('HTTP 403'),
        }),
      );
      final res = await p.listRepos(account);
      expect((res as Success).value, hasLength(2));
    });

    test('login expirado vira signedOut', () async {
      final p = GitHubProvider(
        locatorWith({'/opt/homebrew/bin/gh'}),
        FakeCliRunner({
          'repo list --limit': err(
            'To get started with GitHub CLI, please run:  gh auth login',
          ),
          'api user/orgs': err('x'),
        }),
      );
      final res = await p.listRepos(account);
      expect(
        (res as Failure<List<RemoteRepo>, GitHostingError>).error.kind,
        GitHostingErrorKind.signedOut,
      );
    });

    test('erro genérico vira commandFailed com detail', () async {
      final p = GitHubProvider(
        locatorWith({'/opt/homebrew/bin/gh'}),
        FakeCliRunner({
          'repo list --limit': err(
            'dial tcp: lookup api.github.com: no such host',
          ),
          'api user/orgs': err('x'),
        }),
      );
      final e =
          ((await p.listRepos(account)) as Failure).error as GitHostingError;
      expect(e.kind, GitHostingErrorKind.commandFailed);
      expect(e.detail, contains('no such host'));
    });
  });

  group('comandos', () {
    final p = GitHubProvider(locatorWith({}), FakeCliRunner({}));
    RemoteRepo repo(String host) => RemoteRepo(
      kind: GitHostingKind.github,
      host: host,
      owner: 'acme',
      ownerKind: RepoOwnerKind.organization,
      name: 'api',
      fullName: 'acme/api',
      cloneUrl: 'https://$host/acme/api',
    );

    test('clone github.com: gh repo clone owner/repo pasta -- --progress', () {
      final spec = p.cloneSpec(repo('github.com'), '/p/api') as CliCloneSpec;
      expect(
        spec.command.display,
        'gh repo clone acme/api /p/api -- --progress',
      );
      expect(spec.command.env['GH_HOST'], 'github.com');
    });

    test('clone GitHub Enterprise leva o host', () {
      final spec = p.cloneSpec(repo('ghe.acme.com'), '/p/api') as CliCloneSpec;
      expect(spec.command.args[2], 'ghe.acme.com/acme/api');
    });

    test('instalar por plataforma', () {
      expect(
        GitHubProvider(
          locatorWith({}),
          FakeCliRunner({}),
        ).installHint().command!.display,
        'brew install gh',
      );
      expect(
        GitHubProvider(
          locatorWith({}, os: HostOs.windows),
          FakeCliRunner({}),
        ).installHint().command!.display,
        'winget install --id GitHub.cli',
      );
      final linux = GitHubProvider(
        locatorWith({}, os: HostOs.linux),
        FakeCliRunner({}),
      ).installHint();
      expect(linux.command, isNull);
      expect(linux.url, 'https://cli.github.com');
    });

    test('conectar: gh auth login --web', () {
      expect(p.connectCommands().single.display, 'gh auth login --web');
    });
  });
}
