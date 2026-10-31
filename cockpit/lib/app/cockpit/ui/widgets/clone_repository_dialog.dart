import 'dart:io';

import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/cockpit/domain/validators/clone_destination.dart';
import 'package:cockpit/app/cockpit/domain/validators/git_clone_url.dart';
import 'package:cockpit/app/cockpit/domain/validators/my_repos.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/my_repos_controller.dart';
import 'package:cockpit/app/cockpit/ui/widgets/my_repos_pane.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/utils/native_folder_picker.dart';
import 'package:cockpit/i18n/strings.g.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// O que o dialog "Clonar repositório" devolve: a URL e o caminho final do
/// clone (pasta de destino + nome da pasta).
typedef CloneRequest = ({String url, String targetPath});

/// O que fechou o dialog "Clonar repositório".
sealed class CloneDialogResult {
  const CloneDialogResult();
}

/// "Colar URL": a action roda o `git clone` no dialog de processo.
final class CloneFromUrl extends CloneDialogResult {
  const CloneFromUrl(this.request);

  final CloneRequest request;
}

/// "Meus repositórios": o clone em um clique terminou em [path].
final class ClonedRepo extends CloneDialogResult {
  const ClonedRepo(this.repo, this.path);

  final RemoteRepo repo;
  final String path;
}

/// "Meus repositórios": "Abrir" de um repo que já estava na pasta padrão.
final class OpenClonedRepo extends CloneDialogResult {
  const OpenClonedRepo(this.repo, this.path);

  final RemoteRepo repo;
  final String path;
}

/// "Instalar"/"Conectar": rodar [commands] numa aba de terminal e reabrir o
/// dialog em "Meus repositórios" quando o shell sair.
final class RunInTerminal extends CloneDialogResult {
  const RunInTerminal(this.commands, this.title);

  final List<List<String>> commands;
  final String title;
}

/// Abas do dialog.
enum CloneDialogTab { pasteUrl, myRepos }

/// Dialog "Clonar repositório" (menu do "+" da rail), com duas abas:
///
/// - **Colar URL**: URL SSH/HTTPS, pasta de destino (picker nativo) e nome da
///   pasta, derivado da URL até o usuário editar. Só valida; o clone roda
///   depois, no dialog de processo git. Aceita qualquer servidor Git.
/// - **Meus repositórios** (issue #278, só com [myRepos]): repos das CLIs
///   logadas (`gh`, `glab`, `az`, `tea`), clone em um clique na pasta padrão.
///
/// [initialParent] é onde o picker começa e o destino pré-preenchido.
/// [clipboardText] existe pra teste; por padrão lê o clipboard do sistema e,
/// se houver uma URL git lá, já entra preenchida (e a aba Colar URL abre).
/// [initialTab] força a aba inicial (o retorno do terminal reabre em Meus
/// repositórios). [onCloneRootChosen] grava a pasta padrão nas Configurações;
/// [pickFolder] e [onOpenUrl] existem pra teste.
Future<CloneDialogResult?> showCloneRepositoryDialog(
  BuildContext context, {
  required String initialParent,
  Future<String?> Function()? clipboardText,
  MyReposController? myRepos,
  CloneDialogTab? initialTab,
  void Function(String path)? onCloneRootChosen,
  Future<String?> Function(String? initial)? pickFolder,
  void Function(String url)? onOpenUrl,
}) {
  return showDialog<CloneDialogResult>(
    context: context,
    barrierColor: context.colors.scrim,
    builder: (context) => _CloneRepositoryDialog(
      initialParent: initialParent,
      clipboardText: clipboardText ?? _systemClipboard,
      myRepos: myRepos,
      initialTab: initialTab,
      onCloneRootChosen: onCloneRootChosen ?? (_) {},
      pickFolder: pickFolder,
      onOpenUrl: onOpenUrl ?? (_) {},
    ),
  );
}

Future<String?> _systemClipboard() async =>
    (await Clipboard.getData(Clipboard.kTextPlain))?.text;

class _CloneRepositoryDialog extends StatefulWidget {
  const _CloneRepositoryDialog({
    required this.initialParent,
    required this.clipboardText,
    required this.myRepos,
    required this.initialTab,
    required this.onCloneRootChosen,
    required this.pickFolder,
    required this.onOpenUrl,
  });

  final String initialParent;
  final Future<String?> Function() clipboardText;
  final MyReposController? myRepos;
  final CloneDialogTab? initialTab;
  final void Function(String path) onCloneRootChosen;
  final Future<String?> Function(String? initial)? pickFolder;
  final void Function(String url) onOpenUrl;

  @override
  State<_CloneRepositoryDialog> createState() => _CloneRepositoryDialogState();
}

class _CloneRepositoryDialogState extends State<_CloneRepositoryDialog> {
  final _url = TextEditingController();
  final _folder = TextEditingController();
  late String _parent = widget.initialParent;

