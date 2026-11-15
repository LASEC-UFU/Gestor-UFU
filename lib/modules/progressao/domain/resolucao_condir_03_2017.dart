/// Catálogo da Resolução nº 03/2017 do CONDIR/UFU (avaliação de desempenho
/// para progressão e promoção docente), com as alterações da Resolução SEI
/// nº 05/2018 do CONDIR (itens 147, 150 e 158 do Anexo 1).
library;

/// Forma de cálculo de um item do Anexo 1.
enum TipoPontuacao {
  /// Pontos fixos por unidade (hora, aluno/mês, trabalho, ...).
  porUnidade,

  /// Fração da pontuação de referência por dia (itens de gestão e licenças).
  fracaoReferenciaPorDia,
}

/// Unidade usada para sugerir o cálculo a partir de datas.
enum PeriodoItem { nenhum, meses, dias }

/// Tabelas do Anexo 1.
enum TabelaAnexo1 {
  ensino('A1.1', 'Atividades de ensino', 1, 12),
  orientacao('A1.2', 'Atividades de orientação', 13, 28),
  producao('A1.3', 'Produção intelectual', 29, 88),
  semRemuneracao(
    'A1.4',
    'Atividades de ensino, extensão e pesquisa - sem remuneração suplementar',
    89,
    102,
  ),
  comRemuneracao(
    'A1.5',
    'Atividades de ensino, extensão e pesquisa - com remuneração suplementar',
    103,
    113,
  ),
  gestao('A1.6', 'Atividades de gestão', 114, 162),
  licencas('A1.7', 'Licenças, situações especiais e afastamentos', 163, 167);

  const TabelaAnexo1(this.codigo, this.titulo, this.primeiro, this.ultimo);

  final String codigo;
  final String titulo;
  final int primeiro;
  final int ultimo;

  String get faixa => 'itens $primeiro a $ultimo';

  static TabelaAnexo1 doItem(int numero) =>
      values.firstWhere((t) => numero >= t.primeiro && numero <= t.ultimo);
}

/// Item do roteiro de pontuação (Anexo 1).
class ItemAnexo1 {
  const ItemAnexo1(
    this.numero,
    this.descricao,
    this.pontos,
    this.unidade, {
    this.nota = '',
    this.teto,
    this.periodo = PeriodoItem.nenhum,
    this.alteradoPor = '',
  }) : tipo = TipoPontuacao.porUnidade,
       divisor = 0;

  const ItemAnexo1.fracao(
    this.numero,
    this.descricao,
    this.divisor, {
    this.nota = '',
    this.alteradoPor = '',
  }) : tipo = TipoPontuacao.fracaoReferenciaPorDia,
       pontos = 0,
       unidade = 'dia',
       teto = null,
       periodo = PeriodoItem.dias;

  final int numero;
  final String descricao;
  final String nota;
  final TipoPontuacao tipo;

  /// Pontos por unidade (apenas [TipoPontuacao.porUnidade]).
  final double pontos;

  /// Denominador da fração da pontuação de referência por dia.
  final int divisor;
  final String unidade;

  /// Limite máximo de pontos do item no interstício.
  final double? teto;
  final PeriodoItem periodo;
  final String alteradoPor;

  TabelaAnexo1 get tabela => TabelaAnexo1.doItem(numero);

  /// Subgrupo da Tabela A1.3 (bibliográfica, artística, técnica).
  String get subgrupo {
    if (tabela != TabelaAnexo1.producao) return '';
    if (numero <= 54) return 'Produção bibliográfica e divulgação';
    if (numero <= 68) return 'Produção artística';
    return 'Produção técnica';
  }

  /// Valor de uma unidade, dada a pontuação de referência.
  double valorUnitario(double referencia) =>
      tipo == TipoPontuacao.porUnidade ? pontos : referencia / divisor;

  /// Regra de pontuação em texto, como no Anexo 1.
  String get regra {
    if (tipo == TipoPontuacao.fracaoReferenciaPorDia) {
      return '1/$divisor da pontuação de referência por dia';
    }
    final valor = formatarNumero(pontos);
    final rotulo = pontos < 2 ? 'ponto' : 'pontos';
    final limite = teto == null
        ? ''
        : ' (limite de ${formatarNumero(teto!)} pontos)';
    return '$valor $rotulo por $unidade$limite';
  }
}

String formatarNumero(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  final text = value.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '');
  return text.replaceAll('.', ',');
}

const _obsAula =
    'Comprovação por cópia do diário de classe ou declaração do coordenador do curso '
    'ou diretor de unidade especial, discriminando a quantidade de horas-aula ministradas '
    'no interstício e o número de discentes matriculados. Componentes ministrados por mais '
    'de um docente: pontuação conforme a carga horária ministrada pelo docente.';
const _obsAlunos =
    'Comprovação conforme especificações 1 e 3 do item 1. Considera-se o número de alunos '
    'acima do limite por diário ou, havendo diferentes diários, a soma dos diários, por docente.';
const _obsPos =
    'A comprovação deverá ser feita pela Coordenação do Programa de Pós-graduação no qual o '
    'aluno encontra-se matriculado ou pelo diário de classe.';
const _obsHomologacao =
    'Serão pontuadas as atividades administrativas comprovadas por documento de homologação do cargo.';
const _obsUnidade =
    'Serão pontuadas as ações devidamente comprovadas pela Unidade.';
const _obsQuarto =
    'Pontuada em mais um quarto de sua pontuação de referência a cada nova cidade/local/'
    'reapresentação, limitado a 4, desde que autorizada e comprovada pela Unidade '
    '(informe a quantidade fracionária, ex.: 1,25).';
const _obsCertificado =
    'Somente serão pontuadas as participações devidamente comprovadas por certificado do evento.';
const _obsBancaPos =
    'Serão pontuadas as participações comprovadas por declaração fornecida pelo Coordenador de '
    'Curso de Pós-graduação ou ata.';
const _obsPublicacao =
    'Serão pontuadas as publicações comprovadas por cópia da folha de rosto do meio de divulgação, '
    'da primeira página e da comprovação exigida.';
const _obsLivro =
    'Só serão aceitos livros publicados por Editora com Conselho Editorial ou Editor/Diretor '
    'responsável, comprovados por cópia da folha de rosto e da ficha catalográfica.';
const _m = PeriodoItem.meses;

