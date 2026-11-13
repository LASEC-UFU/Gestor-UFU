import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/core/utils/date_calculator.dart';
import 'package:gestor_ufu/data/services/ajusta_horarios_store.dart';
import 'package:gestor_ufu/domain/entities/academic_term.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_config_snapshot.dart';
import 'package:gestor_ufu/domain/repositories/i_config_repository.dart';

class ConfigController extends ChangeNotifier {
  static const _termKey = 'ajusta_horarios_periodo_letivo';
  static const _termsKey = 'ajusta_horarios_periodos_letivos';
  final IConfigRepository _repo;
  final _uuid = const Uuid();

  ConfigController(this._repo);

  List<CourseConfig> _configs = [];
  CourseConfig? _current;
  bool _loading = false;
  String? _error;
  String _activeTerm = AjustaHorariosStore.defaultTerm;
  List<String> _terms = [AjustaHorariosStore.defaultTerm];
  final Set<String> _selectedActivityIds = {};

  List<CourseConfig> get configs => _configs;
  CourseConfig? get current => _current;
  bool get loading => _loading;
  String? get error => _error;
  Set<String> get selectedActivityIds => _selectedActivityIds;
  bool get hasSelection => _selectedActivityIds.isNotEmpty;
  String get activeTerm => _activeTerm;
  List<String> get terms => List.unmodifiable(_terms);

  Future<void> loadAll() async {
    _loading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      _terms = AcademicTerm.newestFirst(
        (prefs.getStringList(_termsKey) ?? const <String>[])
            .map((term) => term.trim())
            .where((term) => term.isNotEmpty),
      );
      if (_terms.isEmpty) _terms = [AjustaHorariosStore.defaultTerm];
      final storedTerm = prefs.getString(_termKey)?.trim();
      _activeTerm = storedTerm != null && _terms.contains(storedTerm)
          ? storedTerm
          : _terms.first;
      await prefs.setStringList(_termsKey, _terms);
      await prefs.setString(_termKey, _activeTerm);

      final allConfigs = await _repo.getAll();
      final normalized = <CourseConfig>[];
      for (final config in allConfigs) {
        if (config.academicTerm == null ||
            config.academicTerm!.trim().isEmpty) {
          final migrated = config.copyWith(academicTerm: _activeTerm);
          await _repo.save(migrated);
          normalized.add(migrated);
        } else {
          normalized.add(config);
        }
      }
      _configs =
          normalized
              .where((config) => config.academicTerm == _activeTerm)
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> setActiveTerm(String term) async {
    if (!_terms.contains(term) || term == _activeTerm) return;
    final prefs = await SharedPreferences.getInstance();
    _activeTerm = term;
    await prefs.setString(_termKey, term);
    notifyListeners();
    await loadAll();
  }

  Future<void> createTerm(String name) async {
    final requested = name.trim();
    if (requested.isEmpty) return;
    final canonical = AcademicTerm.parse(requested)?.key ?? requested;
    final existing =
        AcademicTerm.findEquivalent(_terms, canonical) ??
        _terms.cast<String?>().firstWhere(
          (item) => item?.toLowerCase() == canonical.toLowerCase(),
          orElse: () => null,
        );
    if (existing != null) {
      await setActiveTerm(existing);
      return;
    }
    _terms = AcademicTerm.newestFirst([..._terms, canonical]);
    _activeTerm = canonical;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_termsKey, _terms);
    await prefs.setString(_termKey, canonical);
    notifyListeners();
    await loadAll();
  }

