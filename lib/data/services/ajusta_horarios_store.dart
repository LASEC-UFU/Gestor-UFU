import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:config_moodle/domain/entities/ajusta_horarios.dart';

class AjustaHorariosStore {
  static const _storageKey = 'ajusta_horarios_disciplinas_2026_2_ca_v2';
  static const _initialResetKey = 'ajusta_horarios_importacao_2026_2_ca_v2';
  static const _termStorageMigrationKey =
      'ajusta_horarios_migracao_periodos_v1';
  static const _modalityGroupingMigrationKey =
      'ajusta_horarios_migracao_grupos_modalidade_v1';
  static const _cleanupMigrationKey = 'ajusta_horarios_limpeza_dados_v1';
  static const _requiredTheoryPracticeGroupsMigrationKey =
      'ajusta_horarios_turmas_teorica_pratica_v1';
  static const _legacySchedulePortMigrationKey =
      'ajusta_horarios_migracao_horarios_legados_para_turma_v1';
  static const _unassignedScheduleCleanupMigrationKey =
      'ajusta_horarios_limpeza_horarios_sem_turma_v1';
  static const _legacyRecordCleanupMigrationKey =
      'ajusta_horarios_limpeza_registros_legados_v1';
  static const _teacherAssignmentsMigrationKey =
      'ajusta_horarios_migracao_alocacao_docentes_turma_v1';
  static const _termsKey = 'ajusta_horarios_periodos_letivos';
  static const defaultTerm = '2\u00ba semestre de 2026';

  String _keyForTerm(String term) {
    final token = base64Url
        .encode(utf8.encode(term.trim()))
        .replaceAll('=', '');
    return '${_storageKey}_$token';
  }

