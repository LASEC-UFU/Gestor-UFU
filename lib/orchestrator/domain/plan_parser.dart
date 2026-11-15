import 'dart:convert';

import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';

/// Provedores aceitos nas tarefas (os agentes do Gestor) e `auto`.
const orqProviders = {'claude', 'chatgpt', 'gemini', 'copilot', 'auto'};

/// Pedido de transferência de uma tarefa para outro agente.
class OrqHandoffRequest {
  const OrqHandoffRequest({
    required this.runId,
    required this.taskId,
    required this.provider,
    required this.context,
    this.profileId = '',
    this.model = '',
    this.effort = '',
  });

  final String runId;
  final String taskId;
  final String provider;
  final String profileId;
  final String model;
  final String effort;
  final String context;
}

/// Resposta estruturada do coordenador.
sealed class OrqCoordinatorReply {
  const OrqCoordinatorReply();
}

class OrqAnswer extends OrqCoordinatorReply {
  const OrqAnswer(this.answer);
  final String answer;
}

class OrqPlanReply extends OrqCoordinatorReply {
  const OrqPlanReply(this.title, this.tasks);
  final String title;
  final List<OrqTask> tasks;
}

class OrqHandoffReply extends OrqCoordinatorReply {
  const OrqHandoffReply(this.handoff);
  final OrqHandoffRequest handoff;
}

