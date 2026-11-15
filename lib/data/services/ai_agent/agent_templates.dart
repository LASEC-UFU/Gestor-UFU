import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/template_generator.dart';

/// Modelos de arquivo aceitos pelas importações do Gestor UFU. O agente usa a
/// ferramenta `create_template` para entregar ao usuário um arquivo no
/// formato exato que cada tela importa — com exemplos ou já com os dados que
/// ele montou a partir do que o usuário colou/anexou.
class AgentTemplates {
  static const all = <String, String>{
    'moodle_planilha':
        'Config Moodle → "Novo" → "Importar Planilha": planilha .xlsx de uma '
        'disciplina (seções e atividades), abas _Datas Especiais e _Trocas de Dia.',
    'diario_planilha':
        'Preenche Diários → "Importar Excel": colunas Data | Modalidade | '
        'Matéria Lecionada.',
    'diario_json':
        'Preenche Diários → carregar JSON: objeto {"DD/MM/AAAA -T": "conteúdo"}.',
    'ajusta_horarios_bdados':
        'Ajusta Horários → "Importar base da planilha" (aba BDados): substitui '
        'a base de disciplinas/turmas/horários do período.',
    'ajusta_horarios_banco':
        'Ajusta Horários → "Importar base da planilha" (aba Banco): '
        'distribuição docente (quem leciona cada turma e as cargas).',
    'equivalencia_curriculo':
        'Equivalência → "Currículos" → importar disciplinas do currículo.',
    'equivalencia_analise':
        'Equivalência → "Importar planilha": análise de um aluno (aba '
        'Equivalencia, blocos currículo atual ↔ anterior).',
    'plano_ensino_json':
        'Planos de Ensino → "Importar backup": lista de planos em JSON.',
    'plano_ensino_cronograma':
        'Planos de Ensino → editar plano → "Aplicar tabela colada": texto com '
        'colunas separadas por TAB (Data, Modalidade, Matéria Lecionada…).',
  };

  /// Gera o modelo [id] e devolve o caminho do arquivo criado.
  ///
  /// [rows]: linhas de dados (lista de listas) no lugar dos exemplos; para
  /// `diario_json` e `plano_ensino_json`, [data] substitui o conteúdo.
  static Future<Map<String, Object?>> create(
    String id, {
    List<List<Object?>>? rows,
    Object? data,
    String? folder,
    String? fileName,
    Map<String, dynamic> options = const {},
  }) async {
    final (String name, List<int> bytes, String howTo) = switch (id) {
      'moodle_planilha' => _moodle(rows, options),
      'diario_planilha' => _diarioXlsx(rows),
      'diario_json' => _diarioJson(data),
      'ajusta_horarios_bdados' => _bdados(rows),
      'ajusta_horarios_banco' => _banco(rows),
      'equivalencia_curriculo' => _curriculo(rows),
      'equivalencia_analise' => _analise(rows, options),
      'plano_ensino_json' => _planoJson(data),
      'plano_ensino_cronograma' => _cronograma(rows),
      _ => throw StateError(
        'Modelo desconhecido "$id". Use um destes: ${all.keys.join(', ')}.',
      ),
    };
    final dir = Directory(
      folder?.trim().isNotEmpty == true ? folder!.trim() : _defaultFolder(),
    );
    await dir.create(recursive: true);
    var target = p.join(
      dir.path,
      fileName?.trim().isNotEmpty == true ? fileName!.trim() : name,
    );
    if (p.extension(target).isEmpty) target += p.extension(name);
    await File(target).writeAsBytes(bytes);
    return {'ok': true, 'path': target, 'template': id, 'como_importar': howTo};
  }

  static String _defaultFolder() {
    final home =
        Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return p.join(home, 'Documents', 'GestorUFU Agente', 'modelos');
  }

  static CellValue _cell(Object? value) => switch (value) {
    null => TextCellValue(''),
    final int v => IntCellValue(v),
    final double v => DoubleCellValue(v),
    final bool v => BoolCellValue(v),
    _ => TextCellValue('$value'),
  };

  static List<int> _encode(Excel excel, String keep) {
    if (excel.tables.containsKey('Sheet1') && keep != 'Sheet1') {
      excel.delete('Sheet1');
    }
    return excel.encode()!;
  }

