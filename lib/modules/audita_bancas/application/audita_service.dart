import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/audita_bancas/application/audita_pdf_exporter.dart';
import 'package:gestor_ufu/modules/audita_bancas/domain/auditoria.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/platform/services/poppler.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/ancora_texto.dart';

/// Resultado de uma análise.
typedef ResultadoAnalise = ({int criadas, int naoAncoradas});

/// Documentos auditados e suas observações. Cada documento fica numa chave
/// própria do banco (`audita_bancas.v1.documento.<id>`); a cópia do PDF fica em
/// Documentos\GestorUFU Agente\audita_bancas\documentos.
class AuditaService extends ChangeNotifier {
  AuditaService({
    KeyValueStore? store,
    this.ia,
    Future<String> Function()? pasta,
  }) : _store = store ?? KeyValueStore(),
       _pastaFn =
           pasta ?? (() => GestorPaths.outputDir('audita_bancas/documentos'));

  static const prefixo = 'audita_bancas.v1.documento.';
  static const limiteObservacoes = 400;
  static const tamanhoBloco = 9000;

  final KeyValueStore _store;
  final AiTextService? ia;
  final Future<String> Function() _pastaFn;
  final List<DocumentoAuditado> _documentos = [];
  bool _carregado = false;

  List<DocumentoAuditado> get documentos => List.unmodifiable(_documentos);

  Future<String> pasta() => _pastaFn();

  DocumentoAuditado? documento(String id) =>
      _documentos.where((d) => d.id == id).firstOrNull;

  Future<void> carregar({bool forcar = false}) async {
    if (_carregado && !forcar) return;
    _carregado = true;
    // Monta a lista nova antes de trocar: quem consultar durante a leitura
    // continua vendo os documentos.
    final lidos = <DocumentoAuditado>[];
    for (final k in await _store.keys(prefixo)) {
      final raw = await _store.readJson(k);
      if (raw is Map) {
        lidos.add(DocumentoAuditado.fromJson(Map<String, dynamic>.from(raw)));
      }
    }
    _documentos
      ..clear()
      ..addAll(lidos);
    _documentos.sort(
      (a, b) =>
          (b.abertoEm ?? DateTime(0)).compareTo(a.abertoEm ?? DateTime(0)),
    );
    notifyListeners();
  }

  Future<void> _gravar(DocumentoAuditado d) async {
    await _store.writeJson('$prefixo${d.id}', d.toJson());
    final i = _documentos.indexWhere((x) => x.id == d.id);
    if (i < 0) {
      _documentos.insert(0, d);
    } else {
      _documentos[i] = d;
    }
    notifyListeners();
  }

  /// Abre o PDF [origem]: guarda uma cópia (o original não muda) e reabre o
  /// documento já auditado se for o mesmo arquivo.
  Future<DocumentoAuditado> abrirPdf(String origem) async {
    await carregar();
    final f = File(origem);
    if (!await f.exists()) {
      throw CommandException(
        'arquivo_nao_encontrado',
        'Arquivo não encontrado: $origem',
      );
    }
    if (p.extension(origem).toLowerCase() != '.pdf') {
      throw const CommandException(
        'formato_nao_suportado',
        'O Audita Bancas analisa arquivos PDF.',
      );
    }
    final bytes = await f.readAsBytes();
    final hash = sha1.convert(bytes).toString();
    final pasta = await _pastaFn();
    await Directory(pasta).create(recursive: true);
    final copia = File(p.join(pasta, '$hash.pdf'));
    if (!await copia.exists()) await copia.writeAsBytes(bytes, flush: true);
    final existente = _documentos.where((d) => d.hash == hash).firstOrNull;
    final doc =
        (existente ??
                DocumentoAuditado(
                  id: const Uuid().v4(),
                  nome: p.basename(origem),
                  hash: hash,
                ))
            .copyWith(origem: origem, abertoEm: DateTime.now());
    await _gravar(doc);
    return doc;
  }

  Future<void> remover(String id) async {
    await _store.remove('$prefixo$id');
    _documentos.removeWhere((d) => d.id == id);
    notifyListeners();
  }

  DocumentoAuditado _exigir(String id) {
    final d = documento(id);
    if (d == null) {
      throw CommandException(
        'documento_inexistente',
        'Documento não encontrado.',
      );
    }
    return d;
  }

  Future<void> salvarObservacao(String docId, Observacao o) async {
    final d = _exigir(docId);
    final lista = [...d.observacoes];
    final i = lista.indexWhere((x) => x.id == o.id);
    if (i < 0) {
      lista.add(o);
    } else {
      lista[i] = o;
    }
    await _gravar(d.copyWith(observacoes: ordenar(lista)));
  }

