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
    this.revisao = 'pendente',
    this.criadoEm,
    this.atualizadoEm,
    this.pdfPagina = 0,
    this.pdfInicio = 0,
    this.pdfFim = 0,
  });

  final String id;

  /// Âncora na visão "PDF original": página (1, 2, …; 0 = ainda não
  /// localizada) e posição no texto da página extraído pelo pdf.js.
  final int pdfPagina;
  final int pdfInicio;
  final int pdfFim;

  /// Índice (0, 1, …) do parágrafo no texto extraído do documento
  /// (-1 = não localizada na visão "Texto").
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

  /// Status de revisão, usado pelo Audita Banco (compatível com dados antigos).
  final String revisao;
  final DateTime? criadoEm;
  final DateTime? atualizadoEm;

  MarcacaoAnexo copyWith({
    String? cor,
    String? comentario,
    String? explicacaoIa,
    String? pergunta,
    String? revisao,
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
    revisao: revisao ?? this.revisao,
    criadoEm: criadoEm,
    atualizadoEm: DateTime.now(),
    pdfPagina: pdfPagina,
    pdfInicio: pdfInicio,
    pdfFim: pdfFim,
  );

  /// A mesma marcação com outras âncoras (texto e/ou PDF).
  MarcacaoAnexo ancorada({
    int? paragrafo,
    int? inicio,
    int? fim,
    int? pdfPagina,
    int? pdfInicio,
    int? pdfFim,
  }) => MarcacaoAnexo(
    id: id,
    paragrafo: paragrafo ?? this.paragrafo,
    inicio: inicio ?? this.inicio,
    fim: fim ?? this.fim,
    texto: texto,
    cor: cor,
    comentario: comentario,
    explicacaoIa: explicacaoIa,
    pergunta: pergunta,
    revisao: revisao,
    criadoEm: criadoEm,
    atualizadoEm: atualizadoEm,
    pdfPagina: pdfPagina ?? this.pdfPagina,
    pdfInicio: pdfInicio ?? this.pdfInicio,
    pdfFim: pdfFim ?? this.pdfFim,
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
    revisao: ['pendente', 'aceito', 'rejeitado'].contains(j['revisao'])
        ? '${j['revisao']}'
        : 'pendente',
    criadoEm: DateTime.tryParse('${j['criado_em'] ?? ''}'),
    atualizadoEm: DateTime.tryParse('${j['atualizado_em'] ?? ''}'),
    pdfPagina: ((j['pdf'] as Map?)?['pagina'] as num?)?.toInt() ?? 0,
    pdfInicio: ((j['pdf'] as Map?)?['inicio'] as num?)?.toInt() ?? 0,
    pdfFim: ((j['pdf'] as Map?)?['fim'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (pdfPagina > 0)
      'pdf': {'pagina': pdfPagina, 'inicio': pdfInicio, 'fim': pdfFim},
    'paragrafo': paragrafo,
    'inicio': inicio,
    'fim': fim,
    'texto': texto,
    'cor': cor,
    if (comentario.isNotEmpty) 'comentario': comentario,
    if (explicacaoIa.isNotEmpty) 'explicacao_ia': explicacaoIa,
    if (pergunta.isNotEmpty) 'pergunta': pergunta,
    if (revisao != 'pendente') 'revisao': revisao,
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

/// Procura o trecho [alvo] em [texto] ignorando diferenças de espaços,
/// quebras de linha, hifenização no fim da linha, maiúsculas e acentos
/// (o texto extraído pelo pdftotext e pelo pdf.js difere nesses pontos).
/// Havendo várias ocorrências, fica a mais próxima de [perto]. Devolve a
/// posição em [texto] ou null.
({int inicio, int fim})? localizarTrecho(
  String alvo,
  String texto, {
  int perto = 0,
}) {
  final (norm, mapa) = _normalizarComMapa(texto);
  final (chave, _) = _normalizarComMapa(alvo);
  final busca = chave.trim();
  if (busca.isEmpty) return null;
  var melhor = -1;
  var distancia = 1 << 30;
  for (var i = norm.indexOf(busca); i >= 0; i = norm.indexOf(busca, i + 1)) {
    final d = (mapa[i] - perto).abs();
    if (d < distancia) {
      distancia = d;
      melhor = i;
    }
  }
  if (melhor < 0) return null;
  return (inicio: mapa[melhor], fim: mapa[melhor + busca.length - 1] + 1);
}

const _acentos = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
const _semAcento = 'aaaaaeeeeiiiiooooouuuucn';

/// Texto normalizado e, para cada caractere dele, a posição no original.
(String, List<int>) _normalizarComMapa(String t) {
  final b = StringBuffer();
  final mapa = <int>[];
  var espaco = false;
  for (var i = 0; i < t.length; i++) {
    var c = t[i];
    // Hífen de quebra de linha ("trans-" + quebra + "formação") e hífen
    // invisível (U+00AD).
    if (c.codeUnitAt(0) == 0xAD) continue;
    if (c == '-' &&
        i + 1 < t.length &&
        (t[i + 1] == '\n' || t[i + 1] == '\r')) {
      var j = i + 1;
      while (j < t.length && RegExp(r'\s').hasMatch(t[j])) {
        j++;
      }
      if (j < t.length && RegExp(r'[a-zà-ÿ]').hasMatch(t[j])) {
        i = j - 1;
        continue;
      }
    }
    if (RegExp(r'\s').hasMatch(c)) {
      if (!espaco && b.isNotEmpty) {
        b.write(' ');
        mapa.add(i);
      }
      espaco = true;
      continue;
    }
    espaco = false;
    c = c.toLowerCase();
    final k = _acentos.indexOf(c);
    b.write(k < 0 ? c : _semAcento[k]);
    mapa.add(i);
  }
  return (b.toString(), mapa);
}
