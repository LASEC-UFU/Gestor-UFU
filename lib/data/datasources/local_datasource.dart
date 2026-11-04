import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_config_snapshot.dart';
import 'package:uuid/uuid.dart';
import 'package:gestor_ufu/core/utils/text_encoding.dart';

class LocalDatasource {
  static const _storageKey = 'config_moodle_data';
  static const _historyStorageKey = 'moodle_config_history_v1';
  static const _maxSnapshotsPerConfig = 200;
  final _uuid = const Uuid();
  Map<String, CourseConfig>? _cache;

  Future<Map<String, CourseConfig>> _loadAll() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      _cache = {};
      return _cache!;
    }
    final Map<String, dynamic> decoded =
        json.decode(raw) as Map<String, dynamic>;
    final jsonMap = _repairStrings(decoded) as Map<String, dynamic>;
    final repairedRaw = json.encode(jsonMap);
    _cache = jsonMap.map(
      (k, v) => MapEntry(k, CourseConfig.fromJson(v as Map<String, dynamic>)),
    );
    if (repairedRaw != raw) {
      await prefs.setString(_storageKey, repairedRaw);
    }
    return _cache!;
  }

  dynamic _repairStrings(dynamic value) {
    if (value is String) return repairMojibake(value);
    if (value is List) return value.map(_repairStrings).toList();
    if (value is Map) {
      return value.map<String, dynamic>(
        (key, item) => MapEntry(key as String, _repairStrings(item)),
      );
    }
    return value;
  }

  Future<void> _saveAll() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonMap = _cache!.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString(_storageKey, json.encode(jsonMap));
  }

  Future<List<CourseConfig>> getAll() async {
    final map = await _loadAll();
    return map.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// Corrige a codificação de configurações antigas sem descartar seus dados.
  Future<void> migrateLegacyTextEncoding() async {
    await _loadAll();
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_historyStorageKey, 'preenche_diarios_entries_v1']) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final repaired = json.encode(_repairStrings(json.decode(raw)));
        if (repaired != raw) await prefs.setString(key, repaired);
      } on FormatException {
        // Mantém intactos dados antigos que não estejam em JSON válido.
      }
    }
  }

  Future<CourseConfig?> getById(String id) async {
    final map = await _loadAll();
    return map[id];
  }

  Future<void> save(CourseConfig config) async {
    await _loadAll();
    final previous = _cache![config.id];
    if (previous != null &&
        _configurationFingerprint(previous) !=
            _configurationFingerprint(config)) {
      await _appendSnapshot(
        previous,
        label: 'Backup automático antes das alterações',
      );
    }
    _cache![config.id] = config;
    await _saveAll();
  }

  Future<void> delete(String id) async {
    await _loadAll();
    final previous = _cache![id];
    if (previous != null) {
      await _appendSnapshot(previous, label: 'Backup antes da exclusão');
    }
    _cache!.remove(id);
    await _saveAll();
  }

  Future<List<MoodleConfigSnapshot>> getSnapshots({String? configId}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyStorageKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = json.decode(raw);
    if (decoded is! List) return [];
    final snapshots = <MoodleConfigSnapshot>[];
    for (final item in decoded.whereType<Map>()) {
      try {
        snapshots.add(
          MoodleConfigSnapshot.fromJson(Map<String, dynamic>.from(item)),
        );
      } catch (_) {
        // Um backup antigo inválido não impede a recuperação dos demais.
      }
    }
    snapshots.removeWhere(
      (snapshot) => configId != null && snapshot.configId != configId,
    );
    snapshots.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return snapshots;
  }

  Future<void> createSnapshot(String configId, {required String label}) async {
    final config = await getById(configId);
    if (config == null) throw StateError('Configuração Moodle não encontrada.');
    await _appendSnapshot(config, label: label);
  }

  Future<void> restoreSnapshot(String configId, String snapshotId) async {
    await _loadAll();
    final snapshots = await getSnapshots(configId: configId);
    MoodleConfigSnapshot? snapshot;
    for (final item in snapshots) {
      if (item.id == snapshotId) snapshot = item;
    }
    if (snapshot == null) throw StateError('Backup não encontrado.');
    final restored = snapshot.toCourseConfig().copyWith(
      updatedAt: DateTime.now(),
    );
    await save(restored);
  }

  Future<void> _appendSnapshot(
    CourseConfig config, {
    required String label,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyStorageKey);
    final history = <MoodleConfigSnapshot>[];
    if (raw != null && raw.isNotEmpty) {
      final decoded = json.decode(raw);
      if (decoded is List) {
        for (final item in decoded.whereType<Map>()) {
          try {
            history.add(
              MoodleConfigSnapshot.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (_) {
            // Ignora somente um registro de backup inválido; preserva os demais.
          }
        }
      }
    }
    final data = config.toJson();
    final snapshot = MoodleConfigSnapshot(
      id: _uuid.v4(),
      configId: config.id,
      courseName: config.name,
      label: label.trim().isEmpty ? 'Backup manual' : label.trim(),
      createdAt: DateTime.now(),
      semesterStartDate: config.semesterStartDate,
      configData: data,
    );
    history.add(snapshot);
    final forConfig =
        history.where((item) => item.configId == config.id).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final keepIds = forConfig
        .take(_maxSnapshotsPerConfig)
        .map((item) => item.id)
        .toSet();
    final boundedHistory = history
        .where(
          (item) => item.configId != config.id || keepIds.contains(item.id),
        )
        .toList();
    await prefs.setString(
      _historyStorageKey,
      json.encode(boundedHistory.map((item) => item.toJson()).toList()),
    );
  }

  String _configurationFingerprint(CourseConfig config) {
    final jsonMap = config.toJson()..remove('updatedAt');
    return json.encode(jsonMap);
  }
}
