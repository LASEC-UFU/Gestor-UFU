import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class RemoteApi {
  RemoteApi({
    required this.host,
    required this.port,
    required this.token,
    required this.fingerprint,
  });
  final String host;
  final int port;
  final String token;
  final String fingerprint;

  String get _expectedFingerprint =>
      fingerprint.replaceAll(RegExp('[^0-9a-fA-F]'), '').toLowerCase();
  Uri _uri(String path) =>
      Uri(scheme: 'https', host: host, port: port, path: path);
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  bool _matchesPin(X509Certificate certificate) =>
      _expectedFingerprint.isNotEmpty &&
      sha256.convert(certificate.der).toString() == _expectedFingerprint;

  /// Verifica a impressão digital mesmo se o Android confiar na CA apresentada.
  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // Disable ambient CA trust so every server certificate is accepted only
    // when its DER SHA-256 matches the fingerprint enrolled by the user.
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.badCertificateCallback = (certificate, _, _) =>
        _matchesPin(certificate);
    try {
      final request = await client.openUrl(method, _uri(path)).timeout(timeout);
      headers?.forEach(request.headers.set);
      if (body is String) {
        request.write(body);
      } else if (body is List<int>) {
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      final peer = response.certificate;
      if (peer == null || !_matchesPin(peer)) {
        await response.drain<void>();
        throw const HandshakeException(
          'O certificado do computador não corresponde ao fingerprint pareado.',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(', ');
      });
      return http.Response.bytes(
        bytes.takeBytes(),
        response.statusCode,
        headers: responseHeaders,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> check() async {
    final health = await _request(
      'GET',
      '/health',
      timeout: const Duration(seconds: 8),
    );
    if (health.statusCode != 200) {
      final decoded = jsonDecode(utf8.decode(health.bodyBytes));
      final body = decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
      final message = body['error']?.toString();
      final sourceAddress = body['sourceAddress']?.toString();
      if (health.statusCode == 403 && sourceAddress != null) {
        throw HttpException(
          'O Windows recebeu a conexÃ£o do IP $sourceAddress, mas ele nÃ£o estÃ¡ autorizado. '
          'No CIDR do Gestor UFU, permita somente esse IP usando /32 (por exemplo, $sourceAddress/32).',
        );
      }
      throw HttpException(
        message == null || message.isEmpty
            ? 'Computador respondeu ${health.statusCode}.'
            : 'Computador respondeu ${health.statusCode}: $message',
      );
    }
    final response = await _request(
      'GET',
      '/api/v1/modules',
      headers: _headers,
      timeout: const Duration(seconds: 8),
    );
    if (response.statusCode == 401)
      throw const HttpException('Token incorreto ou revogado.');
    if (response.statusCode != 200)
      throw HttpException(
        'Falha ao consultar módulos (${response.statusCode}).',
      );
  }

  Future<List<Map<String, dynamic>>> modules() async {
    final response = await _request(
      'GET',
      '/api/v1/modules',
      headers: _headers,
    );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200)
      throw HttpException('${data['error'] ?? response.statusCode}');
    return (data['modules'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> runCommand(
    String id,
    Map<String, dynamic> input, {
    required bool confirmed,
  }) async {
    final key =
        '${DateTime.now().microsecondsSinceEpoch}-$id-${List<int>.generate(8, (_) => Random.secure().nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _request(
          'POST',
          '/api/v1/tasks',
          headers: {..._headers, 'Idempotency-Key': key},
          body: jsonEncode({
            'commandId': id,
            'input': input,
            'confirmed': confirmed,
          }),
          timeout: const Duration(seconds: 20),
        );
        final data = Map<String, dynamic>.from(
          jsonDecode(response.body) as Map,
        );
        if (response.statusCode != 202)
          throw HttpException('${data['error'] ?? response.statusCode}');
        return data;
      } on SocketException catch (_) {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      } on HandshakeException {
        rethrow;
      } on HttpException {
        rethrow;
      } catch (_) {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw const SocketException(
      'Não foi possível confirmar o recebimento da operação. Consulte as tarefas do computador antes de repetir.',
    );
  }

  Future<Map<String, dynamic>> task(String id) async {
    final response = await _request(
      'GET',
      '/api/v1/tasks/$id',
      headers: _headers,
    );
    final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (response.statusCode != 200)
      throw HttpException('${data['error'] ?? response.statusCode}');
    return data;
  }

  Future<List<Map<String, dynamic>>> tasks() async {
    final response = await _request(
      'GET',
      '/api/v1/tasks',
      headers: _headers,
      timeout: const Duration(seconds: 10),
    );
    final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (response.statusCode != 200)
      throw HttpException('${data['error'] ?? response.statusCode}');
    return (data['tasks'] as List? ?? const [])
        .map((task) => Map<String, dynamic>.from(task as Map))
        .toList();
  }

  Future<void> cancelTask(String id) async {
    final response = await _request(
      'DELETE',
      '/api/v1/tasks/$id',
      headers: _headers,
      timeout: const Duration(seconds: 10),
    );
    if (response.statusCode != 202) {
      final data = jsonDecode(response.body) as Map;
      throw HttpException('${data['error'] ?? response.statusCode}');
    }
  }

  Future<Map<String, dynamic>> upload(String name, List<int> bytes) async {
    if (bytes.length > 100 * 1024 * 1024)
      throw const HttpException('O limite por arquivo é 100 MB.');
    final response = await _request(
      'POST',
      '/api/v1/files',
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
        'X-File-Name': Uri.encodeComponent(name),
      },
      body: bytes,
      timeout: const Duration(minutes: 3),
    );
    final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (response.statusCode != 201)
      throw HttpException('${data['error'] ?? response.statusCode}');
    return data;
  }

  Future<List<int>> download(String id) async {
    final response = await _request(
      'GET',
      '/api/v1/files/$id',
      headers: _headers,
      timeout: const Duration(minutes: 3),
    );
    if (response.statusCode != 200)
      throw HttpException('Download falhou (${response.statusCode}).');
    return response.bodyBytes;
  }

  Future<void> sendAgentMessage(String text) async {
    final response = await _request(
      'POST',
      '/api/v1/agent/message',
      headers: _headers,
      body: jsonEncode({'text': text}),
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode != 202) {
      final data = jsonDecode(response.body) as Map;
      throw HttpException('${data['error'] ?? response.statusCode}');
    }
  }

  Future<void> cancelAgentMessage() async {
    final response = await _request(
      'POST',
      '/api/v1/agent/cancel',
      headers: _headers,
      body: '{}',
      timeout: const Duration(seconds: 15),
    );
    if (response.statusCode != 202) {
      final data = jsonDecode(response.body) as Map;
      throw HttpException('${data['error'] ?? response.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> approvals() async {
    final response = await _request(
      'GET',
      '/api/v1/agent/approvals',
      headers: _headers,
      timeout: const Duration(seconds: 10),
    );
    if (response.statusCode != 200) return const [];
    final data = jsonDecode(response.body) as Map;
    return (data['approvals'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> history() async {
    final response = await _request(
      'GET',
      '/api/v1/agent/history',
      headers: _headers,
      timeout: const Duration(seconds: 10),
    );
    if (response.statusCode != 200) return const [];
    final data = jsonDecode(response.body) as Map;
    return (data['messages'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> agentStatus() async {
    final response = await _request(
      'GET',
      '/api/v1/agent/status',
      headers: _headers,
      timeout: const Duration(seconds: 10),
    );
    if (response.statusCode != 200) return const {};
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> answerApproval(String id, bool approved) async {
    final response = await _request(
      'POST',
      '/api/v1/agent/approvals/$id',
      headers: _headers,
      body: jsonEncode({'approved': approved}),
      timeout: const Duration(seconds: 10),
    );
    if (response.statusCode != 200)
      throw HttpException(
        'A confirmação expirou ou foi recusada pelo computador.',
      );
  }

  Future<WebSocket> events() {
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.badCertificateCallback = (certificate, _, _) =>
        _matchesPin(certificate);
    return WebSocket.connect(
      _uri('/api/v1/events').replace(scheme: 'wss').toString(),
      headers: {'Authorization': 'Bearer $token'},
      customClient: client,
    ).timeout(const Duration(seconds: 10));
  }

  static Future<void> save({
    required String host,
    required String port,
    required String token,
    required String fingerprint,
  }) async {
    const vault = FlutterSecureStorage();
    await vault.write(key: 'remote.host', value: host.trim());
    await vault.write(key: 'remote.port', value: port.trim());
    await vault.write(key: 'remote.token', value: token.trim());
    await vault.write(key: 'remote.fingerprint', value: fingerprint.trim());
  }

  static Future<Map<String, String>> load() async {
    const vault = FlutterSecureStorage();
    return {
      'host': await vault.read(key: 'remote.host') ?? '',
      'port': await vault.read(key: 'remote.port') ?? '48761',
      'token': await vault.read(key: 'remote.token') ?? '',
      'fingerprint': await vault.read(key: 'remote.fingerprint') ?? '',
    };
  }
}
