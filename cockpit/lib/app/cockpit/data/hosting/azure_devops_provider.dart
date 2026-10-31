import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_hosting_provider.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Recurso (application id) do Azure DevOps pro token do `az rest`.
const kAzureDevOpsResource = '499b84ac-1321-427f-aa17-267ca6975798';

const _apiVersion = 'api-version=7.1';

/// Azure DevOps pelo `az`, com o login do `az login`.
///
/// Não usa `az repos list`: ele exige `--project` (um por chamada, e cada
/// chamada do `az` custa ~1 s de Python). Em vez disso:
/// 1. descobre as organizações da conta (`_apis/profile` + `_apis/accounts`);
/// 2. lista TODOS os repositórios de cada organização numa chamada
///    (`_apis/git/repositories`, sem projeto) via `az rest`.
///
/// Por isso a extensão `azure-devops` não é necessária. O clone é `git clone`
/// com a URL remota: a credencial é a do git (Git Credential Manager).
///
/// Os argumentos não levam `& | < > ^ %` porque no Windows o `az` é um
/// `az.cmd`, executado pelo `cmd.exe`: os parâmetros da URL vão em
/// `--uri-parameters`.
class AzureDevOpsProvider implements GitHostingProvider {
  AzureDevOpsProvider(this._locator, this._runner);

  final CliLocator _locator;
  final CliRunner _runner;

  @override
  GitHostingKind get kind => GitHostingKind.azureDevOps;

  @override
  String get cliName => 'az';

  /// Windows: o MSI instala o `az.cmd` em
  /// `Program Files\Microsoft SDKs\Azure\CLI2\wbin` (64 ou 32 bits).
  Future<String?> _locate() => _locator.locate(
    'az',
    extraDirs: [
      if (_locator.isWindows)
        for (final base in _locator.windowsProgramDirs())
          _locator.pathContext.join(
            base,
            'Microsoft SDKs',
            'Azure',
            'CLI2',
            'wbin',
          ),
    ],
  );

  @override
  Future<ProviderStatus> status() async {
    final az = await _locate();
    if (az == null) return const ProviderStatus.cliMissing();
    final res = await _runner.run(az, const [
      'account',
      'show',
      '--output',
      'json',
    ]);
    final account = res.ok ? parseAzAccount(res.stdout) : null;
    return ProviderStatus(
      state: account == null ? ProviderState.signedOut : ProviderState.ready,
      cliPath: az,
      accounts: [?account],
    );
  }

  Future<CliResult> _rest(String az, String url, List<String> params) =>
      _runner.run(az, [
        'rest',
        '--method',
        'get',
        '--url',
        url,
        '--resource',
        kAzureDevOpsResource,
        '--uri-parameters',
        ...params,
        _apiVersion,
        '--output',
        'json',
      ]);

  @override
  Future<Result<List<RemoteRepo>, GitHostingError>> listRepos(
    HostingAccount account,
  ) async {
    final az = await _locate();
    if (az == null) {
      return const Failure(GitHostingError(GitHostingErrorKind.cliMissing));
    }
    final profile = await _rest(
      az,
      'https://app.vssps.visualstudio.com/_apis/profile/profiles/me',
      const [],
    );
    if (!profile.ok) return Failure(_error(profile));
    final memberId = parseAzProfileId(profile.stdout);
    if (memberId == null) {
      return Failure(
        GitHostingError(GitHostingErrorKind.badOutput, detail: profile.stdout),
      );
    }
    final accounts = await _rest(
      az,
      'https://app.vssps.visualstudio.com/_apis/accounts',
      ['memberId=$memberId'],
    );
    if (!accounts.ok) return Failure(_error(accounts));
    final orgs = parseAzOrganizations(accounts.stdout);
    if (orgs == null) {
      return Failure(
        GitHostingError(GitHostingErrorKind.badOutput, detail: accounts.stdout),
      );
    }
    if (orgs.isEmpty) {
      return const Failure(GitHostingError(GitHostingErrorKind.noOrganization));
    }
    final results = await Future.wait([
      for (final org in orgs)
        _rest(
          az,
          'https://dev.azure.com/${Uri.encodeComponent(org)}/_apis/git/repositories',
          const [],
        ),
    ]);
    final repos = <RemoteRepo>[];
    CliResult? firstFailure;
    for (var i = 0; i < orgs.length; i++) {
      final res = results[i];
      if (!res.ok) {
        // Organização sem acesso (política de IP, conta desativada): as
        // outras continuam valendo.
        firstFailure ??= res;
        continue;
      }
      repos.addAll(parseAzRepos(res.stdout, organization: orgs[i]) ?? const []);
    }
    if (repos.isEmpty && firstFailure != null) {
      return Failure(_error(firstFailure));
    }
    return Success(repos);
  }

