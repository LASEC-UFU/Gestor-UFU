import 'package:excel/excel.dart';
import 'package:gestor_ufu/core/utils/date_calculator.dart';

/// Gera a planilha-modelo do Config Moodle no MESMO formato que a importação
/// lê (e que a exportação produz): "Inicio do Semestre:", "Disciplina:",
/// "Moodle Course ID:" e o cabeçalho Ordem | Dias Início | … | Tipo …, além
/// das abas `_Datas Especiais` e `_Trocas de Dia`.
///
/// Usado pelo botão "Baixar Planilha Modelo" e pela ferramenta
/// `create_template` do Agente de IA.
class TemplateGenerator {
  static const headers = [
    'Ordem',
    'Dias Início',
    'Hora Início',
    'Dias Término',
    'Hora Término',
    'Nome',
    'Tipo',
    'Modalidade',
    'Visível',
    'Descrição Moodle',
    'Moodle ID',
    'Moodle Module Name',
    'Dia Semana Esperado',
  ];

  /// Linhas de exemplo: uma seção por semana com atividades teóricas e
  /// práticas, prazos com horário e macros de data.
  static const exampleRows = <List<Object?>>[
    [
      1,
      0,
      '',
      '',
      '',
      'Semana 1 - <DD/MM/YYYY> a <DD/MM/YYYY + 6>',
      'Seção',
      '',
      'Sim',
      'Apresentação da disciplina e do plano de ensino.',
      '',
      '',
      '',
    ],
    [
      '',
      0,
      '',
      '',
      '',
      'Aula 1 - Introdução',
      'Página',
      'Teórica',
      'Sim',
      '',
      '',
      '',
      '',
    ],
    [
      '',
      1,
      '',
      '',
      '',
      'Laboratório 1 - Instrumentação',
      'Página',
      'Prática',
      'Sim',
      '',
      '',
      '',
      2,
    ],
    [
      '',
      2,
      '08:00',
      9,
      '23:59',
      'Lista 1 (entrega até <DD/MM/YYYY>AF)',
      'Tarefa',
      'Teórica',
      'Sim',
      '',
      '',
      '',
      '',
    ],
    [
      2,
      7,
      '',
      '',
      '',
      'Semana 2 - <DD/MM/YYYY> a <DD/MM/YYYY + 6>',
      'Seção',
      '',
      'Sim',
      '',
      '',
      '',
      '',
    ],
    [
      '',
      0,
      '',
      '',
      '',
      'Aula 2 - Circuitos de primeira ordem',
      'Página',
      'Teórica',
      'Sim',
      '',
      '',
      '',
      '',
    ],
    [
      '',
      0,
      '19:00',
      0,
      '21:00',
      'Questionário 1',
      'Questionário',
      'Teórica',
      'Não',
      '',
      '',
      '',
      '',
    ],
    [
      '',
      0,
      '',
      '',
      '',
      'Fórum de dúvidas',
      'Fórum',
      '',
      'Stealth',
      '',
      '',
      '',
      '',
    ],
  ];

  /// [rows] substitui os exemplos (cada linha na ordem de [headers]).
  static List<int> generateTemplate({
    String sheetName = 'Disciplina',
    String courseName = 'NOME DA DISCIPLINA NO MOODLE',
    Object? moodleCourseId,
    DateTime? semesterStart,
    List<List<Object?>>? rows,
    List<DateTime> holidays = const [],
    Map<DateTime, int> daySwaps = const {},
  }) {
    final excel = Excel.createExcel();
    final name = sheetName.length > 31 ? sheetName.substring(0, 31) : sheetName;
    final sheet = excel[name];
    final start = semesterStart ?? DateTime(DateTime.now().year, 3, 9);

    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('Inicio do Semestre:'),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(DateCalculator.toExcelSerial(start)),
    ]);
    sheet.appendRow([
      TextCellValue('Disciplina:'),
      TextCellValue(courseName),
      TextCellValue(''),
      TextCellValue('Moodle Course ID:'),
      _cell(moodleCourseId),
    ]);
    sheet.appendRow([TextCellValue('')]);
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    for (final row in rows ?? exampleRows) {
      sheet.appendRow(row.map(_cell).toList());
    }

    final holidaySheet = excel['_Datas Especiais'];
    holidaySheet.appendRow([TextCellValue('Data')]);
    for (final date in holidays) {
      holidaySheet.appendRow([
        DoubleCellValue(DateCalculator.toExcelSerial(date)),
      ]);
    }
    final swapSheet = excel['_Trocas de Dia'];
    swapSheet.appendRow([
      TextCellValue('Data'),
      TextCellValue('Dia Semana Efetivo'),
    ]);
    for (final entry in daySwaps.entries) {
      swapSheet.appendRow([
        DoubleCellValue(DateCalculator.toExcelSerial(entry.key)),
        IntCellValue(entry.value),
      ]);
    }

    if (excel.tables.containsKey('Sheet1') && name != 'Sheet1') {
      excel.delete('Sheet1');
    }
    return excel.encode()!;
  }

  static CellValue _cell(Object? value) => switch (value) {
    null => TextCellValue(''),
    final int v => IntCellValue(v),
    final num v => DoubleCellValue(v.toDouble()),
    final bool v => BoolCellValue(v),
    final String v when v.isEmpty => TextCellValue(''),
    _ => TextCellValue('$value'),
  };
}
