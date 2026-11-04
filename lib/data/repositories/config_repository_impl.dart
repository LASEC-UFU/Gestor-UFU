import 'dart:io';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:uuid/uuid.dart';
import 'package:gestor_ufu/core/utils/date_calculator.dart';
import 'package:gestor_ufu/core/utils/macro_resolver.dart';
import 'package:gestor_ufu/data/datasources/local_datasource.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_config_snapshot.dart';
import 'package:gestor_ufu/domain/repositories/i_config_repository.dart';

/// Padrão para referência de célula com operação: E2+3, B7+1, B10-5
final _formulaRefPattern = RegExp(r'^([A-Z]+)(\d+)([+-])(\d+)$');

/// Padrão para referência simples de célula: B7, E2
final _simpleCellRef = RegExp(r'^([A-Z]+)(\d+)$');

class ConfigRepositoryImpl implements IConfigRepository {
  final LocalDatasource _local;
  final _uuid = const Uuid();

  ConfigRepositoryImpl(this._local);

  @override
  Future<List<CourseConfig>> getAll() => _local.getAll();

  @override
  Future<CourseConfig?> getById(String id) => _local.getById(id);

  @override
  Future<void> save(CourseConfig config) => _local.save(config);

  @override
  Future<void> delete(String id) => _local.delete(id);

  @override
  Future<List<MoodleConfigSnapshot>> getSnapshots({String? configId}) =>
      _local.getSnapshots(configId: configId);

  @override
  Future<void> createSnapshot(String configId, {required String label}) =>
      _local.createSnapshot(configId, label: label);

  @override
  Future<void> restoreSnapshot(String configId, String snapshotId) =>
      _local.restoreSnapshot(configId, snapshotId);

  @override
  Future<CourseConfig> importFromSpreadsheet(
    String filePath, {
    String? replaceId,
  }) async {
    final configs = parseSpreadsheet(filePath);
    return _saveImportedConfigs(configs, replaceId: replaceId);
  }

  @override
  Future<CourseConfig> importFromSpreadsheetBytes(
    Uint8List bytes, {
    String? replaceId,
  }) async {
    final configs = parseSpreadsheetBytes(bytes);
    return _saveImportedConfigs(configs, replaceId: replaceId);
  }

  Future<CourseConfig> _saveImportedConfigs(
    List<CourseConfig> configs, {
    String? replaceId,
  }) async {
    if (configs.isEmpty) {
      throw Exception('Nenhuma configuração válida encontrada na planilha.');
    }

    for (int i = 0; i < configs.length; i++) {
      var config = configs[i];
      // Se replaceId fornecido, substituir a config existente (manter o id)
      if (i == 0 && replaceId != null) {
        config = CourseConfig(
          id: replaceId,
          name: config.name,
          moodleCourseId: config.moodleCourseId,
          moodleCourseName: config.moodleCourseName,
          semesterStartDate: config.semesterStartDate,
          createdAt: config.createdAt,
          updatedAt: DateTime.now(),
          sections: config.sections,
        );
      }
      await _local.save(config);
    }
    return configs.first;
  }

  /// Parseia a planilha e retorna as configs sem salvar.
  List<CourseConfig> parseSpreadsheet(String filePath) {
    if (filePath.toLowerCase().endsWith('.xls') &&
        !filePath.toLowerCase().endsWith('.xlsx')) {
      throw Exception(
        'Formato .xls não é suportado. '
        'Abra o arquivo no Excel ou LibreOffice e salve como .xlsx.',
      );
    }

    final bytes = File(filePath).readAsBytesSync();
    return _parseExcelBytes(bytes);
  }

  @override
  List<CourseConfig> parseSpreadsheetBytes(Uint8List bytes) {
    return _parseExcelBytes(bytes);
  }

