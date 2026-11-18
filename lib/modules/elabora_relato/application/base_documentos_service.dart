import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Base de documentos de consulta do relator (normas, resoluções, anexos):
/// a pasta escolhida pelo usuário, o JSON preparado nela e a busca usada
/// pela IA nas consultas sobre trechos do parecer.
class BaseDocumentosService extends ChangeNotifier {
  BaseDocumentosService({
    KeyValueStore? store,
    this.espera = const Duration(seconds: 3),
  }) : _store = store ?? KeyValueStore();

  /// Espera depois da última mudança na pasta antes de atualizar a base
  /// (cópias de vários arquivos geram muitos eventos seguidos).
  final Duration espera;

  static const pastaKey = 'parecer_base_documentos_pasta';

  final KeyValueStore _store;

  String _pasta = '';
  BaseDocumentos? _base;
  bool _carregado = false;
  bool _preparando = false;
  String etapa = '';
  int progresso = 0;
  int total = 0;
  ResumoAtualizacao? ultimoResumo;
  String? ultimoErro;
  Future<BaseDocumentos?>? _emAndamento;
  StreamSubscription<FileSystemEvent>? _vigia;
  Timer? _timerVigia;

  /// Hora da última atualização disparada pelo vigia da pasta.
  DateTime? atualizadaAutomaticamente;

  /// A pasta está sendo vigiada (Directory.watch) e a base se atualiza
  /// sozinha quando arquivos são adicionados, alterados ou removidos.
  bool get vigiando => _vigia != null;

  String get pasta => _pasta;
  BaseDocumentos? get base => _base;
  bool get preparando => _preparando;
  bool get configurada => _pasta.isNotEmpty;

  String _processoId = '';

  String get _pastaKey =>
      _processoId.isEmpty ? pastaKey : '$pastaKey.$_processoId';

  /// Passa à base de documentos do processo [id] (cada processo tem a sua
  /// pasta; vários processos podem apontar para a mesma).
  Future<void> usarProcesso(String id) async {
    try {
      await _emAndamento;
    } catch (_) {}
    _timerVigia?.cancel();
    await _vigia?.cancel();
    _vigia = null;
    _processoId = id;
    _pasta = '';
    _base = null;
    ultimoResumo = null;
    ultimoErro = null;
    atualizadaAutomaticamente = null;
    _carregado = false;
    await carregar();
  }

  Future<void> carregar() async {
    if (_carregado) return;
    _carregado = true;
    _pasta = (await _store.readString(_pastaKey))?.trim() ?? '';
    if (_pasta.isNotEmpty) {
      _base = await BaseDocumentosIndexer.carregar(_pasta);
    }
    _vigiar();
    notifyListeners();
  }

  /// Troca a pasta da base e a prepara.
  Future<ResumoAtualizacao?> definirPasta(String pasta) async {
    await carregar();
    _pasta = pasta.trim();
    await _store.writeString(_pastaKey, _pasta);
    _base = await BaseDocumentosIndexer.carregar(_pasta);
    _vigiar();
    notifyListeners();
    await preparar();
    return ultimoResumo;
  }

  /// Vigia a pasta da base: cada mudança (fora o próprio JSON e arquivos
  /// temporários) agenda uma atualização incremental depois de [espera].
  /// Se o sistema não permitir vigiar (ex.: algumas pastas de rede), a base
  /// continua sendo conferida antes de cada consulta.
  void _vigiar() {
    _vigia?.cancel();
    _vigia = null;
    _timerVigia?.cancel();
    if (_pasta.isEmpty || !FileSystemEntity.isWatchSupported) return;
    final pasta = _pasta;
    try {
      _vigia = Directory(pasta)
          .watch(recursive: true)
          .listen(
            (e) {
              final rel = p.relative(e.path, from: pasta).replaceAll('\\', '/');
              if (BaseDocumentosIndexer.ignorado(rel)) return;
              _timerVigia?.cancel();
              _timerVigia = Timer(espera, _atualizarPeloVigia);
            },
            onError: (Object _) {
              _vigia?.cancel();
              _vigia = null;
              notifyListeners();
            },
          );
    } catch (_) {
      _vigia = null;
    }
  }

  Future<void> _atualizarPeloVigia() async {
    if (_preparando) {
      // Atualização em andamento: tenta de novo depois dela.
      _timerVigia = Timer(espera, _atualizarPeloVigia);
      return;
    }
    try {
      final antes = _base;
      await preparar();
      if (ultimoResumo?.mudou ?? antes == null) {
        atualizadaAutomaticamente = DateTime.now();
        notifyListeners();
      }
    } catch (_) {
      // O erro fica em ultimoErro; a próxima consulta tenta de novo.
    }
  }

