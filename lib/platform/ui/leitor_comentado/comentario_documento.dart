import 'package:flutter/material.dart';

/// Parte do conteúdo de um comentário, mostrada quando o cartão é
/// expandido ("Por que merece atenção", "Como melhorar"…).
class SecaoComentario {
  const SecaoComentario(this.rotulo, this.texto, {this.icone});

  final String rotulo;
  final String texto;
  final IconData? icone;
}

/// Ação disponível no cartão expandido (editar, excluir, citar…).
class AcaoComentario {
  const AcaoComentario({
    required this.rotulo,
    required this.icone,
    required this.aoAcionar,
    this.destrutiva = false,
  });

  final String rotulo;
  final IconData icone;
  final VoidCallback aoAcionar;
  final bool destrutiva;
}

/// Comentário exibido pela camada de comentários de um documento (HTML ou
/// PDF), independente do módulo que o guarda. O trecho marcado não é
/// repetido no cartão: ele aparece destacado no próprio documento.
class ComentarioDocumento {
  const ComentarioDocumento({
    required this.id,
    required this.titulo,
    required this.cor,
    this.secoes = const [],
    this.etiquetas = const [],
    this.local = '',
    this.ancorado = true,
    this.trechoMarcado = '',
    this.acoes = const [],
  });

  final String id;

  /// O ponto que precisa de atenção, em uma frase.
  final String titulo;

  /// Cor da marcação no documento (barra lateral do cartão).
  final Color cor;
  final List<SecaoComentario> secoes;

  /// Categoria, status… (ajudam a localizar; não substituem o texto).
  final List<String> etiquetas;

  /// Onde está no documento ("p. 3", "II. Fundamentação").
  final String local;

  /// O comentário tem um trecho válido no documento para onde navegar.
  final bool ancorado;

  /// Texto marcado no documento (só para a busca).
  final String trechoMarcado;
  final List<AcaoComentario> acoes;

  /// Texto em que a busca procura.
  String get textoBusca => [
    titulo,
    for (final s in secoes) '${s.rotulo} ${s.texto}',
    ...etiquetas,
    local,
    trechoMarcado,
  ].join('\n');
}

/// Normalização da busca: minúsculas e sem acentos.
String normalizarBusca(String s) {
  const de = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const para = 'aaaaaeeeeiiiiooooouuuucn';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = de.indexOf(ch);
    b.write(i < 0 ? ch : para[i]);
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
