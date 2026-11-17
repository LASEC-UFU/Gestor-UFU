/// Um documento da árvore de um processo SEI.
class SeiDocumento {
  const SeiDocumento({
    required this.ordem,
    required this.nomeArvore,
    this.codigoSei = '',
    this.tipoNumero = '',
    this.data = '',
    this.resumo = '',
    this.texto = '',
    this.idDocumento = '',
  });

  final int ordem;
  final String nomeArvore;
  final String codigoSei;
  final String tipoNumero;
  final String data;
  final String resumo;

  /// Texto visível do documento (só em memória; base do resumo pela IA).
  final String texto;

  /// Id interno do documento no SEI (`id_documento` do endereço da árvore),
  /// usado no link SEI: `<a class="ancora_sei" id="lnkSei{id}">{código}</a>`.
  final String idDocumento;

  SeiDocumento copyWith({String? data, String? resumo}) => SeiDocumento(
    ordem: ordem,
    nomeArvore: nomeArvore,
    codigoSei: codigoSei,
    tipoNumero: tipoNumero,
    data: data ?? this.data,
    resumo: resumo ?? this.resumo,
    texto: texto,
    idDocumento: idDocumento,
  );

  factory SeiDocumento.fromJson(Map<String, dynamic> json) => SeiDocumento(
    ordem: (json['ordem'] as num?)?.toInt() ?? 0,
    nomeArvore: json['nome_arvore']?.toString() ?? '',
    codigoSei: json['codigo_sei']?.toString() ?? '',
    tipoNumero: json['tipo_numero']?.toString() ?? '',
    data: json['data']?.toString() ?? '',
    resumo: json['resumo']?.toString() ?? '',
    idDocumento: json['id_documento']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'ordem': ordem,
    'nome_arvore': nomeArvore,
    'codigo_sei': codigoSei,
    'tipo_numero': tipoNumero,
    'data': data,
    'resumo': resumo,
    'id_documento': idDocumento,
  };

  /// Monta o documento a partir do texto do nó da árvore e, quando houver,
  /// do texto do documento.
  factory SeiDocumento.fromTree(
    int ordem,
    String nomeArvore, {
    String texto = '',
    String href = '',
  }) {
    final (tipo, codigo) = SeiArvoreTexto.dividirNome(nomeArvore);
    return SeiDocumento(
      ordem: ordem,
      nomeArvore: nomeArvore,
      codigoSei: codigo,
      tipoNumero: tipo,
      data: SeiArvoreTexto.data(texto),
      resumo: SeiArvoreTexto.resumo(texto),
      texto: texto,
      idDocumento:
          RegExp(r'id_documento=(\d+)').firstMatch(href)?.group(1) ?? '',
    );
  }
}

/// Regras de leitura do texto da árvore e dos documentos (sem navegador).
class SeiArvoreTexto {
  static final _nome = RegExp(r'^(.*?)\s*\((\d{5,})\)\s*$');
  static final _assinatura = RegExp(
    r'assinado eletronicamente por[^\n]*?\bem\s+(\d{2}/\d{2}/\d{4})',
    caseSensitive: false,
  );
  static final _numerica = RegExp(r'\b(\d{2}/\d{2}/\d{4})\b');
  static final _extenso = RegExp(
    r'\b(\d{1,2})\s+de\s+([a-zç]+)\s+de\s+(\d{4})\b',
    caseSensitive: false,
  );
  static const _meses = {
    'janeiro': 1, 'fevereiro': 2, 'marco': 3, 'março': 3, 'abril': 4, //
    'maio': 5, 'junho': 6, 'julho': 7, 'agosto': 8, 'setembro': 9,
    'outubro': 10, 'novembro': 11, 'dezembro': 12,
  };

  /// "Ofício 12 (1234567)" → ("Ofício 12", "1234567").
  static (String, String) dividirNome(String nome) {
    final text = nome.replaceAll(RegExp(r'\s+'), ' ').trim();
    final match = _nome.firstMatch(text);
    if (match == null) return (text, '');
    return (match.group(1)!.trim(), match.group(2)!);
  }

