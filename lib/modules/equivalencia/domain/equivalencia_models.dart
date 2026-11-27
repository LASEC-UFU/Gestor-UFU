/// Modelos da Equivalência de Alunos (formato gravado no banco, chave
/// `student_equivalencies.blocks.v1`).
library;

class Subject {
  const Subject({
    required this.code,
    required this.name,
    required this.theoretical,
    required this.practical,
    this.period = '',
  });

  final String code, name;
  final String period;
  final int theoretical, practical;

  int get hours => theoretical + practical;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'theoretical': theoretical,
    'practical': practical,
    'period': period,
  };

  factory Subject.fromJson(Map<String, dynamic> j) => Subject(
    code: j['code'] ?? '',
    name: j['name'] ?? '',
    theoretical: j['theoretical'] ?? 0,
    practical: j['practical'] ?? 0,
    period: j['period'] ?? '',
  );
}

class Curriculum {
  const Curriculum({
    required this.id,
    required this.course,
    required this.name,
    this.subjects = const [],
  });

  final String id, course, name;
  final List<Subject> subjects;

  String get label => '$course - $name';

  Curriculum copyWith({List<Subject>? subjects}) => Curriculum(
    id: id,
    course: course,
    name: name,
    subjects: subjects ?? this.subjects,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'course': course,
    'name': name,
    'subjects': subjects.map((e) => e.toJson()).toList(),
  };

