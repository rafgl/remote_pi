import 'dart:async';

import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/my_repos_controller.dart';
import 'package:cockpit/app/cockpit/ui/widgets/clone_repository_dialog.dart';
import 'package:cockpit/app/core/domain/entities/app_settings.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'my_repos_fakes.dart';

Widget _host(Widget child) => TranslationProvider(
  child: ShadcnApp(
    theme: buildTheme(brightness: Brightness.dark),
    builder: (context, body) {
      final tokens = buildTokens(
        brightness: Brightness.dark,
        settings: const AppSettings(),
      );
      return CockpitTheme(
        colors: tokens.colors,
        typo: tokens.typo,
        syntax: tokens.syntax,
        terminal: tokens.terminal,
        child: body!,
      );
    },
    home: Scaffold(child: child),
  ),
);

/// Monta o app, abre o dialog e devolve o futuro do resultado.
Future<Future<CloneDialogResult?>> _open(
  WidgetTester tester,
  MyReposController controller, {
  String? clipboard,
  void Function(String)? onRoot,
  void Function(String)? onUrl,
  Future<String?> Function(String?)? pick,
}) async {
  tester.view.physicalSize = const Size(1000, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext ctx;
  await tester.pumpWidget(
    _host(
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        },
      ),
    ),
  );
  final result = showCloneRepositoryDialog(
    ctx,
    initialParent: '/tmp',
    clipboardText: () async => clipboard,
    myRepos: controller,
    onCloneRootChosen: onRoot,
    onOpenUrl: onUrl,
    pickFolder: pick,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return result;
}

MyReposController _controller(
  FakeCatalog catalog, {
  String? root = '/Users/rafgl/Projetos',
  Set<String> gitRepos = const {},
}) => MyReposController(
  catalog: catalog,
  cloneRoot: root,
  home: catalog.os == HostOs.windows ? r'C:\Users\rafgl' : '/Users/rafgl',
  isGitRepo: gitRepos.contains,
  now: () => DateTime.utc(2026, 10, 31, 12),
);

final _repos = [
  repo(
    'rafgl',
    'remote_pi',
    user: true,
    description: 'Fork do Remote Pi',
    updated: DateTime.utc(2026, 10, 31, 10),
  ),
  repo('rafgl', 'dotfiles', user: true, private: true),
  repo('acme-labs', 'billing-api', private: true),
  repo('acme-labs', 'billing-web', private: true),
];

