import 'package:excel/excel.dart';
import 'package:gestor_ufu/core/utils/date_calculator.dart';

/// Gera uma planilha-template de exemplo para importação.
class TemplateGenerator {
  static List<int> generateTemplate() {
    final excel = Excel.createExcel();
    final sheet = excel['Disciplina 2026_1'];

    // Row 0: vazia
    sheet.appendRow([TextCellValue('')]);

    // Row 1: Inicio do Semestre
    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('Inicio do Semestre:'),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(DateCalculator.toExcelSerial(DateTime(2026, 2, 16))),
    ]);

    // Row 2: vazia
    sheet.appendRow([TextCellValue('')]);

    // Row 3: Dimensão
    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('Dimensão Teórica e Prática'),
    ]);

    // Row 4: vazia
    sheet.appendRow([TextCellValue('')]);

    // Row 5: Headers
    sheet.appendRow([
      TextCellValue('Semana'),
      TextCellValue('Data'),
      TextCellValue('Modalidade'),
      TextCellValue('Turma'),
      TextCellValue('Matéria Lecionada'),
      TextCellValue(''),
      TextCellValue('Descrição Moodle'),
    ]);

    // Dados de exemplo - 3 semanas
    final baseDate = DateTime(2026, 2, 16);

    // Semana 1
    _addRow(
        sheet,
        '1',
        baseDate,
        'Prática',
        'T',
        'Aula 01 - Introdução ao Curso',
        'SEMANA 01 (Inicia: 16/02/2026 e Termina: 23/02/2026).');
    _addRow(
        sheet,
        '',
        baseDate.add(const Duration(days: 1)),
        'Teórica',
        'T e Q',
        'Plano de Ensino e Normas',
        'Apresentação do Plano de Ensino (Realizar-se-á: 17/02/2026).');
    _addRow(
        sheet,
        '',
        baseDate.add(const Duration(days: 2)),
        'Teórica',
        'T e Q',
        'Teoria 01 - Conceitos Básicos',
        'AA - Questionário sobre Conceitos (inicia: 18/02/2026 e termina: 25/02/2026).');

    // Semana 2
    _addRow(
        sheet,
        '2',
        baseDate.add(const Duration(days: 7)),
        'Prática',
        'T',
        'Prática 01 - Exercícios Guiados',
        'SEMANA 02 (Inicia: 23/02/2026 e Termina: 02/03/2026).');
    _addRow(
        sheet,
        '',
        baseDate.add(const Duration(days: 8)),
        'Teórica',
        'T e Q',
        'Teoria 02 - Aprofundamento',
        'AT - Avaliação Teórica 01 (Realizar-se-á: 24/02/2026).');

    // Semana 3
    _addRow(
        sheet,
        '3',
        baseDate.add(const Duration(days: 14)),
        'Prática',
        'Q',
        'Prática 02 - Projeto Integrador',
        'SEMANA 03 (Inicia: 02/03/2026 e Termina: 09/03/2026).');
    _addRow(
        sheet,
        '',
        baseDate.add(const Duration(days: 15)),
        'Teórica',
        'T e Q',
        'Teoria 03 - Revisão',
        'AP - Entrega do Projeto (Realizar-se-á: 03/03/2026).');

    // Remover sheet padrão
    if (excel.tables.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    return excel.encode()!;
  }

  static void _addRow(Sheet sheet, String semana, DateTime date,
      String modalidade, String turma, String materia, String descMoodle) {
    sheet.appendRow([
      TextCellValue(semana),
      DoubleCellValue(DateCalculator.toExcelSerial(date)),
      TextCellValue(modalidade),
      TextCellValue(turma),
      TextCellValue(materia),
      TextCellValue(''),
      TextCellValue(descMoodle),
    ]);
  }
}
