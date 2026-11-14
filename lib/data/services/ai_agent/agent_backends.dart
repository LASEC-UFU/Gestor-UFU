import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/ai_agent/agent_mcp_server.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';

/// Anexo enviado junto com uma mensagem. Textos (planilhas convertidas,
/// CSV, JSON…) vão em [text]; imagens e PDFs em [bytes].
class AgentAttachment {
  AgentAttachment({
    required this.name,
    required this.mimeType,
    this.text,
    this.bytes,
    this.localPath,
  });

  final String name;
  final String mimeType;
  final String? text;
  final List<int>? bytes;
  final String? localPath;

  bool get isImage => mimeType.startsWith('image/');
  bool get isPdf => mimeType == 'application/pdf';
}

sealed class AgentEvent {
  const AgentEvent();
}

class AgentTextEvent extends AgentEvent {
  const AgentTextEvent(this.text);
  final String text;
}

class AgentToolEvent extends AgentEvent {
  const AgentToolEvent(this.name, this.input);
  final String name;
  final Map<String, dynamic> input;
}

class AgentInfoEvent extends AgentEvent {
  const AgentInfoEvent(this.text);
  final String text;
}

typedef AgentEventSink = void Function(AgentEvent event);

class AgentException implements Exception {
  AgentException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AgentBackend {
  /// Instruções de sistema (base + skill) usadas ao iniciar a conversa.
  String systemPrompt = '';

  String get label;

  /// Verifica credenciais/instalação. Lança [AgentException] se falhar.
  Future<String> verify();

  /// Envia a mensagem do usuário e executa o ciclo de ferramentas até a
  /// resposta final.
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  );

  void reset();

  Future<void> cancel() async {}

  Future<void> dispose() async {}
}

// ================================================================ Claude API

class ClaudeApiBackend extends AgentBackend {
  ClaudeApiBackend({
    required this.apiKey,
    required this.model,
    required this.callTool,
  });

