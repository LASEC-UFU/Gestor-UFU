import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/processo_parecer.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Lista de processos do módulo Parecer / Relato. Cada processo guarda, em
/// chaves próprias do banco (sem um índice compartilhado, para não haver
/// conflito na sincronização entre computadores):
/// - `parecer_processo.<id>`: nome, número SEI e datas;
/// - `parecer_relato_rascunho.<id>`: rascunho do parecer e comentários;
/// - `parecer_relato_inventario.<id>`: inventário da árvore do SEI;
/// - `parecer_base_documentos_pasta.<id>`: pasta da base de documentos.
///
/// Abrir um processo troca os dados do [ParecerService] (e da árvore e da
/// base) pelos dele.
class ProcessosParecerService extends ChangeNotifier {
  ProcessosParecerService({required this.parecer, KeyValueStore? store})
    : _store = store ?? KeyValueStore() {
    parecer.aoSalvar = _tocar;
  }

  static const metaPrefix = 'parecer_processo.';

  /// Marca de que o rascunho único (anterior à lista) já virou um processo.
  static const migradoKey = 'parecer_relato_processos_migrado';

  /// Id fixo do processo migrado: dois computadores que migrem o mesmo
  /// rascunho sincronizado gravam a mesma chave (sem duplicar).
  static const idMigrado = 'migrado';

  static const _chavesDeDados = [
    ParecerService.draftKey,
    SeiArvoreService.inventoryKey,
    BaseDocumentosService.pastaKey,
  ];

  final ParecerService parecer;
  final KeyValueStore _store;

  final List<ProcessoParecer> _processos = [];
  final Map<String, ResumoProcesso> _resumos = {};
  bool _carregado = false;
  String? _ativoId;
  DateTime? _ultimoToque;

  List<ProcessoParecer> get processos => List.unmodifiable(_processos);
  ProcessoParecer? get ativo =>
      _processos.where((p) => p.id == _ativoId).firstOrNull;
  ResumoProcesso resumo(String id) => _resumos[id] ?? const ResumoProcesso();

  static String _meta(String id) => '$metaPrefix$id';

  Future<void> carregar({bool forcar = false}) async {
    if (_carregado && !forcar) return;
    _carregado = true;
    await _migrar();
    _processos.clear();
    for (final key in await _store.keys(metaPrefix)) {
      final raw = await _store.readJson(key);
      if (raw is Map) {
        final p = ProcessoParecer.fromJson(Map<String, dynamic>.from(raw));
        if (p.id.isNotEmpty) _processos.add(p);
      }
    }
    _ordenar();
    for (final p in _processos) {
      _resumos[p.id] = await _lerResumo(p.id);
    }
    notifyListeners();
  }

  void _ordenar() => _processos.sort(
    (a, b) => (b.atualizadoEm ?? b.criadoEm ?? DateTime(0)).compareTo(
      a.atualizadoEm ?? a.criadoEm ?? DateTime(0),
    ),
  );

  /// O rascunho único de antes da lista vira o primeiro processo.
  Future<void> _migrar() async {
    if (await _store.contains(migradoKey)) return;
    final rascunho = await _store.readString(ParecerService.draftKey);
    final inventario = await _store.readString(SeiArvoreService.inventoryKey);
    final pasta = await _store.readString(BaseDocumentosService.pastaKey);
    final temAlgo = [
      rascunho,
      inventario,
      pasta,
    ].any((x) => x != null && x.trim().isNotEmpty && x != '[]' && x != '{}');
    if (temAlgo && !await _store.contains(_meta(idMigrado))) {
      for (final chave in _chavesDeDados) {
        final valor = await _store.readString(chave);
        if (valor != null) {
          await _store.writeString(
            ParecerService.chaveDoProcesso(chave, idMigrado),
            valor,
          );
        }
      }
      var nome = 'Processo anterior';
      if (rascunho != null) {
        final assunto = await _store.readJson(ParecerService.draftKey);
        if (assunto is Map && '${assunto['assunto'] ?? ''}'.trim().isNotEmpty) {
          nome = '${assunto['assunto']}'.trim();
        }
      }
      final agora = DateTime.now();
      await _store.writeJson(
        _meta(idMigrado),
        ProcessoParecer(
          id: idMigrado,
          nome: nome,
          criadoEm: agora,
          atualizadoEm: agora,
        ).toJson(),
      );
    }
    await _store.writeString(migradoKey, '1');
  }

  Future<ResumoProcesso> _lerResumo(String id) async {
    final raw = await _store.readJson(
      ParecerService.chaveDoProcesso(ParecerService.draftKey, id),
    );
    final inv = await _store.readJson(
      ParecerService.chaveDoProcesso(SeiArvoreService.inventoryKey, id),
    );
    final p = raw is Map
        ? Parecer.fromJson(Map<String, dynamic>.from(raw))
        : const Parecer();
    return ResumoProcesso(
      assunto: p.assunto.trim(),
      documentos: inv is List ? inv.length : 0,
      comentarios: p.comentarios.length,
      pendentes: p.comentarios
          .where((c) => '${c['status'] ?? ''}' == 'revisar')
          .length,
      secoesComTexto: ParecerSecao.values
          .where(
            (s) =>
                p.secao(s).replaceAll(RegExp(r'<[^>]*>|&nbsp;|\s'), '') != '',
          )
          .length,
    );
  }

