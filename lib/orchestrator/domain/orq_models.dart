/// Modelo do Orquestrador (port de `taskPlan.js` / quadro do
/// Orchestrator-AI): uma rodada (run) nasce de um plano aprovado e tem de 1 a
/// 12 tarefas com dependências, executadas por agentes trabalhadores.
library;

/// Estados de uma tarefa no quadro.
enum OrqTaskStatus {
  planned('Planejada'),
  queued('Na fila'),
  starting('Iniciando'),
  running('Executando'),
  awaitingReview('Aguardando revisão'),
  complete('Concluída'),
  failed('Falhou'),
  blocked('Bloqueada'),
  cancelling('Cancelando'),
  cancelled('Cancelada'),
  parked('Parada');

  const OrqTaskStatus(this.label);
  final String label;

  /// Ocupa uma vaga de execução.
  bool get active => this == starting || this == running || this == cancelling;

  /// Não volta mais a executar sem ação do usuário.
  bool get settled =>
      this == complete || this == cancelled || this == failed || this == parked;

  static OrqTaskStatus parse(Object? value) => OrqTaskStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => OrqTaskStatus.planned,
  );
}

/// Estados da rodada.
enum OrqRunStatus {
  proposed('Plano proposto'),
  running('Em execução'),
  paused('Pausada'),
  cancelled('Cancelada'),
  complete('Concluída'),
  rejected('Plano rejeitado');

  const OrqRunStatus(this.label);
  final String label;

  static OrqRunStatus parse(Object? value) => OrqRunStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => OrqRunStatus.proposed,
  );
}

/// Onde a tarefa trabalha.
enum OrqTarget {
  /// Dados e telas do Gestor UFU (ferramentas do Gestor, sem Git).
  gestor,

  /// Pasta do projeto configurada (worktree Git própria ou checkout atual).
  project;

  static OrqTarget parse(Object? value) =>
      value == 'gestor' ? OrqTarget.gestor : OrqTarget.project;
}

class OrqHistoryItem {
  OrqHistoryItem(this.event, this.detail, {DateTime? at})
    : at = at ?? DateTime.now();

  final DateTime at;
  final String event;
  final String detail;

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'event': event,
    'detail': detail,
  };

  factory OrqHistoryItem.fromJson(Map<String, dynamic> json) => OrqHistoryItem(
    '${json['event'] ?? ''}',
    '${json['detail'] ?? ''}',
    at: DateTime.tryParse('${json['at']}'),
  );
}

/// Arquivo alterado pela tarefa (código do `git status --porcelain`).
class OrqChangedFile {
  const OrqChangedFile(this.code, this.path);

  final String code;
  final String path;

  Map<String, dynamic> toJson() => {'code': code, 'path': path};

  factory OrqChangedFile.fromJson(Map<String, dynamic> json) =>
      OrqChangedFile('${json['code'] ?? ''}', '${json['path'] ?? ''}');
}

class OrqTask {
  OrqTask({
    required this.id,
    required this.title,
    required this.description,
    required this.acceptanceCriteria,
    this.dependsOn = const [],
    this.provider = 'auto',
    this.profileId = '',
    this.model = '',
    this.effort = '',
    this.target = OrqTarget.project,
    this.worktree = '',
    this.base = '',
    this.estimatedCostUsd,
    this.status = OrqTaskStatus.planned,
    this.attempts = 0,
    List<OrqHistoryItem>? history,
    this.result = '',
    this.error = '',
    this.sessionState = const {},
    this.worktreePath = '',
    this.branch = '',
    List<OrqChangedFile>? changedFiles,
    this.memoryStatus = 'unverified',
    this.memoryPage = '',
    this.reviewNote = '',
    this.handoffId = '',
    this.machine = '',
  }) : history = history ?? [],
       changedFiles = changedFiles ?? [];

  final String id;
  String title;
  String description;
  List<String> acceptanceCriteria;
  List<String> dependsOn;

  /// `claude`, `chatgpt`, `gemini`, `copilot` ou `auto`.
  String provider;
  String profileId;
  String model;
  String effort;
  OrqTarget target;

  /// Nome da worktree ("" = gerada pelo id; "current" = checkout atual).
  String worktree;

  /// Branch local de base da worktree.
  String base;
  double? estimatedCostUsd;

  OrqTaskStatus status;
  int attempts;
  final List<OrqHistoryItem> history;
  String result;
  String error;

