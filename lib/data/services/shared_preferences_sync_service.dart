import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

enum SharedPreferencesSyncStatus { disconnected, connected, conflict, error }

class SharedPreferencesSyncService extends ChangeNotifier
    with WidgetsBindingObserver {
  static const metadataPrefix = '__gestor_ufu_cloud_sync_';
  static const _pathKey = '${metadataPrefix}file_path';
  static const _baselineKey = '${metadataPrefix}baseline_hash';
  static const _baselineSnapshotKey = '${metadataPrefix}baseline_snapshot';
  static const _passwordKey = '${metadataPrefix}encryption_key';
  static const _format = 'gestor_ufu_encrypted_shared_database';
  static const _version = 1;

  static const _secureStorage = FlutterSecureStorage();
  static final _aes = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 210000,
    bits: 256,
  );

  String? _filePath;
  String? _password;
  SharedPreferencesSyncStatus _status =
      SharedPreferencesSyncStatus.disconnected;
  String? _error;
  Timer? _timer;
  bool _busy = false;

  SharedPreferencesSyncStatus get status => _status;
  String? get filePath => _filePath;
  String? get error => _error;
  bool get isConnected =>
      _status != SharedPreferencesSyncStatus.disconnected && _filePath != null;

  String get statusLabel => switch (_status) {
    SharedPreferencesSyncStatus.disconnected => 'Banco local',
    SharedPreferencesSyncStatus.connected => 'Banco compartilhado conectado',
    SharedPreferencesSyncStatus.conflict => 'Conflito de sincronizaÃ§Ã£o',
    SharedPreferencesSyncStatus.error => 'Erro de sincronizaÃ§Ã£o',
  };

  SharedPreferencesSyncService() {
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _filePath = prefs.getString(_pathKey);
    if (_filePath == null || _filePath!.isEmpty) return;
    _password = await _secureStorage.read(key: _passwordKey);
    if (_password == null || _password!.isEmpty) {
      _setError(
        'A chave local de criptografia nÃ£o foi encontrada. Reconecte o arquivo compartilhado.',
      );
      return;
    }
    try {
      await _synchronize();
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          unawaited(_synchronize());
        }
      });
    } catch (error) {
      _setError('NÃ£o foi possÃ­vel sincronizar o banco compartilhado: $error');
    }
  }

  Future<void> connectToFile({
    required String filePath,
    required String password,
    required bool useSharedFile,
  }) async {
    if (password.trim().length < 8) {
      throw const FormatException('Use uma senha com pelo menos 8 caracteres.');
    }
    final file = File(filePath);
    if (useSharedFile) {
      if (!await file.exists()) {
        throw const FileSystemException('O arquivo selecionado nÃ£o existe.');
      }
      final remote = await _readRemote(filePath, password);
      await _applyPreferences(remote.preferences);
    }

    _filePath = filePath;
    _password = password;
    await _secureStorage.write(key: _passwordKey, value: password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pathKey, filePath);

    if (useSharedFile) {
      final remote = await _readRemote(filePath, password);
      await prefs.setString(_baselineKey, await _hash(remote.plainText));
      await prefs.setString(_baselineSnapshotKey, remote.plainText);
      _setStatus(SharedPreferencesSyncStatus.connected);
    } else {
      final plainText = await _localSnapshot();
      await _writeRemote(filePath, password, plainText);
      await prefs.setString(_baselineKey, await _hash(plainText));
      await prefs.setString(_baselineSnapshotKey, plainText);
      _setStatus(SharedPreferencesSyncStatus.connected);
    }
    _error = null;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_synchronize());
      }
    });
    notifyListeners();
  }

  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _filePath = null;
    _password = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pathKey);
    await prefs.remove(_baselineKey);
    await prefs.remove(_baselineSnapshotKey);
    await _secureStorage.delete(key: _passwordKey);
    _setStatus(SharedPreferencesSyncStatus.disconnected);
  }

  Future<void> resolveConflict({required bool useSharedFile}) async {
    if (_status != SharedPreferencesSyncStatus.conflict ||
        _filePath == null ||
        _password == null) {
      return;
    }
    try {
      if (useSharedFile) {
        final remote = await _readRemote(_filePath!, _password!);
        await _applyPreferences(remote.preferences);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_baselineKey, await _hash(remote.plainText));
        await prefs.setString(_baselineSnapshotKey, remote.plainText);
      } else {
        final plainText = await _localSnapshot();
        await _writeRemote(_filePath!, _password!, plainText);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_baselineKey, await _hash(plainText));
        await prefs.setString(_baselineSnapshotKey, plainText);
      }
      _error = null;
      _setStatus(SharedPreferencesSyncStatus.connected);
    } catch (error) {
      _setError('NÃ£o foi possÃ­vel resolver o conflito: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isConnected) {
      unawaited(_synchronize());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _synchronize() async {
    if (_busy || _filePath == null || _password == null) return;
    if (_status == SharedPreferencesSyncStatus.conflict) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final localText = await _localSnapshot();
      final localHash = await _hash(localText);
      final baseline = prefs.getString(_baselineKey);
      final file = File(_filePath!);
      if (!await file.exists()) {
        if (baseline == null) {
          await _writeRemote(_filePath!, _password!, localText);
          await prefs.setString(_baselineKey, localHash);
          _setStatus(SharedPreferencesSyncStatus.connected);
          return;
        }
        throw const FileSystemException(
          'O arquivo compartilhado foi removido ou movido.',
        );
      }

      final remote = await _readRemote(_filePath!, _password!);
      final remoteHash = await _hash(remote.plainText);
      if (baseline == null) {
        await _applyPreferences(remote.preferences);
        await prefs.setString(_baselineKey, remoteHash);
        await prefs.setString(_baselineSnapshotKey, remote.plainText);
        _setStatus(SharedPreferencesSyncStatus.connected);
        return;
      }

      final localChanged = localHash != baseline;
      final remoteChanged = remoteHash != baseline;
      if (localChanged && remoteChanged && localHash != remoteHash) {
        final baselineText = prefs.getString(_baselineSnapshotKey);
        final mergedText = baselineText == null
            ? null
            : _mergeSnapshots(
                baselineText: baselineText,
                localText: localText,
                remoteText: remote.plainText,
              );
        if (mergedText == null) {
          _setStatus(SharedPreferencesSyncStatus.conflict);
          return;
        }
        await _writeRemote(_filePath!, _password!, mergedText);
        final mergedHash = await _hash(mergedText);
        await prefs.setString(_baselineKey, mergedHash);
        await prefs.setString(_baselineSnapshotKey, mergedText);
        await _applyPreferences(_decodeSnapshot(mergedText));
        _error = null;
        _setStatus(SharedPreferencesSyncStatus.connected);
        return;
      }
      if (remoteChanged && !localChanged) {
        await prefs.reload();
        final latestLocalHash = await _hash(await _localSnapshot());
        if (latestLocalHash != localHash) {
          // A local edit landed while the remote snapshot was being read.
          // Preserve both copies and ask the user to resolve the conflict.
          _setStatus(SharedPreferencesSyncStatus.conflict);
          return;
        }
        await _applyPreferences(remote.preferences);
        await prefs.setString(_baselineKey, remoteHash);
        await prefs.setString(_baselineSnapshotKey, remote.plainText);
      } else if (localChanged && !remoteChanged) {
        await _writeRemote(_filePath!, _password!, localText);
        await prefs.setString(_baselineKey, localHash);
        await prefs.setString(_baselineSnapshotKey, localText);
      } else if (localChanged && remoteChanged && localHash == remoteHash) {
        await prefs.setString(_baselineKey, localHash);
        await prefs.setString(_baselineSnapshotKey, localText);
      } else {
        // Seed the merge base when this installation predates snapshots.
        await prefs.setString(_baselineSnapshotKey, remote.plainText);
      }
      _error = null;
      _setStatus(SharedPreferencesSyncStatus.connected);
    } catch (error) {
      _setError('NÃ£o foi possÃ­vel sincronizar o banco compartilhado: $error');
    } finally {
      _busy = false;
    }
  }

  Future<String> _localSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final values = <String, Object?>{};
    for (final key in prefs.getKeys().where(
      (key) => !key.startsWith(metadataPrefix),
    )) {
      values[key] = prefs.get(key);
    }
    final sorted = Map<String, Object?>.fromEntries(
      values.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode({
      'format': _format,
      'version': _version,
      'preferences': sorted,
    });
  }

  Map<String, dynamic> _decodeSnapshot(String plainText) {
    final decoded = jsonDecode(plainText);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != _format ||
        decoded['version'] != _version ||
        decoded['preferences'] is! Map) {
      throw const FormatException(
        'Snapshot local de sincroniza\u00e7\u00e3o inv\u00e1lido.',
      );
    }
    return Map<String, dynamic>.from(decoded['preferences'] as Map);
  }

  /// Merge preferences changed independently on the two computers. If both
  /// sides changed one preference to different values, retain the existing
  /// conflict flow instead of silently discarding either edit.
  String? _mergeSnapshots({
    required String baselineText,
    required String localText,
    required String remoteText,
  }) {
    final baseline = _decodeSnapshot(baselineText);
    final local = _decodeSnapshot(localText);
    final remote = _decodeSnapshot(remoteText);
    final keys = <String>{...baseline.keys, ...local.keys, ...remote.keys};
    final merged = <String, Object?>{};

    for (final key in keys) {
      final hadBaseline = baseline.containsKey(key);
      final hasLocal = local.containsKey(key);
      final hasRemote = remote.containsKey(key);
      final baselineValue = baseline[key];
      final localValue = local[key];
      final remoteValue = remote[key];
      final changedLocally =
          hasLocal != hadBaseline ||
          (hasLocal && !_sameSnapshotValue(localValue, baselineValue));
      final changedRemotely =
          hasRemote != hadBaseline ||
          (hasRemote && !_sameSnapshotValue(remoteValue, baselineValue));

      if (changedLocally && changedRemotely) {
        if (hasLocal != hasRemote ||
            (hasLocal && !_sameSnapshotValue(localValue, remoteValue))) {
          return null;
        }
        if (hasLocal) merged[key] = localValue;
      } else if (changedLocally) {
        if (hasLocal) merged[key] = localValue;
      } else if (hasRemote) {
        merged[key] = remoteValue;
      }
    }

    final sorted = Map<String, Object?>.fromEntries(
      merged.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode({
      'format': _format,
      'version': _version,
      'preferences': sorted,
    });
  }

  bool _sameSnapshotValue(Object? a, Object? b) =>
      jsonEncode(a) == jsonEncode(b);

  Future<void> _applyPreferences(Map<String, dynamic> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Validate everything first, then write replacements before removing stale
    // keys. Readers never observe an empty preference store during sync.
    for (final entry in values.entries) {
      if (entry.key.startsWith(metadataPrefix)) continue;
      final value = entry.value;
      if (value is String || value is bool || value is int || value is double) {
        continue;
      }
      if (value is List && value.every((item) => item is String)) continue;
      throw FormatException(
        'Tipo de dado inv\u00e1lido na chave ${entry.key}.',
      );
    }

    for (final entry in values.entries) {
      if (entry.key.startsWith(metadataPrefix)) continue;
      final value = entry.value;
      if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is List && value.every((item) => item is String)) {
        await prefs.setStringList(entry.key, value.cast<String>());
      }
    }

    final remoteKeys = values.keys
        .where((key) => !key.startsWith(metadataPrefix))
        .toSet();
    final staleKeys = prefs
        .getKeys()
        .where(
          (key) => !key.startsWith(metadataPrefix) && !remoteKeys.contains(key),
        )
        .toList();
    for (final key in staleKeys) {
      await prefs.remove(key);
    }
  }

  Future<_RemoteSnapshot> _readRemote(String filePath, String password) async {
    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final file = File(filePath);
        if (!await file.exists()) {
          throw const FileSystemException(
            'O arquivo compartilhado est\u00e1 sendo atualizado ou ainda n\u00e3o foi sincronizado.',
          );
        }

        // OneDrive can expose the destination during its rename/write steps.
        // Accept only identical consecutive reads and retry transient parse or
        // decryption errors rather than applying a partial snapshot.
        final firstRead = await file.readAsString();
        await Future<void>.delayed(const Duration(milliseconds: 180));
        if (!await file.exists()) {
          throw const FileSystemException(
            'O arquivo compartilhado mudou durante a sincroniza\u00e7\u00e3o.',
          );
        }
        final encoded = await file.readAsString();
        if (firstRead != encoded) {
          throw const FormatException(
            'O arquivo compartilhado ainda est\u00e1 sendo atualizado.',
          );
        }

        final outer = jsonDecode(encoded);
        if (outer is! Map<String, dynamic> ||
            outer['format'] != _format ||
            outer['version'] != _version ||
            outer['cipherText'] is! String) {
          throw const FormatException(
            'Formato do banco compartilhado inv\u00e1lido.',
          );
        }
        final salt = base64Decode(outer['salt'] as String);
        final nonce = base64Decode(outer['nonce'] as String);
        final cipherText = base64Decode(outer['cipherText'] as String);
        final mac = Mac(base64Decode(outer['mac'] as String));
        final secretKey = await _kdf.deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: salt,
        );
        final clear = await _aes.decrypt(
          SecretBox(cipherText, nonce: nonce, mac: mac),
          secretKey: secretKey,
        );
        final plainText = utf8.decode(clear);
        final inner = jsonDecode(plainText);
        if (inner is! Map<String, dynamic> ||
            inner['format'] != _format ||
            inner['version'] != _version ||
            inner['preferences'] is! Map) {
          throw const FormatException(
            'Conte?do do banco compartilhado inv\u00e1lido.',
          );
        }
        return _RemoteSnapshot(
          plainText,
          Map<String, dynamic>.from(inner['preferences'] as Map),
        );
      } on Object catch (error) {
        lastError = error;
        if (attempt < 4) {
          await Future<void>.delayed(
            Duration(milliseconds: 180 * (attempt + 1)),
          );
        }
      }
    }
    Error.throwWithStackTrace(
      lastError ??
          const FileSystemException('Falha ao ler o banco compartilhado.'),
      StackTrace.current,
    );
  }

  Future<void> _writeRemote(
    String filePath,
    String password,
    String plainText,
  ) async {
    final random = Random.secure();
    List<int> bytes(int length) =>
        List<int>.generate(length, (_) => random.nextInt(256));
    final salt = bytes(16);
    final nonce = bytes(12);
    final secretKey = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final box = await _aes.encrypt(
      utf8.encode(plainText),
      secretKey: secretKey,
      nonce: nonce,
    );
    final encoded = jsonEncode({
      'format': _format,
      'version': _version,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
    final target = File(filePath);
    await target.parent.create(recursive: true);
    final tempPath = p.join(
      target.parent.path,
      '.${p.basename(filePath)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final temp = File(tempPath);
    await temp.writeAsString(encoded, flush: true);
    final backup = File('$filePath.bak');
    if (await target.exists()) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }
    try {
      await temp.rename(filePath);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(filePath);
      }
      rethrow;
    }
  }

  Future<String> _hash(String value) async {
    final digest = await Sha256().hash(utf8.encode(value));
    return base64UrlEncode(digest.bytes);
  }

  void _setStatus(SharedPreferencesSyncStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  void _setError(String value) {
    _error = value;
    _status = SharedPreferencesSyncStatus.error;
    notifyListeners();
  }
}

class _RemoteSnapshot {
  const _RemoteSnapshot(this.plainText, this.preferences);

  final String plainText;
  final Map<String, dynamic> preferences;
}
