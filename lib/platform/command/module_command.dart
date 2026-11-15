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
    this.approval = CommandApproval.none,
    this.mutates = false,
  });

  /// `modulo.acao`, ex.: `equivalencia.importarCurriculo`.
  final String id;
  final String title;
  final String description;

  /// JSON schema da entrada — adaptador para o agente; o comando valida.
  final Map<String, dynamic> inputSchema;
  final CommandApproval approval;

  /// Altera dados do banco (a janela recarrega após a execução).
  final bool mutates;
  final Future<CommandResult> Function(CommandInput input, CommandOrigin origin)
  run;
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
