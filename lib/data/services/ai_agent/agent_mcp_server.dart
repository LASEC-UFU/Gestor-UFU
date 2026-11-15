import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';

typedef AgentToolCaller =
    Future<String> Function(String name, Map<String, dynamic> input);

/// Pergunta ao usuário se uma ferramenta do CLI pode rodar.
typedef AgentPermissionHandler =
    Future<bool> Function(String tool, Map<String, dynamic> input);

/// Servidor MCP mínimo (Streamable HTTP, respostas JSON) que expõe as
/// ferramentas do Gestor UFU para o Claude Code CLI e o Codex CLI. Escuta
/// apenas em 127.0.0.1 e exige um token aleatório na URL.
class AgentMcpServer {
  AgentMcpServer(this._callTool, {this.onPermission});

  final AgentToolCaller _callTool;

  /// Usado pelo Claude Code (`--permission-prompt-tool`) para pedir
  /// aprovação de comandos e edições no chat do Gestor.
  AgentPermissionHandler? onPermission;
  HttpServer? _server;
  late final String _token = _randomToken();

  static const serverName = 'gestor_ufu';

  /// Servidor separado que só expõe a ferramenta de aprovação.
  static const permissionServerName = 'gestor_ufu_permissao';
  static const permissionToolName = 'aprovar';
  static String get permissionToolId =>
      'mcp__${permissionServerName}__$permissionToolName';

  String get permissionUrl => '$url/permissao';

  String get url {
    final server = _server;
    if (server == null) throw StateError('Servidor MCP não iniciado.');
    return 'http://127.0.0.1:${server.port}/mcp/$_token';
  }

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) => unawaited(_handle(request)));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final base = '/mcp/$_token';
      final permission = request.uri.path == '$base/permissao';
      if (request.uri.path != base && !permission) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body);
      final messages = decoded is List ? decoded : [decoded];
      final replies = <Map<String, dynamic>>[];
      for (final message in messages.whereType<Map>()) {
        final reply = await _process(
          Map<String, dynamic>.from(message),
          permission: permission,
        );
        if (reply != null) replies.add(reply);
      }
      if (replies.isEmpty) {
        response.statusCode = HttpStatus.accepted;
        return;
      }
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(decoded is List ? replies : replies.single));
    } catch (error) {
      response.statusCode = HttpStatus.badRequest;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32700, 'message': '$error'},
        }),
      );
    } finally {
      await response.close();
    }
  }

  Future<Map<String, dynamic>?> _process(
    Map<String, dynamic> message, {
    bool permission = false,
  }) async {
    final id = message['id'];
    final method = message['method'] as String?;
    if (id == null) return null; // notificação
    Map<String, dynamic> ok(Object result) => {
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    };
    switch (method) {
      case 'initialize':
        final params = message['params'] as Map? ?? const {};
        return ok({
          'protocolVersion': params['protocolVersion'] ?? '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {
            'name': permission ? permissionServerName : serverName,
            'version': '1.0.0',
          },
        });
      case 'ping':
      case 'server/discover': // Antigravity pergunta antes do initialize
        return ok({});
      case 'tools/list' when permission:
        return ok({
          'tools': [
            {
              'name': permissionToolName,
              'description': 'Uso interno: aprovação de ferramentas.',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'tool_name': {'type': 'string'},
                  'input': {'type': 'object'},
                  'tool_use_id': {'type': 'string'},
                },
                'required': ['tool_name', 'input'],
              },
            },
          ],
        });
      case 'tools/call' when permission:
        final params = Map<String, dynamic>.from(message['params'] as Map);
        final args = Map<String, dynamic>.from(
          params['arguments'] as Map? ?? const {},
        );
        final input = Map<String, dynamic>.from(args['input'] as Map? ?? {});
        final handler = onPermission;
        final allowed =
            handler != null && await handler('${args['tool_name']}', input);
        return ok({
          'content': [
            {
              'type': 'text',
              'text': jsonEncode(
                allowed
                    ? {'behavior': 'allow', 'updatedInput': input}
                    : {
                        'behavior': 'deny',
                        'message': 'O usuário negou esta ação.',
                      },
              ),
            },
          ],
        });
      case 'tools/list':
        return ok({
          'tools': [
            for (final tool in agentTools)
              {
                'name': tool.name,
                'description': tool.description,
                'inputSchema': tool.schema,
              },
          ],
        });
      case 'tools/call':
        final params = Map<String, dynamic>.from(message['params'] as Map);
        final name = params['name'] as String;
        final input = Map<String, dynamic>.from(
          params['arguments'] as Map? ?? const {},
        );
        final result = await _callTool(name, input);
        final isError = result.startsWith('{"error"');
        // Capturas de tela vão como imagem MCP (o agente "vê" a página).
        if (result.contains('"image_base64"')) {
          try {
            final data = Map<String, dynamic>.from(jsonDecode(result) as Map);
            final image = data.remove('image_base64');
            final mime = data.remove('image_mime') ?? 'image/png';
            return ok({
              'content': [
                {'type': 'image', 'data': image, 'mimeType': mime},
                {'type': 'text', 'text': jsonEncode(data)},
              ],
              'isError': false,
            });
          } catch (_) {}
        }
        return ok({
          'content': [
            {'type': 'text', 'text': result},
          ],
          'isError': isError,
        });
    }
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32601, 'message': 'Método não suportado: $method'},
    };
  }

  static String _randomToken() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
