import 'package:gestor_ufu/core/utils/macro_resolver.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:intl/intl.dart';

enum WordTableColumn {
  date('Data'),
  modality('Modalidade'),
  classGroup('Turma'),
  taughtSubject('Matéria Lecionada'),
  activities('Atividades'),
  moodleDescription('Descrição Moodle');

  final String label;

  const WordTableColumn(this.label);
}

enum WordTablePreset {
  practice('Prática', 'Prática', 'T'),
  theory('Teórica', 'Teórica', 'T e Q'),
  all('Todas', '', 'T e Q');

  final String label;
  final String modality;
  final String defaultClassGroup;

  const WordTablePreset(this.label, this.modality, this.defaultClassGroup);
}

class WordTableOptions {
  final WordTablePreset preset;
  final Set<WordTableColumn> columns;
  final bool onlyMatchingModality;
  final bool includeActivitiesInSubject;

  const WordTableOptions({
    required this.preset,
    required this.columns,
    this.onlyMatchingModality = true,
    this.includeActivitiesInSubject = false,
  });
}

class WordTableRow {
  final DateTime date;
  final String modality;
  final String classGroup;
  final String taughtSubject;
  final String activities;
  final String moodleDescription;
  final bool isSpecial;

  const WordTableRow({
    required this.date,
    required this.modality,
    required this.classGroup,
    required this.taughtSubject,
    required this.activities,
    required this.moodleDescription,
    required this.isSpecial,
  });
}

