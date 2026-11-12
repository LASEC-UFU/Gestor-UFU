const _sentinel = Object();

class CourseConfig {
  final String id;
  final String name;
  final String? academicTerm;
  final int? moodleCourseId;
  final String? moodleCourseName;
  final DateTime semesterStartDate;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SectionEntry> sections;
  final List<DateTime> holidayDates;

  /// Datas de troca de dia da semana.
  /// Chave: data (normalizada), Valor: dia da semana efetivo (1=seg..7=dom).
  final Map<DateTime, int> daySwapDates;

  CourseConfig({
    required this.id,
    required this.name,
    this.academicTerm,
    this.moodleCourseId,
    this.moodleCourseName,
    required this.semesterStartDate,
    required this.createdAt,
    required this.updatedAt,
    this.sections = const [],
    this.holidayDates = const [],
    this.daySwapDates = const {},
  });

  CourseConfig copyWith({
    String? name,
    String? academicTerm,
    Object? moodleCourseId = _sentinel,
    Object? moodleCourseName = _sentinel,
    DateTime? semesterStartDate,
    DateTime? updatedAt,
    List<SectionEntry>? sections,
    List<DateTime>? holidayDates,
    Map<DateTime, int>? daySwapDates,
  }) {
    return CourseConfig(
      id: id,
      name: name ?? this.name,
      academicTerm: academicTerm ?? this.academicTerm,
      moodleCourseId: moodleCourseId == _sentinel
          ? this.moodleCourseId
          : moodleCourseId as int?,
      moodleCourseName: moodleCourseName == _sentinel
          ? this.moodleCourseName
          : moodleCourseName as String?,
      semesterStartDate: semesterStartDate ?? this.semesterStartDate,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      sections: sections ?? this.sections,
      holidayDates: holidayDates ?? this.holidayDates,
      daySwapDates: daySwapDates ?? this.daySwapDates,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'academicTerm': academicTerm,
    'moodleCourseId': moodleCourseId,
    'moodleCourseName': moodleCourseName,
    'semesterStartDate': semesterStartDate.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'sections': sections.map((s) => s.toJson()).toList(),
    'holidayDates': holidayDates.map((d) => d.toIso8601String()).toList(),
    'daySwapDates': daySwapDates.map(
      (k, v) => MapEntry(k.toIso8601String(), v),
    ),
  };

  factory CourseConfig.fromJson(Map<String, dynamic> json) => CourseConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    academicTerm: json['academicTerm'] as String?,
    moodleCourseId: json['moodleCourseId'] as int?,
    moodleCourseName: json['moodleCourseName'] as String?,
    semesterStartDate: DateTime.parse(json['semesterStartDate'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    sections:
        (json['sections'] as List?)
            ?.map((s) => SectionEntry.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [],
    holidayDates:
        (json['holidayDates'] as List?)
            ?.map((d) => DateTime.parse(d as String))
            .toList() ??
        [],
    daySwapDates:
        (json['daySwapDates'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(DateTime.parse(k), v as int),
        ) ??
        {},
  );
}

class SectionEntry {
  final String id;
  final int orderIndex;
  final String name;
  final int referenceDaysOffset;
  final DateTime date;
  final int offsetDays;
  final int? moodleSectionId;
  final bool visible;
  final List<ActivityEntry> activities;
  final String? moodleDescription;

  SectionEntry({
    required this.id,
    required this.orderIndex,
    required this.name,
    this.referenceDaysOffset = 0,
    required this.date,
    required this.offsetDays,
    this.moodleSectionId,
    this.visible = true,
    this.activities = const [],
    this.moodleDescription,
  });

  SectionEntry copyWith({
    int? orderIndex,
    String? name,
    int? referenceDaysOffset,
    DateTime? date,
    int? offsetDays,
    Object? moodleSectionId = _sentinel,
    bool? visible,
    List<ActivityEntry>? activities,
    Object? moodleDescription = _sentinel,
  }) {
    return SectionEntry(
      id: id,
      orderIndex: orderIndex ?? this.orderIndex,
      name: name ?? this.name,
      referenceDaysOffset: referenceDaysOffset ?? this.referenceDaysOffset,
      date: date ?? this.date,
      offsetDays: offsetDays ?? this.offsetDays,
      moodleSectionId: moodleSectionId == _sentinel
          ? this.moodleSectionId
          : moodleSectionId as int?,
      visible: visible ?? this.visible,
      activities: activities ?? this.activities,
      moodleDescription: moodleDescription == _sentinel
          ? this.moodleDescription
          : moodleDescription as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'orderIndex': orderIndex,
    'name': name,
    'referenceDaysOffset': referenceDaysOffset,
    'date': date.toIso8601String(),
    'offsetDays': offsetDays,
    'moodleSectionId': moodleSectionId,
    'visible': visible,
    'activities': activities.map((a) => a.toJson()).toList(),
    'moodleDescription': moodleDescription,
  };

  factory SectionEntry.fromJson(Map<String, dynamic> json) => SectionEntry(
    id: json['id'] as String,
    orderIndex: json['orderIndex'] as int,
    name: json['name'] as String,
    referenceDaysOffset: json['referenceDaysOffset'] as int? ?? 0,
    date: DateTime.parse(json['date'] as String),
    offsetDays: json['offsetDays'] as int,
    moodleSectionId: json['moodleSectionId'] as int?,
    visible: json['visible'] as bool? ?? true,
    activities:
        (json['activities'] as List?)
            ?.map((a) => ActivityEntry.fromJson(a as Map<String, dynamic>))
            .toList() ??
        [],
    moodleDescription: json['moodleDescription'] as String?,
  );
}

class ActivityEntry {
  final String id;
  final String name;
  final String activityType; // AT, AA, AP, AS, Prática, Teórica, etc.
  final DateTime? openDate; // mantido para export/compat
  final DateTime? closeDate; // mantido para export/compat
  final int? openOffsetDays;
  final int? closeOffsetDays;
  final int? openTimeMinutes; // minutos desde 00:00 (ex: 480 = 08:00)
  final int? closeTimeMinutes;
  final int? moodleModuleId;
  final String? moodleModuleName;
  final String? modality; // Prática, Teórica, etc.

  /// 0=oculto, 1=visível, 2=disponível mas não mostrar (stealth)
  final int visibility;

  /// Dia da semana esperado para esta atividade (1=segunda..7=domingo).
  /// null = sem verificação.
  final int? expectedWeekday;

  ActivityEntry({
    required this.id,
    required this.name,
    required this.activityType,
    this.openDate,
    this.closeDate,
    this.openOffsetDays,
    this.closeOffsetDays,
    this.openTimeMinutes,
    this.closeTimeMinutes,
    this.moodleModuleId,
    this.moodleModuleName,
    this.modality,
    this.visibility = 1,
    this.expectedWeekday,
  });

  /// Calcula a data de abertura a partir da data de referência da seção.
  DateTime? computeOpenDate(DateTime sectionRefDate) {
    if (openOffsetDays == null) return null;
    final d = sectionRefDate.add(Duration(days: openOffsetDays!));
    if (openTimeMinutes != null) {
      return DateTime(
        d.year,
        d.month,
        d.day,
        openTimeMinutes! ~/ 60,
        openTimeMinutes! % 60,
      );
    }
    return d;
  }

  /// Calcula a data de encerramento a partir da data de referência da seção.
  DateTime? computeCloseDate(DateTime sectionRefDate) {
    if (closeOffsetDays == null) return null;
    final d = sectionRefDate.add(Duration(days: closeOffsetDays!));
    if (closeTimeMinutes != null) {
      return DateTime(
        d.year,
        d.month,
        d.day,
        closeTimeMinutes! ~/ 60,
        closeTimeMinutes! % 60,
      );
    }
    return d;
  }

  ActivityEntry copyWith({
    String? name,
    String? activityType,
    Object? openDate = _sentinel,
    Object? closeDate = _sentinel,
    Object? openOffsetDays = _sentinel,
    Object? closeOffsetDays = _sentinel,
    Object? openTimeMinutes = _sentinel,
    Object? closeTimeMinutes = _sentinel,
    Object? moodleModuleId = _sentinel,
    Object? moodleModuleName = _sentinel,
    Object? modality = _sentinel,
    int? visibility,
    Object? expectedWeekday = _sentinel,
  }) {
    return ActivityEntry(
      id: id,
      name: name ?? this.name,
      activityType: activityType ?? this.activityType,
      openDate: openDate == _sentinel ? this.openDate : openDate as DateTime?,
      closeDate: closeDate == _sentinel
          ? this.closeDate
          : closeDate as DateTime?,
      openOffsetDays: openOffsetDays == _sentinel
          ? this.openOffsetDays
          : openOffsetDays as int?,
      closeOffsetDays: closeOffsetDays == _sentinel
          ? this.closeOffsetDays
          : closeOffsetDays as int?,
      openTimeMinutes: openTimeMinutes == _sentinel
          ? this.openTimeMinutes
          : openTimeMinutes as int?,
      closeTimeMinutes: closeTimeMinutes == _sentinel
          ? this.closeTimeMinutes
          : closeTimeMinutes as int?,
      moodleModuleId: moodleModuleId == _sentinel
          ? this.moodleModuleId
          : moodleModuleId as int?,
      moodleModuleName: moodleModuleName == _sentinel
          ? this.moodleModuleName
          : moodleModuleName as String?,
      modality: modality == _sentinel ? this.modality : modality as String?,
      visibility: visibility ?? this.visibility,
      expectedWeekday: expectedWeekday == _sentinel
          ? this.expectedWeekday
          : expectedWeekday as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'activityType': activityType,
    'openDate': openDate?.toIso8601String(),
    'closeDate': closeDate?.toIso8601String(),
    'openOffsetDays': openOffsetDays,
    'closeOffsetDays': closeOffsetDays,
    'openTimeMinutes': openTimeMinutes,
    'closeTimeMinutes': closeTimeMinutes,
    'moodleModuleId': moodleModuleId,
    'moodleModuleName': moodleModuleName,
    'modality': modality,
    'visibility': visibility,
    'expectedWeekday': expectedWeekday,
  };

  factory ActivityEntry.fromJson(Map<String, dynamic> json) => ActivityEntry(
    id: json['id'] as String,
    name: json['name'] as String,
    activityType: json['activityType'] as String,
    openDate: json['openDate'] != null
        ? DateTime.parse(json['openDate'] as String)
        : null,
    closeDate: json['closeDate'] != null
        ? DateTime.parse(json['closeDate'] as String)
        : null,
    openOffsetDays: json['openOffsetDays'] as int?,
    closeOffsetDays: json['closeOffsetDays'] as int?,
    openTimeMinutes: json['openTimeMinutes'] as int?,
    closeTimeMinutes: json['closeTimeMinutes'] as int?,
    moodleModuleId: json['moodleModuleId'] as int?,
    moodleModuleName: json['moodleModuleName'] as String?,
    modality: json['modality'] as String?,
    visibility:
        json['visibility'] as int? ?? (json['visible'] == false ? 0 : 1),
    expectedWeekday: json['expectedWeekday'] as int?,
  );
}
