import 'dart:math' as math;

/// Base de consulta montada a partir dos documentos de uma pasta (normas,
/// resoluções, ofícios…). Cada documento original vira uma lista de
/// [TrechoBase] com a localização no arquivo (página, artigo, seção,
/// parágrafo). Os originais nunca são alterados: a base só aponta para eles.
///
/// Gravada em JSON na própria pasta (ver `BaseDocumentosIndexer.nomeArquivo`)
/// para que a IA consulte o conteúdo já extraído, sem reconverter os
/// arquivos a cada pergunta.
class BaseDocumentos {
  BaseDocumentos({
    required this.pasta,
    required this.documentos,
    DateTime? geradoEm,
  }) : geradoEm = geradoEm ?? DateTime.now();

  static const versao = 1;

  final String pasta;
  final List<DocumentoBase> documentos;
  final DateTime geradoEm;

  _IndiceBusca? _indice;

  Iterable<TrechoBase> get trechos => documentos.expand((d) => d.trechos);

  int get totalTrechos => documentos.fold(0, (n, d) => n + d.trechos.length);

  /// Documentos sem texto aproveitável (digitalizados, com erro, formato
  /// não suportado).
  List<DocumentoBase> get semTexto => [
    for (final d in documentos)
      if (d.status != StatusDocumento.ok) d,
  ];

  /// Busca os trechos mais relevantes para [consulta] (termos, número de
  /// artigo, expressão exata).
  List<ResultadoBusca> buscar(String consulta, {int limite = 8}) =>
      (_indice ??= _IndiceBusca(trechos.toList())).buscar(consulta, limite);

  factory BaseDocumentos.fromJson(Map<String, dynamic> json) => BaseDocumentos(
    pasta: '${json['pasta'] ?? ''}',
    geradoEm: DateTime.tryParse('${json['gerado_em'] ?? ''}'),
    documentos: [
      for (final d in (json['documentos'] as List? ?? const []))
        if (d is Map) DocumentoBase.fromJson(Map<String, dynamic>.from(d)),
    ],
  );

  Map<String, dynamic> toJson() => {
    'versao': versao,
    'descricao':
        'Base de consulta gerada pelo Gestor UFU (Parecer / Relato). Cada '
        'trecho aponta para o arquivo original e sua localização; os '
        'arquivos originais são a fonte oficial.',
    'pasta': pasta,
    'gerado_em': geradoEm.toIso8601String(),
    'resumo': {
      'documentos': documentos.length,
      'trechos': totalTrechos,
      'sem_texto': [for (final d in semTexto) d.arquivo],
    },
    // Catálogo para localizar rapidamente as normas e seus artigos.
    'normas': [
      for (final d in documentos)
        if (d.norma.isNotEmpty || d.artigos.isNotEmpty)
          {
            'arquivo': d.arquivo,
            'norma': d.norma,
            'titulo': d.titulo,
            'artigos': d.artigos,
          },
    ],
    'documentos': [for (final d in documentos) d.toJson()],
  };
}

enum StatusDocumento {
  ok,

  /// PDF sem camada de texto (digitalizado como imagem): precisa de OCR.
  requerOcr,

  /// Arquivo lido, mas sem texto.
  vazio,

  naoSuportado,
  erro;

  String get id => switch (this) {
    ok => 'ok',
    requerOcr => 'requer_ocr',
    vazio => 'vazio',
    naoSuportado => 'nao_suportado',
    erro => 'erro',
  };

  String get descricao => switch (this) {
    ok => 'indexado',
    requerOcr => 'sem texto (digitalizado: precisa de OCR)',
    vazio => 'sem texto',
    naoSuportado => 'formato não suportado',
    erro => 'erro na leitura',
  };

  static StatusDocumento deId(String id) => StatusDocumento.values.firstWhere(
    (s) => s.id == id,
    orElse: () => StatusDocumento.erro,
  );
}

/// Um arquivo da pasta e seus trechos.
class DocumentoBase {
  const DocumentoBase({
    required this.arquivo,
    required this.tamanho,
    required this.modificado,
    required this.hash,
    required this.status,
    this.tipo = '',
    this.mensagem = '',
    this.titulo = '',
    this.norma = '',
    this.paginas = 0,
    this.paginasSemTexto = const [],
    this.trechos = const [],
  });

  /// Caminho relativo à pasta da base (com "/").
  final String arquivo;
  final int tamanho;
  final DateTime modificado;

  /// SHA-1 do conteúdo (evita reprocessar quando só a data mudou).
  final String hash;
  final StatusDocumento status;
  final String tipo;
  final String mensagem;
  final String titulo;

  /// Identificação da norma, se reconhecida ("Resolução CONGRAD nº 46/2022").
  final String norma;
  final int paginas;

  /// Páginas de PDF sem texto extraível (provavelmente digitalizadas).
  final List<int> paginasSemTexto;
  final List<TrechoBase> trechos;

  /// Artigos encontrados, na ordem do documento (sem repetição).
  List<String> get artigos {
    final vistos = <String>{};
    return [
      for (final t in trechos)
        if (t.artigo.isNotEmpty && vistos.add(t.artigo)) t.artigo,
    ];
  }

