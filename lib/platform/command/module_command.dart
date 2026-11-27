/// Comando de um módulo: uma ação que a tela, o menu "/" e o Agente de IA
/// executam do mesmo jeito.
///
/// Regras (docs/arquitetura/decisoes.md, D2):
/// - não usa BuildContext, diálogos nem seletores de arquivo — quem chama
///   resolve as interações e passa tudo em [CommandInput];
/// - roda na janela principal;
/// - [approval] diz se o agente precisa pedir confirmação antes.
library;

enum CommandApproval {
  /// Executa direto.
  none,

  /// Ação destrutiva ou externa: o agente pede confirmação no chat.
  required,
}

/// De onde veio a execução (para registro e mensagens).
enum CommandOrigin { ui, palette, agent, test }

/// Contexto para operações remotas longas. Atualiza o celular e oferece
/// cancelamento cooperativo onde o serviço implementa esta execução.
class CommandExecutionContext {
  CommandExecutionContext({
    required this.isCancellationRequested,
    required this.reportProgress,
  });

  final bool Function() isCancellationRequested;
  final void Function(String stage, {double? fraction}) reportProgress;

  bool get cancellationRequested => isCancellationRequested();

  void checkCancellation() {
    if (cancellationRequested) {
      throw const CommandException(
        'cancelled',
        'Operação cancelada pelo usuário.',
      );
    }
  }
}

/// Entrada de um comando: mapa já validado pelo comando.
typedef CommandInput = Map<String, dynamic>;

class CommandResult {
  const CommandResult.ok({this.message = '', this.data = const {}})
    : ok = true,
      code = null;

  const CommandResult.fail(this.code, this.message, {this.data = const {}})
    : ok = false;

  final bool ok;

  /// Código estável do erro (ex.: "arquivo_invalido"); `null` em sucesso.
  final String? code;
  final String message;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'ok': ok,
    if (code != null) 'code': code,
    if (message.isNotEmpty) 'message': message,
    ...data,
  };
}

/// Erro com código estável, lançado pelos comandos e serviços dos módulos.
class CommandException implements Exception {
  const CommandException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class ModuleCommand {
  const ModuleCommand({
    required this.id,
    required this.title,
    required this.description,
    required this.run,
    this.inputSchema = const {'type': 'object', 'properties': {}},
    this.remoteInputSchema,
    this.approval = CommandApproval.none,
    this.mutates = false,
    this.remoteEnabled = true,
    this.runRemote,
  });

  /// `modulo.acao`, ex.: `equivalencia.importarCurriculo`.
  final String id;
  final String title;
  final String description;

  /// JSON schema da entrada — adaptador para o agente; o comando valida.
  final Map<String, dynamic> inputSchema;

  /// Optional schema adapter for commands whose Windows-only inputs are
  /// generated or managed by the host during a remote invocation.
  final Map<String, dynamic>? remoteInputSchema;
  final CommandApproval approval;

  /// Altera dados do banco (a janela recarrega após a execução).
  final bool mutates;

  /// False for actions whose only effect is navigating a desktop-only window.
  /// Remote clients must expose a mobile-capable equivalent instead.
  final bool remoteEnabled;
  final Future<CommandResult> Function(CommandInput input, CommandOrigin origin)
  run;

  /// Implementado por operações remotas longas que reportam etapa e atendem
  /// cancelamento. Comandos sem este handler permanecem não canceláveis.
  final Future<CommandResult> Function(
    CommandInput input,
    CommandOrigin origin,
    CommandExecutionContext context,
  )?
  runRemote;
}

/// Leitura validada da entrada.
extension CommandInputRead on CommandInput {
  String requireString(String key) {
    final value = this[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    throw CommandException('entrada_invalida', 'Informe "$key".');
  }

  String? optionalString(String key) {
    final value = this[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  bool flag(String key, {bool fallback = false}) {
    final value = this[key];
    return value is bool ? value : fallback;
  }
}
