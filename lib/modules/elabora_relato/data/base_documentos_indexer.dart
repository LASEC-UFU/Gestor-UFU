import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/ai_agent/agent_files.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';

/// Parágrafo extraído de um documento, antes do agrupamento em trechos.
typedef ParagrafoFonte = ({String texto, int pagina, bool titulo});

/// O que mudou numa atualização da base.
class ResumoAtualizacao {
  ResumoAtualizacao();

  final novos = <String>[];
  final atualizados = <String>[];
  final removidos = <String>[];
  final reaproveitados = <String>[];
  final semTexto = <String>[];
  final erros = <String>[];
  String arquivoJson = '';

  bool get mudou =>
      novos.isNotEmpty || atualizados.isNotEmpty || removidos.isNotEmpty;

  String get descricao {
    final partes = [
      if (novos.isNotEmpty) '${novos.length} novo(s)',
      if (atualizados.isNotEmpty) '${atualizados.length} atualizado(s)',
      if (removidos.isNotEmpty) '${removidos.length} removido(s)',
      '${reaproveitados.length} sem alteração',
      if (semTexto.isNotEmpty) '${semTexto.length} sem texto extraível',
      if (erros.isNotEmpty) '${erros.length} com erro',
    ];
    return partes.join(', ');
  }
}

/// Prepara a [BaseDocumentos] de uma pasta: extrai o texto de PDF (camada
/// de texto), DOCX, TXT/MD e HTML, divide em trechos com a localização e
/// grava o JSON na própria pasta. Só reprocessa arquivos novos ou
/// alterados; os originais nunca são modificados.
class BaseDocumentosIndexer {
  const BaseDocumentosIndexer._();

  /// Nome do JSON da base, gravado na pasta dos documentos.
  static const nomeArquivo = 'base_consulta.gestor.json';

  static const _extensoesTexto = {'.txt', '.md', '.html', '.htm'};
  static const extensoesSuportadas = {'.pdf', '.docx', ..._extensoesTexto};
  static const _limiteBytes = 150 * 1024 * 1024;

  static String caminhoJson(String pasta) => p.join(pasta, nomeArquivo);

