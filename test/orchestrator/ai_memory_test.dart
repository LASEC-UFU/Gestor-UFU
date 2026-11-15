import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/orchestrator/application/ai_memory.dart';

List<int> _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}

void main() {
  late Directory root;
  late HttpServer server;
  late List<int> payload;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aimem');
    payload = _zip({
      'ai-memory/ai-memory.exe': 'binario',
      'ai-memory/LICENSE': 'MIT',
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..add(payload)
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  String url() => 'http://127.0.0.1:${server.port}/ai-memory.zip';

  test('instala só com tamanho e SHA-256 corretos', () async {
    final runtime = AiMemoryRuntime(root: root.path);
    await expectLater(
      () => runtime.install(
        url: url(),
        sha256Hex: '0' * 64,
        sizeBytes: payload.length,
      ),
      throwsA(isA<AiMemoryException>()),
    );
    expect(await runtime.executable(), isNull);
    final progress = <double>[];
    final exe = await runtime.install(
      url: url(),
      sha256Hex: sha256.convert(payload).toString(),
      sizeBytes: payload.length,
      onProgress: progress.add,
    );
    expect(p.basename(exe), 'ai-memory.exe');
    expect(progress.last, 1.0);
    expect(File(p.join(p.dirname(exe), 'LICENSE')).existsSync(), isTrue);
    // Arquivo temporário do download removido.
    expect(
      root.listSync().whereType<File>().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('recusa pacote maior que a release fixada', () async {
    final runtime = AiMemoryRuntime(root: root.path);
    await expectLater(
      () => runtime.install(
        url: url(),
        sha256Hex: sha256.convert(payload).toString(),
        sizeBytes: payload.length - 1,
      ),
      throwsA(isA<AiMemoryException>()),
    );
  });

  test('extração não sai da pasta (zip slip)', () async {
    for (final evil in ['../fora.txt', '/abs.txt', 'C:/win.txt', 'a/../../x']) {
      await expectLater(
        () => AiMemoryRuntime.extractZip(
          _zip({evil: 'x'}),
          p.join(root.path, 'dest'),
        ),
        throwsA(isA<AiMemoryException>()),
        reason: evil,
      );
    }
    expect(File(p.join(root.path, 'fora.txt')).existsSync(), isFalse);
  });

  test('resposta MCP em JSON ou SSE', () {
    expect(
      AiMemoryRuntime.parseRpcBody(
        '{"jsonrpc":"2.0","id":1,"result":{}}',
      )['id'],
      1,
    );
    expect(
      AiMemoryRuntime.parseRpcBody(
        'event: message\ndata: {"jsonrpc":"2.0","id":2,"result":{"ok":true}}\n\n',
      )['result'],
      {'ok': true},
    );
    expect(AiMemoryBridge.projectFor(r'C:\Projetos\Meu App'), 'meu-app');
    expect(AiMemoryBridge.projectFor(''), 'gestor');
  });
}
