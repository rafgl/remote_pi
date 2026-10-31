@Tags(['preview'])
library;

import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/self_updater.dart';
import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/contracts/url_opener.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/my_repos_controller.dart';
import 'package:cockpit/app/cockpit/ui/widgets/clone_repository_dialog.dart';
import 'package:cockpit/app/cockpit/ui/widgets/my_repos_pane.dart'
    show showCloneRootDialog;
import 'package:cockpit/app/cockpit/domain/entities/git_info.dart';
import 'package:cockpit/app/cockpit/domain/entities/project.dart';
import 'package:cockpit/app/cockpit/domain/entities/realm.dart';
import 'package:cockpit/app/cockpit/domain/entities/update_info.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/update_target.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/update_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/projects_rail.dart';
import 'package:cockpit/app/cockpit/ui/widgets/workspace_settings_dialog.dart'
    show kWorkspacePalette;
import 'package:cockpit/app/core/domain/entities/app_settings.dart';
import 'package:cockpit/app/core/ui/keep_awake_controller.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:cockpit_keepawake/cockpit_keepawake.dart'
    show UnsupportedKeepAwake;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'my_repos_fakes.dart';

/// Telas da aba "Meus repositórios" do dialog de clone (issue #278), com o
/// dialog **real** (`showCloneRepositoryDialog` + `MyReposController`) e um
/// catálogo de serviços fictício. Começou como mockup da proposta; hoje
/// mostra a feature implementada. Roda com:
///
///     flutter test test/ui/clone_my_repos_preview_test.dart --tags preview --run-skipped --update-goldens
///
/// Mesmo host/fontes do `clone_repo_preview_test.dart` (Geist no lugar das
/// fontes de produção, que precisam de rede em teste).
///
/// O clone em um clique roda `gh repo clone <owner>/<repo> <pasta>` (ou
/// `glab repo clone`, ou `git clone` no Azure DevOps/Gitea), com o login que a
/// CLI já tem. As telas 6 e 8 usam a [ProjectsRail] real.

String _pubCache() =>
    '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev';

String _flutterRoot() => Platform.environment['FLUTTER_ROOT'] ?? '';

