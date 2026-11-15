import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/shared_folder/shared_folder_crypto.dart';
import 'package:gestor_ufu/orchestrator/application/ai_memory.dart';

/// Leva a memória do AI Memory entre computadores pela pasta compartilhada,
/// com UM computador ativo por vez (o banco do AI Memory é SQLite: abrir o
/// mesmo arquivo em dois computadores pela nuvem o corromperia).
///
/// - Posse: `ai-memoria/posse.json` (computador + batida a cada minuto).
///   Posse de outro computador com batida recente = esta máquina usa só a
///   memória local, sem enviar. Sem batida há 3 min = pode assumir.
/// - Ao assumir: se a pasta tem uma cópia mais nova de outro computador,
///   restaura com `ai-memory restore` antes de subir o servidor.
/// - Enquanto dono: `ai-memory backup` (online) cifrado em
///   `ai-memoria/memoria.gbk` a cada 10 min e ao sair.
class AiMemoryShare {
  AiMemoryShare(this.runtime, this.openCrypto, {String? machine})
    : machine = machine ?? Platform.localHostname;

  final AiMemoryRuntime runtime;
  final Future<SharedFolderCrypto?> Function() openCrypto;
  final String machine;

  static const dirName = 'ai-memoria';
  static const snapshotName = 'memoria.gbk';
  static const leaseName = 'posse.json';
  static const staleAfter = Duration(minutes: 3);

  SharedFolderCrypto? _crypto;
  Timer? _heartbeat;
  Timer? _export;
  bool owner = false;
  String status = 'Memória só neste computador';

  String get _dir => p.join(_crypto!.folder, dirName);
  File get _lease => File(p.join(_dir, leaseName));
  File get _snapshot => File(p.join(_dir, snapshotName));
  File get _marker => File(p.join(runtime.root, 'compartilhamento.json'));

