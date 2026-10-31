import 'package:cockpit/app/cockpit/domain/entities/git_hosting.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Um serviço Git acessado pela CLI oficial (aba "Meus repositórios").
///
/// A impl conhece a CLI: onde achar o binário em cada sistema, como perguntar
/// pelo login, como listar e como clonar. Plataforma e ambiente são injetados
/// na impl, então o contrato não fala de sistema operacional.
abstract class GitHostingProvider {
  GitHostingKind get kind;

  /// Nome do executável (`gh`, `glab`, `az`, `tea`).
  String get cliName;

  /// Acha a CLI e lê as contas logadas. Nunca lança: CLI ausente ou quebrada
  /// vira [ProviderState.cliMissing] / [ProviderState.signedOut].
  Future<ProviderStatus> status();

  /// Repositórios da [account] (do usuário e das organizações dele).
  Future<Result<List<RemoteRepo>, GitHostingError>> listRepos(
    HostingAccount account,
  );

  /// Como clonar [repo] em [targetPath].
  CloneSpec cloneSpec(RemoteRepo repo, String targetPath);

  /// Como instalar a CLI neste sistema.
  InstallHint installHint();

  /// Comandos que conectam a conta, rodados em ordem numa aba de terminal
  /// (`gh auth login --web`). Interativos: o usuário responde no terminal.
  List<CliCommand> connectCommands();
}

/// Um clone em andamento: saída por linha, código de saída e cancelamento.
class CloneProcess {
  CloneProcess({
    required this.output,
    required this.exitCode,
    required this._cancel,
  });

  final Stream<String> output;
  final Future<int> exitCode;
  final Future<void> Function() _cancel;

  /// Mata o processo (e os filhos: `gh` roda o `git` por baixo) e apaga a
  /// pasta parcial que o clone criou.
  Future<void> cancel() => _cancel();
}

/// Os serviços suportados + o que é comum a eles (rodar o clone, achar
/// binários pra montar o comando do terminal).
abstract class GitHostingCatalog {
  /// Todos os serviços suportados, na ordem em que aparecem na UI.
  List<GitHostingProvider> get providers;

  /// Sistema do host (comando de instalar, separador de caminho).
  HostOs get os;

  /// Caminho absoluto de [program] (`brew`, `gh`...), ou `null` se não achou.
  Future<String?> locate(String program);

  /// Roda o clone de [repo] em [targetPath] segundo o [CloneSpec] do provedor.
  CloneProcess clone(
    GitHostingProvider provider,
    RemoteRepo repo,
    String targetPath,
  );
}
