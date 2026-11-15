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

  static const defaultCurriculum = Curriculum(
    id: 'eca-2020',
    course: 'Engenharia de Controle e Automação',
    name: 'Currículo Proposto (2020/1)',
  );

  Future<EquivalenciaState> load() async {
    var curricula = <Curriculum>[];
    var cases = <EquivalenceCase>[];
    String? currentId;
    final data = await _store.readJson(key);
    if (data is Map) {
      try {
        curricula =
            [
              for (final e in data['curricula'] as List? ?? const [])
                Curriculum.fromJson(Map<String, dynamic>.from(e as Map)),
            ]..removeWhere(
              (c) =>
                  c.id == 'eca-2013' || c.name == 'Currículo Anterior (2013/2)',
            );
        cases = [
          for (final e in data['cases'] as List? ?? const [])
            EquivalenceCase.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
        currentId = data['currentId'] as String?;
      } on Object {
        // JSON inválido: mantém o catálogo inicial.
      }
    } else {
      final migrated = await _migrateLegacy();
      if (migrated != null) {
        curricula = migrated.curricula;
        cases = migrated.cases;
      }
    }
    if (curricula.isEmpty) curricula = [defaultCurriculum];
    currentId ??= curricula.first.id;
    return EquivalenciaState(
      curricula: curricula,
      cases: cases,
      currentId: currentId,
    );
  }

  Future<void> save(EquivalenciaState state) => _store.writeJson(key, {
    'curricula': state.curricula.map((e) => e.toJson()).toList(),
    'cases': state.cases.map((e) => e.toJson()).toList(),
    'currentId': state.currentId,
  });

  /// Converte as análises da versão anterior em blocos de uma disciplina de
  /// cada lado e grava no formato novo (sem apagar a chave antiga).
  Future<EquivalenciaState?> _migrateLegacy() async {
    final legacy = await _store.readJson(legacyKey);
    if (legacy is! List) return null;
    final curricula = <Curriculum>[defaultCurriculum];
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
      currentId: curricula.first.id,
    );
    if (cases.isNotEmpty) await save(state);
    return state;
  }
}
