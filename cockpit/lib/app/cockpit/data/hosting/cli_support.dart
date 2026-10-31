import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/data/setup/remote_pi_resolver.dart';
import 'package:path/path.dart' as p;

/// Lê [key] de um ambiente. No Windows o nome da variável não diferencia
/// maiúsculas (`Path`, `PATH`, `ProgramFiles`); um mapa injetado em teste
/// diferencia, então procura ignorando o caso.
String? envValue(Map<String, String> env, String key) {
  final direct = env[key];
  if (direct != null) return direct;
  final upper = key.toUpperCase();
  for (final e in env.entries) {
    if (e.key.toUpperCase() == upper) return e.value;
  }
  return null;
}

/// Acha executáveis de CLI fora do PATH do app.
///
/// App GUI não herda o PATH do shell: aberto pelo Finder/Dock, o macOS dá só
/// `/usr/bin:/bin:/usr/sbin:/sbin`, sem o Homebrew do Apple Silicon
/// (`/opt/homebrew/bin`) nem o do Intel (`/usr/local/bin`). No Windows o PATH
/// do processo é o do momento em que o app abriu: um `winget install` feito
/// depois não aparece nele. Por isso, além do PATH, procura nas pastas de
/// instalação conhecidas de cada sistema.
///
/// [environment], [os] e [exists] existem pra teste; por padrão vêm do
/// processo e do disco. Nada é cacheado: depois de "Instalar" a mesma
/// instância precisa achar o binário novo.
class CliLocator {
  CliLocator({this._environment, this._os, this._exists});

  final Map<String, String>? _environment;
  final HostOs? _os;
  final Future<bool> Function(String path)? _exists;

  Map<String, String> get environment => _environment ?? Platform.environment;

  HostOs get os =>
      _os ??
      (Platform.isWindows
          ? HostOs.windows
          : Platform.isMacOS
          ? HostOs.macos
          : HostOs.linux);

  bool get isWindows => os == HostOs.windows;

  p.Context get pathContext => isWindows ? p.windows : p.posix;

  /// Pastas de binário conhecidas, além do PATH, em ordem de tentativa.
  List<String> commonDirs() {
    final env = environment;
    if (isWindows) {
      final local = envValue(env, 'LOCALAPPDATA');
      final profile = envValue(env, 'USERPROFILE');
      final scoop = envValue(env, 'SCOOP');
      final programData = envValue(env, 'ProgramData');
      return [
        // winget: pacotes "portable" (tea, glab em versões novas) ganham um
        // link aqui.
        if (local != null && local.isNotEmpty)
          p.windows.join(local, 'Microsoft', 'WinGet', 'Links'),
        if (scoop != null && scoop.isNotEmpty) p.windows.join(scoop, 'shims'),
        if (profile != null && profile.isNotEmpty)
          p.windows.join(profile, 'scoop', 'shims'),
        if (programData != null && programData.isNotEmpty)
          p.windows.join(programData, 'chocolatey', 'bin'),
      ];
    }
    final home = envValue(env, 'HOME');
    return [
      '/opt/homebrew/bin', // Homebrew no Apple Silicon
      '/usr/local/bin', // Homebrew no Intel (e instaladores .pkg)
      '/opt/local/bin', // MacPorts
      if (home != null && home.isNotEmpty) ...[
        p.posix.join(home, '.local', 'bin'),
        p.posix.join(home, 'go', 'bin'), // `go install` (tea)
      ],
      '/usr/bin',
    ];
  }

  /// Pastas de `Program Files` (máquina, 64 e 32 bits) e de programas do
  /// usuário, pra montar o caminho de instaladores MSI/EXE.
  List<String> windowsProgramDirs() {
    final env = environment;
    final seen = <String>{};
    return [
      for (final key in ['ProgramFiles', 'ProgramW6432', 'ProgramFiles(x86)'])
        if (envValue(env, key) case final v? when v.isNotEmpty && seen.add(v))
          v,
      if (envValue(env, 'LOCALAPPDATA') case final v? when v.isNotEmpty)
        p.windows.join(v, 'Programs'),
    ];
  }

  /// Caminho absoluto de [name], ou `null`. Procura no PATH, depois em
  /// [extraDirs] (pastas próprias da CLI) e nas [commonDirs]. No Windows
  /// tenta `.exe`, `.cmd` e `.bat` (o `az` é um `az.cmd`).
  Future<String?> locate(
    String name, {
    List<String> extraDirs = const [],
  }) async {
    final ctx = pathContext;
    final exists = _exists ?? (String path) => File(path).exists();
    final rawPath = envValue(environment, 'PATH') ?? '';
    final pathDirs = rawPath
        .split(isWindows ? ';' : ':')
        .map((d) => d.trim().replaceAll('"', ''))
        .where((d) => d.isNotEmpty);
    final names = isWindows
        ? [
            for (final ext in const ['.exe', '.cmd', '.bat']) '$name$ext',
          ]
        : [name];
    final seen = <String>{};
    for (final dir in [...pathDirs, ...extraDirs, ...commonDirs()]) {
      if (!seen.add(isWindows ? dir.toLowerCase() : dir)) continue;
      for (final n in names) {
        final candidate = ctx.join(dir, n);
        if (await exists(candidate)) return candidate;
      }
    }
    return null;
  }
}

