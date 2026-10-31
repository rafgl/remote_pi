import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/filesystem/git_binary.dart';
import 'package:cockpit/app/cockpit/data/filesystem/git_command_runner_impl.dart'
    show GitProgressThrottle, cloneProcessEnvironment;
import 'package:cockpit/app/cockpit/data/hosting/azure_devops_provider.dart';
import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/data/hosting/gitea_provider.dart';
import 'package:cockpit/app/cockpit/data/hosting/github_provider.dart';
import 'package:cockpit/app/cockpit/data/hosting/gitlab_provider.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/data/setup/remote_pi_resolver.dart';

/// Catálogo dos serviços da aba "Meus repositórios" + o clone em si.
class GitHostingCatalogImpl implements GitHostingCatalog {
  GitHostingCatalogImpl(
    this._gitBinary, {
    CliLocator? locator,
    CliRunner? runner,
  }) : _locator = locator ?? CliLocator(),
       _runner = runner ?? ProcessCliRunner() {
    providers = [
      GitHubProvider(_locator, _runner),
      GitLabProvider(_locator, _runner),
      AzureDevOpsProvider(_locator, _runner),
      GiteaProvider(_locator, _runner),
    ];
  }

  final GitBinary _gitBinary;
  final CliLocator _locator;
  final CliRunner _runner;

  @override
  late final List<GitHostingProvider> providers;

  @override
  HostOs get os => _locator.os;

  @override
  Future<String?> locate(String program) => _locator.locate(program);

  @override
  CloneProcess clone(
    GitHostingProvider provider,
    RemoteRepo repo,
    String targetPath,
  ) {
    final controller = StreamController<String>();
    final exit = Completer<int>();
    final existedBefore = Directory(targetPath).existsSync();
    Process? process;
    var cancelled = false;

    void emit(String line) {
      if (!controller.isClosed) controller.add(line);
    }

    () async {
      try {
        final spec = provider.cloneSpec(repo, targetPath);
        final git = await _gitBinary.resolve();
        final List<String> argv;
        final Map<String, String> extraEnv;
        switch (spec) {
          case CliCloneSpec(:final command):
            final exe = await _locator.locate(command.program);
            if (exe == null) {
              emit('Failed to run ${command.program}: not found');
              exit.complete(-1);
              return;
            }
            argv = [exe, ...command.args];
            extraEnv = command.env;
          case GitUrlCloneSpec(:final url):
            argv = [git, 'clone', '--progress', '--', url, targetPath];
            extraEnv = const {};
        }
        final parent = Directory(targetPath).parent;
        await parent.create(recursive: true);
        final env = cloneProcessEnvironment(
          cliEnvironment(
            await envWithNodeOnPath(),
            executable: argv.first,
            windows: _locator.isWindows,
            extraPath: [git],
            extra: extraEnv,
          ),
          configuredSshCommand: await _configuredSshCommand(git),
        );
        emit('\$ ${[_programName(argv.first), ...argv.skip(1)].join(' ')}');
        if (cancelled) {
          exit.complete(-1);
          return;
        }
        final proc = process = await Process.start(
          argv.first,
          argv.sublist(1),
          workingDirectory: parent.path,
          environment: env,
          runInShell: _locator.isWindows && needsShell(argv.first),
        );
        // `--progress` reescreve a linha com `\r` a cada 1%: passa só a cada
        // 10%, como no clone por URL.
        final throttle = GitProgressThrottle();
        await Future.wait([
          for (final stream in [proc.stdout, proc.stderr])
            stream
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())
                .where(throttle.accept)
                .forEach(emit),
        ]);
        exit.complete(await proc.exitCode);
      } catch (e) {
        emit('Failed to run clone: $e');
        if (!exit.isCompleted) exit.complete(-1);
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }();

    Future<void> cancel() async {
      cancelled = true;
      final proc = process;
      if (proc != null) await _killTree(proc);
      await exit.future;
      // Só apaga o que este clone criou: pasta que já existia antes fica.
      if (!existedBefore) {
        final dir = Directory(targetPath);
        if (await dir.exists()) {
          try {
            await dir.delete(recursive: true);
          } on FileSystemException {
            // Arquivo preso (antivírus no Windows): a pasta fica; o próximo
            // clone reclama de pasta não vazia e o usuário apaga.
          }
        }
      }
    }

    return CloneProcess(
      output: controller.stream,
      exitCode: exit.future,
      cancel: cancel,
    );
  }

  String _programName(String path) =>
      _locator.pathContext.basenameWithoutExtension(path);

  /// `core.sshCommand` do git config do usuário, ou `null`.
  Future<String?> _configuredSshCommand(String git) async {
    try {
      final res = await Process.run(git, const [
        'config',
        '--get',
        'core.sshCommand',
      ]);
      final value = (res.stdout as String).trim();
      return res.exitCode == 0 && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// Mata [proc] e os descendentes: `gh`/`glab` rodam o `git`, que roda o
  /// `git-remote-https`/`index-pack`. Matar só o pai deixaria o download
  /// órfão escrevendo na pasta.
  Future<void> _killTree(Process proc) async {
    final pid = proc.pid;
    try {
      if (_locator.isWindows) {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
        return;
      }
      final all = <int>[];
      Future<void> collect(int parent) async {
        final res = await Process.run('pgrep', ['-P', '$parent']);
        for (final line in (res.stdout as String).split('\n')) {
          final child = int.tryParse(line.trim());
          if (child == null) continue;
          all.add(child);
          await collect(child);
        }
      }

      await collect(pid);
      for (final child in all.reversed) {
        Process.killPid(child);
      }
    } catch (_) {
      // Sem pgrep/taskkill: mata ao menos o processo direto.
    }
    proc.kill();
  }
}