/// Roteiro para pontuação das atividades (Anexo 1).
const List<ItemAnexo1> anexo1 = [
  // TABELA A1.1 - ATIVIDADES DE ENSINO
  ItemAnexo1(
    1,
    'Aula teórica ou prática de componentes curriculares ministrados na modalidade presencial ou a distância, na Educação Básica, na Educação Profissional, em cursos de graduação ou pós-graduação stricto e lato sensu da UFU, aprovadas pelo Conselho da Unidade.',
    1,
    'hora-aula ministrada',
    nota: _obsAula,
  ),
  ItemAnexo1(
    2,
    'Oficina Psicoeducacional ministrada em modalidade de aula para alunos com deficiência e demais discentes da educação básica, profissional ou em cursos de graduação, aprovada pelo Conselho da Unidade.',
    1,
    'hora-aula ministrada',
    nota: 'Comprovação conforme especificações 1 e 2 do item 1.',
  ),
  ItemAnexo1(
    3,
    'Atendimento educacional especializado oferecido em modalidade de aula para alunos da Educação Especial em decorrência de quadro de deficiência, regularmente matriculados na UFU, aprovado pelo Conselho da Unidade.',
    1,
    'hora-aula ministrada',
    nota: 'Comprovação conforme especificações 1 e 2 do item 1.',
  ),
  ItemAnexo1(
    4,
    'Assessoramento à classe comum (Decreto nº 5.671/2008), com atendimento junto ao professor e ao aluno na classe comum, realizado por docentes da área da educação especial da Unidade Especial de Ensino.',
    1,
    'hora-aula',
    nota: 'Comprovação conforme especificação 1 do item 1.',
  ),
  ItemAnexo1(
    5,
    'Aula oferecida em regime especial, aprovada pelo Colegiado do Curso ou Conselho da Unidade.',
    1,
    'hora-aula ministrada',
    nota: 'Comprovação conforme especificações 1 e 2 do item 1.',
  ),
  ItemAnexo1(
    6,
    'Componente curricular teórico presencial para turmas com mais de 45 alunos.',
    0.5,
    'aluno acima de 45',
    nota: _obsAlunos,
  ),
  ItemAnexo1(
    7,
    'Componente curricular prático presencial de Ciências Humanas, Ciências Sociais Aplicadas, Letras, Linguística e Artes para turmas com mais de 12 alunos (exceto Música).',
    0.5,
    'aluno acima de 12',
    nota: _obsAlunos,
  ),
  ItemAnexo1(
    8,
    'Componente curricular prático presencial de Ciências Exatas e da Terra, Ciências Agrárias, Ciências Biológicas, Engenharias e Ciências da Saúde para turmas com mais de 9 alunos.',
    0.5,
    'aluno acima de 9',
    nota: _obsAlunos,
  ),
  ItemAnexo1(
    9,
    'Componente curricular prático presencial de Música ou aula prática clínica presencial da área da saúde, para turmas com mais de 6 alunos de cursos de graduação, pós-graduação ou educação técnica e tecnológica.',
    0.5,
    'aluno acima de 6',
    nota: _obsAlunos,
  ),
  ItemAnexo1(
    10,
    'Componente curricular prático presencial de cursos de pós-graduação lato sensu, para turmas com mais de 8 alunos.',
    0.5,
    'aluno acima de 8',
    nota: _obsAlunos,
  ),
  ItemAnexo1(
    11,
    'Componente curricular teórico da ESEBA, para turmas da educação infantil e primeiro ano do ensino fundamental, com mais de 18 alunos.',
    0.5,
    'aluno acima de 18',
    nota: _obsAlunos,
  ),
  ItemAnexo1(
    12,
    'Componente curricular teórico da ESEBA, para turmas a partir do segundo ano do ensino fundamental e educação de jovens e adultos, com mais de 25 alunos.',
    0.5,
    'aluno acima de 25',
    nota: _obsAlunos,
  ),
  // TABELA A1.2 - ATIVIDADES DE ORIENTAÇÃO
  ItemAnexo1(
    13,
    'Orientação e ou supervisão de alunos de graduação e da educação profissional em atividades curriculares de ensino realizadas no campo de estágio, com a presença do docente, desde que não pontuada nas Atividades de Ensino.',
    0.4,
    'hora de orientação',
    nota:
        'Ex.: Estágio Supervisionado, Estágio Profissionalizante, Assistência Judiciária e similares. A comprovação deverá ser fornecida pela Coordenação do Curso.',
  ),
  ItemAnexo1(
    14,
    'Orientação e ou supervisão de alunos de graduação e da educação profissional em atividades curriculares de ensino, sem a presença do docente, desde que não pontuada nas Atividades de Ensino.',
    1,
    'aluno/mês completo',
    teto: 160,
    periodo: _m,
    nota:
        'Ex.: Estágio Supervisionado, Estágio Profissionalizante, Monografia de Graduação ou Trabalho de Conclusão de Curso de graduação e similares. A comprovação deverá ser fornecida pela Coordenação do Curso.',
  ),
  ItemAnexo1(
    15,
    'Orientação de alunos da Educação Básica, da Educação Profissional ou da graduação em projetos de ensino ou extensão ou pesquisa com bolsa (Ex.: PBG, PEIC, PET, PIBIC, PIBID, OBEDUC, PINA, RENAFOR e similares) e de alunos da Educação Básica em atividades de Iniciação científica com Bolsa na UFU (Ex.: PIBIC EM).',
    1,
    'aluno/mês completo',
    periodo: _m,
    nota:
        'A comprovação deverá ser pelo órgão de fomento ou Pró-Reitorias do qual o aluno é bolsista.',
  ),
  ItemAnexo1(
    16,
    'Orientação de alunos da Educação Básica, da Educação Profissional ou da graduação em Programas de ensino ou extensão ou pesquisa sem bolsa de Iniciação Científica (Ex.: PIVIC).',
    1,
    'aluno/mês completo',
    periodo: _m,
    nota:
        'A comprovação deverá ser feita pelo órgão responsável no qual o aluno está vinculado.',
  ),
  ItemAnexo1(
    17,
    'Orientação de alunos da Educação Básica, da Educação Profissional ou da graduação em projetos de ensino ou extensão ou pesquisa sem bolsa de Iniciação Científica (projetos sem bolsa registrados na Unidade Administrativa em questão e similares).',
    0.75,
    'aluno/mês completo',
    periodo: _m,
    nota:
        'A comprovação deverá ser fornecida pelas Diretorias competentes da UFU.',
  ),
  ItemAnexo1(
    18,
    'Orientação de alunos da Educação Básica e Profissional realizada por docentes da área de psicologia escolar da Unidade Especial de Ensino.',
    0.75,
    'aluno/mês completo',
    periodo: _m,
    nota: 'A comprovação deverá ser fornecida pela Direção da Unidade.',
  ),
  ItemAnexo1(
    19,
    'Orientação de Dissertação de Mestrado.',
    2.5,
    'aluno/mês completo',
    periodo: _m,
    nota: _obsPos,
  ),
  ItemAnexo1(
    20,
    'Coorientação de Dissertação de Mestrado.',
    1.25,
    'aluno/mês completo',
    periodo: _m,
    nota: _obsPos,
  ),
  ItemAnexo1(
    21,
    'Orientação de Tese de Doutorado / Supervisão de estágio de Pós-Doutorado.',
    4,
    'aluno ou estagiário/mês completo',
    periodo: _m,
    nota: _obsPos,
  ),
  ItemAnexo1(
    22,
    'Coorientação de Tese de Doutorado.',
    2,
    'aluno/mês completo',
    periodo: _m,
    nota: _obsPos,
  ),
  ItemAnexo1(
    23,
    'Orientação de graduados em Cursos de Educação profissional ou permanente.',
    1.25,
    'orientação/mês completo',
    periodo: _m,
    nota:
        'As atividades deverão ser comprovadas pela Pró-Reitoria responsável.',
  ),
  ItemAnexo1(
    24,
    'Orientação de Monografia ou Trabalho de Conclusão de Curso em Curso de Especialização.',
    1.25,
    'aluno/mês completo',
    periodo: _m,
    nota:
        'A atividade será comprovada por declaração do Coordenador de Curso ou do Diretor da Unidade.',
  ),
  ItemAnexo1(
    25,
    'Orientação de Monitores e Tutores de EAD.',
    0.5,
    'aluno/mês completo',
    periodo: _m,
    nota: 'A monitoria deverá ser comprovada pela Coordenação do Curso.',
  ),
  ItemAnexo1(
    26,
    'Orientação ou supervisão de alunos da educação básica, profissional e graduação, em exposições, congressos, atividades esportivas, seminários e encontros artísticos culturais em eventos isolados e aprovados pelo Conselho da Unidade.',
    4,
    'aluno/evento',
    nota:
        'Serão pontuadas as atividades aprovadas pelo Conselho da Unidade Especial de Ensino e comprovadas por declaração do Diretor.',
  ),
  ItemAnexo1(
    27,
    'Orientação educacional na educação básica, em atividades de recreio orientado.',
    5,
    'mês completo',
    periodo: _m,
    nota:
        'Serão pontuadas as atividades comprovadas por meio de Portaria de nomeação do docente.',
  ),
  ItemAnexo1(
    28,
    'Orientação de projetos de consultoria, projetos técnicos e tutoria das Empresas Juniores da Universidade Federal de Uberlândia.',
    1,
    'aluno/mês completo',
    periodo: _m,
    nota:
        'Serão pontuadas as atividades aprovadas pelo Conselho da Unidade e comprovadas por declaração do Diretor.',
  ),
  // TABELA A1.3 - PRODUÇÃO INTELECTUAL
  ItemAnexo1(
    29,
    'Artigo técnico-científico publicado em periódico qualificado pela CAPES.',
    150,
    'trabalho',
    nota: _obsPublicacao,
  ),
  ItemAnexo1(
    30,
    'Artigo técnico-científico publicado em periódico não classificado pela CAPES, com corpo de revisores ou equivalente.',
    100,
    'trabalho',
    nota: _obsPublicacao,
  ),
  ItemAnexo1(
    31,
    'Publicação de trabalho completo em anais de reunião científica, com corpo de revisores.',
    60,
    'trabalho',
    nota: _obsPublicacao,
  ),
  ItemAnexo1(
    32,
    'Publicação de resumo expandido em anais de reunião científica.',
    30,
    'trabalho',
    nota:
        'Serão pontuadas as publicações comprovadas por cópia do resumo e da folha de rosto do meio de divulgação do resumo.',
  ),
  ItemAnexo1(
    33,
    'Publicação de resumo em anais de reunião científica.',
    20,
    'trabalho',
    nota:
        'Serão pontuadas as publicações não pontuadas nos itens 31 e 32, comprovadas por cópia do resumo e da folha de rosto.',
  ),
  ItemAnexo1(
    34,
    'Publicação de material didático hipermidiático, elaborado para disciplinas ministradas na Educação Básica, na Educação Profissional, em cursos de Graduação, stricto sensu e lato sensu na modalidade a distância.',
    30,
    'publicação',
    nota:
        'Somente serão aceitos materiais didáticos produzidos por meio de solicitação da coordenação do curso.',
  ),
  ItemAnexo1(
    35,
    'Publicação de material hipermidiático (texto, áudio e ou vídeo) sobre divulgação científica em mídias variadas para o público.',
    15,
    'publicação',
    nota:
        'Aprovadas pela Unidade ou apoiadas por órgãos de fomento (PIBIC, PIBID, PIVIC, PIBIT e similares) ou registradas em Pró-Reitorias.',
  ),
  ItemAnexo1(
    36,
    'Publicação individual de crítica, textos jornalísticos, prefácio de obras especializadas, espetáculos ou exposições.',
    30,
    'publicação',
    nota:
        'Serão pontuadas aquelas comprovadas por cópia da publicação ou folha de rosto do meio de divulgação.',
  ),
  ItemAnexo1(
    37,
    'Publicação de resenha em meios de divulgação com corpo editorial.',
    30,
    'publicação',
    nota: _obsPublicacao,
  ),
  ItemAnexo1(
    38,
    'Apresentação de trabalho ou mostra documental em reunião científica.',
    10,
    'trabalho',
    nota:
        'Serão pontuados apenas os trabalhos apresentados pelo docente, comprovados por certificado assinado pelo Coordenador ou Presidente do evento.',
  ),
  ItemAnexo1(
    39,
    'Palestras e conferências proferidas, minicursos ministrados, seminários, oficinas, participação em painéis de debate ou mesas redondas em reuniões científicas promovidas por associações ou sociedades científicas ou associações esportivas nacionais e internacionais.',
    15,
    'tema',
    nota: _obsCertificado,
  ),
  ItemAnexo1(
    40,
    'Palestras e conferências proferidas, minicursos ministrados, seminários, oficinas, participação em mesas redondas ou em painéis de debate em reuniões científicas não promovidas por associações ou sociedades científicas.',
    10,
    'tema',
    teto: 80,
    nota: _obsCertificado,
  ),
  ItemAnexo1(
    41,
    'Palestras e conferências proferidas, minicursos ministrados, seminários, oficinas, participação em mesas redondas ou em painéis de debate em eventos acadêmicos isolados e eventos sem apresentação de trabalho.',
    5,
    'tema',
    teto: 80,
    nota: _obsCertificado,
  ),
  ItemAnexo1(
    42,
    'Participação em palestras, conferências, minicursos, seminários, oficinas, mesas redondas ou em painéis de debate em eventos da área do docente, sem apresentação de trabalho.',
    3,
    'tema',
    teto: 48,
    nota: _obsCertificado,
  ),
  ItemAnexo1(
    43,
    'Premiação ou menção honrosa de trabalhos artísticos, arquitetônicos, científicos, literários em eventos científicos, esportivos e culturais.',
    30,
    'premiação/trabalho ou evento',
    nota:
        'O trabalho deverá ser pontuado uma única vez e a premiação ou menção honrosa deverá ser comprovada.',
  ),
  ItemAnexo1(
    44,
    'Monografia defendida em curso de especialização.',
    20,
    'monografia',
    nota:
        'A comprovação será feita por declaração da Coordenação do Curso de Especialização.',
  ),
  ItemAnexo1(
    45,
    'Dissertação de Mestrado defendida pelo docente.',
    40,
    'dissertação',
    nota:
        'Comprovada por declaração da Coordenação do Programa de Pós-graduação.',
  ),
  ItemAnexo1(
    46,
    'Tese de Doutorado ou Livre-Docência defendida pelo docente.',
    80,
    'tese',
    nota:
        'Comprovada por declaração da Coordenação do Programa de Pós-graduação.',
  ),
  ItemAnexo1(
    47,
    'Estágio de pós-doutorado concluído pelo docente.',
    5,
    'mês',
    teto: 40,
    periodo: _m,
    nota:
        'A comprovação será feita por declaração do supervisor do referido estágio.',
  ),
  ItemAnexo1(
    48,
    'Conclusão de curso de aperfeiçoamento.',
    0.2,
    'hora',
    nota:
        'Serão pontuados os cursos comprovados por declaração do Coordenador do Curso de Aperfeiçoamento.',
  ),
  ItemAnexo1(
    49,
    'Publicação de livro didático, paradidático, cultural, técnico ou resultado de pesquisa acadêmica.',
    300,
    'publicação',
    nota: _obsLivro,
  ),
  ItemAnexo1(
    50,
    'Publicação de capítulo de livro didático, paradidático, cultural, técnico ou resultado de pesquisa acadêmica, desde que não inserido em anais de congressos ou eventos.',
    100,
    'publicação',
    nota: _obsLivro,
  ),
  ItemAnexo1(
    51,
    'Editoração/organização de livros, de anais de eventos, coleções, periódicos ou dossiês de periódicos.',
    100,
    'obra',
    nota:
        'Serão pontuadas as publicações comprovadas por cópia da folha de rosto do meio de divulgação e da ficha catalográfica.',
  ),
  ItemAnexo1(
    52,
    'Tradução/Versão de peças teatrais, de óperas encenadas ou livros.',
    100,
    'obra',
    nota:
        'A autoria de cada trabalho deverá ser devidamente comprovada. Caso o trabalho tenha sido publicado, pontuar apenas os itens relativos às publicações.',
  ),
  ItemAnexo1(
    53,
    'Tradução/Versão de capítulo de livros ou artigos em periódicos, com corpo editorial ou equivalente.',
    50,
    'capítulo ou artigo',
    nota: _obsPublicacao,
  ),
  ItemAnexo1(
    54,
    'Tradução/Versão de documentos oficiais e traduções simultâneas em eventos acadêmicos e científicos.',
    30,
    'evento',
    nota:
        'Serão pontuadas as traduções comprovadas por certificado emitido pela Instituição solicitante.',
  ),
  ItemAnexo1(
    55,
    'Exposição artística individual de obras artísticas inéditas.',
    150,
    'exposição',
    nota: _obsQuarto,
  ),
  ItemAnexo1(
    56,
    'Exposição artística coletiva de obras artísticas inéditas.',
    60,
    'exposição',
    nota: _obsQuarto,
  ),
  ItemAnexo1(
    57,
    'Ação e ou projeto artístico ou cultural inédito individual em espaço público ou com trânsito livre de pessoas.',
    30,
    'ação',
    nota: _obsQuarto,
  ),
  ItemAnexo1(
    58,
    'Ação e ou projeto artístico ou cultural inédito coletivo em espaço público ou com trânsito livre de pessoas.',
    10,
    'ação',
    nota: _obsQuarto,
  ),
  ItemAnexo1(
    59,
    'Peça de arte interativa inédita de autoria individual publicada ou distribuída em meio eletrônico.',
    30,
    'peça',
    nota: 'Ex.: web arte, net arte, game arte, etc. $_obsUnidade',
  ),
  ItemAnexo1(
    60,
    'Peça de arte interativa inédita de autoria coletiva publicada ou distribuída em meio eletrônico.',
    10,
    'peça',
    nota: 'Ex.: web arte, net arte, game arte, etc. $_obsUnidade',
  ),
  ItemAnexo1(
    61,
    'Participação integral em recitais, concertos, gravações, coreografias, performances, cenas teatrais, intervenções urbanas e apresentações de música, teatro e dança como: ator, diretor/encenador, bailarino, músico, regente, performer, solista e similares.',
    120,
    'apresentação',
    nota: _obsQuarto,
  ),
  ItemAnexo1(
    62,
    'Participação parcial em recitais, concertos, gravações, coreografias, performances, cenas teatrais, intervenções urbanas e apresentações de música, teatro e dança como: ator, bailarino, músico, regente, performer e similares.',
    40,
    'apresentação',
    nota: _obsQuarto,
  ),
  ItemAnexo1(
    63,
    'Participação como figurinista, cenógrafo, diretor musical, orientador corporal, iluminador, dramaturgo ou produtor em óperas, espetáculos teatrais ou de dança e similares.',
    40,
    'participação',
    nota:
        'A participação será pontuada uma única vez, independente do número de apresentações.',
  ),
  ItemAnexo1(
    64,
    'Autoria de peças teatrais, roteiros, óperas, concertos, composições musicais, trilha sonora, cenografia, figurino, iluminação e ou coreografias integrais apresentadas e ou gravadas.',
    120,
    'autoria',
    nota:
        'Os trabalhos artísticos poderão ser pontuados uma única vez, independente do número de apresentações.',
  ),
  ItemAnexo1(
    65,
    'Adaptação de peça teatral e ou ópera encenada e ou autoria de trabalho na área de comunicação visual publicada.',
    40,
    'adaptação ou trabalho',
    nota:
        'Os trabalhos artísticos poderão ser pontuados uma única vez, independente do número de apresentações.',
  ),
  ItemAnexo1(
    66,
    'Transcrição e ou arranjo de obras musicais gravadas ou publicadas.',
    30,
    'obra',
    nota: 'Cada trabalho poderá ser pontuado uma única vez.',
  ),
  ItemAnexo1(
    67,
    'Restauração de obras artísticas e ou partituras musicais de comprovado valor histórico.',
    2,
    'hora',
    nota: 'Será pontuada a atividade aprovada e comprovada pela Unidade.',
  ),
  ItemAnexo1(
    68,
    'Maquetes físicas ou digitais.',
    20,
    'maquete',
    nota: 'Cada maquete poderá ser pontuada uma única vez.',
  ),
  ItemAnexo1(
    69,
    'Membro de Comissão Julgadora ou Comissão Científica de eventos científicos, artísticos, culturais, esportivos ou técnicos.',
    10,
    'participação',
    nota:
        'Serão pontuadas as participações comprovadas com certificado do evento.',
  ),
  ItemAnexo1(
    70,
    'Membro de banca de qualificação para o exercício profissional.',
    10,
    'participação',
    nota:
        'Serão pontuadas as participações comprovadas por portaria de nomeação.',
  ),
  ItemAnexo1(
    71,
    'Membro de Comissão Organizadora de reuniões científicas, artísticas, culturais, técnicas e esportivas.',
    10,
    'participação',
    nota:
        'Comprovadas por declaração do Coordenador da Comissão Organizadora ou do Diretor da Unidade responsável.',
  ),
  ItemAnexo1(
    72,
    'Parecer ad hoc prestado a editoras, revistas especializadas e órgãos de fomento, devidamente comprovado, resguardado o sigilo e demais considerações éticas.',
    10,
    'parecer',
  ),
  ItemAnexo1(
    73,
    'Coordenação de Comissão Organizadora de reuniões científicas, de ensino, artísticas, culturais, técnicas e esportivas, promovidas por Instituições, associações ou sociedades científicas ou artístico-culturais.',
    15,
    'participação',
    nota: 'Comprovada por declaração da instituição solicitante.',
  ),
  ItemAnexo1(
    74,
    'Diretor-geral ou Editor Chefe de revista científica ou artística.',
    5,
    'mês completo',
    periodo: _m,
    nota:
        'Serão pontuadas as participações devidamente comprovadas pela Revista.',
  ),
  ItemAnexo1(
    75,
    'Membro de Conselho ou Corpo Editorial de revista científica, artística ou de Editoras.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Não contempla Conselho Editorial composto pelos consultores ad hoc. Comprovação pela Revista ou Editora.',
  ),
  ItemAnexo1(
    76,
    'Membro titular de banca de defesa de projetos, estágio supervisionado, trabalho de conclusão de curso ou de monografias de graduação.',
    4,
    'participação',
    nota:
        'Serão pontuadas as participações comprovadas por meio de declaração fornecida pelo Coordenador de Curso de Graduação ou pelo Diretor da Unidade.',
  ),
  ItemAnexo1(
    77,
    'Membro titular de banca de defesa de Monografia ou Trabalho de Conclusão de Curso de Pós-graduação lato sensu.',
    5,
    'participação',
    nota: _obsBancaPos,
  ),
  ItemAnexo1(
    78,
    'Membro titular de banca de exame de qualificação de Mestrado ou Doutorado.',
    10,
    'participação',
    nota: _obsBancaPos,
  ),
  ItemAnexo1(
    79,
    'Membro titular de banca de Dissertação de Mestrado.',
    15,
    'participação',
    nota: _obsBancaPos,
  ),
  ItemAnexo1(
    80,
    'Membro titular de banca de Tese de Doutorado.',
    20,
    'participação',
    nota: _obsBancaPos,
  ),
  ItemAnexo1(
    81,
    'Patente ou cultivar com pedido de registro comprovado (com titularidade ou cotitularidade da UFU).',
    80,
    'registro',
  ),
  ItemAnexo1(
    82,
    'Patente ou cultivar transferida (com titularidade ou cotitularidade da UFU).',
    150,
    'patente',
  ),
  ItemAnexo1(
    83,
    'Programa de computador com registro no INPI (com titularidade ou cotitularidade da UFU).',
    80,
    'registro',
  ),
  ItemAnexo1(
    84,
    'Programa de computador transferido (com titularidade ou cotitularidade da UFU).',
    150,
    'registro',
  ),
  ItemAnexo1(
    85,
    'Desenho industrial com registro no INPI (com titularidade ou cotitularidade da UFU).',
    80,
    'registro',
  ),
  ItemAnexo1(
    86,
    'Desenho industrial transferido (com titularidade ou cotitularidade da UFU).',
    150,
    'registro',
  ),
  ItemAnexo1(
    87,
    'Relatório final de ensino ou extensão ou pesquisa com financiamento externo ou interno.',
    20,
    'relatório',
    nota:
        'Os relatórios elaborados pelos discentes não deverão ser pontuados. Serão pontuados os relatórios submetidos e aprovados pelo órgão de fomento.',
  ),
  ItemAnexo1(
    88,
    'Relatório final de ensino ou extensão ou pesquisa sem financiamento, com registro em Pró-Reitoria.',
    10,
    'relatório',
    nota:
        'Os relatórios elaborados pelos discentes não deverão ser pontuados. Serão pontuados os relatórios submetidos e aprovados pela respectiva Pró-Reitoria.',
  ),
  // TABELA A1.4 - SEM REMUNERAÇÃO SUPLEMENTAR
  ItemAnexo1(
    89,
    'Coordenação de projetos de ensino ou extensão ou pesquisa com financiamento externo, aprovado pelo órgão de fomento, pelo Conselho da Unidade ou órgão superior.',
    10,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por documento de aprovação do projeto pelo órgão de fomento e por declaração do Diretor da Unidade.',
  ),
  ItemAnexo1(
    90,
    'Coordenação de projetos de ensino ou extensão ou pesquisa com financiamento interno e registrado em Pró-Reitoria.',
    5,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por documento de aprovação do projeto pela respectiva Pró-Reitoria.',
  ),
  ItemAnexo1(
    91,
    'Coordenação de projetos de ensino ou extensão ou pesquisa sem financiamento e registrado em Pró-Reitoria.',
    3,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por documento de aprovação do projeto pela respectiva Pró-Reitoria.',
  ),
  ItemAnexo1(
    92,
    'Membro de equipe de projetos de ensino ou extensão ou pesquisa com financiamento externo ou interno.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por declaração do Coordenador do projeto ou Diretor da Unidade Acadêmica ou por documento do órgão financiador ou Pró-Reitoria.',
  ),
  ItemAnexo1(
    93,
    'Membro de equipe de projetos de ensino ou extensão ou pesquisa sem financiamento e registrado em Pró-Reitoria.',
    1,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por declaração do Coordenador do projeto ou Diretor da Unidade Acadêmica, ou por Pró-Reitor.',
  ),
  ItemAnexo1(
    94,
    'Curso de extensão, presencial ou a distância, ministrado com aprovação do Conselho da Unidade e registrado na PROEX.',
    1,
    'hora-aula',
    nota:
        'Comprovadas por declaração da Direção da Unidade e número de registro junto à PROEX.',
  ),
  ItemAnexo1(
    95,
    'Coordenação de organização de eventos de ensino e ou extensão abertos à comunidade.',
    5,
    'evento',
    teto: 60,
    nota:
        'Comprovadas por declaração do Diretor da Unidade Acadêmica e número de registro junto à PROEX.',
  ),
  ItemAnexo1(
    96,
    'Membro de equipe de organização de eventos de ensino e ou extensão abertos à comunidade.',
    2,
    'evento',
    teto: 24,
    nota:
        'Comprovadas por declaração do Diretor da Unidade Acadêmica e número de registro junto à PROEX.',
  ),
  ItemAnexo1(
    97,
    'Participação em eventos de ensino e ou extensão abertos à comunidade promovidos por Instituição pública ou privada.',
    0.5,
    'evento',
    nota: 'Comprovadas por declaração do Coordenador do projeto/evento.',
  ),
  ItemAnexo1(
    98,
    'Coordenação e organização de eventos de ensino e ou extensão abertos à comunidade promovidos por Instituição pública ou privada.',
    10,
    'evento',
    nota: 'Comprovadas por declaração da Instituição promotora do evento.',
  ),
  ItemAnexo1(
    99,
    'Consultoria, assessoria, perícia, diagnóstico ou sindicância realizada desde que aprovada pela Unidade.',
    1,
    'hora',
    nota: 'Comprovadas por declaração do Diretor da Unidade.',
  ),
  ItemAnexo1(
    100,
    'Elaboração de projetos técnicos institucionais.',
    30,
    'projeto',
    nota:
        'Cada projeto poderá ser pontuado uma única vez, desde que aprovado pela Unidade.',
  ),
  ItemAnexo1(
    101,
    'Participação nos cursos do Programa de Formação docente da UFU.',
    0.2,
    'hora',
    nota:
        'Serão pontuados os Cursos com o mínimo de 40 horas, comprovado por declaração da DIREN.',
  ),
  ItemAnexo1(
    102,
    'Atendimento às famílias de alunos da Educação Básica.',
    1,
    'mês',
    periodo: _m,
    nota:
        'A comprovação será por meio de declaração do Diretor da Unidade Especial.',
  ),
  // TABELA A1.5 - COM REMUNERAÇÃO SUPLEMENTAR
  ItemAnexo1(
    103,
    'Aula teórica ou prática de componentes curriculares ministrados em cursos de pós-graduação lato sensu ou aperfeiçoamento da UFU, com remuneração suplementar, aprovadas pelo Conselho da Unidade.',
    0.5,
    'hora-aula',
  ),
  ItemAnexo1(
    104,
    'Componente curricular prático de cursos de pós-graduação lato sensu ou aperfeiçoamento da UFU, com remuneração suplementar, para turmas com mais de 8 alunos.',
    0.2,
    'aluno acima de 8',
  ),
  ItemAnexo1(
    105,
    'Curso de extensão ministrado com aprovação do Conselho da Unidade e registrado na PROEX, com remuneração suplementar.',
    0.5,
    'hora-aula',
  ),
  ItemAnexo1(
    106,
    'Consultoria, assessoria, perícia, diagnóstico ou sindicância realizada desde que aprovada pela Unidade, com remuneração suplementar.',
    0.5,
    'hora',
    nota:
        'Serão pontuadas as atividades com relatório final ou laudo e comprovadas por declaração do Diretor da Unidade.',
  ),
  ItemAnexo1(
    107,
    'Elaboração de projetos técnicos institucionais na área de engenharia, arquitetura, urbanismo, design de interiores e comunicação com remuneração suplementar.',
    15,
    'projeto',
    nota:
        'Cada projeto poderá ser pontuado uma única vez, desde que aprovado pela Unidade.',
  ),
  ItemAnexo1(
    108,
    'Coordenação de Curso de Pós-graduação lato sensu ou aperfeiçoamento, com remuneração suplementar.',
    3,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovada por declaração do Diretor ou ata da reunião do Conselho da Unidade.',
  ),
  ItemAnexo1(
    109,
    'Coordenação de projetos de pesquisa, ensino ou extensão com financiamento externo e com remuneração suplementar.',
    5,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por documento de aprovação do projeto pelo órgão de fomento e aprovadas pelo Conselho da Unidade.',
  ),
  ItemAnexo1(
    110,
    'Coordenação de projetos de pesquisa, ensino ou extensão com financiamento interno e registrado em Pró-Reitoria e com remuneração suplementar.',
    3,
    'mês completo',
    periodo: _m,
    nota:
        'Aprovadas pelo Conselho da Unidade e com número de registro junto à respectiva Pró-Reitoria.',
  ),
  ItemAnexo1(
    111,
    'Membro de equipe de projetos de pesquisa, ensino ou extensão com financiamento externo ou interno e com remuneração suplementar.',
    1,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por declaração do Coordenador do projeto ou Diretor da Unidade Acadêmica.',
  ),
  ItemAnexo1(
    112,
    'Membro de comissões externas à UFU, nomeadas por órgãos da administração pública, com remuneração suplementar.',
    5,
    'comissão/representação',
    nota:
        'Ex.: Representante institucional, avaliadores designados pelo MEC/INEP, CAPES, CNPq, FAPEMIG e afins.',
  ),
  ItemAnexo1(
    113,
    'Membro de equipes de órgãos da administração pública conveniados com a UFU, para realização de atividades relacionadas à sua área de atuação, com remuneração suplementar.',
    5,
    'mês completo',
    periodo: _m,
    nota: 'Ex.: BNI, Portal do Professor e semelhantes.',
  ),
  // TABELA A1.6 - ATIVIDADES DE GESTÃO
  ItemAnexo1.fracao(
    114,
    'Reitor, Vice-Reitor, Pró-Reitor, Prefeito Universitário, Diretor Administrativo de Campus e Diretor de Unidade Especial de Ensino.',
    730,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    115,
    'Chefe de Gabinete, Diretor de Unidade, Diretor do Centro de Tecnologia da Informação e Diretor administrativo.',
    900,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    116,
    'Coordenador de Residência Uniprofissional e Multiprofissional, de Curso de Graduação ou de Curso de Pós-graduação stricto sensu ou da Educação Profissional, ou do Comitê de Ética em Pesquisa com Seres Humanos ou Animais, ou Coordenador da Comissão de Biossegurança, ou Presidente da CPPD ou CIARSC, ou Coordenador da COPSIA, ou Coordenadores de Museus.',
    1000,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    117,
    'Coordenação de Curso de Pós-graduação lato sensu ou Coordenador de Extensão que conste no Regimento Interno da Unidade.',
    1200,
    nota:
        'Comprovada por declaração do Diretor ou ata da reunião do Conselho da Unidade.',
  ),
  ItemAnexo1.fracao(
    118,
    'Coordenação pedagógica ou administrativa de áreas de conhecimento e ou estruturas de Unidade Especial de Ensino.',
    1200,
    nota: 'Comprovadas por Declaração do Diretor da Unidade.',
  ),
  ItemAnexo1.fracao(
    119,
    'Diretor Executivo das Fundações Universitárias.',
    1000,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    120,
    'Diretor de Hospital de Clínicas ou de Hospital Veterinário ou de Hospital Odontológico.',
    1000,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    121,
    'Substituições de docentes em cargos de direção.',
    1000,
    nota:
        'Comprovadas por Portaria de homologação do cargo. O substituto legal receberá a pontuação correspondente ao cargo no período que exercê-lo de fato.',
  ),
  ItemAnexo1.fracao(
    122,
    'Diretor de Órgãos Administrativos regulamentados por Resolução do Conselho Universitário (CONSUN) ou Centro de Educação a Distância.',
    1200,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    123,
    'Assessor com CD, FG1, FG2 ou equivalente.',
    1200,
    nota: _obsHomologacao,
  ),
  ItemAnexo1.fracao(
    124,
    'Assessor especial do Ensino Básico, Técnico e tecnológico com CD, FG1, FG2 ou equivalente.',
    1000,
    nota: _obsHomologacao,
  ),
  ItemAnexo1(
    125,
    'Membro de diretoria de órgãos de classe, de organizações de fomento e de organizações não governamentais de expressão reconhecida, desde que relacionado à sua atividade profissional e aprovado pelo Conselho da Unidade.',
    4,
    'mês completo',
    periodo: _m,
    nota: 'Comprovadas por ata da reunião de aprovação no Conselho da Unidade.',
  ),
  ItemAnexo1(
    126,
    'Representante oficial da Unidade junto à Biblioteca, em efetivo exercício.',
    1,
    'mês completo',
    periodo: _m,
  ),
  ItemAnexo1(
    127,
    'Participação como curador de exposições artísticas locais e regionais.',
    10,
    'participação',
  ),
  ItemAnexo1(
    128,
    'Participação como curador de exposições artísticas nacionais.',
    20,
    'participação',
  ),
  ItemAnexo1(
    129,
    'Participação como curador de exposições artísticas internacionais.',
    30,
    'participação',
  ),
  ItemAnexo1(
    130,
    'Participação, em evento de nível local ou regional, como chefe de delegação, membro de comissões técnicas e membro de comissões de avaliações e classificação de equipes esportivas.',
    10,
    'participação',
  ),
  ItemAnexo1(
    131,
    'Participação, em evento de nível nacional, como chefe de delegação, membro de comissões técnicas e membro de comissões de avaliações e classificação de equipes esportivas.',
    20,
    'participação',
  ),
  ItemAnexo1(
    132,
    'Participação, em evento de nível internacional, como chefe de delegação, membro de comissões técnicas e membro de comissões de avaliações e classificação de equipes esportivas.',
    30,
    'participação',
  ),
  ItemAnexo1(
    133,
    'Banca de Concursos Públicos.',
    30,
    'participação',
    nota:
        'A atividade de membro efetivo será comprovada por documentação emitida pelo Diretor da Unidade ou pela Instituição Pública.',
  ),
  ItemAnexo1(
    134,
    'Banca de Processos Seletivos de docentes.',
    20,
    'participação',
    nota:
        'Processos seletivos de docentes com contrato temporário de Universidades e de funcionários de Fundações Universitárias Públicas.',
  ),
  ItemAnexo1(
    135,
    'Banca de Processos Seletivos de discentes.',
    7,
    'participação',
    nota:
        'A atividade de membro efetivo será comprovada por documentação emitida pelo Diretor da Unidade ou pela Instituição Pública.',
  ),
  ItemAnexo1(
    136,
    'Coordenação de laboratórios, Núcleos de Pesquisa, da Clínica Psicológica, da Clínica Odontológica, do Setor de Prática Desportiva e do Setor de Oficina Mecânica.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Coordenações oficializadas por Ordem de Serviço ou Portaria do Diretor da Unidade, com duração superior a três meses.',
  ),
  ItemAnexo1(
    137,
    'Coordenação de Estágio Supervisionado, Trabalho de Conclusão de Curso, de atividade prática curricular profissionalizante e ou Prática de Ensino e Coordenação geral de Internato.',
    10,
    'mês completo',
    periodo: _m,
    nota:
        'Serão pontuadas as atividades nomeadas pelo Diretor da Unidade. (Somente um docente por Curso)',
  ),
  ItemAnexo1(
    138,
    'Tutoria do Programa de Educação Tutorial.',
    20,
    'mês completo',
    periodo: _m,
  ),
  ItemAnexo1(
    139,
    'Participação em Conselhos de Avaliação Discente (Conselho de Classe) das Unidades Especiais de Ensino.',
    2,
    'participação',
  ),
  ItemAnexo1(
    140,
    'Gerente ou Coordenador de área em Unidades Administrativas.',
    4,
    'mês completo',
    periodo: _m,
    nota: _obsHomologacao,
  ),
  ItemAnexo1(
    141,
    'Chefe de setor ou departamento em Unidades Administrativas.',
    3,
    'mês completo',
    periodo: _m,
    nota: _obsHomologacao,
  ),
  ItemAnexo1(
    142,
    'Coordenação de órgão complementar.',
    4,
    'mês completo',
    periodo: _m,
  ),
  ItemAnexo1(
    143,
    'Coordenação de Programa de Educação Continuada e coordenação institucional de programas de bolsas de iniciação à docência, de educação tutorial, de extensão e de bolsas de iniciação científica e similares.',
    20,
    'mês completo',
    periodo: _m,
    nota: _obsHomologacao,
  ),
  ItemAnexo1(
    144,
    'Coordenador de Projeto de Intercâmbio Internacional, nomeado por Portaria.',
    1,
    'mês completo/projeto',
    periodo: _m,
  ),
  ItemAnexo1(
    145,
    'Membro de Comissão Permanente da UFU.',
    10,
    'mês completo/comissão',
    periodo: _m,
    nota: 'Serão pontuadas as atividades administrativas nomeadas pelo Reitor.',
  ),
  ItemAnexo1(
    146,
    'Membro de comissões de ética, de infecção hospitalar, de residência médica (COREME), Residência Multiprofissional (COREMU) e padronização de medicamentos permanente da UFU.',
    5,
    'mês completo/comissão',
    periodo: _m,
  ),
  ItemAnexo1(
    147,
    'Membro do Comitê de Ética em Pesquisa com Seres Humanos ou do Comitê de Ética na Utilização de Animais.',
    15,
    'mês completo',
    periodo: _m,
    alteradoPor: 'Res. SEI 05/2018',
  ),
  ItemAnexo1(
    148,
    'Representante de Unidade Acadêmica ou de Unidade Especial de Ensino em Associação Docente (ADUFU).',
    2,
    'mês completo',
    periodo: _m,
  ),
  ItemAnexo1(
    149,
    'Membro de comissões externas à Unidade, nomeadas pela Administração Superior da UFU ou por órgãos da administração pública.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Serão consideradas as comissões nomeadas por Portarias das Pró-Reitorias, Reitoria e da administração pública.',
  ),
  ItemAnexo1(
    150,
    'Membro de comitê assessor de agência de fomento ou comitê permanente de programas institucionais (PET e outros).',
    10,
    'mês completo',
    periodo: _m,
    nota:
        'Serão pontuadas as participações comprovadas por documento de nomeação ou declaração da presidência do comitê.',
    alteradoPor: 'Res. SEI 05/2018',
  ),
  ItemAnexo1(
    151,
    'Coordenação de estruturas criadas na Unidade, de acordo com o Regimento Interno da mesma.',
    2,
    'mês completo',
    periodo: _m,
    nota: 'Serão limitadas as participações em até três cargos por semestre.',
  ),
  ItemAnexo1(
    152,
    'Membro de Conselhos na UFU.',
    1,
    'mês completo/conselho',
    periodo: _m,
    nota:
        'A participação como membro de Conselho com cargos de CD ou FG não deve ser pontuada neste item.',
  ),
  ItemAnexo1(
    153,
    'Membro de Comissão Permanente da Unidade.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Serão pontuadas as atividades comprovadas por Portaria de nomeação da comissão pelo Diretor da Unidade.',
  ),
  ItemAnexo1(
    154,
    'Membro de Colegiado ou Conselho das Unidades Especiais de Ensino, de Curso de Graduação ou de Programa de Pós-graduação.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por documento de homologação do cargo ou por declaração do Diretor da Unidade.',
  ),
  ItemAnexo1(
    155,
    'Membro de NDE - Núcleo Docente Estruturante de Curso de Graduação.',
    2,
    'mês completo',
    periodo: _m,
    nota:
        'Comprovadas por documento de homologação do cargo ou por declaração do Diretor da Unidade.',
  ),
  ItemAnexo1(
    156,
    'Presidente, em efetivo exercício, de diretoria de associação científica relacionada à sua área profissional.',
    1,
    'mês completo',
    periodo: _m,
  ),
  ItemAnexo1(
    157,
    'Membro, em efetivo exercício, de diretoria de associação científica relacionada à sua área profissional.',
    0.5,
    'mês completo',
    periodo: _m,
  ),
  ItemAnexo1(
    158,
    'Membro de comissões internas de Unidade.',
    2,
    'comissão específica ou mês (comissão permanente)',
    nota: 'A pontuação deve ser comprovada por Ordem de Serviço ou Portaria.',
    alteradoPor: 'Res. SEI 05/2018',
  ),
  ItemAnexo1(
    159,
    'Participação em ações de formação continuada para docentes (Rodas de conversa, programas de integração, oficinas, minicursos e similares) promovidas pela Unidade, setores da Instituição (PROGRAD/PROGEP) e órgãos oficiais.',
    0.5,
    'hora',
  ),
  ItemAnexo1(
    160,
    'Ministrar palestras, curso ou oficinas em programas de formação continuada para docentes ou técnicos administrativos da Instituição, promovidas pelas Pró-Reitorias.',
    1,
    'hora',
  ),
  ItemAnexo1(
    161,
    'Parecer emitido em conselhos superiores.',
    10,
    'parecer',
    nota:
        'A participação será comprovada por documento emitido pela presidência do conselho.',
  ),
  ItemAnexo1(
    162,
    'Parecer emitido em conselhos das Unidades.',
    5,
    'parecer',
    nota:
        'A participação será comprovada por documento emitido pelo Diretor da Unidade.',
  ),
  // TABELA A1.7 - LICENÇAS, SITUAÇÕES ESPECIAIS E AFASTAMENTOS
  ItemAnexo1.fracao(
    163,
    'Licenças de concessão obrigatória (prêmio, gestante, saúde e outras) ou capacitação.',
    730,
    nota:
        'A comprovação da licença será feita por declaração dos órgãos competentes da UFU.',
  ),
  ItemAnexo1.fracao(
    164,
    'Readaptação funcional.',
    730,
    nota:
        'A comprovação será feita por declaração dos órgãos competentes da UFU.',
  ),
  ItemAnexo1.fracao(
    165,
    'Situação especial para o docente servidor cedido para exercício de cargo de natureza especial; DAS 6, 5 ou 4, ou cargo equivalente na Administração Pública Municipal, Estadual ou Federal.',
    730,
  ),
  ItemAnexo1.fracao(
    166,
    'Afastamento integral para cursar pós-graduação em nível de Mestrado, Doutorado, Pós-doutorado ou para atuar como Professor Visitante em outra Instituição de Ensino Superior.',
    730,
    nota:
        'Aprovado pelo Conselho da Unidade e comprovado por ata ou declaração do Diretor e relatório aprovado pelo Conselho da Unidade.',
  ),
  ItemAnexo1.fracao(
    167,
    'Afastamento temporário, inferior a 120 dias, para estágio técnico, aperfeiçoamento ou missão de trabalho.',
    730,
    nota:
        'Aprovado pela Unidade e comprovado por ata ou declaração do Diretor e relatório aprovado pelo Conselho da Unidade.',
  ),
];