/// Erro de plano com mensagem para o usuário.
class OrqPlanException implements Exception {
  const OrqPlanException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _idPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$', caseSensitive: false);
final _branchPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$');

/// Lê a resposta do coordenador: JSON (puro ou em bloco ```json) com
/// `mode` = answer | plan | handoff (port de `parsePlanResponse`).
OrqCoordinatorReply parseCoordinatorReply(String text) {
  final source = text.trim();
  final fenced = RegExp(
    r'```(?:json)?\s*([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(source);
  final candidate = fenced != null ? fenced.group(1)!.trim() : source;
  final start = candidate.indexOf('{');
  final end = candidate.lastIndexOf('}');
  if (start < 0 || end <= start) {
    // Parece um plano incompleto: erro (pedir de novo).
    if (source.contains('"mode"')) {
      throw const OrqPlanException(
        'O coordenador devolveu um plano que não é JSON válido. Peça o plano '
        'novamente.',
      );
    }
    // Sem JSON: trata como resposta em texto (o coordenador conversou).
    if (source.isNotEmpty) return OrqAnswer(source);
    throw const OrqPlanException('O coordenador não respondeu. Tente de novo.');
  }
  Object? parsed;
  try {
    parsed = jsonDecode(candidate.substring(start, end + 1));
  } on FormatException {
    throw const OrqPlanException(
      'O coordenador devolveu um plano que não é JSON válido. Peça o plano '
      'novamente.',
    );
  }
  if (parsed is! Map ||
      !{'answer', 'plan', 'handoff'}.contains(parsed['mode'])) {
    throw const OrqPlanException(
      'O coordenador devolveu um modo de resposta desconhecido.',
    );
  }
  final json = Map<String, dynamic>.from(parsed);
  switch (json['mode']) {
    case 'answer':
      return OrqAnswer('${json['answer'] ?? ''}'.trim());
    case 'handoff':
      final raw = json['handoff'];
      if (raw is! Map) {
        throw const OrqPlanException(
          'A transferência estruturada está ausente.',
        );
      }
      String field(String key, int max) {
        final value = '${raw[key] ?? ''}'.trim();
        return value.length > max ? value.substring(0, max) : value;
      }

      final handoff = OrqHandoffRequest(
        runId: field('runId', 120),
        taskId: field('taskId', 40),
        provider: field('provider', 40),
        profileId: field('profileId', 120),
        model: field('model', 160),
        effort: field('effort', 40),
        context: field('context', 5000),
      );
      if (handoff.runId.isEmpty ||
          !_idPattern.hasMatch(handoff.taskId) ||
          !orqProviders.contains(handoff.provider) ||
          handoff.provider == 'auto' ||
          handoff.context.isEmpty) {
        throw const OrqPlanException(
          'A transferência precisa identificar uma tarefa válida, o agente de '
          'destino e o contexto.',
        );
      }
      return OrqHandoffReply(handoff);
    default:
      final plan = validatePlan(json['plan']);
      return plan;
  }
}

/// Valida o plano (port de `validatePlan`): 1–12 tarefas, IDs únicos,
/// dependências existentes e sem ciclos, critérios de conclusão e worktrees
/// que não sejam usadas por tarefas em paralelo.
OrqPlanReply validatePlan(Object? input) {
  if (input is! Map || input['tasks'] is! List) {
    throw const OrqPlanException(
      'O plano precisa conter entre 1 e 12 tarefas.',
    );
  }
  final rawTasks = input['tasks'] as List;
  if (rawTasks.isEmpty || rawTasks.length > 12) {
    throw const OrqPlanException(
      'O plano precisa conter entre 1 e 12 tarefas.',
    );
  }
  final ids = <String>{};
  final tasks = <OrqTask>[];
  for (var index = 0; index < rawTasks.length; index++) {
    final item = rawTasks[index] is Map
        ? Map<String, dynamic>.from(rawTasks[index] as Map)
        : <String, dynamic>{};
    final id = '${item['id'] ?? 'task-${index + 1}'}'.trim();
    if (!_idPattern.hasMatch(id) || ids.contains(id)) {
      throw OrqPlanException('ID de tarefa inválido ou repetido: $id');
    }
    ids.add(id);
    final title = '${item['title'] ?? ''}'.trim();
    final description = '${item['description'] ?? ''}'.trim();
    final worktree = _cut('${item['worktree'] ?? ''}', 100);
    final base = '${item['base'] ?? ''}'.trim();
    if (base.isNotEmpty &&
        (base.length > 200 ||
            !_branchPattern.hasMatch(base) ||
            base.contains('..') ||
            base.contains('//') ||
            base.endsWith('/') ||
            base.endsWith('.'))) {
      throw OrqPlanException(
        'A branch base da tarefa $id precisa ser um nome de branch local '
        'válido.',
      );
    }
    if (base.isNotEmpty && worktree == 'current') {
      throw OrqPlanException(
        'A tarefa $id usa o checkout atual e não pode definir uma branch base.',
      );
    }
    final criteria = item['acceptanceCriteria'] is List
        ? [
            for (final c in item['acceptanceCriteria'] as List)
              if ('$c'.trim().isNotEmpty) '$c'.trim(),
          ].take(12).toList()
        : <String>[];
    final rawCost = item['estimatedCostUsd'];
    double? cost;
    if (rawCost != null && rawCost != '') {
      cost = rawCost is num ? rawCost.toDouble() : double.tryParse('$rawCost');
      if (cost == null || cost < 0 || cost > 100000) {
        throw OrqPlanException(
          'A estimativa de custo da tarefa $id precisa ser um valor em USD '
          'entre 0 e 100000.',
        );
      }
    }
    if (title.isEmpty ||
        title.length > 160 ||
        description.isEmpty ||
        description.length > 4000 ||
        criteria.isEmpty ||
        criteria.any((c) => c.length > 500) ||
        criteria.join().length > 1500) {
      throw OrqPlanException(
        'A tarefa $id precisa de título, descrição e critérios de conclusão.',
      );
    }
    final provider = '${item['provider'] ?? 'auto'}'.trim().toLowerCase();
    tasks.add(
      OrqTask(
        id: id,
        title: title,
        description: description,
        acceptanceCriteria: criteria,
        dependsOn: item['dependsOn'] is List
            ? {for (final d in item['dependsOn'] as List) '$d'}.toList()
            : [],
        provider: orqProviders.contains(provider) ? provider : 'auto',
        profileId: _cut('${item['profileId'] ?? ''}', 120),
        model: _cut('${item['model'] ?? ''}', 160),
        effort: _cut('${item['effort'] ?? ''}', 40),
        target: OrqTarget.parse(item['target']),
        worktree: worktree,
        base: base,
        estimatedCostUsd: cost,
      ),
    );
  }
  final byId = {for (final t in tasks) t.id: t};
  for (final task in tasks) {
    for (final dep in task.dependsOn) {
      if (!ids.contains(dep)) {
        throw OrqPlanException(
          'A tarefa ${task.id} depende do ID inexistente $dep.',
        );
      }
      if (dep == task.id) {
        throw OrqPlanException(
          'A tarefa ${task.id} não pode depender de si mesma.',
        );
      }
    }
  }
  final visiting = <String>{};
  final visited = <String>{};
  void visit(String id) {
    if (visiting.contains(id)) {
      throw const OrqPlanException('O plano contém dependências circulares.');
    }
    if (visited.contains(id)) return;
    visiting.add(id);
    for (final dep in byId[id]!.dependsOn) {
      visit(dep);
    }
    visiting.remove(id);
    visited.add(id);
  }

  for (final task in tasks) {
    visit(task.id);
  }
  bool dependsOnTransitively(String taskId, String expected) => byId[taskId]!
      .dependsOn
      .any((dep) => dep == expected || dependsOnTransitively(dep, expected));
  final owners = <String, OrqTask>{};
  for (final task in tasks) {
    if (task.worktree.isEmpty || task.target == OrqTarget.gestor) continue;
    final key = branchIdentity(task.worktree);
    final owner = owners[key];
    if (owner != null &&
        !dependsOnTransitively(task.id, owner.id) &&
        !dependsOnTransitively(owner.id, task.id)) {
      throw OrqPlanException(
        'As tarefas ${owner.id} e ${task.id} poderiam executar em paralelo na '
        'mesma worktree (${task.worktree}). Use nomes distintos ou declare a '
        'dependência entre elas.',
      );
    }
    owners.putIfAbsent(key, () => task);
  }
  final title = _cut('${input['title'] ?? 'Plano de trabalho'}', 160);
  return OrqPlanReply(title.isEmpty ? 'Plano de trabalho' : title, tasks);
}

/// Identidade de um nome de branch/worktree (sem maiúsculas e caracteres
/// inválidos), para detectar colisões.
String branchIdentity(String name) {
  final value = name
      .replaceAll(RegExp(r'[^A-Za-z0-9._/-]+'), '-')
      .toLowerCase();
  return value.length > 100 ? value.substring(0, 100) : value;
}

String _cut(String value, int max) {
  final trimmed = value.trim();
  return trimmed.length > max ? trimmed.substring(0, max) : trimmed;
}

final _handoffAction = RegExp(
  r'\b(?:handoff|transfer(?:ir)?|transfira|transfere|trocar de agente|troque de agente|mudar de agente|mude de agente|substituir o agente|substitua o agente|outro agente continuar|continue com outro agente|switch agents?|change agents?|replace the agent)\b',
  caseSensitive: false,
);
final _handoffNegated = RegExp(
  r'\b(?:nao|não|never|do not|don\x27t|should not)\s+(?:(?:the|this|a|o|current|agente|agent|tarefa|task)\s+){0,2}(?:handoff|transfer(?:ir)?|transfira|transfere|trocar|troque|mudar|mude|substituir|substitua|switch|change|replace)\b',
  caseSensitive: false,
);

/// O usuário pediu explicitamente para trocar o agente de uma tarefa.
bool explicitHandoffRequest(String text) =>
    _handoffAction.hasMatch(text) && !_handoffNegated.hasMatch(text);

/// Uma transferência só é aceita se o usuário pediu ou se a tarefa falhou
/// ou está bloqueada.
bool handoffPermitted(OrqTask task, String userText) =>
    task.status == OrqTaskStatus.blocked ||
    task.status == OrqTaskStatus.failed ||
    task.error.trim().isNotEmpty ||
    explicitHandoffRequest(userText);