  Future<Map<String, dynamic>> _readJson(File file) async {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } on Object {
      return {};
    }
  }

  Future<void> _writeLease() async {
    await Directory(_dir).create(recursive: true);
    await _crypto!.writeAtomic(
      _lease.path,
      utf8.encode(
        jsonEncode({
          'computador': machine,
          'batida': DateTime.now().toUtc().toIso8601String(),
        }),
      ),
    );
  }

  /// Antes de subir o servidor: assume a posse (se livre) e restaura a
  /// cópia mais nova da pasta.
  Future<void> beforeStart() async {
    _crypto = await openCrypto();
    if (_crypto == null) {
      status = 'Memória só neste computador (pasta compartilhada desligada)';
      return;
    }
    final lease = await _readJson(_lease);
    final holder = '${lease['computador'] ?? ''}';
    final beat = DateTime.tryParse('${lease['batida']}');
    if (holder.isNotEmpty &&
        holder != machine &&
        beat != null &&
        DateTime.now().toUtc().difference(beat) < staleAfter) {
      owner = false;
      status =
          'Memória em uso em $holder: aqui ela fica só local até lá fechar o '
          'Gestor';
      return;
    }
    await _writeLease();
    owner = true;
    status = 'Memória compartilhada pela pasta';
    await _restoreIfNewer();
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(minutes: 1), (_) async {
      final current = await _readJson(_lease);
      if ('${current['computador'] ?? machine}' != machine) {
        // Outro computador assumiu (este ficou suspenso): para de enviar.
        owner = false;
        status = 'Memória assumida por ${current['computador']}';
        _heartbeat?.cancel();
        _export?.cancel();
        return;
      }
      await _writeLease();
    });
  }

  Future<void> _restoreIfNewer() async {
    final data = await SharedFolderCrypto.readStable(_snapshot.path);
    if (data == null) return;
    final header = SharedFolderCrypto.readHeader(data);
    final remoteAt = DateTime.tryParse('${header['salvoEm']}');
    final marker = await _readJson(_marker);
    final localAt =
        [
          DateTime.tryParse('${marker['importado']}'),
          DateTime.tryParse('${marker['exportado']}'),
        ].whereType<DateTime>().fold<DateTime?>(
          null,
          (a, b) => a == null || b.isAfter(a) ? b : a,
        );
    if (remoteAt == null ||
        header['computador'] == machine ||
        (localAt != null && !remoteAt.isAfter(localAt))) {
      return;
    }
    final exe = await runtime.executable();
    if (exe == null) return;
    runtime.stop();
    final tar = File(
      p.join(Directory.systemTemp.path, 'gestor-ai-memory-restore.tar.gz'),
    );
    try {
      await tar.writeAsBytes(await _crypto!.decryptBytes(data), flush: true);
      // Configuração e token deste computador antes de restaurar: o
      // backup traz só os dados (o token nunca sai do computador).
      await runtime.initialize();
      final result = await Process.run(exe, [
        '--data-dir',
        runtime.dataDir,
        '--config',
        runtime.configPath,
        'restore',
        '--from',
        tar.path,
      ], workingDirectory: runtime.root).timeout(const Duration(minutes: 3));
      if (result.exitCode != 0) {
        status = 'Não foi possível restaurar a memória: ${result.stderr}';
        return;
      }
      await _marker.writeAsString(
        jsonEncode({
          ...marker,
          'importado': remoteAt.toIso8601String(),
          'de': header['computador'],
        }),
      );
      status = 'Memória restaurada de ${header['computador']}';
    } finally {
      if (await tar.exists()) await tar.delete();
    }
  }

  /// Depois de subir o servidor: envia uma cópia a cada 10 minutos.
  void startAutoExport() {
    if (!owner) return;
    _export?.cancel();
    _export = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(export()),
    );
  }

  /// Backup online do AI Memory, cifrado na pasta.
  Future<bool> export() async {
    final url = runtime.url;
    final exe = await runtime.executable();
    if (!owner || _crypto == null || url == null || exe == null) return false;
    final tar = File(
      p.join(
        Directory.systemTemp.path,
        'gestor-ai-memory-${DateTime.now().microsecondsSinceEpoch}.tar.gz',
      ),
    );
    try {
      final result = await Process.run(
        exe,
        [
          '--data-dir',
          runtime.dataDir,
          '--config',
          runtime.configPath,
          'backup',
          '--to',
          tar.path,
        ],
        workingDirectory: runtime.root,
        environment: {'AI_MEMORY_SERVER_URL': url},
      ).timeout(const Duration(minutes: 3));
      if (result.exitCode != 0 || !await tar.exists()) {
        status = 'Falha ao salvar a memória na pasta: ${result.stderr}';
        return false;
      }
      final now = DateTime.now().toUtc();
      await Directory(_dir).create(recursive: true);
      await _crypto!.writeAtomic(
        _snapshot.path,
        await _crypto!.encryptBytes(
          await tar.readAsBytes(),
          header: {
            'salvoEm': now.toIso8601String(),
            'computador': machine,
            'versao': AiMemoryRelease.version,
          },
        ),
      );
      final marker = await _readJson(_marker);
      await _marker.writeAsString(
        jsonEncode({...marker, 'exportado': now.toIso8601String()}),
      );
      status =
          'Memória salva na pasta às ${now.toLocal().hour}:'
          '${now.toLocal().minute.toString().padLeft(2, '0')}';
      return true;
    } on Object catch (error) {
      status = 'Falha ao salvar a memória na pasta: $error';
      return false;
    } finally {
      if (await tar.exists()) await tar.delete();
    }
  }

  /// Ao sair: salva a última versão e libera a posse.
  Future<void> release() async {
    _heartbeat?.cancel();
    _export?.cancel();
    if (!owner || _crypto == null) return;
    await export();
    try {
      final lease = await _readJson(_lease);
      if (lease['computador'] == machine) await _lease.delete();
    } on Object {
      // A posse expira sozinha em 3 minutos.
    }
    owner = false;
  }
}
