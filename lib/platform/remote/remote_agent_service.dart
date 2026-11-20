import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:gestor_ufu/data/services/ai_agent/agent_backends.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_data_host.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_mcp_server.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_skills.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';

class RemoteAgentService {
  AgentBackend? _backend;
  AgentMcpServer? _mcp;
  final _approvals = <String, _RemoteApproval>{};
  bool _busy = false;
  bool _cancelRequested = false;
  String? _lastError;
  final _history = <Map<String, Object?>>[];
  Map<String, dynamic> _savedBackendState = const {};
  File get _stateFile => File(
    p.join(
      Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
      'GestorUFU',
      'RemoteFiles',
      'agent-state.json',
    ),
  );
  Future<void> Function(Map<String, Object?> event)? onEvent;
  bool get busy => _busy;
  String? get lastError => _lastError;
  Future<String> Function(String commandId, Map<String, dynamic> input)?
  executeCommand;
  static const _gestorTools = <String>{
    'get_app_context',
    'list_modules',
    'get_skill',
    'list_keys',
    'read_key',
    'patch_json',
    'write_key',
    'delete_key',
    'list_commands',
    'run_command',
    'list_templates',
    'create_template',
    'workflow_start',
    'workflow_checkpoint',
    'workflow_request_user',
    'workflow_get',
    'workflow_list',
    'workflow_finish',
  };

  Future<void> _connect() async {
    if (_backend != null) return;
    if (_history.isEmpty && _savedBackendState.isEmpty) await _loadState();
    final settings = await AgentSettings.load();
    final provider = settings.provider;
    final mode = settings.modeFor(provider);
    final model = settings.modelFor(provider, mode);
    AgentBackend backend;
    if (mode == AgentAuthMode.apiKey) {
      final key = await AgentSettings.readApiKey(provider);
      if (key == null)
        throw AgentException(
          'O provedor do Agente ainda não tem uma chave de API configurada no Windows.',
        );
      Future<String> caller(String name, Map<String, dynamic> input) =>
          _callTool(name, input, settings);
      backend = switch (provider) {
        AgentProvider.claude => ClaudeApiBackend(
          apiKey: key,
          model: model,
          callTool: caller,
        ),
        AgentProvider.chatgpt => OpenAiApiBackend(
          apiKey: key,
          model: model,
          callTool: caller,
        ),
        AgentProvider.gemini => GeminiApiBackend(
          apiKey: key,
          model: model,
          callTool: caller,
        ),
        AgentProvider.copilot => throw AgentException(
          'O Copilot requer autenticação pelo CLI, não chave de API.',
        ),
      };
    } else {
      final mcp = AgentMcpServer(
        (name, input) => _callTool(name, input, settings),
        toolFilter: _gestorTools,
        onPermission: (tool, input) => _requestApproval(tool, input),
      );
      await mcp.start();
      _mcp = mcp;
      backend = switch (provider) {
        AgentProvider.claude => ClaudeCliBackend(
          mcp: mcp,
          configuredPath: settings.cliPathFor(provider),
          model: model,
        ),
        AgentProvider.chatgpt => CodexCliBackend(
          mcp: mcp,
          configuredPath: settings.cliPathFor(provider),
          model: model,
        ),
        AgentProvider.gemini => GeminiCliBackend(
          mcp: mcp,
          configuredPath: settings.cliPathFor(provider),
          model: model,
        ),
        AgentProvider.copilot => CopilotCliBackend(
          mcp: mcp,
          configuredPath: settings.cliPathFor(provider),
          model: model,
        ),
      };
    }
    backend
      ..access = AgentAccess.gestor
      ..toolFilter = _gestorTools
      ..effort = settings.effort
      ..systemPrompt = AgentSkills.systemPrompt(AgentSkills.general);
    backend.restoreState(_savedBackendState);
    _backend = backend;
  }

  Future<bool> send(String text) async {
    if (text.trim().isEmpty)
      throw AgentException('Diga ou escreva uma solicitação.');
    if (_busy)
      throw AgentException(
        'O Agente já está atendendo outra solicitação neste celular.',
      );
    _busy = true;
    _cancelRequested = false;
    _lastError = null;
    try {
      await _connect();
      if (_cancelRequested) return false;
      final output = StringBuffer();
      _history.add({
        'role': 'user',
        'text': text.trim(),
        'time': DateTime.now().toUtc().toIso8601String(),
      });
      await _persistState();
      await _backend!.send(text.trim(), const [], (event) {
        switch (event) {
          case AgentTextEvent(:final text):
            output
              ..clear()
              ..write(text);
            unawaited(
              onEvent?.call({
                'type': 'agent_text',
                'text': text,
                'final': true,
              }),
            );
          case AgentTextDeltaEvent(:final text):
            output.write(text);
            unawaited(
              onEvent?.call({
                'type': 'agent_text',
                'text': text,
                'final': false,
              }),
            );
          case AgentToolEvent(:final name, :final input):
            unawaited(
              onEvent?.call({
                'type': 'agent_tool',
                'name': name,
                'input': input,
              }),
            );
          case AgentToolResultEvent(:final id, :final result):
            unawaited(
              onEvent?.call({
                'type': 'agent_tool_result',
                'id': id,
                'result': result,
              }),
            );
          case AgentThinkingEvent():
            unawaited(
              onEvent?.call({'type': 'agent_status', 'status': 'thinking'}),
            );
          case AgentInfoEvent(:final text):
            unawaited(onEvent?.call({'type': 'agent_status', 'status': text}));
          case AgentTextBreakEvent():
            output.writeln();
        }
      });
      if (_cancelRequested) return false;
      if (output.isEmpty)
        throw AgentException('O agente não devolveu resposta.');
      _history.add({
        'role': 'assistant',
        'text': output.toString().trim(),
        'time': DateTime.now().toUtc().toIso8601String(),
      });
      if (_history.length > 100) _history.removeRange(0, _history.length - 100);
      await _persistState();
      return true;
    } catch (error) {
      if (_cancelRequested) return false;
      _lastError = '$error';
      rethrow;
    } finally {
      _busy = false;
      _cancelRequested = false;
    }
  }