  Future<ProcessoParecer> _exigir(String id) async {
    await carregar();
    final p = _processos.where((x) => x.id == id).firstOrNull;
    if (p == null) {
      throw CommandException(
        'processo_inexistente',
        'Processo não encontrado: $id.',
      );
    }
    return p;
  }

  Future<void> _gravar(ProcessoParecer p) async {
    await _store.writeJson(_meta(p.id), p.toJson());
    final i = _processos.indexWhere((x) => x.id == p.id);
    if (i < 0) {
      _processos.add(p);
    } else {
      _processos[i] = p;
    }
    _ordenar();
    notifyListeners();
  }

  /// Cria um processo vazio (não o abre).
  Future<ProcessoParecer> criar({
    required String nome,
    String numeroSei = '',
  }) async {
    await carregar();
    final agora = DateTime.now();
    final p = ProcessoParecer(
      id: const Uuid().v4(),
      nome: nome.trim().isEmpty ? 'Novo processo' : nome.trim(),
      numeroSei: numeroSei.trim(),
      criadoEm: agora,
      atualizadoEm: agora,
    );
    _resumos[p.id] = const ResumoProcesso();
    await _gravar(p);
    return p;
  }

  /// Abre o processo: o parecer, a árvore e a base passam a ser os dele.
  Future<void> abrir(String id) async {
    await _exigir(id);
    await parecer.usarProcesso(id);
    _ativoId = id;
    notifyListeners();
  }

  /// Fecha o processo aberto (volta à lista), gravando o rascunho.
  Future<void> fechar() async {
    final id = _ativoId;
    if (id == null) return;
    await parecer.salvarAgora();
    _ativoId = null;
    _resumos[id] = await _lerResumo(id);
    notifyListeners();
  }

  Future<void> renomear(String id, {String? nome, String? numeroSei}) async {
    final p = await _exigir(id);
    await _gravar(
      p.copyWith(
        nome: nome == null || nome.trim().isEmpty ? null : nome.trim(),
        numeroSei: numeroSei?.trim(),
        atualizadoEm: DateTime.now(),
      ),
    );
  }

  /// Cria um processo com uma cópia de tudo do processo [id]: rascunho,
  /// comentários, inventário da árvore e pasta da base.
  Future<ProcessoParecer> duplicar(String id, {String? nome}) async {
    final origem = await _exigir(id);
    if (id == _ativoId) await parecer.salvarAgora();
    final agora = DateTime.now();
    final copia = ProcessoParecer(
      id: const Uuid().v4(),
      nome: (nome ?? '').trim().isEmpty
          ? 'Cópia de ${origem.nome}'
          : nome!.trim(),
      numeroSei: origem.numeroSei,
      criadoEm: agora,
      atualizadoEm: agora,
    );
    for (final chave in _chavesDeDados) {
      final valor = await _store.readString(
        ParecerService.chaveDoProcesso(chave, id),
      );
      if (valor != null) {
        await _store.writeString(
          ParecerService.chaveDoProcesso(chave, copia.id),
          valor,
        );
      }
    }
    _resumos[copia.id] = await _lerResumo(copia.id);
    await _gravar(copia);
    return copia;
  }

  /// Apaga o processo e os seus dados do banco. Os arquivos da pasta da
  /// base (e o JSON da base) não são apagados.
  Future<void> excluir(String id) async {
    await _exigir(id);
    if (id == _ativoId) await fechar();
    for (final chave in _chavesDeDados) {
      await _store.remove(ParecerService.chaveDoProcesso(chave, id));
    }
    await _store.remove(_meta(id));
    _processos.removeWhere((p) => p.id == id);
    _resumos.remove(id);
    notifyListeners();
  }

  /// Para os comandos do agente: garante um processo aberto (o informado,
  /// senão o aberto, senão o mais recente; cria um se não houver nenhum).
  Future<ProcessoParecer> garantirAtivo([String? id]) async {
    await carregar();
    if (id != null && id.isNotEmpty) {
      if (id != _ativoId) await abrir(id);
      return ativo!;
    }
    final atual = ativo;
    if (atual != null) return atual;
    final alvo = _processos.isNotEmpty
        ? _processos.first
        : await criar(nome: 'Novo processo');
    await abrir(alvo.id);
    return ativo!;
  }

  /// Atualiza a data do processo aberto ao gravar o rascunho (no máximo a
  /// cada 30 s, para não gravar a cada tecla).
  void _tocar() {
    final p = ativo;
    if (p == null) return;
    final agora = DateTime.now();
    if (_ultimoToque != null &&
        agora.difference(_ultimoToque!) < const Duration(seconds: 30)) {
      return;
    }
    _ultimoToque = agora;
    unawaited(_gravar(p.copyWith(atualizadoEm: agora)));
  }
}
