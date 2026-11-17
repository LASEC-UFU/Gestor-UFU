import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';

/// HTML do parecer no padrão do editor do SEI.
class SeiParecerHtml {
  const SeiParecerHtml._();

  /// Classe de parágrafo justificado com recuo (estilo do SEI).
  static const classeParagrafo = 'Texto_Justificado_Recuo_Primeira_Linha';
  static const classeJustificado = 'Texto_Justificado';
  static const classeEsquerda = 'Texto_Alinhado_Esquerda';

  static final _esc = const HtmlEscape(HtmlEscapeMode.element);

  static String escape(String text) => _esc.convert(text);

  static const _romanos = [
    'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', //
    'XI', 'XII', 'XIII', 'XIV', 'XV', 'XVI', 'XVII', 'XVIII', 'XIX', 'XX',
  ];

  static String _romano(int n) =>
      n >= 1 && n <= _romanos.length ? _romanos[n - 1] : '$n';

  /// Inventário da árvore no estilo do relatório dos pareceres:
  /// "1. Ofício 12 (1234567) – de 03 de março de 2025, resumo;". Com
  /// [porPastas], insere "Pasta I", "Pasta II"… a cada [docsPorPasta]
  /// documentos (a árvore do SEI agrupa 20 por pasta).
  static String inventario(
    List<SeiDocumento> docs, {
    String introducao = '',
    bool porPastas = true,
    int docsPorPasta = 20,
  }) {
    final b = StringBuffer();
    if (introducao.trim().isNotEmpty) {
      for (final linha in introducao.split('\n')) {
        if (linha.trim().isEmpty) continue;
        b.write('<p class="$classeParagrafo">${escape(linha.trim())}</p>');
      }
    }
    for (var i = 0; i < docs.length; i++) {
      if (porPastas && docs.length > docsPorPasta && i % docsPorPasta == 0) {
        b.write(
          '<p class="$classeEsquerda"><strong>Pasta '
          '${_romano(i ~/ docsPorPasta + 1)}</strong></p>',
        );
      }
      final fim = i == docs.length - 1 ? '.' : ';';
      b.write(
        '<p class="$classeJustificado">${i + 1}. ${item(docs[i])}$fim</p>',
      );
    }
    return b.toString();
  }

  /// Link SEI como o botão "sei!" do editor do SEI gera: o id interno do
  /// documento no `id` e o número SEI como texto.
  static String linkSei(String idDocumento, String codigo) =>
      '<a class="ancora_sei" id="lnkSei${escape(idDocumento)}">'
      '${escape(codigo)}</a>';

  /// Item do inventário em HTML: "Ofício 12 (<link SEI>) – de 03 de março
  /// de 2025, resumo" (sem link quando falta o id interno).
  static String item(SeiDocumento doc) {
    final texto = SeiArvoreTexto.itemParecer(doc);
    if (doc.codigoSei.isEmpty || doc.idDocumento.isEmpty) return escape(texto);
    final alvo = '(${doc.codigoSei})';
    final i = texto.indexOf(alvo);
    if (i < 0) return escape(texto);
    return '${escape(texto.substring(0, i))}('
        '${linkSei(doc.idDocumento, doc.codigoSei)})'
        '${escape(texto.substring(i + alvo.length))}';
  }

  /// Texto simples (uma linha por parágrafo) → parágrafos HTML.
  static String paragrafos(String texto, {String classe = classeParagrafo}) => [
    for (final l in texto.split('\n'))
      if (l.trim().isNotEmpty) '<p class="$classe">${escape(l.trim())}</p>',
  ].join();

  /// Texto puro de um trecho HTML (para contagens e resumos ao agente).
  static String textoPuro(String html) {
    if (html.trim().isEmpty) return '';
    final frag = html_parser.parseFragment(html);
    return frag.nodes
        .map((n) => n.text ?? '')
        .join('\n')
        .replaceAll(RegExp(r'[ \t ]+'), ' ')
        .trim();
  }
}

/// Resultado da montagem no modelo do SEI.
typedef SeiParecerMerge = ({String html, List<String> avisos});

/// Aplica o rascunho ao modelo nativo "Parecer" carregado pelo editor do SEI,
/// preservando cabeçalho, tabelas e estilos do modelo. Recusa-se a gravar se
/// o HTML não tiver as três seções do modelo (nada é alterado).
class SeiParecerHtmlMerger {
  const SeiParecerHtmlMerger._();

