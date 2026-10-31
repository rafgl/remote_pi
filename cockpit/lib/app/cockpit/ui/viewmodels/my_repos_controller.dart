import 'dart:async';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/cockpit/domain/validators/clone_destination.dart';
import 'package:cockpit/app/cockpit/domain/validators/my_repos.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Uma conta logada de um serviço: o que o seletor da aba mostra.
class RepoSource {
  const RepoSource(this.provider, this.account);

  final GitHostingProvider provider;
  final HostingAccount account;

  String get key => '${provider.kind.name}|${account.host}|${account.login}';
}

/// Estado da lista de uma [RepoSource].
sealed class RepoListState {
  const RepoListState();
}

final class RepoListLoading extends RepoListState {
  const RepoListLoading();
}

final class RepoListLoaded extends RepoListState {
  const RepoListLoaded(this.repos);

  final List<RemoteRepo> repos;
}

final class RepoListFailed extends RepoListState {
  const RepoListFailed(this.error);

  final GitHostingError error;
}

/// Clone em andamento (ou que falhou) numa linha da lista.
class RepoCloneState {
  RepoCloneState({required this.command, required this.targetPath});

  /// Linha de comando mostrada embaixo da barra (`$ gh repo clone ...`).
  final String command;
  final String targetPath;
  final List<String> output = [];
  CloneProgress? progress;
  bool running = true;

  /// Preenchido quando o clone falhou (não quando foi cancelado).
  bool failed = false;
  CloneFailure? failure;
  CloneProcess? process;

  /// Última linha que não é progresso nem o eco do comando: o erro cru.
  String? get lastMessage {
    for (final line in output.reversed) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith(r'$ ') || parseCloneProgress(t) != null) {
        continue;
      }
      return t;
    }
    return null;
  }
}

/// Em que ponto a detecção dos serviços está.
enum MyReposPhase { detecting, ready }

/// Controller da aba "Meus repositórios" do dialog de clone. Vive enquanto o
/// dialog está aberto (criado no call-site, descartado depois do `showDialog`).
///
/// Detecta as CLIs em paralelo, monta as fontes (uma por conta logada), lista
/// os repos da fonte escolhida e roda os clones em um clique. Não traduz nada:
/// expõe estado e erros tipados, a UI monta o texto.
class MyReposController extends ChangeNotifier {
  MyReposController({
    required this.catalog,
    required this._cloneRoot,
    required this.home,
    bool Function(String path)? isGitRepo,
    DateTime Function()? now,
  }) : _isGitRepo = isGitRepo ?? _defaultIsGitRepo,
       now = now ?? DateTime.now;

  final GitHostingCatalog catalog;
  final String? home;
  final bool Function(String path) _isGitRepo;
  final DateTime Function() now;

  static bool _defaultIsGitRepo(String path) =>
      FileSystemEntity.typeSync(p.join(path, '.git')) !=
      FileSystemEntityType.notFound;

  MyReposPhase _phase = MyReposPhase.detecting;
  MyReposPhase get phase => _phase;

  final Map<GitHostingKind, ProviderStatus> _statuses = {};
  ProviderStatus? statusOf(GitHostingKind kind) => _statuses[kind];

  List<RepoSource> _sources = const [];
  List<RepoSource> get sources => _sources;

  String? _selectedKey;
  RepoSource? get selected =>
      _sources.where((s) => s.key == _selectedKey).firstOrNull;

  /// Painel "Conectar outro serviço" aberto (ou forçado por não haver fonte).
  bool _connectOpen = false;
  bool get showConnect => _connectOpen || _sources.isEmpty;

  final Map<String, RepoListState> _lists = {};
  RepoListState? get listState {
    final s = selected;
    return s == null ? null : _lists[s.key];
  }

  String _query = '';
  String get query => _query;

  String? _cloneRoot;
  String? get cloneRoot => _cloneRoot;

  /// macOS: o Homebrew existe? Sem ele, "Instalar" vira só o link.
  bool _hasBrew = false;
  bool get hasBrew => _hasBrew;

  final Map<String, RepoCloneState> _clones = {};
  RepoCloneState? cloneOf(RemoteRepo repo) => _clones[_repoKey(repo)];

  bool get anyCloneRunning => _clones.values.any((c) => c.running);

  bool _disposed = false;

  static String _repoKey(RemoteRepo r) =>
      '${r.kind.name}|${r.host}|${r.fullName}';

  HostOs get os => catalog.os;

  p.Context get _ctx => os == HostOs.windows ? p.windows : p.posix;

  /// Pasta sugerida no primeiro uso.
  String? get suggestedRoot => defaultCloneRoot(home, context: _ctx);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Detecta todas as CLIs (em paralelo) e carrega a lista da primeira fonte.
  Future<void> init() async {
    _phase = MyReposPhase.detecting;
    _notify();
    final providers = catalog.providers;
    final results = await Future.wait([
      for (final provider in providers) provider.status(),
      if (os == HostOs.macos) catalog.locate('brew').then((b) => b != null),
    ]);
    if (_disposed) return;
    for (var i = 0; i < providers.length; i++) {
      _statuses[providers[i].kind] = results[i] as ProviderStatus;
    }
    if (os == HostOs.macos) _hasBrew = results.last as bool;
    _sources = [
      for (final provider in providers)
        if (_statuses[provider.kind] case final st?
            when st.state == ProviderState.ready)
          for (final account in st.accounts) RepoSource(provider, account),
    ];
    final keep = _sources.any((s) => s.key == _selectedKey);
    if (!keep) _selectedKey = _sources.firstOrNull?.key;
    if (_sources.isNotEmpty) _connectOpen = false;
    _lists.clear();
    _phase = MyReposPhase.ready;
    _notify();
    final s = selected;
    if (s != null) await _load(s);
  }