  static void _rows(Sheet sheet, Iterable<List<Object?>> rows) {
    for (final row in rows) {
      sheet.appendRow(row.map(_cell).toList());
    }
  }

  // ------------------------------------------------------------ Config Moodle

  static (String, List<int>, String) _moodle(
    List<List<Object?>>? rows,
    Map<String, dynamic> options,
  ) {
    final swaps = <DateTime, int>{};
    final rawSwaps = options['day_swaps'];
    if (rawSwaps is Map) {
      for (final entry in rawSwaps.entries) {
        final date = DateTime.tryParse('${entry.key}');
        final weekday = int.tryParse('${entry.value}');
        if (date != null && weekday != null) swaps[date] = weekday;
      }
    }
    final bytes = TemplateGenerator.generateTemplate(
      sheetName: '${options['sheet_name'] ?? 'Disciplina'}',
      courseName: '${options['course_name'] ?? 'NOME DA DISCIPLINA NO MOODLE'}',
      moodleCourseId: options['moodle_course_id'],
      semesterStart: DateTime.tryParse('${options['semester_start'] ?? ''}'),
      rows: rows,
      holidays: [
        for (final date in (options['holidays'] as List? ?? const []))
          ?DateTime.tryParse('$date'),
      ],
      daySwaps: swaps,
    );
    return (
      'config_moodle_modelo.xlsx',
      bytes,
      'Config Moodle → "Novo" → "Importar Planilha (.xlsx)". Cada aba com a '
          'linha de cabeçalho "Ordem … Tipo" vira uma configuração (o nome da '
          'aba é o nome da configuração).',
    );
  }

  // ------------------------------------------------------------ Diários

  static (String, List<int>, String) _diarioXlsx(List<List<Object?>>? rows) {
    final excel = Excel.createExcel();
    final sheet = excel['Diario'];
    _rows(sheet, [
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
      _encode(excel, 'Diario'),
      'Preenche Diários → "Importar Excel" → escolher a aba. Mescla com o '
          'rascunho atual (datas iguais são sobrescritas).',
    );
  }

  static (String, List<int>, String) _diarioJson(Object? data) {
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

  // ------------------------------------------------------------ Ajusta Horários

  static (String, List<int>, String) _bdados(List<List<Object?>>? rows) {
    final excel = Excel.createExcel();
    final sheet = excel['BDados'];
    _rows(sheet, [
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
      _encode(excel, 'BDados'),
      'Ajusta Horários → "Importar base da planilha". A aba BDados SUBSTITUI '
          'toda a base do período e limpa a distribuição docente.',
    );
  }

  static (String, List<int>, String) _banco(List<List<Object?>>? rows) {
    final excel = Excel.createExcel();
    final sheet = excel['Banco'];
    _rows(sheet, [
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
      _encode(excel, 'Banco'),
      'Ajusta Horários → "Importar base da planilha". Se o arquivo tiver a '
          'aba Banco, ela é usada (tem prioridade sobre BDados) e atualiza só '
          'a Distribuição Docente, mantendo as grades.',
    );
  }

  // ------------------------------------------------------------ Equivalência

  static (String, List<int>, String) _curriculo(List<List<Object?>>? rows) {
    final excel = Excel.createExcel();
    final sheet = excel['Curriculo'];
    _rows(sheet, [
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
      _encode(excel, 'Curriculo'),
      'Equivalência → "Currículos" → editar/criar currículo → importar '
          'disciplinas (.xlsx). A ordem das colunas não importa; o cabeçalho '
          'precisa estar nas 30 primeiras linhas e ter ao menos o nome da '
          'disciplina.',
    );
  }

  static (String, List<int>, String) _analise(
    List<List<Object?>>? rows,
    Map<String, dynamic> options,
  ) {
    final excel = Excel.createExcel();
    final sheet = excel['Equivalencia'];
    _rows(sheet, [
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
    _rows(sheet, data);
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
      _encode(excel, 'Equivalencia'),
      'Equivalência → "Importar planilha" (com um currículo atual '
          'selecionado). A1 = aluno, A2 = matrícula; dados a partir da linha '
          '7. Linhas com a coluna G (Saldo) mesclada formam um bloco.',
    );
  }

  // ------------------------------------------------------------ Planos de Ensino

  static (String, List<int>, String) _planoJson(Object? data) {
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

  static (String, List<int>, String) _cronograma(List<List<Object?>>? rows) {
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
}
