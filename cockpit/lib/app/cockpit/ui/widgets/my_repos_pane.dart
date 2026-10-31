import 'dart:async';

import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/cockpit/domain/validators/clone_destination.dart';
import 'package:cockpit/app/cockpit/domain/validators/my_repos.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/my_repos_controller.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Nome do serviço (nome próprio, não se traduz).
String hostingName(GitHostingKind kind) => switch (kind) {
  GitHostingKind.github => 'GitHub',
  GitHostingKind.gitlab => 'GitLab',
  GitHostingKind.azureDevOps => 'Azure DevOps',
  GitHostingKind.gitea => 'Gitea / Forgejo',
};

/// Nome da CLI como o usuário conhece (nome próprio).
String hostingCliName(GitHostingKind kind) => switch (kind) {
  GitHostingKind.github => 'GitHub CLI',
  GitHostingKind.gitlab => 'GitLab CLI',
  GitHostingKind.azureDevOps => 'Azure CLI',
  GitHostingKind.gitea => 'tea',
};

IconData hostingIcon(GitHostingKind kind) => switch (kind) {
  GitHostingKind.github => Icons.hub_outlined,
  GitHostingKind.gitlab => Icons.change_history,
  GitHostingKind.azureDevOps => Icons.cloud_outlined,
  GitHostingKind.gitea => Icons.local_cafe_outlined,
};

/// Comando mostrado enquanto a lista carrega.
String _listCommand(GitHostingKind kind) => switch (kind) {
  GitHostingKind.github => 'gh repo list',
  GitHostingKind.gitlab => 'glab repo list',
  GitHostingKind.azureDevOps => 'az rest …/_apis/git/repositories',
  GitHostingKind.gitea => 'tea repos ls',
};

/// Exemplo do comando de clone de cada serviço (texto do primeiro uso).
String cloneCommandExample(GitHostingKind kind) => switch (kind) {
  GitHostingKind.github => 'gh repo clone owner/repo',
  GitHostingKind.gitlab => 'glab repo clone group/repo',
  GitHostingKind.azureDevOps || GitHostingKind.gitea => 'git clone <url>',
};

/// "há 2 horas", "ontem"... a partir de [now].
String relativeAgo(BuildContext context, DateTime when, DateTime now) {
  final tr = context.t.cockpit.myRepos;
  final d = now.difference(when);
  if (d.inMinutes < 1) return tr.justNow;
  if (d.inHours < 1) return tr.minutesAgo(n: d.inMinutes);
  if (d.inDays < 1) return tr.hoursAgo(n: d.inHours);
  if (d.inDays < 2) return tr.yesterday;
  if (d.inDays < 7) return tr.daysAgo(n: d.inDays);
  if (d.inDays < 30) return tr.weeksAgo(n: d.inDays ~/ 7);
  if (d.inDays < 365) return tr.monthsAgo(n: d.inDays ~/ 30);
  return tr.yearsAgo(n: d.inDays ~/ 365);
}

/// Aba "Meus repositórios" do dialog de clone. Só desenha o [controller] e
/// repassa as ações; o que fecha o dialog (clonou, abrir, rodar no terminal)
/// vem pelos callbacks.
class MyReposPane extends StatelessWidget {
  const MyReposPane({
    super.key,
    required this.controller,
    required this.ensureCloneRoot,
    required this.onChangeCloneRoot,
    required this.onCloned,
    required this.onOpen,
    required this.onRunInTerminal,
    required this.onOpenUrl,
  });

  final MyReposController controller;

  /// Garante a pasta padrão antes do primeiro clone (pergunta no primeiro
  /// uso). `false` = o usuário cancelou.
  final Future<bool> Function() ensureCloneRoot;

  /// "Alterar…" do rodapé.
  final VoidCallback onChangeCloneRoot;
  final void Function(RemoteRepo repo, String path) onCloned;
  final void Function(RemoteRepo repo, String path) onOpen;

