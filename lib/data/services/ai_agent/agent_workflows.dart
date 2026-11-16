import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/platform/services/gestor_paths.dart';

/// Checkpoint storage shared by Agent UFU workflows in every module.
///
/// Each event is persisted as it happens so a workflow can resume after an
/// app restart and its final report can be handed to a developer.
class AgentWorkflows {
  AgentWorkflows._();

  static const _prefix = 'agent_ufu_workflow_v1_';
  static const _uuid = Uuid();

  static Future<Map<String, Object?>> start({
    required String module,
    required String title,
    required String goal,
    List<String> steps = const [],
  }) async {
    if (module.trim().isEmpty || title.trim().isEmpty || goal.trim().isEmpty) {
      throw ArgumentError(
        'Informe m\u00f3dulo, t\u00edtulo e objetivo do fluxo.',
      );
    }
    final now = DateTime.now().toIso8601String();
    final id = _uuid.v4();
    final workflow = <String, dynamic>{
      'id': id,
      'module': module.trim(),
      'title': title.trim(),
      'goal': goal.trim(),
      'status': 'running',
      'createdAt': now,
      'updatedAt': now,
      'steps': [
        for (var i = 0; i < steps.length; i++)
          {'number': i + 1, 'name': steps[i], 'status': 'pending'},
      ],
      'events': <Map<String, Object?>>[],
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(id), jsonEncode(workflow));
    return _public(workflow);
  }

  static Future<Map<String, Object?>> checkpoint({
    required String id,
    required String step,
    required String status,
    String detail = '',
    String evidence = '',
    String error = '',
  }) async {
    const valid = {'running', 'succeeded', 'failed', 'waiting_user'};
    if (step.trim().isEmpty) throw ArgumentError('Informe a etapa do fluxo.');
    if (!valid.contains(status)) {
      throw ArgumentError('Status de etapa inv\u00e1lido: $status.');
    }
    final workflow = await _read(id);
    final event = <String, Object?>{
      'at': DateTime.now().toIso8601String(),
      'step': step.trim(),
      'status': status,
      if (detail.trim().isNotEmpty) 'detail': detail.trim(),
      if (evidence.trim().isNotEmpty) 'evidence': evidence.trim(),
      if (error.trim().isNotEmpty) 'error': error.trim(),
    };
    final events = (workflow['events'] as List).cast<Map>();
    events.add(event);
    if (events.length > 300) events.removeRange(0, events.length - 300);
    workflow['updatedAt'] = event['at'];
    workflow['status'] = status == 'waiting_user' ? 'waiting_user' : 'running';
    final steps = (workflow['steps'] as List).cast<Map>();
    for (final item in steps) {
      if ('${item['name']}' == step.trim()) item['status'] = status;
    }
    await _write(id, workflow);
    return _public(workflow);
  }

  static Future<Map<String, Object?>> requestUser({
    required String id,
    required String question,
    String step = 'A\u00e7\u00e3o do usu\u00e1rio',
    String detail = '',
  }) {
    if (question.trim().isEmpty) throw ArgumentError('Informe a pergunta.');
    return checkpoint(
      id: id,
      step: step,
      status: 'waiting_user',
      detail: detail,
      evidence: 'Pergunta ao usu\u00e1rio: ${question.trim()}',
    );
  }

  static Future<Map<String, Object?>> get(String id) async =>
      _public(await _read(id));

  static Future<List<Map<String, Object?>>> list({int limit = 20}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final workflows = <Map<String, Object?>>[];
    for (final key in prefs.getKeys().where((key) => key.startsWith(_prefix))) {
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        workflows.add(_public(Map<String, dynamic>.from(jsonDecode(raw))));
      } on Object {
        // Ignore malformed historical entries; a valid workflow remains usable.
      }
    }
    workflows.sort(
      (a, b) => '${b['updatedAt']}'.compareTo('${a['updatedAt']}'),
    );
    return workflows.take(limit.clamp(1, 100).toInt()).toList();
  }

  static Future<Map<String, Object?>> finish({
    required String id,
    required String outcome,
    required String summary,
  }) async {
    const valid = {'completed', 'handoff'};
    if (!valid.contains(outcome)) {
      throw ArgumentError('Resultado deve ser completed ou handoff.');
    }
    final workflow = await _read(id);
    workflow
      ..['status'] = outcome
      ..['summary'] = summary.trim()
      ..['updatedAt'] = DateTime.now().toIso8601String();
    await _write(id, workflow);
    final report = _report(workflow);
    final filePath = await GestorPaths.outputPath(
      null,
      'fluxo_agente_${id.substring(0, 8)}.md',
      sub: 'fluxos_agente',
    );
    await File(filePath).writeAsString(report, flush: true);
    return {..._public(workflow), 'report': report, 'reportPath': filePath};
  }

  static Future<Map<String, dynamic>> _read(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key(id));
    if (raw == null) {
      throw StateError('Fluxo de agente "$id" n\u00e3o encontrado.');
    }
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  static Future<void> _write(String id, Map<String, dynamic> workflow) async {
    await (await SharedPreferences.getInstance()).setString(
      _key(id),
      jsonEncode(workflow),
    );
  }

  static String _key(String id) => '$_prefix${id.trim()}';

  static Map<String, Object?> _public(Map<String, dynamic> workflow) =>
      Map<String, Object?>.from(workflow);

  static String _report(Map<String, dynamic> workflow) {
    final out = StringBuffer()
      ..writeln('# Relat\u00f3rio do fluxo do Agente UFU')
      ..writeln()
      ..writeln('- **ID:** ${workflow['id']}')
      ..writeln('- **M\u00f3dulo:** ${workflow['module']}')
      ..writeln('- **Fluxo:** ${workflow['title']}')
      ..writeln('- **Estado:** ${workflow['status']}')
      ..writeln('- **Objetivo:** ${workflow['goal']}')
      ..writeln('- **Iniciado:** ${workflow['createdAt']}')
      ..writeln('- **Atualizado:** ${workflow['updatedAt']}')
      ..writeln()
      ..writeln('## Etapas registradas')
      ..writeln();
    for (final raw in workflow['events'] as List? ?? const []) {
      final event = Map<String, dynamic>.from(raw as Map);
      out
        ..writeln('### ${event['step']} \u2014 ${event['status']}')
        ..writeln()
        ..writeln('- **Hor\u00e1rio:** ${event['at']}');
      if (event['detail'] != null) {
        out.writeln('- **Detalhe:** ${event['detail']}');
      }
      if (event['evidence'] != null) {
        out.writeln('- **Evid\u00eancia:** ${event['evidence']}');
      }
      if (event['error'] != null) {
        out.writeln('- **Erro:** ${event['error']}');
      }
      out.writeln();
    }
    out
      ..writeln('## Resultado / repasse')
      ..writeln()
      ..writeln(workflow['summary'] ?? 'Sem resumo final.');
    return out.toString();
  }
}
