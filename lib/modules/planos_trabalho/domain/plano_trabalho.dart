class PlanoTrabalho {
  const PlanoTrabalho({
    required this.id,
    required this.nome,
    this.numero = '',
    this.nomeArvore = '',
    this.interessado = '',
    this.pdfPath = '',
    this.spreadsheetData,
  });

  final String id;
  final String nome;
  final String numero;
  final String nomeArvore;
  final String interessado;
  final String pdfPath;
  final Map<String, dynamic>? spreadsheetData;

  PlanoTrabalho copyWith({
    String? nome,
    String? numero,
    String? nomeArvore,
    String? interessado,
    String? pdfPath,
    Map<String, dynamic>? spreadsheetData,
  }) => PlanoTrabalho(
    id: id,
    nome: nome ?? this.nome,
    numero: numero ?? this.numero,
    nomeArvore: nomeArvore ?? this.nomeArvore,
    interessado: interessado ?? this.interessado,
    pdfPath: pdfPath ?? this.pdfPath,
    spreadsheetData: spreadsheetData ?? this.spreadsheetData,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'nome': nome,
    'numero': numero,
    'nomeArvore': nomeArvore,
    'interessado': interessado,
    'pdfPath': pdfPath,
    'spreadsheetData': spreadsheetData,
  };

  factory PlanoTrabalho.fromJson(Map<String, dynamic> json) => PlanoTrabalho(
    id: json['id'] as String,
    nome: json['nome'] as String? ?? '',
    numero: json['numero'] as String? ?? '',
    nomeArvore: json['nomeArvore'] as String? ?? '',
    interessado: json['interessado'] as String? ?? '',
    pdfPath: json['pdfPath'] as String? ?? '',
    spreadsheetData: json['spreadsheetData'] is Map
        ? Map<String, dynamic>.from(json['spreadsheetData'] as Map)
        : null,
  );
}
