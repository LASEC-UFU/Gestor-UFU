import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// Erro da pasta compartilhada (senha errada, formato inválido…).
class SharedFolderException implements Exception {
  const SharedFolderException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Criptografia da pasta compartilhada do Gestor UFU (banco dividido por
/// módulo, arquivos gerados e memória do AI Memory).
///
/// A senha vira uma chave AES-256 uma única vez por sessão (PBKDF2-SHA256,
/// 210 mil iterações, com o "sal" do manifesto). Cada arquivo é cifrado com
/// AES-GCM e um nonce aleatório próprio; o manifesto guarda um texto de
/// verificação para saber, sem tocar nos dados, se a senha está certa.
class SharedFolderCrypto {
  SharedFolderCrypto._(this.folder, this._key);

  static const manifestName = 'gestor-ufu.manifesto.json';
  static const format = 'gestor_ufu_shared_folder';
  static const version = 2;
  static const iterations = 210000;
  static const _check = 'gestor-ufu-pasta-ok';
  static const _fileMagic = 'GUFU2';

  final String folder;
  final List<int> _key;

  static final _aes = AesGcm.with256bits();

  static Future<List<int>> _derive(String password, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return key.extractBytes();
  }

  static List<int> _random(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static bool hasManifest(String folder) =>
      File(p.join(folder, manifestName)).existsSync();

  /// Cria a pasta (manifesto novo) ou abre a existente conferindo a senha.
  static Future<SharedFolderCrypto> open(
    String folder,
    String password, {
    bool create = false,
  }) async {
    final manifest = File(p.join(folder, manifestName));
    if (!await manifest.exists()) {
      if (!create) {
        throw const SharedFolderException(
          'A pasta escolhida não é um banco compartilhado do Gestor UFU.',
        );
      }
      await Directory(folder).create(recursive: true);
      final salt = _random(16);
      final key = await _derive(password, salt);
      final crypto = SharedFolderCrypto._(folder, key);
      final check = await crypto.encryptText(_check);
      await crypto.writeAtomic(
        manifest.path,
        utf8.encode(
          const JsonEncoder.withIndent('  ').convert({
            'format': format,
            'version': version,
            'kdf': 'pbkdf2-sha256',
            'iterations': iterations,
            'salt': base64Encode(salt),
            'check': check,
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          }),
        ),
      );
      return crypto;
    }
    final json = jsonDecode(await manifest.readAsString());
    if (json is! Map ||
        json['format'] != format ||
        (json['version'] as num?)?.toInt() != version) {
      throw const SharedFolderException(
        'Manifesto da pasta compartilhada inválido ou de versão diferente.',
      );
    }
    final key = await _derive(password, base64Decode('${json['salt']}'));
    final crypto = SharedFolderCrypto._(folder, key);
    try {
      if (await crypto.decryptText(json['check']) != _check) throw Error();
    } on Object {
      throw const SharedFolderException(
        'Senha incorreta para esta pasta compartilhada.',
      );
    }
    return crypto;
  }

  // ------------------------------------------------------------ Texto (JSON)

  /// Envelope JSON `{nonce, cipherText, mac}` de um texto.
  Future<Map<String, String>> encryptText(String plain) async {
    final box = await _aes.encrypt(
      utf8.encode(plain),
      secretKey: SecretKey(_key),
      nonce: _random(12),
    );
    return {
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  Future<String> decryptText(Object? envelope) async {
    if (envelope is! Map) {
      throw const SharedFolderException('Conteúdo cifrado inválido.');
    }
    final clear = await _aes.decrypt(
      SecretBox(
        base64Decode('${envelope['cipherText']}'),
        nonce: base64Decode('${envelope['nonce']}'),
        mac: Mac(base64Decode('${envelope['mac']}')),
      ),
      secretKey: SecretKey(_key),
    );
    return utf8.decode(clear);
  }

  // ------------------------------------------------------------ Binário

  /// Cifra bytes (arquivos, backup do AI Memory) num isolate, para não
  /// travar a tela. Formato: "GUFU2" + tamanho do cabeçalho (4 bytes) +
  /// cabeçalho JSON (metadados, sem segredo) + nonce (12) + mac (16) +
  /// conteúdo cifrado.
  Future<Uint8List> encryptBytes(
    List<int> plain, {
    Map<String, Object?> header = const {},
  }) async {
    final key = _key;
    final nonce = _random(12);
    return Isolate.run(() async {
      final box = await AesGcm.with256bits().encrypt(
        plain,
        secretKey: SecretKey(key),
        nonce: nonce,
      );
      final head = utf8.encode(jsonEncode(header));
      final out = BytesBuilder(copy: false)
        ..add(ascii.encode(_fileMagic))
        ..add((ByteData(4)..setUint32(0, head.length)).buffer.asUint8List())
        ..add(head)
        ..add(box.nonce)
        ..add(box.mac.bytes)
        ..add(box.cipherText);
      return out.toBytes();
    });
  }

  /// Só o cabeçalho (sem decifrar o conteúdo).
  static Map<String, Object?> readHeader(Uint8List data) {
    if (data.length < 9 || ascii.decode(data.sublist(0, 5)) != _fileMagic) {
      throw const SharedFolderException('Arquivo cifrado inválido.');
    }
    final length = ByteData.sublistView(data, 5, 9).getUint32(0);
    return Map<String, Object?>.from(
      jsonDecode(utf8.decode(data.sublist(9, 9 + length))) as Map,
    );
  }

  Future<Uint8List> decryptBytes(Uint8List data) async {
    readHeader(data);
    final key = _key;
    return Isolate.run(() async {
      final length = ByteData.sublistView(data, 5, 9).getUint32(0);
      var offset = 9 + length;
      final nonce = data.sublist(offset, offset += 12);
      final mac = data.sublist(offset, offset += 16);
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(data.sublist(offset), nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
      );
      return Uint8List.fromList(clear);
    });
  }

  // ------------------------------------------------------------ Disco

  /// Grava de forma atômica: arquivo temporário numa subpasta `.tmp` e
  /// troca no fim (o Google Drive nunca vê um arquivo pela metade).
  Future<void> writeAtomic(String path, List<int> bytes) async {
    final target = File(path);
    final tmpDir = Directory(p.join(target.parent.path, '.tmp'));
    await tmpDir.create(recursive: true);
    final temp = File(
      p.join(
        tmpDir.path,
        '${p.basename(path)}.${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temp.writeAsBytes(bytes, flush: true);
    for (var attempt = 0; ; attempt++) {
      try {
        if (await target.exists()) await target.delete();
        await temp.rename(path);
        return;
      } on FileSystemException {
        // O Google Drive pode estar segurando o arquivo por um instante.
        if (attempt >= 5) {
          if (await temp.exists()) await temp.delete();
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }

  /// Lê um arquivo só quando duas leituras seguidas coincidem (o Drive pode
  /// expor o arquivo enquanto ainda está baixando).
  static Future<Uint8List?> readStable(String path) async {
    final file = File(path);
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (!await file.exists()) return null;
        final first = await file.readAsBytes();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final second = await file.readAsBytes();
        if (first.length == second.length && _equal(first, second)) {
          return second;
        }
      } on FileSystemException {
        // Arquivo em uso pelo Drive: tenta de novo.
      }
      await Future<void>.delayed(Duration(milliseconds: 180 * (attempt + 1)));
    }
    throw SharedFolderException('O arquivo $path ainda está sendo atualizado.');
  }

  static bool _equal(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