  Future<void> _load(RepoSource source) async {
    _lists[source.key] = const RepoListLoading();
    _notify();
    final res = await source.provider.listRepos(source.account);
    if (_disposed) return;
    _lists[source.key] = switch (res) {
      Success(:final value) => RepoListLoaded(_sorted(value, source)),
      Failure(:final error) => RepoListFailed(error),
    };
    _notify();
  }

  /// Repos do usuário primeiro, depois cada dono em ordem alfabética; dentro
  /// do dono, o atualizado mais recente primeiro.
  List<RemoteRepo> _sorted(List<RemoteRepo> repos, RepoSource source) {
    final list = [...repos];
    list.sort((a, b) {
      final ua = a.ownerKind == RepoOwnerKind.user ? 0 : 1;
      final ub = b.ownerKind == RepoOwnerKind.user ? 0 : 1;
      if (ua != ub) return ua - ub;
      final o = a.owner.toLowerCase().compareTo(b.owner.toLowerCase());
      if (o != 0) return o;
      final da = a.updatedAt, db = b.updatedAt;
      if (da != null && db != null) return db.compareTo(da);
      if (da != null) return -1;
      if (db != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Recarrega a lista da fonte atual (o "Tentar de novo" do erro).
  Future<void> reloadList() async {
    final s = selected;
    if (s != null) await _load(s);
  }

  void selectSource(RepoSource source) {
    _selectedKey = source.key;
    _connectOpen = false;
    _query = '';
    _notify();
    if (_lists[source.key] is! RepoListLoaded) unawaited(_load(source));
  }

  void openConnect() {
    _connectOpen = true;
    _notify();
  }

  void setQuery(String value) {
    _query = value;
    _notify();
  }

  void setCloneRoot(String path) {
    _cloneRoot = path;
    _notify();
  }

  /// Repos da fonte atual filtrados pela busca (dono/nome e descrição).
  List<RemoteRepo> get visibleRepos {
    final state = listState;
    if (state is! RepoListLoaded) return const [];
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return state.repos;
    return [
      for (final r in state.repos)
        if (r.fullName.toLowerCase().contains(q) ||
            (r.description?.toLowerCase().contains(q) ?? false))
          r,
    ];
  }

  int get totalRepos => switch (listState) {
    RepoListLoaded(:final repos) => repos.length,
    _ => 0,
  };

  /// Caminho do clone de [repo] dentro da pasta padrão.
  String? targetOf(RemoteRepo repo) {
    final root = _cloneRoot;
    return root == null
        ? null
        : cloneTargetPath(root, repo.name, context: _ctx);
  }

  /// Caminho do repo se ele já está clonado na pasta padrão (pasta com `.git`).
  String? clonedPath(RemoteRepo repo) {
    final target = targetOf(repo);
    if (target == null) return null;
    final clone = cloneOf(repo);
    if (clone != null && (clone.running || clone.failed)) return null;
    return _isGitRepo(target) ? target : null;
  }

  /// Clona [repo] na pasta padrão. Devolve o caminho em caso de sucesso;
  /// `null` se falhou ou foi cancelado (o estado da linha diz qual).
  Future<String?> clone(RemoteRepo repo) async {
    final source = _sources
        .where((s) => s.provider.kind == repo.kind)
        .firstOrNull;
    final target = targetOf(repo);
    if (source == null || target == null) return null;
    final key = _repoKey(repo);
    final spec = source.provider.cloneSpec(repo, target);
    final command = switch (spec) {
      CliCloneSpec(:final command) => command.display,
      GitUrlCloneSpec(:final url) => 'git clone $url $target',
    };
    final state = RepoCloneState(command: command, targetPath: target);
    _clones[key] = state;
    _notify();
    final process = catalog.clone(source.provider, repo, target);
    state.process = process;
    final sub = process.output.listen((line) {
      state.output.add(line);
      final progress = parseCloneProgress(line);
      if (progress != null) state.progress = progress;
      _notify();
    });
    final code = await process.exitCode;
    await sub.asFuture<void>().catchError((_) {});
    state.running = false;
    state.process = null;
    if (identical(_clones[key], state) && code != 0) {
      state.failed = true;
      state.failure = classifyCloneFailure(state.output);
    }
    _notify();
    return code == 0 ? target : null;
  }

  /// Cancela o clone de [repo] e esquece a linha (volta a "Clonar").
  Future<void> cancelClone(RemoteRepo repo) async {
    final key = _repoKey(repo);
    final state = _clones.remove(key);
    _notify();
    await state?.process?.cancel();
  }

  /// Esquece o erro da linha (antes de "Tentar de novo").
  void clearCloneError(RemoteRepo repo) {
    _clones.remove(_repoKey(repo));
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    // Dialog fechado no meio de um clone: não deixa processo órfão.
    for (final c in _clones.values) {
      unawaited(c.process?.cancel());
    }
    super.dispose();
  }
}
