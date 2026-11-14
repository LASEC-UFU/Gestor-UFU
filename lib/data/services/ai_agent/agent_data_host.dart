import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/data/services/ai_agent/agent_skills.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';
import 'package:gestor_ufu/data/services/shared_preferences_sync_service.dart';

/// Executa, na janela principal, as ferramentas pedidas pela janela do
/// Agente de IA. Centralizar aqui garante que o cache do SharedPreferences
/// desta janela continue coerente e que as páginas abertas sejam recarregadas.
class AgentDataHost {
  AgentDataHost._();
  static final instance = AgentDataHost._();

  static const _termsKey = 'ajusta_horarios_periodos_letivos';
  static const _termKey = 'ajusta_horarios_periodo_letivo';
  static const _maxUndo = 100;
  static const _defaultReadLimit = 60000;

  /// Incrementado após cada gravação do agente; a árvore de páginas usa este
  /// valor como chave para se reconstruir e recarregar os dados.
  final revision = ValueNotifier<int>(0);

  /// Rota exibida na janela principal (atualizada pelo app).
  String? Function()? currentRoute;

  /// Chamado após gravações para invalidar caches de controladores.
  Future<void> Function()? onDataChanged;

  final _undo = <_UndoEntry>[];
  WindowMethodChannel? _channel;

  int get undoCount => _undo.length;

  bool get isRunning => _channel != null;

