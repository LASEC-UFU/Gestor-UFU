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

/// Modelo disponível para a conta conectada. [id] vazio = padrão do CLI.
class AgentModel {
  const AgentModel(this.id, this.label, {this.isDefault = false});
  final String id;
  final String label;
  final bool isDefault;
}

abstract class AgentBackend {
  /// Instruções de sistema (base + skill) usadas ao iniciar a conversa.
  String systemPrompt = '';

  String get label;

  /// Verifica credenciais/instalação. Lança [AgentException] se falhar.
  Future<String> verify();

  /// Modelos que a conta conectada pode usar, consultados no provedor.
  Future<List<AgentModel>> listModels();

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
    final models = await listModels();
    return 'Chave de API da Anthropic válida (${models.length} modelos).';
  }

  @override
  Future<List<AgentModel>> listModels() async {
    final models = <AgentModel>[];
    String? afterId;
    do {
      final response = await http.get(
        Uri.parse('https://api.anthropic.com/v1/models').replace(
          queryParameters: {
            'limit': '1000',
            if (afterId != null) 'after_id': afterId,
          },
        ),
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw AgentException(_apiError('Claude', response));
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      for (final item in (data['data'] as List? ?? const []).cast<Map>()) {
        final id = '${item['id']}';
        models.add(AgentModel(id, '${item['display_name'] ?? id}  ·  $id'));
      }
      afterId = data['has_more'] == true ? data['last_id'] as String? : null;
    } while (afterId != null);
    return models;
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
          emit(
            const AgentInfoEvent(
              'Resposta interrompida pelo limite de tokens.',
            ),
          );
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
    final models = await listModels();
    return 'Chave de API da OpenAI válida (${models.length} modelos).';
  }

  /// Ignora modelos que não conversam (embeddings, áudio, imagem…).
  static final _nonChat = RegExp(
    r'embedding|whisper|tts|dall-e|davinci|babbage|moderation|image|audio|'
    r'realtime|transcribe|search|sora',
  );

  @override
  Future<List<AgentModel>> listModels() async {
    final response = await http.get(
      Uri.parse('https://api.openai.com/v1/models'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw AgentException(_apiError('OpenAI', response));
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final items = (data['data'] as List? ?? const []).cast<Map>().toList()
      ..sort(
        (a, b) => ((b['created'] as num?) ?? 0).compareTo(
          (a['created'] as num?) ?? 0,
        ),
      );
    return [
      for (final item in items)
        if (!_nonChat.hasMatch('${item['id']}'))
          AgentModel('${item['id']}', '${item['id']}'),
    ];
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
    if (error is Map && error['message'] != null)
      detail = '${error['message']}';
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
abstract class CliAgentBackend extends AgentBackend {
  CliAgentBackend({
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
      '"npm install -g ${provider.npmPackage}" '
      'ou informe o caminho do executável nas configurações do agente.',
    );
  }

  /// Pasta onde o CLI roda (o Gemini CLI lê a configuração MCP dela).
  Future<String> workingDirectory() async => Directory.systemTemp.path;

  /// Variáveis extras para o processo do CLI.
  Map<String, String> get environment => const {'NO_COLOR': '1'};

  Future<Process> _start(List<String> args) async {
    final exe = await executable();
    return Process.start(
      exe,
      args,
      runInShell: exe.toLowerCase().endsWith('.cmd'),
      workingDirectory: await workingDirectory(),
      environment: environment,
    );
  }

  /// O CLI está instalado neste computador?
  Future<bool> isInstalled() async {
    try {
      await executable();
      return true;
    } on AgentException {
      return false;
    }
  }

  /// Instala o CLI oficial com o npm (requer Node.js).
  Future<void> install(void Function(String line) onOutput) async {
    final process = await Process.start('npm', [
      'install',
      '-g',
      provider.npmPackage,
    ], runInShell: true);
    final output = _merge(process)
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isNotEmpty) onOutput(line.trim());
        });
    final code = await process.exitCode;
    await output.cancel();
    _resolved = null;
    if (code != 0) {
      throw AgentException(
        'Não foi possível instalar ${provider.cliProductName} (npm terminou '
        'com código $code). Verifique se o Node.js está instalado.',
      );
    }
  }

  /// A conta já está logada no CLI?
  Future<bool> isLoggedIn();

  /// Abre o login no navegador e espera terminar. [onOutput] recebe as
  /// linhas do CLI (por exemplo, o link caso o navegador não abra).
  Future<void> loginWithBrowser(void Function(String line) onOutput) async {
    final process = await _start(provider.loginArgs);
    await process.stdin.close();
    final output = _merge(process)
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final clean = line
              .replaceAll(RegExp(r'\x1B\[[0-9;?]*[A-Za-z]'), '')
              .trim();
          if (clean.isNotEmpty) onOutput(clean);
        });
    _process = process;
    final code = await process.exitCode;
    await output.cancel();
    _process = null;
    if (code != 0 || !await isLoggedIn()) {
      throw AgentException(
        'O login no ${provider.cliProductName} não foi concluído.',
      );
    }
  }

  @override
  Future<String> verify() async {
    final exe = await executable();
    final result = await Process.run(exe, [
      '--version',
    ], runInShell: exe.toLowerCase().endsWith('.cmd'));
    if (result.exitCode != 0) {
      throw AgentException('Falha ao executar $exe: ${result.stderr}');
    }
    return '${provider.cliProductName} ${'${result.stdout}'.trim()} encontrado.';
  }

  /// Abre um terminal com o fluxo de login do CLI.
  Future<void> openLoginTerminal() async {
    final exe = await executable();
    final loginArgs = ['"$exe"', ...provider.loginArgs].join(' ');
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

class ClaudeCliBackend extends CliAgentBackend {
  ClaudeCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.claude);

  @override
  String get label => 'Claude (assinatura via Claude Code)';

  @override
  Future<bool> isLoggedIn() async {
    try {
      final process = await _start(['auth', 'status', '--json']);
      await process.stdin.close();
      final out = await process.stdout.transform(utf8.decoder).join();
      await process.exitCode;
      final start = out.indexOf('{');
      if (start < 0) return false;
      final json = jsonDecode(out.substring(start)) as Map;
      return json['loggedIn'] == true;
    } catch (_) {
      return false;
    }
  }

  /// O Claude Code não tem comando para listar modelos; estes são os mesmos
  /// apelidos do seletor da extensão do VS Code, resolvidos pelo próprio CLI
  /// para a versão mais recente liberada na assinatura.
  @override
  Future<List<AgentModel>> listModels() async => const [
    AgentModel('', 'Padrão (recomendado pelo Claude Code)', isDefault: true),
    AgentModel('opus', 'Opus'),
    AgentModel('sonnet', 'Sonnet'),
    AgentModel('haiku', 'Haiku'),
  ];

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
      // Só a leitura de anexos entre as ferramentas nativas; o resto do
      // acesso é pelas ferramentas do Gestor (MCP).
      '--tools',
      'Read',
      '--allowedTools',
      'mcp__${AgentMcpServer.serverName}',
      'Read',
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
            for (final block
                in (message['content'] as List? ?? const []).whereType<Map>()) {
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

class CodexCliBackend extends CliAgentBackend {
  CodexCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.chatgpt);

  @override
  String get label => 'ChatGPT (assinatura via Codex)';

  @override
  Future<bool> isLoggedIn() async {
    try {
      final process = await _start(['login', 'status']);
      await process.stdin.close();
      final out = await _merge(process).transform(utf8.decoder).join();
      final code = await process.exitCode;
      return code == 0 && out.toLowerCase().contains('logged in');
    } catch (_) {
      return false;
    }
  }

  /// Pergunta ao `codex app-server` (o mesmo usado pela extensão do VS Code)
  /// quais modelos a conta ChatGPT pode usar.
  @override
  Future<List<AgentModel>> listModels() async {
    final exe = await executable();
    final process = await Process.start(
      exe,
      ['app-server'],
      runInShell: exe.toLowerCase().endsWith('.cmd'),
      workingDirectory: await workingDirectory(),
    );
    final completer = Completer<List<AgentModel>>();
    final sub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (completer.isCompleted || !line.trim().startsWith('{')) return;
          try {
            final message = jsonDecode(line) as Map;
            if (message['id'] != 2) return;
            if (message['error'] != null) {
              completer.completeError(
                AgentException('${(message['error'] as Map)['message']}'),
              );
              return;
            }
            final result = message['result'] as Map? ?? const {};
            final raw =
                (result['data'] ?? result['models'] ?? result['items'])
                    as List? ??
                const [];
            completer.complete([
              for (final item in raw.whereType<Map>())
                if (item['hidden'] != true)
                  AgentModel(
                    '${item['model'] ?? item['id'] ?? item['slug']}',
                    '${item['displayName'] ?? item['display_name'] ?? item['model'] ?? item['id']}',
                    isDefault: item['isDefault'] == true,
                  ),
            ]);
          } on FormatException {
            return;
          }
        });
    void send(Map<String, Object?> message) =>
        process.stdin.writeln(jsonEncode(message));
    try {
      send({
        'method': 'initialize',
        'id': 1,
        'params': {
          'clientInfo': {
            'name': 'gestor_ufu',
            'title': 'Gestor UFU',
            'version': '1.0.0',
          },
        },
      });
      send({'method': 'initialized'});
      send({'method': 'model/list', 'id': 2, 'params': {}});
      final models = await completer.future.timeout(
        const Duration(seconds: 20),
      );
      if (models.isEmpty) throw AgentException('lista vazia');
      return models;
    } catch (_) {
      // Versões antigas do Codex não têm model/list.
      return const [
        AgentModel('', 'Padrão (definido no Codex)', isDefault: true),
        AgentModel('gpt-5', 'gpt-5'),
        AgentModel('gpt-5-codex', 'gpt-5-codex'),
      ];
    } finally {
      await sub.cancel();
      process.kill();
    }
  }

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