  /// `true` quando o usuário mexeu no nome da pasta: aí a URL para de
  /// sobrescrevê-lo.
  bool _folderEdited = false;

  /// `true` depois de um submit inválido — só então os erros aparecem.
  bool _attempted = false;

  /// Sem [MyReposController] só existe Colar URL. Com ele, abre em Meus
  /// repositórios, salvo URL git no clipboard (aí Colar URL, já preenchida).
  late CloneDialogTab _tab =
      widget.initialTab ??
      (widget.myRepos == null
          ? CloneDialogTab.pasteUrl
          : CloneDialogTab.myRepos);

  /// O usuário trocou de aba: o clipboard não muda mais a aba dele.
  bool _tabTouched = false;

  @override
  void initState() {
    super.initState();
    _prefillFromClipboard();
  }

  @override
  void dispose() {
    _url.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _prefillFromClipboard() async {
    final text = (await widget.clipboardText())?.trim();
    if (!mounted || text == null || _url.text.isNotEmpty) return;
    if (!isGitCloneUrl(text)) return;
    _setUrl(text);
    if (!_tabTouched && widget.initialTab == null) {
      setState(() => _tab = CloneDialogTab.pasteUrl);
    }
  }

  void _selectTab(CloneDialogTab tab) => setState(() {
    _tab = tab;
    _tabTouched = true;
  });

  Future<String?> _pickFolder(String? initial, String title) async {
    final injected = widget.pickFolder;
    if (injected != null) return injected(initial);
    return NativeFolderPicker.pick(
      dialogTitle: title,
      initialDirectory: initial,
    );
  }

  String _displayPath(MyReposController c, String path) =>
      displayPath(path, home: c.home, windows: c.os == HostOs.windows);

  /// Primeiro clone em um clique sem pasta padrão: pergunta (com `~/Projetos`
  /// sugerida) e grava nas Configurações.
  Future<bool> _ensureCloneRoot() async {
    final c = widget.myRepos!;
    if (c.cloneRoot != null) return true;
    final title = context.t.cockpit.myRepos.chooseRootTitle;
    final chosen = await showCloneRootDialog(
      context,
      suggested: c.suggestedRoot,
      display: (path) => _displayPath(c, path),
      commandExample: cloneCommandExample(
        c.selected?.provider.kind ?? GitHostingKind.github,
      ),
      pickFolder: (initial) => _pickFolder(initial, title),
    );
    if (chosen == null || !mounted) return false;
    c.setCloneRoot(chosen);
    widget.onCloneRootChosen(chosen);
    return true;
  }

  Future<void> _changeCloneRoot() async {
    final c = widget.myRepos!;
    final picked = await _pickFolder(
      c.cloneRoot ?? c.suggestedRoot,
      context.t.cockpit.myRepos.chooseRootTitle,
    );
    if (picked == null || !mounted) return;
    c.setCloneRoot(picked);
    widget.onCloneRootChosen(picked);
  }

  Future<void> _paste() async {
    final text = (await widget.clipboardText())?.trim();
    if (!mounted || text == null || text.isEmpty) return;
    _setUrl(text);
  }

  void _setUrl(String text) {
    _url.text = text;
    _onUrlChanged(text);
  }

  void _onUrlChanged(String value) {
    if (!_folderEdited) _folder.text = repoNameFromGitUrl(value) ?? '';
    setState(() {});
  }

  Future<void> _pickParent() async {
    final picked = await NativeFolderPicker.pick(
      dialogTitle: context.t.cockpit.cloneRepoDialog.chooseParentDialogTitle,
      initialDirectory: _parent,
    );
    if (picked == null || !mounted) return;
    setState(() => _parent = picked);
  }

  String get _urlTrimmed => _url.text.trim();
  String get _folderTrimmed => _folder.text.trim();
  String get _targetPath => cloneTargetPath(_parent, _folderTrimmed);

  bool get _urlInvalid => !isGitCloneUrl(_urlTrimmed);
  bool get _parentInvalid =>
      _parent.isEmpty || !Directory(_parent).existsSync();
  CloneFolderError? get _folderError =>
      validateCloneFolderName(_folder.text, windows: Platform.isWindows);
  bool get _folderInvalid => _folderError != null;

  String _folderErrorText(BuildContext context, CloneFolderError error) {
    final tr = context.t.cockpit.cloneRepoDialog;
    return switch (error) {
      CloneFolderError.empty ||
      CloneFolderError.dotName ||
      CloneFolderError.separator => tr.errFolder,
      CloneFolderError.invalidChar => tr.errFolderChars,
      CloneFolderError.reserved => tr.errFolderReserved(name: _folderTrimmed),
      CloneFolderError.trailingDotOrSpace => tr.errFolderTrailing,
    };
  }

  /// O git só clona numa pasta inexistente ou vazia.
  bool get _targetTaken {
    if (_parentInvalid || _folderInvalid) return false;
    final type = FileSystemEntity.typeSync(_targetPath);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory) return true;
    return Directory(_targetPath).listSync().isNotEmpty;
  }

