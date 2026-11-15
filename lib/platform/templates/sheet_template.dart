import 'dart:convert';

import 'package:excel/excel.dart';

/// Ajudantes para os modelos de arquivo dos módulos (`ModuleTemplate`).
class SheetTemplate {
  static CellValue cell(Object? value) => switch (value) {
    null => TextCellValue(''),
    final int v => IntCellValue(v),
    final double v => DoubleCellValue(v),
    final bool v => BoolCellValue(v),
    _ => TextCellValue('$value'),
  };

  static void rows(Sheet sheet, Iterable<List<Object?>> rows) {
    for (final row in rows) {
      sheet.appendRow(row.map(cell).toList());
    }
  }

  /// Bytes do .xlsx sem a aba padrão "Sheet1" (a menos que seja [keep]).
  static List<int> encode(Excel excel, String keep) {
    if (excel.tables.containsKey('Sheet1') && keep != 'Sheet1') {
      excel.delete('Sheet1');
    }
    return excel.encode()!;
  }

  /// Planilha de uma aba [sheetName] com [content].
  static List<int> xlsx(String sheetName, Iterable<List<Object?>> content) {
    final excel = Excel.createExcel();
    rows(excel[sheetName], content);
    return encode(excel, sheetName);
  }

  static List<int> json(Object? content) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(content));
}
