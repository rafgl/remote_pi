import 'dart:async';

import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/cockpit/domain/validators/clone_destination.dart';
import 'package:cockpit/app/cockpit/domain/validators/my_repos.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/my_repos_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'my_repos_fakes.dart';

MyReposController _controller(
  FakeCatalog catalog, {
  String? root = '/Users/rafgl/Projetos',
  Set<String> gitRepos = const {},
  String home = '/Users/rafgl',
}) => MyReposController(
  catalog: catalog,
  cloneRoot: root,
  home: home,
  isGitRepo: gitRepos.contains,
  now: () => DateTime.utc(2026, 10, 31, 12),
);

void main() {
  test('sem nenhuma CLI: sem fontes, painel de conexão', () async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(GitHostingKind.github),
        FakeProvider(GitHostingKind.gitlab, cliName: 'glab'),
      ]),
    );
    await c.init();
    expect(c.phase, MyReposPhase.ready);
    expect(c.sources, isEmpty);
    expect(c.showConnect, isTrue);
    expect(c.hasBrew, isTrue);
    expect(c.statusOf(GitHostingKind.github)!.state, ProviderState.cliMissing);
  });

  test('gh sem login: painel de conexão com estado signedOut', () async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(
          GitHostingKind.github,
          status: const ProviderStatus(
            state: ProviderState.signedOut,
            cliPath: '/usr/local/bin/gh',
          ),
        ),
      ], programs: const {}),
    );
    await c.init();
    expect(c.showConnect, isTrue);
    expect(c.hasBrew, isFalse);
    expect(c.statusOf(GitHostingKind.github)!.state, ProviderState.signedOut);
  });

  test('Windows não procura brew', () async {
    final c = _controller(
      FakeCatalog([FakeProvider(GitHostingKind.github)], os: HostOs.windows),
      home: r'C:\Users\rafgl',
      root: null,
    );
    await c.init();
    expect(c.hasBrew, isFalse);
    expect(c.suggestedRoot, r'C:\Users\rafgl\Projetos');
  });

  test('uma fonte por conta; carrega, ordena e filtra', () async {
    final gate = Completer<void>();
    final gh = FakeProvider(
      GitHostingKind.github,
      status: ghReady,
      gate: gate,
      repos: [
        repo('acme', 'infra', updated: DateTime.utc(2026, 9)),
        repo('rafgl', 'dotfiles', user: true, updated: DateTime.utc(2026, 10)),
        repo('acme', 'billing-api', updated: DateTime.utc(2026, 10, 30)),
        repo(
          'rafgl',
          'remote_pi',
          user: true,
          updated: DateTime.utc(2026, 10, 31),
        ),
      ],
    );
    final glab = FakeProvider(
      GitHostingKind.gitlab,
      cliName: 'glab',
      status: const ProviderStatus(
        state: ProviderState.ready,
        accounts: [
          HostingAccount(host: 'gitlab.com', login: 'r'),
          HostingAccount(host: 'gitlab.acme.com', login: 'r'),
        ],
      ),
    );
    final c = _controller(FakeCatalog([gh, glab]));
    final init = c.init();
    await pumpEventQueue();
    expect(c.sources, hasLength(3));
    expect(c.selected!.provider.kind, GitHostingKind.github);
    expect(c.listState, isA<RepoListLoading>());
    gate.complete();
    await init;
    expect(c.visibleRepos.map((r) => r.fullName), [
      'rafgl/remote_pi',
      'rafgl/dotfiles',
      'acme/billing-api',
      'acme/infra',
    ]);
    c.setQuery('BILL');
    expect(c.visibleRepos.single.name, 'billing-api');
    expect(c.totalRepos, 4);

    c.selectSource(c.sources[2]);
    expect(c.query, isEmpty);
    await pumpEventQueue();
    expect(glab.listCalls, 1);
    expect(c.selected!.account.host, 'gitlab.acme.com');
  });

  test('erro da lista vira RepoListFailed e recarrega', () async {
    final gh = FakeProvider(
      GitHostingKind.github,
      status: ghReady,
      listError: const GitHostingError(
        GitHostingErrorKind.signedOut,
        detail: 'gh auth login',
      ),
    );
    final c = _controller(FakeCatalog([gh]));
    await c.init();
    final state = c.listState as RepoListFailed;
    expect(state.error.kind, GitHostingErrorKind.signedOut);
    gh.listError = null;
    await c.reloadList();
    expect(c.listState, isA<RepoListLoaded>());
  });

  test('repo já clonado na pasta padrão vira Abrir', () async {
    final c = _controller(
      FakeCatalog([
        FakeProvider(
          GitHostingKind.github,
          status: ghReady,
          repos: [repo('rafgl', 'remote_pi', user: true)],
        ),
      ]),
      gitRepos: {'/Users/rafgl/Projetos/remote_pi'},
    );
    await c.init();
    final r = c.visibleRepos.single;
    expect(c.clonedPath(r), '/Users/rafgl/Projetos/remote_pi');
    c.setCloneRoot('/outra');
    expect(c.clonedPath(r), isNull);
  });

  test('clone: progresso, sucesso devolve o caminho', () async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme', 'api')],
      ),
    ]);
    final c = _controller(catalog);
    await c.init();
    final r = c.visibleRepos.single;
    final done = c.clone(r);
    await pumpEventQueue();
    expect(c.anyCloneRunning, isTrue);
    final clone = catalog.clones['acme/api']!;
    clone.output.add('Receiving objects:  50% (5/10), 1.00 MiB | 1 MiB/s');
    await pumpEventQueue();
    expect(c.cloneOf(r)!.progress!.phase, ClonePhase.receiving);
    expect(c.cloneOf(r)!.command, startsWith('gh repo clone acme/api'));
    await clone.finish(0);
    expect(await done, '/Users/rafgl/Projetos/api');
    expect(c.anyCloneRunning, isFalse);
  });

  test('clone: falha classificada na linha', () async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme', 'web')],
      ),
    ]);
    final c = _controller(catalog);
    await c.init();
    final r = c.visibleRepos.single;
    final done = c.clone(r);
    await pumpEventQueue();
    final clone = catalog.clones['acme/web']!;
    clone.output.add(
      "fatal: destination path 'web' already exists and is not an empty directory.",
    );
    await pumpEventQueue();
    await clone.finish(128);
    expect(await done, isNull);
    final state = c.cloneOf(r)!;
    expect(state.failed, isTrue);
    expect(state.failure, CloneFailure.targetExists);
    expect(state.lastMessage, contains('already exists'));
    c.clearCloneError(r);
    expect(c.cloneOf(r), isNull);
  });

  test('cancelar mata o processo e libera a linha', () async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme', 'api')],
      ),
    ]);
    final c = _controller(catalog);
    await c.init();
    final r = c.visibleRepos.single;
    final done = c.clone(r);
    await pumpEventQueue();
    await c.cancelClone(r);
    expect(catalog.clones['acme/api']!.cancelled, isTrue);
    expect(await done, isNull);
    expect(c.cloneOf(r), isNull);
  });

  test('sem pasta padrão não clona', () async {
    final catalog = FakeCatalog([
      FakeProvider(
        GitHostingKind.github,
        status: ghReady,
        repos: [repo('acme', 'api')],
      ),
    ]);
    final c = _controller(catalog, root: null);
    await c.init();
    expect(await c.clone(c.visibleRepos.single), isNull);
    expect(catalog.cloneTargets, isEmpty);
    expect(c.suggestedRoot, '/Users/rafgl/Projetos');
  });
}
