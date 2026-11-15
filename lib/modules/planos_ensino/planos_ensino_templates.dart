import 'dart:convert';

import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Modelos de arquivo das importações do módulo (create_template).
List<ModuleTemplate> planosEnsinoTemplates() => [
  ModuleTemplate(
    id: 'plano_ensino_json',
    description:
        'Planos de Ensino → "Importar backup": lista de planos em JSON.',
    build: ({rows, data, options = const {}}) => _planoJson(data),
  ),
  ModuleTemplate(
    id: 'plano_ensino_cronograma',
    description:
        'Planos de Ensino → editar plano → "Aplicar tabela colada": texto com '
        'colunas separadas por TAB (Data, Modalidade, Matéria Lecionada…).',
    build: ({rows, data, options = const {}}) => _cronograma(rows),
  ),
];

(String, List<int>, String) _planoJson(Object? data) {
  final content =
      data ??
      [
        {
          'id': 'modelo-1',
          'identificacao': {
            'nome': 'Circuitos Elétricos I',
            'unidade_ofertante': 'Faculdade de Engenharia Elétrica',
            'codigo': 'FEELT31201',
            'periodo_serie': '3º',
            'turma': 'A',
            'carga_teorica': '60',
            'carga_pratica': '30',
            'carga_total': '90',
            'natureza': 'Obrigatória',
            'professor': 'Nome do Professor',
            'ano_semestre': '2026/1',
            'observacoes': '',
          },
          'ementa': 'Texto da ementa…',
          'justificativa': '',
          'objetivo_geral': '',
          'objetivos_especificos': '',
          'programa_teorico': '1. Tópico…',
          'programa_pratico': '',
          'metodologia_tecnicas': '',
          'metodologia_recursos': '',
          'metodologia_audiovisuais': '',
          'cronograma_teorico': [
            {'data': '05/03/2026', 'atividade': 'Apresentação da disciplina'},
          ],
          'cronograma_pratico': [
            {'data': '06/03/2026', 'atividade': 'Laboratório 1'},
          ],
          'avaliacao_geral': '',
          'avaliacao_provas': '',
          'horario_atendimento': '',
          'atividade_recuperacao': '',
          'atendimento_especial': '',
          'bibliografia_basica': ['AUTOR. Título. Editora, ano.'],
          'bibliografia_complementar': <String>[],
        },
      ];
  return (
    'planos_ensino.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(content)),
    'Planos de Ensino → "Importar backup". Os planos são mesclados ao '
        'cadastro (mesmo id = substitui).',
  );
}

(String, List<int>, String) _cronograma(List<List<Object?>>? rows) {
  final lines = [
    [
      'Data',
      'Modalidade',
      'Matéria Lecionada',
      'Atividades',
      'Descrição Moodle',
    ],
    ...?rows,
    if (rows == null) ...[
      ['05/03/2026', 'Teórica', 'Apresentação da disciplina', '', ''],
      ['06/03/2026', 'Prática', 'Laboratório 1: instrumentação', '', ''],
      [
        '12/03/2026',
        'Teórica',
        '',
        'T - Prova 1 | P - Relatório 1',
        'Quanto às provas: …',
      ],
    ],
  ];
  final text = lines
      .map((row) => row.map((cell) => '${cell ?? ''}').join('\t'))
      .join('\r\n');
  return (
    'cronograma_plano_ensino.txt',
    utf8.encode(text),
    'Planos de Ensino → editar plano → "Aplicar tabela colada": copie o '
        'conteúdo do arquivo (Ctrl+A, Ctrl+C) e cole no campo.',
  );
}
