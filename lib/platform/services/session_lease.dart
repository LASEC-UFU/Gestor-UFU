import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Quem está com uma sessão aberta.
class LeaseInfo {
  const LeaseInfo(this.machine, this.at);

  final String machine;
  final DateTime at;

  bool get fresh =>
      DateTime.now().toUtc().difference(at) < SessionLease.staleAfter;
}

/// Posse de sessões entre computadores (docs/arquitetura/decisoes.md, D6):
/// uma sessão (conversa de agente, conversa do coordenador, rodada do
/// Orquestrador) nunca roda em dois computadores ao mesmo tempo.
///
/// Cada sessão aberta tem um arquivo `sessoes/<tipo>-<id>.json` na pasta
/// compartilhada com o computador e a última batida (a cada minuto). Posse
/// sem batida há 3 minutos está livre. Sem pasta compartilhada, tudo é
/// local e a posse é sempre deste computador.
///
/// Os arquivos ficam fora do banco sincronizado: as batidas não geram
/// conflitos nem reenvio de dados (só o computador e a hora, sem conteúdo).
class SessionLease {
  SessionLease(this.folder, {String? machine, Duration? beat})
    : machine = machine ?? Platform.localHostname,
      _beat = beat ?? const Duration(minutes: 1);

  /// Pasta compartilhada configurada (null = sem compartilhamento).
  final Future<String?> Function() folder;
  final String machine;
  final Duration _beat;

  static const staleAfter = Duration(minutes: 3);

  final _held = <String, void Function(String by)>{};
  Timer? _timer;

  static String _name(String kind, String id) =>
      '$kind-${id.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')}.json';

  Future<File?> _file(String kind, String id) async {
    final root = await folder();
    if (root == null || root.isEmpty) return null;
    return File(p.join(root, 'sessoes', _name(kind, id)));
  }

  /// Quem está com a sessão (null = ninguém ou sem pasta).
  Future<LeaseInfo?> holder(String kind, String id) async {
    final file = await _file(kind, id);
    if (file == null || !await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      final at = DateTime.tryParse('${json['batida']}');
      if (json is! Map || at == null) return null;
      return LeaseInfo('${json['computador'] ?? ''}', at);
    } on Object {
      return null;
    }
  }

  /// A sessão está aberta em outro computador agora?
  Future<LeaseInfo?> openElsewhere(String kind, String id) async {
    final info = await holder(kind, id);
    if (info == null || info.machine == machine || !info.fresh) return null;
    return info;
  }

  Future<void> _write(File file) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.$machine.tmp');
    await temp.writeAsString(
      jsonEncode({
        'computador': machine,
        'batida': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    try {
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } on FileSystemException {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Assume a sessão neste computador. [onLost] é chamado se outro
  /// computador assumir depois (este deve parar o agente da sessão).
  Future<void> take(
    String kind,
    String id, {
    required void Function(String by) onLost,
  }) async {
    final file = await _file(kind, id);
    _held['$kind\u0000$id'] = onLost;
    if (file != null) await _write(file);
    _timer ??= Timer.periodic(_beat, (_) => unawaited(heartbeat()));
  }

  /// Este computador tem a sessão?
  bool holds(String kind, String id) => _held.containsKey('$kind\u0000$id');

  /// Libera a sessão (ao sair dela ou fechar o Gestor).
  Future<void> release(String kind, String id) async {
    _held.remove('$kind\u0000$id');
    final file = await _file(kind, id);
    final info = await holder(kind, id);
    if (file != null && info?.machine == machine) {
      try {
        await file.delete();
      } on FileSystemException {
        // Expira sozinha em 3 minutos.
      }
    }
    if (_held.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> releaseAll() async {
    for (final key in List.of(_held.keys)) {
      final parts = key.split('\u0000');
      await release(parts[0], parts[1]);
    }
  }

  /// Renova as posses deste computador; avisa as que outro assumiu.
  Future<void> heartbeat() async {
    for (final entry in Map.of(_held).entries) {
      final parts = entry.key.split('\u0000');
      final file = await _file(parts[0], parts[1]);
      if (file == null) continue;
      final info = await holder(parts[0], parts[1]);
      if (info != null && info.machine != machine) {
        _held.remove(entry.key);
        entry.value(info.machine);
        continue;
      }
      await _write(file);
    }
  }

  void dispose() => _timer?.cancel();
}
