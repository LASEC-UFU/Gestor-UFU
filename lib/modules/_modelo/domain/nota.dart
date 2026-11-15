/// Entidade do módulo: só dados e regras puras (sem Flutter, sem banco).
class Nota {
  const Nota({required this.id, required this.texto, required this.criadaEm});

  final String id;
  final String texto;
  final DateTime criadaEm;

  Map<String, dynamic> toJson() => {
    'id': id,
    'texto': texto,
    'criadaEm': criadaEm.toIso8601String(),
  };

  factory Nota.fromJson(Map<String, dynamic> json) => Nota(
    id: '${json['id']}',
    texto: '${json['texto'] ?? ''}',
    criadaEm: DateTime.tryParse('${json['criadaEm']}') ?? DateTime(2000),
  );
}