  /// Data do documento: a da assinatura eletrônica; senão a primeira data
  /// por extenso ("Uberlândia, 3 de março de 2025") ou numérica.
  static String data(String texto) {
    if (texto.trim().isEmpty) return '';
    final signed = _assinatura.firstMatch(texto);
    if (signed != null) return signed.group(1)!;
    final written = _extenso.firstMatch(texto);
    if (written != null) {
      final month = _meses[written.group(2)!.toLowerCase()];
      if (month != null) {
        final day = written.group(1)!.padLeft(2, '0');
        return '$day/${month.toString().padLeft(2, '0')}/${written.group(3)}';
      }
    }
    return _numerica.firstMatch(texto)?.group(1) ?? '';
  }

  /// Resumo: o "Assunto:"/"Objeto:" do documento; senão o primeiro parágrafo
  /// com conteúdo (sem cabeçalho institucional, vocativo nem assinatura).
  static String resumo(String texto, {int max = 220}) {
    final lines = texto
        .split(RegExp(r'\r?\n'))
        .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    for (final line in lines) {
      final m = RegExp(
        r'^(assunto|objeto|referência|referencia)\s*:\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (m != null) return _cortar(m.group(2)!, max);
    }
    final skip = RegExp(
      r'^(universidade|ministério|ministerio|serviço público|servico publico|'
      r'av\.|avenida|rua|telefone|campus|processo|sei|ao\b|à\b|a\s+sua|'
      r'senhor|senhora|prezad|documento assinado|a autenticidade|referência:|'
      r'referencia:|uberlândia,|uberlandia,|atenciosamente)',
      caseSensitive: false,
    );
    for (final line in lines) {
      if (line.length < 40 || skip.hasMatch(line)) continue;
      return _cortar(line, max);
    }
    return '';
  }

  static String _cortar(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max - 1).trimRight()}…';

  /// Relatório no formato para parecer: "1. Ofício 12 (1234567), de
  /// 03/03/2025 – resumo".
  static String relatorio(List<SeiDocumento> documentos) => documentos
      .map((doc) {
        final ident = doc.tipoNumero.isNotEmpty
            ? doc.tipoNumero
            : doc.nomeArvore;
        final code = doc.codigoSei.isNotEmpty ? ' (${doc.codigoSei})' : '';
        final date = doc.data.isNotEmpty ? ', de ${doc.data}' : '';
        final summary = doc.resumo.isNotEmpty ? ' – ${doc.resumo}' : '';
        return '${doc.ordem}. $ident$code$date$summary';
      })
      .join('\n');

  static const _nomesMeses = [
    'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', //
    'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
  ];

  /// "03/03/2025" → "03 de março de 2025" (outros formatos ficam iguais).
  static String dataPorExtenso(String data) {
    final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(data.trim());
    if (m == null) return data.trim();
    final mes = int.parse(m.group(2)!);
    if (mes < 1 || mes > 12) return data.trim();
    return '${m.group(1)!.padLeft(2, '0')} de ${_nomesMeses[mes - 1]} de '
        '${m.group(3)}';
  }

  /// Item do relatório no estilo dos pareceres: "Ofício 12 (1234567) – de
  /// 03 de março de 2025, resumo" (sem número nem pontuação final).
  static String itemParecer(SeiDocumento doc) {
    final ident = doc.tipoNumero.isNotEmpty ? doc.tipoNumero : doc.nomeArvore;
    final code = doc.codigoSei.isNotEmpty ? ' (${doc.codigoSei})' : '';
    final partes = [
      if (doc.data.isNotEmpty) 'de ${dataPorExtenso(doc.data)}',
      if (doc.resumo.isNotEmpty) doc.resumo.replaceAll(RegExp(r'[;.]+$'), ''),
    ];
    return partes.isEmpty
        ? '$ident$code'
        : '$ident$code – ${partes.join(', ')}';
  }
}
