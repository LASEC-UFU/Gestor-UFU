import 'package:excel/excel.dart' hide Border;
import 'package:intl/intl.dart';

import 'package:gestor_ufu/core/utils/text_encoding.dart';

class DiarioValidation {
  const DiarioValidation(this.valid, this.errors);
  final Map<String, String> valid;
  final Map<String, String> errors;
}

class DiarioImport extends DiarioValidation {
  const DiarioImport(
    super.valid,
    super.errors,
    this.skipped,
    this.duplicates, {
    this.usedDefaultColumns = false,
  });
  final int skipped, duplicates;

  /// Cabeçalho não encontrado: usou as colunas A (data), B (modalidade) e D
  /// (conteúdo).
  final bool usedDefaultColumns;
}

/// Lançamentos do diário: chaves "DD/MM/AAAA -T|-P", validação e leitura da
/// planilha (formato documentado na skill do módulo).
class DiarioLancamentos {
  const DiarioLancamentos._();

  static DiarioImport parseWorksheet(Sheet sheet) {
    final rows = sheet.rows;
    final int? headerIndex = _findHeaderRow(rows);
    final header = headerIndex == null
        ? const {'data': 0, 'modality': 1, 'content': 3}
        : _columnMap(rows[headerIndex]);
    final imported = <String, String>{};
    final errors = <String, String>{};
    var skipped = 0;
    var duplicates = 0;
    for (
      var rowIndex = (headerIndex ?? 0) + 1;
      rowIndex < rows.length;
      rowIndex++
    ) {
      final row = rows[rowIndex];
      final date = _parseWorksheetDate(_cell(row, header['data']!), rows);
      final modality = _cellText(_cell(row, header['modality']!)).toLowerCase();
      final content = _cellText(_cell(row, header['content']!)).trim();
      final suffix = stripAccents(modality).contains('teor')
          ? 'T'
          : stripAccents(modality).contains('prat')
          ? 'P'
          : null;
      if (date == null || suffix == null || content.isEmpty) {
        if (modality.isNotEmpty || content.isNotEmpty) skipped++;
        continue;
      }
      final key = '${formatDate(date)} -$suffix';
      if (imported.containsKey(key)) duplicates++;
      imported[key] = content;
    }
    final validated = validate(imported);
    errors.addAll(validated.errors);
    return DiarioImport(
      validated.valid,
      errors,
      skipped,
      duplicates,
      usedDefaultColumns: headerIndex == null,
    );
  }

  static int? _findHeaderRow(List<List<Data?>> rows) {
    for (var i = 0; i < rows.length && i < 10; i++) {
      final map = _columnMap(rows[i]);
      if (map.containsKey('data') &&
          map.containsKey('modality') &&
          map.containsKey('content')) {
        return i;
      }
    }
    return null;
  }

  static Map<String, int> _columnMap(List<Data?> row) {
    final map = <String, int>{};
    for (var i = 0; i < row.length; i++) {
      final text = stripAccents(
        _cellText(row[i]).toLowerCase().trim(),
      ).replaceAll(RegExp(r'\s+'), ' ');
      if (text == 'data' || text == 'dia') map['data'] = i;
      if (text.startsWith('modalidade')) map['modality'] = i;
      if ({
        'materia lecionada',
        'materia',
        'conteudo',
        'conteudo lecionado',
        'descricao',
      }.contains(text)) {
        map['content'] = i;
      }
    }
    return map;
  }

  static Data? _cell(List<Data?> row, int column) =>
      column < row.length ? row[column] : null;

  static String _cellText(Data? cell) {
    final value = cell?.value;
    if (value == null) return '';
    if (value is TextCellValue) return value.value.text ?? '';
    if (value is FormulaCellValue) return value.formula;
    return value.toString();
  }

