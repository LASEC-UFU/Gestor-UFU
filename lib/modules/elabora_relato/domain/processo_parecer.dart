/// Um processo do módulo Parecer / Relato: cada um tem o seu rascunho de
/// parecer (com comentários), o inventário da árvore do SEI e a pasta da
/// base de documentos.
class ProcessoParecer {
  const ProcessoParecer({
    required this.id,
    required this.nome,
    this.numeroSei = '',
    this.criadoEm,
    this.atualizadoEm,
  });

  final String id;

  /// Nome dado pelo relator ("Estágio – Engenharia Mecânica").
  final String nome;

  /// Número do processo no SEI ("23117.012345/2026-11"), opcional.
  final String numeroSei;
  final DateTime? criadoEm;
  final DateTime? atualizadoEm;

  ProcessoParecer copyWith({
    String? nome,
    String? numeroSei,
    DateTime? atualizadoEm,
  }) => ProcessoParecer(
    id: id,
    nome: nome ?? this.nome,
    numeroSei: numeroSei ?? this.numeroSei,
    criadoEm: criadoEm,
    atualizadoEm: atualizadoEm ?? this.atualizadoEm,
  );

  factory ProcessoParecer.fromJson(Map<String, dynamic> json) =>
      ProcessoParecer(
        id: '${json['id'] ?? ''}',
        nome: '${json['nome'] ?? ''}',
        numeroSei: '${json['numero_sei'] ?? ''}',
        criadoEm: DateTime.tryParse('${json['criado_em'] ?? ''}'),
        atualizadoEm: DateTime.tryParse('${json['atualizado_em'] ?? ''}'),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': nome,
    'numero_sei': numeroSei,
    if (criadoEm != null) 'criado_em': criadoEm!.toIso8601String(),
    if (atualizadoEm != null) 'atualizado_em': atualizadoEm!.toIso8601String(),
  };
}

/// Números de um processo para a lista (lidos do banco sem abri-lo).
class ResumoProcesso {
  const ResumoProcesso({
    this.assunto = '',
    this.documentos = 0,
    this.comentarios = 0,
    this.pendentes = 0,
    this.secoesComTexto = 0,
  });

  final String assunto;

  /// Documentos no inventário da árvore do SEI.
  final int documentos;
  final int comentarios;

  /// Comentários "para revisão".
  final int pendentes;

  /// Seções (das 3) com texto.
  final int secoesComTexto;
}
