import 'dart:convert';

import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/data/hosting/gitea_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _logins =
    '[{"Name":"codeberg","URL":"https://codeberg.org","SSHHost":"codeberg.org",'
    '"User":"rafgl","Default":"true"},'
    '{"name":"work","url":"https://git.acme.com:3000/forgejo","user":"rafa"}]';

const _repos =
    '[{"owner":"rafgl","name":"dotfiles","description":"","url":"https://codeberg.org/rafgl/dotfiles",'
    '"ssh":"git@codeberg.org:rafgl/dotfiles.git","updated":"2026-10-30T12:00:00Z","type":"source"},'
    '{"owner":"acme","name":"api","description":"API","url":"https://codeberg.org/acme/api.git",'
    '"ssh":"git@codeberg.org:acme/api.git","updated":"","type":"mirror","private":"true"}]';

void main() {
  test('logins: chaves em qualquer caso, host com porta e caminho', () {
    expect(parseTeaLogins(_logins), [
      const HostingAccount(
        host: 'codeberg.org',
        login: 'rafgl',
        handle: 'codeberg',
      ),
      const HostingAccount(
        host: 'git.acme.com:3000/forgejo',
        login: 'rafa',
        handle: 'work',
      ),
    ]);
    expect(parseTeaLogins('[]'), isEmpty);
    expect(parseTeaLogins('No logins'), isNull);
  });

  test('repos: URL de clone com .git, dono, privado opcional', () {
    final repos = parseTeaRepos(_repos, host: 'codeberg.org', login: 'rafgl')!;
    expect(repos.map((r) => r.fullName), ['rafgl/dotfiles', 'acme/api']);
    expect(repos[0].cloneUrl, 'https://codeberg.org/rafgl/dotfiles.git');
    expect(repos[0].ownerKind, RepoOwnerKind.user);
    expect(repos[0].description, isNull);
    expect(repos[0].isPrivate, isFalse);
    expect(repos[0].updatedAt, DateTime.utc(2026, 10, 30, 12));
    expect(repos[1].cloneUrl, 'https://codeberg.org/acme/api.git');
    expect(repos[1].ownerKind, RepoOwnerKind.organization);
    expect(repos[1].isPrivate, isTrue);
    expect(repos[1].updatedAt, isNull);
  });

  group('status', () {
    test('sem tea', () async {
      final p = GiteaProvider(locatorWith({}), FakeCliRunner({}));
      expect((await p.status()).state, ProviderState.cliMissing);
    });

    test('tea sem login', () async {
      final p = GiteaProvider(
        locatorWith({'/opt/homebrew/bin/tea'}),
        FakeCliRunner({'logins list': ok('[]')}),
      );
      expect((await p.status()).state, ProviderState.signedOut);
    });

    test('tea com logins', () async {
      final p = GiteaProvider(
        locatorWith({'/usr/local/bin/tea'}),
        FakeCliRunner({'logins list': ok(_logins)}),
      );
      final st = await p.status();
      expect(st.state, ProviderState.ready);
      expect(st.accounts, hasLength(2));
    });

    test('Windows: link do winget', () async {
      const path =
          r'C:\Users\rafgl\AppData\Local\Microsoft\WinGet\Links\tea.exe';
      final p = GiteaProvider(
        locatorWith({path}, os: HostOs.windows, env: windowsEnv),
        FakeCliRunner({'logins list': ok(_logins)}),
      );
      expect((await p.status()).cliPath, path);
    });
  });

  test('listRepos usa --login com o nome do login e pagina', () async {
    final runner = FakeCliRunner({'repos list': ok(_repos)});
    final p = GiteaProvider(locatorWith({'/opt/homebrew/bin/tea'}), runner);
    final res = await p.listRepos(
      const HostingAccount(
        host: 'codeberg.org',
        login: 'rafgl',
        handle: 'codeberg',
      ),
    );
    expect((res as Success).value, hasLength(2));
    final args = runner.calls.single.args;
    expect(args, containsAllInOrder(['--login', 'codeberg']));
    expect(args, containsAllInOrder(['--fields', kTeaRepoFields]));
    expect(args, containsAllInOrder(['--page', '1']));
  });

  test('listRepos para na página cheia + incompleta', () async {
    final full = jsonEncode([
      for (var i = 0; i < kTeaPerPage; i++)
        {'owner': 'rafgl', 'name': 'r$i', 'url': 'https://c.org/rafgl/r$i'},
    ]);
    var call = 0;
    final runner = _SeqRunner(() => ok(call++ == 0 ? full : '[]'));
    final p = GiteaProvider(locatorWith({'/opt/homebrew/bin/tea'}), runner);
    final res = await p.listRepos(
      const HostingAccount(host: 'c.org', login: 'rafgl', handle: 'c'),
    );
    expect((res as Success).value, hasLength(kTeaPerPage));
    expect(call, 2);
  });

  test('clone por git, instalar e conectar', () {
    final mac = GiteaProvider(locatorWith({}), FakeCliRunner({}));
    final repo = parseTeaRepos(
      _repos,
      host: 'codeberg.org',
      login: 'rafgl',
    )!.first;
    expect(
      (mac.cloneSpec(repo, '/p/dotfiles') as GitUrlCloneSpec).url,
      'https://codeberg.org/rafgl/dotfiles.git',
    );
    expect(mac.installHint().command!.display, 'brew install tea');
    expect(
      GiteaProvider(
        locatorWith({}, os: HostOs.windows),
        FakeCliRunner({}),
      ).installHint().command!.display,
      'winget install --id Gitea.tea',
    );
    expect(mac.connectCommands().single.display, 'tea login add');
  });
}

class _SeqRunner implements CliRunner {
  _SeqRunner(this.next);

  final CliResult Function() next;

  @override
  Future<CliResult> run(
    String executable,
    List<String> args, {
    Map<String, String> env = const {},
  }) async => next();
}
