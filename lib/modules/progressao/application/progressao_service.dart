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
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
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

/// Etapas da montagem do dossiê no SEI, na ordem em que são feitas.
enum EtapaSei {
  processo('Processo no SEI'),
  requerimento('Requerimento'),
  comprovantes('Comprovantes das atividades'),
  titulacao('Comprovante da última titulação'),
  relatorio('Relatório de atividades');

  const EtapaSei(this.titulo);
  final String titulo;
}

/// O que já está no processo do SEI, lido da árvore (sem gravar nada).
class SituacaoSei {
  const SituacaoSei({
    required this.logado,
    required this.numeroProcesso,
    this.numeroAberto = '',
    this.requerimento = false,
    this.comprovantesNoSei = 0,
    this.comprovantesTotal = 0,
    this.comprovantesFaltantes = const [],
    this.titulacao = false,
    this.relatorio = false,
    required this.verificadoEm,
  });

  final bool logado;

  /// Processo do cadastro confirmado no SEI (vazio se não há processo
  /// salvo ou se o aberto no Edge é outro).
  final String numeroProcesso;

  /// Processo aberto no Edge no momento da leitura (pode ser outro).
  final String numeroAberto;
  final bool requerimento;
  final int comprovantesNoSei;
  final int comprovantesTotal;
  final List<String> comprovantesFaltantes;
  final bool titulacao;
  final bool relatorio;
  final DateTime verificadoEm;

  bool concluida(EtapaSei etapa) => switch (etapa) {
    EtapaSei.processo => logado && numeroProcesso.isNotEmpty,
    EtapaSei.requerimento => requerimento,
    EtapaSei.comprovantes =>
      comprovantesTotal > 0 && comprovantesNoSei >= comprovantesTotal,
    EtapaSei.titulacao => titulacao,
    EtapaSei.relatorio => relatorio,
  };

  /// Uma etapa fica disponível quando todas as anteriores estão concluídas.
  bool disponivel(EtapaSei etapa) =>
      EtapaSei.values.takeWhile((e) => e != etapa).every(concluida);

  bool get tudoConcluido => EtapaSei.values.every(concluida);
}

/// Estado do envio de comprovantes ao SEI: o Edge controlado e o log
/// continuam disponíveis ao trocar de aba ou de tela (e para o agente).
class ProgressaoEnvioSei extends ChangeNotifier {
  final automation = SeiAutomationService();
  final logs = <String>[];
  String url = 'https://sei.ufu.br';
  bool enviando = false;
  bool cancelar = false;
  bool prontoParaCriarProcesso = false;
  String unidadeSeiSelecionada = '';
  String? processoSeiPendenteId;
  ProgressaoDossieSeiOpcoes? opcoesSeiPendentes;

  /// Última leitura do processo no SEI (por id do processo de progressão).
  final situacoes = <String, SituacaoSei>{};

  /// Etapa em execução (para destacar na tela).
  EtapaSei? etapaEmExecucao;
  bool verificando = false;

  void log(String mensagem) {
    final agora = DateTime.now();
    final hora =
        '${agora.hour.toString().padLeft(2, '0')}:'
        '${agora.minute.toString().padLeft(2, '0')}';
    logs.insert(0, '$hora  $mensagem');
    if (logs.length > 300) logs.removeLast();
    notifyListeners();
    _gravarArquivo('${agora.toIso8601String()}  $mensagem');
  }

