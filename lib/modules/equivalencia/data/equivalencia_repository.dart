import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Persistência da Equivalência de Alunos.
class EquivalenciaRepository {
  EquivalenciaRepository(this._store);

  final KeyValueStore _store;

  static const key = 'student_equivalencies.blocks.v1';

  /// Versão anterior (análises de uma disciplina de cada lado). Só lida, para
  /// migrar; nunca apagada.
  static const legacyKey = 'student_equivalencies.v1';

  static const schemaVersion = 2;
  static const seedAsset = 'assets/equivalencia/curriculo_eca_2020.json';

  static Future<Curriculum> loadSeed() async => Curriculum.fromJson(
    jsonDecode(await rootBundle.loadString(seedAsset)) as Map<String, dynamic>,
  );

  Future<EquivalenciaState> load() async {
    final stored = await _store.readJson(key);
    final data = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    var changed = false;
    if (stored == null && !await _store.contains(key)) {
      final legacy = await _migrateLegacy();
      if (legacy != null) {
        data.addAll({
          'curricula': legacy.curricula.map((c) => c.toJson()).toList(),
          'cases': legacy.cases.map((c) => c.toJson()).toList(),
          'currentId': legacy.currentId,
        });
      }
      changed = true;
    } else if (stored is! Map) {
      // Não substitui um banco inválido por uma semente silenciosamente.
      throw const FormatException('Banco de equivalência inválido.');
    }

    final curricula = data['curricula'] as List? ?? [];
    if (curricula.isEmpty) {
      final seed = await loadSeed();
      data['curricula'] = [seed.toJson()];
      data.putIfAbsent('currentId', () => seed.id);
      changed = true;
    }
    data.putIfAbsent('cases', () => []);
    if ((data['schemaVersion'] as int? ?? 1) < schemaVersion) {
      _migratePeriods(data);
      data['schemaVersion'] = schemaVersion;
      changed = true;
    }
    // A migração opera no JSON, preservando cases e campos desconhecidos.
    if (changed) await _store.writeJson(key, data);
    return EquivalenciaState(
      curricula: [
        for (final c in data['curricula'] as List)
          Curriculum.fromJson(Map<String, dynamic>.from(c as Map)),
      ],
      cases: [
        for (final c in data['cases'] as List)
          EquivalenceCase.fromJson(Map<String, dynamic>.from(c as Map)),
      ],
      currentId: data['currentId'] as String?,
    );
  }

  Future<void> save(EquivalenciaState state) async {
    final stored = await _store.readJson(key);
    await _store.writeJson(key, {
      if (stored is Map) ...Map<String, dynamic>.from(stored),
      'curricula': state.curricula.map((e) => e.toJson()).toList(),
      'cases': state.cases.map((e) => e.toJson()).toList(),
      'currentId': state.currentId,
    });
  }

  /// Reparo único da classificação incorreta no catálogo ECA 2020.
  /// Valores personalizados e os demais currículos não são alterados.
  static void _migratePeriods(Map<String, dynamic> data) {
    const periods = {
      'INFIS39032': '1º Período',
      'INFIS31402': '2º Período',
      'INFIS39056': '2º Período',
      'FEELT32301': '3º Período',
      'INFIS39034': '4º Período',
      'FEELT32401': '4º Período',
      'FEELT32602': '6º Período',
    };
    bool customized(Map subject) {
      final period = (subject['period'] as String? ?? '').trim();
      return period.isNotEmpty && period != 'Optativas';
    }

    for (final curriculum in data['curricula'] as List) {
      if (curriculum['id'] != 'eca-2020') continue;
      final subjects = <Map<String, dynamic>>[];
      final byCode = <String, int>{};
      for (final raw in curriculum['subjects'] as List? ?? []) {
        final subject = Map<String, dynamic>.from(raw as Map);
        final code = subject['code'] as String? ?? '';
        final index = code.isEmpty ? null : byCode[code];
        if (index == null) {
          if (code.isNotEmpty) byCode[code] = subjects.length;
          subjects.add(subject);
        } else if (!customized(subjects[index]) && customized(subject)) {
          // Em duplicatas, prioriza um período já corrigido pelo usuário.
          subjects[index] = subject;
        }
      }
      for (final subject in subjects) {
        final period = periods[subject['code']];
        if (period != null && !customized(subject)) {
          subject['period'] = period;
        }
      }
      curriculum['subjects'] = subjects;
    }
  }

  /// Converte as análises da versão anterior em blocos de uma disciplina de
  /// cada lado e grava no formato novo (sem apagar a chave antiga).
  Future<EquivalenciaState?> _migrateLegacy() async {
    final legacy = await _store.readJson(legacyKey);
    if (legacy is! List) return null;
    final curricula = <Curriculum>[];
    final cases = <EquivalenceCase>[];
    try {
      for (final entry in legacy) {
        final old = Map<String, dynamic>.from(entry as Map);
        final course = (old['destinationCourse'] as String? ?? '').trim();
        const label = 'Currículo de destino';
        var curriculum = curricula
            .where((c) => c.course == course && c.name == label)
            .firstOrNull;
        if (curriculum == null) {
          curriculum = Curriculum(
            id:
                'legacy-current-${DateTime.now().microsecondsSinceEpoch}-'
                '${curricula.length}',
            course: course.isEmpty ? 'Curso não informado' : course,
            name: label,
          );
          curricula.add(curriculum);
        }
        final hours =
            int.tryParse((old['hours'] as String? ?? '0').trim()) ?? 0;
        cases.add(
          EquivalenceCase(
            id:
                old['id'] as String? ??
                DateTime.now().microsecondsSinceEpoch.toString(),
            student: old['student'] as String? ?? '',
            studentId: old['studentId'] as String? ?? '',
            currentCurriculumId: curriculum.id,
            priorCurriculumId: '',
            status: old['status'] as String? ?? 'Em análise',
            notes: old['notes'] as String? ?? '',
            blocks: [
              EquivalenceBlock(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                period: '',
                current: [
                  Subject(
                    code: '',
                    name: old['destinationSubject'] as String? ?? '',
                    theoretical: hours,
                    practical: 0,
                  ),
                ],
                prior: [
                  Subject(
                    code: '',
                    name: old['sourceSubject'] as String? ?? '',
                    theoretical: hours,
                    practical: 0,
                  ),
                ],
              ),
            ],
          ),
        );
      }
    } on Object {
      // Um JSON legado inválido não impede o uso dos novos cadastros.
      return null;
    }
    final state = EquivalenciaState(
      curricula: curricula,
      cases: cases,
      currentId: curricula.firstOrNull?.id,
    );
    return state;
  }
}