class GeminiCliBackend extends CliAgentBackend {
  GeminiCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.gemini);

  @override
  String get label => 'Gemini (assinatura via Gemini CLI)';

  /// Usa o login Google (Code Assist) e confia na pasta de trabalho, onde
  /// fica a configuração do servidor MCP do Gestor.
  @override
  Map<String, String> get environment => const {
    'NO_COLOR': '1',
    'GOOGLE_GENAI_USE_GCA': 'true',
    'GEMINI_CLI_TRUST_WORKSPACE': 'true',
  };

  @override
  Future<bool> isLoggedIn() async {
    final home = Platform.environment['USERPROFILE'] ?? '';
    return File(p.join(home, '.gemini', 'oauth_creds.json')).exists();
  }

  /// O login do Gemini CLI só existe no modo interativo: abre um terminal
  /// com o CLI, que leva ao navegador. Espera até as credenciais existirem.
  @override
  Future<void> loginWithBrowser(void Function(String line) onOutput) async {
    await openLoginTerminal();
    onOutput('Conclua o login no terminal/navegador que foi aberto.');
    for (var i = 0; i < 180; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (await isLoggedIn()) return;
    }
    throw AgentException('Tempo esgotado aguardando o login do Gemini CLI.');
  }

  @override
  Future<List<AgentModel>> listModels() async {
    try {
      final process = await _start(['--list-models', '-o', 'json']);
      await process.stdin.close();
      final out = await process.stdout.transform(utf8.decoder).join();
      await process.exitCode;
      final start = out.indexOf('[');
      final list = jsonDecode(out.substring(start)) as List;
      return [
        for (final item in list.whereType<Map>())
          AgentModel(
            item['id'] == 'auto' ? '' : '${item['id'] ?? item['modelId']}',
            '${item['displayName'] ?? item['id']}',
            isDefault: item['id'] == 'auto',
          ),
      ];
    } catch (_) {
      return const [
        AgentModel('', 'Auto (definido no Gemini CLI)', isDefault: true),
        AgentModel('gemini-2.5-pro', 'gemini-2.5-pro'),
      ];
    }
  }

  /// Pasta fixa: o Gemini CLI guarda as sessões por projeto, então ela
  /// precisa ser a mesma para que `--resume` encontre a conversa.
  @override
  Future<String> workingDirectory() async {
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'gestor_ufu_gemini'),
    );
    final settings = File(p.join(dir.path, '.gemini', 'settings.json'));
    await settings.parent.create(recursive: true);
    // O servidor MCP local é "confiável": suas ferramentas rodam sem pedir
    // confirmação. Ferramentas de shell e de arquivos ficam excluídas.
    await settings.writeAsString(
      jsonEncode({
        'mcpServers': {
          AgentMcpServer.serverName: {'httpUrl': mcp.url, 'trust': true},
        },
        'excludeTools': ['run_shell_command', 'write_file', 'replace'],
      }),
    );
    return dir.path;
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    final args = [
      '--output-format',
      'stream-json',
      '--allowed-mcp-server-names',
      AgentMcpServer.serverName,
      if (model.isNotEmpty) ...['-m', model],
      // O Gemini CLI retoma por "latest" (a pasta de trabalho é exclusiva).
      if (sessionId != null) ...['--resume', 'latest'],
      // Modo headless: a mensagem vai pelo stdin e este texto é anexado.
      '-p',
      '.',
    ];
    final text = StringBuffer();
    String? failure;
    void flush() {
      final value = text.toString().trim();
      if (value.isNotEmpty) emit(AgentTextEvent(value));
      text.clear();
    }

    await _run(args, _composePrompt(prompt, attachments), (event) {
      final id = event['session_id'];
      if (id is String && id.isNotEmpty) sessionId = id;
      switch (event['type']) {
        case 'message':
          if (event['role'] == 'assistant') {
            text.write('${event['content'] ?? ''}');
            if (event['delta'] != true) flush();
          }
        case 'tool_use':
          flush();
        case 'error':
          failure = '${event['message'] ?? event['error']}';
        case 'result':
          flush();
          if (event['status'] == 'error') {
            final error = event['error'];
            failure = error is Map ? '${error['message']}' : '$error';
          }
      }
    });
    flush();
    if (failure != null) {
      throw AgentException(
        'Gemini CLI: $failure. Contas Google pessoais não são mais aceitas '
        'pelo Gemini CLI (o Google migrou o plano gratuito para o '
        'Antigravity); use a chave de API do Google AI Studio.',
      );
    }
  }
}

