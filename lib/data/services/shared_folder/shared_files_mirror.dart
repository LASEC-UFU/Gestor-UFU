import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/shared_folder/shared_folder_crypto.dart';
import 'package:gestor_ufu/data/services/shared_preferences_sync_service.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

/// Espelha os arquivos gerados pelo Gestor e pelo agente
/// (`Documentos\GestorUFU Agente`) na pasta compartilhada (`arquivos/`),
/// cifrados com a mesma senha, para aparecerem no outro computador.
///
/// - Novo ou alterado aqui: envia. Novo ou alterado lá: baixa.
/// - Alterado nos dois: guarda as duas versões (a de lá ganha o sufixo
///   "(de NOME-DO-COMPUTADOR)"); nada é sobrescrito.
/// - Apagar num computador não apaga no outro (segurança).
class SharedFilesMirror {
  SharedFilesMirror(
    this.sync, {
    String? localRoot,
    this.interval = const Duration(seconds: 60),
  }) : _localRoot = localRoot;

  final SharedPreferencesSyncService sync;
  final Duration interval;
  final String? _localRoot;

  static const remoteDir = 'arquivos';
  static const ext = '.gfa';
  static const maxBytes = 50 * 1024 * 1024;

  Timer? _timer;
  bool _busy = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(syncOnce()));
    unawaited(syncOnce());
  }

  void stop() => _timer?.cancel();

  Future<String> _local() async => _localRoot ?? await GestorPaths.outputDir();

  static bool _skip(String name) =>
      name.startsWith('~\$') ||
      name.startsWith('.') ||
      name.endsWith('.tmp') ||
      name.endsWith('.part');

  /// Uma rodada (também chamada pelos testes).
  Future<void> syncOnce({SharedFolderCrypto? crypto, String? stateDir}) async {
    final c = crypto ?? sync.crypto;
    if (c == null || _busy) return;
    _busy = true;
    try {
      final localRoot = await _local();
      final remoteRoot = p.join(c.folder, remoteDir);
      final stateFile = File(
        p.join(
          stateDir ?? SharedPreferencesSyncService.stateDirFor(c.folder),
          'arquivos.json',
        ),
      );
      Map<String, dynamic> state;
      try {
        state = Map<String, dynamic>.from(
          jsonDecode(await stateFile.readAsString()) as Map,
        );
      } on Object {
        state = {};
      }

      Future<String> stamp(File file) async {
        final st = await file.stat();
        return '${st.size}:${st.modified.millisecondsSinceEpoch}';
      }

      final locals = <String, File>{};
      if (await Directory(localRoot).exists()) {
        await for (final e in Directory(localRoot).list(recursive: true)) {
          if (e is File && !_skip(p.basename(e.path))) {
            locals[p.relative(e.path, from: localRoot).replaceAll('\\', '/')] =
                e;
          }
        }
      }
      final remotes = <String, File>{};
      if (await Directory(remoteRoot).exists()) {
        await for (final e in Directory(remoteRoot).list(recursive: true)) {
          final name = p.basename(e.path);
          if (e is File && name.endsWith(ext) && !name.contains(' (')) {
            final rel = p
                .relative(e.path, from: remoteRoot)
                .replaceAll('\\', '/');
            remotes[rel.substring(0, rel.length - ext.length)] = e;
          }
        }
      }

      Future<void> upload(String rel, File file) async {
        if (await file.length() > maxBytes) return;
        final bytes = await file.readAsBytes();
        final modified = (await file.stat()).modified;
        final target = p.join(remoteRoot, '$rel$ext');
        await Directory(p.dirname(target)).create(recursive: true);
        await c.writeAtomic(
          target,
          await c.encryptBytes(
            bytes,
            header: {
              'arquivo': rel,
              'modificado': modified.toUtc().toIso8601String(),
              'computador': Platform.localHostname,
            },
          ),
        );
        state[rel] = {
          'local': await stamp(file),
          'remote': await stamp(File(target)),
        };
      }

      Future<void> download(String rel, File remote, {String? asName}) async {
        final data = await SharedFolderCrypto.readStable(remote.path);
        if (data == null) return;
        final header = SharedFolderCrypto.readHeader(data);
        final clear = await c.decryptBytes(data);
        final path = asName ?? p.join(localRoot, rel);
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(clear, flush: true);
        final modified = DateTime.tryParse('${header['modificado']}');
        if (modified != null) await file.setLastModified(modified.toLocal());
        if (asName == null) {
          state[rel] = {
            'local': await stamp(file),
            'remote': await stamp(remote),
          };
        }
      }

      for (final entry in locals.entries) {
        final info = state[entry.key] as Map?;
        final localNow = await stamp(entry.value);
        if (info != null && info['local'] == localNow) continue;
        final remote = remotes[entry.key];
        if (info != null &&
            remote != null &&
            info['remote'] != await stamp(remote)) {
          // Alterado nos dois: guarda a versão do outro computador ao lado.
          final header = SharedFolderCrypto.readHeader(
            (await SharedFolderCrypto.readStable(remote.path))!,
          );
          final other = '${header['computador'] ?? 'outro computador'}';
          final local = entry.value.path;
          await download(
            entry.key,
            remote,
            asName:
                '${p.withoutExtension(local)} (de $other)${p.extension(local)}',
          );
        }
        await upload(entry.key, entry.value);
      }
      for (final entry in remotes.entries) {
        final info = state[entry.key] as Map?;
        final remoteNow = await stamp(entry.value);
        final local = locals[entry.key];
        if (local == null) {
          // Apagado aqui de propósito: não baixa de novo.
          if (info != null && info['remote'] == remoteNow) continue;
          await download(entry.key, entry.value);
        } else if (info == null || info['remote'] != remoteNow) {
          await download(entry.key, entry.value);
        }
      }
      await stateFile.parent.create(recursive: true);
      await stateFile.writeAsString(jsonEncode(state));
    } on Object {
      // Pasta indisponível (Drive offline): tenta na próxima rodada.
    } finally {
      _busy = false;
    }
  }
}