ItemAnexo1? itemAnexo1(int numero) {
  for (final item in anexo1) {
    if (item.numero == numero) return item;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Anexos 2 e 3 — pontuação de referência por carreira, classe, nível e regime.
// ---------------------------------------------------------------------------

enum Carreira {
  magisterioSuperior('Magistério Superior'),
  ebtt('Ensino Básico, Técnico e Tecnológico');

  const Carreira(this.rotulo);
  final String rotulo;
}

enum Regime {
  de('Dedicação Exclusiva', '40 horas DE'),
  h40('40 horas', '40 horas'),
  h20('20 horas', '20 horas');

  const Regime(this.rotulo, this.textoRelatorio);
  final String rotulo;
  final String textoRelatorio;
}

enum Titulacao {
  graduacao('G, A ou E', 'graduado, aperfeiçoado ou especialista'),
  mestrado('M', 'mestre'),
  doutorado('D', 'doutor');

  const Titulacao(this.sigla, this.rotulo);
  final String sigla;
  final String rotulo;
}

/// Posição na carreira (classe + nível).
class PosicaoCarreira {
  const PosicaoCarreira(this.carreira, this.classe, this.nivel);

  final Carreira carreira;

  /// MS: A, B, C, D, E. EBTT: D I, D II, D III, D IV, Titular.
  final String classe;

  /// MS: I..IV. EBTT: 1..4. Vazio para Titular.
  final String nivel;

  String get id => '${carreira.name}|$classe|$nivel';

  bool get titular => classe == 'E' || classe == 'Titular';

  /// Ex.: "Associado III", "Adjunto A II", "D IV 2", "Titular".
  String denominacao(Titulacao titulacao) {
    if (carreira == Carreira.ebtt) {
      return titular ? 'Titular' : '$classe nível $nivel';
    }
    final nome = switch (classe) {
      'A' => switch (titulacao) {
        Titulacao.graduacao => 'Auxiliar',
        Titulacao.mestrado => 'Assistente A',
        Titulacao.doutorado => 'Adjunto A',
      },
      'B' => 'Assistente',
      'C' => 'Adjunto',
      'D' => 'Associado',
      _ => 'Titular',
    };
    return titular ? nome : '$nome $nivel';
  }

  /// Ex.: "classe D nível III", "classe D IV nível 2", "classe Titular".
  String get descricaoClasseNivel {
    if (titular) {
      return carreira == Carreira.ebtt
          ? 'classe Titular'
          : 'classe E (Titular)';
    }
    return 'classe $classe nível $nivel';
  }
}

const _niveisRomanos = ['I', 'II', 'III', 'IV'];

/// Sequência de posições de cada carreira, na ordem de desenvolvimento.
List<PosicaoCarreira> posicoesCarreira(Carreira carreira) {
  if (carreira == Carreira.magisterioSuperior) {
    return [
      for (final n in ['I', 'II']) PosicaoCarreira(carreira, 'A', n),
      for (final n in ['I', 'II']) PosicaoCarreira(carreira, 'B', n),
      for (final n in _niveisRomanos) PosicaoCarreira(carreira, 'C', n),
      for (final n in _niveisRomanos) PosicaoCarreira(carreira, 'D', n),
      PosicaoCarreira(carreira, 'E', ''),
    ];
  }
  return [
    for (final n in ['1', '2']) PosicaoCarreira(carreira, 'D I', n),
    for (final n in ['1', '2']) PosicaoCarreira(carreira, 'D II', n),
    for (final n in ['1', '2', '3', '4']) PosicaoCarreira(carreira, 'D III', n),
    for (final n in ['1', '2', '3', '4']) PosicaoCarreira(carreira, 'D IV', n),
    PosicaoCarreira(carreira, 'Titular', ''),
  ];
}

/// Posições que podem ser alvo de uma avaliação (todas exceto a primeira).
List<PosicaoCarreira> posicoesAlvo(Carreira carreira) =>
    posicoesCarreira(carreira).skip(1).toList();

PosicaoCarreira? posicaoAnterior(PosicaoCarreira alvo) {
  final lista = posicoesCarreira(alvo.carreira);
  final index = lista.indexWhere((p) => p.id == alvo.id);
  return index > 0 ? lista[index - 1] : null;
}

PosicaoCarreira? posicaoPorId(String id) {
  for (final carreira in Carreira.values) {
    for (final p in posicoesCarreira(carreira)) {
      if (p.id == id) return p;
    }
  }
  return null;
}

// Linhas: G/A/E, M, D. Colunas: níveis da classe.
const _msTempoIntegral = <String, List<List<int?>>>{
  'A': [
    [null, 600],
    [null, 610],
    [null, 630],
  ],
  'B': [
    [620, 630],
    [630, 650],
    [650, 670],
  ],
  'C': [
    [640, 650, 660, 670],
    [660, 680, 700, 720],
    [700, 730, 760, 790],
  ],
  'D': [
    [null, null, null, null],
    [null, null, null, null],
    [840, 880, 920, 960],
  ],
  'E': [
    [null],
    [null],
    [1000],
  ],
};

const _ms20h = <String, List<List<int?>>>{
  'A': [
    [null, 300],
    [null, 305],
    [null, 310],
  ],
  'B': [
    [305, 310],
    [310, 315],
    [315, 320],
  ],
  'C': [
    [320, 325, 330, 335],
    [320, 330, 340, 350],
    [330, 340, 350, 360],
  ],
  'D': [
    [null, null, null, null],
    [null, null, null, null],
    [370, 380, 390, 400],
  ],
  'E': [
    [null],
    [null],
    [420],
  ],
};

const _ebttDe = <String, List<List<int?>>>{
  'D I': [
    [null, 600],
    [null, 610],
    [null, 630],
  ],
  'D II': [
    [620, 630],
    [630, 650],
    [650, 670],
  ],
  'D III': [
    [640, 650, 660, 670],
    [660, 680, 700, 720],
    [700, 730, 760, 790],
  ],
  'D IV': [
    [700, 730, 760, 790],
    [760, 800, 840, 880],
    [840, 880, 920, 960],
  ],
  'Titular': [
    [null],
    [null],
    [1000],
  ],
};

const _ebtt20h = <String, List<List<int?>>>{
  'D I': [
    [null, 300],
    [null, 305],
    [null, 310],
  ],
  'D II': [
    [305, 310],
    [310, 315],
    [315, 320],
  ],
  'D III': [
    [320, 325, 330, 335],
    [320, 330, 340, 350],
    [330, 340, 350, 360],
  ],
  'D IV': [
    [330, 340, 350, 360],
    [350, 360, 370, 380],
    [370, 380, 390, 400],
  ],
  'Titular': [
    [null],
    [null],
    [420],
  ],
};

int _nivelIndex(String nivel) {
  final romano = _niveisRomanos.indexOf(nivel);
  if (romano >= 0) return romano;
  final n = int.tryParse(nivel);
  return n == null ? 0 : n - 1;
}

/// Pontuação de referência (mínima) para chegar à posição [alvo].
/// Retorna `null` quando a combinação não existe nas tabelas.
int? pontuacaoReferencia({
  required PosicaoCarreira alvo,
  required Regime regime,
  required Titulacao titulacao,
}) {
  final tabela = switch ((alvo.carreira, regime)) {
    (Carreira.magisterioSuperior, Regime.h20) => _ms20h,
    (Carreira.magisterioSuperior, _) => _msTempoIntegral,
    (Carreira.ebtt, Regime.h20) => _ebtt20h,
    // O Anexo 3 só traz DE e 20h; 40h usa a tabela de tempo integral.
    (Carreira.ebtt, _) => _ebttDe,
  };
  final linhas = tabela[alvo.classe];
  if (linhas == null) return null;
  final linha = linhas[titulacao.index];
  final coluna = alvo.titular ? 0 : _nivelIndex(alvo.nivel);
  if (coluna < 0 || coluna >= linha.length) return null;
  return linha[coluna];
}

/// Artigo da Resolução que rege a avaliação para a posição alvo.
String artigoAvaliacao(PosicaoCarreira alvo) {
  if (alvo.titular) {
    return alvo.carreira == Carreira.ebtt ? 'art. 8º' : 'art. 7º';
  }
  if (alvo.carreira == Carreira.magisterioSuperior && alvo.classe == 'D') {
    return 'art. 6º';
  }
  return 'art. 5º';
}

/// Tabela do Anexo com a pontuação de referência.
String tabelaReferencia(Carreira carreira, Regime regime) {
  if (carreira == Carreira.magisterioSuperior) {
    return regime == Regime.h20 ? 'Tabela A2.2' : 'Tabela A2.1';
  }
  return regime == Regime.h20 ? 'Tabela A3.2' : 'Tabela A3.1';
}
