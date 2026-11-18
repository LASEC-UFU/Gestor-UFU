import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/checklist_sei.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/sei_parecer_automation.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/sei_parecer_html.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Pedido para um editor de seção inserir HTML na posição do cursor.
typedef InsercaoNoEditor = ({ParecerSecao secao, String html});

/// Rascunho do parecer (assunto, ementa, vocativo e as três seções), salvo
/// no banco do Gestor, e a inserção no SEI. Usado pelas abas e pelos
/// comandos do agente.
class ParecerService extends ChangeNotifier {
  ParecerService({
    KeyValueStore? store,
    required this.arvore,
    this.ia,
    BaseDocumentosService? base,
  }) : _store = store ?? KeyValueStore(),
       base = base ?? BaseDocumentosService(store: store),
       _sei = SeiParecerAutomation(arvore.automation);

  static const draftKey = 'parecer_relato_rascunho';
  static const stylesKey = 'parecer_relato_estilos_sei';

  /// Chave de um dado do processo [id] (`chave.id`); sem processo, a chave
  /// antiga (um único parecer, antes da lista de processos).
  static String chaveDoProcesso(String chave, String id) =>
      id.isEmpty ? chave : '$chave.$id';

  String _processoId = '';

  /// Processo aberto ('' = nenhum: chaves antigas).
  String get processoId => _processoId;

  String get _draftKey => chaveDoProcesso(draftKey, _processoId);

  /// Chamado depois de cada gravação do rascunho (data de atualização na
  /// lista de processos).
  void Function()? aoSalvar;

  final KeyValueStore _store;
  final SeiArvoreService arvore;
  final AiTextService? ia;

  /// Base de documentos de consulta (pasta com normas e anexos).
  final BaseDocumentosService base;
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

  /// Comentários (anotações privadas) da [secao], fora do HTML do parecer.
  List<Map<String, dynamic>> comentarios(ParecerSecao secao) => [
    for (final c in _parecer.comentarios)
      if ('${c['secao']}' == secao.id) c,
  ];

  Future<void> salvarComentario(Map<String, dynamic> comentario) async {
    final lista = [..._parecer.comentarios];
    final id = '${comentario['id']}';
    final i = lista.indexWhere((c) => '${c['id']}' == id);
    if (i < 0) {
      lista.add(comentario);
    } else {
      lista[i] = comentario;
    }
    _parecer = _parecer.copyWith(comentarios: lista);
    await salvarAgora();
    notifyListeners();
  }

  Future<void> excluirComentario(String id) async {
    _parecer = _parecer.copyWith(
      comentarios: _parecer.comentarios
          .where((c) => '${c['id']}' != id)
          .toList(),
    );
    await salvarAgora();
    notifyListeners();
  }

  /// Perguntas para o simulado de arguição: comentários (de todas as
  /// seções) com "possível pergunta na arguição". Comentários antigos da
  /// análise guardavam a pergunta em `pergunta`.
  List<Map<String, dynamic>> perguntasArguicao() => [
    for (final c in _parecer.comentarios)
      if (perguntaArguicao(c).isNotEmpty && '${c['status']}' != 'nao_aplica') c,
  ];

  static String perguntaArguicao(Map<String, dynamic> c) {
    final nova = '${c['pergunta_arguicao'] ?? ''}'.trim();
    if (nova.isNotEmpty) return nova;
    // Em consultas à IA, `pergunta` é a pergunta do relator, não da banca.
    if ('${c['categoria']}' == 'consulta_ia') return '';
    return '${c['pergunta'] ?? ''}'.trim();
  }

  /// Registra o resultado de uma pergunta no simulado (acertou/rever).
  Future<void> registrarTreino(String id, {required bool acertou}) async {
    final c = _parecer.comentarios.where((x) => '${x['id']}' == id).firstOrNull;
    if (c == null) return;
    final treino = Map<String, dynamic>.from(
      c['treino'] is Map ? c['treino'] as Map : const {},
    );
    final chave = acertou ? 'acertos' : 'rever';
    treino[chave] = ((treino[chave] as num?)?.toInt() ?? 0) + 1;
    treino['ultimo'] = acertou ? 'acertou' : 'rever';
    treino['em'] = DateTime.now().toIso8601String();
    await salvarComentario({...c, 'treino': treino});
  }

  /// Verificação antes de inserir no SEI (não bloqueia a inserção).
  Future<ChecklistSei> checklistSei() async {
    await carregar();
    BaseDocumentos? b;
    try {
      b = await base.garantirAtualizada();
    } catch (_) {
      b = base.base;
    }
    return ChecklistSei.verificar(
      parecer: _parecer,
      textoDe: (s) => ChecklistSei.textoDeHtml(_parecer.secao(s)),
      base: b,
      baseConfigurada: base.configurada,
    );
  }

  /// Passa a trabalhar no processo [id]: grava o rascunho atual, troca o
  /// rascunho, o inventário da árvore e a base de documentos.
  Future<void> usarProcesso(String id) async {
    if (_inserindo) {
      throw const CommandException(
        'em_andamento',
        'Aguarde a inserção no SEI terminar antes de trocar de processo.',
      );
    }
    if (_carregado && _processoId == id) return;
    if (_carregado) await salvarAgora();
    await arvore.usarProcesso(id);
    await base.usarProcesso(id);
    _processoId = id;
    _parecer = const Parecer();
    _carregado = false;
    await carregar();
    for (final s in ParecerSecao.values) {
      _substituicoes.add(s);
    }
  }

  Future<void> carregar() async {
    if (_carregado) return;
    _carregado = true;
    final raw = await _store.readJson(_draftKey);
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
    await _store.writeJson(_draftKey, _parecer.toJson());
    aoSalvar?.call();
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