  /// Lê o JSON da base da [pasta] (null se não existir ou for inválido).
  static Future<BaseDocumentos?> carregar(String pasta) async {
    final file = File(caminhoJson(pasta));
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      final base = BaseDocumentos.fromJson(Map<String, dynamic>.from(json));
      return BaseDocumentos(
        pasta: pasta,
        documentos: base.documentos,
        geradoEm: base.geradoEm,
      );
    } catch (_) {
      return null;
    }
  }

  /// Arquivos fora da base: o próprio JSON (e o temporário da gravação),
  /// arquivos de bloqueio do Office (~$), ocultos e pastas ocultas.
  static bool ignorado(String rel) {
    final partes = rel.replaceAll('\\', '/').split('/');
    final nome = partes.last;
    return nome == nomeArquivo ||
        nome == '$nomeArquivo.tmp' ||
        nome.startsWith('~\$') ||
        nome.toLowerCase().endsWith('.tmp') ||
        partes.any((x) => x.startsWith('.'));
  }

  /// Arquivos que a base deve cobrir (relativos à pasta, com "/").
  static Future<Map<String, File>> listarArquivos(String pasta) async {
    final dir = Directory(pasta);
    if (!await dir.exists()) {
      throw StateError('A pasta da base não existe: $pasta');
    }
    final out = <String, File>{};
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: pasta).replaceAll('\\', '/');
      if (ignorado(rel)) continue;
      out[rel] = e;
    }
    return out;
  }

  /// Verifica, só pelos metadados (tamanho/data), se a base está em dia com
  /// a pasta. Barato: não lê o conteúdo dos arquivos.
  static Future<bool> emDia(BaseDocumentos base) async {
    final arquivos = await listarArquivos(base.pasta);
    if (arquivos.length != base.documentos.length) return false;
    final porNome = {for (final d in base.documentos) d.arquivo: d};
    for (final e in arquivos.entries) {
      final d = porNome[e.key];
      if (d == null) return false;
      final stat = await e.value.stat();
      if (stat.size != d.tamanho || !_mesmaData(stat.modified, d.modificado)) {
        return false;
      }
    }
    return true;
  }

  static bool _mesmaData(DateTime a, DateTime b) =>
      (a.millisecondsSinceEpoch - b.millisecondsSinceEpoch).abs() < 1000;

  /// Atualiza a base da [pasta] a partir da [anterior]: reaproveita os
  /// arquivos sem alteração, processa os novos/alterados e retira os
  /// removidos. Grava o JSON e devolve a base com o resumo.
  static Future<(BaseDocumentos, ResumoAtualizacao)> atualizar(
    String pasta, {
    BaseDocumentos? anterior,
    bool forcar = false,
    void Function(String arquivo, int atual, int total)? progresso,
  }) async {
    final resumo = ResumoAtualizacao();
    final arquivos = await listarArquivos(pasta);
    final antigos = {
      for (final d in anterior?.documentos ?? const <DocumentoBase>[])
        d.arquivo: d,
    };
    final documentos = <DocumentoBase>[];
    final nomes = arquivos.keys.toList()..sort();
    for (var i = 0; i < nomes.length; i++) {
      final rel = nomes[i];
      final file = arquivos[rel]!;
      progresso?.call(rel, i + 1, nomes.length);
      final stat = await file.stat();
      final velho = antigos[rel];
      if (!forcar &&
          velho != null &&
          velho.tamanho == stat.size &&
          _mesmaData(velho.modificado, stat.modified)) {
        documentos.add(velho);
        resumo.reaproveitados.add(rel);
        _contarSemTexto(velho, resumo);
        continue;
      }
      final ext = p.extension(rel).toLowerCase();
      final suportado = extensoesSuportadas.contains(ext);
      String hash = '';
      if (suportado && stat.size <= _limiteBytes) {
        hash = sha1.convert(await file.readAsBytes()).toString();
        if (!forcar && velho != null && velho.hash == hash) {
          // Só a data mudou (cópia, sincronização): mesmo conteúdo.
          documentos.add(velho.comArquivo(modificado: stat.modified));
          resumo.reaproveitados.add(rel);
          _contarSemTexto(velho, resumo);
          continue;
        }
      }
      final doc = await processar(
        file.path,
        rel,
        tamanho: stat.size,
        modificado: stat.modified,
        hash: hash,
      );
      documentos.add(doc);
      (velho == null ? resumo.novos : resumo.atualizados).add(rel);
      _contarSemTexto(doc, resumo);
    }
    resumo.removidos.addAll(
      antigos.keys.where((k) => !arquivos.containsKey(k)),
    );
    final base = BaseDocumentos(pasta: pasta, documentos: documentos);
    resumo.arquivoJson = await _gravar(base);
    return (base, resumo);
  }

  static void _contarSemTexto(DocumentoBase d, ResumoAtualizacao r) {
    switch (d.status) {
      case StatusDocumento.ok:
        break;
      case StatusDocumento.erro:
        r.erros.add('${d.arquivo}: ${d.mensagem}');
      case StatusDocumento.naoSuportado:
        break;
      case StatusDocumento.requerOcr || StatusDocumento.vazio:
        r.semTexto.add(d.arquivo);
    }
  }

  static Future<String> _gravar(BaseDocumentos base) async {
    final destino = caminhoJson(base.pasta);
    final texto = const JsonEncoder.withIndent(' ').convert(base.toJson());
    final tmp = File('$destino.tmp');
    await tmp.writeAsString(texto, encoding: utf8, flush: true);
    final alvo = File(destino);
    if (await alvo.exists()) await alvo.delete();
    await tmp.rename(destino);
    return destino;
  }

  /// Extrai e segmenta um arquivo.
  static Future<DocumentoBase> processar(
    String caminho,
    String rel, {
    required int tamanho,
    required DateTime modificado,
    required String hash,
  }) async {
    final ext = p.extension(rel).toLowerCase();
    final tipo = ext.isEmpty ? '' : ext.substring(1);
    DocumentoBase falha(StatusDocumento status, String mensagem) =>
        DocumentoBase(
          arquivo: rel,
          tamanho: tamanho,
          modificado: modificado,
          hash: hash,
          status: status,
          tipo: tipo,
          mensagem: mensagem,
        );

    if (!extensoesSuportadas.contains(ext)) {
      return falha(StatusDocumento.naoSuportado, switch (ext) {
        '.doc' => 'Word antigo (.doc): salve como .docx para indexar.',
        '.odt' || '.rtf' => 'Salve como .docx ou PDF para indexar.',
        '.jpg' || '.jpeg' || '.png' || '.tif' || '.tiff' || '.bmp' =>
          'Imagem: o texto só seria lido com OCR, que o Gestor não faz.',
        _ => 'Formato não indexado.',
      });
    }
    if (tamanho > _limiteBytes) {
      return falha(StatusDocumento.erro, 'Arquivo maior que 150 MB.');
    }
    final idBase = hash.isEmpty ? 'x' : hash.substring(0, 10);
    try {
      final (:paragrafos, :paginas, :semTexto) = await extrairParagrafos(
        caminho,
      );
      final trechos = await Isolate.run(
        () => segmentar(idBase, rel, paragrafos),
      );
      if (trechos.isEmpty) {
        return DocumentoBase(
          arquivo: rel,
          tamanho: tamanho,
          modificado: modificado,
          hash: hash,
          status: ext == '.pdf'
              ? StatusDocumento.requerOcr
              : StatusDocumento.vazio,
          tipo: tipo,
          paginas: paginas,
          mensagem: ext == '.pdf'
              ? 'PDF sem camada de texto (digitalizado). É necessário OCR, '
                    'que o Gestor não oferece; gere um PDF pesquisável e '
                    'atualize a base.'
              : 'Nenhum texto encontrado.',
        );
      }
      final inicio = paragrafos.take(40).map((x) => x.texto).join('\n');
      return DocumentoBase(
        arquivo: rel,
        tamanho: tamanho,
        modificado: modificado,
        hash: hash,
        status: StatusDocumento.ok,
        tipo: tipo,
        titulo: titulo(paragrafos, rel),
        norma: norma(inicio),
        paginas: paginas,
        paginasSemTexto: semTexto,
        mensagem: semTexto.isEmpty
            ? ''
            : '${semTexto.length} página(s) sem texto extraível (podem ser '
                  'imagens digitalizadas).',
        trechos: trechos,
      );
    } catch (e) {
      final msg = e is StateError ? e.message : '$e';
      return falha(StatusDocumento.erro, msg);
    }
  }

  /// Parágrafos de um arquivo (PDF com camada de texto, DOCX, TXT/MD,
  /// HTML), com a página (PDF) e as páginas sem texto extraível. Lança
  /// [StateError] para formato não suportado ou falha de leitura.
  static Future<
    ({List<ParagrafoFonte> paragrafos, int paginas, List<int> semTexto})
  >
  extrairParagrafos(String caminho) async {
    final ext = p.extension(caminho).toLowerCase();
    if (!extensoesSuportadas.contains(ext)) {
      throw StateError(
        'Formato não suportado ($ext). Use PDF, DOCX, TXT, MD ou HTML.',
      );
    }
    if (ext == '.pdf') {
      final pags = await AgentFiles.pdfPages(caminho);
      final semTexto = [
        for (var i = 0; i < pags.length; i++)
          if (pags[i].replaceAll(RegExp(r'\s'), '').length < 20) i + 1,
      ];
      final paragrafos = await Isolate.run(
        () => [
          for (var i = 0; i < pags.length; i++)
            ...paragrafosDeTexto(pags[i], pagina: i + 1),
        ],
      );
      return (paragrafos: paragrafos, paginas: pags.length, semTexto: semTexto);
    }
    if (ext == '.docx') {
      final bytes = await File(caminho).readAsBytes();
      final paragrafos = await Isolate.run(() => paragrafosDeDocx(bytes));
      return (paragrafos: paragrafos, paginas: 0, semTexto: const <int>[]);
    }
    var texto = utf8.decode(
      await File(caminho).readAsBytes(),
      allowMalformed: true,
    );
    if (ext == '.html' || ext == '.htm') texto = _textoDeHtml(texto);
    return (
      paragrafos: paragrafosDeTexto(texto),
      paginas: 0,
      semTexto: const <int>[],
    );
  }

  static String _textoDeHtml(String html) {
    final doc = html_parser.parse(html);
    for (final el in doc.querySelectorAll(
      'p, div, br, li, h1, h2, h3, h4, tr',
    )) {
      el.append(html_parser.parseFragment('\n'));
    }
    return doc.body?.text ?? doc.documentElement?.text ?? '';
  }

  // ------------------------------------------------------------ parágrafos

  static final _artigo = RegExp(
    r'^(?:Art(?:igo)?|ART(?:IGO)?)\.?\s*(\d+)\s*[º°o]?\s*(-\s*[A-Z]\b)?',
  );
  static final _cabecalho = RegExp(
    r'^(T[ÍI]TULO|CAP[ÍI]TULO|SE[ÇC][ÃA]O|SUBSE[ÇC][ÃA]O|ANEXO|LIVRO)\b',
    caseSensitive: false,
  );
  static final _inicioEstrutura = RegExp(
    r'^((?:Art(?:igo)?|ART(?:IGO)?)\.?\s*\d|§|Par[áa]grafo\s+[úu]nico|'
    r'PAR[ÁA]GRAFO\s+[ÚU]NICO|[IVXLC]{1,6}\s*[-–—.)]\s|[a-z]\)\s|'
    r'\d+(\.\d+)*[.)]\s+[A-ZÁÉÍÓÚÂÊÔÃÕÇ])',
  );
  static final _numeroPagina = RegExp(
    r'^(p[áa]gina\s+)?\d+(\s*(de|/)\s*\d+)?$',
    caseSensitive: false,
  );

  /// Divide o texto (de uma página, ou de um TXT) em parágrafos, juntando
  /// as linhas quebradas pelo PDF e separando dispositivos (artigos,
  /// parágrafos, incisos, alíneas) e títulos.
  static List<ParagrafoFonte> paragrafosDeTexto(
    String texto, {
    int pagina = 0,
  }) {
    final out = <ParagrafoFonte>[];
    final atual = StringBuffer();
    void fechar() {
      final t = atual.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
      atual.clear();
      if (t.isEmpty) return;
      out.add((texto: t, pagina: pagina, titulo: ehTitulo(t)));
    }

    for (final bruta in texto.split(RegExp(r'\r?\n'))) {
      final linha = bruta.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (linha.isEmpty) {
        fechar();
        continue;
      }
      if (_numeroPagina.hasMatch(linha)) continue;
      final anterior = atual.toString().trimRight();
      final novo =
          anterior.isEmpty ||
          _inicioEstrutura.hasMatch(linha) ||
          _cabecalho.hasMatch(linha) ||
          ehTitulo(anterior) ||
          (ehTitulo(linha) && !anterior.endsWith(',')) ||
          (RegExp(r'[.:;]$').hasMatch(anterior) &&
              RegExp(r'^[A-ZÁÉÍÓÚÂÊÔÃÕÇ0-9"“]').hasMatch(linha));
      if (novo) {
        fechar();
        atual.write(linha);
      } else if (anterior.endsWith('-') &&
          RegExp(r'^[a-záéíóúâêôãõç]').hasMatch(linha)) {
        // Palavra hifenizada na quebra de linha.
        atual
          ..clear()
          ..write(anterior.substring(0, anterior.length - 1))
          ..write(linha);
      } else {
        atual
          ..write(' ')
          ..write(linha);
      }
    }
    fechar();
    return out;
  }

  /// Parágrafos de um DOCX (estilos de título viram títulos).
  static List<ParagrafoFonte> paragrafosDeDocx(List<int> bytes) => [
    for (final par in AgentFiles.docxParagraphs(bytes))
      if (par.texto.trim().isNotEmpty)
        (
          texto: par.texto.replaceAll(RegExp(r'[ \t]+'), ' ').trim(),
          pagina: 0,
          titulo:
              RegExp(
                r'heading|t[ií]?tulo|ttulo|title',
                caseSensitive: false,
              ).hasMatch(par.estilo) ||
              ehTitulo(par.texto.trim()),
        ),
  ];

  /// Título de seção: TÍTULO/CAPÍTULO/SEÇÃO… ou linha curta toda em
  /// maiúsculas, sem ponto final.
  static bool ehTitulo(String t) {
    final s = t.trim();
    if (s.isEmpty || s.length > 140) return false;
    if (_cabecalho.hasMatch(s) && s.length < 140) {
      return s == s.toUpperCase() || s.length < 60;
    }
    if (s.endsWith('.') || s.endsWith(';') || s.endsWith(',')) return false;
    final letras = s.replaceAll(RegExp(r'[^A-Za-zÀ-ÿ]'), '');
    if (letras.length < 4) return false;
    return s == s.toUpperCase() && letras.length >= s.length * 0.5;
  }

  // -------------------------------------------------------------- trechos

  static const _maxArtigo = 1600;
  static const _maxTexto = 1000;

  /// Agrupa os parágrafos em trechos: um artigo (com seus parágrafos,
  /// incisos e alíneas) por trecho; fora de artigos, blocos de ~1000
  /// caracteres. Cada trecho guarda página, artigo, seção e o número do
  /// primeiro parágrafo.
  static List<TrechoBase> segmentar(
    String idBase,
    String arquivo,
    List<ParagrafoFonte> paragrafos,
  ) {
    final trechos = <TrechoBase>[];
    var secao = '';
    var artigo = '';
    final buffer = <String>[];
    var pagIni = 0, pagFim = 0, parIni = 0, tamanho = 0;
    var tituloPendente = false;

    void fechar() {
      if (buffer.isEmpty) return;
      trechos.add(
        TrechoBase(
          id: '$idBase-${trechos.length + 1}',
          arquivo: arquivo,
          texto: buffer.join('\n'),
          pagina: pagIni,
          paginaFim: pagFim,
          artigo: artigo,
          secao: secao,
          paragrafo: parIni,
        ),
      );
      buffer.clear();
      tamanho = 0;
    }

    for (var i = 0; i < paragrafos.length; i++) {
      final par = paragrafos[i];
      final numero = i + 1;
      if (par.titulo && !_artigo.hasMatch(par.texto)) {
        fechar();
        artigo = '';
        final rotulo = par.texto.length > 120
            ? '${par.texto.substring(0, 119)}…'
            : par.texto;
        // "CAPÍTULO II" + "DAS DISPOSIÇÕES GERAIS" → um só título.
        if (tituloPendente && secao.length + rotulo.length < 160) {
          secao = '$secao – $rotulo';
          tituloPendente = false;
        } else {
          secao = rotulo;
          tituloPendente =
              _cabecalho.hasMatch(rotulo) &&
              rotulo.split(RegExp(r'\s+')).length <= 3;
        }
        continue;
      }
      tituloPendente = false;
      final art = _artigo.firstMatch(par.texto);
      final limite = artigo.isNotEmpty || art != null ? _maxArtigo : _maxTexto;
      if (art != null) {
        fechar();
        final letra = (art.group(2) ?? '').replaceAll(RegExp(r'[\s-]'), '');
        artigo = 'Art. ${art.group(1)}${letra.isEmpty ? '' : '-$letra'}';
      } else if (tamanho > 0 && tamanho + par.texto.length > limite) {
        fechar();
      }
      if (buffer.isEmpty) {
        pagIni = par.pagina;
        parIni = numero;
      }
      // Parágrafo muito longo: fatia em pedaços (mesma localização).
      var resto = par.texto;
      while (resto.length > limite * 1.5) {
        var corte = resto.lastIndexOf(RegExp(r'[.;]\s'), limite);
        if (corte < limite ~/ 2) corte = resto.lastIndexOf(' ', limite);
        if (corte <= 0) corte = limite;
        buffer.add(resto.substring(0, corte + 1).trim());
        pagFim = par.pagina;
        fechar();
        pagIni = par.pagina;
        parIni = numero;
        resto = resto.substring(corte + 1).trim();
      }
      if (resto.isNotEmpty) {
        buffer.add(resto);
        tamanho += resto.length;
        pagFim = par.pagina;
      }
    }
    fechar();
    return trechos;
  }

  // -------------------------------------------------------- identificação

  static final _norma = RegExp(
    r'(resolu[çc][ãa]o|portaria|lei(?:\s+complementar)?|decreto(?:-lei)?|'
    r'instru[çc][ãa]o\s+normativa|norma\s+operacional|regimento|estatuto|'
    r'of[íi]cio(?:\s+circular)?|parecer|nota\s+t[ée]cnica|despacho|'
    r'deliberação|ato)\b[^\n]{0,60}?\bn[º°o.]?\s*[\d.]+(?:\s*[/,-]\s*\d{2,4})?',
    caseSensitive: false,
  );

  /// Identificação da norma no início do documento ("RESOLUÇÃO CONGRAD Nº
  /// 46, DE 2022"), ou ''.
  static String norma(String inicio) {
    final m = _norma.firstMatch(inicio);
    if (m == null) return '';
    return m.group(0)!.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Primeira linha com conteúdo que pareça título; senão o nome do arquivo.
  static String titulo(List<ParagrafoFonte> paragrafos, String arquivo) {
    for (final par in paragrafos.take(25)) {
      final t = par.texto.trim();
      if (t.length < 8 || t.length > 200) continue;
      if (RegExp(
        r'^(universidade|servi[çc]o p[úu]blico|minist[ée]rio|reitoria|'
        r'conselho)',
        caseSensitive: false,
      ).hasMatch(t)) {
        continue;
      }
      return t;
    }
    return p.basenameWithoutExtension(arquivo);
  }
}
