import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';

/// Item exibido no chat do agente.
/// [thought] = "Pensou por Xs" (o texto guarda os segundos).
enum AgentEntryKind { user, agent, tool, thought, info, error }

class AgentEntry {
  AgentEntry(
    this.kind,
    String text, {
    DateTime? time,
    this.attachments = const [],
    this.toolName,
    this.toolInput,
    this.toolResult,
    this.toolError = false,
    this.running = false,
  }) : time = time ?? DateTime.now(),
       buffer = StringBuffer(text);

  final AgentEntryKind kind;
  final StringBuffer buffer;
  final DateTime time;
  final List<String> attachments;
  final String? toolName;
  final Map<String, dynamic>? toolInput;
  String? toolResult;
  bool toolError;

  /// Ferramenta em execução ou texto ainda chegando.
  bool running;

  String get text => buffer.toString();

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    'time': time.toIso8601String(),
    if (attachments.isNotEmpty) 'attachments': attachments,
    if (toolName != null) 'toolName': toolName,
    if (toolInput != null) 'toolInput': toolInput,
    if (toolResult != null) 'toolResult': toolResult,
    if (toolError) 'toolError': true,
  };

  factory AgentEntry.fromJson(Map<String, dynamic> json) => AgentEntry(
    AgentEntryKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => AgentEntryKind.info,
    ),
    '${json['text'] ?? ''}',
    time: DateTime.tryParse('${json['time']}'),
    attachments: [
      ...(json['attachments'] as List? ?? const []).map((e) => '$e'),
    ],
    toolName: json['toolName'] as String?,
    toolInput: json['toolInput'] is Map
        ? Map<String, dynamic>.from(json['toolInput'] as Map)
        : null,
    toolResult: json['toolResult'] as String?,
    toolError: json['toolError'] == true,
  );
}

/// Conversa guardada no histórico (como a lista "Chats" da extensão).
class AgentConversation {
  AgentConversation({
    required this.id,
    required this.provider,
    required this.mode,
    this.title = '',
    this.skill = 'geral',
    DateTime? updatedAt,
    List<AgentEntry>? entries,
    Map<String, dynamic>? state,
  }) : updatedAt = updatedAt ?? DateTime.now(),
       entries = entries ?? [],
       state = state ?? {};

  final String id;
  String provider;
  String mode;
  String title;
  String skill;
  DateTime updatedAt;
  final List<AgentEntry> entries;

  /// Estado do back-end (id da sessão do CLI ou mensagens da API).
  Map<String, dynamic> state;

  bool get hasMessages => entries.any((e) => e.kind == AgentEntryKind.user);

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider,
    'mode': mode,
    'title': title,
    'skill': skill,
    'updatedAt': updatedAt.toIso8601String(),
    'entries': [
      for (final e in entries)
        if (e.kind != AgentEntryKind.info) e.toJson(),
    ],
    'state': state,
  };

  /// Versão enxuta para o banco sincronizado: resultados de ferramentas
  /// encurtados e estado do back-end descartado se for grande demais (a
  /// conversa então continua pela transcrição).
  Map<String, dynamic> toSyncJson() {
    final json = toJson();
    for (final entry
        in (json['entries'] as List).cast<Map<String, dynamic>>()) {
      final result = entry['toolResult'];
      if (result is String && result.length > 3000) {
        entry['toolResult'] = '${result.substring(0, 3000)}\n…';
      }
    }
    if (jsonEncode(state).length > 300000) {
      json['state'] = {
        for (final e in state.entries)
          if (e.value is! List && e.value is! Map) e.key: e.value,
      };
    }
    return json;
  }

  /// Transcrição da conversa para o agente continuar quando a sessão
  /// original não está disponível (outro computador, sessão expirada…).
  String transcript({int maxChars = 30000}) {
    final buffer = StringBuffer();
    for (final e in entries) {
      switch (e.kind) {
        case AgentEntryKind.user:
          buffer.writeln('Usuário: ${e.text}');
        case AgentEntryKind.agent:
          buffer.writeln('Agente: ${e.text}');
        case AgentEntryKind.tool:
          buffer.writeln(
            '[ferramenta ${e.toolName}: ${jsonEncode(e.toolInput ?? {})}]',
          );
        case AgentEntryKind.thought:
        case AgentEntryKind.info:
        case AgentEntryKind.error:
          break;
      }
    }
    final text = buffer.toString();
    return text.length <= maxChars
        ? text
        : '…${text.substring(text.length - maxChars)}';
  }

  factory AgentConversation.fromJson(Map<String, dynamic> json) =>
      AgentConversation(
        id: '${json['id']}',
        provider: '${json['provider'] ?? 'claude'}',
        mode: '${json['mode'] ?? 'cli'}',
        title: '${json['title'] ?? ''}',
        skill: '${json['skill'] ?? 'geral'}',
        updatedAt: DateTime.tryParse('${json['updatedAt']}'),
        entries: [
          for (final e
              in (json['entries'] as List? ?? const []).whereType<Map>())
            AgentEntry.fromJson(Map<String, dynamic>.from(e)),
        ],
        state: Map<String, dynamic>.from(json['state'] as Map? ?? const {}),
      );
}

/// Histórico das conversas, guardado no banco do Gestor (SharedPreferences)
/// e por isso sincronizado com os outros computadores pelo arquivo
/// compartilhado. A gravação é feita pela janela principal (dona do banco),
/// por meio do canal do agente.
class AgentHistory {
  static const keyPrefix = 'gestor_ufu_agente_conversa_v1_';
  static const limit = 100;

  static const _channel = WindowMethodChannel(
    agentToolChannelName,
    mode: ChannelMode.bidirectional,
  );

  /// Resumo (sem as mensagens) de todas as conversas, mais recentes primeiro.
  static Future<List<AgentConversation>> list() async {
    await _migrateLocal();
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('historyList');
      final result = <AgentConversation>[
        for (final item in raw ?? const [])
          if (item is String)
            AgentConversation.fromJson(
              Map<String, dynamic>.from(jsonDecode(item) as Map),
            ),
      ];
      result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return result;
    } catch (_) {
      return [];
    }
  }

  static Future<AgentConversation?> load(String id) async {
    try {
      final raw = await _channel.invokeMethod<String>('historyLoad', {
        'id': id,
      });
      if (raw == null) return null;
      return AgentConversation.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(AgentConversation conversation) async {
    if (!conversation.hasMessages) return;
    await _channel.invokeMethod<bool>('historySave', {
      'id': conversation.id,
      'json': jsonEncode(conversation.toSyncJson()),
    });
  }

  static Future<void> delete(String id) async {
    try {
      await _channel.invokeMethod<bool>('historyDelete', {'id': id});
    } catch (_) {}
  }

  static bool _migrated = false;

  /// Leva para o banco as conversas da versão anterior, que ficavam só em
  /// %APPDATA%\GestorUFU\agente\conversas.
  static Future<void> _migrateLocal() async {
    if (_migrated) return;
    _migrated = true;
    final base = Platform.environment['APPDATA'];
    if (base == null) return;
    final dir = Directory(p.join(base, 'GestorUFU', 'agente', 'conversas'));
    if (!await dir.exists()) return;
    await for (final file in dir.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        await save(AgentConversation.fromJson(json));
        await file.delete();
      } catch (_) {}
    }
  }
}