  /// Instalar/Conectar: argv de cada comando + título da aba de terminal.
  final void Function(List<List<String>> commands, String title)
  onRunInTerminal;
  final void Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final tr = context.t.cockpit.myRepos;
        if (c.phase == MyReposPhase.detecting) {
          return _Loading(label: tr.detecting);
        }
        final source = c.selected;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.sources.isNotEmpty) ...[
              _SourceBar(controller: c),
              const SizedBox(height: 12),
            ],
            if (c.showConnect || source == null)
              _ConnectPanel(
                controller: c,
                onRunInTerminal: onRunInTerminal,
                onOpenUrl: onOpenUrl,
              )
            else
              switch (c.listState) {
                null || RepoListLoading() => _Loading(
                  label: tr.loading(
                    provider: hostingName(source.provider.kind),
                  ),
                  command: _listCommand(source.provider.kind),
                ),
                RepoListFailed(:final error) => _ListError(
                  source: source,
                  error: error,
                  onRetry: c.reloadList,
                  onConnect: c.openConnect,
                ),
                RepoListLoaded() => _RepoBrowser(
                  controller: c,
                  source: source,
                  ensureCloneRoot: ensureCloneRoot,
                  onChangeCloneRoot: onChangeCloneRoot,
                  onCloned: onCloned,
                  onOpen: onOpen,
                ),
              },
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Seletor de serviço
// ---------------------------------------------------------------------------

class _SourceBar extends StatelessWidget {
  const _SourceBar({required this.controller});

  final MyReposController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final selectedKey = c.showConnect ? null : c.selected?.key;
    Widget chip({
      required Key key,
      required bool active,
      required IconData icon,
      required String label,
      required VoidCallback onPressed,
    }) {
      final leading = Icon(icon, size: 14);
      final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
      return active
          ? PrimaryButton(
              key: key,
              size: ButtonSize.small,
              onPressed: onPressed,
              leading: leading,
              child: text,
            )
          : OutlineButton(
              key: key,
              size: ButtonSize.small,
              onPressed: onPressed,
              leading: leading,
              child: text,
            );
    }

