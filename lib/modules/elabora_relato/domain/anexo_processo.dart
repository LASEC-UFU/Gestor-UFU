/// Cores das marcações (nome guardado → cor ARGB).
const coresMarcacao = <String, int>{
  'amarelo': 0xFFFFF176,
  'verde': 0xFFAED581,
  'azul': 0xFF81D4FA,
  'rosa': 0xFFF48FB1,
  'laranja': 0xFFFFB74D,
};

/// Marcação num documento anexado: um trecho de um parágrafo, com cor e,
/// opcionalmente, comentário e a explicação dada pela IA.
class MarcacaoAnexo {
  const MarcacaoAnexo({
    required this.id,
    required this.paragrafo,
    required this.inicio,
    required this.fim,
    required this.texto,
    this.cor = 'amarelo',
    this.comentario = '',
    this.explicacaoIa = '',
    this.pergunta = '',
    this.criadoEm,
    this.atualizadoEm,
  });

  final String id;

  /// Índice (0, 1, …) do parágrafo no texto extraído do documento.
  final int paragrafo;

  /// Posição do trecho dentro do parágrafo.
  final int inicio;
  final int fim;

  /// Texto marcado (para conferir e relocalizar).
  final String texto;
  final String cor;
  final String comentario;

  /// Resposta da IA guardada com a marcação.
  final String explicacaoIa;

  /// Pergunta feita à IA sobre o trecho.
  final String pergunta;
  final DateTime? criadoEm;
  final DateTime? atualizadoEm;

  MarcacaoAnexo copyWith({
    String? cor,
    String? comentario,
    String? explicacaoIa,
    String? pergunta,
  }) => MarcacaoAnexo(
    id: id,
    paragrafo: paragrafo,
    inicio: inicio,
    fim: fim,
    texto: texto,
    cor: cor ?? this.cor,
    comentario: comentario ?? this.comentario,
    explicacaoIa: explicacaoIa ?? this.explicacaoIa,
    pergunta: pergunta ?? this.pergunta,
    criadoEm: criadoEm,
    atualizadoEm: DateTime.now(),
  );

  factory MarcacaoAnexo.fromJson(Map<String, dynamic> j) => MarcacaoAnexo(
    id: '${j['id'] ?? ''}',
    paragrafo: (j['paragrafo'] as num?)?.toInt() ?? 0,
    inicio: (j['inicio'] as num?)?.toInt() ?? 0,
    fim: (j['fim'] as num?)?.toInt() ?? 0,
    texto: '${j['texto'] ?? ''}',
    cor: coresMarcacao.containsKey(j['cor']) ? '${j['cor']}' : 'amarelo',
    comentario: '${j['comentario'] ?? ''}',
    explicacaoIa: '${j['explicacao_ia'] ?? ''}',
    pergunta: '${j['pergunta'] ?? ''}',
    criadoEm: DateTime.tryParse('${j['criado_em'] ?? ''}'),
    atualizadoEm: DateTime.tryParse('${j['atualizado_em'] ?? ''}'),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'paragrafo': paragrafo,
    'inicio': inicio,
    'fim': fim,
    'texto': texto,
    'cor': cor,
    if (comentario.isNotEmpty) 'comentario': comentario,
    if (explicacaoIa.isNotEmpty) 'explicacao_ia': explicacaoIa,
    if (pergunta.isNotEmpty) 'pergunta': pergunta,
    if (criadoEm != null) 'criado_em': criadoEm!.toIso8601String(),
    if (atualizadoEm != null) 'atualizado_em': atualizadoEm!.toIso8601String(),
  };
}

/// Documento do processo anexado para leitura (não é editado): uma cópia
/// guardada pelo Gestor, o texto extraído (em cache) e as marcações.
class AnexoProcesso {
  const AnexoProcesso({
    required this.id,
    required this.nome,
    required this.hash,
    required this.extensao,
    this.origem = '',
    this.paginas = 0,
    this.paragrafos = 0,
    this.aviso = '',
    this.anexadoEm,
    this.marcacoes = const [],
  });

  final String id;

  /// Nome exibido (o nome do arquivo, editável).
  final String nome;

  /// SHA-1 do conteúdo: nome da cópia guardada e do cache de texto.
  final String hash;

  /// ".pdf", ".docx"…
  final String extensao;

  /// Caminho de onde o arquivo foi anexado (só informativo).
  final String origem;
  final int paginas;
  final int paragrafos;

  /// Limitação da leitura (ex.: páginas digitalizadas sem texto).
  final String aviso;
  final DateTime? anexadoEm;
  final List<MarcacaoAnexo> marcacoes;

  /// Nome da cópia guardada na pasta de anexos do Gestor.
  String get arquivoGuardado => '$hash$extensao';

  AnexoProcesso copyWith({String? nome, List<MarcacaoAnexo>? marcacoes}) =>
      AnexoProcesso(
        id: id,
        nome: nome ?? this.nome,
        hash: hash,
        extensao: extensao,
        origem: origem,
        paginas: paginas,
        paragrafos: paragrafos,
        aviso: aviso,
        anexadoEm: anexadoEm,
        marcacoes: marcacoes ?? this.marcacoes,
      );

  factory AnexoProcesso.fromJson(Map<String, dynamic> j) => AnexoProcesso(
    id: '${j['id'] ?? ''}',
    nome: '${j['nome'] ?? ''}',
    hash: '${j['sha1'] ?? ''}',
    extensao: '${j['extensao'] ?? ''}',
    origem: '${j['origem'] ?? ''}',
    paginas: (j['paginas'] as num?)?.toInt() ?? 0,
    paragrafos: (j['paragrafos'] as num?)?.toInt() ?? 0,
    aviso: '${j['aviso'] ?? ''}',
    anexadoEm: DateTime.tryParse('${j['anexado_em'] ?? ''}'),
    marcacoes: [
      for (final m in (j['marcacoes'] as List? ?? const []))
        if (m is Map) MarcacaoAnexo.fromJson(Map<String, dynamic>.from(m)),
    ],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': nome,
    'sha1': hash,
    'extensao': extensao,
    if (origem.isNotEmpty) 'origem': origem,
    'paginas': paginas,
    'paragrafos': paragrafos,
    if (aviso.isNotEmpty) 'aviso': aviso,
    if (anexadoEm != null) 'anexado_em': anexadoEm!.toIso8601String(),
    'marcacoes': [for (final m in marcacoes) m.toJson()],
  };
}

/// Pedaço de um parágrafo para exibir: texto e a marcação que o cobre
/// (null = sem marcação).
typedef SegmentoMarcado = ({String texto, MarcacaoAnexo? marcacao});

/// Divide o [texto] de um parágrafo pelos limites das [marcacoes]
/// (sobreposição: vale a marcação mais recente na lista).
List<SegmentoMarcado> segmentarParagrafo(
  String texto,
  List<MarcacaoAnexo> marcacoes,
) {
  if (marcacoes.isEmpty || texto.isEmpty) {
    return [(texto: texto, marcacao: null)];
  }
  final dona = List<MarcacaoAnexo?>.filled(texto.length, null);
  for (final m in marcacoes) {
    final a = m.inicio.clamp(0, texto.length);
    final b = m.fim.clamp(a, texto.length);
    for (var i = a; i < b; i++) {
      dona[i] = m;
    }
  }
  final out = <SegmentoMarcado>[];
  var inicio = 0;
  for (var i = 1; i <= texto.length; i++) {
    if (i == texto.length || !identical(dona[i], dona[inicio])) {
      out.add((texto: texto.substring(inicio, i), marcacao: dona[inicio]));
      inicio = i;
    }
  }
  return out;
}
