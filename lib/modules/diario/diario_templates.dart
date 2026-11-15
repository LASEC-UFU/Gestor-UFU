import 'dart:convert';
import 'package:excel/excel.dart';

import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/templates/sheet_template.dart';

/// Modelos de arquivo das importações do módulo (create_template).
List<ModuleTemplate> diarioTemplates() => [
  ModuleTemplate(
    id: 'diario_planilha',
    description:
        'Preenche Diários → "Importar Excel": colunas Data | Modalidade | '
        'Matéria Lecionada.',
    build: ({rows, data, options = const {}}) => _diarioXlsx(rows),
  ),
  ModuleTemplate(
    id: 'diario_json',
    description:
        'Preenche Diários → carregar JSON: objeto {"DD/MM/AAAA -T": "conteúdo"}.',
    build: ({rows, data, options = const {}}) => _diarioJson(data),
  ),
];

(String, List<int>, String) _diarioXlsx(List<List<Object?>>? rows) {
  final excel = Excel.createExcel();
  final sheet = excel['Diario'];
  SheetTemplate.rows(sheet, [
    ['Data', 'Modalidade', 'Matéria Lecionada'],
    ...?rows,
    if (rows == null) ...[
      [
        '05/03/2026',
        'Teórica',
        'Apresentação da disciplina e do plano de ensino',
      ],
      ['05/03/2026', 'Prática', 'Laboratório 1: instrumentação'],
      ['12/03/2026', 'Teórica', 'Circuitos de primeira ordem'],
    ],
  ]);
  return (
    'diario_modelo.xlsx',
    SheetTemplate.encode(excel, 'Diario'),
    'Preenche Diários → "Importar Excel" → escolher a aba. Mescla com o '
        'rascunho atual (datas iguais são sobrescritas).',
  );
}

(String, List<int>, String) _diarioJson(Object? data) {
  final content =
      data ??
      {
        '05/03/2026 -T': 'Apresentação da disciplina e do plano de ensino',
        '05/03/2026 -P': 'Laboratório 1: instrumentação',
        '12/03/2026 -T': 'Circuitos de primeira ordem',
      };
  return (
    'diario_modelo.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(content)),
    'Preenche Diários → botão de carregar JSON. Substitui o rascunho atual.',
  );
}
