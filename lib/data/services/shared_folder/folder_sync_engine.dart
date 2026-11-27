import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/shared_folder/shared_folder_crypto.dart';

/// Acesso ao banco local (SharedPreferences no app; mapa em memória nos
/// testes).
abstract class PrefsBackend {
  /// Todas as chaves sincronizáveis (sem os metadados de sincronização).
  Future<Map<String, Object?>> readAll();

  /// Grava [values] e remove [remove].
  Future<void> apply(Map<String, Object?> values, Set<String> remove);
}

/// Em qual arquivo da pasta compartilhada cada chave fica. Grupos pequenos
/// e independentes: uma alteração reenvia só o arquivo do seu módulo, e
/// dois computadores mexendo em módulos diferentes não entram em conflito.
String syncGroupFor(String key) {
  const conversation = 'gestor_ufu_agente_conversa_v1_';
  if (key.startsWith(conversation)) {
    return 'agente-conversa-${_safe(key.substring(conversation.length))}';
  }
  final run = RegExp(r'^orquestrador\.(?:run|events)\.(.+)$').firstMatch(key);
  if (run != null) return 'orquestrador-rodada-${_safe(run.group(1)!)}';
  final handoff = RegExp(r'^orquestrador\.handoff\.([^.]+)\.').firstMatch(key);
  if (handoff != null) {
    return 'orquestrador-rodada-${_safe(handoff.group(1)!)}';
  }
  // Conversa "atual" de cada computador: chave por computador, sem conflito.
  if (key.startsWith('orquestrador.chat.atual.') ||
      key.startsWith('orquestrador.projeto.')) {
    return 'orquestrador-computadores';
  }
  if (key.startsWith('orquestrador.chat.') && key != 'orquestrador.chat.v1') {
    return 'orquestrador-conversa-${_safe(key.substring('orquestrador.chat.'.length))}';
  }
  if (key.startsWith('orquestrador.')) return 'orquestrador';
  // Períodos letivos são de todos os módulos.
  if (key == 'ajusta_horarios_periodos_letivos' ||
      key == 'ajusta_horarios_periodo_letivo') {
    return 'geral';
  }
  const prefixes = <String, String>{
    'ajusta_horarios_': 'ajusta-horarios',
    'config_moodle': 'moodle',
    'moodle_': 'moodle',
    'last_moodle': 'moodle',
    'preenche_diarios': 'diario',
    'portal_docente': 'diario',
    'student_equivalencies': 'equivalencia',
    'progressao': 'progressao',
    'inserir_documentos_sei.': 'acoes-na-web',
    'gestor_ufu_planos_ensino': 'planos-ensino',
    'planos_ensino': 'planos-ensino',
    'gestor_ufu_planos_trabalho': 'planos-trabalho',
    'planos_trabalho': 'planos-trabalho',
    'sei_tree': 'elabora-relato',
    'gestor_ufu_ai_agent': 'agente',
  };
  for (final entry in prefixes.entries) {
    if (key.startsWith(entry.key)) return entry.value;
  }
  return 'geral';
}

String _safe(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
}

/// Resultado de uma rodada de sincronização.
class FolderSyncResult {
  FolderSyncResult();

  /// Chaves alteradas neste computador por dados vindos da pasta.
  final changedKeys = <String>{};
  final uploaded = <String>{};
  final conflicts = <String>{};
}

/// Sincronização do banco do Gestor com uma pasta (Google Drive, OneDrive,
/// rede…), um arquivo cifrado por grupo em `dados/<grupo>.gdb`.
///
/// A cada rodada: compara cada grupo local com a última versão combinada
/// ("base", guardada só neste computador) e olha só tamanho/data dos
/// arquivos da pasta; decifra apenas os grupos cujo arquivo mudou. Mudou
/// só aqui: envia. Mudou só lá: aplica. Mudou nos dois: junta por chave;
/// se a mesma chave mudou para valores diferentes, o grupo fica em
/// conflito para o usuário escolher.
class FolderSyncEngine {
  FolderSyncEngine({
    required this.crypto,
    required this.backend,
    required this.stateDir,
    this.machine = '',
  });

  static const dataDir = 'dados';
  static const ext = '.gdb';
  static const format = 'gestor_ufu_shared_group';

  final SharedFolderCrypto crypto;
  final PrefsBackend backend;

  /// Pasta local com as bases de cada grupo (fora da nuvem).
  final String stateDir;
  final String machine;

  /// Grupos em conflito (aguardando a escolha do usuário).
  final conflicts = <String>{};

  Map<String, dynamic>? _state;

  String get _dataPath => p.join(crypto.folder, dataDir);
  File get _stateFile => File(p.join(stateDir, 'estado.json'));
  File _baseFile(String group) => File(p.join(stateDir, 'base', '$group.json'));

  Future<Map<String, dynamic>> _loadState() async {
    if (_state != null) return _state!;
    try {
      _state = Map<String, dynamic>.from(
        jsonDecode(await _stateFile.readAsString()) as Map,
      );
    } on Object {
      _state = {};
    }
    return _state!;
  }

