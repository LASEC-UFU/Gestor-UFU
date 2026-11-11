import 'package:gestor_ufu/domain/progressao/resolucao_condir_03_2017.dart';

/// Uma linha do relatório: atividade comprovada e pontuada por um item do
/// Anexo 1 da Resolução 03/2017.
class LancamentoProgressao {
  const LancamentoProgressao({
    required this.id,
    required this.item,
    this.periodo = '',
    this.descricao = '',
    this.comprovante = '',
    this.quantidade = 0,
    this.inicio,
    this.fim,
  });

  final String id;
  final int item;

  /// Semestre ou período (ex.: 2023/01).
  final String periodo;
  final String descricao;

  /// Nome do arquivo/documento comprobatório anexado ao SEI.
  final String comprovante;

  /// Horas, meses, alunos, trabalhos, dias... conforme a unidade do item.
  final double quantidade;
  final DateTime? inicio;
  final DateTime? fim;

  LancamentoProgressao copyWith({
    int? item,
    String? periodo,
    String? descricao,
    String? comprovante,
    double? quantidade,
    DateTime? inicio,
    DateTime? fim,
    bool limparDatas = false,
  }) => LancamentoProgressao(
    id: id,
    item: item ?? this.item,
    periodo: periodo ?? this.periodo,
    descricao: descricao ?? this.descricao,
    comprovante: comprovante ?? this.comprovante,
    quantidade: quantidade ?? this.quantidade,
    inicio: limparDatas ? null : inicio ?? this.inicio,
    fim: limparDatas ? null : fim ?? this.fim,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'item': item,
    'periodo': periodo,
    'descricao': descricao,
    'comprovante': comprovante,
    'quantidade': quantidade,
    'inicio': inicio?.toIso8601String(),
    'fim': fim?.toIso8601String(),
  };

  factory LancamentoProgressao.fromJson(Map<String, dynamic> json) =>
      LancamentoProgressao(
        id: json['id'] as String? ?? '',
        item: (json['item'] as num?)?.toInt() ?? 1,
        periodo: json['periodo'] as String? ?? '',
        descricao: json['descricao'] as String? ?? '',
        comprovante: json['comprovante'] as String? ?? '',
        quantidade: (json['quantidade'] as num?)?.toDouble() ?? 0,
        inicio: DateTime.tryParse(json['inicio'] as String? ?? ''),
        fim: DateTime.tryParse(json['fim'] as String? ?? ''),
      );
}

/// Processo de progressão/promoção de um docente.
class ProgressaoDocente {
  const ProgressaoDocente({
    required this.id,
    this.docente = '',
    this.siape = '',
    this.lotacao = '',
    this.destinatario = '',
    this.cidade = 'Uberlândia',
    this.dataDocumento,
    this.carreira = Carreira.magisterioSuperior,
    this.regime = Regime.de,
    this.titulacao = Titulacao.doutorado,
    this.alvoId = 'magisterioSuperior|D|II',
    this.intersticioInicio,
    this.intersticioFim,
    this.relatorioInicio,
    this.relatorioFim,
    this.semestres = '',
    this.textoAssiduidade = textoAssiduidadePadrao,
    this.textoAvaliacaoDidatica = textoAvaliacaoDidaticaPadrao,
    this.avaliacoesDidaticas = const [],
    this.textoAvaliacaoConclusao = textoAvaliacaoConclusaoPadrao,
    this.logoPath = '',
    this.lancamentos = const [],
    this.atualizadoEm,
  });

  static const textoAssiduidadePadrao =
      'Neste sentido, tenho a informar que sou assíduo, pontual e sempre cumpri com '
      'responsabilidade minhas atividades. A qualidade do trabalho pode ser atestada pelos '
      'desenvolvimentos no período, seja nas atividades de ensino, pesquisa, extensão ou '
      'administração.';

  static const textoAvaliacaoDidaticaPadrao =
      'A Pró-reitoria de Graduação (PROGRAD) disponibiliza no sítio '
      'www.avaliacaodocente.ufu.br/docente uma avaliação realizada pelo corpo discente, '
      'com as avaliações de cada disciplina cursada em cada semestre letivo. '
      'Das disciplinas ministradas no interstício, as abaixo listadas foram avaliadas pelos discentes.';

  static const textoAvaliacaoConclusaoPadrao =
      'De uma forma geral, as avaliações foram positivas e, diante dos resultados, acredito que '
      'meu desempenho didático, avaliado pelo corpo discente, está adequado às exigências das '
      'disciplinas ministradas. Não obstante a esta afirmação, as sugestões, reclamações e pontos '
      'negativos relatados são de fundamental importância para melhorar meu desempenho e, '
      'portanto, são sempre investigados e ajustados.';