  static DateTime? _parseExcelDate(Data? cell) {
    final value = cell?.value;
    if (value is DateCellValue) return value.asDateTimeLocal();
    if (value is DateTimeCellValue) return value.asDateTimeLocal();
    if (value is IntCellValue) {
      return DateTime(1899, 12, 30).add(Duration(days: value.value));
    }
    if (value is DoubleCellValue) {
      return DateTime(1899, 12, 30).add(Duration(days: value.value.floor()));
    }
    final text = _cellText(cell).trim();
    final match = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(text);
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  static DateTime? _parseWorksheetDate(
    Data? cell,
    List<List<Data?>> rows, [
    Set<String>? references,
  ]) {
    final value = cell?.value;
    if (value is! FormulaCellValue) return _parseExcelDate(cell);

    final formula = value.formula
        .trim()
        .replaceFirst(RegExp(r'^='), '')
        .replaceAll(r'$', '')
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase();
    final match = RegExp(
      r'^([A-Z]{1,3})(\d+)(?:([+-])(\d+(?:\.\d+)?))?$',
    ).firstMatch(formula);
    if (match == null) return null;

    var column = 0;
    for (final character in match.group(1)!.codeUnits) {
      column = column * 26 + character - 64;
    }
    final rowIndex = int.parse(match.group(2)!) - 1;
    final columnIndex = column - 1;
    if (rowIndex < 0 || rowIndex >= rows.length || columnIndex < 0) {
      return null;
    }

    final address = '${match.group(1)}${match.group(2)}';
    final visited = references ?? <String>{};
    if (!visited.add(address)) return null;
    final referencedRows = rows[rowIndex];
    final baseDate = _parseWorksheetDate(
      _cell(referencedRows, columnIndex),
      rows,
      visited,
    );
    visited.remove(address);
    if (baseDate == null) return null;

    final offset = double.tryParse(match.group(4) ?? '0');
    if (offset == null) return null;
    final signedOffset = match.group(3) == '-' ? -offset : offset;
    return baseDate.add(
      Duration(
        microseconds: (signedOffset * Duration.microsecondsPerDay).round(),
      ),
    );
  }

  static DiarioValidation validate(dynamic raw) {
    if (raw is! Map) {
      return const DiarioValidation({}, {
        '__root__':
            'O JSON precisa ser um objeto {"DD/MM/AAAA -P": "conteúdo"}.',
      });
    }
    final valid = <String, String>{};
    final errors = <String, String>{};
    for (final entry in raw.entries) {
      final originalKey = '${entry.key}';
      if (entry.value is! String) {
        errors[originalKey] = 'O conteúdo precisa ser texto.';
        continue;
      }
      final normalized = normalizeKey(originalKey);
      if (normalized == null) {
        errors[originalKey] =
            'Use uma data válida no formato DD/MM/AAAA -P (ou -T).';
      } else if (valid.containsKey(normalized)) {
        errors[originalKey] =
            'A chave duplicou após a normalização: $normalized.';
      } else {
        valid[normalized] = entry.value as String;
      }
    }
    return DiarioValidation(valid, errors);
  }

  static String? normalizeKey(String key) {
    final normalized = key
        .replaceAll(RegExp('[\\u2013\\u2014\\u2212]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final match = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{2,4})(?:\s*-\s*(.*))?$',
    ).firstMatch(normalized);
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    final suffix = (match.group(4) ?? '').trim();
    return '${formatDate(date)} -${suffix.isEmpty ? 'P' : suffix}';
  }

  static String stripAccents(String value) => repairMojibake(value)
      .toLowerCase()
      .replaceAll(RegExp(r'[\u00e1\u00e0\u00e2\u00e3\u00e4]'), 'a')
      .replaceAll(RegExp(r'[\u00e9\u00e8\u00ea\u00eb]'), 'e')
      .replaceAll(RegExp(r'[\u00ed\u00ec\u00ee\u00ef]'), 'i')
      .replaceAll(RegExp(r'[\u00f3\u00f2\u00f4\u00f5\u00f6]'), 'o')
      .replaceAll(RegExp(r'[\u00fa\u00f9\u00fb\u00fc]'), 'u')
      .replaceAll('\u00e7', 'c');

  static String formatDate(DateTime date) =>
      DateFormat('dd/MM/yyyy').format(date);

  static Map<String, String> sortMap(Map<String, String> map) {
    final entries = map.entries.toList()
      ..sort((a, b) {
        final aDate = dateFromKey(a.key);
        final bDate = dateFromKey(b.key);
        if (aDate == null) return bDate == null ? a.key.compareTo(b.key) : 1;
        if (bDate == null) return -1;
        final cmp = aDate.compareTo(bDate);
        return cmp == 0 ? a.key.compareTo(b.key) : cmp;
      });
    return Map.fromEntries(entries);
  }

  static DateTime? dateFromKey(String key) {
    final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})\s*-').firstMatch(key);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(3)!),
      int.parse(match.group(2)!),
      int.parse(match.group(1)!),
    );
  }
}