  Future<void> start() async {
    if (_channel != null) return;
    final channel = WindowMethodChannel(
      agentToolChannelName,
      mode: ChannelMode.bidirectional,
    );
    await channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map
          ? Map<String, dynamic>.from(call.arguments as Map)
          : <String, dynamic>{};
      switch (call.method) {
        case 'tool':
          return runTool(
            args['name'] as String,
            Map<String, dynamic>.from(
              jsonDecode(args['input'] as String? ?? '{}') as Map,
            ),
          );
        case 'undo':
          return undoLast();
        case 'undoCount':
          return _undo.length;
        case 'currentSkill':
          return AgentSkills.idForRoute(currentRoute?.call());
      }
      throw MissingPluginException('Método não reconhecido: ${call.method}');
    });
    _channel = channel;
  }

  /// Executa uma ferramenta e devolve o resultado como texto JSON.
  Future<String> runTool(String name, Map<String, dynamic> input) async {
    try {
      final result = await _dispatch(name, input);
      return jsonEncode(result);
    } on _ToolError catch (error) {
      return jsonEncode({'error': error.message});
    } catch (error) {
      return jsonEncode({'error': '$error'});
    }
  }

  Future<Object?> _dispatch(String name, Map<String, dynamic> input) async {
    final prefs = await SharedPreferences.getInstance();
    switch (name) {
      case 'get_app_context':
        final route = currentRoute?.call();
        return {
          'activeTerm': prefs.getString(_termKey),
          'terms': prefs.getStringList(_termsKey) ?? const <String>[],
          'currentRoute': route,
          'currentModule': AgentSkills.idForRoute(route),
          'undoAvailable': _undo.length,
          'today': DateTime.now().toIso8601String().substring(0, 10),
        };
      case 'list_modules':
        return [
          for (final skill in AgentSkills.all)
            {'id': skill.id, 'title': skill.title, 'summary': skill.summary},
        ];
      case 'get_skill':
        final skill = AgentSkills.byId('${input['module']}');
        if (skill == null) throw _ToolError('Módulo desconhecido.');
        return {'id': skill.id, 'title': skill.title, 'skill': skill.body};
      case 'list_keys':
        final prefix = '${input['prefix'] ?? ''}';
        final keys =
            prefs
                .getKeys()
                .where((key) => key.startsWith(prefix) && !_isProtected(key))
                .toList()
              ..sort();
        return [
          for (final key in keys) {'key': key, ..._describe(prefs.get(key))},
        ];
      case 'term_storage_key':
        final token = base64Url
            .encode(utf8.encode('${input['term']}'.trim()))
            .replaceAll('=', '');
        return {'key': '${input['prefix']}$token'};
      case 'read_key':
        return _read(prefs, input);
      case 'patch_json':
        return _patch(prefs, input);
      case 'write_key':
        return _write(prefs, input);
      case 'delete_key':
        final key = _checkedKey(input);
        if (!prefs.containsKey(key)) return {'ok': true, 'existed': false};
        _pushUndo(key, prefs.get(key));
        await prefs.remove(key);
        await _changed();
        return {'ok': true, 'existed': true};
    }
    throw _ToolError('Ferramenta desconhecida: $name');
  }

  Map<String, Object?> _read(
    SharedPreferences prefs,
    Map<String, dynamic> input,
  ) {
    final key = _checkedKey(input);
    if (!prefs.containsKey(key)) {
      return {'key': key, 'exists': false};
    }
    final raw = prefs.get(key);
    Object? value = raw;
    var isJson = false;
    if (raw is String) {
      final decoded = _tryDecode(raw);
      if (decoded.$1) {
        value = decoded.$2;
        isJson = true;
      }
    }
    final path = _readPath(input['path']);
    if (path.isNotEmpty) value = _get(value, path);
    final text = value is String && !isJson ? value : jsonEncode(value);
    final offset = ((input['offset'] as num?)?.toInt() ?? 0).clamp(
      0,
      text.length,
    );
    final limit = ((input['limit'] as num?)?.toInt() ?? _defaultReadLimit)
        .clamp(1, 200000);
    final end = (offset + limit).clamp(0, text.length);
    return {
      'key': key,
      'exists': true,
      'storedType': _typeName(raw),
      'isJson': isJson,
      'totalChars': text.length,
      'offset': offset,
      'truncated': end < text.length,
      'content': text.substring(offset, end),
    };
  }

  Future<Map<String, Object?>> _patch(
    SharedPreferences prefs,
    Map<String, dynamic> input,
  ) async {
    final key = _checkedKey(input);
    final operations = (input['operations'] as List? ?? const []);
    if (operations.isEmpty) throw _ToolError('Nenhuma operação informada.');
    final raw = prefs.get(key);
    if (raw != null && raw is! String) {
      throw _ToolError(
        'A chave guarda ${_typeName(raw)}, não JSON. Use write_key.',
      );
    }
    Object? root;
    if (raw is String && raw.trim().isNotEmpty) {
      final decoded = _tryDecode(raw);
      if (!decoded.$1) throw _ToolError('O valor atual não é JSON válido.');
      root = decoded.$2;
    }
    for (final item in operations) {
      final op = Map<String, dynamic>.from(item as Map);
      final path = _readPath(op['path']);
      root ??= path.isNotEmpty && path.first is int ? <Object?>[] : {};
      root = _apply(root, '${op['op']}', path, op['value']);
    }
    _pushUndo(key, raw);
    await prefs.setString(key, jsonEncode(root));
    await _changed();
    return {'ok': true, 'key': key, 'operations': operations.length};
  }

  Future<Map<String, Object?>> _write(
    SharedPreferences prefs,
    Map<String, dynamic> input,
  ) async {
    final key = _checkedKey(input);
    final value = input['value'];
    final type = '${input['value_type'] ?? 'json'}';
    final previous = prefs.get(key);
    _pushUndo(key, previous);
    switch (type) {
      case 'string':
        await prefs.setString(key, value is String ? value : '$value');
      case 'string_list':
        if (value is! List) throw _ToolError('value precisa ser uma lista.');
        await prefs.setStringList(key, value.map((e) => '$e').toList());
      case 'bool':
        await prefs.setBool(key, value == true || value == 'true');
      case 'int':
        await prefs.setInt(key, (value as num).toInt());
      case 'double':
        await prefs.setDouble(key, (value as num).toDouble());
      default:
        Object? json = value;
        if (value is String) {
          final decoded = _tryDecode(value);
          if (decoded.$1) json = decoded.$2;
        }
        await prefs.setString(key, jsonEncode(json));
    }
    await _changed();
    return {'ok': true, 'key': key, 'previousExisted': previous != null};
  }

  Future<Map<String, Object?>> undoLast() async {
    if (_undo.isEmpty) return {'ok': false, 'message': 'Nada para desfazer.'};
    final entry = _undo.removeLast();
    final prefs = await SharedPreferences.getInstance();
    final value = entry.previous;
    if (value == null) {
      await prefs.remove(entry.key);
    } else if (value is String) {
      await prefs.setString(entry.key, value);
    } else if (value is bool) {
      await prefs.setBool(entry.key, value);
    } else if (value is int) {
      await prefs.setInt(entry.key, value);
    } else if (value is double) {
      await prefs.setDouble(entry.key, value);
    } else if (value is List) {
      await prefs.setStringList(entry.key, value.cast<String>());
    }
    await _changed();
    return {'ok': true, 'key': entry.key, 'remaining': _undo.length};
  }

  void _pushUndo(String key, Object? previous) {
    _undo.add(
      _UndoEntry(
        key,
        previous is List ? List<String>.of(previous.cast()) : previous,
      ),
    );
    if (_undo.length > _maxUndo) _undo.removeAt(0);
  }

  Future<void> _changed() async {
    try {
      await onDataChanged?.call();
    } finally {
      revision.value++;
    }
  }

  // ---------------------------------------------------------------- helpers

  String _checkedKey(Map<String, dynamic> input) {
    final key = '${input['key'] ?? ''}'.trim();
    if (key.isEmpty) throw _ToolError('Informe a chave.');
    if (_isProtected(key)) {
      throw _ToolError('Chave protegida: credenciais não são acessíveis.');
    }
    return key;
  }

  static bool _isProtected(String key) {
    final lower = key.toLowerCase();
    return key.startsWith(SharedPreferencesSyncService.metadataPrefix) ||
        lower.contains('credential') ||
        lower.contains('password') ||
        lower.contains('senha') ||
        lower.contains('token');
  }

  static (bool, Object?) _tryDecode(String raw) {
    final trimmed = raw.trimLeft();
    if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) {
      return (false, null);
    }
    try {
      return (true, jsonDecode(raw));
    } on FormatException {
      return (false, null);
    }
  }

  static Map<String, Object?> _describe(Object? value) {
    if (value is String) {
      final json = _tryDecode(value);
      return {
        'type': json.$1 ? 'json' : 'string',
        'chars': value.length,
        if (json.$2 is List) 'items': (json.$2 as List).length,
        if (json.$2 is Map) 'entries': (json.$2 as Map).length,
      };
    }
    if (value is List) return {'type': 'string_list', 'items': value.length};
    return {'type': _typeName(value), 'value': value};
  }

  static String _typeName(Object? value) => switch (value) {
    null => 'null',
    String() => 'string',
    bool() => 'bool',
    int() => 'int',
    double() => 'double',
    List() => 'string_list',
    _ => value.runtimeType.toString(),
  };

  static List<Object> _readPath(Object? raw) {
    if (raw == null) return const [];
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return const [];
      final decoded = _tryDecode(trimmed);
      if (decoded.$1 && decoded.$2 is List) return _readPath(decoded.$2);
      return [trimmed];
    }
    if (raw is! List) throw _ToolError('path precisa ser uma lista.');
    return [
      for (final segment in raw)
        if (segment is num) segment.toInt() else '$segment',
    ];
  }

  static Object? _get(Object? root, List<Object> path) {
    var node = root;
    for (final segment in path) {
      if (node is Map) {
        if (!node.containsKey('$segment')) {
          throw _ToolError('Caminho inexistente: ${jsonEncode(path)}');
        }
        node = node['$segment'];
      } else if (node is List && segment is int) {
        if (segment < 0 || segment >= node.length) {
          throw _ToolError('Índice fora da lista: $segment');
        }
        node = node[segment];
      } else {
        throw _ToolError('Caminho inválido: ${jsonEncode(path)}');
      }
    }
    return node;
  }

  static Object? _apply(
    Object? root,
    String op,
    List<Object> path,
    Object? value,
  ) {
    if (path.isEmpty) {
      return switch (op) {
        'set' => value,
        'merge' => {..._asMap(root), ..._asMap(value)},
        'append' => [...(root as List? ?? const []), value],
        'delete' => throw _ToolError('Não é possível apagar a raiz.'),
        _ => throw _ToolError('Operação desconhecida: $op'),
      };
    }
    final parent = _container(root, path.sublist(0, path.length - 1), op);
    final last = path.last;
    if (parent is Map) {
      final key = '$last';
      switch (op) {
        case 'set':
          parent[key] = value;
        case 'merge':
          parent[key] = {..._asMap(parent[key]), ..._asMap(value)};
        case 'append':
          parent[key] = [...(parent[key] as List? ?? const []), value];
        case 'delete':
          parent.remove(key);
        default:
          throw _ToolError('Operação desconhecida: $op');
      }
    } else if (parent is List) {
      if (last is! int) throw _ToolError('Use índice inteiro para listas.');
      final inRange = last >= 0 && last < parent.length;
      switch (op) {
        case 'set':
          if (last == parent.length) {
            parent.add(value);
          } else if (inRange) {
            parent[last] = value;
          } else {
            throw _ToolError('Índice fora da lista: $last');
          }
        case 'merge':
          if (!inRange) throw _ToolError('Índice fora da lista: $last');
          parent[last] = {..._asMap(parent[last]), ..._asMap(value)};
        case 'append':
          if (!inRange) throw _ToolError('Índice fora da lista: $last');
          parent[last] = [...(parent[last] as List? ?? const []), value];
        case 'delete':
          if (!inRange) throw _ToolError('Índice fora da lista: $last');
          parent.removeAt(last);
        default:
          throw _ToolError('Operação desconhecida: $op');
      }
    } else {
      throw _ToolError('Caminho inválido: ${jsonEncode(path)}');
    }
    return root;
  }

  /// Navega até o contêiner do último segmento, criando objetos/listas
  /// intermediários em operações de escrita.
  static Object? _container(Object? root, List<Object> path, String op) {
    var node = root;
    for (var i = 0; i < path.length; i++) {
      final segment = path[i];
      final nextIsIndex = i + 1 < path.length ? path[i + 1] is int : false;
      Object? child;
      if (node is Map) {
        child = node['$segment'];
        if (child == null && op != 'delete') {
          child = nextIsIndex ? <Object?>[] : <String, Object?>{};
          node['$segment'] = child;
        }
      } else if (node is List && segment is int) {
        if (segment < 0 || segment >= node.length) {
          throw _ToolError('Índice fora da lista: $segment');
        }
        child = node[segment];
      } else {
        throw _ToolError('Caminho inválido: ${jsonEncode(path)}');
      }
      node = child;
    }
    return node;
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value == null) return {};
    if (value is Map) return Map<String, Object?>.from(value);
    throw _ToolError('merge exige objetos JSON.');
  }
}

class _UndoEntry {
  _UndoEntry(this.key, this.previous);
  final String key;
  final Object? previous;
}

class _ToolError implements Exception {
  _ToolError(this.message);
  final String message;
}