  Future<void> excluirObservacao(String docId, String id) async {
    final d = _exigir(docId);
    await _gravar(
      d.copyWith(observacoes: d.observacoes.where((o) => o.id != id).toList()),
    );
  }

  Future<void> definirRevisao(String docId, String id, Revisao r) async {
    final o = _exigir(docId).observacoes.where((x) => x.id == id).firstOrNull;
    if (o != null) await salvarObservacao(docId, o.copyWith(revisao: r));
  }

  /// Ordem do documento: página e posição (as não localizadas no fim).
  static List<Observacao> ordenar(List<Observacao> lista) =>
      [...lista]..sort((a, b) {
        final pa = a.ancorada ? a.pagina : 1 << 20;
        final pb = b.ancorada ? b.pagina : 1 << 20;
        return pa != pb ? pa.compareTo(pb) : a.inicio.compareTo(b.inicio);
      });

  /// Nova observação ancorada no trecho [inicio]..[fim] da [pagina].
  static Observacao novaObservacao({
    required int pagina,
    required String textoPagina,
    required int inicio,
    required int fim,
    String problema = '',
    String importancia = '',
    String melhoria = '',
    String categoria = '',
    bool manual = true,
  }) {
    final a = inicio.clamp(0, textoPagina.length);
    final b = fim.clamp(a, textoPagina.length);
    return Observacao(
      id: const Uuid().v4(),
      trecho: textoPagina
          .substring(a, b)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
      pagina: pagina,
      inicio: a,
      fim: b,
      problema: problema,
      importancia: importancia,
      melhoria: melhoria,
      categoria: categoria,
      manual: manual,
    );
  }

  // ------------------------------------------------------------- análise

  /// Blocos de até [tamanhoBloco] caracteres com o texto das páginas
  /// (página inteira quando cabe; páginas longas são divididas).
  static List<List<({int pagina, String texto})>> blocos(List<String> paginas) {
    final out = <List<({int pagina, String texto})>>[];
    var atual = <({int pagina, String texto})>[];
    var tamanho = 0;
    for (var i = 0; i < paginas.length; i++) {
      var resto = paginas[i].trim();
      while (resto.isNotEmpty) {
        final cabe = tamanhoBloco - tamanho;
        if (cabe < 500 && atual.isNotEmpty) {
          out.add(atual);
          atual = [];
          tamanho = 0;
          continue;
        }
        final parte = resto.length <= cabe ? resto : resto.substring(0, cabe);
        atual.add((pagina: i + 1, texto: parte));
        tamanho += parte.length;
        resto = resto.substring(parte.length);
      }
    }
    if (atual.isNotEmpty) out.add(atual);
    return out;
  }

  static const sistemaAnalise =
      'Você é um revisor acadêmico de TCCs, dissertações e teses. Escreva '
      'para o autor, em português direto, didático e respeitoso. Use somente '
      'os critérios recebidos; não invente normas. Retorne SOMENTE um JSON '
      'array com até 8 objetos, cada um com: trecho (citação literal curta do '
      'documento, até 220 caracteres, copiada exatamente), categoria '
      '(Editorial, Metodológica ou Norma a confirmar), problema (qual é o '
      'ponto que precisa de atenção, em frase completa), importancia (por que '
      'merece revisão) e melhoria (o que fazer para melhorar). Não use '
      'rótulos soltos no lugar de explicações. Se não houver problemas '
      'justificáveis, retorne [].';

  static String promptAnalise(
    String criterios,
    List<({int pagina, String texto})> bloco,
    int numero,
    int total,
  ) =>
      'Critérios/rubrica/normas fornecidos pelo usuário:\n'
      '${criterios.trim().isEmpty ? '(nenhum; limite-se a recomendações editoriais gerais)' : criterios.trim()}\n\n'
      'Parte $numero/$total do documento:\n'
      '${bloco.map((b) => '[p. ${b.pagina}] ${b.texto}').join('\n')}';

  /// Lista JSON da resposta (tolera ```json e texto em volta).
  static List<Map<String, dynamic>> lerResposta(String texto) {
    final t = texto.trim();
    final a = t.indexOf('['), b = t.lastIndexOf(']');
    if (a < 0 || b < a) {
      throw const FormatException(
        'A resposta do modelo não veio no formato JSON esperado.',
      );
    }
    final v = jsonDecode(t.substring(a, b + 1));
    if (v is! List) {
      throw const FormatException(
        'A resposta da análise não é uma lista de observações.',
      );
    }
    return [
      for (final x in v)
        if (x is Map) Map<String, dynamic>.from(x),
    ];
  }

