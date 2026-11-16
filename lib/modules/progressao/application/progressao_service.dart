import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/progressao/application/progressao_comprovantes_service.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_pdf_service.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_sei_requerimento.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_sei_text.dart';
import 'package:gestor_ufu/modules/progressao/data/progressao_store.dart';
import 'package:gestor_ufu/modules/progressao/domain/comprovantes.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/modules/progressao/domain/resolucao_condir_03_2017.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

const _uuid = Uuid();

String _nomeArvoreCurto(String nome) {
  final limpo = nome.trim();
  return limpo.length <= limiteNomeArvoreSei
      ? limpo
      : limpo.substring(0, limiteNomeArvoreSei);
}

class ProgressaoDossieSeiOpcoes {
  const ProgressaoDossieSeiOpcoes({
    this.criarNovo = false,
    this.numeroProcesso = '',
    this.tipoProcesso = '',
    this.especificacao = '',
    this.interessado = '',
    this.acessoComprovantes = AcessoComprovantesSei.restrito,
    this.incluirRequerimento = true,
    this.incluirComprovantes = true,
    this.incluirTitulacao = true,
    this.incluirRelatorio = true,
    this.confirmarNovoComProcessoSalvo = false,
  });

  final bool criarNovo;
  final String numeroProcesso;
  final String tipoProcesso;
  final String especificacao;
  final String interessado;
  final AcessoComprovantesSei acessoComprovantes;
  final bool incluirRequerimento;
  final bool incluirComprovantes;
  final bool incluirTitulacao;
  final bool incluirRelatorio;
  final bool confirmarNovoComProcessoSalvo;
}

class ProgressaoDossieSeiResultado {
  const ProgressaoDossieSeiResultado({
    required this.numeroProcesso,
    required this.requerimento,
    required this.comprovantesNovos,
    required this.comprovantesExistentes,
    required this.titulacao,
    required this.relatorio,
    this.pendencias = const [],
  });

  final String numeroProcesso;
  final String requerimento;
  final int comprovantesNovos;
  final int comprovantesExistentes;
  final String titulacao;
  final String relatorio;
  final List<String> pendencias;
}

/// Estado do envio de comprovantes ao SEI: o Edge controlado e o log
/// continuam disponíveis ao trocar de aba ou de tela (e para o agente).
class ProgressaoEnvioSei extends ChangeNotifier {
  final automation = SeiAutomationService();
  final logs = <String>[];
  String url = 'https://sei.ufu.br';
  bool enviando = false;
  bool cancelar = false;

  void log(String mensagem) {
    final agora = DateTime.now();
    final hora =
        '${agora.hour.toString().padLeft(2, '0')}:'
        '${agora.minute.toString().padLeft(2, '0')}';
    logs.insert(0, '$hora  $mensagem');
    if (logs.length > 300) logs.removeLast();
    notifyListeners();
  }

  void atualizar() => notifyListeners();

  @override
  void dispose() {
    automation.close();
    super.dispose();
  }
}

/// Regras da Progressão / Promoção. A tela e os comandos (inclusive os do
/// Agente de IA) usam os mesmos métodos.
class ProgressaoService extends ChangeNotifier {
  ProgressaoService(
    this._store, {
    this.comprovantes = const ProgressaoComprovantesService(),
  });

  final ProgressaoStore _store;
  final ProgressaoComprovantesService comprovantes;
  final envio = ProgressaoEnvioSei();

  List<ProgressaoDocente> _items = [];
  bool _loaded = false;
  Timer? _saveTimer;

  List<ProgressaoDocente> get items => List.unmodifiable(_items);
  bool get isLoaded => _loaded;

  ProgressaoDocente? byId(String id) {
    for (final p in _items) {
      if (p.id == id) return p;
    }
    return null;
  }

  ProgressaoDocente _require(String id) =>
      byId(id) ??
      (throw CommandException(
        'processo_nao_encontrado',
        'Processo "$id" não encontrado.',
      ));