  Future<bool> cancel() async {
    if (!_busy) return false;
    _cancelRequested = true;
    for (final item in _approvals.values) {
      if (!item.completer.isCompleted) item.completer.complete(false);
    }
    try {
      await _backend?.cancel();
    } catch (error) {
      _cancelRequested = false;
      _lastError = 'Não foi possível interromper o agente: $error';
      rethrow;
    }
    return true;
  }

  List<Map<String, Object?>> get history => List.unmodifiable(_history);

  Future<void> _loadState() async {
    try {
      if (!await _stateFile.exists()) return;
      final data = Map<String, dynamic>.from(
        jsonDecode(await _stateFile.readAsString()) as Map,
      );
      _savedBackendState = Map<String, dynamic>.from(
        data['backend'] as Map? ?? const {},
      );
      _history
        ..clear()
        ..addAll(
          (data['history'] as List? ?? const []).whereType<Map>().map(
            (e) => Map<String, Object?>.from(e),
          ),
        );
    } catch (_) {
      _history.clear();
      _savedBackendState = const {};
    }
  }

  Future<void> _persistState() async {
    try {
      await _stateFile.parent.create(recursive: true);
      final temporary = File('${_stateFile.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'history': _history,
          'backend': _backend?.saveState() ?? _savedBackendState,
        }),
        flush: true,
      );
      if (await _stateFile.exists()) await _stateFile.delete();
      await temporary.rename(_stateFile.path);
    } catch (_) {}
  }

  Future<String> _callTool(
    String name,
    Map<String, dynamic> input,
    AgentSettings settings,
  ) async {
    if (!_gestorTools.contains(name))
      return jsonEncode({
        'error': 'Ferramenta não permitida na conexão remota.',
      });
    if (name == 'list_commands') {
      final moduleId = '${input['module'] ?? ''}'.trim();
      return jsonEncode({
        'commands': [
          for (final module in ModuleRegistry.instance.modules)
            if (moduleId.isEmpty || module.id == moduleId)
              for (final command in module.commands)
                if (command.remoteEnabled)
                  {
                    'id': command.id,
                    'module': module.id,
                    'title': command.title,
                    'description': command.description,
                    'input': command.remoteInputSchema ?? command.inputSchema,
                    if (command.approval == CommandApproval.required)
                      'requires_approval': true,
                  },
        ],
      });
    }
    if (name == 'run_command') {
      final command = ModuleRegistry.instance.commandById(
        '${input['command'] ?? ''}',
      );
      if (command != null && !command.remoteEnabled) {
        return jsonEncode({
          'error':
              'Esta ação só navega uma tela do computador; use a operação equivalente do app móvel.',
        });
      }
      if (command?.approval == CommandApproval.required &&
          !await _requestApproval(
            'Comando: ${command!.title}',
            Map<String, dynamic>.from(input['input'] as Map? ?? const {}),
          )) {
        return jsonEncode({
          'error': 'Ação não aprovada pelo usuário no celular.',
        });
      }
      if (command != null && executeCommand != null) {
        return executeCommand!(
          command.id,
          Map<String, dynamic>.from(input['input'] as Map? ?? const {}),
        );
      }
    }
    return AgentDataHost.instance.runTool(name, input);
  }

  Future<bool> _requestApproval(String tool, Map<String, dynamic> input) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final approval = _RemoteApproval(id, tool, input);
    _approvals[id] = approval;
    await onEvent?.call({
      'type': 'approval_required',
      'id': id,
      'tool': tool,
      'input': input,
    });
    try {
      return await approval.completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => false,
      );
    } finally {
      _approvals.remove(id);
    }
  }

  List<Map<String, Object?>> get pendingApprovals => [
    for (final a in _approvals.values) a.toJson(),
  ];

  bool answer(String id, bool approved) {
    final item = _approvals[id];
    if (item == null || item.completer.isCompleted) return false;
    item.completer.complete(approved);
    return true;
  }

  Future<void> dispose() async {
    _cancelRequested = true;
    for (final item in _approvals.values) {
      if (!item.completer.isCompleted) item.completer.complete(false);
    }
    await _backend?.dispose();
    await _mcp?.stop();
    _backend = null;
    _mcp = null;
    _busy = false;
    _cancelRequested = false;
  }
}

class _RemoteApproval {
  _RemoteApproval(this.id, this.tool, this.input);
  final String id;
  final String tool;
  final Map<String, dynamic> input;
  final completer = Completer<bool>();
  Map<String, Object?> toJson() => {'id': id, 'tool': tool, 'input': input};
}
