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
    required this.code,
    required this.acronym,
    required this.name,
    required this.className,
    required this.teacher,
    this.coTeachers = const [],
    required this.room,
    required this.coursePeriods,
    required this.slots,
    this.theoryHours = 0,
    this.practiceHours = 0,
  });

  final String id;
  final String code;
  final String acronym;
  final String name;
  final String className;
  final String teacher;
  final List<String> coTeachers;
  final String room;
  final List<CursoPeriodo> coursePeriods;
  final List<HorarioSlot> slots;
  final int theoryHours;
  final int practiceHours;

  List<String> get teacherNames => {
    if (teacher.trim().isNotEmpty) teacher.trim(),
    ...coTeachers.map((name) => name.trim()).where((name) => name.isNotEmpty),
  }.toList();

  HorarioDisciplina copyWith({
    String? id,
    String? code,
    String? acronym,
    String? name,
    String? className,
    String? teacher,
    List<String>? coTeachers,
    String? room,
    List<CursoPeriodo>? coursePeriods,
    List<HorarioSlot>? slots,
    int? theoryHours,
    int? practiceHours,
  }) => HorarioDisciplina(
    id: id ?? this.id,
    code: code ?? this.code,
    acronym: acronym ?? this.acronym,
    name: name ?? this.name,
    className: className ?? this.className,
    teacher: teacher ?? this.teacher,
    coTeachers: coTeachers ?? this.coTeachers,
    room: room ?? this.room,
    coursePeriods: coursePeriods ?? this.coursePeriods,
    slots: slots ?? this.slots,
    theoryHours: theoryHours ?? this.theoryHours,
    practiceHours: practiceHours ?? this.practiceHours,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'code': code,
    'acronym': acronym,
    'name': name,
    'className': className,
    'teacher': teacher,
    'coTeachers': coTeachers,
    'room': room,
    'coursePeriods': coursePeriods.map((item) => item.toJson()).toList(),
    'slots': slots.map((item) => item.toJson()).toList(),
    'theoryHours': theoryHours,
    'practiceHours': practiceHours,
  };

  factory HorarioDisciplina.fromJson(Map<String, dynamic> json) =>
      HorarioDisciplina(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        acronym: json['acronym'] as String? ?? '',
        name: json['name'] as String? ?? '',
        className: json['className'] as String? ?? '',
        teacher: json['teacher'] as String? ?? '',
        coTeachers: ((json['coTeachers'] as List?) ?? const [])
            .map((name) => name.toString())
            .toList(),
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
