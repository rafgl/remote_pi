import 'dart:async';

import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Provedor com status e lista programáveis. [gate] segura a lista (estado
/// "carregando") até ser completado.
class FakeProvider implements GitHostingProvider {
  FakeProvider(
    this.kind, {
    this.cliName = 'gh',
    ProviderStatus? status,
    this.repos = const [],
    this.listError,
    this.gate,
    this.install = const InstallHint(
      url: 'https://cli.github.com',
      command: CliCommand('brew', ['install', 'gh']),
    ),
    this.connectArgs = const ['auth', 'login', '--web'],
  }) : statusValue = status ?? const ProviderStatus.cliMissing();

  @override
  final GitHostingKind kind;
  @override
  final String cliName;
  ProviderStatus statusValue;
  List<RemoteRepo> repos;
  GitHostingError? listError;
  Completer<void>? gate;
  final InstallHint install;
  final List<String> connectArgs;
  int listCalls = 0;

  @override
  Future<ProviderStatus> status() async => statusValue;

  @override
  Future<Result<List<RemoteRepo>, GitHostingError>> listRepos(
    HostingAccount account,
  ) async {
    listCalls++;
    await gate?.future;
    final e = listError;
    return e == null ? Success(repos) : Failure(e);
  }

  @override
  CloneSpec cloneSpec(RemoteRepo repo, String targetPath) => CliCloneSpec(
    CliCommand('gh', ['repo', 'clone', repo.fullName, targetPath]),
  );

  @override
  InstallHint installHint() => install;

  @override
  List<CliCommand> connectCommands() => [CliCommand(cliName, connectArgs)];
}

/// Clone controlável pelo teste.
class FakeClone {
  final output = StreamController<String>();
  final exit = Completer<int>();
  bool cancelled = false;

  late final process = CloneProcess(
    output: output.stream,
    exitCode: exit.future,
    cancel: () async {
      cancelled = true;
      if (!exit.isCompleted) exit.complete(-1);
      await output.close();
    },
  );

  Future<void> finish(int code) async {
    if (!exit.isCompleted) exit.complete(code);
    await output.close();
  }
}

class FakeCatalog implements GitHostingCatalog {
  FakeCatalog(
    this.providers, {
    this.os = HostOs.macos,
    this.programs = const {'brew': '/opt/homebrew/bin/brew'},
  });

  @override
  final List<GitHostingProvider> providers;
  @override
  final HostOs os;
  final Map<String, String> programs;
  final clones = <String, FakeClone>{};
  final cloneTargets = <String>[];

  @override
  Future<String?> locate(String program) async => programs[program];

  @override
  CloneProcess clone(
    GitHostingProvider provider,
    RemoteRepo repo,
    String targetPath,
  ) {
    cloneTargets.add(targetPath);
    return (clones[repo.fullName] = FakeClone()).process;
  }
}

RemoteRepo repo(
  String owner,
  String name, {
  bool user = false,
  bool private = false,
  String? description,
  DateTime? updated,
}) => RemoteRepo(
  kind: GitHostingKind.github,
  host: 'github.com',
  owner: owner,
  ownerKind: user ? RepoOwnerKind.user : RepoOwnerKind.organization,
  name: name,
  fullName: '$owner/$name',
  description: description,
  isPrivate: private,
  updatedAt: updated,
  cloneUrl: 'https://github.com/$owner/$name',
);

const ghReady = ProviderStatus(
  state: ProviderState.ready,
  cliPath: '/opt/homebrew/bin/gh',
  accounts: [HostingAccount(host: 'github.com', login: 'rafgl')],
);