  Future<List<HorarioDisciplina>> load({String term = defaultTerm}) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_initialResetKey) != true) {
      // Some shared databases were created before this marker existed. Never
      // replace an existing timetable with the bundled seed on those installs.
      final active = prefs.getString('ajusta_horarios_periodo_letivo')?.trim();
      final existingScheduleKeys = prefs
          .getKeys()
          .where(
            (key) =>
                key.startsWith('${_storageKey}_') &&
                prefs.getString(key) != null,
          )
          .toList();
      final existingScheduleKey = existingScheduleKeys.isEmpty
          ? null
          : existingScheduleKeys.first;
      final legacySchedule =
          prefs.getString(_storageKey) ??
          prefs.getString('ajusta_horarios_disciplinas_2026_2_ca_v1') ??
          prefs.getString('ajusta_horarios_disciplinas_v1');
      if (existingScheduleKey == null && legacySchedule != null) {
        await prefs.setString(
          _keyForTerm(active?.isNotEmpty == true ? active! : defaultTerm),
          legacySchedule,
        );
      } else if (existingScheduleKey == null && legacySchedule == null) {
        await save(await _loadSeed(), term: defaultTerm);
      }

      if (!prefs.containsKey('ajusta_horarios_cursos')) {
        await prefs.setString(
          'ajusta_horarios_cursos',
          '{"2":"Engenharia de Controle e Automa\u00e7\u00e3o"}',
        );
      }
      if (!prefs.containsKey('ajusta_horarios_periodo_letivo')) {
        await prefs.setString('ajusta_horarios_periodo_letivo', defaultTerm);
      }
      final terms = prefs.getStringList(_termsKey) ?? const <String>[];
      if (terms.isEmpty) await prefs.setStringList(_termsKey, [defaultTerm]);
      await prefs.setBool(_initialResetKey, true);
    }

    if (prefs.getBool(_termStorageMigrationKey) != true) {
      final previous = prefs.getString(_storageKey);
      final savedActive = prefs.getString('ajusta_horarios_periodo_letivo');
      final active = savedActive?.trim().isNotEmpty == true
          ? savedActive!.trim()
          : defaultTerm;
      if (previous != null && prefs.getString(_keyForTerm(active)) == null) {
        await prefs.setString(_keyForTerm(active), previous);
      }
      await prefs.remove(_storageKey);
      final terms = prefs.getStringList(_termsKey) ?? const <String>[];
      if (terms.isEmpty) {
        await prefs.setStringList(_termsKey, [active]);
        await prefs.setString('ajusta_horarios_periodo_letivo', active);
      }
      await prefs.setBool(_termStorageMigrationKey, true);
    }

    if (prefs.getBool(_modalityGroupingMigrationKey) != true) {
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith('${_storageKey}_'),
      )) {
        final stored = prefs.getString(key);
        if (stored == null) continue;
        try {
          final decoded = jsonDecode(stored) as List;
          final entries = decoded
              .map(
                (row) => HorarioDisciplina.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              )
              .toList();
          final grouped = _groupExistingOfferings(entries);
          await prefs.setString(
            key,
            jsonEncode(grouped.map((entry) => entry.toJson()).toList()),
          );
        } on Object {
          // Keep an unrecognized period untouched; loading it will surface
          // the original decoding error rather than damaging its stored data.
        }
      }
      await prefs.setBool(_modalityGroupingMigrationKey, true);
    }

    if (prefs.getBool(_teacherAssignmentsMigrationKey) != true) {
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith('${_storageKey}_'),
      )) {
        final stored = prefs.getString(key);
        if (stored == null) continue;
        try {
          final decoded = jsonDecode(stored) as List;
          final entries = decoded
              .map(
                (row) => HorarioDisciplina.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              )
              .toList();
          final migrated = _migrateTeacherAssignments(entries);
          final canonical = jsonEncode(
            migrated.map((entry) => entry.toJson()).toList(),
          );
          if (canonical != stored) await prefs.setString(key, canonical);
        } on Object {
          // Keep malformed or unknown periods intact for recovery.
        }
      }
      await prefs.setBool(_teacherAssignmentsMigrationKey, true);
    }

    if (prefs.getBool(_cleanupMigrationKey) != true) {
      // A primeira versão do cadastro da ABI guardou DCF como uma turma
      // legada com os horários de EaD/prática misturados. O registro correto
      // de prática (por exemplo DCF-P-U1) é preservado; este registro-base é
      // somente EaD e não ocupa a grade semanal.
      for (final key in prefs.getKeys().where(
        (key) => key.startsWith('${_storageKey}_'),
      )) {
        final stored = prefs.getString(key);
        if (stored == null) continue;
        try {
          final decoded = jsonDecode(stored) as List;
          var changed = false;
          final entries = decoded.map((row) {
            final entry = HorarioDisciplina.fromJson(
              Map<String, dynamic>.from(row as Map),
            );
            final isAbiDcfSeed =
                entry.id.startsWith('abi_') &&
                entry.id.endsWith('_02') &&
                entry.acronym.trim().toUpperCase() == 'DCF' &&
                entry.name.toLowerCase().contains(
                  'dispositivos ciberfísicos',
                ) &&
                entry.modality == 'legacy' &&
                entry.className.trim().isEmpty;
            if (!isAbiDcfSeed) return entry;
            changed = true;
            return entry.copyWith(modality: 'ead', slots: const []);
          }).toList();
          if (changed) {
            await prefs.setString(
              key,
              jsonEncode(entries.map((entry) => entry.toJson()).toList()),
            );
          }
        } on Object {
          // Não remover nem reescrever dados cujo formato não reconhecemos.
        }
      }

      // Migra as últimas preferências globais de visualização para o período
      // padrão antes de remover as chaves antigas sem escopo por período.
      final defaultToken = base64Url
          .encode(utf8.encode(defaultTerm.trim()))
          .replaceAll('=', '');
      String scoped(String key) => '${key}_$defaultToken';
      for (final key in const [
        'ajusta_horarios_curso_selecionado',
        'ajusta_horarios_periodo_selecionado',
        'ajusta_horarios_visao_selecionada',
        'ajusta_horarios_docente_selecionado',
        'ajusta_horarios_grade_scroll_curso_y',
        'ajusta_horarios_grade_scroll_curso_x',
        'ajusta_horarios_grade_scroll_docente_y',
        'ajusta_horarios_grade_scroll_docente_x',
      ]) {
        if (prefs.containsKey(key) && !prefs.containsKey(scoped(key))) {
          final value = prefs.get(key);
          if (value is int) await prefs.setInt(scoped(key), value);
          if (value is double) await prefs.setDouble(scoped(key), value);
          if (value is String) await prefs.setString(scoped(key), value);
        }
      }

      // Remoção de chaves internas de versões antigas. Dados atuais por
      // período, cursos, docentes e backups/exportações são mantidos.
      for (final key in const [
        'ajusta_horarios_disciplinas_v1',
        'ajusta_horarios_disciplinas_2026_2_ca_v1',
        'ajusta_horarios_disciplinas_2026_2_ca_v2',
        'ajusta_horarios_distribuicao_docente',
        'ajusta_horarios_docentes_ocultos_distribuicao',
        'ajusta_horarios_curso_selecionado',
        'ajusta_horarios_periodo_selecionado',
        'ajusta_horarios_visao_selecionada',
        'ajusta_horarios_docente_selecionado',
        'ajusta_horarios_grade_scroll_curso_y',
        'ajusta_horarios_grade_scroll_curso_x',
        'ajusta_horarios_grade_scroll_docente_y',
        'ajusta_horarios_grade_scroll_docente_x',
      ]) {
        await prefs.remove(key);
      }
      await prefs.setBool(_cleanupMigrationKey, true);
    }

    if (prefs.getBool(_requiredTheoryPracticeGroupsMigrationKey) != true) {
      await _ensureTheoryAndPracticeGroups(prefs);
    }

    if (prefs.getBool(_legacySchedulePortMigrationKey) != true) {
      await _portLegacySchedulesToClass(prefs);
    }

    if (prefs.getBool(_unassignedScheduleCleanupMigrationKey) != true) {
      await _clearSchedulesWithoutClassOrModality(prefs);
    }

    if (prefs.getBool(_legacyRecordCleanupMigrationKey) != true) {
      await _removeLegacyRecords(prefs);
    }

    final stored = prefs.getString(_keyForTerm(term));
    if (stored != null) {
      final data = jsonDecode(stored) as List;
      final entries = data
          .map(
            (row) => HorarioDisciplina.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
      final grouped = _groupExistingOfferings(entries);
      if (!_sameGrouping(entries, grouped)) {
        await save(grouped, term: term);
      }
      return grouped;
    }

    return const <HorarioDisciplina>[];
  }

  Future<List<HorarioDisciplina>> _loadSeed() async {
    final seed =
        jsonDecode(
              await rootBundle.loadString('assets/adjust_schedule/seed.json'),
            )
            as List;
    return seed
        .map(
          (row) =>
              HorarioDisciplina.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  List<HorarioDisciplina> _groupExistingOfferings(
    List<HorarioDisciplina> entries,
  ) {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    final groups = <String, List<int>>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final identity = [
        normalize(entry.code),
        normalize(entry.name),
        entry.coursePeriods
            .map((item) => '${item.program}:${item.period}')
            .toSet()
            .toList()
          ..sort(),
      ];
      groups.putIfAbsent(jsonEncode(identity), () => []).add(i);
    }

    final updated = [...entries];
    for (final indexes in groups.values) {
      final subjectId = entries[indexes.first].subjectId;
      for (final index in indexes) {
        final entry = entries[index];
        final nonZeroModalities = <String>[
          if (entry.theoryHours > 0) 'theory',
          if (entry.practiceHours > 0) 'practice',
          if (entry.eadHours > 0) 'ead',
          if (entry.extensionHours > 0) 'extension',
        ];
        final inferred =
            entry.modality == 'legacy' && nonZeroModalities.length == 1
            ? nonZeroModalities.single
            : entry.modality;
        updated[index] = entry.copyWith(
          subjectId: subjectId,
          modality: inferred,
        );
      }
    }
    return updated;
  }

  Future<void> _ensureTheoryAndPracticeGroups(SharedPreferences prefs) async {
    var allSchedulesParsed = true;
    final scheduleKeys = prefs
        .getKeys()
        .where((key) => key.startsWith('${_storageKey}_'))
        .toList();

    for (final key in scheduleKeys) {
      final stored = prefs.getString(key);
      if (stored == null) continue;

      try {
        final decoded = jsonDecode(stored) as List;
        final original = decoded
            .map(
              (row) => HorarioDisciplina.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList();
        final entries = _groupExistingOfferings(original);
        final usedIds = entries.map((entry) => entry.id).toSet();
        final groupedBySubject = <String, List<HorarioDisciplina>>{};
        for (final entry in entries) {
          groupedBySubject.putIfAbsent(entry.subjectId, () => []).add(entry);
        }

        for (final subjectEntries in groupedBySubject.values) {
          if (subjectEntries.isEmpty) continue;
          final subject = subjectEntries.first;
          final requiredModalities = <String>[
            if (subjectEntries.any((entry) => entry.theoryHours > 0)) 'theory',
            if (subjectEntries.any((entry) => entry.practiceHours > 0))
              'practice',
          ];

          for (final modality in requiredModalities) {
            final modalityGroups = subjectEntries
                .where((entry) => entry.modality == modality)
                .toList();

            // Existing groups with a blank identifier are real records. Give
            // them the first available class name without touching schedules.
            var nextClassNumber = 1;
            final classNames = modalityGroups
                .map((entry) => entry.className.trim())
                .where((name) => name.isNotEmpty)
                .toSet();
            while (classNames.contains('$nextClassNumber')) {
              nextClassNumber++;
            }
            for (var index = 0; index < entries.length; index++) {
              final entry = entries[index];
              if (entry.subjectId != subject.subjectId ||
                  entry.modality != modality ||
                  entry.className.trim().isNotEmpty) {
                continue;
              }
              final className = '$nextClassNumber';
              entries[index] = entry.copyWith(className: className);
              classNames.add(className);
              nextClassNumber++;
            }

            final hasIdentifiedGroup = entries.any(
              (entry) =>
                  entry.subjectId == subject.subjectId &&
                  entry.modality == modality &&
                  entry.className.trim().isNotEmpty,
            );
            if (hasIdentifiedGroup) continue;

            var className = '1';
            while (classNames.contains(className)) {
              nextClassNumber++;
              className = '$nextClassNumber';
            }
            var id = '${subject.subjectId}_${modality}_class_$className';
            var suffix = 2;
            while (usedIds.contains(id)) {
              id =
                  '${subject.subjectId}_${modality}_class_${className}_$suffix';
              suffix++;
            }
            usedIds.add(id);
            entries.add(
              subject.copyWith(
                id: id,
                subjectId: subject.subjectId,
                modality: modality,
                className: className,
                teachers: const [],
                room: '',
                slots: const [],
              ),
            );
          }
        }

        final updated = jsonEncode(
          entries.map((entry) => entry.toJson()).toList(),
        );
        if (updated != stored) await prefs.setString(key, updated);
      } on Object {
        // Do not mark the migration complete if any saved period could not be
        // parsed; a later load can retry it after the data becomes available.
        allSchedulesParsed = false;
      }
    }

    if (allSchedulesParsed) {
      await prefs.setBool(_requiredTheoryPracticeGroupsMigrationKey, true);
    }
  }

  Future<void> _clearSchedulesWithoutClassOrModality(
    SharedPreferences prefs,
  ) async {
    var allSchedulesParsed = true;
    final scheduleKeys = prefs
        .getKeys()
        .where((key) => key.startsWith('${_storageKey}_'))
        .toList();

    for (final key in scheduleKeys) {
      final stored = prefs.getString(key);
      if (stored == null) continue;
      try {
        final decoded = jsonDecode(stored) as List;
        var changed = false;
        final entries = decoded.map((row) {
          final entry = HorarioDisciplina.fromJson(
            Map<String, dynamic>.from(row as Map),
          );
          final hasClass = entry.className.trim().isNotEmpty;
          final hasValidModality = const {
            'theory',
            'practice',
            'ead',
            'extension',
          }.contains(entry.modality);
          final isUnassignedClass = !hasClass || !hasValidModality;
          if (!isUnassignedClass) return entry;

          final hasLegacyClassName = entry.className.trim().isNotEmpty;
          if (entry.slots.isEmpty && !hasLegacyClassName) return entry;
          changed = true;
          return entry.copyWith(className: '', slots: const []);
        }).toList();

        if (changed) {
          await prefs.setString(
            key,
            jsonEncode(entries.map((entry) => entry.toJson()).toList()),
          );
        }
      } on Object {
        allSchedulesParsed = false;
      }
    }

    if (allSchedulesParsed) {
      await prefs.setBool(_unassignedScheduleCleanupMigrationKey, true);
    }
  }

  Future<void> _portLegacySchedulesToClass(SharedPreferences prefs) async {
    var allSchedulesParsed = true;
    final scheduleKeys = prefs
        .getKeys()
        .where((key) => key.startsWith('${_storageKey}_'))
        .toList();

    for (final key in scheduleKeys) {
      final stored = prefs.getString(key);
      if (stored == null) continue;
      try {
        final decoded = jsonDecode(stored) as List;
        final entries = _groupExistingOfferings(
          decoded
              .map(
                (row) => HorarioDisciplina.fromJson(
                  Map<String, dynamic>.from(row as Map),
                ),
              )
              .toList(),
        );
        final usedIds = entries.map((entry) => entry.id).toSet();
        var changed = false;
        final legacyRows = entries
            .where(
              (entry) => entry.modality == 'legacy' && entry.slots.isNotEmpty,
            )
            .toList();

        for (final legacy in legacyRows) {
          final related = entries
              .where((entry) => entry.subjectId == legacy.subjectId)
              .toList();
          final theoryHours = related.fold<int>(
            0,
            (value, entry) =>
                entry.theoryHours > value ? entry.theoryHours : value,
          );
          final practiceHours = related.fold<int>(
            0,
            (value, entry) =>
                entry.practiceHours > value ? entry.practiceHours : value,
          );
          final targetModality = theoryHours > 0
              ? 'theory'
              : practiceHours > 0
              ? 'practice'
              : null;

          if (targetModality != null) {
            final requestedClass = legacy.className.trim().isEmpty
                ? '1'
                : legacy.className.trim();
            var targetIndex = entries.indexWhere(
              (entry) =>
                  entry.subjectId == legacy.subjectId &&
                  entry.modality == targetModality &&
                  entry.className.trim().toLowerCase() ==
                      requestedClass.toLowerCase(),
            );

            if (targetIndex < 0) {
              // The previous migration created a placeholder class "1".
              // If it is still empty, reuse it with the identifier from the
              // legacy record instead of producing a duplicate turma.
              targetIndex = entries.indexWhere(
                (entry) =>
                    entry.subjectId == legacy.subjectId &&
                    entry.modality == targetModality &&
                    entry.id ==
                        '${legacy.subjectId}_${targetModality}_class_1' &&
                    entry.className.trim() == '1' &&
                    entry.slots.isEmpty,
              );
              if (targetIndex >= 0) {
                entries[targetIndex] = entries[targetIndex].copyWith(
                  className: requestedClass,
                );
              }
            }

            if (targetIndex < 0) {
              final id = _uniqueClassId(
                legacy.subjectId,
                targetModality,
                requestedClass,
                usedIds,
              );
              usedIds.add(id);
              entries.add(
                legacy.copyWith(
                  id: id,
                  subjectId: legacy.subjectId,
                  modality: targetModality,
                  className: requestedClass,
                  slots: legacy.slots,
                ),
              );
              targetIndex = entries.length - 1;
            } else {
              final target = entries[targetIndex];
              final byKey = <String, HorarioSlot>{
                for (final slot in target.slots) slot.key: slot,
                for (final slot in legacy.slots) slot.key: slot,
              };
              final slots = byKey.values.toList()
                ..sort((a, b) => a.key.compareTo(b.key));
              entries[targetIndex] = target.copyWith(slots: slots);
            }
          }

          final legacyIndex = entries.indexWhere(
            (entry) => entry.id == legacy.id,
          );
          if (legacyIndex >= 0) {
            entries[legacyIndex] = entries[legacyIndex].copyWith(
              className: '',
              slots: const [],
            );
          }
          changed = true;
        }

        final updated = jsonEncode(
          entries.map((entry) => entry.toJson()).toList(),
        );
        if (changed || updated != stored) await prefs.setString(key, updated);
      } on Object {
        allSchedulesParsed = false;
      }
    }

    if (allSchedulesParsed) {
      await prefs.setBool(_legacySchedulePortMigrationKey, true);
    }
  }

  Future<void> _removeLegacyRecords(SharedPreferences prefs) async {
    var allSchedulesParsed = true;
    final scheduleKeys = prefs
        .getKeys()
        .where((key) => key.startsWith('${_storageKey}_'))
        .toList();

    for (final key in scheduleKeys) {
      final stored = prefs.getString(key);
      if (stored == null) continue;
      try {
        final decoded = jsonDecode(stored) as List;
        final entries = decoded
            .map(
              (row) => HorarioDisciplina.fromJson(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .toList();
        final currentEntries = entries
            .where((entry) => entry.modality != 'legacy')
            .toList();
        if (currentEntries.length != entries.length) {
          await prefs.setString(
            key,
            jsonEncode(currentEntries.map((entry) => entry.toJson()).toList()),
          );
        }
      } on Object {
        // Do not remove records from a period whose data could not be parsed.
        allSchedulesParsed = false;
      }
    }

    if (allSchedulesParsed) {
      await prefs.setBool(_legacyRecordCleanupMigrationKey, true);
    }
  }

  String _uniqueClassId(
    String subjectId,
    String modality,
    String className,
    Set<String> usedIds,
  ) {
    final normalizedClass = className.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9_-]+'),
      '_',
    );
    var id = '${subjectId}_${modality}_class_$normalizedClass';
    var suffix = 2;
    while (usedIds.contains(id)) {
      id = '${subjectId}_${modality}_class_${normalizedClass}_$suffix';
      suffix++;
    }
    return id;
  }

  List<HorarioDisciplina> _migrateTeacherAssignments(
    List<HorarioDisciplina> entries,
  ) {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    String subjectKey(HorarioDisciplina entry) {
      final explicitId = entry.subjectId.trim();
      if (explicitId.isNotEmpty && explicitId != entry.id) {
        return 'id:${normalize(explicitId)}';
      }
      return 'course:${normalize(entry.code)}:${normalize(entry.name)}';
    }

    final bySubject = <String, List<HorarioDisciplina>>{};
    for (final entry in entries) {
      bySubject.putIfAbsent(subjectKey(entry), () => []).add(entry);
    }

    return entries.map((entry) {
      if (entry.teacherNames.isNotEmpty) return entry;
      final siblings = bySubject[subjectKey(entry)] ?? const [];
      final assigned = siblings
          .where((sibling) => sibling.teacherNames.isNotEmpty)
          .toList();
      if (assigned.isEmpty) return entry;

      final assignmentSets = assigned
          .map((sibling) => sibling.teacherNames.toSet())
          .toList();
      final distinctAssignments = assignmentSets
          .map((names) => (names.toList()..sort()).join('\u0000'))
          .toSet();
      if (distinctAssignments.length == 1) {
        return entry.copyWith(teachers: assigned.first.teacherNames);
      }

      // If multiple groups of the same subject had different teachers, only
      // transfer a group with the same class identifier. Leave ambiguous
      // records for the user to review instead of guessing a teacher.
      final sameClass = assigned
          .where(
            (sibling) =>
                normalize(sibling.className) == normalize(entry.className),
          )
          .map((sibling) => sibling.teacherNames)
          .toList();
      final matchingAssignments = sameClass
          .map((names) => (names.toList()..sort()).join('\u0000'))
          .toSet();
      if (matchingAssignments.length == 1 && sameClass.isNotEmpty) {
        return entry.copyWith(teachers: sameClass.first);
      }
      return entry;
    }).toList();
  }

  bool _sameGrouping(
    List<HorarioDisciplina> before,
    List<HorarioDisciplina> after,
  ) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (before[i].subjectId != after[i].subjectId ||
          before[i].modality != after[i].modality) {
        return false;
      }
    }
    return true;
  }

  Future<void> save(
    List<HorarioDisciplina> entries, {
    String term = defaultTerm,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyForTerm(term),
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }

  Future<void> clear({String term = defaultTerm}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyForTerm(term));
  }
}
