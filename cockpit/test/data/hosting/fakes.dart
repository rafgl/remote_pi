import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';

/// [CliRunner] com respostas gravadas: a chave é `args.join(' ')`, e a
/// primeira chave que for prefixo dos args responde. Guarda as chamadas.
class FakeCliRunner implements CliRunner {
  FakeCliRunner(this.responses);

  final Map<String, CliResult> responses;
  final calls = <({String exe, List<String> args, Map<String, String> env})>[];

  @override
  Future<CliResult> run(
    String executable,
    List<String> args, {
    Map<String, String> env = const {},
  }) async {
    calls.add((exe: executable, args: args, env: env));
    final line = args.join(' ');
    for (final e in responses.entries) {
      if (line == e.key || line.startsWith('${e.key} ')) return e.value;
    }
    return const CliResult(1, '', 'unexpected call');
  }
}

CliResult ok(String stdout) => CliResult(0, stdout, '');
CliResult err(String stderr, {String stdout = ''}) =>
    CliResult(1, stdout, stderr);

/// Locator que só "acha" os caminhos de [present].
CliLocator locatorWith(
  Set<String> present, {
  HostOs os = HostOs.macos,
  Map<String, String> env = const {'PATH': '/usr/bin:/bin'},
}) => CliLocator(
  environment: env,
  os: os,
  exists: (path) async => present.contains(path),
);

/// Ambiente típico de um Windows 11 com Program Files e LocalAppData.
const windowsEnv = <String, String>{
  'Path': r'C:\Windows\system32;C:\Windows',
  'ProgramFiles': r'C:\Program Files',
  'ProgramFiles(x86)': r'C:\Program Files (x86)',
  'LOCALAPPDATA': r'C:\Users\rafgl\AppData\Local',
  'USERPROFILE': r'C:\Users\rafgl',
};
