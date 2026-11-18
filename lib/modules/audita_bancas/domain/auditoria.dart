/// Estado da revisão de uma observação.
enum Revisao {
  pendente('Pendente'),
  aceita('Aceita'),
  rejeitada('Rejeitada');

  const Revisao(this.rotulo);
  final String rotulo;

  static Revisao de(String? s) => switch (s) {
    'aceito' || 'aceita' => aceita,
    'rejeitado' || 'rejeitada' => rejeitada,
    _ => pendente,
  };
}

/// Observação sobre um trecho do documento auditado (TCC, dissertação,
/// tese): o problema, por que importa e como melhorar, ancorada na página
/// e na posição do trecho no texto da página (pdf.js).
class Observacao {
  const Observacao({
    required this.id,
    required this.trecho,
    required this.problema,
    this.pagina = 0,
    this.inicio = 0,
    this.fim = 0,
    this.categoria = '',
    this.importancia = '',
    this.melhoria = '',
    this.revisao = Revisao.pendente,
    this.manual = false,
  });

  final String id;

  /// Texto do documento a que a observação se refere.
  final String trecho;

  /// Página (1, 2…; 0 = trecho não localizado no PDF) e posição no texto da
  /// página.
  final int pagina;
  final int inicio;
  final int fim;
  final String categoria;
  final String problema;
  final String importancia;
  final String melhoria;
  final Revisao revisao;

  /// Escrita pelo usuário (não pela análise da IA).
  final bool manual;

  bool get ancorada => pagina > 0 && fim > inicio;

  /// Texto completo (relatório e PDF exportado).
  String get texto => [
    if (problema.isNotEmpty) 'Problema: $problema',
    if (importancia.isNotEmpty) 'Por que importa: $importancia',
    if (melhoria.isNotEmpty) 'Como melhorar: $melhoria',
  ].join('\n');

  Observacao copyWith({
    String? categoria,
    String? problema,
    String? importancia,
    String? melhoria,
    Revisao? revisao,
  }) => Observacao(
    id: id,
    trecho: trecho,
    pagina: pagina,
    inicio: inicio,
    fim: fim,
    categoria: categoria ?? this.categoria,
    problema: problema ?? this.problema,
    importancia: importancia ?? this.importancia,
    melhoria: melhoria ?? this.melhoria,
    revisao: revisao ?? this.revisao,
    manual: manual,
  );

  factory Observacao.fromJson(Map<String, dynamic> j) => Observacao(
    id: '${j['id'] ?? ''}',
    trecho: '${j['trecho'] ?? ''}',
    pagina: (j['pagina'] as num?)?.toInt() ?? 0,
    inicio: (j['inicio'] as num?)?.toInt() ?? 0,
    fim: (j['fim'] as num?)?.toInt() ?? 0,
    categoria: '${j['categoria'] ?? ''}',
    problema: '${j['problema'] ?? ''}',
    importancia: '${j['importancia'] ?? ''}',
    melhoria: '${j['melhoria'] ?? ''}',
    revisao: Revisao.de('${j['revisao'] ?? ''}'),
    manual: j['manual'] == true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'trecho': trecho,
    if (pagina > 0) ...{'pagina': pagina, 'inicio': inicio, 'fim': fim},
    if (categoria.isNotEmpty) 'categoria': categoria,
    'problema': problema,
    if (importancia.isNotEmpty) 'importancia': importancia,
    if (melhoria.isNotEmpty) 'melhoria': melhoria,
    'revisao': revisao.name,
    if (manual) 'manual': true,
  };
}

/// PDF auditado: cópia guardada pelo Gestor (o original não muda) e as
/// observações.
class DocumentoAuditado {
  const DocumentoAuditado({
    required this.id,
    required this.nome,
    required this.hash,
    this.origem = '',
    this.criterios = '',
    this.abertoEm,
    this.observacoes = const [],
  });

  final String id;
  final String nome;

  /// SHA-1 do PDF (nome da cópia guardada).
  final String hash;

  /// Caminho de onde o PDF foi aberto (destino padrão das exportações).
  final String origem;

  /// Critérios/rubrica da última análise.
  final String criterios;
  final DateTime? abertoEm;
  final List<Observacao> observacoes;

  String get arquivo => '$hash.pdf';

  DocumentoAuditado copyWith({
    String? origem,
    String? criterios,
    DateTime? abertoEm,
    List<Observacao>? observacoes,
  }) => DocumentoAuditado(
    id: id,
    nome: nome,
    hash: hash,
    origem: origem ?? this.origem,
    criterios: criterios ?? this.criterios,
    abertoEm: abertoEm ?? this.abertoEm,
    observacoes: observacoes ?? this.observacoes,
  );

  factory DocumentoAuditado.fromJson(Map<String, dynamic> j) =>
      DocumentoAuditado(
        id: '${j['id'] ?? ''}',
        nome: '${j['nome'] ?? ''}',
        hash: '${j['sha1'] ?? ''}',
        origem: '${j['origem'] ?? ''}',
        criterios: '${j['criterios'] ?? ''}',
        abertoEm: DateTime.tryParse('${j['aberto_em'] ?? ''}'),
        observacoes: [
          for (final o in (j['observacoes'] as List? ?? const []))
            if (o is Map) Observacao.fromJson(Map<String, dynamic>.from(o)),
        ],
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': nome,
    'sha1': hash,
    if (origem.isNotEmpty) 'origem': origem,
    if (criterios.isNotEmpty) 'criterios': criterios,
    if (abertoEm != null) 'aberto_em': abertoEm!.toIso8601String(),
    'observacoes': [for (final o in observacoes) o.toJson()],
  };
}