  /// Observação de um item da resposta, ancorada nas [paginas] (preferindo
  /// as páginas do bloco analisado).
  static Observacao observacaoDeItem(
    Map<String, dynamic> item,
    List<String> paginas, {
    Iterable<int> preferidas = const [],
  }) {
    final trecho = '${item['trecho'] ?? ''}'.trim();
    final ordem = [
      ...preferidas,
      for (var n = 1; n <= paginas.length; n++)
        if (!preferidas.contains(n)) n,
    ];
    for (final n in ordem) {
      if (n < 1 || n > paginas.length) continue;
      final r = localizarTrecho(trecho, paginas[n - 1]);
      if (r != null) {
        return novaObservacao(
          pagina: n,
          textoPagina: paginas[n - 1],
          inicio: r.inicio,
          fim: r.fim,
          categoria: '${item['categoria'] ?? ''}'.trim(),
          problema: '${item['problema'] ?? ''}'.trim(),
          importancia: '${item['importancia'] ?? ''}'.trim(),
          melhoria: '${item['melhoria'] ?? ''}'.trim(),
          manual: false,
        );
      }
    }
    return Observacao(
      id: const Uuid().v4(),
      trecho: trecho,
      categoria: '${item['categoria'] ?? ''}'.trim(),
      problema: '${item['problema'] ?? ''}'.trim(),
      importancia: '${item['importancia'] ?? ''}'.trim(),
      melhoria: '${item['melhoria'] ?? ''}'.trim(),
    );
  }

  /// Analisa o documento com a IA, bloco a bloco, a partir do texto das
  /// [paginas] (o mesmo do visualizador). Observações iguais (mesmo trecho
  /// e página) já existentes são atualizadas, sem duplicar.
  Future<ResultadoAnalise> analisar(
    String docId,
    List<String> paginas, {
    String criterios = '',
    void Function(String etapa)? progresso,
  }) async {
    final ai = ia;
    if (ai == null) {
      throw const CommandException(
        'ia_indisponivel',
        'O Agente de IA não está configurado.',
      );
    }
    if (paginas.every((t) => t.trim().isEmpty)) {
      throw const CommandException(
        'sem_texto',
        'O PDF não tem camada de texto pesquisável (digitalizado). OCR não '
            'está disponível.',
      );
    }
    final doc = _exigir(docId);
    await _gravar(doc.copyWith(criterios: criterios));
    final lista = blocos(paginas);
    var criadas = 0, naoAncoradas = 0, total = 0;
    for (var i = 0; i < lista.length; i++) {
      progresso?.call('Analisando a parte ${i + 1} de ${lista.length}…');
      final resposta = await ai.gerar(
        sistema: sistemaAnalise,
        prompt: promptAnalise(criterios, lista[i], i + 1, lista.length),
      );
      final itens = lerResposta(resposta);
      total += itens.length;
      if (total > limiteObservacoes) {
        throw const CommandException(
          'limite',
          'Limite de segurança de $limiteObservacoes observações atingido; '
              'refine os critérios para reduzir os resultados.',
        );
      }
      final atuais = [..._exigir(docId).observacoes];
      for (final item in itens) {
        if ('${item['trecho'] ?? ''}'.trim().isEmpty) continue;
        var o = observacaoDeItem(
          item,
          paginas,
          preferidas: {for (final b in lista[i]) b.pagina},
        );
        if (!o.ancorada) naoAncoradas++;
        final igual = atuais.indexWhere(
          (x) =>
              !x.manual &&
              x.pagina == o.pagina &&
              x.trecho.toLowerCase() == o.trecho.toLowerCase(),
        );
        if (igual >= 0) {
          o = atuais[igual].copyWith(
            categoria: o.categoria,
            problema: o.problema,
            importancia: o.importancia,
            melhoria: o.melhoria,
          );
          atuais[igual] = o;
        } else {
          atuais.add(o);
          criadas++;
        }
      }
      await _gravar(_exigir(docId).copyWith(observacoes: ordenar(atuais)));
    }
    return (criadas: criadas, naoAncoradas: naoAncoradas);
  }

  /// Caminho da cópia guardada do PDF.
  Future<String> caminhoPdf(DocumentoAuditado d) async =>
      p.join(await _pastaFn(), d.arquivo);

