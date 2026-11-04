import 'package:gestor_ufu/domain/entities/course_config.dart';

/// Imutável: uma fotografia completa da configuração em um momento do tempo.
class MoodleConfigSnapshot {
  final String id;
  final String configId;
  final String courseName;
  final String label;
  final DateTime createdAt;
  final DateTime semesterStartDate;
  final Map<String, dynamic> configData;

  const MoodleConfigSnapshot({
    required this.id,
    required this.configId,
    required this.courseName,
    required this.label,
    required this.createdAt,
    required this.semesterStartDate,
    required this.configData,
  });

  CourseConfig toCourseConfig() => CourseConfig.fromJson(configData);

  Map<String, dynamic> toJson() => {
    'id': id,
    'configId': configId,
    'courseName': courseName,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
    'semesterStartDate': semesterStartDate.toIso8601String(),
    'configData': configData,
  };

  factory MoodleConfigSnapshot.fromJson(Map<String, dynamic> json) =>
      MoodleConfigSnapshot(
        id: json['id'] as String,
        configId: json['configId'] as String,
        courseName: json['courseName'] as String? ?? 'Configuração Moodle',
        label: json['label'] as String? ?? 'Backup',
        createdAt: DateTime.parse(json['createdAt'] as String),
        semesterStartDate: DateTime.parse(json['semesterStartDate'] as String),
        configData: Map<String, dynamic>.from(
          json['configData'] as Map<String, dynamic>,
        ),
      );
}