  /// Estado do backend do trabalhador (retomar a mesma sessão no "repetir").
  Map<String, dynamic> sessionState;
  String worktreePath;
  String branch;
  List<OrqChangedFile> changedFiles;
  String memoryStatus;
  String memoryPage;

  /// Orientação do revisor para a próxima tentativa.
  String reviewNote;
  String handoffId;

  /// Computador que executa a tarefa (o quadro é sincronizado entre
  /// computadores; a execução e a worktree pertencem a um só).
  String machine;

  void log(String event, [String detail = '']) {
    history.add(OrqHistoryItem(event, detail));
    if (history.length > 100) history.removeRange(0, history.length - 100);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'acceptanceCriteria': acceptanceCriteria,
    'dependsOn': dependsOn,
    'provider': provider,
    'profileId': profileId,
    'model': model,
    'effort': effort,
    'target': target.name,
    'worktree': worktree,
    'base': base,
    if (estimatedCostUsd != null) 'estimatedCostUsd': estimatedCostUsd,
    'status': status.name,
    'attempts': attempts,
    'history': [for (final h in history) h.toJson()],
    'result': result,
    'error': error,
    if (sessionState.isNotEmpty) 'sessionState': sessionState,
    'worktreePath': worktreePath,
    'branch': branch,
    'changedFiles': [for (final f in changedFiles) f.toJson()],
    'memoryStatus': memoryStatus,
    'memoryPage': memoryPage,
    'reviewNote': reviewNote,
    'handoffId': handoffId,
    'machine': machine,
  };

  factory OrqTask.fromJson(Map<String, dynamic> json) => OrqTask(
    id: '${json['id']}',
    title: '${json['title'] ?? ''}',
    description: '${json['description'] ?? ''}',
    acceptanceCriteria: [
      for (final c in json['acceptanceCriteria'] as List? ?? const []) '$c',
    ],
    dependsOn: [for (final d in json['dependsOn'] as List? ?? const []) '$d'],
    provider: '${json['provider'] ?? 'auto'}',
    profileId: '${json['profileId'] ?? ''}',
    model: '${json['model'] ?? ''}',
    effort: '${json['effort'] ?? ''}',
    target: OrqTarget.parse(json['target']),
    worktree: '${json['worktree'] ?? ''}',
    base: '${json['base'] ?? ''}',
    estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble(),
    status: OrqTaskStatus.parse(json['status']),
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    history: [
      for (final h in json['history'] as List? ?? const [])
        OrqHistoryItem.fromJson(Map<String, dynamic>.from(h as Map)),
    ],
    result: '${json['result'] ?? ''}',
    error: '${json['error'] ?? ''}',
    sessionState: Map<String, dynamic>.from(
      json['sessionState'] as Map? ?? const {},
    ),
    worktreePath: '${json['worktreePath'] ?? ''}',
    branch: '${json['branch'] ?? ''}',
    changedFiles: [
      for (final f in json['changedFiles'] as List? ?? const [])
        OrqChangedFile.fromJson(Map<String, dynamic>.from(f as Map)),
    ],
    memoryStatus: '${json['memoryStatus'] ?? 'unverified'}',
    memoryPage: '${json['memoryPage'] ?? ''}',
    reviewNote: '${json['reviewNote'] ?? ''}',
    handoffId: '${json['handoffId'] ?? ''}',
    machine: '${json['machine'] ?? ''}',
  );
}

/// Rodada: um plano e a execução das suas tarefas.
class OrqRun {
  OrqRun({
    required this.id,
    required this.title,
    required this.prompt,
    required this.tasks,
    this.status = OrqRunStatus.proposed,
    this.projectPath = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String title;

  /// Pedido do usuário que originou o plano.
  final String prompt;
  final List<OrqTask> tasks;
  OrqRunStatus status;
  String projectPath;
  final DateTime createdAt;

  OrqTask? task(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'prompt': prompt,
    'status': status.name,
    'projectPath': projectPath,
    'createdAt': createdAt.toIso8601String(),
    'tasks': [for (final t in tasks) t.toJson()],
  };

  factory OrqRun.fromJson(Map<String, dynamic> json) => OrqRun(
    id: '${json['id']}',
    title: '${json['title'] ?? ''}',
    prompt: '${json['prompt'] ?? ''}',
    status: OrqRunStatus.parse(json['status']),
    projectPath: '${json['projectPath'] ?? ''}',
    createdAt: DateTime.tryParse('${json['createdAt']}'),
    tasks: [
      for (final t in json['tasks'] as List? ?? const [])
        OrqTask.fromJson(Map<String, dynamic>.from(t as Map)),
    ],
  );
}