  List<CourseConfig> _parseExcelBytes(List<int> bytes) {
    final excel = Excel.decodeBytes(bytes);
    final configs = <CourseConfig>[];
    final holidayDates = _parseHolidayDates(excel);
    final daySwapDates = _parseDaySwapDates(excel);

    for (final sheetName in excel.tables.keys) {
      if (sheetName == '_Datas Especiais' || sheetName == '_Trocas de Dia') {
        continue;
      }
      final sheet = excel.tables[sheetName]!;
      final rows = sheet.rows;
      if (rows.isEmpty) continue;

      final config = _parseSheet(
        sheetName,
        rows,
        holidayDates: holidayDates,
        daySwapDates: daySwapDates,
      );
      if (config != null) configs.add(config);
    }

    return configs;
  }

  // ── Extração de valores de CellValue ─────────────────────────────────────

  /// Converte índice de coluna (0-based) para letra Excel (A, B, ... Z).
  String _colLetter(int c) => String.fromCharCode(65 + c);

  /// Referência de célula Excel (ex: "B7") - row é 0-based internamente.
  String _cellRef(int row, int col) => '${_colLetter(col)}${row + 1}';

  /// Extrai texto de um CellValue. Para FormulaCellValue, usa o campo formula
  /// que contém o valor cacheado (para fórmulas de texto) ou a fórmula.
  String _cellText(CellValue? value) {
    if (value == null) return '';
    if (value is FormulaCellValue) return value.formula.trim();
    return value.toString().trim();
  }

  String _normalizedText(String text) {
    return text
        .trim()
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
        .replaceAll('ü', 'u')
        .replaceAll('ç', 'c');
  }