  /// Relê o banco (grava antes o que estiver pendente).
  Future<List<ProgressaoDocente>> load({bool flushPending = true}) async {
    if (flushPending) {
      await flush();
    } else {
      _saveTimer?.cancel();
      _saveTimer = null;
    }
    _items = await _store.list();
    _loaded = true;
    notifyListeners();
    return items;
  }

  Future<void> _ensure() async {
    if (!_loaded) await load();
  }

  /// Insere ou atualiza um processo. [debounce] agrupa gravações rápidas
  /// (edição campo a campo na tela).
  Future<ProgressaoDocente> save(
    ProgressaoDocente p, {
    bool debounce = false,
  }) async {
    final updated = p.copyWith(atualizadoEm: DateTime.now());
    final i = _items.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      _items[i] = updated;
    } else {
      _items.insert(0, updated);
    }
    notifyListeners();
    _saveTimer?.cancel();
    if (debounce) {
      _saveTimer = Timer(
        const Duration(milliseconds: 500),
        () => _store.saveAll(_items),
      );
    } else {
      await _store.saveAll(_items);
    }
    return updated;
  }

  /// Grava agora o que estiver aguardando o debounce.
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _store.saveAll(_items);
    }
  }

  Future<ProgressaoDocente> create({
    required String pastaComprovantes,
    String docente = '',
  }) async {
    await _ensure();
    if (pastaComprovantes.trim().isEmpty) {
      throw const CommandException(
        'pasta_obrigatoria',
        'Escolha a pasta onde os comprovantes do processo serão salvos.',
      );
    }
    return save(
      ProgressaoDocente(
        id: _uuid.v4(),
        docente: docente,
        dataDocumento: DateTime.now(),
        pastaComprovantes: pastaComprovantes.trim(),
      ),
    );
  }

  Future<ProgressaoDocente> duplicate(String id) async {
    await _ensure();
    final json = _require(id).toJson()
      ..['id'] = _uuid.v4()
      ..['atualizadoEm'] = null;
    return save(ProgressaoDocente.fromJson(json));
  }

  Future<ProgressaoDocente> remove(String id) async {
    await _ensure();
    final p = _require(id);
    _saveTimer?.cancel();
    _items.removeWhere((e) => e.id == id);
    notifyListeners();
    await _store.saveAll(_items);
    return p;
  }

  /// Nome sugerido para o PDF do processo.
  static String pdfFileName(ProgressaoDocente p) {
    final nome = p.docente.trim().isEmpty
        ? 'docente'
        : p.docente.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
    final alvo = p.alvo.denominacao(p.titulacao).replaceAll(' ', '');
    return 'Progressao_${alvo}_${nome.replaceAll(RegExp(r'\s+'), '')}.pdf';
  }

  /// Gera o requerimento + relatório em PDF e grava em [path].
  Future<String> exportPdf(String id, String path) async {
    await _ensure();
    final bytes = await ProgressaoPdfService().gerar(_require(id));
    final file = File(path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  // ---------------------------------------------------------- lançamentos

  /// Acrescenta um lançamento do item [item] do Anexo 1 (logo após os
  /// lançamentos do mesmo item, como na tela).
  Future<LancamentoProgressao> addLancamento(
    String id, {
    required int item,
    double quantidade = 0,
    String periodo = '',
    String descricao = '',
    DateTime? inicio,
    DateTime? fim,
  }) async {
    await _ensure();
    if (itemAnexo1(item) == null) {
      throw CommandException(
        'item_invalido',
        'O item $item não existe no Anexo 1 (1 a ${anexo1.length}).',
      );
    }
    final p = _require(id);
    final novo = LancamentoProgressao(
      id: _uuid.v4(),
      item: item,
      quantidade: quantidade,
      periodo: periodo,
      descricao: descricao,
      inicio: inicio,
      fim: fim,
    );
    final lista = List.of(p.lancamentos);
    final ultimo = lista.lastIndexWhere((l) => l.item == item);
    if (ultimo >= 0) {
      lista.insert(ultimo + 1, novo);
    } else {
      lista.add(novo);
    }
    await save(p.copyWith(lancamentos: lista));
    return novo;
  }

  Future<LancamentoProgressao> removeLancamento(
    String id,
    String lancamentoId,
  ) async {
    await _ensure();
    final p = _require(id);
    final alvo = p.lancamentos.where((l) => l.id == lancamentoId).firstOrNull;
    if (alvo == null) {
      throw CommandException(
        'lancamento_nao_encontrado',
        'Lançamento "$lancamentoId" não encontrado.',
      );
    }
    final semComprovante = await comprovantes.remover(p, alvo);
    await save(
      p.copyWith(
        lancamentos: p.lancamentos.where((l) => l.id != lancamentoId).toList(),
      ),
    );
    return semComprovante;
  }

  /// Copia o comprovante [origem] para a pasta do processo (renomeado, na
  /// subpasta da tabela) e o vincula ao lançamento.
  Future<LancamentoProgressao> attachComprovante(
    String id,
    String lancamentoId,
    String origem,
  ) async {
    await _ensure();
    final p = _require(id);
    if (p.pastaComprovantes.isEmpty) {
      throw const CommandException(
        'pasta_obrigatoria',
        'O processo não tem pasta de comprovantes.',
      );
    }
    if (!await File(origem).exists()) {
      throw CommandException(
        'arquivo_nao_encontrado',
        'Arquivo não encontrado: $origem',
      );
    }
    final ext = origem.split('.').last.toLowerCase();
    if (!extensoesComprovante.contains(ext)) {
      throw CommandException(
        'formato_invalido',
        'Comprovante precisa ser ${extensoesComprovante.join(', ')}.',
      );
    }
    final linha = p.lancamentos.where((l) => l.id == lancamentoId).firstOrNull;
    if (linha == null) {
      throw CommandException(
        'lancamento_nao_encontrado',
        'Lançamento "$lancamentoId" não encontrado.',
      );
    }
    final novo = await comprovantes.importar(
      processo: p,
      lancamento: linha,
      origem: origem,
    );
    await save(
      p.copyWith(
        lancamentos: [
          for (final l in p.lancamentos) l.id == lancamentoId ? novo : l,
        ],
      ),
    );
    return novo;
  }

  // ---------------------------------------------------------- SEI

  Future<String> abrirSei([String? url]) async {
    if (url != null && url.trim().isNotEmpty) envio.url = url.trim();
    final aberto = await envio.automation.openBrowser(envio.url);
    envio.log('Edge pronto em $aberto. Entre no SEI e abra o processo.');
    return aberto;
  }

  /// Comprovantes do processo que ainda não estão na pasta.
  List<String> comprovantesAusentes(ProgressaoDocente p) => [
    for (final l in lancamentosComComprovante(p))
      if (!comprovantes.existe(p, l)) l.rotuloComprovante,
  ];

  /// Fluxo completo e retomável de autuação e montagem do dossiê no SEI.
  Future<ProgressaoDossieSeiResultado> montarProcessoSei(
    String id,
    ProgressaoDossieSeiOpcoes opcoes,
  ) async {
    await _ensure();
    var p = _require(id);
    final pendencias = <String>[
      if (p.docente.trim().isEmpty) 'Informe o nome do docente.',
      if (p.siape.trim().isEmpty) 'Informe o SIAPE.',
      if (p.lotacao.trim().isEmpty) 'Informe a lotacao.',
      if (opcoes.incluirRequerimento && p.dataAdmissao == null)
        'Informe a data de admissao.',
      if (opcoes.incluirRequerimento && p.dataDocumento == null)
        'Informe a data do requerimento.',
      if (p.intersticioInicio == null || p.intersticioFim == null)
        'Informe inicio e fim do intersticio.',
      if (opcoes.incluirRelatorio &&
          (p.relatorioInicio == null || p.relatorioFim == null))
        'Informe inicio e fim do relatorio.',
      if (opcoes.incluirComprovantes && p.lancamentos.isEmpty)
        'Nao ha lancamentos para anexar.',
      if (opcoes.incluirComprovantes &&
          p.lancamentos.any((l) => l.comprovante.trim().isEmpty))
        'Todos os lancamentos precisam ter comprovante vinculado.',
      if (opcoes.incluirComprovantes && comprovantesAusentes(p).isNotEmpty)
        'Ha comprovantes ausentes: ${comprovantesAusentes(p).join(', ')}.',
      if (opcoes.incluirTitulacao && !comprovantes.titulacaoExiste(p))
        'Selecione o comprovante da ultima titulacao.',
      if (opcoes.incluirRelatorio && p.pastaComprovantes.trim().isEmpty)
        'Escolha a pasta dos comprovantes para gerar o relatorio.',
      if (opcoes.incluirRequerimento &&
          p.relatorioInicio != null &&
          p.intersticioInicio != null &&
          p.relatorioInicio!.isBefore(p.intersticioInicio!) &&
          p.justificativaIntersticio.trim().isEmpty)
        'Informe a justificativa quando o relatorio comeca antes do intersticio.',
    ];
    if (pendencias.isNotEmpty) {
      throw StateError('Pré-checagem: ${pendencias.join(' ')}');
    }
    if (p.pastaComprovantes.trim().isEmpty &&
        (opcoes.incluirComprovantes || opcoes.incluirTitulacao)) {
      throw StateError(
        'Escolha a pasta dos comprovantes na aba Comprovantes / SEI.',
      );
    }
    if (opcoes.criarNovo &&
        p.processoSei.trim().isNotEmpty &&
        !opcoes.confirmarNovoComProcessoSalvo) {
      throw StateError(
        'Já há o processo ${p.processoSei} salvo. Confirme explicitamente a criação de outro processo.',
      );
    }

    // Gera e grava o PDF antes de qualquer mudança no SEI.
    String? relatorioPath;
    if (opcoes.incluirRelatorio) {
      final bytes = await ProgressaoPdfService().gerarRelatorio(p);
      final pasta = Directory(p.pastaComprovantes);
      await pasta.create(recursive: true);
      final base = p.docente
          .trim()
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
          .replaceAll(RegExp(r'\s+'), '_');
      relatorioPath =
          '${pasta.path}${Platform.pathSeparator}'
          'Relatorio_Atividades_${base.isEmpty ? 'docente' : base}.pdf';
      await File(relatorioPath).writeAsBytes(bytes, flush: true);
    }

    final tipo = opcoes.tipoProcesso.trim().isEmpty
        ? tipoProcessoSugeridoSei(p)
        : opcoes.tipoProcesso.trim();
    final especificacao = opcoes.especificacao.trim().isEmpty
        ? especificacaoProcessoSei(p)
        : opcoes.especificacao.trim();
    final interessado = opcoes.interessado.trim().isEmpty
        ? p.docente.trim()
        : opcoes.interessado.trim();
    p = (await save(
      p.copyWith(
        tipoProcessoSei: tipo,
        especificacaoSei: especificacao,
        processoSei: opcoes.criarNovo
            ? p.processoSei
            : opcoes.numeroProcesso.trim(),
        acessoComprovantesSei: opcoes.acessoComprovantes,
      ),
    ));

    envio
      ..enviando = true
      ..cancelar = false
      ..atualizar();
    final seiFlow = ProgressaoSeiRequerimento(envio.automation);
    var requestStatus = 'não solicitado';
    var novos = 0;
    var existentes = 0;
    var titulacaoStatus = 'não solicitada';
    var relatorioStatus = 'não solicitado';
    try {
      if (!envio.automation.isConnected) {
        await abrirSei('https://sei.ufu.br');
      } else {
        await envio.automation.focus();
      }
      await seiFlow.aguardarLogin(log: envio.log);

      String numero;
      if (opcoes.criarNovo) {
        numero = await seiFlow.iniciarProcesso(
          p,
          tipo: tipo,
          especificacao: especificacao,
          interessado: interessado,
          hipoteseLegal: ProgressaoSeiRequerimento.hipotesePessoal,
          log: envio.log,
        );
        p = await save(p.copyWith(processoSei: numero));
        envio.log(
          'SEI: número $numero gravado no cadastro; a execução pode ser retomada neste processo.',
        );
      } else {
        final alvo = opcoes.numeroProcesso.trim();
        if (alvo.isNotEmpty) await seiFlow.abrirProcesso(alvo);
        numero = await seiFlow.numeroProcessoAtual();
        if (numero.isEmpty) {
          throw StateError(
            'Abra a árvore do processo no SEI ou informe o número do processo existente.',
          );
        }
        if (alvo.isNotEmpty && numero != alvo) {
          throw StateError(
            'O processo aberto é $numero, diferente do informado $alvo.',
          );
        }
        p = await save(p.copyWith(processoSei: numero));
        envio.log('SEI: processo existente confirmado: $numero.');
      }

      if (opcoes.incluirRequerimento) {
        requestStatus = await seiFlow.inserirRequerimento(p, log: envio.log)
            ? 'novo'
            : 'existente';
        if (envio.cancelar)
          throw StateError('Execução interrompida após o requerimento.');
      }

      if (opcoes.incluirComprovantes) {
        final lista = lancamentosComComprovante(p);
        final lote = await envio.automation.insertExternalBatch(
          documentos: [
            for (final l in lista)
              SeiDocumentoExterno(
                caminho: comprovantes.caminhoAbsoluto(p, l)!,
                nomeArvore: _nomeArvoreCurto(l.rotuloComprovante),
              ),
          ],
          serie: p.tipoDocumentoSei.trim().isEmpty
              ? ProgressaoDocente.tipoDocumentoSeiPadrao
              : p.tipoDocumentoSei.trim(),
          nivelAcesso:
              opcoes.acessoComprovantes == AcessoComprovantesSei.restrito
              ? SeiNivelAcesso.restrito
              : SeiNivelAcesso.publico,
          log: envio.log,
          cancelado: () => envio.cancelar,
        );
        novos += lote.criados.length;
        existentes += lote.existentes.length;
        if (lote.erros.isNotEmpty)
          throw StateError('Envio interrompido: ${lote.erros.join('; ')}');
      }

      if (opcoes.incluirTitulacao) {
        final diploma = 'Diploma de ${p.titulacao.rotulo}';
        final lote = await envio.automation.insertExternalBatch(
          documentos: [
            SeiDocumentoExterno(
              caminho: comprovantes.caminhoTitulacao(p)!,
              nomeArvore: '- $diploma',
              nomesAlternativos: [
                diploma,
                'Comprovante - $diploma',
                'Comprovante da ultima titulacao - ${p.titulacao.rotulo}',
              ],
            ),
          ],
          serie: 'Comprovante',
          nivelAcesso: SeiNivelAcesso.publico,
          log: envio.log,
          cancelado: () => envio.cancelar,
        );
        novos += lote.criados.length;
        existentes += lote.existentes.length;
        if (lote.erros.isNotEmpty)
          throw StateError('Falha ao anexar diploma: ${lote.erros.join('; ')}');
        titulacaoStatus = lote.criados.isEmpty ? 'existente' : 'incluída';
      }

      if (opcoes.incluirRelatorio) {
        final nome = 'de Atividades - ${p.docente.trim()}';
        final lote = await envio.automation.insertExternalBatch(
          documentos: [
            SeiDocumentoExterno(
              caminho: relatorioPath!,
              nomeArvore: nome.length > limiteNomeArvoreSei
                  ? nome.substring(0, limiteNomeArvoreSei)
                  : nome,
              nomesAlternativos: [
                'Relatório de Atividades - ${p.docente.trim()}',
              ],
            ),
          ],
          serie: 'Relatório',
          nivelAcesso: SeiNivelAcesso.publico,
          log: envio.log,
          cancelado: () => envio.cancelar,
        );
        novos += lote.criados.length;
        existentes += lote.existentes.length;
        if (lote.erros.isNotEmpty)
          throw StateError(
            'Falha ao anexar relatório: ${lote.erros.join('; ')}',
          );
        relatorioStatus = lote.criados.isEmpty ? 'existente' : 'incluído';
        if (lote.existentes.isNotEmpty) {
          envio.log(
            'SEI: relatório ativo já existe. Para substituir, cancele-o no SEI e execute novamente.',
          );
        }
      }

      await envio.automation.treeDocuments();
      final verificacoes = <String, List<String>>{
        if (opcoes.incluirRequerimento)
          'requerimento': ['Requerimento de Progressão / Promoção Docente'],
        if (opcoes.incluirComprovantes)
          for (final l in lancamentosComComprovante(p))
            l.rotuloComprovante: [l.rotuloComprovante],
        if (opcoes.incluirTitulacao)
          'titulação': [
            'Diploma de ${p.titulacao.rotulo}',
            'Comprovante - Diploma de ${p.titulacao.rotulo}',
            'Comprovante da ultima titulacao',
          ],
        if (opcoes.incluirRelatorio)
          'relatório': [
            'de Atividades - ${p.docente.trim()}',
            'Relatório de Atividades - ${p.docente.trim()}',
          ],
      };
      final faltantes = <String>[];
      for (final entry in verificacoes.entries) {
        if (!await envio.automation.existeDocumento(entry.value)) {
          faltantes.add(entry.key);
        }
      }
      if (faltantes.isNotEmpty) {
        throw StateError(
          'Conferência final: ausentes na árvore: ${faltantes.join(', ')}.',
        );
      }
      p = await save(
        p.copyWith(processoSei: numero, enviadoSeiEm: DateTime.now()),
      );
      envio.log(
        'Concluído: Processo $numero; requerimento $requestStatus; $novos comprovantes incluídos e $existentes já existentes; titulação $titulacaoStatus; relatório $relatorioStatus. Pendente: conferir e assinar o requerimento no SEI.',
      );
      return ProgressaoDossieSeiResultado(
        numeroProcesso: numero,
        requerimento: requestStatus,
        comprovantesNovos: novos,
        comprovantesExistentes: existentes,
        titulacao: titulacaoStatus,
        relatorio: relatorioStatus,
      );
    } finally {
      envio
        ..enviando = false
        ..atualizar();
    }
  }

  /// Inclui os comprovantes como documentos externos no processo aberto no
  /// Edge (os que já estão na árvore são mantidos).
  Future<SeiLoteResultado> enviarComprovantes(String id) async {
    await _ensure();
    final p = _require(id);
    final lista = lancamentosComComprovante(p);
    final ausentes = comprovantesAusentes(p);
    if (ausentes.isNotEmpty) {
      throw CommandException(
        'comprovantes_ausentes',
        'Arquivos não encontrados na pasta: ${ausentes.join(', ')}',
      );
    }
    if (lista.isEmpty) {
      throw const CommandException(
        'sem_comprovantes',
        'Nenhum comprovante anexado aos lançamentos.',
      );
    }
    if (!envio.automation.isConnected) {
      throw const CommandException(
        'sei_fechado',
        'Abra o SEI (comando progressao.abrirSei) e o processo antes de enviar.',
      );
    }
    envio
      ..enviando = true
      ..cancelar = false
      ..atualizar();
    try {
      final r = await envio.automation.insertExternalBatch(
        documentos: [
          for (final l in lista)
            SeiDocumentoExterno(
              caminho: comprovantes.caminhoAbsoluto(p, l)!,
              nomeArvore: l.rotuloComprovante,
            ),
        ],
        serie: p.tipoDocumentoSei.trim().isEmpty
            ? ProgressaoDocente.tipoDocumentoSeiPadrao
            : p.tipoDocumentoSei.trim(),
        log: envio.log,
        cancelado: () => envio.cancelar,
      );
      for (final e in r.erros) {
        envio.log('ERRO: $e');
      }
      envio.log(
        'Concluído: ${r.criados.length} incluído(s), '
        '${r.existentes.length} já existente(s), ${r.erros.length} erro(s).',
      );
      return r;
    } finally {
      envio
        ..enviando = false
        ..atualizar();
    }
  }

  /// Envia ao processo já aberto os comprovantes, a prova da última
  /// titulação e, por último, o relatório de atividades separado.
  Future<SeiLoteResultado> enviarDossieSei(String id) async {
    await _ensure();
    final p = _require(id);
    if (!envio.automation.isConnected) {
      throw const CommandException(
        'sei_fechado',
        'Abra o SEI e deixe aberto o processo de destino.',
      );
    }
    if (!comprovantes.titulacaoExiste(p)) {
      throw const CommandException(
        'titulacao_ausente',
        'Selecione e arquive o comprovante da última titulação.',
      );
    }
    final ausentes = comprovantesAusentes(p);
    if (ausentes.isNotEmpty) {
      throw CommandException(
        'comprovantes_ausentes',
        'Arquivos não encontrados: ${ausentes.join(', ')}',
      );
    }
    if (p.relatorioInicio == null || p.relatorioFim == null) {
      throw const CommandException(
        'periodo_relatorio_ausente',
        'Informe o período do relatório antes de enviar ao SEI.',
      );
    }

    envio
      ..enviando = true
      ..cancelar = false
      ..atualizar();
    try {
      final comprovantesLista = lancamentosComComprovante(p);
      final loteComprovantes = await envio.automation.insertExternalBatch(
        documentos: [
          for (final l in comprovantesLista)
            SeiDocumentoExterno(
              caminho: comprovantes.caminhoAbsoluto(p, l)!,
              nomeArvore: l.rotuloComprovante,
            ),
        ],
        serie: p.tipoDocumentoSei.trim().isEmpty
            ? ProgressaoDocente.tipoDocumentoSeiPadrao
            : p.tipoDocumentoSei.trim(),
        log: envio.log,
        cancelado: () => envio.cancelar,
      );
      if (loteComprovantes.erros.isNotEmpty || envio.cancelar) {
        return loteComprovantes;
      }

      final titulacaoPath = comprovantes.caminhoTitulacao(p)!;
      final loteTitulacao = await envio.automation.insertExternalBatch(
        documentos: [
          SeiDocumentoExterno(
            caminho: titulacaoPath,
            nomeArvore:
                'Comprovante da última titulação - ${p.titulacao.rotulo}',
          ),
        ],
        serie: 'Comprovante',
        log: envio.log,
        cancelado: () => envio.cancelar,
      );
      if (loteTitulacao.erros.isNotEmpty || envio.cancelar) {
        return SeiLoteResultado(
          criados: [...loteComprovantes.criados, ...loteTitulacao.criados],
          existentes: [
            ...loteComprovantes.existentes,
            ...loteTitulacao.existentes,
          ],
          erros: loteTitulacao.erros,
        );
      }

      final bytes = await ProgressaoPdfService().gerarRelatorio(p);
      final pasta = Directory(p.pastaComprovantes);
      await pasta.create(recursive: true);
      final nomeBase = p.docente
          .trim()
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
          .replaceAll(RegExp(r'\s+'), '_');
      final relatorioPath =
          '${pasta.path}${Platform.pathSeparator}'
          'Relatorio_Atividades_${nomeBase.isEmpty ? 'docente' : nomeBase}.pdf';
      await File(relatorioPath).writeAsBytes(bytes, flush: true);
      final nomeArvoreRelatorio = 'de Atividades - ${p.docente.trim()}';
      final loteRelatorio = await envio.automation.insertExternalBatch(
        documentos: [
          SeiDocumentoExterno(
            caminho: relatorioPath,
            nomeArvore: nomeArvoreRelatorio.length > limiteNomeArvoreSei
                ? nomeArvoreRelatorio.substring(0, limiteNomeArvoreSei)
                : nomeArvoreRelatorio,
          ),
        ],
        serie: 'Relatório',
        log: envio.log,
        cancelado: () => envio.cancelar,
      );
      return SeiLoteResultado(
        criados: [
          ...loteComprovantes.criados,
          ...loteTitulacao.criados,
          ...loteRelatorio.criados,
        ],
        existentes: [
          ...loteComprovantes.existentes,
          ...loteTitulacao.existentes,
          ...loteRelatorio.existentes,
        ],
        erros: loteRelatorio.erros,
      );
    } finally {
      envio
        ..enviando = false
        ..atualizar();
    }
  }

  @override
  void dispose() {
    unawaited(flush());
    envio.dispose();
    super.dispose();
  }
}