  Future<void> loadById(String id) async {
    _loading = true;
    notifyListeners();
    try {
      _current = await _repo.getById(id);
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _loading = false;
    notifyListeners();
  }

  Future<void> createEmpty(String name) async {
    final now = DateTime.now();
    final config = CourseConfig(
      id: _uuid.v4(),
      name: name,
      academicTerm: _activeTerm,
      semesterStartDate: now,
      createdAt: now,
      updatedAt: now,
      sections: [],
    );
    await _repo.save(config);
    await loadAll();
  }

  Future<void> saveNewConfig(CourseConfig config) async {
    await _repo.save(
      config.academicTerm == null || config.academicTerm!.trim().isEmpty
          ? config.copyWith(academicTerm: _activeTerm)
          : config,
    );
    await loadAll();
  }

  Future<bool> importSpreadsheet(String filePath, {String? replaceId}) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _repo.importFromSpreadsheet(filePath, replaceId: replaceId);
      await loadAll();
      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Erro ao importar: $e';
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> importSpreadsheetBytes(
    Uint8List bytes, {
    String? replaceId,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _repo.importFromSpreadsheetBytes(bytes, replaceId: replaceId);
      await loadAll();
      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Erro ao importar: $e';
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  /// Retorna configs existentes cujo nome coincide com alguma sheet da planilha.
  List<CourseConfig> findDuplicates(String filePath) {
    final repo = _repo as dynamic;
    final parsed = repo.parseSpreadsheet(filePath) as List<CourseConfig>;
    if (parsed.isEmpty) return [];
    final names = parsed.map((c) => c.name.toLowerCase()).toSet();
    return _configs.where((c) => names.contains(c.name.toLowerCase())).toList();
  }

  /// Retorna configs existentes cujo nome coincide com alguma sheet (via bytes).
  List<CourseConfig> findDuplicatesFromBytes(Uint8List bytes) {
    final parsed = _repo.parseSpreadsheetBytes(bytes);
    if (parsed.isEmpty) return [];
    final names = parsed.map((c) => c.name.toLowerCase()).toSet();
    return _configs.where((c) => names.contains(c.name.toLowerCase())).toList();
  }

  Future<Uint8List?> exportSpreadsheetBytes(String courseConfigId) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final bytes = await _repo.exportToSpreadsheetBytes(courseConfigId);
      _loading = false;
      notifyListeners();
      return bytes;
    } catch (e) {
      _error = 'Erro ao exportar: $e';
      _loading = false;
      notifyListeners();
      return null;
    }
  }

  Future<void> deleteConfig(String id) async {
    await _repo.delete(id);
    if (_current?.id == id) _current = null;
    await loadAll();
  }

  Future<List<MoodleConfigSnapshot>> getSnapshots({String? configId}) =>
      _repo.getSnapshots(configId: configId);

  Future<void> createSnapshot(String configId, {required String label}) async {
    await _repo.createSnapshot(configId, label: label);
    notifyListeners();
  }

  Future<void> restoreSnapshot(String configId, String snapshotId) async {
    await _repo.restoreSnapshot(configId, snapshotId);
    await loadAll();
  }

  // ── Edição de data principal ──────────────────────────────────────────────

  Future<void> updateSemesterStartDate(DateTime newDate) async {
    if (_current == null) return;

    final oldDate = _current!.semesterStartDate;
    final offsetShift = newDate.difference(oldDate).inDays;

    final updatedSections = _current!.sections.map((section) {
      final newSectionDate = section.date.add(Duration(days: offsetShift));
      final sectionRefDate = newDate.add(
        Duration(days: section.referenceDaysOffset),
      );
      final updatedActivities = section.activities.map((activity) {
        // Recomputar datas absolutas a partir dos offsets
        return activity.copyWith(
          openDate: activity.computeOpenDate(sectionRefDate),
          closeDate: activity.computeCloseDate(sectionRefDate),
        );
      }).toList();
      return section.copyWith(
        date: newSectionDate,
        activities: updatedActivities,
      );
    }).toList();

    _current = _current!.copyWith(
      semesterStartDate: newDate,
      sections: updatedSections,
    );
    await _repo.save(_current!);
    notifyListeners();
  }

  // ── CRUD Seções ───────────────────────────────────────────────────────────

  Future<void> addSection(String name, DateTime date) async {
    if (_current == null) return;
    final offset = DateCalculator.calculateOffset(
      _current!.semesterStartDate,
      date,
    );
    final section = SectionEntry(
      id: _uuid.v4(),
      orderIndex: _current!.sections.length + 1,
      name: name,
      referenceDaysOffset: offset,
      date: date,
      offsetDays: offset,
    );
    _current = _current!.copyWith(sections: [..._current!.sections, section]);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> updateSection(
    String sectionId, {
    String? name,
    int? referenceDaysOffset,
    DateTime? date,
    bool? visible,
  }) async {
    if (_current == null) return;
    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      final newRefOffset = referenceDaysOffset ?? s.referenceDaysOffset;
      final newDate =
          date ?? _current!.semesterStartDate.add(Duration(days: newRefOffset));
      final newOffsetDays = DateCalculator.calculateOffset(
        _current!.semesterStartDate,
        newDate,
      );
      return s.copyWith(
        name: name,
        referenceDaysOffset: newRefOffset,
        date: newDate,
        offsetDays: newOffsetDays,
        visible: visible,
      );
    }).toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> removeSection(String sectionId) async {
    if (_current == null) return;
    final sections = _current!.sections
        .where((s) => s.id != sectionId)
        .toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> reorderSections(int oldIndex, int newIndex) async {
    if (_current == null) return;
    final sections = [..._current!.sections];
    final item = sections.removeAt(oldIndex);
    if (newIndex > oldIndex) newIndex--;
    sections.insert(newIndex, item);
    for (var i = 0; i < sections.length; i++) {
      sections[i] = sections[i].copyWith(orderIndex: i + 1);
    }
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  // ── CRUD Atividades ───────────────────────────────────────────────────────

  Future<void> addActivity(
    String sectionId,
    String name,
    String type, {
    int? openOffsetDays,
    int? closeOffsetDays,
    int? openTimeMinutes,
    int? closeTimeMinutes,
    int? moodleModuleId,
    String? modality,
  }) async {
    if (_current == null) return;
    final section = _current!.sections.firstWhere((s) => s.id == sectionId);
    final sectionRefDate = _current!.semesterStartDate.add(
      Duration(days: section.referenceDaysOffset),
    );
    final activity = ActivityEntry(
      id: _uuid.v4(),
      name: name,
      activityType: type,
      moodleModuleId: moodleModuleId,
      openOffsetDays: openOffsetDays,
      closeOffsetDays: closeOffsetDays,
      openTimeMinutes: openTimeMinutes,
      closeTimeMinutes: closeTimeMinutes,
      modality: modality,
    );
    // Computar datas absolutas para export/compat
    final withDates = activity.copyWith(
      openDate: activity.computeOpenDate(sectionRefDate),
      closeDate: activity.computeCloseDate(sectionRefDate),
    );
    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(activities: [...s.activities, withDates]);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  static const _sentinel = Object();

  Future<void> updateActivity(
    String sectionId,
    String activityId, {
    String? name,
    String? type,
    Object? openOffsetDays = _sentinel,
    Object? closeOffsetDays = _sentinel,
    Object? openTimeMinutes = _sentinel,
    Object? closeTimeMinutes = _sentinel,
    Object? moodleModuleId = _sentinel,
    Object? moodleModuleName = _sentinel,
    Object? modality = _sentinel,
    int? visibility,
    Object? expectedWeekday = _sentinel,
  }) async {
    if (_current == null) return;
    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      final sectionRefDate = _current!.semesterStartDate.add(
        Duration(days: s.referenceDaysOffset),
      );
      final activities = s.activities.map((a) {
        if (a.id != activityId) return a;
        final updated = a.copyWith(
          name: name,
          activityType: type,
          openOffsetDays: openOffsetDays == _sentinel
              ? a.openOffsetDays
              : openOffsetDays as int?,
          closeOffsetDays: closeOffsetDays == _sentinel
              ? a.closeOffsetDays
              : closeOffsetDays as int?,
          openTimeMinutes: openTimeMinutes == _sentinel
              ? a.openTimeMinutes
              : openTimeMinutes as int?,
          closeTimeMinutes: closeTimeMinutes == _sentinel
              ? a.closeTimeMinutes
              : closeTimeMinutes as int?,
          moodleModuleId: moodleModuleId == _sentinel
              ? a.moodleModuleId
              : moodleModuleId as int?,
          moodleModuleName: moodleModuleName == _sentinel
              ? a.moodleModuleName
              : moodleModuleName as String?,
          modality: modality == _sentinel ? a.modality : modality as String?,
          visibility: visibility,
          expectedWeekday: expectedWeekday == _sentinel
              ? a.expectedWeekday
              : expectedWeekday as int?,
        );
        // Recomputar datas absolutas
        return updated.copyWith(
          openDate: updated.computeOpenDate(sectionRefDate),
          closeDate: updated.computeCloseDate(sectionRefDate),
        );
      }).toList();
      return s.copyWith(activities: activities);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    notifyListeners();
    await _repo.save(_current!);
  }

  Future<void> removeActivity(String sectionId, String activityId) async {
    if (_current == null) return;
    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(
        activities: s.activities.where((a) => a.id != activityId).toList(),
      );
    }).toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> reorderActivities(
    String sectionId,
    int oldIndex,
    int newIndex,
  ) async {
    if (_current == null) return;

    if (_selectedActivityIds.isNotEmpty) {
      await _reorderSelectedActivities(sectionId, oldIndex, newIndex);
      return;
    }

    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      final list = [...s.activities];
      final item = list.removeAt(oldIndex);
      if (newIndex > oldIndex) newIndex--;
      list.insert(newIndex, item);
      return s.copyWith(activities: list);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> _reorderSelectedActivities(
    String sectionId,
    int draggedIndex,
    int targetIndex,
  ) async {
    if (_current == null) return;

    // ReorderableListView convention: adjust targetIndex when moving down
    if (targetIndex > draggedIndex) targetIndex--;

    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      final activities = [...s.activities];
      final selectedIds = _selectedActivityIds;

      // Ensure dragged item is in selection
      final draggedId = activities[draggedIndex].id;
      if (!selectedIds.contains(draggedId)) {
        // Fallback to single-item reorder
        final item = activities.removeAt(draggedIndex);
        activities.insert(targetIndex, item);
        return s.copyWith(activities: activities);
      }

      // Extract selected items preserving their relative order
      final selected = activities
          .where((a) => selectedIds.contains(a.id))
          .toList();
      final remaining = activities
          .where((a) => !selectedIds.contains(a.id))
          .toList();

      // Compute insertion index in the remaining list:
      // Count how many non-selected items are before the target position
      final insertAt = activities
          .sublist(0, targetIndex + (targetIndex >= draggedIndex ? 1 : 0))
          .where((a) => !selectedIds.contains(a.id))
          .length
          .clamp(0, remaining.length);

      remaining.insertAll(insertAt, selected);
      return s.copyWith(activities: remaining);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    _selectedActivityIds.clear();
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> moveActivity(
    String fromSectionId,
    String toSectionId,
    String activityId,
  ) async {
    if (_current == null) return;
    ActivityEntry? moving;
    var sections = _current!.sections.map((s) {
      if (s.id != fromSectionId) return s;
      moving = s.activities.firstWhere((a) => a.id == activityId);
      return s.copyWith(
        activities: s.activities.where((a) => a.id != activityId).toList(),
      );
    }).toList();
    if (moving == null) return;
    sections = sections.map((s) {
      if (s.id != toSectionId) return s;
      return s.copyWith(activities: [...s.activities, moving!]);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  /// Move a single activity to [toSectionId] at [insertIndex].
  /// Works for both cross-section and within-section repositioning.
  Future<void> moveActivityToIndex(
    String fromSectionId,
    String toSectionId,
    String activityId,
    int insertIndex,
  ) async {
    if (_current == null) return;
    ActivityEntry? moving;

    // Remove from source
    var sections = _current!.sections.map((s) {
      if (s.id != fromSectionId) return s;
      moving = s.activities.firstWhere((a) => a.id == activityId);
      return s.copyWith(
        activities: s.activities.where((a) => a.id != activityId).toList(),
      );
    }).toList();
    if (moving == null) return;

    // Insert at target index
    sections = sections.map((s) {
      if (s.id != toSectionId) return s;
      final list = [...s.activities];
      final clampedIdx = insertIndex.clamp(0, list.length);
      list.insert(clampedIdx, moving!);
      return s.copyWith(activities: list);
    }).toList();

    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  void toggleActivitySelection(String activityId) {
    if (_selectedActivityIds.contains(activityId)) {
      _selectedActivityIds.remove(activityId);
    } else {
      _selectedActivityIds.add(activityId);
    }
    notifyListeners();
  }

  void clearSelection() {
    _selectedActivityIds.clear();
    notifyListeners();
  }

  Future<void> moveSelectedActivities(String toSectionId) async {
    if (_current == null || _selectedActivityIds.isEmpty) return;
    final ids = Set<String>.from(_selectedActivityIds);
    final List<ActivityEntry> moving = [];

    var sections = _current!.sections.map((s) {
      final toMove = s.activities.where((a) => ids.contains(a.id)).toList();
      if (toMove.isEmpty) return s;
      moving.addAll(toMove);
      return s.copyWith(
        activities: s.activities.where((a) => !ids.contains(a.id)).toList(),
      );
    }).toList();

    if (moving.isEmpty) return;

    sections = sections.map((s) {
      if (s.id != toSectionId) return s;
      return s.copyWith(activities: [...s.activities, ...moving]);
    }).toList();

    _current = _current!.copyWith(sections: sections);
    _selectedActivityIds.clear();
    await _repo.save(_current!);
    notifyListeners();
  }

  /// Move selected activities to [toSectionId] inserting at [insertIndex].
  /// Used for within-section reorder via drag-and-drop.
  Future<void> moveSelectedActivitiesAtIndex(
    String toSectionId,
    int insertIndex,
  ) async {
    if (_current == null || _selectedActivityIds.isEmpty) return;
    final ids = Set<String>.from(_selectedActivityIds);
    final List<ActivityEntry> moving = [];

    var sections = _current!.sections.map((s) {
      final toMove = s.activities.where((a) => ids.contains(a.id)).toList();
      if (toMove.isEmpty) return s;
      moving.addAll(toMove);
      return s.copyWith(
        activities: s.activities.where((a) => !ids.contains(a.id)).toList(),
      );
    }).toList();

    if (moving.isEmpty) return;

    sections = sections.map((s) {
      if (s.id != toSectionId) return s;
      final list = [...s.activities];
      final clampedIdx = insertIndex.clamp(0, list.length);
      list.insertAll(clampedIdx, moving);
      return s.copyWith(activities: list);
    }).toList();

    _current = _current!.copyWith(sections: sections);
    _selectedActivityIds.clear();
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> updateConfigName(String name) async {
    if (_current == null) return;
    _current = _current!.copyWith(name: name);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> linkMoodleCourse(
    int moodleCourseId,
    String moodleCourseName,
  ) async {
    if (_current == null) return;
    _current = _current!.copyWith(
      moodleCourseId: moodleCourseId,
      moodleCourseName: moodleCourseName,
    );
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> linkSectionToMoodle(
    String sectionId,
    int? moodleSectionId,
  ) async {
    if (_current == null) return;
    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(moodleSectionId: moodleSectionId);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> linkActivityToMoodle(
    String sectionId,
    String activityId,
    int? moodleModuleId, {
    String? activityType,
    String? name,
    String? moodleModuleName,
  }) async {
    if (_current == null) return;
    final sections = _current!.sections.map((s) {
      if (s.id != sectionId) return s;
      final activities = s.activities.map((a) {
        if (a.id != activityId) return a;
        return a.copyWith(
          moodleModuleId: moodleModuleId,
          activityType: activityType,
          name: name,
          moodleModuleName: moodleModuleName,
        );
      }).toList();
      return s.copyWith(activities: activities);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    notifyListeners();
    await _repo.save(_current!);
  }

  /// Remove todos os vínculos Moodle (seções + atividades).
  Future<void> unlinkAll() async {
    if (_current == null) return;
    final sections = _current!.sections.map((s) {
      final activities = s.activities.map((a) {
        return a.copyWith(
          moodleModuleId: null,
          activityType: '',
          moodleModuleName: null,
        );
      }).toList();
      return s.copyWith(moodleSectionId: null, activities: activities);
    }).toList();
    _current = _current!.copyWith(sections: sections);
    notifyListeners();
    await _repo.save(_current!);
  }

  // ── Datas de feriado ──────────────────────────────────────────────────────

  List<DateTime> get holidayDates => _current?.holidayDates ?? [];

  Future<void> addHolidayDate(DateTime date) async {
    if (_current == null) return;
    final normalized = DateTime(date.year, date.month, date.day);
    if (_current!.holidayDates.any(
      (d) =>
          d.year == normalized.year &&
          d.month == normalized.month &&
          d.day == normalized.day,
    )) {
      return;
    }
    final updated = [..._current!.holidayDates, normalized]
      ..sort((a, b) => a.compareTo(b));
    _current = _current!.copyWith(holidayDates: updated);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> removeHolidayDate(DateTime date) async {
    if (_current == null) return;
    final updated = _current!.holidayDates
        .where(
          (d) =>
              !(d.year == date.year &&
                  d.month == date.month &&
                  d.day == date.day),
        )
        .toList();
    _current = _current!.copyWith(holidayDates: updated);
    await _repo.save(_current!);
    notifyListeners();
  }

  /// Extrai todas as datas no formato DD/MM/YYYY de um texto resolvido.
  static final _dateInTextPattern = RegExp(r'(\d{2})/(\d{2})/(\d{4})');

  List<DateTime> _extractDatesFromText(String text) {
    final dates = <DateTime>[];
    for (final m in _dateInTextPattern.allMatches(text)) {
      final day = int.tryParse(m.group(1)!);
      final month = int.tryParse(m.group(2)!);
      final year = int.tryParse(m.group(3)!);
      if (day != null &&
          month != null &&
          year != null &&
          month >= 1 &&
          month <= 12 &&
          day >= 1 &&
          day <= 31) {
        try {
          dates.add(DateTime(year, month, day));
        } catch (_) {}
      }
    }
    return dates;
  }

  /// Verifica se o nome resolvido de uma atividade contém alguma data de feriado.
  bool activityMatchesHoliday(String resolvedName) {
    if (_current == null || _current!.holidayDates.isEmpty) return false;
    for (final date in _current!.holidayDates) {
      final dd = date.day.toString().padLeft(2, '0');
      final mm = date.month.toString().padLeft(2, '0');
      final yyyy = date.year.toString();
      // Busca no formato DD/MM/YYYY ou DD/MM
      if (resolvedName.contains('$dd/$mm/$yyyy') ||
          resolvedName.contains('$dd/$mm')) {
        return true;
      }
    }
    return false;
  }

  // ── Datas de troca de dia da semana ──────────────────────────────────────

  Map<DateTime, int> get daySwapDates => _current?.daySwapDates ?? {};

  Future<void> addDaySwapDate(DateTime date, int effectiveWeekday) async {
    if (_current == null) return;
    final normalized = DateTime(date.year, date.month, date.day);
    final updated = Map<DateTime, int>.from(_current!.daySwapDates);
    updated[normalized] = effectiveWeekday;
    _current = _current!.copyWith(daySwapDates: updated);
    await _repo.save(_current!);
    notifyListeners();
  }

  Future<void> removeDaySwapDate(DateTime date) async {
    if (_current == null) return;
    final normalized = DateTime(date.year, date.month, date.day);
    final updated = Map<DateTime, int>.from(_current!.daySwapDates);
    updated.remove(normalized);
    _current = _current!.copyWith(daySwapDates: updated);
    await _repo.save(_current!);
    notifyListeners();
  }

  /// Retorna o dia da semana efetivo de uma data, considerando daySwapDates.
  int effectiveWeekday(DateTime date) {
    if (_current == null) return date.weekday;
    final normalized = DateTime(date.year, date.month, date.day);
    for (final entry in _current!.daySwapDates.entries) {
      if (entry.key.year == normalized.year &&
          entry.key.month == normalized.month &&
          entry.key.day == normalized.day) {
        return entry.value;
      }
    }
    return date.weekday;
  }

  /// Verifica se a data de abertura da atividade cai em dia diferente do esperado.
  /// Também verifica datas extraídas do texto resolvido.
  /// Retorna true se há conflito (amarelo).
  bool activityWeekdayMismatch(
    ActivityEntry activity,
    DateTime sectionRefDate, {
    String? resolvedName,
  }) {
    if (activity.expectedWeekday == null) return false;

    // Verificar pela data de abertura
    final openDate = activity.computeOpenDate(sectionRefDate);
    if (openDate != null) {
      final wd = effectiveWeekday(openDate);
      if (wd != activity.expectedWeekday) return true;
    }

    // Verificar por datas no texto resolvido
    if (resolvedName != null) {
      final textDates = _extractDatesFromText(resolvedName);
      for (final date in textDates) {
        final wd = effectiveWeekday(date);
        if (wd != activity.expectedWeekday) return true;
      }
    }

    return false;
  }
}