  final String id;
  final String docente;
  final String siape;

  /// Unidade de lotação (ex.: Faculdade de Engenharia Elétrica).
  final String lotacao;

  /// Destinatário do requerimento (ex.: Diretor da Faculdade ... Prof. Dr. ...).
  final String destinatario;
  final String cidade;
  final DateTime? dataDocumento;
  final Carreira carreira;
  final Regime regime;
  final Titulacao titulacao;
  final String alvoId;
  final DateTime? intersticioInicio;
  final DateTime? intersticioFim;
  final DateTime? relatorioInicio;
  final DateTime? relatorioFim;
  final String semestres;
  final String textoAssiduidade;
  final String textoAvaliacaoDidatica;
  final List<String> avaliacoesDidaticas;
  final String textoAvaliacaoConclusao;

  /// Imagem opcional (PNG/JPG) exibida no cabeçalho das páginas do PDF.
  final String logoPath;
  final List<LancamentoProgressao> lancamentos;
  final DateTime? atualizadoEm;

  PosicaoCarreira get alvo =>
      posicaoPorId(alvoId) ?? posicoesAlvo(carreira).first;

  PosicaoCarreira? get atual => posicaoAnterior(alvo);

  /// Promoção quando muda de classe; progressão dentro da mesma classe.
  bool get promocao => atual == null || atual!.classe != alvo.classe;

  String get tipoMovimento => promocao ? 'promoção' : 'progressão';

  int? get referencia =>
      pontuacaoReferencia(alvo: alvo, regime: regime, titulacao: titulacao);

  double get _referenciaCalculo => (referencia ?? 0).toDouble();

  double pontosLancamento(LancamentoProgressao l) {
    final item = itemAnexo1(l.item);
    if (item == null) return 0;
    return l.quantidade * item.valorUnitario(_referenciaCalculo);
  }

  List<LancamentoProgressao> lancamentosDoItem(int numero) =>
      lancamentos.where((l) => l.item == numero).toList();

  /// Itens com lançamentos, em ordem numérica.
  List<int> itensUsados([TabelaAnexo1? tabela]) {
    final set = <int>{
      for (final l in lancamentos)
        if (tabela == null || TabelaAnexo1.doItem(l.item) == tabela) l.item,
    };
    return set.toList()..sort();
  }

  /// Soma bruta dos lançamentos do item (sem teto).
  double pontosBrutosItem(int numero) =>
      lancamentosDoItem(numero).fold(0, (sum, l) => sum + pontosLancamento(l));

  /// Pontos do item respeitando o limite do Anexo 1, quando houver.
  double pontosItem(int numero) {
    final bruto = pontosBrutosItem(numero);
    final teto = itemAnexo1(numero)?.teto;
    return teto != null && bruto > teto ? teto : bruto;
  }

  double totalTabela(TabelaAnexo1 tabela) =>
      itensUsados(tabela).fold(0, (sum, n) => sum + pontosItem(n));

  double get total =>
      TabelaAnexo1.values.fold(0, (sum, t) => sum + totalTabela(t));

  bool get atingeReferencia => referencia != null && total >= referencia!;