/// `pumpAndSettle` nunca assenta aqui: o cursor do campo de busca pisca e
/// o spinner é indeterminado. Pumps fixos bastam pros dialogs e fades.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('carregando: esqueleto e comando da lista', (tester) async {
    final gate = Completer<void>();
    final c = _controller(
      FakeCatalog([
        FakeProvider(GitHostingKind.github, status: ghReady, gate: gate),
      ]),
    );
    await _open(tester, c);
    unawaited(c.init());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('my-repos-loading')), findsOneWidget);
    expect(find.text('gh repo list'), findsOneWidget);
    gate.complete();
    await _settle(tester);
    expect(find.byKey(const ValueKey('my-repos-loading')), findsNothing);
  });

  testWidgets('lista: donos, Clonar/Abrir, busca, conta logada', (
    tester,
  ) async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(GitHostingKind.github, status: ghReady, repos: _repos),
      ]),
      gitRepos: {'/Users/rafgl/Projetos/remote_pi'},
    );
    await _open(tester, c);
    await c.init();
    await _settle(tester);
    expect(find.text('rafgl · you'), findsOneWidget);
    expect(find.text('acme-labs · organization'), findsOneWidget);
    expect(find.text('github.com · signed in as rafgl (gh)'), findsOneWidget);
    expect(find.text('4 repositories'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-repos-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-repos-clone')), findsNWidgets(3));
    expect(find.text('Already cloned in ~/Projetos/remote_pi'), findsOneWidget);
    expect(find.textContaining('updated 2 hours ago'), findsOneWidget);
    expect(find.text('~/Projetos'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('my-repos-search')),
      'billing',
    );
    await _settle(tester);
    expect(find.text('2 of 4'), findsOneWidget);
    expect(find.text('rafgl · you'), findsNothing);
  });

  testWidgets('Abrir devolve o repo já clonado', (tester) async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(GitHostingKind.github, status: ghReady, repos: _repos),
      ]),
      gitRepos: {'/Users/rafgl/Projetos/remote_pi'},
    );
    final result = await _open(tester, c);
    await c.init();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('my-repos-open')));
    await _settle(tester);
    final r = await result as OpenClonedRepo;
    expect(r.repo.name, 'remote_pi');
    expect(r.path, '/Users/rafgl/Projetos/remote_pi');
  });

  testWidgets('primeiro clone pergunta a pasta, clona e devolve', (
    tester,
  ) async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme-labs', 'billing-api')],
      ),
    ]);
    final c = _controller(catalog, root: null);
    String? savedRoot;
    final result = await _open(tester, c, onRoot: (p) => savedRoot = p);
    await c.init();
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('my-repos-clone')));
    await _settle(tester);
    expect(
      find.text('Where should your repositories be cloned?'),
      findsOneWidget,
    );
    expect(find.text('~/Projetos'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('clone-root-confirm')));
    await _settle(tester);
    expect(savedRoot, '/Users/rafgl/Projetos');
    expect(catalog.cloneTargets, ['/Users/rafgl/Projetos/billing-api']);

    final clone = catalog.clones['acme-labs/billing-api']!;
    clone.output.add('Receiving objects:  62% (620/1000), 38.20 MiB | 5 MiB/s');
    await tester.pump();
    expect(find.text('Receiving objects 62% · 38.20 MiB'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-repos-cancel')), findsOneWidget);

    await clone.finish(0);
    await _settle(tester);
    final r = await result as ClonedRepo;
    expect(r.path, '/Users/rafgl/Projetos/billing-api');
    expect(r.repo.name, 'billing-api');
  });

  testWidgets('cancelar o primeiro uso não clona', (tester) async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme-labs', 'api')],
      ),
    ]);
    final c = _controller(catalog, root: null);
    await _open(tester, c);
    await c.init();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('my-repos-clone')));
    await _settle(tester);
    await tester.tap(find.text('Cancel').last);
    await _settle(tester);
    expect(catalog.cloneTargets, isEmpty);
  });

  testWidgets('erro na linha: causa, saída e Tentar de novo', (tester) async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme-labs', 'infra')],
      ),
    ]);
    final c = _controller(catalog);
    await _open(tester, c);
    await c.init();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('my-repos-clone')));
    await tester.pump();
    final clone = catalog.clones['acme-labs/infra']!;
    clone.output.add('HTTP 404: Not Found (https://api.github.com/repos/x)');
    await clone.finish(1);
    await _settle(tester);
    expect(find.text('No access to acme-labs/infra'), findsOneWidget);
    expect(find.textContaining('HTTP 404'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-repos-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-repos-retry')));
    await tester.pump();
    expect(catalog.cloneTargets, hasLength(2));
  });

  testWidgets('erro da lista: mensagem e Tentar de novo', (tester) async {
    final gh = FakeProvider(
      GitHostingKind.github,
      status: ghReady,
      listError: const GitHostingError(
        GitHostingErrorKind.commandFailed,
        detail: 'dial tcp: no such host',
      ),
    );
    final c = _controller(FakeCatalog([gh]));
    await _open(tester, c);
    await c.init();
    await _settle(tester);
    expect(find.text('gh could not list the repositories.'), findsOneWidget);
    expect(find.text('dial tcp: no such host'), findsOneWidget);
    gh.listError = null;
    gh.repos = _repos;
    await tester.tap(find.text('Try again'));
    await _settle(tester);
    expect(find.text('4 repositories'), findsOneWidget);
  });

  testWidgets('macOS sem CLI: Instalar roda brew absoluto no terminal', (
    tester,
  ) async {
    final c = _controller(FakeCatalog([FakeProvider(GitHostingKind.github)]));
    final result = await _open(tester, c);
    await c.init();
    await _settle(tester);
    expect(find.byKey(const ValueKey('my-repos-connect')), findsOneWidget);
    expect(find.text('No Git service connected'), findsOneWidget);
    expect(find.text('brew install gh'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-repos-install-github')));
    await _settle(tester);
    final r = await result as RunInTerminal;
    expect(r.commands, [
      ['/opt/homebrew/bin/brew', 'install', 'gh'],
    ]);
    expect(r.title, 'Install GitHub CLI');
  });

  testWidgets('macOS sem Homebrew: botão Baixar abre a página oficial', (
    tester,
  ) async {
    final c = _controller(
      FakeCatalog([FakeProvider(GitHostingKind.github)], programs: const {}),
    );
    String? opened;
    await _open(tester, c, onUrl: (u) => opened = u);
    await c.init();
    await _settle(tester);
    expect(find.text('https://cli.github.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-repos-download-github')));
    await tester.pump();
    expect(opened, 'https://cli.github.com');
  });

  testWidgets('Windows sem CLI mostra o winget', (tester) async {
    final c = _controller(
      FakeCatalog(
        [
          FakeProvider(
            GitHostingKind.github,
            install: const InstallHint(
              url: 'https://cli.github.com',
              command: CliCommand('winget', ['install', '--id', 'GitHub.cli']),
            ),
          ),
        ],
        os: HostOs.windows,
        programs: const {},
      ),
      root: null,
    );
    await _open(tester, c);
    await c.init();
    await _settle(tester);
    expect(find.text('winget install --id GitHub.cli'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('my-repos-install-github')),
      findsOneWidget,
    );
    expect(find.textContaining(r'C:\Users\rafgl\Projetos'), findsOneWidget);
  });

  testWidgets('sem login: Conectar usa o caminho absoluto da CLI', (
    tester,
  ) async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(
          GitHostingKind.github,
          status: const ProviderStatus(
            state: ProviderState.signedOut,
            cliPath: '/usr/local/bin/gh',
          ),
        ),
      ]),
    );
    final result = await _open(tester, c);
    await c.init();
    await _settle(tester);
    expect(find.text('gh is installed, not connected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-repos-connect-github')));
    await _settle(tester);
    final r = await result as RunInTerminal;
    expect(r.commands, [
      ['/usr/local/bin/gh', 'auth', 'login', '--web'],
    ]);
    expect(r.title, 'Connect GitHub');
  });

  testWidgets('seletor: vários serviços e Conectar outro serviço', (
    tester,
  ) async {
    final glab = FakeProvider(
      GitHostingKind.gitlab,
      cliName: 'glab',
      status: const ProviderStatus(
        state: ProviderState.ready,
        accounts: [HostingAccount(host: 'gitlab.com', login: 'r')],
      ),
      repos: [repo('grupo', 'app')],
    );
    final c = _controller(
      FakeCatalog([
        FakeProvider(GitHostingKind.github, status: ghReady, repos: _repos),
        glab,
        FakeProvider(GitHostingKind.gitea, cliName: 'tea'),
      ]),
    );
    await _open(tester, c);
    await c.init();
    await _settle(tester);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('GitLab'), findsOneWidget);
    await tester.tap(find.text('GitLab'));
    await _settle(tester);
    expect(find.text('gitlab.com · signed in as r (glab)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('my-repos-connect-other')));
    await _settle(tester);
    expect(find.text('Connect a Git service'), findsOneWidget);
    expect(find.text('tea is not installed'), findsOneWidget);
    expect(find.textContaining('Bitbucket'), findsOneWidget);
  });

  testWidgets('abas: URL no clipboard abre Colar URL', (tester) async {
    final c = _controller(FakeCatalog([FakeProvider(GitHostingKind.github)]));
    await _open(tester, c, clipboard: 'git@github.com:org/repo.git');
    await _settle(tester);
    expect(find.byKey(const ValueKey('clone-url')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('clone-tab-myRepos')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('clone-url')), findsNothing);
  });

  testWidgets('Alterar… troca a pasta padrão', (tester) async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(GitHostingKind.github, status: ghReady, repos: _repos),
      ]),
    );
    String? saved;
    await _open(
      tester,
      c,
      onRoot: (p) => saved = p,
      pick: (_) async => '/Volumes/dev/code',
    );
    await c.init();
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('my-repos-change-root')));
    await _settle(tester);
    expect(saved, '/Volumes/dev/code');
    expect(find.text('/Volumes/dev/code'), findsOneWidget);
  });
}
