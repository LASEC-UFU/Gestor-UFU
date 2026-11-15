import 'package:excel/excel.dart';

import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/templates/sheet_template.dart';

/// Modelos de arquivo das importações do módulo (create_template).
List<ModuleTemplate> equivalenciaTemplates() => [
  ModuleTemplate(
    id: 'equivalencia_curriculo',
    description:
        'Equivalência → "Currículos" → importar disciplinas do currículo.',
    build: ({rows, data, options = const {}}) => _curriculo(rows),
  ),
  ModuleTemplate(
    id: 'equivalencia_analise',
    description:
        'Equivalência → "Importar planilha": análise de um aluno (aba '
        'Equivalencia, blocos currículo atual ↔ anterior).',
    build: ({rows, data, options = const {}}) => _analise(rows, options),
  ),
];

(String, List<int>, String) _curriculo(List<List<Object?>>? rows) {
  final excel = Excel.createExcel();
  final sheet = excel['Curriculo'];
  SheetTemplate.rows(sheet, [
    [
      'Código Disciplina',
      'Nome Disciplina',
      'CH Teórica',
      'CH Prática',
      'CH Total',
      'Tipo',
      'Estrutura Curricular',
    ],
    ...?rows,
    if (rows == null) ...[
      ['FEELT31101', 'Cálculo I', 90, 0, 90, 'Obrigatória', 'Núcleo básico'],
      [
        'FEELT31102',
        'Física Experimental I',
        0,
        30,
        30,
        'Obrigatória',
        'Núcleo básico',
      ],
    ],
  ]);
  return (
    'equivalencia_curriculo.xlsx',
    SheetTemplate.encode(excel, 'Curriculo'),
    'Equivalência → "Currículos" → editar/criar currículo → importar '
        'disciplinas (.xlsx). A ordem das colunas não importa; o cabeçalho '
        'precisa estar nas 30 primeiras linhas e ter ao menos o nome da '
        'disciplina.',
  );
}

(String, List<int>, String) _analise(
  List<List<Object?>>? rows,
  Map<String, dynamic> options,
) {
  final excel = Excel.createExcel();
  final sheet = excel['Equivalencia'];
  SheetTemplate.rows(sheet, [
    ['${options['student'] ?? 'NOME DO ALUNO'}'],
    ['${options['student_id'] ?? 'MATRÍCULA'}'],
    [''],
    [''],
    [''],
    [
      'Período',
      'Código (atual)',
      'Disciplina (currículo atual)',
      'CH T',
      'CH P',
      '',
      'Saldo',
      'Código (anterior)',
      'Disciplina cursada (currículo anterior)',
      'CH T',
      'CH P',
    ],
  ]);
  final data =
      rows ??
      [
        [
          '1',
          'FEELT31101',
          'Cálculo I',
          90,
          0,
          '',
          '',
          'GMA001',
          'Cálculo Diferencial e Integral I',
          90,
          0,
        ],
        [
          '2',
          'FEELT31201',
          'Circuitos Elétricos I',
          60,
          30,
          '',
          '',
          'FEE101',
          'Circuitos I',
          60,
          0,
        ],
        [
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          'FEE102',
          'Laboratório de Circuitos',
          0,
          30,
        ],
      ];
  SheetTemplate.rows(sheet, data);
  // Linhas que formam um mesmo bloco: mescla a coluna G (Saldo).
  final groups =
      (options['blocks'] as List?)?.whereType<List>().toList() ??
      (rows == null
          ? [
              [2, 3],
            ]
          : const <List>[]);
  for (final group in groups) {
    if (group.length < 2) continue;
    final first = (group.first as num).toInt();
    final last = (group.last as num).toInt();
    // Dados começam na linha 7 (índice 6); first/last são 1 = 1ª linha.
    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: 5 + first),
      CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: 5 + last),
    );
  }
  return (
    'equivalencia_analise.xlsx',
    SheetTemplate.encode(excel, 'Equivalencia'),
    'Equivalência → "Importar planilha" (com um currículo atual '
        'selecionado). A1 = aluno, A2 = matrícula; dados a partir da linha '
        '7. Linhas com a coluna G (Saldo) mesclada formam um bloco.',
  );
}