  final String apiKey;
  final String model;
  final AgentToolCaller callTool;
  final _messages = <Map<String, dynamic>>[];
  http.Client? _client;

  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  @override
  String get label => 'Claude (chave de API · $model)';

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2026-10-21',
    'anthropic-beta': 'server-side-fallback-2026-07-01',
  };

  @override
  Future<String> verify() async {
    final response = await http.get(
      Uri.parse('https://api.anthropic.com/v1/models/$model'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw AgentException(_apiError('Claude', response));
    }
    return 'Chave de API da Anthropic válida.';
  }

  @override
  void reset() => _messages.clear();

  @override
  Future<void> cancel() async {
    _client?.close();
    _client = null;
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    _messages.add({
      'role': 'user',
      'content': [
        for (final attachment in attachments) _attachmentBlock(attachment),
        {'type': 'text', 'text': prompt},
      ],
    });
    final client = _client = http.Client();
    try {
      for (var round = 0; round < 40; round++) {
        final response = await client
            .post(
              _endpoint,
              headers: _headers,
              body: jsonEncode({
                'model': model,
                'max_tokens': 16000,
                'fallbacks': 'default',
                'output_config': {'effort': 'high'},
                'system': [
                  {
                    'type': 'text',
                    'text': systemPrompt,
                    'cache_control': {'type': 'ephemeral'},
                  },
                ],
                'tools': [
                  for (final tool in agentTools)
                    {
                      'name': tool.name,
                      'description': tool.description,
                      'input_schema': tool.schema,
                    },
                ],
                'messages': _messages,
              }),
            )
            .timeout(const Duration(minutes: 10));
        if (response.statusCode != 200) {
          // Remove a pergunta para que o usuário possa reenviar.
          if (round == 0) _messages.removeLast();
          throw AgentException(_apiError('Claude', response));
        }
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final content = (data['content'] as List).cast<Map>();
        // A resposta volta para o histórico sem alterações (inclui blocos de
        // raciocínio e de fallback, que a API exige na ordem original).
        _messages.add({'role': 'assistant', 'content': content});
        for (final block in content) {
          if (block['type'] == 'text') {
            final text = '${block['text']}'.trim();
            if (text.isNotEmpty) emit(AgentTextEvent(text));
          }
        }
        final stopReason = data['stop_reason'];
        if (stopReason == 'refusal') {
          final details = data['stop_details'] as Map?;
          throw AgentException(
            'O modelo recusou a solicitação'
            '${details?['explanation'] != null ? ': ${details!['explanation']}' : '.'}',
          );
        }
        if (stopReason == 'max_tokens') {
          emit(const AgentInfoEvent('Resposta interrompida pelo limite de tokens.'));
          return;
        }
        if (stopReason != 'tool_use') return;

        final results = <Map<String, dynamic>>[];
        for (final block in content.where((b) => b['type'] == 'tool_use')) {
          final name = block['name'] as String;
          final input = Map<String, dynamic>.from(block['input'] as Map? ?? {});
          emit(AgentToolEvent(name, input));
          final result = await callTool(name, input);
          results.add({
            'type': 'tool_result',
            'tool_use_id': block['id'],
            'content': result,
            if (result.startsWith('{"error"')) 'is_error': true,
          });
        }
        _messages.add({'role': 'user', 'content': results});
      }
      emit(const AgentInfoEvent('Limite de etapas atingido nesta resposta.'));
    } on http.ClientException catch (error) {
      if (_client == null) throw AgentException('Cancelado.');
      throw AgentException('Falha de conexão: ${error.message}');
    } finally {
      client.close();
      _client = null;
    }
  }

  Map<String, dynamic> _attachmentBlock(AgentAttachment attachment) {
    if (attachment.isImage && attachment.bytes != null) {
      return {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': attachment.mimeType,
          'data': base64Encode(attachment.bytes!),
        },
      };
    }
    if (attachment.isPdf && attachment.bytes != null) {
      return {
        'type': 'document',
        'title': attachment.name,
        'source': {
          'type': 'base64',
          'media_type': 'application/pdf',
          'data': base64Encode(attachment.bytes!),
        },
      };
    }
    return {
      'type': 'text',
      'text': 'Anexo "${attachment.name}":\n${attachment.text ?? ''}',
    };
  }
}

// ================================================================ OpenAI API

class OpenAiApiBackend extends AgentBackend {
  OpenAiApiBackend({
    required this.apiKey,
    required this.model,
    required this.callTool,
  });

  final String apiKey;
  final String model;
  final AgentToolCaller callTool;
  final _messages = <Map<String, dynamic>>[];
  http.Client? _client;

