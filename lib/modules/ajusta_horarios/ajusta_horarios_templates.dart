import 'package:excel/excel.dart';

import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/templates/sheet_template.dart';

/// Modelos de arquivo das importações do módulo (create_template).
List<ModuleTemplate> ajustaHorariosTemplates() => [
  ModuleTemplate(
    id: 'ajusta_horarios_bdados',
    description:
        'Ajusta Horários → "Importar base da planilha" (aba BDados): substitui '
        'a base de disciplinas/turmas/horários do período.',
    build: ({rows, data, options = const {}}) => _bdados(rows),
  ),
  ModuleTemplate(
    id: 'ajusta_horarios_banco',
    description:
        'Ajusta Horários → "Importar base da planilha" (aba Banco): '
        'distribuição docente (quem leciona cada turma e as cargas).',
    build: ({rows, data, options = const {}}) => _banco(rows),
  ),
];

(String, List<int>, String) _bdados(List<List<Object?>>? rows) {
  final excel = Excel.createExcel();
  final sheet = excel['BDados'];
  SheetTemplate.rows(sheet, [
    ['Base de disciplinas (dados a partir da linha 3)'],
    [
      'ID',
      'Cursos/Períodos (período,curso;…)',
      'Horários (faixa,dia+1;…)',
      'Código',
      'Sigla',
      'Disciplina',
      'Turma',
      'Docentes (separados por vírgula)',
      'Sala',
      'CH Teórica',
      'CH Prática',
    ],
    ...?rows,
    if (rows == null) ...[
      [
        '',
        '3,1;3,2',
        '1,2;2,2',
        'FEELT31301',
        'CIRC1',
        'Circuitos Elétricos I',
        'A',
        'Maria Silva',
        '1E-102',
        60,
        0,
      ],
      [
        '',
        '3,1',
        '7,4;8,4',
        'FEELT31301',
        'CIRC1',
        'Circuitos Elétricos I',
        'P1',
        'João Souza',
        'Lab 1',
        0,
        30,
      ],
    ],
  ]);
  return (
    'ajusta_horarios_BDados.xlsx',
    SheetTemplate.encode(excel, 'BDados'),
    'Ajusta Horários → "Importar base da planilha". A aba BDados SUBSTITUI '
        'toda a base do período e limpa a distribuição docente.',
  );
}

(String, List<int>, String) _banco(List<List<Object?>>? rows) {
  final excel = Excel.createExcel();
  final sheet = excel['Banco'];
  SheetTemplate.rows(sheet, [
    [
      'Período',
      'Sigla',
      'Disciplina',
      'Turma',
      'Docente',
      'Opção (Sigla Turma)',
      'CH_T',
      'CH_P',
      'CH EAD',
      'CH Extensão',
    ],
    ...?rows,
    if (rows == null) ...[
      [
        '3',
        'CIRC1',
        'Circuitos Elétricos I',
        'A',
        'Maria Silva',
        'CIRC1 A',
        60,
        0,
        0,
        0,
      ],
      [
        '3',
        'CIRC1',
        'Circuitos Elétricos I',
        'P1',
        'João Souza',
        'CIRC1 P1',
        0,
        30,
        0,
        0,
      ],
    ],
  ]);
  return (
    'ajusta_horarios_Banco.xlsx',
    SheetTemplate.encode(excel, 'Banco'),
    'Ajusta Horários → "Importar base da planilha". Se o arquivo tiver a '
        'aba Banco, ela é usada (tem prioridade sobre BDados) e atualiza só '
        'a Distribuição Docente, mantendo as grades.',
  );
}