  GitHostingError _error(CliResult res) => GitHostingError(
    looksSignedOut(res.message)
        ? GitHostingErrorKind.signedOut
        : GitHostingErrorKind.commandFailed,
    detail: res.message,
  );

  @override
  CloneSpec cloneSpec(RemoteRepo repo, String targetPath) =>
      GitUrlCloneSpec(repo.cloneUrl);

  @override
  InstallHint installHint() => InstallHint(
    url: 'https://learn.microsoft.com/cli/azure/install-azure-cli',
    command: switch (_locator.os) {
      HostOs.macos => const CliCommand('brew', ['install', 'azure-cli']),
      HostOs.windows => const CliCommand('winget', [
        'install',
        '--id',
        'Microsoft.AzureCLI',
      ]),
      HostOs.linux => null,
    },
  );

  @override
  List<CliCommand> connectCommands() => const [
    CliCommand('az', ['login']),
  ];
}

/// Conta de `az account show --output json`. `null` sem login.
HostingAccount? parseAzAccount(String raw) {
  final json = tryDecodeJson(raw);
  if (json is! Map) return null;
  final user = json['user'];
  final login = user is Map ? user['name'] as String? : null;
  if (login == null || login.isEmpty) return null;
  return HostingAccount(host: 'dev.azure.com', login: login);
}

/// `id` de `_apis/profile/profiles/me`.
String? parseAzProfileId(String raw) {
  final json = tryDecodeJson(raw);
  return json is Map ? json['id'] as String? : null;
}

/// Nomes das organizações de `_apis/accounts?memberId=…` (`value[].accountName`).
List<String>? parseAzOrganizations(String raw) {
  final json = tryDecodeJson(raw);
  if (json is! Map || json['value'] is! List) return null;
  return [
    for (final a in json['value'] as List)
      if (a is Map && a['accountName'] is String) a['accountName'] as String,
  ];
}

/// Repositórios de `_apis/git/repositories` de uma organização. O dono
/// exibido é `organização/projeto`; repos desativados ficam de fora (o clone
/// falharia).
List<RemoteRepo>? parseAzRepos(String raw, {required String organization}) {
  final json = tryDecodeJson(raw);
  final list = switch (json) {
    {'value': final List v} => v,
    final List v => v,
    _ => null,
  };
  if (list == null) return null;
  final repos = <RemoteRepo>[];
  for (final r in list) {
    if (r is! Map || r['isDisabled'] == true) continue;
    final name = r['name'] as String?;
    final url = r['remoteUrl'] as String?;
    if (name == null || url == null) continue;
    final project = r['project'] is Map ? r['project'] as Map : const {};
    final projectName = (project['name'] as String?) ?? name;
    repos.add(
      RemoteRepo(
        kind: GitHostingKind.azureDevOps,
        host: 'dev.azure.com',
        owner: '$organization/$projectName',
        ownerKind: RepoOwnerKind.organization,
        name: name,
        fullName: '$organization/$projectName/$name',
        description: null,
        isPrivate: project['visibility'] != 'public',
        updatedAt: DateTime.tryParse(
          project['lastUpdateTime'] as String? ?? '',
        ),
        cloneUrl: url,
        sshUrl: r['sshUrl'] as String?,
      ),
    );
  }
  return repos;
}
