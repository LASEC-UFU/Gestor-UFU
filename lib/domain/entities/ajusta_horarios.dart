class HorarioSlot {
  const HorarioSlot({required this.weekday, required this.slot});

  /// Monday = 1 ... Friday = 5, matching the original BDados encoding.
  final int weekday;

  /// Time slot index in [horarioFaixas].
  final int slot;

  String get key => '$weekday:$slot';
  Map<String, int> toJson() => {'weekday': weekday, 'slot': slot};
  factory HorarioSlot.fromJson(Map<String, dynamic> json) => HorarioSlot(
    weekday: (json['weekday'] as num).toInt(),
    slot: (json['slot'] as num).toInt(),
  );
}

class CursoPeriodo {
  const CursoPeriodo({required this.program, required this.period});
  final int program;
  final int period;
  Map<String, int> toJson() => {'program': program, 'period': period};
  factory CursoPeriodo.fromJson(Map<String, dynamic> json) => CursoPeriodo(
    program: (json['program'] as num).toInt(),
    period: (json['period'] as num).toInt(),
  );
}

class HorarioDisciplina {
  const HorarioDisciplina({
    required this.id,
    String? subjectId,
    this.modality = 'legacy',
    required this.code,
    required this.acronym,
    required this.name,
    required this.className,
    this.teachers = const [],
    required this.room,
    required this.coursePeriods,
    required this.slots,
    this.theoryHours = 0,
    this.practiceHours = 0,
    this.eadHours = 0,
    this.extensionHours = 0,
  }) : subjectId = subjectId ?? id;

  final String id;

  /// Identifies the logical subject shared by its theory/practice/EaD/extension groups.
  final String subjectId;

  /// theory, practice, ead, extension or legacy (pre-modality records).
  final String modality;
  final String code;
  final String acronym;
  final String name;
  final String className;

  /// Teachers assigned to this specific modality/class group.
  final List<String> teachers;
  final String room;
  final List<CursoPeriodo> coursePeriods;
  final List<HorarioSlot> slots;
  final int theoryHours;
  final int practiceHours;
  final int eadHours;
  final int extensionHours;

  String get timetableLabel {
    final subject = acronym.trim().isEmpty ? name.trim() : acronym.trim();
    final modalityLabel = switch (modality) {
      'theory' => 'T',
      'practice' => 'P',
      'ead' => 'EaD',
      'extension' => 'E',
      _ => '',
    };
    return [
      subject,
      modalityLabel,
      className.trim(),
    ].where((part) => part.isNotEmpty).join('-');
  }

  List<String> get teacherNames => teachers
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList();

  HorarioDisciplina copyWith({
    String? id,
    String? subjectId,
    String? modality,
    String? code,
    String? acronym,
    String? name,
    String? className,
    List<String>? teachers,
    String? room,
    List<CursoPeriodo>? coursePeriods,
    List<HorarioSlot>? slots,
    int? theoryHours,
    int? practiceHours,
    int? eadHours,
    int? extensionHours,
  }) => HorarioDisciplina(
    id: id ?? this.id,
    subjectId: subjectId ?? this.subjectId,
    modality: modality ?? this.modality,
    code: code ?? this.code,
    acronym: acronym ?? this.acronym,
    name: name ?? this.name,
    className: className ?? this.className,
    teachers: teachers ?? this.teachers,
    room: room ?? this.room,
    coursePeriods: coursePeriods ?? this.coursePeriods,
    slots: slots ?? this.slots,
    theoryHours: theoryHours ?? this.theoryHours,
    practiceHours: practiceHours ?? this.practiceHours,
    eadHours: eadHours ?? this.eadHours,
    extensionHours: extensionHours ?? this.extensionHours,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'subjectId': subjectId,
    'modality': modality,
    'code': code,
    'acronym': acronym,
    'name': name,
    'className': className,
    'teachers': teacherNames,
    'room': room,
    'coursePeriods': coursePeriods.map((item) => item.toJson()).toList(),
    'slots': slots.map((item) => item.toJson()).toList(),
    'theoryHours': theoryHours,
    'practiceHours': practiceHours,
    'eadHours': eadHours,
    'extensionHours': extensionHours,
  };

  static List<String> _readTeacherNames(Map<String, dynamic> json) {
    final names = <String>[];
    final seen = <String>{};

    void add(Object? value) {
      final name = value?.toString().trim() ?? '';
      if (name.isEmpty || !seen.add(name.toLowerCase())) return;
      names.add(name);
    }

    // `teacher` and `coTeachers` were used by older database files. Keep
    // reading them so upgrading the app never silently removes assignments.
    final current = json['teachers'];
    if (current is List) {
      for (final name in current) {
        add(name);
      }
    }
    add(json['teacher']);
    final legacyCoTeachers = json['coTeachers'];
    if (legacyCoTeachers is List) {
      for (final name in legacyCoTeachers) {
        add(name);
      }
    }
    return names;
  }

  factory HorarioDisciplina.fromJson(Map<String, dynamic> json) =>
      HorarioDisciplina(
        id: json['id'] as String,
        subjectId: json['subjectId'] as String? ?? json['id'] as String,
        modality: json['modality'] as String? ?? 'legacy',
        code: json['code'] as String? ?? '',
        acronym: json['acronym'] as String? ?? '',
        name: json['name'] as String? ?? '',
        className: json['className'] as String? ?? '',
        teachers: _readTeacherNames(json),
        room: json['room'] as String? ?? '',
        coursePeriods: ((json['coursePeriods'] as List?) ?? const [])
            .map(
              (item) =>
                  CursoPeriodo.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList(),
        slots: ((json['slots'] as List?) ?? const [])
            .map(
              (item) =>
                  HorarioSlot.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList(),
        theoryHours: (json['theoryHours'] as num?)?.toInt() ?? 0,
        practiceHours: (json['practiceHours'] as num?)?.toInt() ?? 0,
        eadHours: (json['eadHours'] as num?)?.toInt() ?? 0,
        extensionHours: (json['extensionHours'] as num?)?.toInt() ?? 0,
      );
}

const horarioProgramas = <int, String>{
  1: 'Engenharia Elétrica',
  2: 'Engenharia de Controle e Automação',
  3: 'Engenharia Eletrônica e de Telecomunicações',
  4: 'Engenharia de Computação',
  5: 'Engenharia Biomédica',
};

const horarioDias = <String>['Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta'];
const horarioFaixas = <String>[
  '07:10 – 08:00',
  '08:00 – 08:50',
  '08:50 – 09:40',
  '09:50 – 10:40',
  '10:40 – 11:30',
  '11:30 – 12:20',
  '13:10 – 14:00',
  '14:00 – 14:50',
  '14:50 – 15:40',
  '16:00 – 16:50',
  '16:50 – 17:40',
  '17:40 – 18:30',
  '19:00 – 19:50',
  '19:50 – 20:40',
  '20:50 – 21:40',
  '21:40 – 22:30',
];
