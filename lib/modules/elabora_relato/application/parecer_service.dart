import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/sei_parecer_automation.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/sei_parecer_html.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Pedido para um editor de seção inserir HTML na posição do cursor.
typedef InsercaoNoEditor = ({ParecerSecao secao, String html});

/// Rascunho do parecer (assunto, ementa, vocativo e as três seções), salvo
/// no banco do Gestor, e a inserção no SEI. Usado pelas abas e pelos
/// comandos do agente.
class ParecerService extends ChangeNotifier {
  ParecerService({KeyValueStore? store, required this.arvore})
    : _store = store ?? KeyValueStore(),
      _sei = SeiParecerAutomation(arvore.automation);

  static const draftKey = 'parecer_relato_rascunho';
  static const stylesKey = 'parecer_relato_estilos_sei';

  final KeyValueStore _store;
  final SeiArvoreService arvore;
  final SeiParecerAutomation _sei;

  Parecer _parecer = const Parecer();
  bool _carregado = false;
  bool _inserindo = false;
  Timer? _salvarTimer;
  String _estilosCss = '';
  List<Map<String, dynamic>> _estilos = const [];
  final _insercoes = StreamController<InsercaoNoEditor>.broadcast();
  final _substituicoes = StreamController<ParecerSecao>.broadcast();

  Parecer get parecer => _parecer;
  bool get inserindo => _inserindo;

  /// CSS das classes do editor do SEI capturado na última inserção ('' =
  /// usa os estilos padrão embutidos).
  String get estilosCss => _estilosCss;

  /// Lista "Escolha o estilo" do SEI capturada (vazia = lista padrão).
  List<Map<String, dynamic>> get estilos => _estilos;

  /// Pedidos de inserção no cursor (ex.: inventário da árvore no relatório).
  Stream<InsercaoNoEditor> get insercoes => _insercoes.stream;

  /// Seção trocada por fora do editor (agente/comando): o editor recarrega.
  Stream<ParecerSecao> get substituicoes => _substituicoes.stream;

  Future<void> carregar() async {
    if (_carregado) return;
    _carregado = true;
    final raw = await _store.readJson(draftKey);
    if (raw is Map) _parecer = Parecer.fromJson(Map<String, dynamic>.from(raw));
    final estilos = await _store.readJson(stylesKey);
    if (estilos is Map) {
      _estilosCss = '${estilos['css'] ?? ''}';
      _estilos = [
        for (final e in (estilos['estilos'] as List? ?? const []))
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    notifyListeners();
  }

  /// Atualiza os campos (sem as seções) e agenda o salvamento.
  void atualizar(Parecer novo) {
    _parecer = novo;
    _agendarSalvar();
    notifyListeners();
  }

  /// Conteúdo digitado num editor de seção.
  void definirSecaoDoEditor(ParecerSecao secao, String html) {
    if (_parecer.secao(secao) == html) return;
    _parecer = _parecer.comSecao(secao, html);
    _agendarSalvar();
  }

  /// Troca o HTML de uma seção por fora do editor (agente, limpar).
  Future<void> substituirSecao(ParecerSecao secao, String html) async {
    _parecer = _parecer.comSecao(secao, html);
    _substituicoes.add(secao);
    notifyListeners();
    await salvarAgora();
  }

  /// Insere [html] no cursor do editor da [secao] (ou ao final, se o editor
  /// não estiver aberto).
  void inserirNoEditor(ParecerSecao secao, String html) {
    if (_insercoes.hasListener) {
      _insercoes.add((secao: secao, html: html));
    } else {
      unawaited(substituirSecao(secao, _parecer.secao(secao) + html));
    }
  }

  /// Número SEI → id interno, dos documentos da árvore extraída (para o
  /// botão "sei!" do editor).
  Map<String, String> linksSei() => {
    for (final d in arvore.documentos)
      if (d.codigoSei.isNotEmpty && d.idDocumento.isNotEmpty)
        d.codigoSei: d.idDocumento,
  };

  /// HTML do inventário da árvore no estilo do relatório.
  String inventarioHtml({bool porPastas = true, String introducao = ''}) =>
      SeiParecerHtml.inventario(
        arvore.documentos,
        porPastas: porPastas,
        introducao: introducao,
      );

  void _agendarSalvar() {
    _salvarTimer?.cancel();
    _salvarTimer = Timer(const Duration(milliseconds: 800), salvarAgora);
  }

  Future<void> salvarAgora() async {
    _salvarTimer?.cancel();
    await _store.writeJson(draftKey, _parecer.toJson());
  }

  /// Apaga o rascunho (mantém vocativo e fecho padrão).
  Future<void> novoParecer() async {
    _parecer = const Parecer();
    for (final s in ParecerSecao.values) {
      _substituicoes.add(s);
    }
    notifyListeners();
    await salvarAgora();
  }

  /// Insere o parecer no processo aberto no Edge (ou no editor de Parecer
  /// já aberto) e salva sem assinar.
  Future<List<String>> inserirNoSei() async {
    if (_inserindo) {
      throw const CommandException(
        'em_andamento',
        'Uma inserção no SEI já está em andamento.',
      );
    }
    if (!arvore.conectado) {
      throw const CommandException(
        'sei_fechado',
        'Abra o SEI pelo app (aba I. RELATÓRIO › Extrair árvore › Abrir '
            'Edge), entre e abra o processo.',
      );
    }
    _inserindo = true;
    notifyListeners();
    try {
      await salvarAgora();
      arvore.log('Inserindo o parecer no SEI…');
      final r = await _sei.inserir(_parecer, log: arvore.log);
      final estilos = r.estilos;
      if (estilos != null) {
        _estilosCss = estilos.css;
        _estilos = estilos.estilos;
        await _store.writeJson(stylesKey, {
          'css': estilos.css,
          'estilos': estilos.estilos,
        });
      }
      await _guardarModelo(r.modeloHtml);
      return r.avisos;
    } on StateError catch (e) {
      throw CommandException('falha_sei', e.message);
    } on TimeoutException catch (e) {
      throw CommandException('tempo_esgotado', e.message ?? '$e');
    } finally {
      _inserindo = false;
      notifyListeners();
    }
  }

  /// Lê os estilos do editor do SEI aberto (sem inserir nada).
  Future<bool> capturarEstilosDoSei() async {
    final estilos = await _sei.capturarEstilos();
    if (estilos == null) return false;
    _estilosCss = estilos.css;
    _estilos = estilos.estilos;
    await _store.writeJson(stylesKey, {
      'css': estilos.css,
      'estilos': estilos.estilos,
    });
    notifyListeners();
    return true;
  }

  /// Guarda o modelo nativo lido (diagnóstico do encaixe nos campos).
  Future<void> _guardarModelo(String html) async {
    try {
      final path = await GestorPaths.outputPath(
        null,
        'modelo_parecer_sei.html',
        sub: 'elabora_relato',
      );
      await File(path).writeAsString(html, encoding: utf8);
    } catch (_) {}
  }

  @override
  void dispose() {
    _salvarTimer?.cancel();
    _insercoes.close();
    _substituicoes.close();
    super.dispose();
  }
}
