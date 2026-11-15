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

  /// Dimensões da imagem ("382×447"), mostradas no chip do anexo.
  String? dims;

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

/// Pedaço de texto da resposta (streaming), anexado ao bloco atual.
class AgentTextDeltaEvent extends AgentEvent {
  const AgentTextDeltaEvent(this.text);
  final String text;
}

/// Início de um novo bloco de texto da resposta.
class AgentTextBreakEvent extends AgentEvent {
  const AgentTextBreakEvent();
}

/// Ferramenta iniciada pelo próprio CLI (web, comandos, Gestor…).
class AgentToolEvent extends AgentEvent {
  const AgentToolEvent(this.id, this.name, this.input);
  final String id;
  final String name;
  final Map<String, dynamic> input;
}

/// Resultado de uma ferramenta relatada por [AgentToolEvent].
class AgentToolResultEvent extends AgentEvent {
  const AgentToolResultEvent(this.id, this.result, {this.isError = false});
  final String id;
  final String result;
  final bool isError;
}

/// O modelo está raciocinando antes de responder.
class AgentThinkingEvent extends AgentEvent {
  const AgentThinkingEvent();
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

  /// O que o agente pode fazer além das ferramentas do Gestor.
  AgentAccess access = AgentAccess.gestor;

  /// Pasta de trabalho dos CLIs fora do modo "Só o Gestor".
  String workDir = '';

  /// Servidores MCP adicionais (nome → URL HTTP) entregues aos CLIs, além do
  /// servidor do Gestor (ex.: AI Memory nos agentes do Orquestrador).
  Map<String, String> extraMcpServers = const {};

  /// Nível de esforço ('' = padrão).
  String effort = '';

  /// Modelo realmente em uso, informado pelo provedor.
  String? activeModel;

  /// Aplica mudanças de [access]/[effort] sem perder a conversa.
  void refreshSession() {}

  /// Pergunta ao usuário antes de comandos/edições (modo "Pedir permissão").
  AgentPermissionHandler? onPermission;

  /// O back-end relata as ferramentas por [AgentToolEvent]; senão a janela
  /// mostra as chamadas às ferramentas do Gestor por conta própria.
  bool get reportsTools => false;

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

  /// Estado da conversa para guardar no histórico e retomar depois.
  Map<String, dynamic> saveState() => const {};

  void restoreState(Map<String, dynamic> state) {}

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
    activeModel = model;
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
  Map<String, dynamic> saveState() => {'messages': _messages};

