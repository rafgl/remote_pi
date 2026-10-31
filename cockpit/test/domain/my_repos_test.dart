import 'package:cockpit/app/cockpit/domain/validators/clone_destination.dart';
import 'package:cockpit/app/cockpit/domain/validators/my_repos.dart';
import 'package:cockpit/app/core/utils/user_home.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('defaultCloneRoot', () {
    test('macOS (Silicon e Intel): ~/Projetos', () {
      final home = userHome(
        environment: const {'HOME': '/Users/rafgl'},
        isWindows: false,
      );
      expect(defaultCloneRoot(home, context: p.posix), '/Users/rafgl/Projetos');
    });

    test(r'Windows: %USERPROFILE%\Projetos, sem HOME', () {
      final home = userHome(
        environment: const {'USERPROFILE': r'C:\Users\rafgl'},
        isWindows: true,
      );
      expect(
        defaultCloneRoot(home, context: p.windows),
        r'C:\Users\rafgl\Projetos',
      );
    });

    test(r'Windows: HOMEDRIVE+HOMEPATH quando falta USERPROFILE', () {
      final home = userHome(
        environment: const {'HOMEDRIVE': 'D:', 'HOMEPATH': r'\Users\rafgl'},
        isWindows: true,
      );
      expect(
        defaultCloneRoot(home, context: p.windows),
        r'D:\Users\rafgl\Projetos',
      );
    });

    test('sem home: null (usuário escolhe)', () {
      expect(defaultCloneRoot(null), isNull);
      expect(defaultCloneRoot('  '), isNull);
    });

    test('alvo do clone com o separador da plataforma', () {
      expect(
        cloneTargetPath(r'C:\Users\rafgl\Projetos', 'api', context: p.windows),
        r'C:\Users\rafgl\Projetos\api',
      );
      expect(
        cloneTargetPath('/Users/rafgl/Projetos', 'api', context: p.posix),
        '/Users/rafgl/Projetos/api',
      );
    });
  });

  group('displayPath', () {
    test('POSIX encurta com ~', () {
      expect(
        displayPath('/Users/me/Projetos/api', home: '/Users/me'),
        '~/Projetos/api',
      );
      expect(displayPath('/Users/me', home: '/Users/me'), '~');
      expect(displayPath('/Users/meu/x', home: '/Users/me'), '/Users/meu/x');
    });

    test('Windows mantém o caminho inteiro', () {
      expect(
        displayPath(
          r'C:\Users\me\Projetos',
          home: r'C:\Users\me',
          windows: true,
        ),
        r'C:\Users\me\Projetos',
      );
    });
  });

  group('parseCloneProgress', () {
    test('recebendo objetos com volume', () {
      final p = parseCloneProgress(
        'Receiving objects:  62% (620/1000), 38.20 MiB | 5.00 MiB/s',
      )!;
      expect(p.phase, ClonePhase.receiving);
      expect(p.percent, 62);
      expect(p.transferred, '38.20 MiB');
      expect(p.overall, closeTo(0.496, 0.001));
    });

    test('fases do servidor ficam em 0', () {
      final p = parseCloneProgress(
        'remote: Counting objects: 100% (5/5), done.',
      )!;
      expect(p.phase, ClonePhase.counting);
      expect(p.overall, 0);
    });

    test('resolvendo deltas e checkout', () {
      expect(
        parseCloneProgress('Resolving deltas: 50% (1/2)')!.overall,
        closeTo(0.875, 0.001),
      );
      expect(
        parseCloneProgress('Updating files: 100% (9/9), done.')!.overall,
        1,
      );
    });

    test('linha comum não é progresso', () {
      expect(parseCloneProgress("Cloning into 'api'..."), isNull);
      expect(parseCloneProgress(r'$ gh repo clone a/b'), isNull);
    });
  });

  group('shellCommand / terminalScript', () {
    test('POSIX: aspas só quando precisa', () {
      expect(
        shellCommand([
          '/opt/homebrew/bin/gh',
          'auth',
          'login',
          '--web',
        ], TerminalShell.posix),
        '/opt/homebrew/bin/gh auth login --web',
      );
      expect(
        shellCommand([
          '/Applications/My Tools/gh',
          "it's",
        ], TerminalShell.posix),
        r"'/Applications/My Tools/gh' 'it'\''s'",
      );
    });

    test('PowerShell: & antes de programa com espaço', () {
      expect(
        shellCommand([
          r'C:\Program Files\GitHub CLI\gh.exe',
          'auth',
          'login',
          '--web',
        ], TerminalShell.powershell),
        r"& 'C:\Program Files\GitHub CLI\gh.exe' auth login --web",
      );
      expect(
        shellCommand([
          'winget',
          'install',
          '--id',
          'GitHub.cli',
        ], TerminalShell.powershell),
        'winget install --id GitHub.cli',
      );
    });

    test('script termina em exit e usa ; (PowerShell 5 não tem &&)', () {
      expect(
        terminalScript([
          ['az', 'login'],
          ['az', 'account', 'show'],
        ], TerminalShell.powershell),
        'az login; az account show; exit',
      );
    });
  });

  group('classifyCloneFailure', () {
    test('pasta já existe', () {
      expect(
        classifyCloneFailure([
          "fatal: destination path '/p/api' already exists and is not an "
              'empty directory.',
        ]),
        CloneFailure.targetExists,
      );
    });

    test('gh sem acesso', () {
      expect(
        classifyCloneFailure([
          'GraphQL: Could not resolve to a Repository with the name x/y.',
        ]),
        CloneFailure.auth,
      );
      expect(classifyCloneFailure(['HTTP 404: Not Found']), CloneFailure.auth);
    });
  });
}