  ProgressaoDocente copyWith({
    String? docente,
    String? siape,
    String? lotacao,
    String? destinatario,
    String? cidade,
    DateTime? dataDocumento,
    Carreira? carreira,
    Regime? regime,
    Titulacao? titulacao,
    String? alvoId,
    DateTime? intersticioInicio,
    DateTime? intersticioFim,
    DateTime? relatorioInicio,
    DateTime? relatorioFim,
    String? semestres,
    String? textoAssiduidade,
    String? textoAvaliacaoDidatica,
    List<String>? avaliacoesDidaticas,
    String? textoAvaliacaoConclusao,
    String? logoPath,
    List<LancamentoProgressao>? lancamentos,
    DateTime? atualizadoEm,
  }) => ProgressaoDocente(
    id: id,
    docente: docente ?? this.docente,
    siape: siape ?? this.siape,
    lotacao: lotacao ?? this.lotacao,
    destinatario: destinatario ?? this.destinatario,
    cidade: cidade ?? this.cidade,
    dataDocumento: dataDocumento ?? this.dataDocumento,
    carreira: carreira ?? this.carreira,
    regime: regime ?? this.regime,
    titulacao: titulacao ?? this.titulacao,
    alvoId: alvoId ?? this.alvoId,
    intersticioInicio: intersticioInicio ?? this.intersticioInicio,
    intersticioFim: intersticioFim ?? this.intersticioFim,
    relatorioInicio: relatorioInicio ?? this.relatorioInicio,
    relatorioFim: relatorioFim ?? this.relatorioFim,
    semestres: semestres ?? this.semestres,
    textoAssiduidade: textoAssiduidade ?? this.textoAssiduidade,
    textoAvaliacaoDidatica:
        textoAvaliacaoDidatica ?? this.textoAvaliacaoDidatica,
    avaliacoesDidaticas: avaliacoesDidaticas ?? this.avaliacoesDidaticas,
    textoAvaliacaoConclusao:
        textoAvaliacaoConclusao ?? this.textoAvaliacaoConclusao,
    logoPath: logoPath ?? this.logoPath,
    lancamentos: lancamentos ?? this.lancamentos,
    atualizadoEm: atualizadoEm ?? this.atualizadoEm,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'docente': docente,
    'siape': siape,
    'lotacao': lotacao,
    'destinatario': destinatario,
    'cidade': cidade,
    'dataDocumento': dataDocumento?.toIso8601String(),
    'carreira': carreira.name,
    'regime': regime.name,
    'titulacao': titulacao.name,
    'alvoId': alvoId,
    'intersticioInicio': intersticioInicio?.toIso8601String(),
    'intersticioFim': intersticioFim?.toIso8601String(),
    'relatorioInicio': relatorioInicio?.toIso8601String(),
    'relatorioFim': relatorioFim?.toIso8601String(),
    'semestres': semestres,
    'textoAssiduidade': textoAssiduidade,
    'textoAvaliacaoDidatica': textoAvaliacaoDidatica,
    'avaliacoesDidaticas': avaliacoesDidaticas,
    'textoAvaliacaoConclusao': textoAvaliacaoConclusao,
    'logoPath': logoPath,
    'lancamentos': lancamentos.map((l) => l.toJson()).toList(),
    'atualizadoEm': atualizadoEm?.toIso8601String(),
  };

  factory ProgressaoDocente.fromJson(Map<String, dynamic> json) {
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    DateTime? date(String key) => DateTime.tryParse(json[key] as String? ?? '');
    return ProgressaoDocente(
      id: json['id'] as String? ?? '',
      docente: json['docente'] as String? ?? '',
      siape: json['siape'] as String? ?? '',
      lotacao: json['lotacao'] as String? ?? '',
      destinatario: json['destinatario'] as String? ?? '',
      cidade: json['cidade'] as String? ?? 'Uberlândia',
      dataDocumento: date('dataDocumento'),
      carreira: byName(
        Carreira.values,
        json['carreira'],
        Carreira.magisterioSuperior,
      ),
      regime: byName(Regime.values, json['regime'], Regime.de),
      titulacao: byName(
        Titulacao.values,
        json['titulacao'],
        Titulacao.doutorado,
      ),
      alvoId: json['alvoId'] as String? ?? 'magisterioSuperior|D|II',
      intersticioInicio: date('intersticioInicio'),
      intersticioFim: date('intersticioFim'),
      relatorioInicio: date('relatorioInicio'),
      relatorioFim: date('relatorioFim'),
      semestres: json['semestres'] as String? ?? '',
      textoAssiduidade:
          json['textoAssiduidade'] as String? ?? textoAssiduidadePadrao,
      textoAvaliacaoDidatica:
          json['textoAvaliacaoDidatica'] as String? ??
          textoAvaliacaoDidaticaPadrao,
      avaliacoesDidaticas: (json['avaliacoesDidaticas'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      textoAvaliacaoConclusao:
          json['textoAvaliacaoConclusao'] as String? ??
          textoAvaliacaoConclusaoPadrao,
      logoPath: json['logoPath'] as String? ?? '',
      lancamentos: (json['lancamentos'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (e) => LancamentoProgressao.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(),
      atualizadoEm: date('atualizadoEm'),
    );
  }
}

/// Meses completos entre duas datas, contando o dia final (ex.: 01/06 a 30/11 = 6).
int mesesCompletos(DateTime inicio, DateTime fim) {
  final a = DateTime(inicio.year, inicio.month, inicio.day);
  final b = DateTime(fim.year, fim.month, fim.day).add(const Duration(days: 1));
  if (!b.isAfter(a)) return 0;
  var meses = (b.year - a.year) * 12 + (b.month - a.month);
  if (b.day < a.day) meses--;
  return meses < 0 ? 0 : meses;
}

/// Dias entre duas datas, como o DATEDIF(...;"d") do Excel.
int diasEntre(DateTime inicio, DateTime fim) {
  final a = DateTime.utc(inicio.year, inicio.month, inicio.day);
  final b = DateTime.utc(fim.year, fim.month, fim.day);
  final dias = b.difference(a).inDays;
  return dias < 0 ? 0 : dias;
}