  @override
  String get label => 'ChatGPT (chave de API · $model)';

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'authorization': 'Bearer $apiKey',
  };

  @override
  Future<String> verify() async {
    final response = await http.get(
      Uri.parse('https://api.openai.com/v1/models/$model'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw AgentException(_apiError('OpenAI', response));
    }
    return 'Chave de API da OpenAI válida.';
  }

  @override
  void reset() => _messages.clear();

  @override
  Future<void> cancel() async {
    _client?.close();
    _client = null;
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    _messages.add({
      'role': 'user',
      'content': [
        for (final attachment in attachments) _attachmentPart(attachment),
        {'type': 'text', 'text': prompt},
      ],
    });
    final client = _client = http.Client();
    try {
      for (var round = 0; round < 40; round++) {
        final response = await client
            .post(
              Uri.parse('https://api.openai.com/v1/chat/completions'),
              headers: _headers,
              body: jsonEncode({
                'model': model,
                'messages': [
                  {'role': 'system', 'content': systemPrompt},
                  ..._messages,
                ],
                'tools': [
                  for (final tool in agentTools)
                    {
                      'type': 'function',
                      'function': {
                        'name': tool.name,
                        'description': tool.description,
                        'parameters': tool.schema,
                      },
                    },
                ],
              }),
            )
            .timeout(const Duration(minutes: 10));
        if (response.statusCode != 200) {
          if (round == 0) _messages.removeLast();
          throw AgentException(_apiError('OpenAI', response));
        }
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final choice = (data['choices'] as List).first as Map;
        final message = Map<String, dynamic>.from(choice['message'] as Map);
        _messages.add(message);
        final text = '${message['content'] ?? ''}'.trim();
        if (text.isNotEmpty) emit(AgentTextEvent(text));
        final calls = (message['tool_calls'] as List?) ?? const [];
        if (calls.isEmpty) return;
        for (final call in calls.cast<Map>()) {
          final function = call['function'] as Map;
          final name = function['name'] as String;
          Map<String, dynamic> input;
          try {
            input = Map<String, dynamic>.from(
              jsonDecode('${function['arguments'] ?? '{}'}') as Map,
            );
          } catch (_) {
            input = {};
          }
          emit(AgentToolEvent(name, input));
          final result = await callTool(name, input);
          _messages.add({
            'role': 'tool',
            'tool_call_id': call['id'],
            'content': result,
          });
        }
      }
      emit(const AgentInfoEvent('Limite de etapas atingido nesta resposta.'));
    } on http.ClientException catch (error) {
      if (_client == null) throw AgentException('Cancelado.');
      throw AgentException('Falha de conexão: ${error.message}');
    } finally {
      client.close();
      _client = null;
    }
  }

  Map<String, dynamic> _attachmentPart(AgentAttachment attachment) {
    if (attachment.isImage && attachment.bytes != null) {
      return {
        'type': 'image_url',
        'image_url': {
          'url':
              'data:${attachment.mimeType};base64,${base64Encode(attachment.bytes!)}',
        },
      };
    }
    if (attachment.isPdf && attachment.bytes != null) {
      return {
        'type': 'file',
        'file': {
          'filename': attachment.name,
          'file_data':
              'data:application/pdf;base64,${base64Encode(attachment.bytes!)}',
        },
      };
    }
    return {
      'type': 'text',
      'text': 'Anexo "${attachment.name}":\n${attachment.text ?? ''}',
    };
  }
}

String _apiError(String provider, http.Response response) {
  var detail = response.body;
  try {
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    final error = json is Map ? json['error'] : null;
    if (error is Map && error['message'] != null) detail = '${error['message']}';
  } catch (_) {}
  final hint = switch (response.statusCode) {
    401 || 403 => ' Verifique a chave de API.',
    404 => ' Verifique o nome do modelo.',
    429 => ' Limite de uso atingido; tente novamente em instantes.',
    _ => '',
  };
  return '$provider respondeu ${response.statusCode}: $detail.$hint';
}

// ======================================================= CLIs (assinatura)

/// Base para os CLIs oficiais (Claude Code e Codex), que usam o login da
/// assinatura do próprio usuário. As ferramentas chegam a eles pelo
/// [AgentMcpServer] local.
abstract class _CliBackend extends AgentBackend {
  _CliBackend({
    required this.provider,
    required this.mcp,
    required this.configuredPath,
    required this.model,
  });

  final AgentProvider provider;
  final AgentMcpServer mcp;
  final String configuredPath;
  final String model;
  String? sessionId;
  Process? _process;
  String? _resolved;

  @override
  void reset() => sessionId = null;

  @override
  Future<void> cancel() async {
    _process?.kill();
    _process = null;
  }