  /// Cópia do log em Documentos\GestorUFU Agente\logs\progressao_sei.log,
  /// para diagnóstico (e para o Agente de IA) sem depender da tela.
  Future<void> _gravarArquivo(String linha) async {
    try {
      final dir = await GestorPaths.outputDir('logs');
      await File(
        '$dir${Platform.pathSeparator}progressao_sei.log',
      ).writeAsString('$linha\n', mode: FileMode.append, flush: true);
    } catch (_) {}
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

  /// Abre o SEI e aguarda o login e a seleção manual da unidade antes de
  /// oferecer a criação do processo. Nenhum processo é criado nesta etapa.
  Future<void> prepararMontagemProcessoSei(
    String id,
    ProgressaoDossieSeiOpcoes opcoes,
  ) async {
    if (!opcoes.criarNovo) {
      throw ArgumentError('A preparação manual só se aplica a processo novo.');
    }
    await _ensure();
    _require(id);
    envio
      ..prontoParaCriarProcesso = false
      ..processoSeiPendenteId = null
      ..opcoesSeiPendentes = null
      ..cancelar = false
      ..enviando = true
      ..atualizar();
    try {
      if (!envio.automation.isConnected) {
        await abrirSei('https://sei.ufu.br');
      } else {
        await envio.automation.focus();
      }
      final seiFlow = ProgressaoSeiRequerimento(envio.automation);
      envio.log(
        'Entre no SEI e selecione a unidade onde o processo será criado.',
      );
      await seiFlow.aguardarLogin(
        log: envio.log,
        cancelado: () => envio.cancelar,
      );
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      var unidade = '';
      while (DateTime.now().isBefore(deadline)) {
        if (envio.cancelar) throw StateError('Preparação interrompida.');
        unidade = (await seiFlow.unidadeAtual()).trim();
        if (unidade.isNotEmpty) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (unidade.isEmpty) {
        throw TimeoutException(
          'Não identifiquei a unidade do SEI. Selecione a unidade e tente novamente.',
        );
      }
      envio
        ..processoSeiPendenteId = id
        ..opcoesSeiPendentes = opcoes
        ..unidadeSeiSelecionada = unidade
        ..prontoParaCriarProcesso = true;
      envio.log(
        'Unidade "$unidade" selecionada. Use o botão para criar o processo.',
      );
    } catch (error) {
      envio.log('Não foi possível preparar a criação do processo: $error');
      rethrow;
    } finally {
      envio
        ..enviando = false
        ..atualizar();
    }
  }

  Future<ProgressaoDossieSeiResultado> continuarMontagemProcessoSei() async {
    final id = envio.processoSeiPendenteId;
    final opcoes = envio.opcoesSeiPendentes;
    if (!envio.prontoParaCriarProcesso || id == null || opcoes == null) {
      throw StateError('Faça login no SEI e selecione a unidade primeiro.');
    }
    envio
      ..prontoParaCriarProcesso = false
      ..enviando = true
      ..atualizar();
    try {
      return await montarProcessoSei(id, opcoes);
    } finally {
      envio
        ..processoSeiPendenteId = null
        ..opcoesSeiPendentes = null
        ..prontoParaCriarProcesso = false
        ..enviando = false
        ..atualizar();
      try {
        await verificarSei(id);
      } catch (_) {}
    }
  }

  // ------------------------------------------------- SEI em etapas

  static const nomeRequerimentoSei =
      'Requerimento de Progressão / Promoção Docente';

  List<String> _nomesTitulacaoSei(ProgressaoDocente p) {
    final diploma = 'Diploma de ${p.titulacao.rotulo}';
    return [
      '- $diploma',
      diploma,
      'Comprovante - $diploma',
      'Comprovante da ultima titulacao - ${p.titulacao.rotulo}',
    ];
  }

  List<String> _nomesRelatorioSei(ProgressaoDocente p) => [
    'de Atividades - ${p.docente.trim()}',
    'Relatório de Atividades - ${p.docente.trim()}',
  ];

  /// Lê o processo no SEI (abre o processo salvo, se preciso) e informa quais
  /// etapas já estão feitas. Não grava nada no SEI.
  Future<SituacaoSei> verificarSei(String id) async {
    await _ensure();
    final p = _require(id);
    final lista = lancamentosComComprovante(p);
    envio
      ..verificando = true
      ..atualizar();
    try {
      if (!envio.automation.isConnected) await abrirSei('https://sei.ufu.br');
      final seiFlow = ProgressaoSeiRequerimento(envio.automation);
      if (!await seiFlow.estaLogado()) {
        envio.log(
          'SEI: entre no SEI pelo Edge e clique em "Verificar no SEI".',
        );
        return _guardarSituacao(
          id,
          SituacaoSei(
            logado: false,
            numeroProcesso: '',
            comprovantesTotal: lista.length,
            verificadoEm: DateTime.now(),
          ),
        );
      }
      final salvo = p.processoSei.trim();
      var aberto = await seiFlow.numeroProcessoAtual();
      if (salvo.isNotEmpty && aberto != salvo) {
        envio.log('SEI: abrindo o processo $salvo.');
        await seiFlow.abrirProcesso(salvo);
        aberto = await seiFlow.numeroProcessoAtual();
      }
      final confirmado = salvo.isNotEmpty && aberto == salvo ? salvo : '';
      if (confirmado.isEmpty) {
        envio.log(
          salvo.isEmpty
              ? 'SEI: nenhum processo salvo no cadastro${aberto.isEmpty ? '' : '; aberto no Edge: $aberto'}.'
              : 'SEI: não consegui abrir o processo $salvo.',
        );
        return _guardarSituacao(
          id,
          SituacaoSei(
            logado: true,
            numeroProcesso: '',
            numeroAberto: aberto,
            comprovantesTotal: lista.length,
            verificadoEm: DateTime.now(),
          ),
        );
      }
      final grupos = <List<String>>[
        [nomeRequerimentoSei],
        for (final l in lista)
          [_nomeArvoreCurto(l.rotuloComprovante), l.rotuloComprovante],
        _nomesTitulacaoSei(p),
        _nomesRelatorioSei(p),
      ];
      final presentes = await envio.automation.documentosPresentes(grupos);
      final comprovantesPresentes = presentes.sublist(1, 1 + lista.length);
      final faltantes = [
        for (final (i, l) in lista.indexed)
          if (!comprovantesPresentes[i]) l.rotuloComprovante,
      ];
      final situacao = SituacaoSei(
        logado: true,
        numeroProcesso: confirmado,
        numeroAberto: aberto,
        requerimento: presentes.first,
        comprovantesNoSei: lista.length - faltantes.length,
        comprovantesTotal: lista.length,
        comprovantesFaltantes: faltantes,
        titulacao: presentes[1 + lista.length],
        relatorio: presentes[2 + lista.length],
        verificadoEm: DateTime.now(),
      );
      envio.log(
        'SEI: processo $confirmado — requerimento ${situacao.requerimento ? 'presente' : 'pendente'}; '
        'comprovantes ${situacao.comprovantesNoSei}/${situacao.comprovantesTotal}; '
        'titulação ${situacao.titulacao ? 'presente' : 'pendente'}; '
        'relatório ${situacao.relatorio ? 'presente' : 'pendente'}.',
      );
      return _guardarSituacao(id, situacao);
    } finally {
      envio
        ..verificando = false
        ..atualizar();
    }
  }

  SituacaoSei _guardarSituacao(String id, SituacaoSei situacao) {
    envio.situacoes[id] = situacao;
    envio.atualizar();
    return situacao;
  }

  /// Executa só a [etapa] no processo salvo (ou, para [EtapaSei.processo]
  /// sem processo salvo, adota o processo aberto no Edge) e lê de novo o SEI.
  /// A criação de um processo novo usa [prepararMontagemProcessoSei].
  Future<void> executarEtapaSei(String id, EtapaSei etapa) async {
    await _ensure();
    final p = _require(id);
    envio
      ..etapaEmExecucao = etapa
      ..atualizar();
    try {
      await montarProcessoSei(
        id,
        ProgressaoDossieSeiOpcoes(
          numeroProcesso: p.processoSei.trim(),
          acessoComprovantes: p.acessoComprovantesSei,
          incluirRequerimento: etapa == EtapaSei.requerimento,
          incluirComprovantes: etapa == EtapaSei.comprovantes,
          incluirTitulacao: etapa == EtapaSei.titulacao,
          incluirRelatorio: etapa == EtapaSei.relatorio,
        ),
      );
    } finally {
      envio
        ..etapaEmExecucao = null
        ..atualizar();
      try {
        await verificarSei(id);
      } catch (error) {
        envio.log('SEI: não consegui reler o processo: $error');
      }
    }
  }

  /// Executa, em ordem, as etapas ainda pendentes; para no primeiro erro.
  Future<void> executarEtapasPendentes(String id) async {
    var situacao = await verificarSei(id);
    if (!situacao.concluida(EtapaSei.processo)) {
      throw StateError(
        situacao.logado
            ? 'Crie ou abra o processo no SEI (etapa 1) antes das demais.'
            : 'Entre no SEI pelo Edge antes de continuar.',
      );
    }
    for (final etapa in EtapaSei.values.skip(1)) {
      if (envio.cancelar) break;
      if (situacao.concluida(etapa)) continue;
      await executarEtapaSei(id, etapa);
      situacao = envio.situacoes[id] ?? situacao;
      if (!situacao.concluida(etapa)) {
        throw StateError(
          'A etapa "${etapa.titulo}" não foi confirmada no SEI.',
        );
      }
    }
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
      if (p.lotacao.trim().isEmpty) 'Informe a lota\u00e7\u00e3o.',
      // Em processo existente, o requerimento pode j\u00e1 estar na \u00e1rvore do SEI.
      // A automa\u00e7\u00e3o verifica isso antes de criar outro; n\u00e3o bloqueie a
      // inclus\u00e3o dos demais documentos por dados necess\u00e1rios apenas a um novo requerimento.
      if (opcoes.criarNovo &&
          opcoes.incluirRequerimento &&
          p.dataAdmissao == null)
        'Informe a data de admiss\u00e3o.',
      if (opcoes.criarNovo &&
          opcoes.incluirRequerimento &&
          p.dataDocumento == null)
        'Informe a data do requerimento.',
      if (p.intersticioInicio == null || p.intersticioFim == null)
        'Informe in\u00edcio e fim do interst\u00edcio.',
      if (opcoes.incluirRelatorio &&
          (p.relatorioInicio == null || p.relatorioFim == null))
        'Informe in\u00edcio e fim do relat\u00f3rio.',
      if (opcoes.incluirComprovantes && p.lancamentos.isEmpty)
        'N\u00e3o h\u00e1 lan\u00e7amentos para anexar.',
      if (opcoes.incluirComprovantes &&
          p.lancamentos.any((l) => l.comprovante.trim().isEmpty))
        'Todos os lan\u00e7amentos precisam ter comprovante vinculado.',
      if (opcoes.incluirComprovantes && comprovantesAusentes(p).isNotEmpty)
        'H\u00e1 comprovantes ausentes: ${comprovantesAusentes(p).join(', ')}.',
      if (opcoes.incluirTitulacao && !comprovantes.titulacaoExiste(p))
        'Selecione o comprovante da \u00faltima titula\u00e7\u00e3o.',
      if (opcoes.incluirRelatorio && p.pastaComprovantes.trim().isEmpty)
        'Escolha a pasta dos comprovantes para gerar o relat\u00f3rio.',
      if (opcoes.incluirRequerimento &&
          p.relatorioInicio != null &&
          p.intersticioInicio != null &&
          p.relatorioInicio!.isBefore(p.intersticioInicio!) &&
          p.justificativaIntersticio.trim().isEmpty)
        'Informe a justificativa quando o relat\u00f3rio come\u00e7a antes do interst\u00edcio.',
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

    final tipo = opcoes.criarNovo
        ? tipoProcessoSugeridoSei(p)
        : p.tipoProcessoSei.trim();
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
