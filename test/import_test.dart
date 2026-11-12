import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/core/utils/date_calculator.dart';
import 'package:gestor_ufu/data/datasources/local_datasource.dart';
import 'package:gestor_ufu/data/repositories/config_repository_impl.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';

/// Mock datasource que guarda em memória (sem path_provider).
class MockDatasource extends LocalDatasource {
  final _store = <String, CourseConfig>{};

  @override
  Future<List<CourseConfig>> getAll() async => _store.values.toList();

  @override
  Future<CourseConfig?> getById(String id) async => _store[id];

  @override
  Future<void> save(CourseConfig config) async => _store[config.id] = config;

  @override
  Future<void> delete(String id) async => _store.remove(id);
}

Uint8List _workbookBytes({required bool includeActivities}) {
  final excel = Excel.createExcel();
  final sheet = excel['Curso de teste'];
  sheet.appendRow([
    TextCellValue('Inicio do Semestre:'),
    DoubleCellValue(DateCalculator.toExcelSerial(DateTime(2025, 2, 17))),
  ]);
  sheet.appendRow([
    TextCellValue('Disciplina:'),
    TextCellValue('Curso de teste'),
  ]);
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
  ]);

  for (var index = 1; index <= 10; index++) {
    sheet.appendRow([
      IntCellValue(index),
      IntCellValue((index - 1) * 7),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue('Seção $index'),
      TextCellValue('Seção'),
      TextCellValue(''),
      TextCellValue('Sim'),
    ]);
    if (includeActivities && index == 1) {
      sheet.appendRow([
        TextCellValue(''),
        IntCellValue(0),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue('Atividade de teste'),
        TextCellValue('Tarefa'),
        TextCellValue('Teórica'),
        TextCellValue('Sim'),
      ]);
    }
  }

  excel.delete('Sheet1');
  return Uint8List.fromList(excel.encode()!);
}

void main() {
  test('imports an in-memory workbook with sections', () async {
    final repo = ConfigRepositoryImpl(MockDatasource());

    final config = await repo.importFromSpreadsheetBytes(
      _workbookBytes(includeActivities: false),
    );

    expect(config.sections, hasLength(10));
    expect(config.semesterStartDate, DateTime(2025, 2, 17));
    expect(config.sections.first.date, DateTime(2025, 2, 17));
  });

  test('imports activities from an in-memory workbook', () async {
    final repo = ConfigRepositoryImpl(MockDatasource());

    final config = await repo.importFromSpreadsheetBytes(
      _workbookBytes(includeActivities: true),
    );

    expect(config.sections.first.activities, hasLength(1));
  });

  test('reject xls files', () async {
    final repo = ConfigRepositoryImpl(MockDatasource());

    expect(
      () => repo.importFromSpreadsheet('unsupported.xls'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('.xls não é suportado'),
        ),
      ),
    );
  });
}