    // Um único serviço com uma conta: o nome basta. Vários hosts do mesmo
    // serviço (github.com + GHE): o host desambigua.
    final kinds = c.sources.map((s) => s.provider.kind).toList();
    String labelOf(RepoSource s) {
      final repeated = kinds.where((k) => k == s.provider.kind).length > 1;
      return repeated
          ? '${hostingName(s.provider.kind)} · ${s.account.host}'
          : hostingName(s.provider.kind);
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in c.sources)
          chip(
            key: ValueKey('my-repos-source-${s.key}'),
            active: s.key == selectedKey,
            icon: hostingIcon(s.provider.kind),
            label: labelOf(s),
            onPressed: () => c.selectSource(s),
          ),
        chip(
          key: const ValueKey('my-repos-connect-other'),
          active: c.showConnect,
          icon: Icons.add_link,
          label: context.t.cockpit.myRepos.connectOther,
          onPressed: c.openConnect,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Carregando
// ---------------------------------------------------------------------------

class _Loading extends StatelessWidget {
  const _Loading({required this.label, this.command});

  final String label;
  final String? command;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: colors.panel3,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Column(
      key: const ValueKey('my-repos-loading'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          enabled: false,
          placeholder: Text(tr.search),
          features: const [InputFeature.leading(Icon(Icons.search, size: 16))],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(size: 12, color: colors.accent),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: context.typo.label.copyWith(color: colors.text2),
              ),
            ),
            if (command != null)
              Text(
                command!,
                style: context.typo.mono.copyWith(
                  fontSize: 10.5,
                  color: colors.text3,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(90, 10),
              const SizedBox(height: 12),
              for (final w in const [140.0, 110.0, 170.0, 125.0, 150.0])
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    children: [
                      bar(15, 15),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            bar(w, 12),
                            const SizedBox(height: 6),
                            bar(w + 120, 9),
                          ],
                        ),
                      ),
                      bar(78, 28),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Erro da lista
// ---------------------------------------------------------------------------

class _ListError extends StatelessWidget {
  const _ListError({
    required this.source,
    required this.error,
    required this.onRetry,
    required this.onConnect,
  });

  final RepoSource source;
  final GitHostingError error;
  final VoidCallback onRetry;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final cli = source.provider.cliName;
    final provider = hostingName(source.provider.kind);
    final message = switch (error.kind) {
      GitHostingErrorKind.signedOut => tr.errSignedOut(provider: provider),
      GitHostingErrorKind.cliMissing => tr.errCli(cli: cli),
      GitHostingErrorKind.noOrganization => tr.errNoOrg,
      GitHostingErrorKind.commandFailed => tr.errCommand(cli: cli),
      GitHostingErrorKind.badOutput => tr.errOutput(cli: cli),
    };
    final detail = error.detail?.trim();
    return Container(
      key: const ValueKey('my-repos-list-error'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: colors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: context.typo.body.copyWith(color: colors.text),
                ),
              ),
            ],
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: context.typo.mono.copyWith(
                fontSize: 10.5,
                color: colors.text3,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              PrimaryButton(
                size: ButtonSize.small,
                onPressed: onRetry,
                leading: const Icon(Icons.refresh, size: 14),
                child: Text(tr.retry),
              ),
              if (error.kind == GitHostingErrorKind.signedOut ||
                  error.kind == GitHostingErrorKind.cliMissing) ...[
                const SizedBox(width: 8),
                OutlineButton(
                  size: ButtonSize.small,
                  onPressed: onConnect,
                  child: Text(tr.connectOther),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lista
// ---------------------------------------------------------------------------

class _RepoBrowser extends StatefulWidget {
  const _RepoBrowser({
    required this.controller,
    required this.source,
    required this.ensureCloneRoot,
    required this.onChangeCloneRoot,
    required this.onCloned,
    required this.onOpen,
  });

  final MyReposController controller;
  final RepoSource source;
  final Future<bool> Function() ensureCloneRoot;
  final VoidCallback onChangeCloneRoot;
  final void Function(RemoteRepo repo, String path) onCloned;
  final void Function(RemoteRepo repo, String path) onOpen;

  @override
  State<_RepoBrowser> createState() => _RepoBrowserState();
}

class _RepoBrowserState extends State<_RepoBrowser> {
  late final _search = TextEditingController(text: widget.controller.query);

  @override
  void didUpdateWidget(covariant _RepoBrowser old) {
    super.didUpdateWidget(old);
    // Trocou de fonte: a busca foi zerada no controller.
    if (_search.text != widget.controller.query) {
      _search.text = widget.controller.query;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _clone(RemoteRepo repo) async {
    if (!await widget.ensureCloneRoot()) return;
    if (!mounted) return;
    final path = await widget.controller.clone(repo);
    if (path == null || !mounted) return;
    widget.onCloned(repo, path);
  }

  Future<void> _retry(RemoteRepo repo) async {
    widget.controller.clearCloneError(repo);
    await _clone(repo);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final visible = c.visibleRepos;
    final q = c.query.trim();
    final account = widget.source.account;
    final windows = c.os == HostOs.windows;
    final root = c.cloneRoot ?? c.suggestedRoot;

    final items = <Widget>[];
    String? lastOwner;
    for (final r in visible) {
      if (r.owner != lastOwner) {
        items.add(
          _OwnerHeader(
            owner: r.owner,
            kind: r.ownerKind,
            first: lastOwner == null,
          ),
        );
        lastOwner = r.owner;
      }
      items.add(
        _RepoRow(
          key: ValueKey('my-repos-row-${r.fullName}'),
          repo: r,
          query: q,
          controller: c,
          onClone: () => _clone(r),
          onRetry: () => _retry(r),
          onOpen: (path) => widget.onOpen(r, path),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('my-repos-search'),
          controller: _search,
          autofocus: true,
          placeholder: Text(tr.search),
          features: const [InputFeature.leading(Icon(Icons.search, size: 16))],
          onChanged: c.setQuery,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(Icons.check_circle, size: 12, color: colors.online),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr.signedInAs(
                  host: account.host,
                  login: account.login,
                  cli: widget.source.provider.cliName,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.label.copyWith(color: colors.text3),
              ),
            ),
            Text(
              q.isEmpty
                  ? tr.count(n: c.totalRepos)
                  : tr.countFiltered(
                      shown: visible.length,
                      total: c.totalRepos,
                    ),
              style: context.typo.label.copyWith(color: colors.text3),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          constraints: const BoxConstraints(maxHeight: 400),
          decoration: BoxDecoration(
            color: colors.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.border),
          ),
          child: items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      q.isEmpty ? tr.empty : tr.noMatch(query: q),
                      style: context.typo.label.copyWith(color: colors.text3),
                    ),
                  ),
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ListView(shrinkWrap: true, children: items),
                ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.folder_outlined, size: 14, color: colors.text3),
            const SizedBox(width: 6),
            Text(
              '${tr.clonesInto} ',
              style: context.typo.label.copyWith(color: colors.text3),
            ),
            Expanded(
              child: Text(
                root == null
                    ? '—'
                    : displayPath(root, home: c.home, windows: windows),
                key: const ValueKey('my-repos-root'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.typo.mono.copyWith(
                  fontSize: 11,
                  color: c.cloneRoot == null ? colors.text3 : colors.text2,
                ),
              ),
            ),
            GhostButton(
              key: const ValueKey('my-repos-change-root'),
              size: ButtonSize.small,
              onPressed: c.anyCloneRunning ? null : widget.onChangeCloneRoot,
              child: Text(tr.change),
            ),
          ],
        ),
      ],
    );
  }
}

class _OwnerHeader extends StatelessWidget {
  const _OwnerHeader({
    required this.owner,
    required this.kind,
    required this.first,
  });

  final String owner;
  final RepoOwnerKind kind;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final org = kind == RepoOwnerKind.organization;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(
            org ? Icons.apartment_outlined : Icons.person_outline,
            size: 13,
            color: colors.text3,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              org ? tr.ownerOrg(owner: owner) : tr.ownerYou(owner: owner),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typo.label.copyWith(
                color: colors.text3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RepoRow extends StatefulWidget {
  const _RepoRow({
    super.key,
    required this.repo,
    required this.query,
    required this.controller,
    required this.onClone,
    required this.onRetry,
    required this.onOpen,
  });

  final RemoteRepo repo;
  final String query;
  final MyReposController controller;
  final VoidCallback onClone;
  final VoidCallback onRetry;
  final void Function(String path) onOpen;

  @override
  State<_RepoRow> createState() => _RepoRowState();
}

class _RepoRowState extends State<_RepoRow> {
  bool _details = false;

  /// Nome com o trecho buscado destacado.
  Widget _name(BuildContext context) {
    final colors = context.colors;
    final name = widget.repo.name;
    final base = context.typo.body.copyWith(
      color: colors.text,
      fontWeight: FontWeight.w600,
    );
    final q = widget.query.toLowerCase();
    final i = q.isEmpty ? -1 : name.toLowerCase().indexOf(q);
    if (i < 0) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: name.substring(0, i)),
          TextSpan(
            text: name.substring(i, i + q.length),
            style: base.copyWith(
              color: colors.accentText,
              backgroundColor: colors.accentSoft,
            ),
          ),
          TextSpan(text: name.substring(i + q.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _failureText(BuildContext context, RepoCloneState clone) {
    final tr = context.t.cockpit.myRepos;
    final c = widget.controller;
    final repo = widget.repo.fullName;
    return switch (clone.failure) {
      CloneFailure.auth => tr.failAuth(repo: repo),
      CloneFailure.targetExists => tr.failExists(
        path: displayPath(
          clone.targetPath,
          home: c.home,
          windows: c.os == HostOs.windows,
        ),
      ),
      CloneFailure.gitMissing => tr.failGit,
      CloneFailure.xcodeToolsMissing => tr.failXcode,
      CloneFailure.sshMissing => tr.failSsh,
      CloneFailure.hostKey => tr.failHostKey,
      null => tr.failGeneric(repo: repo),
    };
  }

  String _phaseText(BuildContext context, CloneProgress? progress) {
    final tr = context.t.cockpit.myRepos;
    if (progress == null) return tr.phaseStarting;
    final phase = switch (progress.phase) {
      ClonePhase.counting => tr.phaseCounting,
      ClonePhase.compressing => tr.phaseCompressing,
      ClonePhase.receiving => tr.phaseReceiving,
      ClonePhase.resolving => tr.phaseResolving,
      ClonePhase.updating => tr.phaseUpdating,
    };
    final size = progress.transferred;
    return size == null
        ? tr.progress(phase: phase, percent: progress.percent)
        : tr.progressSize(phase: phase, percent: progress.percent, size: size);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final c = widget.controller;
    final repo = widget.repo;
    final windows = c.os == HostOs.windows;
    final clone = c.cloneOf(repo);
    final cloning = clone?.running ?? false;
    final failed = clone?.failed ?? false;
    final clonedAt = c.clonedPath(repo);
    final meta = context.typo.label.copyWith(color: colors.text3);
    final updated = repo.updatedAt;

    final Widget action;
    if (cloning) {
      action = OutlineButton(
        key: const ValueKey('my-repos-cancel'),
        size: ButtonSize.small,
        onPressed: () => unawaited(c.cancelClone(repo)),
        child: Text(context.t.common.cancel),
      );
    } else if (failed) {
      action = PrimaryButton(
        key: const ValueKey('my-repos-retry'),
        size: ButtonSize.small,
        onPressed: c.anyCloneRunning ? null : widget.onRetry,
        leading: const Icon(Icons.refresh, size: 14),
        child: Text(tr.retry),
      );
    } else if (clonedAt != null) {
      action = OutlineButton(
        key: const ValueKey('my-repos-open'),
        size: ButtonSize.small,
        onPressed: () => widget.onOpen(clonedAt),
        leading: Icon(Icons.check, size: 14, color: colors.online),
        child: Text(tr.open),
      );
    } else {
      action = PrimaryButton(
        key: const ValueKey('my-repos-clone'),
        size: ButtonSize.small,
        onPressed: c.anyCloneRunning ? null : widget.onClone,
        leading: const Icon(Icons.download_outlined, size: 14),
        child: Text(tr.clone),
      );
    }

    return Container(
      color: cloning || failed ? colors.panel2 : null,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                repo.isPrivate ? Icons.lock_outline : Icons.book_outlined,
                size: 15,
                color: colors.text3,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: _name(context)),
                        if (repo.isPrivate) ...[
                          const SizedBox(width: 6),
                          _Badge(tr.private),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        repo.owner,
                        ?repo.description,
                        if (updated != null)
                          tr.updated(
                            ago: relativeAgo(context, updated, c.now()),
                          ),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: meta,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              action,
            ],
          ),
          if (clonedAt != null && !cloning && !failed)
            Padding(
              padding: const EdgeInsets.only(left: 25, top: 4),
              child: Text(
                tr.alreadyCloned(
                  path: displayPath(clonedAt, home: c.home, windows: windows),
                ),
                style: context.typo.mono.copyWith(
                  fontSize: 10.5,
                  color: colors.text3,
                ),
              ),
            ),
          if (failed && clone != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 25),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 14, color: colors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _failureText(context, clone),
                      key: const ValueKey('my-repos-row-error'),
                      style: context.typo.label.copyWith(color: colors.error),
                    ),
                  ),
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: () => setState(() => _details = !_details),
                    child: Text(_details ? tr.hideDetails : tr.details),
                  ),
                ],
              ),
            ),
            if (_details)
              Container(
                margin: const EdgeInsets.only(left: 25, top: 4),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(
                  color: colors.panel3,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    clone.output.join('\n'),
                    style: context.typo.mono.copyWith(
                      fontSize: 10.5,
                      color: colors.text2,
                    ),
                  ),
                ),
              )
            else if (clone.lastMessage case final last?)
              Padding(
                padding: const EdgeInsets.only(left: 25, top: 2),
                child: Text(
                  last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.typo.mono.copyWith(
                    fontSize: 10.5,
                    color: colors.text3,
                  ),
                ),
              ),
          ],
          if (cloning && clone != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 25),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: SizedBox(
                      height: 6,
                      child: Stack(
                        children: [
                          Container(color: colors.panel3),
                          FractionallySizedBox(
                            widthFactor: clone.progress?.overall ?? 0,
                            child: Container(color: colors.accent),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(_phaseText(context, clone.progress), style: meta),
                  const SizedBox(height: 2),
                  Text(
                    '\$ ${clone.command}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.typo.mono.copyWith(
                      fontSize: 10.5,
                      color: colors.text2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border2),
      ),
      child: Text(
        text,
        style: context.typo.label.copyWith(fontSize: 10, color: colors.text3),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Conectar serviço
// ---------------------------------------------------------------------------

class _ConnectPanel extends StatelessWidget {
  const _ConnectPanel({
    required this.controller,
    required this.onRunInTerminal,
    required this.onOpenUrl,
  });

  final MyReposController controller;
  final void Function(List<List<String>> commands, String title)
  onRunInTerminal;
  final void Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final c = controller;
    final root = c.cloneRoot ?? c.suggestedRoot;
    return Container(
      key: const ValueKey('my-repos-connect'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 18, color: colors.warn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.sources.isEmpty ? tr.noneTitle : tr.connectTitle,
                  style: context.typo.title.copyWith(color: colors.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr.connectIntro,
            style: context.typo.body.copyWith(color: colors.text2),
          ),
          const SizedBox(height: 6),
          for (final provider in c.catalog.providers)
            _ProviderRow(
              controller: c,
              kind: provider.kind,
              onRunInTerminal: onRunInTerminal,
              onOpenUrl: onOpenUrl,
            ),
          const SizedBox(height: 10),
          Text(
            tr.bitbucketNote,
            style: context.typo.label.copyWith(color: colors.text3),
          ),
          if (root != null) ...[
            const SizedBox(height: 4),
            Text(
              tr.clonesGoTo(
                path: displayPath(
                  root,
                  home: c.home,
                  windows: c.os == HostOs.windows,
                ),
              ),
              style: context.typo.label.copyWith(color: colors.text3),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              PrimaryButton(
                key: const ValueKey('my-repos-check-again'),
                size: ButtonSize.small,
                onPressed: () => unawaited(c.init()),
                leading: const Icon(Icons.refresh, size: 14),
                child: Text(tr.checkAgain),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  tr.pasteStillWorks,
                  style: context.typo.label.copyWith(color: colors.text3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.controller,
    required this.kind,
    required this.onRunInTerminal,
    required this.onOpenUrl,
  });

  final MyReposController controller;
  final GitHostingKind kind;
  final void Function(List<List<String>> commands, String title)
  onRunInTerminal;
  final void Function(String url) onOpenUrl;

  Future<void> _install(BuildContext context) async {
    final provider = controller.catalog.providers.firstWhere(
      (p) => p.kind == kind,
    );
    final command = provider.installHint().command;
    if (command == null) return;
    final title = context.t.cockpit.myRepos.terminalInstall(
      cli: hostingCliName(kind),
    );
    // Caminho absoluto do brew/winget: o shell da aba pode não ter o
    // Homebrew no PATH (perfil sem `brew shellenv`).
    final program =
        await controller.catalog.locate(command.program) ?? command.program;
    onRunInTerminal([
      [program, ...command.args],
    ], title);
  }

  void _connect(BuildContext context) {
    final provider = controller.catalog.providers.firstWhere(
      (p) => p.kind == kind,
    );
    // Caminho absoluto da CLI: no Windows o PowerShell da aba herda o PATH do
    // app, que não tem a CLI recém-instalada pelo winget.
    final cli = controller.statusOf(kind)?.cliPath;
    onRunInTerminal([
      for (final command in provider.connectCommands())
        [
          if (command.program == provider.cliName && cli != null)
            cli
          else
            command.program,
          ...command.args,
        ],
    ], context.t.cockpit.myRepos.terminalConnect(provider: hostingName(kind)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final c = controller;
    final provider = c.catalog.providers.firstWhere((p) => p.kind == kind);
    final status = c.statusOf(kind);
    final state = status?.state ?? ProviderState.cliMissing;
    final hint = provider.installHint();
    final canInstallHere =
        hint.command != null && (c.os != HostOs.macos || c.hasBrew);
    final cli = provider.cliName;

    final String stateText;
    final String? commandText;
    final Widget? action;
    switch (state) {
      case ProviderState.cliMissing:
        stateText = tr.stateMissing(cli: cli);
        commandText = canInstallHere ? hint.command!.display : hint.url;
        action = canInstallHere
            ? PrimaryButton(
                key: ValueKey('my-repos-install-${kind.name}'),
                size: ButtonSize.small,
                onPressed: () => unawaited(_install(context)),
                leading: const Icon(Icons.download_outlined, size: 14),
                child: Text(tr.install),
              )
            : OutlineButton(
                key: ValueKey('my-repos-download-${kind.name}'),
                size: ButtonSize.small,
                onPressed: () => onOpenUrl(hint.url),
                leading: const Icon(Icons.open_in_new, size: 14),
                child: Text(tr.getAt),
              );
      case ProviderState.signedOut:
        stateText = tr.stateSignedOut(cli: cli);
        commandText = provider
            .connectCommands()
            .map((c) => c.display)
            .join('; ');
        action = PrimaryButton(
          key: ValueKey('my-repos-connect-${kind.name}'),
          size: ButtonSize.small,
          onPressed: () => _connect(context),
          leading: const Icon(Icons.login, size: 14),
          child: Text(tr.connect),
        );
      case ProviderState.ready:
        stateText = tr.stateReady(
          login: status!.accounts.map((a) => a.login).join(', '),
        );
        commandText = null;
        action = null;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(hostingIcon(kind), size: 16, color: colors.text2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      hostingName(kind),
                      style: context.typo.body.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (state == ProviderState.ready)
                      Icon(Icons.check_circle, size: 12, color: colors.online),
                    if (state == ProviderState.ready) const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        stateText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.label.copyWith(color: colors.text3),
                      ),
                    ),
                  ],
                ),
                if (commandText != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.panel3,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      commandText,
                      style: context.typo.mono.copyWith(
                        fontSize: 11.5,
                        color: colors.text,
                      ),
                    ),
                  ),
                ],
                if (state == ProviderState.cliMissing &&
                    hint.command != null &&
                    !canInstallHere) ...[
                  const SizedBox(height: 4),
                  Text(
                    tr.noBrew(cli: hostingCliName(kind)),
                    style: context.typo.label.copyWith(color: colors.text3),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 10), action],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Primeiro uso: onde clonar
// ---------------------------------------------------------------------------

/// Pergunta a pasta padrão dos clones (só no primeiro clone em um clique).
/// [suggested] é `~/Projetos` resolvido pra plataforma; [pickFolder] abre o
/// seletor nativo. Devolve a pasta escolhida, ou `null` se cancelou.
Future<String?> showCloneRootDialog(
  BuildContext context, {
  required String? suggested,
  required String Function(String path) display,
  required String commandExample,
  required Future<String?> Function(String? initial) pickFolder,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: context.colors.scrim,
    builder: (_) => _CloneRootDialog(
      suggested: suggested,
      display: display,
      commandExample: commandExample,
      pickFolder: pickFolder,
    ),
  );
}

class _CloneRootDialog extends StatefulWidget {
  const _CloneRootDialog({
    required this.suggested,
    required this.display,
    required this.commandExample,
    required this.pickFolder,
  });

  final String? suggested;
  final String Function(String path) display;
  final String commandExample;
  final Future<String?> Function(String? initial) pickFolder;

  @override
  State<_CloneRootDialog> createState() => _CloneRootDialogState();
}

class _CloneRootDialogState extends State<_CloneRootDialog> {
  late String? _chosen = widget.suggested;

  Future<void> _pick() async {
    final picked = await widget.pickFolder(_chosen);
    if (picked == null || !mounted) return;
    setState(() => _chosen = picked);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.myRepos;
    final chosen = _chosen;
    return AlertDialog(
      title: Text(
        tr.firstFolderTitle,
        style: context.typo.title.copyWith(fontSize: 15, color: colors.text),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr.firstFolderBody(command: widget.commandExample),
              style: context.typo.body.copyWith(color: colors.text2),
            ),
            if (chosen != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.accent),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.radio_button_checked,
                      size: 16,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.folder_outlined, size: 16, color: colors.text2),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.display(chosen),
                        key: const ValueKey('clone-root-chosen'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.typo.mono.copyWith(
                          fontSize: 13,
                          color: colors.text,
                        ),
                      ),
                    ),
                    if (chosen == widget.suggested) ...[
                      const SizedBox(width: 8),
                      Text(
                        tr.suggested,
                        style: context.typo.label.copyWith(
                          color: colors.accentText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlineButton(
              key: const ValueKey('clone-root-pick'),
              size: ButtonSize.small,
              onPressed: _pick,
              leading: const Icon(Icons.drive_folder_upload_outlined, size: 14),
              child: Text(tr.chooseOther),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.info_outline, size: 13, color: colors.text3),
                const SizedBox(width: 6),
                Text(
                  tr.changeLater,
                  style: context.typo.label.copyWith(color: colors.text3),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        OutlineButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.common.cancel),
        ),
        PrimaryButton(
          key: const ValueKey('clone-root-confirm'),
          onPressed: chosen == null
              ? null
              : () => Navigator.of(context).pop(chosen),
          child: Text(
            tr.useAndClone(path: chosen == null ? '…' : widget.display(chosen)),
          ),
        ),
      ],
    );
  }
}