  @override
  void restoreState(Map<String, dynamic> state) => _messages
    ..clear()
    ..addAll([
      for (final m in (state['messages'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(m),
    ]);

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
                'output_config': {
                  'effort': effort.isEmpty
                      ? 'high'
                      : (effort == 'xhigh' ? 'high' : effort),
                },
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
    activeModel = model;
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
  Map<String, dynamic> saveState() => {'messages': _messages};

  @override
  void restoreState(Map<String, dynamic> state) => _messages
    ..clear()
    ..addAll([
      for (final m in (state['messages'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(m),
    ]);

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

/// Base para os CLIs oficiais (Claude Code, Codex e Gemini CLI), que usam o
/// login da assinatura do próprio usuário. As ferramentas chegam a eles pelo
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

  /// Identificador da conversa no CLI (permite retomar pelo histórico).
  String? sessionId;
  Process? _process;
  String? _resolved;

  @override
  Map<String, dynamic> saveState() => {
    if (sessionId != null) 'sessionId': sessionId,
  };

  @override
  void restoreState(Map<String, dynamic> state) {
    reset();
    sessionId = state['sessionId'] as String?;
  }

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
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    candidates.addAll([
      p.join(home, '.local', 'bin', '$name.exe'),
      p.join(appData, 'npm', '$name.cmd'),
      // Instalações pelo winget (ex.: Antigravity CLI).
      p.join(localAppData, 'Microsoft', 'WinGet', 'Links', '$name.exe'),
    ]);
    for (final candidate in candidates) {
      final lower = candidate.toLowerCase();
      if (!(lower.endsWith('.exe') || lower.endsWith('.cmd'))) continue;
      // Atalho do VS Code para o Copilot: usa o CLI instalado pelo npm.
      if (lower.contains('copilot-shim')) continue;
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

  /// A sessão [id] ainda existe neste computador para ser retomada?
  Future<bool> canResume(String id) async => true;

  /// Procura um arquivo cujo nome contém [id] dentro de [root].
  static Future<bool> _sessionFileExists(String root, String id) async {
    final dir = Directory(root);
    if (!await dir.exists()) return false;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && p.basename(entity.path).contains(id)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

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

  String get _instructions => access == AgentAccess.gestor
      ? '$systemPrompt\n'
            'As ferramentas do Gestor UFU estão no servidor MCP '
            '"${AgentMcpServer.serverName}". Use somente elas para acessar os '
            'dados; não edite arquivos nem rode comandos.'
      : '$systemPrompt\n'
            'As ferramentas do Gestor UFU estão no servidor MCP '
            '"${AgentMcpServer.serverName}": use-as sempre para ler e alterar '
            'os dados do Gestor (nunca edite os arquivos internos do app). '
            'Você também pode pesquisar na web, ler arquivos e usar as demais '
            'ferramentas quando ajudar a atender o pedido.';

  /// Pasta usada fora do modo "Só o Gestor".
  Future<String> _userWorkDir() async {
    final configured = workDir.trim();
    final home =
        Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    final dir = Directory(
      configured.isNotEmpty
          ? configured
          : p.join(home, 'Documents', 'GestorUFU Agente'),
    );
    await dir.create(recursive: true);
    return dir.path;
  }

  /// Salva em arquivo temporário um anexo binário colado (sem caminho), para
  /// que o CLI possa lê-lo.
  Future<String?> _materialize(AgentAttachment attachment) async {
    if (attachment.localPath != null) return attachment.localPath;
    final bytes = attachment.bytes;
    if (bytes == null) return null;
    final dir = Directory(
      p.join(Directory.systemTemp.path, 'gestor_ufu_anexos'),
    );
    await dir.create(recursive: true);
    final file = File(
      p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}_${attachment.name}',
      ),
    );
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Monta o texto enviado ao CLI. [withInstructions] inclui as instruções
  /// do Gestor (apenas no início da conversa, quando o CLI não as recebe de
  /// outra forma). Anexos em [inline] já vão como blocos próprios.
  Future<String> _composePrompt(
    String prompt,
    List<AgentAttachment> attachments, {
    required bool withInstructions,
    Set<AgentAttachment> inline = const {},
  }) async {
    final buffer = StringBuffer();
    if (withInstructions) {
      buffer
        ..writeln('<instrucoes_do_gestor_ufu>')
        ..writeln(_instructions)
        ..writeln('</instrucoes_do_gestor_ufu>')
        ..writeln();
    }
    for (final attachment in attachments) {
      if (inline.contains(attachment)) continue;
      if (attachment.text != null) {
        buffer
          ..writeln('<anexo nome="${attachment.name}">')
          ..writeln(attachment.text)
          ..writeln('</anexo>');
        continue;
      }
      final path = await _materialize(attachment);
      if (path != null) {
        buffer.writeln(
          'Anexo "${attachment.name}" salvo em: $path '
          '(leia o arquivo para usar o conteúdo).',
        );
      }
    }
    buffer.write(prompt);
    return buffer.toString();
  }
}

/// Claude Code em sessão contínua (`--input-format stream-json`), como a
/// extensão do VS Code: um único processo atende a conversa inteira e o
/// texto chega em pedaços (`--include-partial-messages`).
class ClaudeCliBackend extends CliAgentBackend {
  ClaudeCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.claude);

  Process? _session;
  String? _configPath;
  Completer<void>? _turn;
  AgentEventSink? _emit;
  String? _turnError;
  bool _cancelled = false;
  bool _instructionsSent = false;
  int _controlId = 0;
  final _stderr = StringBuffer();

  @override
  String get label => 'Claude (assinatura via Claude Code)';

  @override
  bool get reportsTools => true;

  /// No modo "Só o Gestor", os conectores da conta claude.ai ficam de fora.
  @override
  Map<String, String> get environment => {
    'NO_COLOR': '1',
    if (access == AgentAccess.gestor) 'ENABLE_CLAUDEAI_MCP_SERVERS': 'false',
  };

  @override
  Future<String> workingDirectory() async =>
      access == AgentAccess.gestor ? Directory.systemTemp.path : _userWorkDir();

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

  /// O Claude Code guarda as sessões em ~/.claude/projects e apaga as
  /// antigas sozinho.
  @override
  Future<bool> canResume(String id) => CliAgentBackend._sessionFileExists(
    p.join(Platform.environment['USERPROFILE'] ?? '', '.claude', 'projects'),
    id,
  );

  /// O Claude Code não tem comando para listar modelos; estes são os mesmos
  /// apelidos do seletor da extensão do VS Code, resolvidos pelo próprio CLI
  /// para a versão mais recente liberada na assinatura.
  @override
  Future<List<AgentModel>> listModels() async => const [
    AgentModel('', 'Padrão (recomendado)', isDefault: true),
    AgentModel('opus', 'Opus'),
    AgentModel('sonnet', 'Sonnet'),
    AgentModel('haiku', 'Haiku'),
  ];

  Future<String> _mcpConfigFile() async {
    final existing = _configPath;
    if (existing != null && await File(existing).exists()) return existing;
    final dir = await Directory.systemTemp.createTemp('gestor_ufu_agent_');
    final file = File(p.join(dir.path, 'mcp.json'));
    await file.writeAsString(
      jsonEncode({
        'mcpServers': {
          AgentMcpServer.serverName: {'type': 'http', 'url': mcp.url},
          for (final extra in extraMcpServers.entries)
            extra.key: {'type': 'http', 'url': extra.value},
          if (access != AgentAccess.gestor && access != AgentAccess.bypass)
            AgentMcpServer.permissionServerName: {
              'type': 'http',
              'url': mcp.permissionUrl,
            },
        },
      }),
    );
    return _configPath = file.path;
  }

  Future<Process> _ensureSession() async {
    final running = _session;
    if (running != null) return running;
    final args = [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--mcp-config',
      await _mcpConfigFile(),
      ...switch (access) {
        // Só a leitura de anexos entre as ferramentas nativas; o resto do
        // acesso é pelas ferramentas do Gestor (MCP).
        AgentAccess.gestor => [
          '--strict-mcp-config',
          '--tools',
          'Read',
          '--allowedTools',
          'mcp__${AgentMcpServer.serverName}',
          'Read',
        ],
        // Como no VS Code: leitura e web liberadas; o resto segue o modo
        // escolhido e, quando precisa, pede aprovação no chat.
        AgentAccess.bypass => [
          '--permission-mode',
          'bypassPermissions',
          '--allowedTools',
          'mcp__${AgentMcpServer.serverName}',
        ],
        _ => [
          '--permission-mode',
          access.claudeMode,
          '--allowedTools',
          'mcp__${AgentMcpServer.serverName}',
          'Read',
          'Glob',
          'Grep',
          'WebSearch',
          'WebFetch',
          'TodoWrite',
          '--permission-prompt-tool',
          AgentMcpServer.permissionToolId,
        ],
      },
      if (model.isNotEmpty) ...['--model', model],
      if (effort.isNotEmpty) ...['--effort', effort],
      if (sessionId != null) ...['--resume', sessionId!],
    ];
    final process = await _start(args);
    _session = process;
    _instructionsSent = sessionId != null;
    _stderr.clear();
    process.stderr.transform(utf8.decoder).listen((chunk) {
      if (_stderr.length < 20000) _stderr.write(chunk);
    });
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    unawaited(
      process.exitCode.then((code) {
        if (_session == process) _session = null;
        final turn = _turn;
        if (turn == null || turn.isCompleted) return;
        final detail = _stderr.toString().trim();
        _turnError ??= _cancelled
            ? 'Cancelado.'
            : 'O Claude Code terminou (código $code)'
                  '${detail.isEmpty ? '' : ':\n$detail'}';
        turn.complete();
      }),
    );
    return process;
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) return;
    Map<String, dynamic> event;
    try {
      event = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
    } on FormatException {
      return;
    }
    final id = event['session_id'];
    if (id is String && id.isNotEmpty) sessionId = id;
    final emit = _emit;
    if (event['type'] == 'system' && event['model'] is String) {
      activeModel = event['model'] as String;
    }
    switch (event['type']) {
      case 'stream_event':
        // Só a conversa principal (subagentes têm parent_tool_use_id).
        if (event['parent_tool_use_id'] != null || emit == null) return;
        final inner = event['event'] as Map? ?? const {};
        if (inner['type'] == 'content_block_delta') {
          final delta = inner['delta'] as Map? ?? const {};
          if (delta['type'] == 'text_delta') {
            emit(AgentTextDeltaEvent('${delta['text'] ?? ''}'));
          } else if (delta['type'] == 'thinking_delta') {
            emit(const AgentThinkingEvent());
          }
        } else if (inner['type'] == 'content_block_start') {
          final block = inner['content_block'] as Map? ?? const {};
          if (block['type'] == 'thinking') emit(const AgentThinkingEvent());
          if (block['type'] == 'text') emit(const AgentTextBreakEvent());
        }
      case 'assistant' when event['parent_tool_use_id'] == null:
        final message = event['message'] as Map? ?? const {};
        for (final block
            in (message['content'] as List? ?? const []).whereType<Map>()) {
          if (block['type'] != 'tool_use') continue;
          emit?.call(
            AgentToolEvent(
              '${block['id']}',
              '${block['name']}',
              Map<String, dynamic>.from(block['input'] as Map? ?? const {}),
            ),
          );
        }
      case 'user':
        final message = event['message'] as Map? ?? const {};
        final content = message['content'];
        if (content is! List) return;
        for (final block in content.whereType<Map>()) {
          if (block['type'] != 'tool_result') continue;
          final raw = block['content'];
          final text = raw is List
              ? raw
                    .whereType<Map>()
                    .map((part) => '${part['text'] ?? ''}')
                    .join('\n')
              : '${raw ?? ''}';
          emit?.call(
            AgentToolResultEvent(
              '${block['tool_use_id']}',
              text,
              isError: block['is_error'] == true,
            ),
          );
        }
      case 'result':
        if (event['is_error'] == true) {
          _turnError = _cancelled
              ? 'Cancelado.'
              : 'Claude Code: ${event['result'] ?? event['subtype']}';
        }
        final turn = _turn;
        if (turn != null && !turn.isCompleted) turn.complete();
    }
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    final process = await _ensureSession();
    final images = {
      for (final a in attachments)
        if (a.isImage && a.bytes != null) a,
    };
    final text = await _composePrompt(
      prompt,
      attachments,
      withInstructions: !_instructionsSent,
      inline: images,
    );
    _instructionsSent = true;
    final turn = _turn = Completer<void>();
    _emit = emit;
    _turnError = null;
    _cancelled = false;
    process.stdin.writeln(
      jsonEncode({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            for (final image in images)
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': image.mimeType,
                  'data': base64Encode(image.bytes!),
                },
              },
            {'type': 'text', 'text': text},
          ],
        },
      }),
    );
    await process.stdin.flush();
    try {
      await turn.future;
    } finally {
      _emit = null;
      _turn = null;
    }
    final error = _turnError;
    if (error != null) throw AgentException(error);
  }

  /// Interrompe a resposta atual (como o botão Parar da extensão). Se o CLI
  /// não atender, encerra o processo; a conversa continua com `--resume`.
  @override
  Future<void> cancel() async {
    final process = _session;
    final turn = _turn;
    if (process == null || turn == null || turn.isCompleted) return;
    _cancelled = true;
    try {
      process.stdin.writeln(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'gestor_${++_controlId}',
          'request': {'subtype': 'interrupt'},
        }),
      );
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 3));
    if (_turn == turn && !turn.isCompleted) _closeSession();
  }

  void _closeSession() {
    final process = _session;
    _session = null;
    process?.kill();
  }

  @override
  void reset() {
    _closeSession();
    sessionId = null;
    _instructionsSent = false;
  }

  /// Reinicia o processo com os novos argumentos e retoma a conversa.
  @override
  void refreshSession() {
    _closeSession();
    _configPath = null;
  }

  @override
  Future<void> dispose() async {
    _closeSession();
    final config = _configPath;
    if (config != null) {
      try {
        await File(config).parent.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// Codex pelo `codex app-server` (o mesmo protocolo JSON-RPC usado pela
/// extensão do VS Code): um processo por janela, conversas como "threads" e
/// o texto chegando em pedaços.
class CodexCliBackend extends CliAgentBackend {
  CodexCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.chatgpt);

  Process? _server;
  Future<Process>? _starting;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  String? _loadedThread;
  String? _turnId;
  Completer<void>? _turn;
  AgentEventSink? _emit;
  String? _failure;
  bool _interrupted = false;
  final _streamedItems = <String>{};

  @override
  String get label => 'ChatGPT (assinatura via Codex)';

  @override
  bool get reportsTools => true;

  @override
  Future<String> workingDirectory() async =>
      access == AgentAccess.gestor ? Directory.systemTemp.path : _userWorkDir();

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

  @override
  Future<bool> canResume(String id) => CliAgentBackend._sessionFileExists(
    p.join(Platform.environment['USERPROFILE'] ?? '', '.codex', 'sessions'),
    id,
  );

  Future<Process> _ensureServer() {
    final running = _server;
    if (running != null) return Future.value(running);
    return _starting ??= () async {
      try {
        final process = await _start(['app-server']);
        _server = process;
        process.stderr.drain<void>();
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_onLine);
        unawaited(
          process.exitCode.then((code) {
            if (_server != process) return;
            _server = null;
            _loadedThread = null;
            final error = AgentException('O Codex terminou (código $code).');
            for (final pending in _pending.values) {
              if (!pending.isCompleted) pending.completeError(error);
            }
            _pending.clear();
            final turn = _turn;
            if (turn != null && !turn.isCompleted) {
              _failure ??= error.message;
              turn.complete();
            }
          }),
        );
        await _request('initialize', {
          'clientInfo': {
            'name': 'gestor_ufu',
            'title': 'Gestor UFU',
            'version': '1.0.0',
          },
        });
        _write({'method': 'initialized'});
        return process;
      } finally {
        _starting = null;
      }
    }();
  }

  void _write(Map<String, Object?> message) =>
      _server?.stdin.writeln(jsonEncode(message));

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = _nextId++;
    final completer = _pending[id] = Completer<Map<String, dynamic>>();
    _write({'method': method, 'id': id, 'params': params});
    return completer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        _pending.remove(id);
        throw AgentException('O Codex não respondeu a "$method".');
      },
    );
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) return;
    Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
    } on FormatException {
      return;
    }
    final id = message['id'];
    final method = message['method'] as String?;
    if (method == null && id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(AgentException('${error['message']}'));
      } else {
        completer.complete(
          Map<String, dynamic>.from(message['result'] as Map? ?? const {}),
        );
      }
      return;
    }
    final params = Map<String, dynamic>.from(
      message['params'] as Map? ?? const {},
    );
    if (method != null && id != null) {
      unawaited(_answer(id, method, params));
      return;
    }
    if (method != null) _onNotification(method, params);
  }

  /// Pedidos do Codex ao app. Comandos e edições de arquivo são recusados
  /// (o agente só mexe nos dados pelas ferramentas do Gestor); pedidos de
  /// confirmação das ferramentas do Gestor são aceitos.
  Future<void> _answer(
    Object id,
    String method,
    Map<String, dynamic> params,
  ) async {
    Future<bool> ask(String tool) async {
      if (access == AgentAccess.bypass) return true;
      if (access == AgentAccess.gestor) return false;
      final handler = onPermission;
      return handler != null && await handler(tool, params);
    }

    final result = switch (method) {
      'mcpServer/elicitation/request' => {
        'action': 'accept',
        'content': <String, Object?>{},
      },
      'item/commandExecution/requestApproval' => {
        'decision': await ask('Comando') ? 'accept' : 'decline',
      },
      'item/fileChange/requestApproval' => {
        'decision': await ask('Editar arquivos') ? 'accept' : 'decline',
      },
      'execCommandApproval' || 'applyPatchApproval' => {
        'decision': await ask('Comando') ? 'approved' : 'denied',
      },
      _ => null,
    };
    if (result == null) {
      _write({
        'id': id,
        'error': {'code': -32601, 'message': 'Não suportado: $method'},
      });
    } else {
      _write({'id': id, 'result': result});
    }
  }

  void _onNotification(String method, Map<String, dynamic> params) {
    final thread = params['threadId'];
    if (thread != null && thread != _loadedThread) return;
    final emit = _emit;
    switch (method) {
      case 'item/agentMessage/delta':
        final item = '${params['itemId']}';
        if (!_streamedItems.contains(item)) {
          _streamedItems.add(item);
          emit?.call(const AgentTextBreakEvent());
        }
        emit?.call(AgentTextDeltaEvent('${params['delta'] ?? ''}'));
      case 'item/started':
        final item = params['item'] as Map? ?? const {};
        if (item['type'] == 'reasoning') emit?.call(const AgentThinkingEvent());
        final tool = _toolOf(item);
        if (tool != null) {
          emit?.call(AgentToolEvent('${item['id']}', tool.$1, tool.$2));
        }
      case 'item/completed':
        final item = params['item'] as Map? ?? const {};
        if (item['type'] == 'agentMessage' &&
            !_streamedItems.contains('${item['id']}')) {
          final text = '${item['text'] ?? ''}'.trim();
          if (text.isNotEmpty) emit?.call(AgentTextEvent(text));
        }
        if (_toolOf(item) != null) {
          final result = _toolResult(item);
          emit?.call(
            AgentToolResultEvent(
              '${item['id']}',
              result.$1,
              isError: result.$2,
            ),
          );
        }
      case 'error':
        if (params['willRetry'] == true) return;
        final error = params['error'];
        _failure = error is Map ? '${error['message']}' : '$error';
      case 'turn/completed':
        final turn = params['turn'] as Map? ?? const {};
        if (turn['status'] == 'failed') {
          final error = turn['error'];
          _failure ??= error is Map ? '${error['message']}' : 'falha no turno';
        }
        if (turn['status'] == 'interrupted') _interrupted = true;
        final pending = _turn;
        if (pending != null && !pending.isCompleted) pending.complete();
    }
  }

  /// Nome e entrada exibidos para os itens que são ferramentas.
  static (String, Map<String, dynamic>)? _toolOf(Map item) =>
      switch (item['type']) {
        'commandExecution' => ('Comando', {'command': item['command']}),
        'webSearch' => ('Pesquisa na web', {'query': item['query']}),
        'fileChange' => (
          'Editar arquivos',
          {
            'arquivos': [
              for (final change
                  in (item['changes'] as List? ?? const []).whereType<Map>())
                change['path'],
            ],
          },
        ),
        'mcpToolCall' => (
          item['server'] == AgentMcpServer.serverName
              ? '${item['tool']}'
              : '${item['server']} · ${item['tool']}',
          item['arguments'] is Map
              ? Map<String, dynamic>.from(item['arguments'] as Map)
              : <String, dynamic>{},
        ),
        'dynamicToolCall' => ('${item['tool']}', <String, dynamic>{}),
        _ => null,
      };

  static (String, bool) _toolResult(Map item) {
    final failed = item['status'] == 'failed' || item['status'] == 'declined';
    switch (item['type']) {
      case 'commandExecution':
        return ('${item['aggregatedOutput'] ?? item['status'] ?? ''}', failed);
      case 'mcpToolCall':
        final error = item['error'];
        if (error is Map) return ('${error['message']}', true);
        final result = item['result'] as Map? ?? const {};
        final text = (result['content'] as List? ?? const [])
            .whereType<Map>()
            .map((part) => '${part['text'] ?? ''}')
            .join('\n');
        return (text, failed);
      default:
        return ('${item['status'] ?? ''}', failed);
    }
  }

  Future<Map<String, Object?>> _threadParams() async => {
    'cwd': await workingDirectory(),
    ...switch (access) {
      AgentAccess.gestor => {'approvalPolicy': 'never', 'sandbox': 'read-only'},
      AgentAccess.manual => {
        'approvalPolicy': 'untrusted',
        'sandbox': 'workspace-write',
      },
      AgentAccess.acceptEdits || AgentAccess.auto => {
        'approvalPolicy': 'on-request',
        'sandbox': 'workspace-write',
      },
      AgentAccess.plan => {
        'approvalPolicy': 'on-request',
        'sandbox': 'read-only',
      },
      AgentAccess.bypass => {
        'approvalPolicy': 'never',
        'sandbox': 'danger-full-access',
      },
    },
    'developerInstructions': access == AgentAccess.plan
        ? '$_instructions\nModo planejar: explore e apresente um plano; não '
              'altere nada até o usuário aprovar.'
        : _instructions,
    if (model.isNotEmpty) 'model': model,
    'config': {
      'mcp_servers.${AgentMcpServer.serverName}.url': mcp.url,
      for (final extra in extraMcpServers.entries)
        'mcp_servers.${extra.key}.url': extra.value,
      if (access != AgentAccess.gestor) 'web_search': 'live',
    },
  };

  Future<void> _ensureThread() async {
    if (_loadedThread != null && _loadedThread == sessionId) return;
    final params = await _threadParams();
    if (sessionId != null) {
      try {
        final resumed = await _request('thread/resume', {
          'threadId': sessionId,
          ...params,
        });
        if (resumed['model'] is String) {
          activeModel = resumed['model'] as String;
        }
        _loadedThread = sessionId;
        return;
      } on AgentException {
        sessionId = null; // conversa não encontrada: começa outra
      }
    }
    final result = await _request('thread/start', params);
    if (result['model'] is String) activeModel = result['model'] as String;
    final thread = result['thread'] as Map? ?? const {};
    sessionId = '${thread['id']}';
    _loadedThread = sessionId;
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    await _ensureServer();
    await _ensureThread();
    final images = {
      for (final a in attachments)
        if (a.isImage && a.bytes != null) a,
    };
    final text = await _composePrompt(
      prompt,
      attachments,
      withInstructions: false,
      inline: images,
    );
    final turn = _turn = Completer<void>();
    _emit = emit;
    _failure = null;
    _interrupted = false;
    _streamedItems.clear();
    try {
      final result = await _request('turn/start', {
        'threadId': sessionId,
        if (effort.isNotEmpty) 'effort': effort == 'max' ? 'xhigh' : effort,
        'input': [
          {'type': 'text', 'text': text},
          for (final image in images)
            {
              'type': 'image',
              'url':
                  'data:${image.mimeType};base64,${base64Encode(image.bytes!)}',
            },
        ],
      });
      _turnId = '${(result['turn'] as Map? ?? const {})['id']}';
      await turn.future;
    } finally {
      _emit = null;
      _turn = null;
      _turnId = null;
    }
    if (_interrupted) throw AgentException('Cancelado.');
    final failure = _failure;
    if (failure != null) {
      throw AgentException(
        'Codex: $failure. Se for problema de login, use "Entrar" nas '
        'configurações do agente.',
      );
    }
  }

  @override
  Future<void> cancel() async {
    final turnId = _turnId;
    if (turnId == null || sessionId == null) return;
    try {
      await _request('turn/interrupt', {
        'threadId': sessionId,
        'turnId': turnId,
      });
    } catch (_) {
      _server?.kill();
    }
  }

  @override
  void reset() {
    sessionId = null;
    _loadedThread = null;
  }

  /// Retoma a thread com as novas permissões no próximo envio.
  @override
  void refreshSession() => _loadedThread = null;

  @override
  Future<void> dispose() async {
    final server = _server;
    _server = null;
    server?.kill();
  }

  /// Pergunta ao `codex app-server` quais modelos a conta ChatGPT pode usar.
  @override
  Future<List<AgentModel>> listModels() async {
    try {
      await _ensureServer();
      final result = await _request('model/list', {});
      final raw =
          (result['data'] ?? result['models'] ?? result['items']) as List? ??
          const [];
      final models = [
        for (final item in raw.whereType<Map>())
          if (item['hidden'] != true)
            AgentModel(
              '${item['model'] ?? item['id'] ?? item['slug']}',
              '${item['displayName'] ?? item['display_name'] ?? item['model'] ?? item['id']}',
              isDefault: item['isDefault'] == true,
            ),
      ];
      if (models.isEmpty) throw AgentException('lista vazia');
      return models;
    } catch (_) {
      // Versões antigas do Codex não têm model/list.
      return const [
        AgentModel('', 'Padrão (definido no Codex)', isDefault: true),
      ];
    }
  }
}