  void _submit() {
    if (_urlInvalid || _parentInvalid || _folderInvalid || _targetTaken) {
      setState(() => _attempted = true);
      return;
    }
    Navigator.of(context).pop<CloneDialogResult>(
      CloneFromUrl((url: _urlTrimmed, targetPath: _targetPath)),
    );
  }

  void _close(CloneDialogResult result) =>
      Navigator.of(context).pop<CloneDialogResult>(result);

  /// "Colar URL" | "Meus repositórios" — chips no estilo do seletor de auth do
  /// dialog de host remoto.
  Widget _tabs(BuildContext context) {
    final tr = context.t.cockpit.myRepos;
    Widget tab(CloneDialogTab value, IconData icon, String label) {
      final leading = Icon(icon, size: 14);
      final key = ValueKey('clone-tab-${value.name}');
      return _tab == value
          ? PrimaryButton(
              key: key,
              size: ButtonSize.small,
              onPressed: () => _selectTab(value),
              leading: leading,
              child: Text(label),
            )
          : OutlineButton(
              key: key,
              size: ButtonSize.small,
              onPressed: () => _selectTab(value),
              leading: leading,
              child: Text(label),
            );
    }

    return Row(
      children: [
        tab(CloneDialogTab.pasteUrl, Icons.link, tr.tabPasteUrl),
        const SizedBox(width: 8),
        tab(CloneDialogTab.myRepos, Icons.inventory_2_outlined, tr.tabMyRepos),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: context.typo.label.copyWith(color: context.colors.text2),
    ),
  );

  Widget _errorText(BuildContext context, String message) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      message,
      style: context.typo.label.copyWith(
        fontSize: 11,
        color: context.colors.error,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.cloneRepoDialog;
    final myRepos = widget.myRepos;
    final showMyRepos = myRepos != null && _tab == CloneDialogTab.myRepos;
    return AlertDialog(
      title: Text(
        tr.title,
        style: context.typo.title.copyWith(fontSize: 15, color: colors.text),
      ),
      content: SizedBox(
        width: myRepos == null ? 460 : 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (myRepos != null) ...[
              _tabs(context),
              const SizedBox(height: 14),
            ],
            if (showMyRepos)
              MyReposPane(
                controller: myRepos,
                ensureCloneRoot: _ensureCloneRoot,
                onChangeCloneRoot: _changeCloneRoot,
                onCloned: (repo, path) => _close(ClonedRepo(repo, path)),
                onOpen: (repo, path) => _close(OpenClonedRepo(repo, path)),
                onRunInTerminal: (commands, title) =>
                    _close(RunInTerminal(commands, title)),
                onOpenUrl: widget.onOpenUrl,
              )
            else
              ..._pasteUrlFields(context),
          ],
        ),
      ),
      actions: showMyRepos
          ? [
              OutlineButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.t.common.close),
              ),
            ]
          : [
              OutlineButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.t.common.cancel),
              ),
              PrimaryButton(onPressed: _submit, child: Text(tr.cloneAction)),
            ],
    );
  }

  List<Widget> _pasteUrlFields(BuildContext context) {
    final colors = context.colors;
    final tr = context.t.cockpit.cloneRepoDialog;
    return [
      _label(context, tr.urlLabel),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('clone-url'),
              controller: _url,
              autofocus: true,
              placeholder: Text(tr.urlPlaceholder),
              style: context.typo.mono.copyWith(fontSize: 12),
              onChanged: _onUrlChanged,
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(width: 8),
          OutlineButton(
            size: ButtonSize.small,
            onPressed: _paste,
            child: Text(tr.paste),
          ),
        ],
      ),
      if (_attempted && _urlInvalid) _errorText(context, tr.errUrl),
      const SizedBox(height: 12),
      _label(context, tr.parentLabel),
      Row(
        children: [
          Expanded(
            child: Text(
              _parent,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typo.mono.copyWith(
                fontSize: 11,
                color: colors.text2,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlineButton(
            size: ButtonSize.small,
            onPressed: _pickParent,
            child: Text(tr.choose),
          ),
        ],
      ),
      if (_attempted && _parentInvalid) _errorText(context, tr.errParent),
      const SizedBox(height: 12),
      _label(context, tr.folderLabel),
      TextField(
        key: const ValueKey('clone-folder'),
        controller: _folder,
        onChanged: (_) => setState(() => _folderEdited = true),
        onSubmitted: (_) => _submit(),
      ),
      if (_attempted && _folderError != null)
        _errorText(context, _folderErrorText(context, _folderError!)),
      if (_attempted && _targetTaken)
        _errorText(context, tr.errExists(path: _targetPath)),
      if (!_folderInvalid && !_parentInvalid) ...[
        const SizedBox(height: 10),
        Text(
          tr.targetPreview(path: _targetPath),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.typo.mono.copyWith(fontSize: 11, color: colors.text3),
        ),
      ],
    ];
  }
}
