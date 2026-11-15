/// Uma linha da distribuição docente (aba Banco): docente, disciplina/turma,
/// período e cargas horárias.
class DistribuicaoDocente {
  const DistribuicaoDocente({
    required this.teacher,
    required this.discipline,
    required this.period,
    required this.theoryHours,
    required this.practiceHours,
    this.eadHours = 0,
    this.extensionHours = 0,
  });

  final String teacher;
  final String discipline;
  final String period;
  final int theoryHours;
  final int practiceHours;
  final int eadHours;
  final int extensionHours;

  Map<String, Object> toJson() => {
    'teacher': teacher,
    'discipline': discipline,
    'period': period,
    'theoryHours': theoryHours,
    'practiceHours': practiceHours,
    'eadHours': eadHours,
    'extensionHours': extensionHours,
  };

  factory DistribuicaoDocente.fromJson(Map<String, dynamic> json) =>
      DistribuicaoDocente(
        teacher: json['teacher'] as String? ?? '',
        discipline: json['discipline'] as String? ?? '',
        period: json['period'] as String? ?? '',
        theoryHours: (json['theoryHours'] as num?)?.toInt() ?? 0,
        practiceHours: (json['practiceHours'] as num?)?.toInt() ?? 0,
        eadHours: (json['eadHours'] as num?)?.toInt() ?? 0,
        extensionHours: (json['extensionHours'] as num?)?.toInt() ?? 0,
      );
}