/// Gemini pelo Antigravity CLI (`agy`), o sucessor oficial do Gemini CLI
/// para contas Google pessoais (Google AI Pro etc.). Sessão contínua com
/// `--input-format stream-json`; as ferramentas do Gestor entram por um
/// `.agents/mcp_config.json` na pasta de trabalho.
class GeminiCliBackend extends CliAgentBackend {
  GeminiCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.gemini);

  Process? _session;
  Completer<void>? _turn;
  AgentEventSink? _emit;
  String? _turnError;
  bool _cancelled = false;
  bool _instructionsSent = false;
  int? _textStep;
  final _stderr = StringBuffer();

  @override
  String get label => 'Gemini (assinatura via Antigravity CLI)';

  @override
  bool get reportsTools => true;

  static String get _dataDir => p.join(
    Platform.environment['USERPROFILE'] ?? '',
    '.gemini',
    'antigravity-cli',
  );

  @override
  Future<bool> isLoggedIn() async {
    try {
      final process = await _start(['models']);
      await process.stdin.close();
      final out = await _merge(process)
          .transform(utf8.decoder)
          .join()
          .timeout(
            const Duration(seconds: 40),
            onTimeout: () {
              process.kill();
              return '';
            },
          );
      final code = await process.exitCode;
      return code == 0 && !out.toLowerCase().contains('sign in');
    } catch (_) {
      return false;
    }
  }

  /// Instala pelo winget (pacote oficial do Google).
  @override
  Future<void> install(void Function(String line) onOutput) async {
    final process = await Process.start('winget', [
      'install',
      '--id',
      'Google.AntigravityCLI',
      '-e',
      '--accept-package-agreements',
      '--accept-source-agreements',
      '--silent',
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
        'Não foi possível instalar o Antigravity CLI (winget terminou com '
        'código $code).',
      );
    }
  }

  /// O login do Antigravity é feito no modo interativo: abre um terminal
  /// com o `agy`, que leva ao navegador, e espera a conta ficar disponível.
  @override
  Future<void> loginWithBrowser(void Function(String line) onOutput) async {
    await openLoginTerminal();
    onOutput(
      'Entre com sua conta Google no terminal/navegador que foi aberto e '
      'feche o terminal ao terminar.',
    );
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (await isLoggedIn()) return;
    }
    throw AgentException('Tempo esgotado aguardando o login no Antigravity.');
  }

  @override
  Future<String> verify() async {
    final exe = await executable();
    final result = await Process.run(exe, ['--version']);
    if (result.exitCode != 0) {
      throw AgentException('Falha ao executar $exe: ${result.stderr}');
    }
    if (!await isLoggedIn()) {
      throw AgentException(
        'Entre com sua conta Google no Antigravity para usar o Gemini.',
      );
    }
    return 'Antigravity CLI ${'${result.stdout}'.trim()} encontrado.';
  }

  @override
  Future<List<AgentModel>> listModels() async {
    final models = <AgentModel>[
      const AgentModel('', 'Padrão do Antigravity', isDefault: true),
    ];
    try {
      final process = await _start(['models']);
      await process.stdin.close();
      final out = await process.stdout.transform(utf8.decoder).join();
      await process.exitCode;
      for (final line in const LineSplitter().convert(out)) {
        final parts = line.split('\t');
        if (parts.length < 2 || parts.first.trim().isEmpty) continue;
        models.add(AgentModel(parts.first.trim(), parts[1].trim()));
      }
    } catch (_) {}
    return models;
  }

  @override
  Future<bool> canResume(String id) =>
      CliAgentBackend._sessionFileExists(p.join(_dataDir, 'conversations'), id);

  /// Pasta de trabalho com o `.agents/mcp_config.json` do Gestor (só para
  /// esta pasta; a configuração global do usuário não é alterada).
  @override
  Future<String> workingDirectory() async {
    final dir = access == AgentAccess.gestor
        ? p.join(Directory.systemTemp.path, 'gestor_ufu_agy')
        : await _userWorkDir();
    await Directory(dir).create(recursive: true);
    String? url;
    try {
      url = mcp.url;
    } on StateError {
      url = null; // verificação de login: o servidor MCP ainda não subiu
    }
    if (url != null) {
      final config = File(p.join(dir, '.agents', 'mcp_config.json'));
      await config.parent.create(recursive: true);
      await config.writeAsString(
        jsonEncode({
          'mcpServers': {
            AgentMcpServer.serverName: {'serverUrl': url},
            for (final extra in extraMcpServers.entries)
              extra.key: {'serverUrl': extra.value},
          },
        }),
      );
    }
    return dir;
  }

  Future<Process> _ensureSession() async {
    final running = _session;
    if (running != null) return running;
    final args = [
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--settings',
      jsonEncode({
        'permissions': {
          'allow': ['mcp(${AgentMcpServer.serverName}/*)'],
        },
      }),
      ...switch (access) {
        AgentAccess.bypass => ['--dangerously-skip-permissions'],
        AgentAccess.acceptEdits => ['--mode', 'accept-edits'],
        AgentAccess.plan => ['--mode', 'plan'],
        AgentAccess.auto => ['--mode', 'auto'],
        _ => const <String>[],
      },
      if (model.isNotEmpty) ...['--model', model],
      if (effort.isNotEmpty) ...['--effort', effort],
      if (sessionId != null) ...['--conversation', sessionId!],
      '-p=',
    ];
    final process = await _start(args);
    _session = process;
    _instructionsSent = sessionId != null;
    _stderr.clear();
    process.stderr.transform(utf8.decoder).listen((chunk) {
      if (_stderr.length < 20000) _stderr.write(chunk);
    });
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    unawaited(
      process.exitCode.then((code) {
        if (_session == process) _session = null;
        final turn = _turn;
        if (turn == null || turn.isCompleted) return;
        final detail = _stderr.toString().trim();
        _turnError ??= _cancelled
            ? 'Cancelado.'
            : 'O Antigravity terminou (código $code)'
                  '${detail.isEmpty ? '' : ':\n$detail'}';
        turn.complete();
      }),
    );
    return process;
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) {
      // Avisos do CLI (ex.: ação negada por falta de permissão).
      if (trimmed.isNotEmpty && _emit != null && trimmed.contains('denied')) {
        _emit!(AgentInfoEvent(trimmed));
      }
      return;
    }
    Map<String, dynamic> event;
    try {
      event = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
    } on FormatException {
      return;
    }
    final emit = _emit;
    switch (event['event']) {
      case 'init':
        final id = event['conversation_id'];
        if (id is String && id.isNotEmpty) sessionId = id;
        final init = event['init'] as Map? ?? const {};
        if (init['model'] is String) activeModel = init['model'] as String;
      case 'step_update':
        final step = event['step_update'] as Map? ?? const {};
        final id = step['conversation_id'];
        if (id is String && id.isNotEmpty) sessionId = id;
        if (emit == null) return;
        final index = step['step_index'] as int? ?? -1;
        final state = '${step['state'] ?? ''}';
        switch (step['step_type']) {
          case 'agent_response':
            final delta = step['text_delta'];
            if (delta is String && delta.isNotEmpty) {
              if (_textStep != index) {
                _textStep = index;
                emit(const AgentTextBreakEvent());
              }
              emit(AgentTextDeltaEvent(delta));
            } else if (state == 'ACTIVE') {
              emit(const AgentThinkingEvent());
            }
          case 'tool':
            final info = step['tool_info'] as Map? ?? const {};
            final params = Map<String, dynamic>.from(
              info['parameters'] as Map? ?? const {},
            );
            final isMcp = step['tool_name'] == 'call_mcp_tool';
            final name = isMcp
                ? (params['ServerName'] == AgentMcpServer.serverName
                      ? '${params['ToolName']}'
                      : '${params['ServerName']} · ${params['ToolName']}')
                : '${step['tool_name'] ?? info['name']}';
            final input = isMcp
                ? Map<String, dynamic>.from(params['Arguments'] as Map? ?? {})
                : params;
            final toolId = 'step$index';
            if (state == 'ACTIVE') {
              emit(AgentToolEvent(toolId, name, input));
            } else {
              final error = info['error'];
              emit(
                AgentToolResultEvent(
                  toolId,
                  error is Map
                      ? '${error['message']}'
                      : '${info['output'] ?? ''}',
                  isError: state == 'ERROR',
                ),
              );
            }
          default:
            if (state == 'ACTIVE') emit(const AgentThinkingEvent());
        }
      case 'result':
        final result = event['result'] as Map? ?? const {};
        final id = result['conversation_id'];
        if (id is String && id.isNotEmpty) sessionId = id;
        if (result['status'] == 'ERROR') {
          _turnError = _cancelled
              ? 'Cancelado.'
              : 'Antigravity: ${result['error'] ?? 'erro desconhecido'}';
        }
        final denied = result['denied_actions'];
        if (denied is List && denied.isNotEmpty && emit != null) {
          emit(
            AgentInfoEvent(
              'Ações negadas neste modo: '
              '${denied.whereType<Map>().map((d) => d['display_name'] ?? d['action']).join(', ')}. '
              'Use "Ignorar permissões" ou "Editar automaticamente" para '
              'liberá-las.',
            ),
          );
        }
        final turn = _turn;
        if (turn != null && !turn.isCompleted) turn.complete();
    }
  }

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    final process = await _ensureSession();
    final text = await _composePrompt(
      prompt,
      attachments,
      withInstructions: !_instructionsSent,
    );
    _instructionsSent = true;
    final turn = _turn = Completer<void>();
    _emit = emit;
    _turnError = null;
    _cancelled = false;
    _textStep = null;
    process.stdin.writeln(
      jsonEncode({
        'event': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      }),
    );
    await process.stdin.flush();
    try {
      await turn.future;
    } finally {
      _emit = null;
      _turn = null;
    }
    final error = _turnError;
    if (error != null) throw AgentException(error);
  }

  /// Interrompe encerrando o processo; a conversa continua com
  /// `--conversation` na próxima mensagem.
  @override
  Future<void> cancel() async {
    if (_turn == null) return;
    _cancelled = true;
    _closeSession();
  }

  void _closeSession() {
    final process = _session;
    _session = null;
    process?.kill();
  }

  @override
  void reset() {
    _closeSession();
    sessionId = null;
    _instructionsSent = false;
  }

  @override
  void refreshSession() => _closeSession();

  @override
  Future<void> dispose() async => _closeSession();
}

