/// Seções do corpo do parecer, cada uma editada numa aba.
enum ParecerSecao {
  relatorio('relatorio', 'I. RELATÓRIO'),
  fundamentacao('fundamentacao', 'II. FUNDAMENTAÇÃO E ANÁLISE'),
  conclusao('conclusao', 'III. CONCLUSÃO');

  const ParecerSecao(this.id, this.titulo);

  final String id;

  /// Título da seção no documento (e da aba).
  final String titulo;

  static ParecerSecao? porId(String id) =>
      values.where((s) => s.id == id).firstOrNull;
}

/// Rascunho do parecer: os campos do modelo "Parecer" do SEI e o HTML de
/// cada seção (o mesmo HTML do editor do SEI, com as classes de estilo).
///
/// O cabeçalho (PARECER Nº, PROCESSO Nº, INTERESSADO(S)) é preenchido pelo
/// próprio SEI e não faz parte do rascunho.
class Parecer {
  const Parecer({
    this.assunto = '',
    this.ementa = '',
    this.vocativo = 'Senhor Presidente,\nSenhores(as) Conselheiros(as),',
    this.abertura = '',
    this.relatorio = '',
    this.fundamentacao = '',
    this.conclusao = '',
    this.fecho = 'À consideração superior.',
    this.nomeSignatario = '',
    this.cargoSignatario = '',
    this.descricaoSei = '',
  });

  /// Linha "ASSUNTO:" da tabela do modelo.
  final String assunto;

  /// Ementa (célula à direita, abaixo do assunto).
  final String ementa;

  /// Uma linha por vocativo ("Senhor Presidente,").
  final String vocativo;

  /// Parágrafos de abertura, antes de "I. RELATÓRIO" (um por linha).
  final String abertura;

  final String relatorio;
  final String fundamentacao;
  final String conclusao;

  /// Fecho ("À consideração superior.").
  final String fecho;
  final String nomeSignatario;
  final String cargoSignatario;

  /// Descrição do documento no SEI (metadados ao gerar o documento).
  final String descricaoSei;

  String secao(ParecerSecao s) => switch (s) {
    ParecerSecao.relatorio => relatorio,
    ParecerSecao.fundamentacao => fundamentacao,
    ParecerSecao.conclusao => conclusao,
  };

  Parecer comSecao(ParecerSecao s, String html) => copyWith(
    relatorio: s == ParecerSecao.relatorio ? html : null,
    fundamentacao: s == ParecerSecao.fundamentacao ? html : null,
    conclusao: s == ParecerSecao.conclusao ? html : null,
  );

  Parecer copyWith({
    String? assunto,
    String? ementa,
    String? vocativo,
    String? abertura,
    String? relatorio,
    String? fundamentacao,
    String? conclusao,
    String? fecho,
    String? nomeSignatario,
    String? cargoSignatario,
    String? descricaoSei,
  }) => Parecer(
    assunto: assunto ?? this.assunto,
    ementa: ementa ?? this.ementa,
    vocativo: vocativo ?? this.vocativo,
    abertura: abertura ?? this.abertura,
    relatorio: relatorio ?? this.relatorio,
    fundamentacao: fundamentacao ?? this.fundamentacao,
    conclusao: conclusao ?? this.conclusao,
    fecho: fecho ?? this.fecho,
    nomeSignatario: nomeSignatario ?? this.nomeSignatario,
    cargoSignatario: cargoSignatario ?? this.cargoSignatario,
    descricaoSei: descricaoSei ?? this.descricaoSei,
  );

  factory Parecer.fromJson(Map<String, dynamic> json) {
    String s(String k, String padrao) =>
        json.containsKey(k) ? '${json[k] ?? ''}' : padrao;
    const vazio = Parecer();
    return Parecer(
      assunto: s('assunto', vazio.assunto),
      ementa: s('ementa', vazio.ementa),
      vocativo: s('vocativo', vazio.vocativo),
      abertura: s('abertura', vazio.abertura),
      relatorio: s('relatorio', vazio.relatorio),
      fundamentacao: s('fundamentacao', vazio.fundamentacao),
      conclusao: s('conclusao', vazio.conclusao),
      fecho: s('fecho', vazio.fecho),
      nomeSignatario: s('nome_signatario', vazio.nomeSignatario),
      cargoSignatario: s('cargo_signatario', vazio.cargoSignatario),
      descricaoSei: s('descricao_sei', vazio.descricaoSei),
    );
  }

  Map<String, dynamic> toJson() => {
    'assunto': assunto,
    'ementa': ementa,
    'vocativo': vocativo,
    'abertura': abertura,
    'relatorio': relatorio,
    'fundamentacao': fundamentacao,
    'conclusao': conclusao,
    'fecho': fecho,
    'nome_signatario': nomeSignatario,
    'cargo_signatario': cargoSignatario,
    'descricao_sei': descricaoSei,
  };
}