  DocumentoBase comArquivo({required DateTime modificado}) => DocumentoBase(
    arquivo: arquivo,
    tamanho: tamanho,
    modificado: modificado,
    hash: hash,
    status: status,
    tipo: tipo,
    mensagem: mensagem,
    titulo: titulo,
    norma: norma,
    paginas: paginas,
    paginasSemTexto: paginasSemTexto,
    trechos: trechos,
  );

  factory DocumentoBase.fromJson(Map<String, dynamic> json) {
    final arquivo = '${json['arquivo'] ?? ''}';
    return DocumentoBase(
      arquivo: arquivo,
      tamanho: (json['tamanho'] as num?)?.toInt() ?? 0,
      modificado:
          DateTime.tryParse('${json['modificado'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      hash: '${json['sha1'] ?? ''}',
      status: StatusDocumento.deId('${json['status'] ?? ''}'),
      tipo: '${json['tipo'] ?? ''}',
      mensagem: '${json['mensagem'] ?? ''}',
      titulo: '${json['titulo'] ?? ''}',
      norma: '${json['norma'] ?? ''}',
      paginas: (json['paginas'] as num?)?.toInt() ?? 0,
      paginasSemTexto: [
        for (final p in (json['paginas_sem_texto'] as List? ?? const []))
          if (p is num) p.toInt(),
      ],
      trechos: [
        for (final t in (json['trechos'] as List? ?? const []))
          if (t is Map)
            TrechoBase.fromJson(Map<String, dynamic>.from(t), arquivo),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'arquivo': arquivo,
    'tipo': tipo,
    'tamanho': tamanho,
    'modificado': modificado.toIso8601String(),
    'sha1': hash,
    'status': status.id,
    if (mensagem.isNotEmpty) 'mensagem': mensagem,
    if (titulo.isNotEmpty) 'titulo': titulo,
    if (norma.isNotEmpty) 'norma': norma,
    if (paginas > 0) 'paginas': paginas,
    if (paginasSemTexto.isNotEmpty) 'paginas_sem_texto': paginasSemTexto,
    'artigos': artigos,
    'trechos': [for (final t in trechos) t.toJson()],
  };
}

/// Um trecho de um documento, com a localização no original.
class TrechoBase {
  const TrechoBase({
    required this.id,
    required this.arquivo,
    required this.texto,
    this.pagina = 0,
    this.paginaFim = 0,
    this.artigo = '',
    this.secao = '',
    this.paragrafo = 0,
  });

  /// Identificador estável dentro da base (`hash-n`).
  final String id;
  final String arquivo;
  final String texto;

  /// Página inicial/final (PDF; 0 = não se aplica).
  final int pagina;
  final int paginaFim;

  /// "Art. 41" quando o trecho é (parte de) um artigo.
  final String artigo;

  /// Título/capítulo/seção em que o trecho está.
  final String secao;

  /// Número do primeiro parágrafo do trecho no documento (1, 2, …).
  final int paragrafo;

  /// Localização legível: "p. 3 · Art. 41 · CAPÍTULO IV · § 12".
  String get localizacao => [
    if (pagina > 0) paginaFim > pagina ? 'p. $pagina–$paginaFim' : 'p. $pagina',
    if (artigo.isNotEmpty) artigo,
    if (secao.isNotEmpty) secao,
    if (paragrafo > 0) 'parágrafo $paragrafo',
  ].join(' · ');

  factory TrechoBase.fromJson(Map<String, dynamic> json, String arquivo) =>
      TrechoBase(
        id: '${json['id'] ?? ''}',
        arquivo: arquivo,
        texto: '${json['texto'] ?? ''}',
        pagina: (json['pagina'] as num?)?.toInt() ?? 0,
        paginaFim: (json['pagina_fim'] as num?)?.toInt() ?? 0,
        artigo: '${json['artigo'] ?? ''}',
        secao: '${json['secao'] ?? ''}',
        paragrafo: (json['paragrafo'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (pagina > 0) 'pagina': pagina,
    if (paginaFim > pagina) 'pagina_fim': paginaFim,
    if (artigo.isNotEmpty) 'artigo': artigo,
    if (secao.isNotEmpty) 'secao': secao,
    if (paragrafo > 0) 'paragrafo': paragrafo,
    'texto': texto,
  };
}

class ResultadoBusca {
  const ResultadoBusca(this.trecho, this.pontuacao);

  final TrechoBase trecho;
  final double pontuacao;
}

/// Normalização de texto para a busca: minúsculas, sem acentos, sem
/// palavras vazias e com plural simplificado.
class TextoBusca {
  const TextoBusca._();

  static const _de = 'áàâãäéèêëíìîïóòôõöúùûüçñº°ª';
  static const _para = 'aaaaaeeeeiiiiooooouuuucnooa';

  static String semAcentos(String s) {
    final b = StringBuffer();
    for (final rune in s.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      final i = _de.indexOf(ch);
      b.write(i < 0 ? ch : _para[i]);
    }
    return b.toString();
  }

  static const _vazias = {
    'a', 'o', 'as', 'os', 'um', 'uma', 'uns', 'umas', 'de', 'do', 'da', //
    'dos', 'das', 'em', 'no', 'na', 'nos', 'nas', 'por', 'pelo', 'pela',
    'pelos', 'pelas', 'para', 'pra', 'com', 'sem', 'que', 'e', 'ou', 'se',
    'ao', 'aos', 'como', 'mais', 'mas', 'ja', 'nao', 'sim', 'esta', 'este',
    'isto', 'isso', 'esse', 'essa', 'aquele', 'aquela', 'ser', 'sao', 'foi',
    'sera', 'ha', 'tem', 'ter', 'seu', 'sua', 'seus', 'suas', 'lhe', 'me',
    'meu', 'minha', 'qual', 'quais', 'quando', 'onde', 'entre', 'sobre',
    'forma', 'desta', 'deste', 'dessa', 'desse', 'estao', 'pedindo',
    'mudar', 'trecho', 'plausivel', 'assim',
  };

  static String _radical(String t) {
    if (t.length <= 4 || RegExp(r'^\d').hasMatch(t)) return t;
    if (t.endsWith('coes')) return '${t.substring(0, t.length - 4)}cao';
    if (t.endsWith('oes') || t.endsWith('aes')) {
      return '${t.substring(0, t.length - 3)}ao';
    }
    if (t.endsWith('is') && t.length > 5) {
      return '${t.substring(0, t.length - 2)}l';
    }
    if (t.endsWith('s')) return t.substring(0, t.length - 1);
    return t;
  }

  static List<String> termos(String s) => [
    for (final t in semAcentos(s).split(RegExp(r'[^a-z0-9]+')))
      if (t.isNotEmpty && (t.length > 1 || RegExp(r'\d').hasMatch(t)))
        if (!_vazias.contains(t)) _radical(t),
  ];

  /// Texto comparável (sem acentos e com espaços normalizados), para
  /// conferir citações literais.
  static String comparavel(String s) => semAcentos(s)
      .replaceAll(RegExp('[“”"«»]'), '"')
      .replaceAll(RegExp("[‘’`´]"), "'")
      .replaceAll(RegExp(r'[–—]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static final _artigo = RegExp(
    r'\bart(?:igo)?s?\.?\s*(\d+)',
    caseSensitive: false,
  );

  /// Números de artigo citados ("art. 41", "artigo 3º").
  static Set<String> artigos(String s) => {
    for (final m in _artigo.allMatches(semAcentos(s))) m.group(1)!,
  };
}

/// Índice invertido em memória (BM25), reconstruído a cada carga da base.
class _IndiceBusca {
  _IndiceBusca(this._trechos) {
    var soma = 0;
    for (var i = 0; i < _trechos.length; i++) {
      final t = _trechos[i];
      final termos = TextoBusca.termos('${t.artigo} ${t.secao} ${t.texto}');
      _tamanhos.add(termos.length);
      soma += termos.length;
      final freq = <String, int>{};
      for (final termo in termos) {
        freq[termo] = (freq[termo] ?? 0) + 1;
      }
      freq.forEach((termo, n) => (_postings[termo] ??= []).add((i, n)));
      _normalizados.add(TextoBusca.comparavel(t.texto));
      final artigo = RegExp(r'\d+').firstMatch(t.artigo)?.group(0);
      _artigos.add(artigo);
    }
    _media = _trechos.isEmpty ? 1 : soma / _trechos.length;
  }

  final List<TrechoBase> _trechos;
  final _postings = <String, List<(int, int)>>{};
  final _tamanhos = <int>[];
  final _normalizados = <String>[];
  final _artigos = <String?>[];
  double _media = 1;

  List<ResultadoBusca> buscar(String consulta, int limite) {
    if (_trechos.isEmpty) return const [];
    final termos = TextoBusca.termos(consulta).toSet();
    final pontos = <int, double>{};
    const k1 = 1.2, b = 0.75;
    final n = _trechos.length;
    for (final termo in termos) {
      final lista = _postings[termo];
      if (lista == null) continue;
      final idf = math.log(1 + (n - lista.length + 0.5) / (lista.length + 0.5));
      for (final (i, f) in lista) {
        final norm = 1 - b + b * _tamanhos[i] / _media;
        pontos[i] = (pontos[i] ?? 0) + idf * (f * (k1 + 1)) / (f + k1 * norm);
      }
    }
    // Artigo citado pelo número: reforça os trechos desse artigo.
    final artigos = TextoBusca.artigos(consulta);
    if (artigos.isNotEmpty) {
      for (final i in pontos.keys.toList()) {
        if (artigos.contains(_artigos[i])) pontos[i] = pontos[i]! + 4;
      }
    }
    // Expressão exata (consultas curtas).
    final frase = TextoBusca.comparavel(consulta);
    if (frase.length >= 6 && frase.length <= 160) {
      for (final i in pontos.keys.toList()) {
        if (_normalizados[i].contains(frase)) pontos[i] = pontos[i]! + 3;
      }
    }
    final ordem = pontos.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in ordem.take(limite))
        ResultadoBusca(_trechos[e.key], e.value),
    ];
  }
}
