import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/orchestrator/application/orq_memory.dart';
import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';
import 'package:gestor_ufu/orchestrator/domain/secret_redaction.dart';

/// Release oficial do AI Memory usada pelo Gestor (mesma fixada pelo
/// Orchestrator-AI em `upstream-releases.json`). AI Memory é MIT:
/// Copyright (c) 2026 Fabio Akita (akitaonrails/ai-memory).
class AiMemoryRelease {
  static const repository = 'akitaonrails/ai-memory';
  static const version = 'v3.4.5';
  static const url =
      'https://github.com/akitaonrails/ai-memory/releases/download/v3.4.5/'
      'ai-memory-windows-x86_64.zip';
  static const sha256Hex =
      '2166ba0cdd2e65029bd2350fe256abb97c9dbb7a346d8f588b625ae7527acef3';
  static const sizeBytes = 27147495;
}

class AiMemoryException implements Exception {
  const AiMemoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Runtime oficial do AI Memory gerenciado pelo Gestor (port de
/// `aiMemoryRuntime.js` / `managedRuntimeSetup.js`): baixa a release fixada,
/// confere tamanho e SHA-256, extrai com segurança numa pasta privada, roda
/// `init` e `serve` só em loopback e conversa pelo MCP HTTP (`/mcp`).
class AiMemoryRuntime {
  AiMemoryRuntime({String? root, HttpClient Function()? http})
    : root = root ?? _defaultRoot(),
      _http = http ?? HttpClient.new;

  final String root;
  final HttpClient Function() _http;
  Process? _server;
  String? _url;

  static String _defaultRoot() => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'GestorUFU',
    'ai-memory',
  );

  String get installDir => p.join(root, AiMemoryRelease.version);
  String get dataDir => p.join(root, 'data');
  String get configPath => p.join(dataDir, 'config.toml');
  String get endpointPath => p.join(root, 'endpoint.json');

  /// URL do servidor (ex.: http://127.0.0.1:5123) quando ativo.
  String? get url => _url;
  String? get mcpUrl => _url == null ? null : '$_url/mcp';

  /// Executável já instalado (ou null).
  Future<String?> executable() async {
    final dir = Directory(installDir);
    if (!await dir.exists()) return null;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File &&
          p.basename(entity.path).toLowerCase() == 'ai-memory.exe') {
        return entity.path;
      }
    }
    return null;
  }

  /// Baixa e instala a release fixada. [onProgress] recebe 0..1.
  Future<String> install({
    void Function(double progress)? onProgress,
    String url = AiMemoryRelease.url,
    String sha256Hex = AiMemoryRelease.sha256Hex,
    int sizeBytes = AiMemoryRelease.sizeBytes,
  }) async {
    final existing = await executable();
    if (existing != null) return existing;
    await Directory(root).create(recursive: true);
    final part = File(
      p.join(
        root,
        'ai-memory-${AiMemoryRelease.version}-'
        '${DateTime.now().microsecondsSinceEpoch}.zip.part',
      ),
    );
    final client = _http();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw AiMemoryException(
          'Download do AI Memory falhou (HTTP ${response.statusCode}).',
        );
      }
      final sink = part.openWrite();
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > sizeBytes) {
          await sink.close();
          throw const AiMemoryException(
            'O arquivo baixado é maior que a release fixada; instalação '
            'recusada.',
          );
        }
        sink.add(chunk);
        hasher.add(chunk);
        onProgress?.call(received / sizeBytes);
      }
      await sink.close();
      hasher.close();
      if (received != sizeBytes || digestSink.value.toString() != sha256Hex) {
        throw const AiMemoryException(
          'O SHA-256 do AI Memory baixado não confere com a release fixada; '
          'instalação recusada.',
        );
      }
      await extractZip(await part.readAsBytes(), installDir);
    } finally {
      client.close(force: true);
      if (await part.exists()) await part.delete();
    }
    final exe = await executable();
    if (exe == null) {
      throw const AiMemoryException(
        'O pacote do AI Memory não contém ai-memory.exe.',
      );
    }
    return exe;
  }

  /// Extrai o zip sem permitir caminhos para fora de [target].
  static Future<void> extractZip(List<int> bytes, String target) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final base = p.normalize(p.absolute(target));
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      if (name.isEmpty ||
          name.startsWith('/') ||
          name.split('/').any((s) => s == '..') ||
          RegExp(r'^[A-Za-z]:').hasMatch(name)) {
        throw AiMemoryException('Caminho inválido no pacote: ${file.name}');
      }
      final out = p.normalize(p.join(base, name));
      if (!p.isWithin(base, out) && out != base) {
        throw AiMemoryException('Caminho inválido no pacote: ${file.name}');
      }
      if (file.isFile) {
        await File(out).parent.create(recursive: true);
        await File(out).writeAsBytes(file.content as List<int>);
      } else {
        await Directory(out).create(recursive: true);
      }
    }
  }

  Future<bool> healthy(String url) async {
    final client = _http()
      ..connectionTimeout = const Duration(milliseconds: 700);
    try {
      final request = await client.getUrl(Uri.parse('$url/healthz'));
      final response = await request.close().timeout(
        const Duration(milliseconds: 900),
      );
      if (response.statusCode != 200) return false;
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      return body is Map && body['status'] == 'ok';
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Garante o servidor ativo (reaproveita o que estiver no endpoint salvo).
  Future<String> ensureServer() async {
    final current = _url;
    if (current != null && await healthy(current)) return current;
    final exe = await executable();
    if (exe == null) {
      throw const AiMemoryException(
        'O AI Memory não está instalado. Instale nas configurações do '
        'Orquestrador.',
      );
    }
    await Directory(dataDir).create(recursive: true);
    if (!await File(configPath).exists()) {
      final init = await Process.run(exe, [
        '--data-dir',
        dataDir,
        '--config',
        configPath,
        'init',
      ], workingDirectory: root).timeout(const Duration(seconds: 60));
      if (init.exitCode != 0) {
        throw AiMemoryException('ai-memory init falhou: ${init.stderr}');
      }
    }
    try {
      final saved = jsonDecode(await File(endpointPath).readAsString());
      final savedUrl = saved is Map ? '${saved['url'] ?? ''}' : '';
      if (savedUrl.startsWith('http://127.0.0.1:') && await healthy(savedUrl)) {
        return _url = savedUrl;
      }
    } on Object {
      // Sem endpoint salvo: sobe um servidor novo.
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final process = await Process.start(exe, [
      '--data-dir',
      dataDir,
      '--config',
      configPath,
      'serve',
      '--transport',
      'http',
      '--bind',
      '127.0.0.1:$port',
      '--no-watcher',
    ], workingDirectory: root);
    final stderr = StringBuffer();
    process.stderr.transform(utf8.decoder).listen((chunk) {
      stderr.write(chunk);
    });
    process.stdout.drain<void>();
    _server = process;
    final url = 'http://127.0.0.1:$port';
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    while (DateTime.now().isBefore(deadline)) {
      if (exited) break;
      if (await healthy(url)) {
        await File(endpointPath).writeAsString(
          jsonEncode({
            'url': url,
            'pid': process.pid,
            'version': AiMemoryRelease.version,
            'startedAt': DateTime.now().toIso8601String(),
          }),
        );
        return _url = url;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    process.kill();
    _server = null;
    final detail = stderr.toString().trim();
    throw AiMemoryException(
      'O servidor do AI Memory não ficou pronto.'
      '${detail.isEmpty ? '' : ' ${detail.length > 600 ? detail.substring(detail.length - 600) : detail}'}',
    );
  }

  void stop() {
    _server?.kill();
    _server = null;
    _url = null;
  }

  // ------------------------------------------------------------ MCP

  String? _session;
  int _nextId = 1;

  Future<Object?> _rpc(String method, Map<String, dynamic> params) async {
    final url = await ensureServer();
    final client = _http();
    try {
      final request = await client.postUrl(Uri.parse('$url/mcp'));
      request.headers
        ..contentType = ContentType.json
        ..set('Accept', 'application/json, text/event-stream');
      if (_session != null) request.headers.set('Mcp-Session-Id', _session!);
      final id = _nextId++;
      request.add(
        utf8.encode(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final session = response.headers.value('mcp-session-id');
      if (session != null) _session = session;
      final body = await utf8.decoder.bind(response).join();
      final json = parseRpcBody(body);
      if (json['error'] is Map) {
        final error = json['error'] as Map;
        final data = error['data'];
        throw AiMemoryException(
          '${error['message'] ?? 'Erro do AI Memory'}'
          '${data is Map && data['reason'] != null ? ' (${data['reason']})' : ''}',
        );
      }
      return json['result'];
    } finally {
      client.close(force: true);
    }
  }

  /// Corpo JSON ou SSE (`data: {...}`).
  static Map<String, dynamic> parseRpcBody(String body) {
    final text = body.trim();
    if (text.startsWith('{')) {
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    }
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        if (data.startsWith('{')) {
          return Map<String, dynamic>.from(jsonDecode(data) as Map);
        }
      }
    }
    throw const AiMemoryException('Resposta MCP do AI Memory ilegível.');
  }

  Future<void> _ensureInitialized() async {
    if (_session != null) return;
    await _rpc('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'gestor-ufu-orquestrador', 'version': '1.0'},
    });
  }

  /// Chama uma ferramenta do AI Memory e devolve o JSON da resposta.
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    await _ensureInitialized();
    final result = await _rpc('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    if (result is! Map) return const {};
    final texts = [
      for (final c in result['content'] as List? ?? const [])
        if (c is Map && c['type'] == 'text') '${c['text']}',
    ].join();
    if (result['isError'] == true) throw AiMemoryException(texts);
    try {
      final decoded = jsonDecode(texts);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : {'value': decoded};
    } on FormatException {
      return {'text': texts};
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest value = Digest(const []);
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Memória do Orquestrador no AI Memory (port de `aiMemoryKnowledge.js`):
/// uma página por tarefa e um relatório por tentativa, no escopo
/// `gestor-ufu/<projeto>`. Escreve com `create_only`, confere lendo de
/// volta e só marca "verified" quando a leitura confirma.
class AiMemoryBridge implements OrqMemoryBridge {
  AiMemoryBridge(this.runtime);

  final AiMemoryRuntime runtime;
  String _status = 'AI Memory não iniciado';
  bool _ready = false;

  static const workspace = 'gestor-ufu';

  @override
  String get statusLabel => _status;

  @override
  bool get available => _ready;

  /// Inicia o servidor se o AI Memory estiver instalado.
  Future<void> start() async {
    if (await runtime.executable() == null) {
      _status = 'AI Memory não instalado';
      _ready = false;
      return;
    }
    try {
      await runtime.ensureServer();
      _status = 'AI Memory ${AiMemoryRelease.version} ativo';
      _ready = true;
    } on Object catch (error) {
      _status = 'AI Memory com erro: $error';
      _ready = false;
    }
  }

  static String projectFor(String path) {
    final name = path.trim().isEmpty ? 'gestor' : p.basename(path.trim());
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'gestor' : slug;
  }

  static String taskPage(OrqRun run, OrqTask task) =>
      'orquestrador/tarefas/${run.id}/${task.id}.md';

  static String attemptPage(OrqRun run, OrqTask task, String provider) =>
      'orquestrador/tarefas/${run.id}/${task.id}/agentes/'
      '$provider-tentativa-${task.attempts < 1 ? 1 : task.attempts}.md';

  String _project(OrqRun run, OrqTask task) =>
      task.target == OrqTarget.gestor ? 'gestor' : projectFor(run.projectPath);

  @override
  Future<String> coordinatorContext(String query, String projectPath) async {
    if (!_ready) return '';
    try {
      final result = await runtime.callTool('memory_query', {
        'workspace': workspace,
        'project': projectFor(projectPath),
        'query': query.length > 500 ? query.substring(0, 500) : query,
      });
      final hits = result['hits'];
      if (hits is! List || hits.isEmpty) return '';
      final text = jsonEncode(hits.take(8).toList());
      return redactSensitiveText(text, max: 4000);
    } on Object {
      // Escopo inexistente ou servidor fora: sem contexto de memória.
      return '';
    }
  }

  Future<Map<String, dynamic>?> _read(String project, String path) async {
    try {
      return await runtime.callTool('memory_read_page', {
        'workspace': workspace,
        'project': project,
        'path': path,
      });
    } on Object {
      return null;
    }
  }

  @override
  Future<OrqTaskMemory> prepareTask(OrqRun run, OrqTask task) async {
    if (!_ready) return const OrqTaskMemory();
    final project = _project(run, task);
    final path = taskPage(run, task);
    final marker = 'orquestrador-tarefa: ${run.id}/${task.id}';
    var page = await _read(project, path);
    if (page == null) {
      try {
        await runtime.callTool('memory_write_page', {
          'workspace': workspace,
          'project': project,
          'path': path,
          'create_only': true,
          'body': redactSensitiveText(
            '# ${task.title}\n\n<!-- $marker -->\n\n'
            '**Objetivo:** ${task.description}\n\n'
            '**Critérios:**\n'
            '${task.acceptanceCriteria.map((c) => '- $c').join('\n')}\n\n'
            '**Pedido original:** ${run.prompt}\n',
          ),
        });
      } on Object {
        // Outra tentativa pode ter criado a página: a leitura decide.
      }
      page = await _read(project, path);
    }
    final body = '${page?['body'] ?? page?['content'] ?? ''}';
    final verified = page != null && body.contains(marker);
    final serverMcp = runtime.mcpUrl ?? '';
    return OrqTaskMemory(
      status: verified ? 'verified' : 'unverified',
      pagePath: path,
      context: verified ? redactSensitiveText(body, max: 4000) : '',
      mcpServerUrl: serverMcp,
      instructions:
          'Memória compartilhada (AI Memory, opcional): se as ferramentas '
          'ai_memory estiverem disponíveis, use o escopo workspace=$workspace, '
          'project=$project; a página da tarefa é $path e o relatório desta '
          'tentativa vai em ${attemptPage(run, task, task.provider)} '
          '(crie com create_only e confira lendo de volta). Nunca diga que '
          'leu ou gravou uma página sem confirmar.',
    );
  }

  @override
  Future<String> recordAttempt(
    OrqRun run,
    OrqTask task,
    String provider,
  ) async {
    if (!_ready) return 'unverified';
    final project = _project(run, task);
    final path = attemptPage(run, task, provider);
    if (await _read(project, path) != null) return 'verified';
    final marker = 'orquestrador-resumo: ${run.id}/${task.id}#${task.attempts}';
    try {
      await runtime.callTool('memory_write_page', {
        'workspace': workspace,
        'project': project,
        'path': path,
        'create_only': true,
        'body': redactSensitiveText(
          '# Tentativa ${task.attempts} · $provider\n\n<!-- $marker -->\n\n'
          '_Resumo gravado pelo Orquestrador (o agente não registrou o '
          'relatório)._\n\n${task.result}\n',
        ),
      });
    } on Object {
      return 'unverified';
    }
    final back = await _read(project, path);
    final body = '${back?['body'] ?? back?['content'] ?? ''}';
    return body.contains(marker) ? 'verified' : 'unverified';
  }
}
