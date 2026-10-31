import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('CliLocator', () {
    test('macOS Apple Silicon: acha no Homebrew fora do PATH do app', () async {
      final locator = locatorWith({'/opt/homebrew/bin/gh'});
      expect(await locator.locate('gh'), '/opt/homebrew/bin/gh');
    });

    test('macOS Intel: acha no /usr/local/bin', () async {
      final locator = locatorWith({'/usr/local/bin/glab'});
      expect(await locator.locate('glab'), '/usr/local/bin/glab');
    });

    test('PATH vem antes das pastas conhecidas', () async {
      final locator = locatorWith(
        {'/custom/bin/gh', '/opt/homebrew/bin/gh'},
        env: const {'PATH': '/custom/bin:/usr/bin'},
      );
      expect(await locator.locate('gh'), '/custom/bin/gh');
    });

    test('~/go/bin (tea por go install)', () async {
      final locator = locatorWith(
        {'/Users/me/go/bin/tea'},
        env: const {'PATH': '/usr/bin', 'HOME': '/Users/me'},
      );
      expect(await locator.locate('tea'), '/Users/me/go/bin/tea');
    });

    test('ausente devolve null', () async {
      expect(await locatorWith({}).locate('gh'), isNull);
    });

    test('Windows: separador ; e extensão .exe no PATH', () async {
      final locator = locatorWith(
        {r'C:\tools\gh.exe'},
        os: HostOs.windows,
        env: const {'Path': r'C:\Windows;C:\tools'},
      );
      expect(await locator.locate('gh'), r'C:\tools\gh.exe');
    });

    test('Windows: .cmd quando não há .exe (az)', () async {
      final locator = locatorWith(
        {r'C:\az\wbin\az.cmd'},
        os: HostOs.windows,
        env: const {'PATH': r'C:\az\wbin'},
      );
      expect(await locator.locate('az'), r'C:\az\wbin\az.cmd');
    });

    test('Windows: links do winget e shims do scoop', () async {
      final winget = locatorWith(
        {r'C:\Users\rafgl\AppData\Local\Microsoft\WinGet\Links\tea.exe'},
        os: HostOs.windows,
        env: windowsEnv,
      );
      expect(
        await winget.locate('tea'),
        r'C:\Users\rafgl\AppData\Local\Microsoft\WinGet\Links\tea.exe',
      );
      final scoop = locatorWith(
        {r'C:\Users\rafgl\scoop\shims\gh.exe'},
        os: HostOs.windows,
        env: windowsEnv,
      );
      expect(await scoop.locate('gh'), r'C:\Users\rafgl\scoop\shims\gh.exe');
    });

    test('Windows: extraDirs da CLI e Program Files dedup', () async {
      final locator = locatorWith(
        {r'C:\Program Files\GitHub CLI\gh.exe'},
        os: HostOs.windows,
        env: {...windowsEnv, 'ProgramW6432': r'C:\Program Files'},
      );
      expect(locator.windowsProgramDirs(), [
        r'C:\Program Files',
        r'C:\Program Files (x86)',
        r'C:\Users\rafgl\AppData\Local\Programs',
      ]);
      expect(
        await locator.locate('gh', extraDirs: [r'C:\Program Files\GitHub CLI']),
        r'C:\Program Files\GitHub CLI\gh.exe',
      );
    });
  });

  group('cliEnvironment', () {
    test('POSIX: prefixa a pasta da CLI e do git no PATH', () {
      final env = cliEnvironment(
        const {'PATH': '/usr/bin:/bin'},
        executable: '/opt/homebrew/bin/gh',
        windows: false,
        extraPath: const ['/usr/local/bin/git'],
        extra: const {'GH_HOST': 'github.com'},
      );
      expect(env['PATH'], '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin');
      expect(env['GH_HOST'], 'github.com');
      expect(env['GIT_TERMINAL_PROMPT'], '0');
      expect(env['GH_PROMPT_DISABLED'], '1');
    });

    test('Windows: preserva a chave Path e usa ;', () {
      final env = cliEnvironment(
        const {'Path': r'C:\Windows'},
        executable: r'C:\Program Files\GitHub CLI\gh.exe',
        windows: true,
        extraPath: const [r'C:\Program Files\Git\cmd\git.exe'],
      );
      expect(
        env['Path'],
        r'C:\Program Files\GitHub CLI;C:\Program Files\Git\cmd;C:\Windows',
      );
      expect(env.containsKey('PATH'), isFalse);
    });

    test('executável relativo não mexe no PATH', () {
      final env = cliEnvironment(
        const {'PATH': '/usr/bin'},
        executable: 'git',
        windows: false,
      );
      expect(env['PATH'], '/usr/bin');
    });
  });

  test('needsShell só para .cmd/.bat', () {
    expect(needsShell(r'C:\az\wbin\az.cmd'), isTrue);
    expect(needsShell(r'C:\x\run.BAT'), isTrue);
    expect(needsShell(r'C:\gh\gh.exe'), isFalse);
    expect(needsShell('/opt/homebrew/bin/az'), isFalse);
  });

  test('tryDecodeJson tolera aviso antes do JSON', () {
    expect(tryDecodeJson('WARNING: x\n[1, 2]'), [1, 2]);
    expect(tryDecodeJson('nada'), isNull);
    expect(tryDecodeJson(''), isNull);
  });

  test('envValue ignora maiúsculas', () {
    expect(envValue(const {'Path': 'a'}, 'PATH'), 'a');
    expect(envValue(const {'PROGRAMFILES': 'b'}, 'ProgramFiles'), 'b');
  });
}