Future<void> _font(String family, String path, [List<String>? more]) async {
  final loader = FontLoader(family);
  for (final file in [path, ...?more]) {
    final f = File(file);
    if (!f.existsSync()) continue;
    loader.addFont(Future.value(f.readAsBytesSync().buffer.asByteData()));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  final shadcn = '${_pubCache()}/shadcn_flutter-0.0.52/lib';
  final sans = [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      '$shadcn/fonts/Geist-$w.otf',
  ];
  final mono = [
    for (final w in ['Regular', 'Medium', 'SemiBold'])
      '$shadcn/fonts/GeistMono-$w.otf',
  ];
  for (final family in ['Geist', 'packages/shadcn_flutter/GeistSans']) {
    await _font(family, sans.first, sans.skip(1).toList());
  }
  for (final family in ['GeistMono', 'packages/shadcn_flutter/GeistMono']) {
    await _font(family, mono.first, mono.skip(1).toList());
  }
  for (final icon in const [
    'icons/LucideIcons.ttf',
    'icons/RadixIcons.otf',
    'icons/BootstrapIcons.otf',
  ]) {
    final family =
        'packages/shadcn_flutter/${icon.split('/').last.split('.').first}';
    await _font(family, '$shadcn/$icon');
  }
  await _font(
    'MaterialIcons',
    '${_flutterRoot()}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
}

const _settings = AppSettings(interfaceFont: 'Geist', codeFont: 'GeistMono');

Widget _host(Widget child) {
  final tokens = buildTokens(brightness: Brightness.dark, settings: _settings);
  return TranslationProvider(
    child: ShadcnApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(
        brightness: Brightness.dark,
        settings: _settings,
      ).copyWith(platform: () => TargetPlatform.macOS),
      builder: (context, nav) => CockpitTheme(
        colors: tokens.colors,
        typo: tokens.typo,
        syntax: tokens.syntax,
        terminal: tokens.terminal,
        child: nav ?? const SizedBox.shrink(),
      ),
      home: Scaffold(child: child),
    ),
  );
}

// ---------------------------------------------------------------------------
// Dados fictícios
// ---------------------------------------------------------------------------

final _now = DateTime.utc(2026, 10, 31, 12);

RemoteRepo _r(
  String owner,
  String name,
  Duration ago, {
  bool private = false,
  String? description,
}) => repo(
  owner,
  name,
  user: owner == 'rafgl',
  private: private,
  description: description,
  updated: _now.subtract(ago),
);

final _repos = <RemoteRepo>[
  _r(
    'rafgl',
    'remote_pi',
    const Duration(hours: 2),
    description: 'Fork do Remote Pi',
  ),
  _r('rafgl', 'dotfiles', const Duration(days: 3), private: true),
  _r('rafgl', 'flutter-playground', const Duration(days: 15)),
  _r(
    'acme-labs',
    'billing-api',
    const Duration(minutes: 40),
    private: true,
    description: 'Cobrança e faturas (Rust)',
  ),
  _r(
    'acme-labs',
    'billing-web',
    const Duration(days: 1, hours: 2),
    private: true,
    description: 'Painel de cobrança (Next.js)',
  ),
  _r('acme-labs', 'design-system', const Duration(days: 5)),
  _r('acme-labs', 'infra', const Duration(days: 35), private: true),
];

InstallHint _hint(GitHostingKind kind, HostOs os) {
  const urls = {
    GitHostingKind.github: 'https://cli.github.com',
    GitHostingKind.gitlab: 'https://gitlab.com/gitlab-org/cli',
    GitHostingKind.azureDevOps:
        'https://learn.microsoft.com/cli/azure/install-azure-cli',
    GitHostingKind.gitea: 'https://gitea.com/gitea/tea',
  };
  const brew = {
    GitHostingKind.github: 'gh',
    GitHostingKind.gitlab: 'glab',
    GitHostingKind.azureDevOps: 'azure-cli',
    GitHostingKind.gitea: 'tea',
  };
  const winget = {
    GitHostingKind.github: 'GitHub.cli',
    GitHostingKind.gitlab: 'GLab.GLab',
    GitHostingKind.azureDevOps: 'Microsoft.AzureCLI',
    GitHostingKind.gitea: 'Gitea.tea',
  };
  return InstallHint(
    url: urls[kind]!,
    command: os == HostOs.windows
        ? CliCommand('winget', ['install', '--id', winget[kind]!])
        : CliCommand('brew', ['install', brew[kind]!]),
  );
}

const _cli = {
  GitHostingKind.github: 'gh',
  GitHostingKind.gitlab: 'glab',
  GitHostingKind.azureDevOps: 'az',
  GitHostingKind.gitea: 'tea',
};

/// Os quatro serviços; [ready] recebem conta e a lista [_repos].
FakeCatalog _catalog({
  Map<GitHostingKind, ProviderStatus> status = const {},
  HostOs os = HostOs.macos,
  Completer<void>? gate,
}) => FakeCatalog([
  for (final kind in GitHostingKind.values)
    FakeProvider(
      kind,
      cliName: _cli[kind]!,
      status: status[kind],
      repos: _repos,
      gate: kind == GitHostingKind.github ? gate : null,
      install: _hint(kind, os),
      connectArgs: switch (kind) {
        GitHostingKind.github => const ['auth', 'login', '--web'],
        GitHostingKind.gitlab => const ['auth', 'login'],
        GitHostingKind.azureDevOps => const ['login'],
        GitHostingKind.gitea => const ['login', 'add'],
      },
    ),
], os: os);

const _glabReady = ProviderStatus(
  state: ProviderState.ready,
  cliPath: '/opt/homebrew/bin/glab',
  accounts: [HostingAccount(host: 'gitlab.com', login: 'rafgl')],
);

MyReposController _controller(
  FakeCatalog catalog, {
  String? root = '/Users/rafgl/Projetos',
  bool windows = false,
}) => MyReposController(
  catalog: catalog,
  cloneRoot: windows && root != null ? r'C:\Users\rafgl\Projetos' : root,
  home: windows ? r'C:\Users\rafgl' : '/Users/rafgl',
  isGitRepo: (path) => path.endsWith('remote_pi'),
  now: () => _now,
);

// ---------------------------------------------------------------------------
// Janela com a ProjectsRail real (telas 6 e 8)
// ---------------------------------------------------------------------------

class _NoUpdateChecker implements UpdateChecker {
  @override
  Future<UpdateInfo?> fetchLatest() async => null;
}

class _NoDismissStore implements DismissedUpdateStore {
  @override
  String? dismissedVersion() => null;
  @override
  Future<void> dismiss(String version) async {}
}

class _NoUrlOpener implements UrlOpener {
  @override
  Future<bool> open(String url) async => true;
}

class _NoSelfUpdater implements SelfUpdater {
  @override
  bool get isSupported => false;
  @override
  SelfUpdateState get state => const SelfUpdateState.idle();
  @override
  Stream<SelfUpdateState> get changes => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> checkForUpdates({bool inBackground = true}) async {}
  @override
  Future<void> applyUpdate() async {}
  @override
  void dispose() {}
}

UpdateViewModel _fakeUpdateVm() => UpdateViewModel(
  _NoUpdateChecker(),
  _NoDismissStore(),
  _NoUrlOpener(),
  const UpdateTarget(
    version: '1.0.0',
    platform: 'macos',
    format: 'dmg',
    arch: 'arm64',
  ),
  _NoSelfUpdater(),
);

final _realm = Realm(
  id: Realm.defaultId,
  name: 'Default',
  createdAt: DateTime.utc(2026),
);

Project _ws(String id, String name, int order) => Project(
  id: id,
  name: name,
  path: '/Users/rafgl/Projetos/$name',
  // Cada workspace novo pega a próxima cor da paleta (como no app).
  colorValue: kWorkspacePalette[order % kWorkspacePalette.length],
  createdAt: DateTime.utc(2026),
  order: order,
);

/// Workspaces que já existiam + (opcional) o recém-clonado no fim.
List<Project> _workspaces({required bool withBillingApi}) => [
  _ws('ws-remote-pi', 'remote_pi', 0),
  _ws('ws-site', 'site-pessoal', 1),
  if (withBillingApi) _ws('ws-billing-api', 'billing-api', 2),
];

/// Área principal mínima: cabeçalho do workspace + estado vazio.
class _MainArea extends StatelessWidget {
  const _MainArea({required this.project, this.toast});

  final Project project;
  final String? toast;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Stack(
      children: [
        Column(
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: colors.panel,
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Text(
                    project.name,
                    style: context.typo.title.copyWith(color: colors.text),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.call_split, size: 13, color: colors.text3),
                  const SizedBox(width: 4),
                  Text(
                    'main',
                    style: context.typo.mono.copyWith(
                      fontSize: 11,
                      color: colors.text2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '~/Projetos/${project.name}',
                    style: context.typo.mono.copyWith(
                      fontSize: 11,
                      color: colors.text3,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.terminal, size: 28, color: colors.text4),
                    const SizedBox(height: 10),
                    Text(
                      'Abra um terminal ou um agente em ${project.name}',
                      style: context.typo.body.copyWith(color: colors.text3),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // Toast estático no estilo do `_toast` do app (SurfaceCard no canto
        // inferior direito); o showToast real anima e deixaria timer pendente.
        if (toast != null)
          Positioned(
            right: 16,
            bottom: 16,
            child: SurfaceCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 18,
                      color: colors.ok,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      toast!,
                      style: context.typo.label.copyWith(color: colors.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Janela do Cockpit: [ProjectsRail] real à esquerda + [_MainArea].
Widget _window({
  required List<Project> projects,
  required String selectedId,
  String? toast,
}) {
  final tokens = buildTokens(brightness: Brightness.dark, settings: _settings);
  final selected = projects.firstWhere((p) => p.id == selectedId);
  final feature = createModule(
    path: '/',
    register: (c) => c.route(
      '/',
      child: (context, state) => Scaffold(
        child: Row(
          children: [
            ProjectsRail(
              projects: projects,
              worktreesOf: (_) => const [],
              worktreesExpanded: (_) => false,
              onWorktreesExpanded: (_, _) {},
              selectedId: selectedId,
              notificationCounts: const {},
              gitInfo: (_) => const GitInfo(branch: 'main'),
              rootsSummary: (_) => (1, 0),
              rootsOf: (id) => [
                (
                  path: projects.firstWhere((p) => p.id == id).path,
                  name: projects.firstWhere((p) => p.id == id).name,
                  git: const GitInfo(branch: 'main'),
                ),
              ],
              forkOriginName: (_) => null,
              onSelect: (_) {},
              onAdd: () async => true,
              onConfigure: (_) {},
              onDelete: (_) {},
              onCreateWorktree: (_, _) {},
              onRemoveWorktree: (_) {},
              onMergeWorktree: (_) {},
              onUpdateWorktree: (_) {},
              onForkWorktree: (_) {},
              onSync: (_, _) {},
              onPull: (_, _) {},
              onPush: (_, _) {},
              onOpenSettings: () {},
              onReorder: (_, _, _) {},
              realms: [_realm],
              activeRealm: _realm,
              onSwitchRealm: (_) {},
              onCreateRealm: () {},
              onManageRealms: () {},
              moveTargetsOf: (_) => const [],
              onMoveToRealm: (_, _) {},
              onSelectCockpit: () {},
              onNewWorkspace: (_) {},
              onSelectRemote: (_) {},
              remoteGitInfoOf: (_) => null,
              onRemoteWorkspaceAction: (_, _) {},
            ),
            Expanded(
              child: _MainArea(project: selected, toast: toast),
            ),
          ],
        ),
      ),
    ),
  );
  return TranslationProvider(
    child: ModularApp(
      module: createModule(register: (c) => c.module(feature)),
      provide: (s) => s
        ..addChangeNotifier<UpdateViewModel>(_fakeUpdateVm)
        ..addChangeNotifier<KeepAwakeController>(
          () => KeepAwakeController(keepAwake: const UnsupportedKeepAwake()),
        ),
      child: Builder(
        builder: (context) => ShadcnApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness: Brightness.dark,
            settings: _settings,
          ).copyWith(platform: () => TargetPlatform.macOS),
          builder: (context, nav) => CockpitTheme(
            colors: tokens.colors,
            typo: tokens.typo,
            syntax: tokens.syntax,
            terminal: tokens.terminal,
            child: nav ?? const SizedBox.shrink(),
          ),
          routerConfig: ModularApp.routerConfigOf(context),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    LocaleSettings.setLocale(AppLocale.ptBr);
  });

  /// Abre o dialog real com [controller] e espera a detecção.
  Future<void> open(
    WidgetTester tester,
    MyReposController controller, {
    double height = 840,
    bool waitInit = true,
  }) async {
    tester.view.physicalSize = Size(820, height) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(const SizedBox.expand()));
    unawaited(
      showCloneRepositoryDialog(
        tester.element(find.byType(SizedBox).last),
        initialParent: '/Users/rafgl/Projetos',
        clipboardText: () async => null,
        myRepos: controller,
      ),
    );
    if (waitInit) {
      await controller.init();
    } else {
      unawaited(controller.init());
    }
    await _settle(tester);
  }

  Future<void> snap(String file) =>
      expectLater(find.byType(ShadcnApp), matchesGoldenFile('previews/$file'));

  testWidgets('1 lista', (tester) async {
    await open(
      tester,
      _controller(
        _catalog(
          status: {
            GitHostingKind.github: ghReady,
            GitHostingKind.gitlab: _glabReady,
          },
        ),
      ),
      height: 900,
    );
    await snap('clone_my_repos_1_list.png');
  });

  testWidgets('2 busca', (tester) async {
    final c = _controller(_catalog(status: {GitHostingKind.github: ghReady}));
    await open(tester, c, height: 600);
    await tester.enterText(
      find.byKey(const ValueKey('my-repos-search')),
      'billing',
    );
    await _settle(tester);
    await snap('clone_my_repos_2_search.png');
  });

  testWidgets('3 clonando', (tester) async {
    final catalog = _catalog(status: {GitHostingKind.github: ghReady});
    final c = _controller(catalog);
    await open(tester, c, height: 960);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('my-repos-row-acme-labs/billing-api')),
        matching: find.byKey(const ValueKey('my-repos-clone')),
      ),
    );
    await tester.pump();
    catalog.clones['acme-labs/billing-api']!.output.add(
      'Receiving objects:  62% (6200/10000), 38.20 MiB | 5.10 MiB/s',
    );
    await _settle(tester);
    await snap('clone_my_repos_3_cloning.png');
  });

  testWidgets('4 sem CLI (macOS)', (tester) async {
    await open(tester, _controller(_catalog()), height: 760);
    await snap('clone_my_repos_4_no_cli.png');
  });

  testWidgets('4b sem CLI (Windows)', (tester) async {
    await open(
      tester,
      _controller(_catalog(os: HostOs.windows), windows: true),
      height: 760,
    );
    await snap('clone_my_repos_4b_no_cli_windows.png');
  });

  testWidgets('5 carregando', (tester) async {
    final gate = Completer<void>();
    await open(
      tester,
      _controller(
        _catalog(status: {GitHostingKind.github: ghReady}, gate: gate),
      ),
      height: 680,
      waitInit: false,
    );
    await snap('clone_my_repos_5_loading.png');
    gate.complete();
  });

  Future<void> windowShot(WidgetTester tester, Widget app, String file) async {
    tester.view.physicalSize = const Size(1100, 640) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await _settle(tester);
    await expectLater(
      find.byType(ShadcnApp),
      matchesGoldenFile('previews/$file'),
    );
  }

  testWidgets('6 workspace criado', (tester) async {
    await windowShot(
      tester,
      _window(
        projects: _workspaces(withBillingApi: true),
        selectedId: 'ws-billing-api',
        toast: 'billing-api clonado em ~/Projetos/billing-api',
      ),
      'clone_my_repos_6_done.png',
    );
  });

  testWidgets('7 erro na linha', (tester) async {
    final catalog = _catalog(status: {GitHostingKind.github: ghReady});
    final c = _controller(catalog);
    await open(tester, c, height: 820);
    await tester.enterText(
      find.byKey(const ValueKey('my-repos-search')),
      'acme-labs/',
    );
    await _settle(tester);
    Future<void> fail(String name, String line, int code) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('my-repos-row-acme-labs/$name')),
          matching: find.byKey(const ValueKey('my-repos-clone')),
        ),
      );
      await tester.pump();
      final clone = catalog.clones['acme-labs/$name']!;
      clone.output.add(line);
      await clone.finish(code);
      await _settle(tester);
    }

    await fail(
      'infra',
      'GraphQL: Could not resolve to a Repository with the name '
          "'acme-labs/infra'. (repository)",
      1,
    );
    await fail(
      'billing-web',
      "fatal: destination path '/Users/rafgl/Projetos/billing-web' already "
          'exists and is not an empty directory.',
      128,
    );
    await snap('clone_my_repos_7_error.png');
  });

  testWidgets('8 abrir já clonado', (tester) async {
    await windowShot(
      tester,
      _window(
        projects: _workspaces(withBillingApi: false),
        selectedId: 'ws-remote-pi',
      ),
      'clone_my_repos_8_open.png',
    );
  });

  testWidgets('9 primeira pasta', (tester) async {
    tester.view.physicalSize = const Size(820, 560) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(const SizedBox.expand()));
    unawaited(
      showCloneRootDialog(
        tester.element(find.byType(SizedBox).last),
        suggested: '/Users/rafgl/Projetos',
        display: (p) => p.replaceFirst('/Users/rafgl', '~'),
        commandExample: 'gh repo clone owner/repo',
        pickFolder: (_) async => null,
      ),
    );
    await _settle(tester);
    await snap('clone_my_repos_9_first_folder.png');
  });

  testWidgets('10 conectar outro serviço', (tester) async {
    final c = _controller(
      _catalog(
        status: {
          GitHostingKind.github: ghReady,
          GitHostingKind.gitlab: const ProviderStatus(
            state: ProviderState.signedOut,
            cliPath: '/opt/homebrew/bin/glab',
          ),
        },
      ),
    );
    await open(tester, c, height: 800);
    await tester.tap(find.byKey(const ValueKey('my-repos-connect-other')));
    await _settle(tester);
    await snap('clone_my_repos_10_connect.png');
  });
}