/// GitHub Copilot (assinatura Copilot Pro) pelo GitHub Copilot CLI no modo
/// ACP (Agent Client Protocol): sessão contínua por JSON-RPC, texto em
/// pedaços, ferramentas relatadas e pedidos de permissão respondidos no
/// chat do Gestor.
class CopilotCliBackend extends CliAgentBackend {
  CopilotCliBackend({
    required super.mcp,
    required super.configuredPath,
    required super.model,
  }) : super(provider: AgentProvider.copilot);

  Process? _server;
  Future<Process>? _starting;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  String? _loadedSession;
  AgentEventSink? _emit;
  bool _cancelled = false;
  bool _streaming = false;
  Object? _messageId;
  final _stderr = StringBuffer();
  List<AgentModel>? _models;

  @override
  String get label => 'GitHub Copilot (assinatura via Copilot CLI)';

  @override
  bool get reportsTools => true;

  @override
  Future<String> workingDirectory() async =>
      access == AgentAccess.gestor ? Directory.systemTemp.path : _userWorkDir();

  /// Opções de inicialização conforme o modo de permissão.
  List<String> get _args => [
    '--acp',
    '--no-auto-update',
    '--allow-tool',
    AgentMcpServer.serverName,
    ...switch (access) {
      AgentAccess.bypass => ['--allow-all'],
      AgentAccess.acceptEdits => ['--allow-tool', 'write'],
      AgentAccess.plan => ['--plan'],
      AgentAccess.auto => ['--assisted-approval'],
      _ => const <String>[],
    },
    if (model.isNotEmpty) ...['--model', model],
    if (effort.isNotEmpty) ...['--reasoning-effort', effort],
  ];