  Future<String> executable() async {
    if (_resolved != null) return _resolved!;
    if (configuredPath.isNotEmpty) {
      if (!await File(configuredPath).exists()) {
        throw AgentException('Executável não encontrado: $configuredPath');
      }
      return _resolved = configuredPath;
    }
    final name = provider.cliName;
    final candidates = <String>[];
    try {
      final where = await Process.run('where', [name]);
      candidates.addAll(
        '${where.stdout}'
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty),
      );
    } catch (_) {}
    final home = Platform.environment['USERPROFILE'] ?? '';
    final appData = Platform.environment['APPDATA'] ?? '';
    candidates.addAll([
      p.join(home, '.local', 'bin', '$name.exe'),
      p.join(appData, 'npm', '$name.cmd'),
    ]);
    for (final candidate in candidates) {
      final lower = candidate.toLowerCase();
      if (!(lower.endsWith('.exe') || lower.endsWith('.cmd'))) continue;
      if (await File(candidate).exists()) return _resolved = candidate;
    }
    throw AgentException(
      'Não encontrei o "${provider.cliName}". Instale com '
      '"npm install -g ${provider == AgentProvider.claude ? '@anthropic-ai/claude-code' : '@openai/codex'}" '
      'ou informe o caminho do executável nas configurações do agente.',
    );
  }

  Future<Process> _start(List<String> args) async {
    final exe = await executable();
    return Process.start(
      exe,
      args,
      runInShell: exe.toLowerCase().endsWith('.cmd'),
      workingDirectory: Directory.systemTemp.path,
      environment: const {'NO_COLOR': '1'},
    );
  }

  @override
  Future<String> verify() async {
    final exe = await executable();
    final result = await Process.run(
      exe,
      ['--version'],
      runInShell: exe.toLowerCase().endsWith('.cmd'),
    );
    if (result.exitCode != 0) {
      throw AgentException('Falha ao executar $exe: ${result.stderr}');
    }
    return '${provider.cliName} ${'${result.stdout}'.trim()} encontrado.';
  }

  /// Abre um terminal com o fluxo de login do CLI.
  Future<void> openLoginTerminal() async {
    final exe = await executable();
    final loginArgs = provider == AgentProvider.claude
        ? '"$exe"'
        : '"$exe" login';
    await Process.start('cmd', [
      '/c',
      'start',
      'Login ${provider.label}',
      'cmd',
      '/k',
      loginArgs,
    ], mode: ProcessStartMode.detached);
  }

  String _composePrompt(String prompt, List<AgentAttachment> attachments) {
    final buffer = StringBuffer();
    if (sessionId == null) {
      buffer
        ..writeln('<instrucoes_do_gestor_ufu>')
        ..writeln(systemPrompt)
        ..writeln(
          'As ferramentas do Gestor UFU estão no servidor MCP '
          '"${AgentMcpServer.serverName}". Use somente elas para acessar os '
          'dados; não edite arquivos nem rode comandos.',
        )
        ..writeln('</instrucoes_do_gestor_ufu>')
        ..writeln();
    }
    for (final attachment in attachments) {
      if (attachment.text != null) {
        buffer
          ..writeln('<anexo nome="${attachment.name}">')
          ..writeln(attachment.text)
          ..writeln('</anexo>');
      } else if (attachment.localPath != null) {
        buffer.writeln(
          'Anexo "${attachment.name}" salvo em: ${attachment.localPath} '
          '(leia o arquivo para usar o conteúdo).',
        );
      }
    }
    buffer.write(prompt);
    return buffer.toString();
  }

  Future<void> _run(
    List<String> args,
    String stdinText,
    void Function(Map<String, dynamic> event) onEvent,
  ) async {
    final process = _process = await _start(args);
    final errors = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(errors.write)
        .asFuture<void>();
    process.stdin.add(utf8.encode(stdinText));
    await process.stdin.close();
    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        onEvent(Map<String, dynamic>.from(jsonDecode(trimmed) as Map));
      } on FormatException {
        continue;
      }
    }
    final code = await process.exitCode;
    await stderrDone;
    if (_process == null) throw AgentException('Cancelado.');
    _process = null;
    if (code != 0) {
      final message = errors.toString().trim();
      throw AgentException(
        '${provider.cliName} terminou com código $code'
        '${message.isEmpty ? '' : ':\n$message'}',
      );
    }
  }
}

