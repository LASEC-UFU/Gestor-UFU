import 'package:flutter/painting.dart';

/// Parágrafo do texto extraído de um documento (mesmo formato do texto
/// extraído pelos módulos: página 0 = sem página).
typedef ParagrafoDocumento = ({String texto, int pagina, bool titulo});

/// Marcação desenhada sobre o documento. Pode ter âncora na visão de texto
/// ([paragrafo] ≥ 0, [inicio]..[fim] no parágrafo) e/ou no PDF
/// ([pdfPagina] > 0, [pdfInicio]..[pdfFim] no texto da página do pdf.js).
class MarcaDocumento {
  const MarcaDocumento({
    required this.id,
    required this.cor,
    this.comentada = false,
    this.paragrafo = -1,
    this.inicio = 0,
    this.fim = 0,
    this.pdfPagina = 0,
    this.pdfInicio = 0,
    this.pdfFim = 0,
  });

  final String id;
  final Color cor;

  /// Tem comentário (sublinhado no documento).
  final bool comentada;
  final int paragrafo;
  final int inicio;
  final int fim;
  final int pdfPagina;
  final int pdfInicio;
  final int pdfFim;

  bool get noTexto => paragrafo >= 0 && fim > inicio;
  bool get noPdf => pdfPagina > 0 && pdfFim > pdfInicio;
}

/// Destaque do trecho do comentário selecionado: cor bem diferente das
/// marcações comuns, sempre junto de contorno/marcador (não só a cor).
const corSelecionada = Color(0xFF64B5F6);
const corContornoSelecionado = Color(0xFF0B4FA8);

/// Ação pedida sobre um trecho selecionado no documento.
enum AcaoTrecho { marcar, comentar, perguntar }

/// Divide [texto] pelos limites das [marcas] do parágrafo (sobreposição:
/// vale a última da lista).
List<({String texto, MarcaDocumento? marca})> segmentarTexto(
  String texto,
  List<MarcaDocumento> marcas,
) {
  if (marcas.isEmpty || texto.isEmpty) return [(texto: texto, marca: null)];
  final dona = List<MarcaDocumento?>.filled(texto.length, null);
  for (final m in marcas) {
    final a = m.inicio.clamp(0, texto.length);
    final b = m.fim.clamp(a, texto.length);
    for (var i = a; i < b; i++) {
      dona[i] = m;
    }
  }
  final out = <({String texto, MarcaDocumento? marca})>[];
  var inicio = 0;
  for (var i = 1; i <= texto.length; i++) {
    if (i == texto.length || !identical(dona[i], dona[inicio])) {
      out.add((texto: texto.substring(inicio, i), marca: dona[inicio]));
      inicio = i;
    }
  }
  return out;
}
