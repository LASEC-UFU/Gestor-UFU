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