class ClaudeCliBackend extends _CliBackend {
  ClaudeCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.claude);

  @override
  String get label => 'Claude (assinatura via Claude Code)';

  Future<String> _mcpConfigFile() async {
    final dir = await Directory.systemTemp.createTemp('gestor_ufu_agent_');
    final file = File(p.join(dir.path, 'mcp.json'));
    await file.writeAsString(
      jsonEncode({
        'mcpServers': {
          AgentMcpServer.serverName: {'type': 'http', 'url': mcp.url},
        },
      }),
    );
    return file.path;
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    final config = await _mcpConfigFile();
    final args = [
      '-p',
      '--output-format',
      'stream-json',
      '--verbose',
      '--mcp-config',
      config,
      '--strict-mcp-config',
      '--allowedTools',
      'mcp__${AgentMcpServer.serverName}',
      'Read',
      '--disallowedTools',
      'Bash',
      'Edit',
      'Write',
      if (model.isNotEmpty) ...['--model', model],
      if (sessionId != null) ...['--resume', sessionId!],
    ];
    var isError = false;
    String? errorText;
    try {
      await _run(args, _composePrompt(prompt, attachments), (event) {
        final id = event['session_id'];
        if (id is String && id.isNotEmpty) sessionId = id;
        switch (event['type']) {
          case 'assistant':
            final message = event['message'] as Map? ?? const {};
            for (final block in (message['content'] as List? ?? const [])
                .whereType<Map>()) {
              if (block['type'] == 'text') {
                final text = '${block['text']}'.trim();
                if (text.isNotEmpty) emit(AgentTextEvent(text));
              }
            }
          case 'result':
            isError = event['is_error'] == true;
            if (isError) errorText = '${event['result'] ?? event['subtype']}';
        }
      });
    } finally {
      try {
        await File(config).parent.delete(recursive: true);
      } catch (_) {}
    }
    if (isError) {
      throw AgentException(
        'Claude Code: ${errorText ?? 'erro desconhecido'}. Se for problema '
        'de login, use "Entrar" nas configurações do agente.',
      );
    }
  }
}

class CodexCliBackend extends _CliBackend {
  CodexCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.chatgpt);

  @override
  String get label => 'ChatGPT (assinatura via Codex)';

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    final args = [
      'exec',
      '--json',
      '--skip-git-repo-check',
      '--sandbox',
      'read-only',
      '-c',
      'mcp_servers.${AgentMcpServer.serverName}.url=${mcp.url}',
      '-c',
      'approval_policy=never',
      if (model.isNotEmpty) ...['-m', model],
      if (sessionId != null) ...['resume', sessionId!],
      '-',
    ];
    String? failure;
    await _run(args, _composePrompt(prompt, attachments), (event) {
      switch (event['type']) {
        case 'thread.started':
          final id = event['thread_id'];
          if (id is String) sessionId = id;
        case 'item.completed':
          final item = event['item'] as Map? ?? const {};
          if (item['type'] == 'agent_message') {
            final text = '${item['text'] ?? ''}'.trim();
            if (text.isNotEmpty) emit(AgentTextEvent(text));
          } else if (item['type'] == 'error') {
            failure = '${item['message']}';
          }
        case 'turn.failed':
        case 'error':
          final error = event['error'];
          failure = error is Map
              ? '${error['message']}'
              : '${event['message'] ?? error}';
      }
    });
    if (failure != null) {
      throw AgentException(
        'Codex: $failure. Se for problema de login, use "Entrar" nas '
        'configurações do agente.',
      );
    }
  }
}

/// Facilita a chamada de [_CliBackend.openLoginTerminal] fora deste arquivo.
Future<void> openCliLogin(AgentBackend backend) async {
  if (backend is _CliBackend) await backend.openLoginTerminal();
}