  /// Texto das páginas do PDF guardado (Poppler), para os comandos, que
  /// rodam sem o visualizador aberto.
  Future<List<String>> paginasDoPdf(String docId) async =>
      Poppler.paginasDeTexto(await caminhoPdf(_exigir(docId)));

  /// Confere as âncoras no texto das [paginas] do visualizador e relocaliza
  /// as que não batem (análises feitas pelos comandos usam o texto do
  /// Poppler, que difere um pouco do pdf.js). Devolve quantas continuam sem
  /// trecho no documento.
  Future<int> reancorar(String docId, List<String> paginas) async {
    final d = documento(docId);
    if (d == null || paginas.isEmpty) return 0;
    var mudou = false, semTrecho = 0;
    final lista = <Observacao>[];
    for (final o in d.observacoes) {
      if (o.trecho.isEmpty) {
        lista.add(o);
        continue;
      }
      final confere =
          o.ancorada &&
          o.pagina <= paginas.length &&
          o.fim <= paginas[o.pagina - 1].length &&
          localizarTrecho(
                o.trecho,
                paginas[o.pagina - 1].substring(o.inicio, o.fim),
              ) !=
              null;
      if (confere) {
        lista.add(o);
        continue;
      }
      final nova = observacaoDeItem(
        {'trecho': o.trecho},
        paginas,
        preferidas: [if (o.pagina > 0) o.pagina],
      );
      if (!nova.ancorada) {
        semTrecho++;
        lista.add(o);
        continue;
      }
      mudou = true;
      lista.add(
        Observacao(
          id: o.id,
          trecho: o.trecho,
          pagina: nova.pagina,
          inicio: nova.inicio,
          fim: nova.fim,
          categoria: o.categoria,
          problema: o.problema,
          importancia: o.importancia,
          melhoria: o.melhoria,
          revisao: o.revisao,
          manual: o.manual,
        ),
      );
    }
    if (mudou) await _gravar(d.copyWith(observacoes: ordenar(lista)));
    return semTrecho;
  }

  /// Caminho livre ao lado do PDF de origem: `<nome>_audita_bancas<ext>`
  /// (sem a origem, na pasta de saídas do Gestor).
  Future<String> caminhoSaida(DocumentoAuditado d, String ext) async {
    final origem = d.origem.isNotEmpty && await File(d.origem).parent.exists()
        ? d.origem
        : p.join(await GestorPaths.outputDir('audita_bancas'), d.nome);
    final base = p.join(
      p.dirname(origem),
      '${p.basenameWithoutExtension(origem)}_audita_bancas',
    );
    var c = '$base$ext';
    for (var i = 2; await File(c).exists(); i++) {
      c = '$base ($i)$ext';
    }
    return c;
  }

  /// Grava o relatório em texto; devolve o caminho.
  Future<String> exportarRelatorio(String docId, {String? caminho}) async {
    final d = _exigir(docId);
    final destino = caminho ?? await caminhoSaida(d, '.txt');
    await File(destino).writeAsString(relatorio(d));
    return destino;
  }

  /// Gera o PDF anotado com as observações aceitas; devolve o caminho.
  Future<String> exportarPdf(
    String docId, {
    String? caminho,
    void Function(String etapa)? progresso,
  }) async {
    final d = _exigir(docId);
    final aceitas = [
      for (final o in d.observacoes)
        if (o.revisao == Revisao.aceita) o,
    ];
    if (aceitas.isEmpty) {
      throw const CommandException(
        'sem_aceitas',
        'Aceite pelo menos uma observação antes de exportar o PDF anotado.',
      );
    }
    final destino = caminho ?? await caminhoSaida(d, '.pdf');
    try {
      await AuditaPdfExporter.export(
        source: await caminhoPdf(d),
        comments: aceitas,
        target: destino,
        onProgress: progresso,
      );
    } on StateError catch (e) {
      throw CommandException('exportacao_falhou', e.message);
    }
    return destino;
  }

  /// Relatório em texto com todas as observações.
  static String relatorio(DocumentoAuditado d) {
    final b = StringBuffer('Audita Bancas — ${d.nome}\n\n');
    for (final o in d.observacoes) {
      b
        ..writeln(
          '${o.revisao.rotulo.toUpperCase()} • '
          '${o.ancorada ? 'página ${o.pagina}' : 'sem página'}'
          '${o.categoria.isEmpty ? '' : ' • ${o.categoria}'}',
        )
        ..writeln('Trecho: ${o.trecho}')
        ..writeln(o.texto)
        ..writeln();
    }
    return b.toString();
  }
}
