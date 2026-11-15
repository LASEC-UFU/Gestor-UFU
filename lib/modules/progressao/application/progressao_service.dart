import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/progressao/application/progressao_comprovantes_service.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_pdf_service.dart';
import 'package:gestor_ufu/modules/progressao/data/progressao_store.dart';
import 'package:gestor_ufu/modules/progressao/domain/comprovantes.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/modules/progressao/domain/resolucao_condir_03_2017.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

const _uuid = Uuid();

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
  Future<List<ProgressaoDocente>> load() async {
    await flush();
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

  @override
  void dispose() {
    unawaited(flush());
    envio.dispose();
    super.dispose();
  }
}