  @override
  void dispose() {
    _timerVigia?.cancel();
    _vigia?.cancel();
    super.dispose();
  }

  /// Atualiza a base: processa só os arquivos novos ou alterados e retira
  /// os removidos. Com [forcar], reprocessa tudo.
  Future<BaseDocumentos?> preparar({bool forcar = false}) {
    return _emAndamento ??= _preparar(
      forcar,
    ).whenComplete(() => _emAndamento = null);
  }

  Future<BaseDocumentos?> _preparar(bool forcar) async {
    await carregar();
    if (_pasta.isEmpty) {
      throw const CommandException(
        'base_sem_pasta',
        'Escolha a pasta com os documentos de consulta (normas, '
            'resoluções, anexos) antes de preparar a base.',
      );
    }
    _preparando = true;
    ultimoErro = null;
    etapa = 'Verificando os arquivos…';
    notifyListeners();
    try {
      final (base, resumo) = await BaseDocumentosIndexer.atualizar(
        _pasta,
        anterior: _base,
        forcar: forcar,
        progresso: (arquivo, atual, n) {
          etapa = arquivo;
          progresso = atual;
          total = n;
          notifyListeners();
        },
      );
      _base = base;
      ultimoResumo = resumo;
      return base;
    } catch (e) {
      ultimoErro = e is StateError ? e.message : '$e';
      rethrow;
    } finally {
      _preparando = false;
      etapa = '';
      notifyListeners();
    }
  }

  /// Garante a base em dia antes de uma consulta: confere tamanho/data dos
  /// arquivos (sem lê-los) e só reprocessa o que mudou. Sem pasta
  /// configurada, devolve null.
  Future<BaseDocumentos?> garantirAtualizada() async {
    await carregar();
    if (_pasta.isEmpty) return null;
    final atual = _base;
    if (atual != null && !_preparando) {
      try {
        if (await BaseDocumentosIndexer.emDia(atual)) return atual;
      } catch (_) {
        // Pasta inacessível: usa a base já carregada.
        return atual;
      }
    }
    return preparar();
  }

  /// Fontes para uma consulta: os trechos mais relevantes da base e dos
  /// documentos do processo lidos da árvore do SEI (em memória).
  Future<List<FonteConsulta>> fontesPara(
    String consulta, {
    List<SeiDocumento> processo = const [],
    int limiteBase = 8,
    int limiteProcesso = 4,
  }) async {
    final base = await garantirAtualizada();
    final fontes = <FonteConsulta>[];
    for (final r in base?.buscar(consulta, limite: limiteBase) ?? const []) {
      fontes.add(
        FonteConsulta(
          id: 'F${fontes.length + 1}',
          arquivo: r.trecho.arquivo,
          localizacao: r.trecho.localizacao,
          texto: r.trecho.texto,
          caminho: base!.pasta,
        ),
      );
    }
    final doProcesso = basePara(processo);
    for (final r in doProcesso.buscar(consulta, limite: limiteProcesso)) {
      fontes.add(
        FonteConsulta(
          id: 'F${fontes.length + 1}',
          arquivo: r.trecho.arquivo,
          localizacao: r.trecho.localizacao,
          texto: r.trecho.texto,
        ),
      );
    }
    return fontes;
  }

  /// Base temporária com os documentos da árvore do SEI lidos nesta sessão.
  static BaseDocumentos basePara(List<SeiDocumento> docs) => BaseDocumentos(
    pasta: '',
    documentos: [
      for (final d in docs)
        if (d.texto.trim().isNotEmpty)
          DocumentoBase(
            arquivo: 'Processo SEI – ${d.nomeArvore} (ordem ${d.ordem})',
            tamanho: d.texto.length,
            modificado: DateTime.now(),
            hash: '',
            status: StatusDocumento.ok,
            tipo: 'sei',
            trechos: BaseDocumentosIndexer.segmentar(
              'sei${d.ordem}',
              'Processo SEI – ${d.nomeArvore} (ordem ${d.ordem})',
              BaseDocumentosIndexer.paragrafosDeTexto(d.texto),
            ),
          ),
    ],
  );
}

/// Trecho entregue à IA numa consulta, com o identificador curto ("F3")
/// que ela usa para citar e a localização no arquivo original.
class FonteConsulta {
  const FonteConsulta({
    required this.id,
    required this.arquivo,
    required this.localizacao,
    required this.texto,
    this.caminho = '',
  });

  final String id;

  /// Caminho relativo à pasta da base, ou a identificação do documento SEI.
  final String arquivo;
  final String localizacao;
  final String texto;

  /// Pasta da base ('' = documento do processo SEI, sem arquivo local).
  final String caminho;

  String get referencia =>
      localizacao.isEmpty ? arquivo : '$arquivo — $localizacao';
}