  Future<Process> _ensureServer() {
    final running = _server;
    if (running != null) return Future.value(running);
    return _starting ??= () async {
      try {
        final process = await _start(_args);
        _server = process;
        _stderr.clear();
        process.stderr.transform(utf8.decoder).listen((chunk) {
          if (_stderr.length < 20000) _stderr.write(chunk);
        });
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_onLine);
        unawaited(
          process.exitCode.then((code) {
            if (_server != process) return;
            _server = null;
            _loadedSession = null;
            final detail = _stderr.toString().trim();
            final error = AgentException(
              _cancelled
                  ? 'Cancelado.'
                  : 'O Copilot terminou (código $code)'
                        '${detail.isEmpty ? '' : ':\n$detail'}',
            );
            for (final pending in _pending.values) {
              if (!pending.isCompleted) pending.completeError(error);
            }
            _pending.clear();
          }),
        );
        await _request('initialize', {
          'protocolVersion': 1,
          'clientCapabilities': {
            'fs': {'readTextFile': false, 'writeTextFile': false},
            'terminal': false,
          },
        }, timeout: const Duration(minutes: 1));
        return process;
      } finally {
        _starting = null;
      }
    }();
  }

  void _write(Map<String, Object?> message) =>
      _server?.stdin.writeln(jsonEncode({'jsonrpc': '2.0', ...message}));

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) {
    final id = _nextId++;
    final completer = _pending[id] = Completer<Map<String, dynamic>>();
    _write({'id': id, 'method': method, 'params': params});
    final future = completer.future;
    if (timeout == null) return future;
    return future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw AgentException('O Copilot não respondeu a "$method".');
      },
    );
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) return;
    Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
    } on FormatException {
      return;
    }
    final id = message['id'];
    final method = message['method'] as String?;
    if (method == null && id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(AgentException('${error['message']}'));
      } else {
        completer.complete(
          Map<String, dynamic>.from(message['result'] as Map? ?? const {}),
        );
      }
      return;
    }
    final params = Map<String, dynamic>.from(
      message['params'] as Map? ?? const {},
    );
    if (method != null && id != null) {
      unawaited(_answer(id, method, params));
    } else if (method == 'session/update') {
      _onUpdate(params);
    }
  }

  /// Pedido de permissão do Copilot: vira o cartão Permitir/Negar no chat.
  Future<void> _answer(
    Object id,
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method != 'session/request_permission') {
      _write({
        'id': id,
        'error': {'code': -32601, 'message': 'Não suportado: $method'},
      });
      return;
    }
    final toolCall = params['toolCall'] as Map? ?? const {};
    final options = (params['options'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    String? optionOf(String kind) {
      for (final option in options) {
        if (option['kind'] == kind) return '${option['optionId']}';
      }
      return null;
    }

    final input = toolCall['rawInput'] is Map
        ? Map<String, dynamic>.from(toolCall['rawInput'] as Map)
        : <String, dynamic>{'acao': '${toolCall['title'] ?? ''}'};
    final title = '${toolCall['title'] ?? toolCall['kind'] ?? 'Ferramenta'}';
    bool allowed;
    if (access == AgentAccess.bypass) {
      allowed = true;
    } else if (access == AgentAccess.gestor) {
      allowed = title.contains(AgentMcpServer.serverName);
    } else {
      final handler = onPermission;
      allowed = handler != null && await handler(title, input);
    }
    final optionId = allowed
        ? (optionOf('allow_once') ?? optionOf('allow_always'))
        : (optionOf('reject_once') ?? optionOf('reject_always'));
    _write({
      'id': id,
      'result': {
        'outcome': optionId == null
            ? {'outcome': 'cancelled'}
            : {'outcome': 'selected', 'optionId': optionId},
      },
    });
  }

  static String _contentText(Object? content) {
    if (content is Map) {
      if (content['text'] != null) return '${content['text']}';
      if (content['content'] != null) return _contentText(content['content']);
      return '';
    }
    if (content is List) {
      return content.map(_contentText).where((t) => t.isNotEmpty).join('\n');
    }
    return content == null ? '' : '$content';
  }

  void _onUpdate(Map<String, dynamic> params) {
    if (params['sessionId'] != _loadedSession) return;
    final emit = _emit;
    if (emit == null) return; // replay do session/load
    final update = params['update'] as Map? ?? const {};
    switch (update['sessionUpdate']) {
      case 'agent_message_chunk':
        final text = _contentText(update['content']);
        if (text.isEmpty) return;
        final messageId = update['messageId'];
        if (!_streaming || messageId != _messageId) {
          _streaming = true;
          _messageId = messageId;
          emit(const AgentTextBreakEvent());
        }
        emit(AgentTextDeltaEvent(text));
      case 'agent_thought_chunk':
        emit(const AgentThinkingEvent());
      case 'tool_call':
        _streaming = false;
        final raw = update['rawInput'];
        emit(
          AgentToolEvent(
            '${update['toolCallId']}',
            '${update['title'] ?? update['kind'] ?? 'Ferramenta'}',
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{},
          ),
        );
      case 'tool_call_update':
        final status = update['status'];
        if (status != 'completed' && status != 'failed') return;
        final output = _contentText(update['content']);
        emit(
          AgentToolResultEvent(
            '${update['toolCallId']}',
            output.isNotEmpty ? output : '${update['rawOutput'] ?? ''}',
            isError: status == 'failed',
          ),
        );
    }
  }

  Future<List<Map<String, Object?>>> _mcpServers() async => [
    {
      'type': 'http',
      'name': AgentMcpServer.serverName,
      'url': mcp.url,
      'headers': <Object>[],
    },
    for (final extra in extraMcpServers.entries)
      {
        'type': 'http',
        'name': extra.key,
        'url': extra.value,
        'headers': <Object>[],
      },
  ];

  void _readSessionInfo(Map<String, dynamic> result) {
    final models = result['models'];
    if (models is Map) {
      final current = models['currentModelId'];
      if (current is String) activeModel = current;
      final seen = <String>{};
      _models = [
        for (final item
            in (models['availableModels'] as List? ?? const [])
                .whereType<Map>())
          if (seen.add('${item['modelId']}'))
            AgentModel(
              '${item['modelId']}',
              '${item['name'] ?? item['modelId']}',
              isDefault: item['modelId'] == current,
            ),
      ];
    }
  }

  Future<void> _ensureSession() async {
    await _ensureServer();
    if (_loadedSession != null && _loadedSession == sessionId) return;
    final cwd = await workingDirectory();
    if (sessionId != null) {
      try {
        final result = await _request('session/load', {
          'sessionId': sessionId,
          'cwd': cwd,
          'mcpServers': await _mcpServers(),
        }, timeout: const Duration(minutes: 2));
        _loadedSession = sessionId;
        _readSessionInfo(result);
        return;
      } on AgentException {
        sessionId = null; // sessão não encontrada: começa outra
      }
    }
    final result = await _request('session/new', {
      'cwd': cwd,
      'mcpServers': await _mcpServers(),
    }, timeout: const Duration(minutes: 2));
    sessionId = '${result['sessionId']}';
    _loadedSession = sessionId;
    _readSessionInfo(result);
  }

  /// Logado = o Copilot aceita abrir uma sessão (não gasta requisições).
  @override
  Future<bool> isLoggedIn() async {
    final probe = CopilotCliBackend(
      mcp: mcp,
      configuredPath: configuredPath,
      model: '',
    )..access = AgentAccess.gestor;
    try {
      await probe._ensureServer();
      await probe._request('session/new', {
        'cwd': Directory.systemTemp.path,
        'mcpServers': <Object>[],
      }, timeout: const Duration(seconds: 40));
      return true;
    } catch (_) {
      return false;
    } finally {
      await probe.dispose();
    }
  }

  @override
  Future<String> verify() async {
    final version = await super.verify();
    if (!await isLoggedIn()) {
      throw AgentException(
        'Entre com sua conta GitHub (Copilot) para usar este agente.',
      );
    }
    return version;
  }

  @override
  Future<List<AgentModel>> listModels() async {
    try {
      await _ensureSession();
    } catch (_) {}
    final models = _models;
    if (models != null && models.isNotEmpty) return models;
    return const [
      AgentModel('', 'Auto (definido pelo Copilot)', isDefault: true),
    ];
  }

  @override
  Future<bool> canResume(String id) => CliAgentBackend._sessionFileExists(
    p.join(
      Platform.environment['USERPROFILE'] ?? '',
      '.copilot',
      'session-state',
    ),
    id,
  );

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    final withInstructions = sessionId == null || _loadedSession == null;
    await _ensureSession();
    final images = {
      for (final a in attachments)
        if (a.isImage && a.bytes != null) a,
    };
    final text = await _composePrompt(
      prompt,
      attachments,
      withInstructions: withInstructions,
      inline: images,
    );
    _emit = emit;
    _cancelled = false;
    _streaming = false;
    Map<String, dynamic> result;
    try {
      result = await _request('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': text},
          for (final image in images)
            {
              'type': 'image',
              'mimeType': image.mimeType,
              'data': base64Encode(image.bytes!),
            },
        ],
      });
    } finally {
      _emit = null;
    }
    final stop = result['stopReason'];
    if (stop == 'cancelled' || _cancelled) throw AgentException('Cancelado.');
    if (stop == 'refusal') {
      throw AgentException('O Copilot recusou a solicitação.');
    }
    if (stop == 'max_tokens') {
      emit(
        const AgentInfoEvent('Resposta interrompida pelo limite de tokens.'),
      );
    }
  }

  @override
  Future<void> cancel() async {
    final session = _loadedSession;
    if (session == null || _emit == null) return;
    _cancelled = true;
    _write({
      'method': 'session/cancel',
      'params': {'sessionId': session},
    });
  }

  void _closeServer() {
    final server = _server;
    _server = null;
    _loadedSession = null;
    server?.kill();
  }

  @override
  void reset() {
    sessionId = null;
    _loadedSession = null;
  }

  /// Novas opções (modo/esforço) exigem reiniciar o Copilot; a conversa é
  /// retomada com session/load.
  @override
  void refreshSession() => _closeServer();

  @override
  Future<void> dispose() async => _closeServer();
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
    activeModel = model;
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
  Map<String, dynamic> saveState() => {'contents': _contents};

  @override
  void restoreState(Map<String, dynamic> state) => _contents
    ..clear()
    ..addAll([
      for (final m in (state['contents'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(m),
    ]);

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
