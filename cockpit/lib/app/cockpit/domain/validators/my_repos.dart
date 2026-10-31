import 'package:path/path.dart' as p;

/// Regras puras da aba "Meus repositórios" (issue #278): pasta padrão dos
/// clones, leitura do progresso do `git clone` e a linha de comando digitada
/// na aba de terminal. Plataforma injetável, sem tocar disco nem processo.

/// Nome da pasta padrão sugerida no primeiro uso.
const kDefaultCloneFolderName = 'Projetos';

/// Pasta sugerida pros clones: `~/Projetos` no macOS,
/// `%USERPROFILE%\Projetos` no Windows. [home] vem de `userHome()`; `null`
/// quando o ambiente não tem home (aí o usuário escolhe a pasta).
String? defaultCloneRoot(String? home, {p.Context? context}) {
  if (home == null || home.trim().isEmpty) return null;
  return (context ?? p.context).join(home.trim(), kDefaultCloneFolderName);
}

/// [path] encurtado com `~` quando está dentro de [home] (só POSIX; no
/// Windows o caminho fica inteiro, como o Explorer mostra).
String displayPath(String path, {String? home, bool windows = false}) {
  if (windows || home == null || home.isEmpty) return path;
  if (path == home) return '~';
  final prefix = home.endsWith('/') ? home : '$home/';
  return path.startsWith(prefix) ? '~/${path.substring(prefix.length)}' : path;
}

/// Fase do `git clone --progress`.
enum ClonePhase { counting, compressing, receiving, resolving, updating }

/// Uma linha de progresso do git, interpretada.
class CloneProgress {
  const CloneProgress({
    required this.phase,
    required this.percent,
    this.transferred,
  });

  final ClonePhase phase;

  /// 0–100 dentro da fase.
  final int percent;

  /// Volume já baixado (`38.20 MiB`), só em [ClonePhase.receiving].
  final String? transferred;

  /// Progresso total 0.0–1.0. O download domina o tempo do clone, então ele
  /// ocupa 0–80%; resolver deltas 80–95%; checkout 95–100%. As fases do
  /// servidor (contar/comprimir) ficam em 0.
  double get overall {
    final f = percent.clamp(0, 100) / 100;
    return switch (phase) {
      ClonePhase.counting || ClonePhase.compressing => 0,
      ClonePhase.receiving => f * 0.8,
      ClonePhase.resolving => 0.8 + f * 0.15,
      ClonePhase.updating => 0.95 + f * 0.05,
    };
  }
}

final _progressLine = RegExp(
  r'^(?:remote:\s*)?(Counting|Compressing|Receiving|Resolving|Updating)'
  r'\s+(?:objects|deltas|files):\s+(\d{1,3})%(.*)$',
);
final _transferred = RegExp(r',\s*([\d.]+\s*[KMGT]?i?B)\b');

/// Lê uma linha de saída do clone. `null` quando não é progresso.
CloneProgress? parseCloneProgress(String line) {
  final m = _progressLine.firstMatch(line.trim());
  if (m == null) return null;
  final phase = switch (m.group(1)!) {
    'Counting' => ClonePhase.counting,
    'Compressing' => ClonePhase.compressing,
    'Receiving' => ClonePhase.receiving,
    'Resolving' => ClonePhase.resolving,
    _ => ClonePhase.updating,
  };
  final size = phase == ClonePhase.receiving
      ? _transferred.firstMatch(m.group(3)!)?.group(1)
      : null;
  return CloneProgress(
    phase: phase,
    percent: int.parse(m.group(2)!),
    transferred: size,
  );
}

/// Shell da aba de terminal que roda os comandos de instalar/conectar.
enum TerminalShell { posix, powershell }

final _posixSafe = RegExp(r'^[A-Za-z0-9_./:=@%+,-]+$');

String _quotePosix(String arg) =>
    _posixSafe.hasMatch(arg) ? arg : "'${arg.replaceAll("'", r"'\''")}'";

String _quotePowerShell(String arg) =>
    _posixSafe.hasMatch(arg) ? arg : "'${arg.replaceAll("'", "''")}'";

/// Uma linha de comando ([argv] = programa + argumentos) escrita pro [shell].
/// No PowerShell, programa com aspas (caminho com espaço, como
/// `C:\Program Files\GitHub CLI\gh.exe`) precisa do operador `&`.
String shellCommand(List<String> argv, TerminalShell shell) {
  if (argv.isEmpty) return '';
  final quote = shell == TerminalShell.powershell
      ? _quotePowerShell
      : _quotePosix;
  final program = quote(argv.first);
  final head = shell == TerminalShell.powershell && program != argv.first
      ? '& $program'
      : program;
  return [head, ...argv.skip(1).map(quote)].join(' ');
}

/// Vários comandos numa linha só, em sequência, e o shell sai no fim — a saída
/// do shell é o sinal de "terminou" que faz a lista recarregar. `;` serve no
/// zsh/bash/fish e no PowerShell 5 (que não tem `&&`).
String terminalScript(List<List<String>> commands, TerminalShell shell) =>
    [for (final c in commands) shellCommand(c, shell), 'exit'].join('; ');
