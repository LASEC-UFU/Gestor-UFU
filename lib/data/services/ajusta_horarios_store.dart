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
      final seed = await _loadSeed();
      await save(seed, term: defaultTerm);
      await prefs.remove('ajusta_horarios_disciplinas_v1');
      await prefs.remove('ajusta_horarios_disciplinas_2026_2_ca_v1');
      await prefs.remove(_storageKey);
      await prefs.remove('ajusta_horarios_distribuicao_docente');
      await prefs.remove('ajusta_horarios_docentes_ocultos_distribuicao');
      await prefs.setString(
        'ajusta_horarios_cursos',
        '{"2":"Engenharia de Controle e Automa\u00e7\u00e3o"}',
      );
      await prefs.setInt('ajusta_horarios_curso_selecionado', 2);
      await prefs.setInt('ajusta_horarios_periodo_selecionado', 1);
      await prefs.setInt('ajusta_horarios_visao_selecionada', 0);
      await prefs.setString('ajusta_horarios_periodo_letivo', defaultTerm);
      await prefs.setStringList(_termsKey, [defaultTerm]);
      await prefs.remove('ajusta_horarios_docente_selecionado');
      for (final key in const [
        'curso_y',
        'curso_x',
        'docente_y',
        'docente_x',
      ]) {
        await prefs.remove('ajusta_horarios_grade_scroll_$key');
      }
      await prefs.setBool(_initialResetKey, true);
      return seed;
    }

    if (prefs.getBool(_termStorageMigrationKey) != true) {
      final previous = prefs.getString(_storageKey);
      final savedActive = prefs.getString('ajusta_horarios_periodo_letivo');
      final active = savedActive?.trim().isNotEmpty == true
          ? savedActive!.trim()
          : defaultTerm;
      if (previous != null) {
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
