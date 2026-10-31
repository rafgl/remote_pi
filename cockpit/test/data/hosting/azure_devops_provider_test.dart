import 'package:cockpit/app/cockpit/data/hosting/azure_devops_provider.dart';
import 'package:cockpit/app/cockpit/data/hosting/cli_support.dart';
import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _account =
    '{"environmentName":"AzureCloud","user":{"name":"rafa@acme.com","type":"user"}}';
const _profile = '{"id":"6a30c7e7-26e4","displayName":"Rafa"}';
const _orgs =
    '{"count":2,"value":[{"accountName":"acme","accountUri":"https://x/"},'
    '{"accountName":"claims","accountUri":"https://y/"}]}';
const _acmeRepos =
    '{"count":2,"value":[{"name":"landing","isDisabled":false,'
    '"remoteUrl":"https://acme@dev.azure.com/acme/uInspect/_git/landing",'
    '"sshUrl":"git@ssh.dev.azure.com:v3/acme/uInspect/landing",'
    '"project":{"name":"uInspect","visibility":"private",'
    '"lastUpdateTime":"2026-07-15T15:17:34.67Z"}},'
    '{"name":"old","isDisabled":true,"remoteUrl":"https://x/old",'
    '"project":{"name":"uInspect"}}]}';

String _url(List<String> args) => args[args.indexOf('--url') + 1];

void main() {
  group('parsers', () {
    test('account show', () {
      expect(
        parseAzAccount(_account),
        const HostingAccount(host: 'dev.azure.com', login: 'rafa@acme.com'),
      );
      expect(parseAzAccount('Please run az login'), isNull);
    });

    test('profile e organizações', () {
      expect(parseAzProfileId(_profile), '6a30c7e7-26e4');
      expect(parseAzOrganizations(_orgs), ['acme', 'claims']);
      expect(parseAzOrganizations('{"count":0,"value":[]}'), isEmpty);
      expect(parseAzOrganizations('x'), isNull);
    });

    test('repositórios: dono org/projeto, pula desativado', () {
      final repos = parseAzRepos(_acmeRepos, organization: 'acme')!;
      expect(repos, hasLength(1));
      final r = repos.single;
      expect(r.owner, 'acme/uInspect');
      expect(r.fullName, 'acme/uInspect/landing');
      expect(r.ownerKind, RepoOwnerKind.organization);
      expect(r.isPrivate, isTrue);
      expect(
        r.cloneUrl,
        'https://acme@dev.azure.com/acme/uInspect/_git/landing',
      );
      expect(r.updatedAt, DateTime.utc(2026, 7, 15, 15, 17, 34, 670));
    });
  });

  group('status', () {
    test('sem az', () async {
      final p = AzureDevOpsProvider(locatorWith({}), FakeCliRunner({}));
      expect((await p.status()).state, ProviderState.cliMissing);
    });

    test('az sem login', () async {
      final p = AzureDevOpsProvider(
        locatorWith({'/opt/homebrew/bin/az'}),
        FakeCliRunner({'account show': err("Please run 'az login'")}),
      );
      expect((await p.status()).state, ProviderState.signedOut);
    });

    test('az logado', () async {
      final p = AzureDevOpsProvider(
        locatorWith({'/usr/local/bin/az'}),
        FakeCliRunner({'account show': ok(_account)}),
      );
      final st = await p.status();
      expect(st.state, ProviderState.ready);
      expect(st.accounts.single.login, 'rafa@acme.com');
    });

    test('Windows: az.cmd em Microsoft SDKs\\Azure\\CLI2\\wbin', () async {
      const path = r'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd';
      final p = AzureDevOpsProvider(
        locatorWith({path}, os: HostOs.windows, env: windowsEnv),
        FakeCliRunner({'account show': ok(_account)}),
      );
      expect((await p.status()).cliPath, path);
    });
  });

  group('listRepos', () {
    const account = HostingAccount(host: 'dev.azure.com', login: 'rafa');

    test('descobre organizações e lista cada uma (sem & nos args)', () async {
      final runner = _UrlRunner({
        'profiles/me': ok(_profile),
        '_apis/accounts': ok(_orgs),
        'acme/_apis/git/repositories': ok(_acmeRepos),
        'claims/_apis/git/repositories': err('TF400813: not authorized'),
      });
      final p = AzureDevOpsProvider(
        locatorWith({'/opt/homebrew/bin/az'}),
        runner,
      );
      final res = await p.listRepos(account);
      final repos = (res as Success<List<RemoteRepo>, GitHostingError>).value;
      expect(repos.single.name, 'landing');
      for (final args in runner.calls) {
        expect(args.join(' '), isNot(matches(RegExp(r'[&|<>^%]'))));
        expect(args, contains(kAzureDevOpsResource));
      }
      final accounts = runner.calls.firstWhere(
        (a) => _url(a).contains('_apis/accounts'),
      );
      expect(accounts, contains('memberId=6a30c7e7-26e4'));
    });

    test('sem organização', () async {
      final p = AzureDevOpsProvider(
        locatorWith({'/opt/homebrew/bin/az'}),
        _UrlRunner({
          'profiles/me': ok(_profile),
          '_apis/accounts': ok('{"count":0,"value":[]}'),
        }),
      );
      final res = await p.listRepos(account);
      expect(
        (res as Failure<List<RemoteRepo>, GitHostingError>).error.kind,
        GitHostingErrorKind.noOrganization,
      );
    });

    test('token expirado vira signedOut', () async {
      final p = AzureDevOpsProvider(
        locatorWith({'/opt/homebrew/bin/az'}),
        _UrlRunner({
          'profiles/me': err("AADSTS700082: expired. Please run 'az login'"),
        }),
      );
      final res = await p.listRepos(account);
      expect(
        (res as Failure<List<RemoteRepo>, GitHostingError>).error.kind,
        GitHostingErrorKind.signedOut,
      );
    });
  });

  test('clone por git, instalar e conectar', () {
    final mac = AzureDevOpsProvider(locatorWith({}), FakeCliRunner({}));
    final spec = mac.cloneSpec(
      parseAzRepos(_acmeRepos, organization: 'acme')!.single,
      '/p/landing',
    );
    expect(
      (spec as GitUrlCloneSpec).url,
      'https://acme@dev.azure.com/acme/uInspect/_git/landing',
    );
    expect(mac.installHint().command!.display, 'brew install azure-cli');
    expect(
      AzureDevOpsProvider(
        locatorWith({}, os: HostOs.windows),
        FakeCliRunner({}),
      ).installHint().command!.display,
      'winget install --id Microsoft.AzureCLI',
    );
    expect(mac.connectCommands().single.display, 'az login');
  });
}

/// Responde pelo trecho da `--url` do `az rest` e guarda os args.
class _UrlRunner implements CliRunner {
  _UrlRunner(this.byUrl);

  final Map<String, CliResult> byUrl;
  final calls = <List<String>>[];

  @override
  Future<CliResult> run(
    String executable,
    List<String> args, {
    Map<String, String> env = const {},
  }) async {
    calls.add(args);
    final url = _url(args);
    for (final e in byUrl.entries) {
      if (url.contains(e.key)) return e.value;
    }
    return err('unexpected $url');
  }
}