  static final _reRelatorio = RegExp(r'^i\s*[.\-–)]?\s*relatorio\b');
  static final _reFundamentacao = RegExp(r'^ii\s*[.\-–)]?\s*fundamentacao\b');
  static final _reConclusao = RegExp(r'^iii\s*[.\-–)]?\s*conclusao\b');
  static final _reFecho = RegExp(r'^a consideracao superior');
  static final _reNome = RegExp(r'^nome do servidor');
  static final _reCargo = RegExp(r'^cargo\s*/?\s*funcao do servidor');
  static final _reVocativo = RegExp(
    r'^(senhor|senhora|senhores|senhoras|prezad|excelentissim|magnific|'
    r'ilustrissim|exm|ilm)',
  );

  static SeiParecerMerge merge(String modelHtml, Parecer p) {
    final frag = html_parser.parseFragment(modelHtml);
    final avisos = <String>[];

    final rel = _bloco(frag, _reRelatorio);
    final fund = _bloco(frag, _reFundamentacao);
    final conc = _bloco(frag, _reConclusao);
    if (rel == null || fund == null || conc == null) {
      throw StateError(
        'O editor aberto não contém o modelo de Parecer do SEI (seções '
        '"I. RELATÓRIO", "II. FUNDAMENTAÇÃO" e "III. CONCLUSÃO"). Nada foi '
        'alterado.',
      );
    }

    _preencherTabelaAssunto(frag, p, avisos);
    _preencherVocativoEAbertura(frag, rel, p, avisos);

    _substituirEntre(rel, fund, p.relatorio);
    _substituirEntre(fund, conc, p.fundamentacao);
    if (_norm(fund.text) != _norm(ParecerSecao.fundamentacao.titulo)) {
      _definirTexto(fund, ParecerSecao.fundamentacao.titulo);
    }

    final fecho = _blocoDepois(frag, conc, _reFecho);
    final nome = _blocoDepois(frag, conc, _reNome);
    final cargo = _blocoDepois(frag, conc, _reCargo);
    _substituirEntre(conc, fecho ?? nome, p.conclusao);
    if (fecho != null && p.fecho.trim().isNotEmpty) {
      _definirTexto(fecho, p.fecho.trim());
    }
    if (nome != null && p.nomeSignatario.trim().isNotEmpty) {
      _definirTexto(nome, p.nomeSignatario.trim());
    }
    if (cargo != null && p.cargoSignatario.trim().isNotEmpty) {
      _definirTexto(cargo, p.cargoSignatario.trim());
    }
    if (p.relatorio.trim().isEmpty) avisos.add('I. RELATÓRIO está vazio.');
    if (p.fundamentacao.trim().isEmpty) {
      avisos.add('II. FUNDAMENTAÇÃO E ANÁLISE está vazia.');
    }
    if (p.conclusao.trim().isEmpty) avisos.add('III. CONCLUSÃO está vazia.');
    return (html: frag.outerHtml, avisos: avisos);
  }

  // ------------------------------------------------------------ tabela

  static void _preencherTabelaAssunto(
    DocumentFragment frag,
    Parecer p,
    List<String> avisos,
  ) {
    final rotulo = frag.querySelectorAll('td,th').where((c) {
      final t = _norm(c.text);
      return t.startsWith('assunto') && t.length <= 12;
    }).firstOrNull;
    if (rotulo == null) {
      if (p.assunto.trim().isNotEmpty) {
        avisos.add('Não achei a linha ASSUNTO no modelo; preencha no SEI.');
      }
      return;
    }
    final linha = rotulo.parent!;
    final celulas = linha.children.where(_ehCelula).toList();
    final idx = celulas.indexOf(rotulo);
    if (p.assunto.trim().isNotEmpty && idx + 1 < celulas.length) {
      _definirCelula(celulas[idx + 1], p.assunto);
    }
    if (p.ementa.trim().isEmpty) return;
    Element? ementa = frag
        .querySelectorAll('td,th')
        .where((c) => _norm(c.text).contains('texto do item da ementa'))
        .firstOrNull;
    if (ementa == null) {
      final tr = linha.parent?.children.where((e) => e.localName == 'tr');
      final linhas = tr?.toList() ?? const <Element>[];
      final i = linhas.indexOf(linha);
      if (i >= 0 && i + 1 < linhas.length) {
        ementa = linhas[i + 1].children.where(_ehCelula).lastOrNull;
      }
    }
    if (ementa == null) {
      avisos.add('Não achei a célula da ementa no modelo; preencha no SEI.');
    } else {
      _definirCelula(ementa, p.ementa);
    }
  }

  static bool _ehCelula(Element e) =>
      e.localName == 'td' || e.localName == 'th';

  /// Troca o conteúdo da célula mantendo o parágrafo (e o estilo) original.
  static void _definirCelula(Element celula, String texto) {
    final linhas = texto
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final modelo = celula.querySelector('p');
    if (modelo == null) {
      celula.text = linhas.join(' ');
      return;
    }
    celula.nodes.clear();
    for (final l in linhas) {
      final p = modelo.clone(false)..text = l;
      celula.append(p);
    }
  }