class WordTableGenerator {
  static final _dateFormat = DateFormat('dd/MM/yyyy');
  static final _datePattern = RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{4})\b');

  static List<WordTableRow> buildRows(
    CourseConfig config,
    WordTableOptions options,
  ) {
    final rows = <WordTableRow>[];
    for (final section in config.sections) {
      final resolvedSectionName = _cleanText(
        MacroResolver.resolve(
          section.name,
          config.semesterStartDate,
          section.date,
        ),
      );
      final resolvedDescription = _cleanText(
        MacroResolver.resolve(
          section.moodleDescription ?? '',
          config.semesterStartDate,
          section.date,
        ),
      );
      final activityInfos = section.activities.map((activity) {
        final explicitOpenDate =
            activity.computeOpenDate(section.date) ?? activity.openDate;
        final closeDate =
            activity.computeCloseDate(section.date) ?? activity.closeDate;
        final provisionalName = _cleanText(
          MacroResolver.resolve(
            activity.name,
            config.semesterStartDate,
            explicitOpenDate ?? section.date,
            explicitOpenDate,
            closeDate,
          ),
        );
        final activityDate =
            explicitOpenDate ??
            _extractActivityDate(provisionalName) ??
            section.date;
        final name = explicitOpenDate == null
            ? provisionalName
            : _cleanText(
                MacroResolver.resolve(
                  activity.name,
                  config.semesterStartDate,
                  explicitOpenDate,
                  explicitOpenDate,
                  closeDate,
                ),
              );
        return (
          date: _dateOnly(activityDate),
          name: name,
          modality: activity.modality,
        );
      }).toList();

      final hasExplicitModality = activityInfos.any(
        (activity) =>
            activity.modality != null && activity.modality!.isNotEmpty,
      );
      final selectedActivityInfos =
          options.onlyMatchingModality &&
              options.preset != WordTablePreset.all &&
              hasExplicitModality
          ? activityInfos
                .where(
                  (activity) =>
                      activity.modality != null &&
                      _sameLabel(activity.modality!, options.preset.modality),
                )
                .toList()
          : activityInfos;

      if (hasExplicitModality && selectedActivityInfos.isEmpty) {
        continue;
      }

      if (selectedActivityInfos.isEmpty) {
        _addRow(
          rows,
          options,
          date: section.date,
          sectionName: resolvedSectionName,
          description: resolvedDescription,
          activityInfos: const [],
        );
        continue;
      }

      final activitiesByDate =
          <DateTime, List<({String name, String? modality})>>{};
      for (final activity in selectedActivityInfos) {
        activitiesByDate.putIfAbsent(activity.date, () => []).add((
          name: activity.name,
          modality: activity.modality,
        ));
      }

      for (final entry in activitiesByDate.entries) {
        _addRow(
          rows,
          options,
          date: entry.key,
          sectionName: resolvedSectionName,
          description: resolvedDescription,
          activityInfos: entry.value,
        );
      }
    }
    rows.sort((a, b) => a.date.compareTo(b.date));
    return rows;
  }

  static void _addRow(
    List<WordTableRow> rows,
    WordTableOptions options, {
    required DateTime date,
    required String sectionName,
    required String description,
    required List<({String name, String? modality})> activityInfos,
  }) {
    final resolvedActivities = activityInfos
        .map((activity) => activity.name)
        .toList();

    final text = _joinText([sectionName, description, ...resolvedActivities]);
    String? explicitModality;
    for (final activity in activityInfos) {
      final value = activity.modality;
      if (value != null && value.trim().isNotEmpty) {
        explicitModality = value;
        break;
      }
    }
    final inferredModality =
        explicitModality ?? _inferModality(text) ?? options.preset.modality;

    if (options.onlyMatchingModality &&
        options.preset != WordTablePreset.all &&
        !_sameLabel(inferredModality, options.preset.modality)) {
      return;
    }

    final subjectParts = [
      sectionName,
      if (options.includeActivitiesInSubject) ...resolvedActivities,
    ].where((s) => s.trim().isNotEmpty).toList();

    rows.add(
      WordTableRow(
        date: _dateOnly(date),
        modality: inferredModality.isEmpty
            ? options.preset.modality
            : inferredModality,
        classGroup: _inferClassGroup(text, options.preset.defaultClassGroup),
        taughtSubject: subjectParts.join(' - '),
        activities: resolvedActivities.join(' | '),
        moodleDescription: description,
        isSpecial: _isSpecial(text),
      ),
    );
  }

  static String generateTsv(CourseConfig config, WordTableOptions options) {
    final columns = options.columns.toList();
    final rows = buildRows(config, options);
    final buffer = StringBuffer();
    buffer.writeln(columns.map((c) => c.label).join('\t'));
    for (final row in rows) {
      buffer.writeln(
        columns.map((column) => _cellText(row, column)).join('\t'),
      );
    }
    return buffer.toString();
  }

  static String generateHtml(CourseConfig config, WordTableOptions options) {
    final columns = options.columns.toList();
    final rows = buildRows(config, options);
    final title = '${config.name} - ${options.preset.label}';
    final buffer = StringBuffer()
      ..writeln('<!doctype html>')
      ..writeln('<html><head><meta charset="utf-8">')
      ..writeln('<title>${_escape(title)}</title>')
      ..writeln('<style>')
      ..writeln('body{font-family:Arial,sans-serif;font-size:10pt;}')
      ..writeln('table{border-collapse:collapse;}')
      ..writeln('th,td{border:1px solid #000;padding:2px 5px;}')
      ..writeln('th{font-weight:bold;background:#fff;}')
      ..writeln('.practice td{background:#fff;}')
      ..writeln('.theory td{background:#fff;}')
      ..writeln('.special td{color:#f00;font-weight:bold;}')
      ..writeln(
        '.date,.modality,.classGroup{text-align:center;white-space:nowrap;}',
      )
      ..writeln('</style></head><body>')
      ..writeln('<table>')
      ..writeln('<thead><tr>');
    for (final column in columns) {
      buffer.writeln('<th>${_escape(column.label)}</th>');
    }
    buffer.writeln('</tr></thead><tbody>');
    for (final row in rows) {
      final classes = [
        if (_sameLabel(row.modality, 'Teórica')) 'theory' else 'practice',
        if (row.isSpecial) 'special',
      ].join(' ');
      buffer.writeln('<tr class="$classes">');
      for (final column in columns) {
        buffer.writeln(
          '<td class="${column.name}">${_escape(_cellText(row, column))}</td>',
        );
      }
      buffer.writeln('</tr>');
    }
    buffer.writeln('</tbody></table></body></html>');
    return buffer.toString();
  }

  static String _cellText(WordTableRow row, WordTableColumn column) {
    return switch (column) {
      WordTableColumn.date => _dateFormat.format(row.date),
      WordTableColumn.modality => row.modality,
      WordTableColumn.classGroup => row.classGroup,
      WordTableColumn.taughtSubject => row.taughtSubject,
      WordTableColumn.activities => row.activities,
      WordTableColumn.moodleDescription => row.moodleDescription,
    };
  }

  static String? _inferModality(String text) {
    final normalized = _normalize(text);
    if (normalized.contains('teorica') || normalized.contains('teoria')) {
      return 'Teórica';
    }
    if (normalized.contains('pratica') || normalized.contains('pratico')) {
      return 'Prática';
    }
    return null;
  }

  static String _inferClassGroup(String text, String fallback) {
    final normalized = _normalize(text);
    final hasT = RegExp(r'(^|[^a-z0-9])t([^a-z0-9]|$)').hasMatch(normalized);
    final hasQ = RegExp(r'(^|[^a-z0-9])q([^a-z0-9]|$)').hasMatch(normalized);
    if (hasT && hasQ) return 'T e Q';
    if (hasQ) return 'Q';
    if (hasT) return 'T';
    return fallback;
  }

  static bool _isSpecial(String text) {
    final normalized = _normalize(text);
    return normalized.contains('feriado') ||
        normalized.contains('carnaval') ||
        normalized.contains('recesso') ||
        normalized.contains('prova') ||
        normalized.contains('substitutiva') ||
        normalized.contains('apresentacao');
  }

  static String _joinText(Iterable<String> parts) {
    return parts.where((s) => s.trim().isNotEmpty).join(' ');
  }

  static DateTime _dateOnly(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  static DateTime? _extractActivityDate(String text) {
    final matches = _datePattern.allMatches(text).toList();
    if (matches.isEmpty) return null;

    for (final match in matches) {
      final prefixStart = (match.start - 60).clamp(0, match.start);
      final prefix = _normalize(text.substring(prefixStart, match.start));
      if (prefix.contains('realizar') ||
          prefix.contains('inicia') ||
          prefix.contains('inicio') ||
          prefix.contains('abertura') ||
          prefix.contains('comeca')) {
        return _parseDateMatch(match);
      }
    }

    return _parseDateMatch(matches.first);
  }

  static DateTime? _parseDateMatch(RegExpMatch match) {
    final day = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final year = int.tryParse(match.group(3)!);
    if (day == null || month == null || year == null) return null;
    final date = DateTime(year, month, day);
    if (date.day != day || date.month != month || date.year != year) {
      return null;
    }
    return date;
  }

  static String _cleanText(String value) {
    if (value.trim().isEmpty) return '';
    return _decodeHtmlEntities(value)
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('\u00a0', ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\s*\n\s*'), '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();
  }

  static String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }

  static bool _sameLabel(String a, String b) => _normalize(a) == _normalize(b);

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('ã', 'a')
        .replaceAll('é', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ô', 'o')
        .replaceAll('õ', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c')
        .replaceAll('á', 'a')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('ã', 'a')
        .replaceAll('é', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ô', 'o')
        .replaceAll('õ', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c');
  }

  static String _escape(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }
}
