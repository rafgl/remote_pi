/// Entidades da aba "Meus repositórios" do dialog de clone (issue #278).
///
/// Cada serviço Git entra pela CLI oficial que o usuário já tem logada na
/// máquina (`gh`, `glab`, `az`, `tea`). O Cockpit não pede nem guarda token:
/// a credencial fica com a CLI.
library;

/// Serviços com CLI oficial capaz de listar repositórios.
///
/// Bitbucket fica de fora por enquanto: não tem CLI oficial que liste repos.
/// Quando tiver, entra como mais um valor aqui e um `GitHostingProvider` novo;
/// o resto da aba (seletor, lista, clone) já é genérico.
enum GitHostingKind { github, gitlab, azureDevOps, gitea }

/// Sistema do host, pra escolher comando de instalação e caminhos.
enum HostOs { macos, windows, linux }

/// Dono do repositório do ponto de vista do usuário logado.
enum RepoOwnerKind { user, organization }

/// Uma conta logada numa CLI: o host (`github.com`, `gitlab.empresa.com`,
/// `dev.azure.com/org`) e o login mostrado na UI.
class HostingAccount {
  const HostingAccount({required this.host, required this.login, this.handle});

  final String host;
  final String login;

  /// Identificador da conta na CLI, quando não é o host (o nome do login no
  /// `tea`, passado em `--login`).
  final String? handle;

  @override
  bool operator ==(Object other) =>
      other is HostingAccount && other.host == host && other.login == login;

  @override
  int get hashCode => Object.hash(host, login);
}

/// Situação de uma CLI na máquina.
enum ProviderState {
  /// O executável não foi achado (nem no PATH nem nas pastas conhecidas).
  cliMissing,

  /// A CLI existe, mas não há conta logada.
  signedOut,

  /// Instalada e com pelo menos uma conta.
  ready,
}

class ProviderStatus {
  const ProviderStatus({
    required this.state,
    this.cliPath,
    this.accounts = const [],
  });

  const ProviderStatus.cliMissing() : this(state: ProviderState.cliMissing);

  final ProviderState state;

  /// Caminho absoluto do executável, quando achado.
  final String? cliPath;

  /// Contas logadas (vazio fora de [ProviderState.ready]).
  final List<HostingAccount> accounts;
}

/// Um repositório listado pela CLI.
class RemoteRepo {
  const RemoteRepo({
    required this.kind,
    required this.host,
    required this.owner,
    required this.ownerKind,
    required this.name,
    required this.fullName,
    required this.cloneUrl,
    this.description,
    this.isPrivate = false,
    this.updatedAt,
    this.sshUrl,
  });

  final GitHostingKind kind;
  final String host;

  /// Dono exibido no agrupamento: usuário, organização, grupo do GitLab ou
  /// `organização/projeto` no Azure DevOps.
  final String owner;
  final RepoOwnerKind ownerKind;

  /// Nome curto do repositório. É também o nome da pasta do clone (no GitLab
  /// é o `path`, o slug, que é o que o `git clone` cria).
  final String name;

  /// Identificador completo no serviço (`owner/repo`, `grupo/sub/repo`).
  final String fullName;
  final String? description;
  final bool isPrivate;
  final DateTime? updatedAt;

  /// URL HTTPS do clone.
  final String cloneUrl;
  final String? sshUrl;
}

/// Por que a lista não veio.
enum GitHostingErrorKind {
  /// A CLI sumiu entre a detecção e o uso.
  cliMissing,

  /// A CLI respondeu que não há login (ou o login expirou).
  signedOut,

  /// Azure DevOps: a conta não tem nenhuma organização acessível.
  noOrganization,

  /// A CLI terminou com erro; o stderr vai em [GitHostingError.detail].
  commandFailed,

  /// A CLI respondeu algo que não é o JSON esperado.
  badOutput,
}

/// Erro tipado da listagem. Sem frase pronta: a UI traduz pelo [kind] e mostra
/// [detail] (saída crua da CLI) sem traduzir.
class GitHostingError {
  const GitHostingError(this.kind, {this.detail});

  final GitHostingErrorKind kind;
  final String? detail;

  @override
  String toString() => 'GitHostingError($kind, $detail)';
}

/// Uma linha de comando: programa + argumentos (+ variáveis de ambiente).
class CliCommand {
  const CliCommand(this.program, this.args, {this.env = const {}});

  final String program;
  final List<String> args;
  final Map<String, String> env;

  /// Como o usuário digitaria (`gh auth login --web`). Só pra exibir.
  String get display => [program, ...args].join(' ');
}

/// Como instalar a CLI neste sistema: um comando (quando há gerenciador de
/// pacotes) e sempre a página oficial, pra quem não tem Homebrew/winget.
class InstallHint {
  const InstallHint({required this.url, this.command});

  final CliCommand? command;
  final String url;
}

/// Como clonar um repositório da lista.
sealed class CloneSpec {
  const CloneSpec();
}

/// Clone pela própria CLI (`gh repo clone`, `glab repo clone`): usa o mesmo
/// login que montou a lista.
final class CliCloneSpec extends CloneSpec {
  const CliCloneSpec(this.command);

  final CliCommand command;
}

/// Clone com `git clone <url>` (Azure DevOps, Gitea/Forgejo): a CLI não clona,
/// a credencial é a do git (Git Credential Manager, keychain, SSH).
final class GitUrlCloneSpec extends CloneSpec {
  const GitUrlCloneSpec(this.url);

  final String url;
}