  // ---------------------------------------------------------- vocativo

  static void _preencherVocativoEAbertura(
    DocumentFragment frag,
    Element rel,
    Parecer p,
    List<String> avisos,
  ) {
    final blocos = _blocos(frag);
    final fimIdx = blocos.indexOf(rel);
    Element? vocativo;
    for (var i = 0; i < fimIdx; i++) {
      final t = _norm(blocos[i].text);
      if (_reVocativo.hasMatch(t) && t.length < 200) {
        vocativo = blocos[i];
        break;
      }
    }
    final linhasVoc = p.vocativo
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final linhasAbertura = p.abertura
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (vocativo == null) {
      if (linhasVoc.isNotEmpty) {
        avisos.add('Não achei o vocativo ("Senhor…,") no modelo.');
      }
      for (final l in linhasAbertura) {
        _inserirAntes(
          rel,
          Element.tag('p')
            ..attributes['class'] = SeiParecerHtml.classeParagrafo
            ..text = l,
        );
      }
      return;
    }

    // Remove o texto anterior entre o vocativo e o relatório (vocativos
    // extras e aberturas de uma inserção anterior); mantém linhas vazias.
    final vIdx = blocos.indexOf(vocativo);
    for (var i = vIdx + 1; i < fimIdx; i++) {
      final b = blocos[i];
      if (b.text.trim().isNotEmpty && b.parentNode != null) {
        b.remove();
      }
    }
    if (linhasVoc.isNotEmpty) {
      Element anterior = vocativo;
      _definirTexto(vocativo, linhasVoc.first);
      for (final l in linhasVoc.skip(1)) {
        final novo = vocativo.clone(false)..text = l;
        _inserirDepois(anterior, novo);
        anterior = novo;
      }
    }
    for (final l in linhasAbertura) {
      _inserirAntes(rel, vocativo.clone(false)..text = l);
    }
  }

  // ----------------------------------------------------------- seções

  /// Remove o que está entre [inicio] e [fim] (ou até o fim do contêiner) e
  /// coloca [html] logo após [inicio].
  static void _substituirEntre(Element inicio, Element? fim, String html) {
    final pai = inicio.parentNode!;
    while (true) {
      final i = pai.nodes.indexOf(inicio);
      if (i + 1 >= pai.nodes.length) break;
      final prox = pai.nodes[i + 1];
      if (fim != null && (prox == fim || prox.contains(fim))) break;
      prox.remove();
    }
    if (html.trim().isEmpty) return;
    final novo = html_parser.parseFragment(html);
    Node anterior = inicio;
    for (final n in novo.nodes.toList()) {
      n.remove();
      _inserirDepois(anterior, n);
      anterior = n;
    }
  }

  // --------------------------------------------------------- utilidades

  static List<Element> _blocos(DocumentFragment frag) => frag
      .querySelectorAll('p,h1,h2,h3,h4,h5,h6,div,li')
      .where((e) => e.querySelector('p,div,h1,h2,h3,h4,h5,h6,table') == null)
      .toList();

  static Element? _bloco(DocumentFragment frag, RegExp re) =>
      _blocos(frag).where((e) => re.hasMatch(_norm(e.text))).firstOrNull;

  static Element? _blocoDepois(DocumentFragment frag, Element ref, RegExp re) {
    final blocos = _blocos(frag);
    final i = blocos.indexOf(ref);
    return blocos
        .skip(i + 1)
        .where((e) => re.hasMatch(_norm(e.text)))
        .firstOrNull;
  }

  /// Troca o texto do bloco preservando a formatação do elemento mais
  /// interno (ex.: <p><strong>texto</strong></p>).
  static void _definirTexto(Element bloco, String texto) {
    var alvo = bloco;
    while (alvo.children.length == 1 &&
        alvo.nodes.whereType<Text>().every((t) => t.text.trim().isEmpty)) {
      alvo = alvo.children.first;
    }
    alvo.text = texto;
  }

  static void _inserirDepois(Node ref, Node novo) {
    final pai = ref.parentNode!;
    final i = pai.nodes.indexOf(ref);
    if (i + 1 >= pai.nodes.length) {
      pai.append(novo);
    } else {
      pai.insertBefore(novo, pai.nodes[i + 1]);
    }
  }

  static void _inserirAntes(Node ref, Node novo) =>
      ref.parentNode!.insertBefore(novo, ref);

  static String _norm(String? value) => (value ?? '')
      .toLowerCase()
      .replaceAll(RegExp(r'[áàãâä]'), 'a')
      .replaceAll(RegExp(r'[éèêë]'), 'e')
      .replaceAll(RegExp(r'[íìîï]'), 'i')
      .replaceAll(RegExp(r'[óòôõö]'), 'o')
      .replaceAll(RegExp(r'[úùûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
