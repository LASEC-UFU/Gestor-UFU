import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';

/// Memória entregue a um trabalhador antes da tarefa.
class OrqTaskMemory {
  const OrqTaskMemory({
    this.status = 'unverified',
    this.pagePath = '',
    this.context = '',
    this.instructions = '',
    this.mcpServerUrl = '',
  });

  /// `verified` só depois de leitura/escrita confirmadas.
  final String status;
  final String pagePath;

  /// Trechos verificados (evidência histórica, não instruções).
  final String context;

  /// Como o trabalhador pode consultar/atualizar a memória.
  final String instructions;

  /// Servidor MCP do AI Memory para registrar no trabalhador (CLI).
  final String mcpServerUrl;
}

/// Ponte de memória do Orquestrador. A implementação padrão não tem
/// memória; o AI Memory gerenciado entra por [AiMemoryBridge].
abstract class OrqMemoryBridge {
  /// Estado para a tela (ex.: "AI Memory v3.4.5 ativo").
  String get statusLabel;

  bool get available;

  /// Trechos relevantes para o pedido do usuário (consulta do coordenador).
  Future<String> coordinatorContext(String query, String projectPath);

  /// Prepara a página da tarefa e devolve o contexto para o trabalhador.
  Future<OrqTaskMemory> prepareTask(OrqRun run, OrqTask task);

  /// Registra o relatório da tentativa (criação única, verificada).
  Future<String> recordAttempt(OrqRun run, OrqTask task, String provider);
}

class NoMemoryBridge implements OrqMemoryBridge {
  const NoMemoryBridge();

  @override
  String get statusLabel => 'AI Memory desligado';

  @override
  bool get available => false;

  @override
  Future<String> coordinatorContext(String query, String projectPath) async =>
      '';

  @override
  Future<OrqTaskMemory> prepareTask(OrqRun run, OrqTask task) async =>
      const OrqTaskMemory();

  @override
  Future<String> recordAttempt(
    OrqRun run,
    OrqTask task,
    String provider,
  ) async => 'unverified';
}