// ================================================================ Gemini API

class GeminiApiBackend extends AgentBackend {
  GeminiApiBackend({
    required this.apiKey,
    required this.model,
    required this.callTool,
  });

  final String apiKey;
  final String model;
  final AgentToolCaller callTool;
  final _contents = <Map<String, dynamic>>[];
  http.Client? _client;

  static const _base = 'https://generativelanguage.googleapis.com/v1beta';

  @override
  String get label => 'Gemini (chave de API · $model)';

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'x-goog-api-key': apiKey,
  };

  @override
  Future<String> verify() async {
    final models = await listModels();
    return 'Chave de API do Google AI Studio válida (${models.length} modelos).';
  }

  @override
  Future<List<AgentModel>> listModels() async {
    final models = <AgentModel>[];
    String? pageToken;
    do {
      final response = await http.get(
        Uri.parse('$_base/models').replace(
          queryParameters: {
            'pageSize': '1000',
            if (pageToken != null) 'pageToken': pageToken,
          },
        ),
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw AgentException(_apiError('Gemini', response));
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      for (final item in (data['models'] as List? ?? const []).cast<Map>()) {
        final methods = (item['supportedGenerationMethods'] as List? ?? []);
        if (!methods.contains('generateContent')) continue;
        final id = '${item['name']}'.replaceFirst('models/', '');
        models.add(AgentModel(id, '${item['displayName'] ?? id}  ·  $id'));
      }
      final next = data['nextPageToken'];
      pageToken = next is String && next.isNotEmpty ? next : null;
    } while (pageToken != null);
    return models;
  }

  @override
  void reset() => _contents.clear();

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
    _contents.add({
      'role': 'user',
      'parts': [
        for (final attachment in attachments) _attachmentPart(attachment),
        {'text': prompt},
      ],
    });
    final client = _client = http.Client();
    try {
      for (var round = 0; round < 40; round++) {
        final response = await client
            .post(
              Uri.parse('$_base/models/$model:generateContent'),
              headers: _headers,
              body: jsonEncode({
                'systemInstruction': {
                  'parts': [
                    {'text': systemPrompt},
                  ],
                },
                'contents': _contents,
                'tools': [
                  {
                    'functionDeclarations': [
                      for (final tool in agentTools)
                        {
                          'name': tool.name,
                          'description': tool.description,
                          'parametersJsonSchema': tool.schema,
                        },
                    ],
                  },
                ],
              }),
            )
            .timeout(const Duration(minutes: 10));
        if (response.statusCode != 200) {
          if (round == 0) _contents.removeLast();
          throw AgentException(_apiError('Gemini', response));
        }
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final candidates = (data['candidates'] as List?) ?? const [];
        if (candidates.isEmpty) {
          final feedback = data['promptFeedback'] as Map?;
          throw AgentException(
            'O Gemini não respondeu'
            '${feedback?['blockReason'] != null ? ' (bloqueado: ${feedback!['blockReason']})' : ''}.',
          );
        }
        final candidate = candidates.first as Map;
        final content = Map<String, dynamic>.from(
          candidate['content'] as Map? ?? {'role': 'model', 'parts': []},
        );
        // Mantém as partes como vieram (inclui assinaturas de raciocínio).
        _contents.add(content);
        final parts = (content['parts'] as List? ?? const []).cast<Map>();
        final text = parts
            .where((part) => part['text'] != null && part['thought'] != true)
            .map((part) => '${part['text']}')
            .join()
            .trim();
        if (text.isNotEmpty) emit(AgentTextEvent(text));
        final calls = parts.where((part) => part['functionCall'] != null);
        if (calls.isEmpty) {
          if (candidate['finishReason'] == 'MAX_TOKENS') {
            emit(
              const AgentInfoEvent(
                'Resposta interrompida pelo limite de tokens.',
              ),
            );
          }
          return;
        }
        final responses = <Map<String, dynamic>>[];
        for (final part in calls) {
          final call = part['functionCall'] as Map;
          final name = '${call['name']}';
          final input = Map<String, dynamic>.from(call['args'] as Map? ?? {});
          emit(AgentToolEvent(name, input));
          final result = await callTool(name, input);
          Object? decoded;
          try {
            decoded = jsonDecode(result);
          } catch (_) {
            decoded = result;
          }
          responses.add({
            'functionResponse': {
              'name': name,
              if (call['id'] != null) 'id': call['id'],
              'response': decoded is Map ? decoded : {'result': decoded},
            },
          });
        }
        _contents.add({'role': 'user', 'parts': responses});
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
    if ((attachment.isImage || attachment.isPdf) && attachment.bytes != null) {
      return {
        'inlineData': {
          'mimeType': attachment.mimeType,
          'data': base64Encode(attachment.bytes!),
        },
      };
    }
    return {'text': 'Anexo "${attachment.name}":\n${attachment.text ?? ''}'};
  }
}

Stream<List<int>> _merge(Process process) {
  final controller = StreamController<List<int>>();
  var open = 2;
  void done() {
    if (--open == 0) controller.close();
  }

  process.stdout.listen(controller.add, onDone: done);
  process.stderr.listen(controller.add, onDone: done);
  return controller.stream;
}

/// Facilita a chamada de [CliAgentBackend.openLoginTerminal] fora deste arquivo.
Future<void> openCliLogin(AgentBackend backend) async {
  if (backend is CliAgentBackend) await backend.openLoginTerminal();
}