  factory Curriculum.fromJson(Map<String, dynamic> j) => Curriculum(
    id: j['id'] ?? '',
    course: j['course'] ?? '',
    name: j['name'] ?? '',
    subjects: (j['subjects'] as List? ?? const [])
        .map((e) => Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

/// Bloco da análise: disciplinas do currículo atual ↔ cursadas na origem.
class EquivalenceBlock {
  const EquivalenceBlock({
    required this.id,
    required this.period,
    required this.current,
    required this.prior,
  });

  final String id, period;
  final List<Subject> current, prior;

  int get currentHours => current.fold(0, (sum, s) => sum + s.hours);
  int get priorHours => prior.fold(0, (sum, s) => sum + s.hours);

  Map<String, dynamic> toJson() => {
    'id': id,
    'period': period,
    'current': current.map((e) => e.toJson()).toList(),
    'prior': prior.map((e) => e.toJson()).toList(),
  };

  factory EquivalenceBlock.fromJson(Map<String, dynamic> j) => EquivalenceBlock(
    id: j['id'] ?? '',
    period: j['period'] ?? '',
    current: (j['current'] as List? ?? const [])
        .map((e) => Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    prior: (j['prior'] as List? ?? const [])
        .map((e) => Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

/// Disciplina exibida no histórico visual do aluno.
class HistoricalSubject {
  const HistoricalSubject({required this.subject, this.status = 'Não cursada'});

  final Subject subject;
  final String status;

  HistoricalSubject copyWith({String? status}) =>
      HistoricalSubject(subject: subject, status: status ?? this.status);

  Map<String, dynamic> toJson() => {
    'subject': subject.toJson(),
    'status': status,
  };

  factory HistoricalSubject.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status'] as String?;
    final status = switch (rawStatus) {
      'Não cursada' || 'Dispensado' || 'Aprovado' => rawStatus!,
      _ =>
        json['equivalent'] == true || rawStatus == 'Aprovado'
            ? 'Aprovado'
            : 'Não cursada',
    };
    return HistoricalSubject(
      subject: Subject.fromJson(
        Map<String, dynamic>.from(json['subject'] as Map),
      ),
      status: status,
    );
  }
}

/// Análise de transferência de um aluno.
class EquivalenceCase {
  const EquivalenceCase({
    required this.id,
    required this.student,
    required this.studentId,
    required this.currentCurriculumId,
    required this.priorCurriculumId,
    required this.status,
    required this.notes,
    required this.blocks,
    this.currentCatalog = const [],
    this.priorCatalog = const [],
    this.history = const [],
  });

  static const statuses = ['Em análise', 'Deferida', 'Indeferida'];

  final String id,
      student,
      studentId,
      currentCurriculumId,
      priorCurriculumId,
      status,
      notes;
  final List<EquivalenceBlock> blocks;
  final List<Subject> currentCatalog, priorCatalog;
  final List<HistoricalSubject> history;

  /// A dispensa é derivada dos blocos, inclusive nas análises antigas.
  List<HistoricalSubject> historyFor({Iterable<Subject> subjects = const []}) {
    final equivalent = {
      for (final subject in blocks.expand((b) => b.current))
        subjectCatalogKey(subject): subject,
    };
    final saved = {
      for (final entry in history) subjectCatalogKey(entry.subject): entry,
    };
    return [
      for (final subject in mergeSubjects([
        ...subjects,
        ...history.map((e) => e.subject),
        ...equivalent.values,
      ]))
        HistoricalSubject(
          subject: subject,
          status: equivalent.containsKey(subjectCatalogKey(subject))
              ? 'Dispensado'
              : saved[subjectCatalogKey(subject)]?.status == 'Aprovado'
              ? 'Aprovado'
              : 'Não cursada',
        ),
    ];
  }

  bool get isApproved => status.trim().toLowerCase() == 'deferida';

  Map<String, dynamic> toJson() => {
    'id': id,
    'student': student,
    'studentId': studentId,
    'currentCurriculumId': currentCurriculumId,
    'priorCurriculumId': priorCurriculumId,
    'status': status,
    'notes': notes,
    'blocks': blocks.map((e) => e.toJson()).toList(),
    'currentCatalog': currentCatalog.map((e) => e.toJson()).toList(),
    'priorCatalog': priorCatalog.map((e) => e.toJson()).toList(),
    'history': history.map((e) => e.toJson()).toList(),
  };

  factory EquivalenceCase.fromJson(Map<String, dynamic> j) {
    final blocks = (j['blocks'] as List? ?? const [])
        .map((e) => EquivalenceBlock.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    List<Subject> catalog(String key, bool current) {
      final stored = j[key] as List?;
      final values = stored == null
          ? blocks.expand((b) => current ? b.current : b.prior).toList()
          : stored
                .map((e) => Subject.fromJson(Map<String, dynamic>.from(e)))
                .toList();
      return mergeSubjects(values);
    }

    final item = EquivalenceCase(
      id: j['id'] ?? '',
      student: j['student'] ?? '',
      studentId: j['studentId'] ?? '',
      currentCurriculumId: j['currentCurriculumId'] ?? '',
      priorCurriculumId: '',
      status: j['status'] ?? 'Em análise',
      notes: j['notes'] ?? '',
      blocks: blocks,
      currentCatalog: catalog('currentCatalog', true),
      priorCatalog: catalog('priorCatalog', false),
      history: (j['history'] as List? ?? const [])
          .map((e) => HistoricalSubject.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
    return item.copyWith(history: item.historyFor());
  }

  EquivalenceCase copyWith({
    List<EquivalenceBlock>? blocks,
    List<HistoricalSubject>? history,
    List<Subject>? priorCatalog,
  }) => EquivalenceCase(
    id: id,
    student: student,
    studentId: studentId,
    currentCurriculumId: currentCurriculumId,
    priorCurriculumId: priorCurriculumId,
    status: status,
    notes: notes,
    blocks: blocks ?? this.blocks,
    currentCatalog: currentCatalog,
    priorCatalog: priorCatalog ?? this.priorCatalog,
    history: history ?? this.history,
  );
}

/// Tudo que o módulo guarda.
class EquivalenciaState {
  const EquivalenciaState({
    required this.curricula,
    required this.cases,
    required this.currentId,
  });

  final List<Curriculum> curricula;
  final List<EquivalenceCase> cases;

  /// Currículo de destino selecionado na tela.
  final String? currentId;

  Curriculum? curriculum(String? id) {
    for (final c in curricula) {
      if (c.id == id) return c;
    }
    return null;
  }

  EquivalenceCase? caseById(String id) {
    for (final c in cases) {
      if (c.id == id) return c;
    }
    return null;
  }

  EquivalenciaState copyWith({
    List<Curriculum>? curricula,
    List<EquivalenceCase>? cases,
    String? currentId,
  }) => EquivalenciaState(
    curricula: curricula ?? this.curricula,
    cases: cases ?? this.cases,
    currentId: currentId ?? this.currentId,
  );
}

/// Identidade de uma disciplina no catálogo (código + nome, sem caixa).
String subjectCatalogKey(Subject subject) =>
    '${subject.code.trim().toLowerCase()}|${subject.name.trim().toLowerCase()}';

/// Une listas de disciplinas sem repetir (a última ocorrência vence).
List<Subject> mergeSubjects(Iterable<Subject> subjects) {
  final result = <String, Subject>{};
  for (final subject in subjects) {
    result[subjectCatalogKey(subject)] = subject;
  }
  return result.values.toList();
}

void addSubjects(List<Subject> catalog, Iterable<Subject> subjects) {
  final merged = mergeSubjects([...catalog, ...subjects]);
  catalog
    ..clear()
    ..addAll(merged);
}