  int? _parseIntText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final direct = int.tryParse(trimmed);
    if (direct != null) return direct;
    final asDouble = double.tryParse(trimmed.replaceAll(',', '.'));
    if (asDouble == null) return null;
    return asDouble.round();
  }

  /// Tenta resolver o valor numérico de um CellValue, usando o cache de
  /// valores já resolvidos para avaliar fórmulas simples.
  double? _resolveNumeric(CellValue? value, Map<String, double> cache) {
    if (value == null) return null;
    if (value is IntCellValue) return value.value.toDouble();
    if (value is DoubleCellValue) return value.value;
    if (value is DateCellValue) {
      return DateCalculator.toExcelSerial(
        DateTime(value.year, value.month, value.day),
      );
    }
    if (value is FormulaCellValue) {
      final formula = value.formula.trim();
      if (formula.isEmpty) return null;

      // Tentar como número puro
      final num = double.tryParse(formula.replaceAll(',', '.'));
      if (num != null) return num;

      // Tentar referência + operação: E2+3, B7+1
      final match = _formulaRefPattern.firstMatch(formula);
      if (match != null) {
        final ref = '${match.group(1)}${match.group(2)}';
        final op = match.group(3);
        final offset = int.parse(match.group(4)!);
        final refVal = cache[ref];
        if (refVal != null) {
          return op == '+' ? refVal + offset : refVal - offset;
        }
        return null;
      }

      // Tentar referência simples: B7
      final simple = _simpleCellRef.firstMatch(formula);
      if (simple != null) {
        return cache['${simple.group(1)}${simple.group(2)}'];
      }
      return null;
    }
    return double.tryParse(value.toString().replaceAll(',', '.'));
  }

  // ── Parsing de Sheet ─────────────────────────────────────────────────────

  /// Parseia uma sheet e retorna um CourseConfig, ou null se não reconhecida.
  CourseConfig? _parseSheet(
    String sheetName,
    List<List<Data?>> rawRows, {
    List<DateTime> holidayDates = const [],
    Map<DateTime, int> daySwapDates = const {},
  }) {
    if (rawRows.isEmpty) return null;

    // Cache de valores numéricos resolvidos, indexado por referência Excel
    final cache = <String, double>{};
    DateTime? semesterStart;

    // 1ª passada: cachear valores diretos (Int, Double, Date) e achar semestre
    for (int r = 0; r < rawRows.length; r++) {
      final row = rawRows[r];
      for (int c = 0; c < row.length; c++) {
        final val = row[c]?.value;
        if (val == null) continue;

        if (val is IntCellValue) {
          cache[_cellRef(r, c)] = val.value.toDouble();
        } else if (val is DoubleCellValue) {
          cache[_cellRef(r, c)] = val.value;
        } else if (val is DateCellValue) {
          final serial = DateCalculator.toExcelSerial(
            DateTime(val.year, val.month, val.day),
          );
          cache[_cellRef(r, c)] = serial;
        }

        final text = _normalizedText(_cellText(val));
        if (text.contains('inicio do semestre')) {
          for (int nc = c + 1; nc < row.length; nc++) {
            final dateVal = row[nc]?.value;
            if (dateVal is DateCellValue) {
              semesterStart = DateTime(
                dateVal.year,
                dateVal.month,
                dateVal.day,
              );
              cache[_cellRef(r, nc)] = DateCalculator.toExcelSerial(
                semesterStart,
              );
              break;
            }
            final numVal = _resolveNumeric(dateVal, cache);
            if (numVal != null && numVal > 40000) {
              semesterStart = DateCalculator.fromExcelSerial(numVal);
              cache[_cellRef(r, nc)] = numVal;
              break;
            }
          }
        }
      }
    }

    semesterStart ??= DateTime.now();

    // Encontrar row de header: Ordem | Dias Início | ...
    int? headerRow;
    for (int r = 0; r < rawRows.length; r++) {
      final row = rawRows[r];
      final texts = row
          .map((c) => _normalizedText(_cellText(c?.value)))
          .toList();
      final joined = texts.join(' ');
      if (joined.contains('ordem') && joined.contains('tipo')) {
        headerRow = r;
        break;
      }
    }

    if (headerRow == null) return null;

    // Mapear colunas pelo header
    final hdrRow = rawRows[headerRow];
    final hdrTexts = hdrRow
        .map((c) => _normalizedText(_cellText(c?.value)))
        .toList();

    int? colOrdem,
        colDiasInicio,
        colDiasTermino,
        colHoraInicio,
        colHoraTermino,
        colNome,
        colTipo,
        colModalidade,
        colVisivel,
        colDesc,
        colMoodleId,
        colMoodleModuleName,
        colExpectedWeekday;
    for (int c = 0; c < hdrTexts.length; c++) {
      final h = hdrTexts[c].trim();
      if (h == 'ordem') colOrdem = c;
      if (h.contains('dias') && h.contains('inicio')) {
        colDiasInicio = c;
      }
      if (h.contains('dias') && h.contains('termino')) {
        colDiasTermino = c;
      }
      if (h.contains('hora') && h.contains('inicio')) {
        colHoraInicio = c;
      }
      if (h.contains('hora') && h.contains('termino')) {
        colHoraTermino = c;
      }
      if (h == 'nome') colNome = c;
      if (h == 'tipo') colTipo = c;
      if (h == 'modalidade') colModalidade = c;
      if (h.contains('visivel')) colVisivel = c;
      if (h.contains('descricao')) colDesc = c;
      if (h.contains('moodle id')) colMoodleId = c;
      if (h.contains('moodle module name')) colMoodleModuleName = c;
      if (h.contains('dia semana esperado')) colExpectedWeekday = c;
    }

    if (colNome == null || colTipo == null || colDiasInicio == null) {
      return null;
    }

    // Procurar Disciplina e Moodle Course ID nas linhas acima do header
    int? moodleCourseId;
    String? moodleCourseName;
    for (int r = 0; r < headerRow; r++) {
      final row = rawRows[r];
      final texts = row.map((c) => _cellText(c?.value)).toList();
      for (int c = 0; c < texts.length; c++) {
        if (_normalizedText(texts[c]).contains('disciplina')) {
          if (c + 1 < texts.length && texts[c + 1].isNotEmpty) {
            moodleCourseName = texts[c + 1];
          }
        }
        if (_normalizedText(texts[c]).contains('moodle course id')) {
          if (c + 1 < texts.length) {
            moodleCourseId = _parseIntText(texts[c + 1]);
          }
        }
      }
    }

    final sections = <SectionEntry>[];
    SectionEntry? currentSection;

    for (int r = headerRow + 1; r < rawRows.length; r++) {
      final row = rawRows[r];
      if (row.every((c) => c == null || _cellText(c.value).isEmpty)) continue;

      String cellAt(int? col) =>
          (col != null && col < row.length) ? _cellText(row[col]?.value) : '';

      final ordem = cellAt(colOrdem);
      final nome = cellAt(colNome);
      final tipo = cellAt(colTipo);
      final modalidade = cellAt(colModalidade);
      final visivel = cellAt(colVisivel);
      final desc = cellAt(colDesc);
      final moodleIdStr = cellAt(colMoodleId);
      final moodleId = _parseIntText(moodleIdStr);
      final moodleModuleName = cellAt(colMoodleModuleName);
      final expectedWeekday = _parseIntText(cellAt(colExpectedWeekday));

      final openStr = cellAt(colDiasInicio);
      final openOffset = _parseIntText(openStr);
      int? closeOffset;
      if (colDiasTermino != null) {
        final closeStr = cellAt(colDiasTermino);
        closeOffset = _parseIntText(closeStr);
      }
      int? openTimeMinutes;
      if (colHoraInicio != null) {
        openTimeMinutes = _parseTimeToMinutes(cellAt(colHoraInicio));
      }
      int? closeTimeMinutes;
      if (colHoraTermino != null) {
        closeTimeMinutes = _parseTimeToMinutes(cellAt(colHoraTermino));
      }

      final normalizedVisibility = _normalizedText(visivel);
      final isHidden =
          normalizedVisibility == 'nao' || normalizedVisibility == 'n';
      final isVisible = !isHidden;
      final activityVisibility = normalizedVisibility == 'stealth'
          ? 2
          : (isHidden ? 0 : 1);

      if (_normalizedText(tipo) == 'secao') {
        final orderIndex = _parseIntText(ordem) ?? (sections.length + 1);
        final offset = openOffset ?? 0;
        final date = semesterStart.add(Duration(days: offset));
        currentSection = SectionEntry(
          id: _uuid.v4(),
          orderIndex: orderIndex,
          name: nome,
          referenceDaysOffset: offset,
          date: date,
          offsetDays: offset,
          moodleSectionId: moodleId,
          visible: isVisible,
          activities: [],
          moodleDescription: desc.isNotEmpty ? desc : null,
        );
        sections.add(currentSection);
      } else if (currentSection != null) {
        final sectionRefDate = semesterStart.add(
          Duration(days: currentSection.referenceDaysOffset),
        );
        final activity = ActivityEntry(
          id: _uuid.v4(),
          name: nome,
          activityType: tipo,
          openOffsetDays: openOffset,
          closeOffsetDays: closeOffset,
          openTimeMinutes: openTimeMinutes,
          closeTimeMinutes: closeTimeMinutes,
          moodleModuleId: moodleId,
          moodleModuleName: moodleModuleName.isNotEmpty
              ? moodleModuleName
              : null,
          modality: modalidade.isNotEmpty ? modalidade : null,
          visibility: activityVisibility,
          expectedWeekday: expectedWeekday,
        );
        final withDates = activity.copyWith(
          openDate: activity.computeOpenDate(sectionRefDate),
          closeDate: activity.computeCloseDate(sectionRefDate),
        );
        _addActivityToSection(sections, currentSection, withDates);
        currentSection = sections.last;
      }
    }

    if (sections.isEmpty) return null;

    // ── Substituir datas hardcoded por macros nos textos ────────────────────
    for (int i = 0; i < sections.length; i++) {
      final section = sections[i];
      final sectionRefDate = semesterStart.add(
        Duration(days: section.referenceDaysOffset),
      );

      final newName = MacroResolver.replaceDatesWithMacros(
        section.name,
        sectionRefDate,
      );
      final newDesc = section.moodleDescription != null
          ? MacroResolver.replaceDatesWithMacros(
              section.moodleDescription!,
              sectionRefDate,
            )
          : null;

      final updatedActivities = section.activities.map((activity) {
        final openDate = activity.computeOpenDate(sectionRefDate);
        final closeDate = activity.computeCloseDate(sectionRefDate);
        final newActName = MacroResolver.replaceDatesWithMacros(
          activity.name,
          sectionRefDate,
          activityOpenDate: openDate,
          activityCloseDate: closeDate,
        );
        return newActName != activity.name
            ? activity.copyWith(name: newActName)
            : activity;
      }).toList();

      sections[i] = section.copyWith(
        name: newName,
        moodleDescription: newDesc,
        activities: updatedActivities,
      );
    }

    final now = DateTime.now();
    return CourseConfig(
      id: _uuid.v4(),
      name: sheetName,
      moodleCourseId: moodleCourseId,
      moodleCourseName: moodleCourseName,
      semesterStartDate: semesterStart,
      createdAt: now,
      updatedAt: now,
      sections: sections,
      holidayDates: holidayDates,
      daySwapDates: daySwapDates,
    );
  }

  /// Adiciona atividade à última seção da lista (atualiza imutável).
  void _addActivityToSection(
    List<SectionEntry> sections,
    SectionEntry section,
    ActivityEntry act,
  ) {
    final idx = sections.indexOf(section);
    if (idx < 0) return;
    sections[idx] = section.copyWith(activities: [...section.activities, act]);
  }

  List<DateTime> _parseHolidayDates(Excel excel) {
    final sheet = excel.tables['_Datas Especiais'];
    if (sheet == null) return const [];
    final dates = <DateTime>[];
    for (final row in sheet.rows.skip(1)) {
      if (row.isEmpty) continue;
      final value = row.first?.value;
      final serial = _resolveNumeric(value, {});
      DateTime? date;
      if (serial != null && serial > 40000) {
        date = DateCalculator.fromExcelSerial(serial);
      } else {
        date = _tryParseDate(_cellText(value));
      }
      if (date != null) {
        dates.add(DateTime(date.year, date.month, date.day));
      }
    }
    return dates;
  }

  Map<DateTime, int> _parseDaySwapDates(Excel excel) {
    final sheet = excel.tables['_Trocas de Dia'];
    if (sheet == null) return const {};
    final swaps = <DateTime, int>{};
    for (final row in sheet.rows.skip(1)) {
      if (row.length < 2) continue;
      final value = row[0]?.value;
      final serial = _resolveNumeric(value, {});
      DateTime? date;
      if (serial != null && serial > 40000) {
        date = DateCalculator.fromExcelSerial(serial);
      } else {
        date = _tryParseDate(_cellText(value));
      }
      final weekday = _parseIntText(_cellText(row[1]?.value));
      if (date != null && weekday != null && weekday >= 1 && weekday <= 7) {
        swaps[DateTime(date.year, date.month, date.day)] = weekday;
      }
    }
    return swaps;
  }

  DateTime? _tryParseDate(String text) {
    final parts = text.trim().split('/');
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return null;
    return DateTime(year, month, day);
  }

  @override
  Future<Uint8List> exportToSpreadsheetBytes(String courseConfigId) async {
    final config = await _local.getById(courseConfigId);
    if (config == null) throw Exception('Configuração não encontrada');

    final excel = Excel.createExcel();
    final sheetName = config.name.length > 31
        ? config.name.substring(0, 31)
        : config.name;
    final sheet = excel[sheetName];

    // Header
    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('Inicio do Semestre:'),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(DateCalculator.toExcelSerial(config.semesterStartDate)),
    ]);
    sheet.appendRow([
      TextCellValue('Disciplina:'),
      TextCellValue(config.moodleCourseName ?? ''),
      TextCellValue(''),
      TextCellValue('Moodle Course ID:'),
      config.moodleCourseId != null
          ? IntCellValue(config.moodleCourseId!)
          : TextCellValue(''),
    ]);
    sheet.appendRow([TextCellValue('')]);
    sheet.appendRow([
      TextCellValue('Ordem'),
      TextCellValue('Dias Início'),
      TextCellValue('Hora Início'),
      TextCellValue('Dias Término'),
      TextCellValue('Hora Término'),
      TextCellValue('Nome'),
      TextCellValue('Tipo'),
      TextCellValue('Modalidade'),
      TextCellValue('Visível'),
      TextCellValue('Descrição Moodle'),
      TextCellValue('Moodle ID'),
      TextCellValue('Moodle Module Name'),
      TextCellValue('Dia Semana Esperado'),
    ]);

    for (final section in config.sections) {
      sheet.appendRow([
        IntCellValue(section.orderIndex),
        IntCellValue(section.referenceDaysOffset),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(section.name),
        TextCellValue('Seção'),
        TextCellValue(''),
        TextCellValue(section.visible ? 'Sim' : 'Não'),
        TextCellValue(section.moodleDescription ?? ''),
        section.moodleSectionId != null
            ? IntCellValue(section.moodleSectionId!)
            : TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
      ]);

      for (final activity in section.activities) {
        sheet.appendRow([
          TextCellValue(''),
          activity.openOffsetDays != null
              ? IntCellValue(activity.openOffsetDays!)
              : TextCellValue(''),
          activity.openTimeMinutes != null
              ? TextCellValue(_minutesToTime(activity.openTimeMinutes!))
              : TextCellValue(''),
          activity.closeOffsetDays != null
              ? IntCellValue(activity.closeOffsetDays!)
              : TextCellValue(''),
          activity.closeTimeMinutes != null
              ? TextCellValue(_minutesToTime(activity.closeTimeMinutes!))
              : TextCellValue(''),
          TextCellValue(activity.name),
          TextCellValue(activity.activityType),
          TextCellValue(activity.modality ?? ''),
          TextCellValue(switch (activity.visibility) {
            0 => 'Não',
            2 => 'Stealth',
            _ => 'Sim',
          }),
          TextCellValue(''),
          activity.moodleModuleId != null
              ? IntCellValue(activity.moodleModuleId!)
              : TextCellValue(''),
          TextCellValue(activity.moodleModuleName ?? ''),
          activity.expectedWeekday != null
              ? IntCellValue(activity.expectedWeekday!)
              : TextCellValue(''),
        ]);
      }
    }

    if (config.holidayDates.isNotEmpty) {
      final holidays = excel['_Datas Especiais'];
      holidays.appendRow([TextCellValue('Data')]);
      for (final date in config.holidayDates) {
        holidays.appendRow([
          DoubleCellValue(DateCalculator.toExcelSerial(date)),
        ]);
      }
    }

    if (config.daySwapDates.isNotEmpty) {
      final swaps = excel['_Trocas de Dia'];
      swaps.appendRow([
        TextCellValue('Data'),
        TextCellValue('Dia Semana Efetivo'),
      ]);
      final entries = config.daySwapDates.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in entries) {
        swaps.appendRow([
          DoubleCellValue(DateCalculator.toExcelSerial(entry.key)),
          IntCellValue(entry.value),
        ]);
      }
    }

    // Remove sheet default se criou outra
    if (excel.tables.containsKey('Sheet1') && sheetName != 'Sheet1') {
      excel.delete('Sheet1');
    }

    final fileBytes = excel.encode()!;
    return Uint8List.fromList(fileBytes);
  }

  /// Converte minutos desde 00:00 para string HH:mm.
  String _minutesToTime(int minutes) {
    final h = (minutes ~/ 60).toString().padLeft(2, '0');
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Parseia string HH:mm para minutos desde 00:00, ou null.
  int? _parseTimeToMinutes(String text) {
    if (text.isEmpty) return null;
    final parts = text.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }
}