/// Resultado de uma chamada de CLI.
class CliResult {
  const CliResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// stderr, ou stdout quando o stderr veio vazio, sem espaços nas pontas.
  String get message {
    final err = stderr.trim();
    return err.isNotEmpty ? err : stdout.trim();
  }
}

/// Roda uma CLI e devolve a saída inteira. Contrato próprio pra os provedores
/// serem testados com saída gravada, sem processo de verdade.
abstract class CliRunner {
  Future<CliResult> run(
    String executable,
    List<String> args, {
    Map<String, String> env = const {},
  });
}

/// Variáveis que deixam as CLIs não interativas e sem cor: o app não tem TTY,
/// e um prompt deixaria o processo pendurado.
const kQuietCliEnv = <String, String>{
  'GH_PROMPT_DISABLED': '1',
  'GH_NO_UPDATE_NOTIFIER': '1',
  'GLAB_NO_PROMPT': '1',
  'NO_PROMPT': '1',
  'NO_COLOR': '1',
  'CLICOLOR': '0',
  'AZURE_CORE_NO_COLOR': '1',
  'AZURE_CORE_ONLY_SHOW_ERRORS': '1',
  'AZURE_CORE_COLLECT_TELEMETRY': '0',
  'GIT_TERMINAL_PROMPT': '0',
};

/// Ambiente do processo da CLI: o do app (com o `node` no PATH, como os outros
/// spawns), o PATH acrescido da pasta do próprio executável e de [extraPath]
/// (a do `git`: `gh repo clone` chama o `git` pelo PATH), e [kQuietCliEnv].
Map<String, String> cliEnvironment(
  Map<String, String> base, {
  required String executable,
  required bool windows,
  List<String> extraPath = const [],
  Map<String, String> extra = const {},
}) {
  final env = Map<String, String>.of(base);
  final ctx = windows ? p.windows : p.posix;
  final sep = windows ? ';' : ':';
  final pathKey = windows
      ? env.keys.firstWhere(
          (k) => k.toUpperCase() == 'PATH',
          orElse: () => 'Path',
        )
      : 'PATH';
  final dirs = <String>[
    if (ctx.isAbsolute(executable)) ctx.dirname(executable),
    for (final e in extraPath)
      if (ctx.isAbsolute(e)) ctx.dirname(e),
  ];
  final current = env[pathKey] ?? '';
  final parts = current.split(sep).where((d) => d.isNotEmpty).toList();
  for (final d in dirs.reversed) {
    if (!parts.contains(d)) parts.insert(0, d);
  }
  env[pathKey] = parts.join(sep);
  env.addAll(kQuietCliEnv);
  env.addAll(extra);
  return env;
}

/// `true` quando o Windows só executa [executable] via `cmd.exe` (`.cmd`,
/// `.bat`). Os argumentos que passam por aí não podem ter `& | < > ^ %`; os
/// provedores montam os deles sem esses caracteres.
bool needsShell(String executable) {
  final lower = executable.toLowerCase();
  return lower.endsWith('.cmd') || lower.endsWith('.bat');
}

/// [CliRunner] de verdade, com `Process.run` e timeout.
class ProcessCliRunner implements CliRunner {
  ProcessCliRunner({this.timeout = const Duration(seconds: 90)});

  final Duration timeout;

  @override
  Future<CliResult> run(
    String executable,
    List<String> args, {
    Map<String, String> env = const {},
  }) async {
    final windows = Platform.isWindows;
    try {
      final environment = cliEnvironment(
        await envWithNodeOnPath(),
        executable: executable,
        windows: windows,
        extra: env,
      );
      final res = await Process.run(
        executable,
        args,
        environment: environment,
        runInShell: windows && needsShell(executable),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      return CliResult(
        res.exitCode,
        res.stdout as String? ?? '',
        res.stderr as String? ?? '',
      );
    } on TimeoutException {
      return CliResult(
        -1,
        '',
        '$executable timed out after ${timeout.inSeconds}s',
      );
    } on ProcessException catch (e) {
      return CliResult(-1, '', 'Failed to run $executable: ${e.message}');
    }
  }
}

/// `jsonDecode` que devolve `null` em vez de lançar. Algumas CLIs imprimem
/// aviso antes do JSON (`az` com extensão desatualizada), então tenta também a
/// partir do primeiro `[` ou `{`.
Object? tryDecodeJson(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    final start = text.indexOf(RegExp(r'[\[{]'));
    if (start <= 0) return null;
    try {
      return jsonDecode(text.substring(start));
    } on FormatException {
      return null;
    }
  }
}

/// Mensagem de erro da CLI indica falta de login?
bool looksSignedOut(String message) {
  final m = message.toLowerCase();
  return m.contains('auth login') ||
      m.contains('not logged') ||
      m.contains('az login') ||
      m.contains('login add') ||
      m.contains('no login') ||
      m.contains('401 unauthorized') ||
      m.contains('authentication required') ||
      m.contains('has not been authenticated');
}