  Future<void> _saveState() async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(jsonEncode(_state ?? {}));
  }

  static String canonical(Map<String, Object?> values) {
    final sorted = Map<String, Object?>.fromEntries(
      values.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return jsonEncode(sorted);
  }

  static String _digest(String text) =>
      hash.sha256.convert(utf8.encode(text)).toString();

  Future<String?> _base(String group) async {
    final file = _baseFile(group);
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> _setBase(String group, String json) async {
    final file = _baseFile(group);
    await file.parent.create(recursive: true);
    await file.writeAsString(json);
    final state = await _loadState();
    (state['groups'] ??= <String, dynamic>{})[group] = {
      ...?(state['groups'][group] as Map?)?.cast<String, dynamic>(),
      'baseHash': _digest(json),
    };
  }

  String _stamp(FileStat stat) =>
      '${stat.size}:${stat.modified.millisecondsSinceEpoch}';

  /// Arquivos dos grupos na pasta (nome → carimbo tamanho:data).
  Future<Map<String, String>> _remoteStamps() async {
    final dir = Directory(_dataPath);
    if (!await dir.exists()) return {};
    final result = <String, String>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      // Ignora cópias de conflito do Drive ("arquivo (1).gdb") e temporários.
      if (!name.endsWith(ext) || name.contains(' (')) continue;
      result[name.substring(0, name.length - ext.length)] = _stamp(
        await entity.stat(),
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _readRemote(String group) async {
    final bytes = await SharedFolderCrypto.readStable(
      p.join(_dataPath, '$group$ext'),
    );
    if (bytes == null) return {};
    final outer = jsonDecode(utf8.decode(bytes));
    if (outer is! Map || outer['format'] != format) {
      throw SharedFolderException('Arquivo do grupo $group inválido.');
    }
    final inner = jsonDecode(await crypto.decryptText(outer['data']));
    return Map<String, Object?>.from(inner as Map);
  }

  Future<void> _writeRemote(String group, String json) async {
    final envelope = {
      'format': format,
      'version': SharedFolderCrypto.version,
      'group': group,
      'machine': machine,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'data': await crypto.encryptText(json),
    };
    final path = p.join(_dataPath, '$group$ext');
    await crypto.writeAtomic(path, utf8.encode(jsonEncode(envelope)));
    final state = await _loadState();
    (state['groups'] ??= <String, dynamic>{})[group] = {
      ...?(state['groups'][group] as Map?)?.cast<String, dynamic>(),
      'stamp': _stamp(await File(path).stat()),
    };
  }

  Map<String, Map<String, Object?>> _group(Map<String, Object?> all) {
    final groups = <String, Map<String, Object?>>{};
    for (final entry in all.entries) {
      (groups[syncGroupFor(entry.key)] ??= {})[entry.key] = entry.value;
    }
    return groups;
  }

  /// Define a base de todos os grupos a partir de um retrato completo (ex.:
  /// o banco antigo de arquivo único na migração). Os arquivos da pasta são
  /// relidos na próxima rodada.
  Future<void> seedBaseline(Map<String, Object?> snapshot) async {
    final state = await _loadState();
    state['groups'] = <String, dynamic>{};
    for (final entry in _group(snapshot).entries) {
      await _setBase(entry.key, canonical(entry.value));
    }
    await _saveState();
  }

  /// Envia todos os grupos deste computador (cria a pasta / "publicar").
  Future<void> publishAll() async {
    final local = _group(await backend.readAll());
    for (final entry in local.entries) {
      final json = canonical(entry.value);
      await _writeRemote(entry.key, json);
      await _setBase(entry.key, json);
    }
    conflicts.clear();
    await _saveState();
  }

  /// Aplica todos os grupos da pasta neste computador ("usar a pasta").
  Future<Set<String>> adoptAll() async {
    final changed = <String>{};
    final local = _group(await backend.readAll());
    final remote = await _remoteStamps();
    final state = await _loadState();
    for (final group in remote.keys) {
      final values = await _readRemote(group);
      final mine = local[group] ?? const {};
      final remove = mine.keys.where((k) => !values.containsKey(k)).toSet();
      await backend.apply(values, remove);
      changed
        ..addAll(values.keys)
        ..addAll(remove);
      await _setBase(group, canonical(values));
      (state['groups'] as Map)[group]['stamp'] = remote[group];
    }
    conflicts.clear();
    await _saveState();
    return changed;
  }

  /// Resolve o conflito de um grupo mantendo a pasta ou este computador.
  Future<Set<String>> resolve(String group, {required bool useShared}) async {
    final local = _group(await backend.readAll())[group] ?? const {};
    final changed = <String>{};
    if (useShared) {
      final remote = await _readRemote(group);
      final remove = local.keys.where((k) => !remote.containsKey(k)).toSet();
      await backend.apply(remote, remove);
      changed
        ..addAll(remote.keys)
        ..addAll(remove);
      await _setBase(group, canonical(remote));
      final stamps = await _remoteStamps();
      (await _loadState())['groups'][group]['stamp'] = stamps[group];
    } else {
      final json = canonical(local);
      await _writeRemote(group, json);
      await _setBase(group, json);
    }
    conflicts.remove(group);
    await _saveState();
    return changed;
  }

  /// Uma rodada de sincronização.
  Future<FolderSyncResult> sync() async {
    final result = FolderSyncResult();
    final state = await _loadState();
    final groupsState = (state['groups'] ??= <String, dynamic>{}) as Map;
    final local = _group(await backend.readAll());
    final remote = await _remoteStamps();
    final names = <String>{...local.keys, ...remote.keys, ...groupsState.keys};
    for (final group in names) {
      if (conflicts.contains(group)) continue;
      final info = Map<String, dynamic>.from(groupsState[group] as Map? ?? {});
      final localJson = canonical(local[group] ?? const {});
      final baseHash = info['baseHash'] as String?;
      final localChanged = baseHash == null
          ? (local[group]?.isNotEmpty ?? false)
          : _digest(localJson) != baseHash;
      final remoteStamp = remote[group];
      final remoteTouched = remoteStamp != null && remoteStamp != info['stamp'];
      if (!localChanged && !remoteTouched) {
        // Arquivo sumiu da pasta (removido por engano): envia de novo.
        if (remoteStamp == null && baseHash != null && local[group] != null) {
          await _writeRemote(group, localJson);
          result.uploaded.add(group);
        }
        continue;
      }
      final baseJson = await _base(group);
      final remoteValues = remoteTouched ? await _readRemote(group) : null;
      final remoteJson = remoteValues == null
          ? baseJson
          : canonical(remoteValues);
      final remoteChanged = remoteTouched && remoteJson != baseJson;
      if (remoteTouched && !remoteChanged) {
        groupsState[group] = {...info, 'stamp': remoteStamp};
      }
      if (localChanged && !remoteChanged) {
        await _writeRemote(group, localJson);
        await _setBase(group, localJson);
        result.uploaded.add(group);
      } else if (remoteChanged && !localChanged) {
        final values = remoteValues!;
        final mine = local[group] ?? const {};
        final remove = mine.keys.where((k) => !values.containsKey(k)).toSet();
        await backend.apply(values, remove);
        for (final key in {...values.keys, ...remove}) {
          if (jsonEncode(values[key]) != jsonEncode(mine[key])) {
            result.changedKeys.add(key);
          }
        }
        await _setBase(group, remoteJson!);
        groupsState[group]['stamp'] = remoteStamp;
      } else if (localChanged && remoteChanged) {
        if (localJson == remoteJson) {
          await _setBase(group, localJson);
          groupsState[group]['stamp'] = remoteStamp;
          continue;
        }
        final merged = mergeValues(
          base: baseJson == null
              ? const {}
              : Map<String, Object?>.from(jsonDecode(baseJson) as Map),
          local: local[group] ?? const {},
          remote: remoteValues!,
        );
        if (merged == null) {
          conflicts.add(group);
          result.conflicts.add(group);
          continue;
        }
        final mine = local[group] ?? const {};
        final remove = mine.keys.where((k) => !merged.containsKey(k)).toSet();
        await backend.apply(merged, remove);
        for (final key in {...merged.keys, ...remove}) {
          if (jsonEncode(merged[key]) != jsonEncode(mine[key])) {
            result.changedKeys.add(key);
          }
        }
        final json = canonical(merged);
        await _writeRemote(group, json);
        await _setBase(group, json);
        result.uploaded.add(group);
      }
    }
    await _saveState();
    return result;
  }

  /// Junção por chave: mudanças em chaves diferentes são combinadas; a
  /// mesma chave alterada para valores diferentes nos dois lados = null
  /// (conflito).
  static Map<String, Object?>? mergeValues({
    required Map<String, Object?> base,
    required Map<String, Object?> local,
    required Map<String, Object?> remote,
  }) {
    bool same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
    final merged = <String, Object?>{};
    for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
      final hadBase = base.containsKey(key);
      final hasLocal = local.containsKey(key);
      final hasRemote = remote.containsKey(key);
      final changedLocally =
          hasLocal != hadBase || (hasLocal && !same(local[key], base[key]));
      final changedRemotely =
          hasRemote != hadBase || (hasRemote && !same(remote[key], base[key]));
      if (changedLocally && changedRemotely) {
        if (hasLocal != hasRemote ||
            (hasLocal && !same(local[key], remote[key]))) {
          return null;
        }
        if (hasLocal) merged[key] = local[key];
      } else if (changedLocally) {
        if (hasLocal) merged[key] = local[key];
      } else if (hasRemote) {
        merged[key] = remote[key];
      }
    }
    return merged;
  }
}
