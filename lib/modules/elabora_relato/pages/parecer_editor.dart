import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/consulta_trecho.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/base_documentos_dialog.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/consulta_ia_dialog.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/webview_local.dart';

/// Arquivos do editor (CKEditor 5 + estilos do SEI) copiados dos assets para
/// uma pasta local servida ao WebView2 por um host virtual.
class _EditorArquivos {
  static const _nomes = [
    'editor.html',
    'editor.js',
    'sei_estilos.css',
    'ckeditor5.css',
    'ckeditor5.umd.js',
    'pt-br.umd.js',
  ];

  static Future<String>? _pasta;

  static Future<String> pasta() => _pasta ??= _copiar();

  static Future<String> _copiar() async {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'GestorUFU', 'ParecerEditor', 'app'));
    await dir.create(recursive: true);
    for (final nome in _nomes) {
      final data = await rootBundle.load('assets/parecer_editor/$nome');
      await File(p.join(dir.path, nome)).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return dir.path;
  }

  /// O ambiente do WebView2 é único por processo (compartilhado com o
  /// visualizador de PDF).
  static Future<void> ambiente() => WebviewLocal.ambiente();
}

/// Editor HTML de uma seção do parecer, com os recursos de edição do SEI
/// (CKEditor 5 dentro de um WebView2). O conteúdo é gravado no
/// [ParecerService] a cada alteração.
class ParecerEditor extends StatefulWidget {
  const ParecerEditor({
    required this.secao,
    required this.service,
    this.dica = '',
    super.key,
  });

  final ParecerSecao secao;
  final ParecerService service;
  final String dica;

  @override
  State<ParecerEditor> createState() => _ParecerEditorState();
}

class _ParecerEditorState extends State<ParecerEditor>
    with AutomaticKeepAliveClientMixin {
  final _web = WebviewController();
  final _subs = <StreamSubscription<dynamic>>[];
  bool _iniciado = false;
  bool _controladorCriado = false;
  bool _pronto = false;
  String? _erro;
  double _zoom = 1;
  Map<String, dynamic>? _selecao;
  String? _ativo;

  @override
  bool get wantKeepAlive => true;

  /// Processo deste editor: mensagens que cheguem depois de trocar de
  /// processo não podem gravar no outro.
  late final String _processoId = widget.service.processoId;

  bool get _mesmoProcesso => widget.service.processoId == _processoId;

  @override
  void initState() {
    super.initState();
    _processoId;
    widget.service.arvore.addListener(_atualizarLinks);
    _iniciar();
  }

  int _qtdLinks = -1;

  void _atualizarLinks() {
    final links = widget.service.linksSei();
    if (!_pronto || links.length == _qtdLinks) return;
    _qtdLinks = links.length;
    _js('window.parecer.definirLinks(${jsonEncode(links)})');
  }

  Future<void> _iniciar() async {
    try {
      final versao = await WebviewController.getWebViewVersion();
      if (versao == null) {
        throw StateError(
          'O Microsoft Edge WebView2 Runtime não está instalado. Instale-o '
          '(go.microsoft.com/fwlink/p/?LinkId=2124703) e reabra o Gestor.',
        );
      }
      final pasta = await _EditorArquivos.pasta();
      await _EditorArquivos.ambiente();
      await _web.initialize();
      _controladorCriado = true;
      _subs.add(_web.webMessage.listen(_mensagem));
      _subs.add(
        widget.service.insercoes
            .where((i) => i.secao == widget.secao)
            .listen(
              (i) => _js('window.parecer.inserir(${jsonEncode(i.html)})'),
            ),
      );
      _subs.add(
        widget.service.substituicoes.where((s) => s == widget.secao).listen((
          _,
        ) async {
          await _js(
            'window.parecer.definir(${jsonEncode(widget.service.parecer.secao(widget.secao))})',
          );
          _repintarComentarios();
        }),
      );
      _subs.add(
        widget.service.comentariosAlterados
            .where((s) => s == widget.secao)
            .listen((_) {
              _repintarComentarios();
              if (mounted) setState(() {});
            }),
      );
      await _web.setBackgroundColor(const Color(0xFFE9EAEE));
      await _web.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _web.addVirtualHostNameMapping(
        'parecer.gestor',
        pasta,
        WebviewHostResourceAccessKind.allow,
      );
      await _web.loadUrl('https://parecer.gestor/editor.html');
      if (mounted) setState(() => _iniciado = true);
    } catch (e) {
      if (mounted) setState(() => _erro = '$e');
    }
  }

  void _mensagem(dynamic msg) {
    if (msg is! Map) return;
    switch (msg['tipo']) {
      case 'carregado':
        final opcoes = {
          'html': widget.service.parecer.secao(widget.secao),
          'css': widget.service.estilosCss,
          'estilos': widget.service.estilos,
          'dica': widget.dica,
          'linksSei': widget.service.linksSei(),
          'comentarios': widget.service.comentarios(widget.secao),
        };
        _js('window.parecer.iniciar(${jsonEncode(opcoes)})');
      case 'pronto':
        if (mounted) setState(() => _pronto = true);
      case 'mudou':
        if (!_mesmoProcesso) return;
        widget.service.definirSecaoDoEditor(
          widget.secao,
          '${msg['html'] ?? ''}',
        );
      case 'erro':
        if (mounted) setState(() => _erro = '${msg['mensagem']}');
      case 'selecao':
        if (mounted) setState(() => _selecao = Map<String, dynamic>.from(msg));
      case 'consultarIa':
        final dados = Map<String, dynamic>.from(msg);
        if (mounted) setState(() => _selecao = dados);
        unawaited(_consultarIa(dados));
      case 'comentar':
        unawaited(_novoComentario());
      case 'comentarioClic':
        if (mounted) setState(() => _ativo = '${msg['id']}');
        final encontrado = widget.service
            .comentarios(widget.secao)
            .where((c) => '${c['id']}' == '${msg['id']}')
            .firstOrNull;
        if (encontrado != null && mounted) _detalharComentario(encontrado);
      case 'statusComentario':
        final c = msg['comentario'];
        if (c is Map) {
          final atualizado = Map<String, dynamic>.from(c);
          final atual = widget.service.parecer.comentarios
              .where((x) => '${x['id']}' == '${atualizado['id']}')
              .firstOrNull;
          if (atual != null &&
              atual['localizado'] != atualizado['localizado']) {
            unawaited(widget.service.salvarComentario(atualizado));
          }
        }
    }
  }

  Future<void> _js(String script) async {
    try {
      await _web.executeScript(script);
    } catch (_) {}
  }

  Future<void> _definirZoom(double z) async {
    setState(() => _zoom = z);
    await _web.setZoomFactor(z);
  }

  /// Recarrega o editor (ex.: depois de capturar os estilos do SEI).
  Future<void> recarregar() async {
    setState(() => _pronto = false);
    await _web.reload();
  }

  @override
  void dispose() {
    widget.service.arvore.removeListener(_atualizarLinks);
    for (final s in _subs) {
      s.cancel();
    }
    // Garante que o último trecho digitado (antes do debounce) seja salvo.
    unawaited(widget.service.salvarAgora());
    if (_controladorCriado) _web.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_erro != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppTheme.danger),
              const SizedBox(height: 10),
              Text(
                _erro!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  setState(() => _erro = null);
                  recarregar();
                },
                child: const Text('Tentar de novo'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final editorView = ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    if (_iniciado) Positioned.fill(child: Webview(_web)),
                    if (!_pronto)
                      const Positioned.fill(
                        child: ColoredBox(
                          color: Color(0xFFE9EAEE),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                  ],
                ),
              );
              if (constraints.maxWidth < 650) {
                return Column(
                  children: [
                    Expanded(child: editorView),
                    SizedBox(height: 170, child: _painelComentarios()),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: editorView),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 260, child: _painelComentarios()),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(
                Icons.zoom_in_rounded,
                size: 16,
                color: AppTheme.textSecondary,
              ),
              const SizedBox(width: 6),
              DropdownButton<double>(
                value: _zoom,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [0.75, 0.9, 1.0, 1.1, 1.25, 1.5]
                    .map(
                      (z) => DropdownMenuItem(
                        value: z,
                        child: Text('${(z * 100).round()}%'),
                      ),
                    )
                    .toList(),
                onChanged: (z) => z == null ? null : _definirZoom(z),
              ),
              const Spacer(),
              Text(
                'Salvo automaticamente no Gestor',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _painelComentarios() {
    final cs = widget.service.comentarios(widget.secao);
    final temSelecao = '${_selecao?['texto'] ?? ''}'.trim().isNotEmpty;
    return Column(
      children: [
        Row(
          children: [
            const Expanded(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'Comentários',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            IconButton(
              tooltip:
                  'Consultar a IA sobre a seleção ou o cursor (também pelo '
                  'botão direito no texto)',
              onPressed: _selecao == null ? null : () => _consultarIa(),
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            PopupMenuButton<String>(
              tooltip: 'Mais ações',
              icon: const Icon(Icons.more_vert),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'base',
                  child: Text('Base de documentos…'),
                ),
                const PopupMenuItem(
                  value: 'analisar',
                  child: Text('Analisar a seção com a base'),
                ),
                PopupMenuItem(
                  value: 'comentar',
                  enabled: temSelecao,
                  child: const Text('Comentar seleção'),
                ),
              ],
              onSelected: (v) => switch (v) {
                'base' => mostrarBaseDocumentos(context, widget.service.base),
                'analisar' => _analisarRelato(),
                _ => _novoComentario(),
              },
            ),
            IconButton(
              tooltip: 'Anterior',
              onPressed: cs.isEmpty ? null : () => _navegar(-1, cs),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Próximo',
              onPressed: cs.isEmpty ? null : () => _navegar(1, cs),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
          ],
        ),
        Expanded(
          child: cs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Selecione um trecho (ou clique no texto) e use o botão '
                      'direito para consultar a IA ou comentar.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final c in cs)
                      Card(
                        color: '${c['id']}' == _ativo
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                        child: ListTile(
                          dense: true,
                          title: Text(
                            '${c['texto'] ?? ''}',
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_categoria(c)} · ${_status(c)}\n'
                            '${c['localizado'] == false ? 'Trecho não localizado' : c['referencia'] ?? c['trecho'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            setState(() => _ativo = '${c['id']}');
                            _js('window.parecer.navegar(${jsonEncode(c)})');
                            _detalharComentario(c);
                          },
                          trailing: PopupMenuButton<String>(
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'confirmado',
                                child: Text('Marcar confirmado'),
                              ),
                              PopupMenuItem(
                                value: 'revisar',
                                child: Text('Marcar para revisão'),
                              ),
                              PopupMenuItem(
                                value: 'nao_aplica',
                                child: Text('Não se aplica'),
                              ),
                              PopupMenuItem(
                                value: 'editar',
                                child: Text('Editar'),
                              ),
                              PopupMenuItem(
                                value: 'excluir',
                                child: Text('Excluir'),
                              ),
                            ],
                            onSelected: (v) async {
                              if (v == 'editar') {
                                await _editarComentario(c);
                                return;
                              }
                              if (v == 'excluir') {
                                await widget.service.excluirComentario(
                                  '${c['id']}',
                                );
                              } else {
                                await widget.service.salvarComentario({
                                  ...c,
                                  'status': v,
                                });
                              }
                              _repintarComentarios();
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        if (cs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              '${(_indice(cs) + 1).clamp(1, cs.length)} de ${cs.length}',
            ),
          ),
      ],
    );
  }

  static String _categoria(Map<String, dynamic> c) =>
      switch ('${c['categoria'] ?? ''}') {
        '' => 'Nota',
        'analise_normativa' => 'Análise normativa',
        'consulta_ia' => 'Consulta à IA',
        'rastreabilidade' => 'Fontes do texto aceito',
        'defesa' => 'Defesa do voto',
        final x => x,
      };

  static String _status(Map<String, dynamic> c) =>
      switch ('${c['status'] ?? ''}') {
        'confirmado' => 'confirmado',
        'revisar' => 'para revisão',
        'nao_aplica' => 'não se aplica',
        _ => 'anotação',
      };

  void _repintarComentarios() => _js(
    'window.parecer.definirComentarios(${jsonEncode(widget.service.comentarios(widget.secao))})',
  );

  int _indice(List<Map<String, dynamic>> cs) =>
      math.max(0, cs.indexWhere((c) => '${c['id']}' == _ativo));

  void _navegar(int d, List<Map<String, dynamic>> cs) {
    final i = (_indice(cs) + d + cs.length) % cs.length;
    final c = cs[i];
    setState(() => _ativo = '${c['id']}');
    _js('window.parecer.navegar(${jsonEncode(c)})');
  }

  Future<void> _detalharComentario(Map<String, dynamic> c) async {
    final fields = <String, String>{
      'Trecho do relato': '${c['trecho'] ?? ''}',
      'Comentário': '${c['texto'] ?? ''}',
      'Pergunta feita': '${c['pergunta'] ?? ''}',
      'Referência': '${c['referencia'] ?? ''}',
      'Citação literal da fonte': '${c['citacao_literal'] ?? ''}',
      'Em palavras simples': '${c['explicacao_simples'] ?? ''}',
      'Por que importa': '${c['importancia'] ?? ''}',
      'Possível pergunta na arguição': '${c['pergunta_arguicao'] ?? ''}',
      'Resposta oral sugerida': '${c['resposta_oral'] ?? ''}',
      'Se insistirem (contra-argumento)': '${c['contra_argumento'] ?? ''}',
      'Fontes usadas': [
        for (final f in (c['fontes'] as List? ?? const []))
          if (f is Map)
            '${f['arquivo']}'
                '${'${f['localizacao'] ?? ''}'.isEmpty ? '' : ' — ${f['localizacao']}'}'
                '\n"${f['trecho'] ?? ''}"',
      ].join('\n\n'),
      'Texto antes da alteração': '${c['texto_anterior'] ?? ''}',
    }..removeWhere((_, v) => v.trim().isEmpty);
    if (fields.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${_categoria(c)} · ${_status(c)}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in fields.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.key,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        SelectableText(e.value),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  /// Âncora de um comentário na seleção (texto + contexto em volta).
  Map<String, dynamic> _ancora(Map<String, dynamic> s) {
    final t = '${s['texto'] ?? ''}';
    return {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'secao': widget.secao.id,
      'selecionado': t,
      'anterior': _fim('${s['anterior'] ?? ''}', 80),
      'posterior': _ini('${s['posterior'] ?? ''}', 80),
      'posicao': s['posicao'] ?? 0,
      'trecho': t.substring(0, math.min(100, t.length)),
      'localizado': true,
    };
  }

  static String _fim(String s, int n) =>
      s.length <= n ? s : s.substring(s.length - n);
  static String _ini(String s, int n) => s.length <= n ? s : s.substring(0, n);

  Future<void> _novoComentario() async {
    final s = _selecao;
    if (s == null || '${s['texto'] ?? ''}'.trim().isEmpty) return;
    await _editarComentario(_ancora(s));
  }

  Future<void> _editarComentario(Map<String, dynamic> c) async {
    final ctrl = TextEditingController(text: '${c['texto'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          c['texto'] == null ? 'Novo comentário' : 'Editar comentário',
        ),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'Comentário'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await widget.service.salvarComentario({...c, 'texto': ctrl.text.trim()});
      if (mounted) setState(() => _ativo = '${c['id']}');
      _repintarComentarios();
    }
    ctrl.dispose();
  }

  bool _consultaAberta = false;

  /// Abre a caixa "Consultar a IA" sobre a seleção (ou o cursor). O trecho
  /// fica reservado no editor (marcador vivo, destacado) enquanto a caixa
  /// está aberta; o relato só muda se o usuário aceitar a proposta.
  Future<void> _consultarIa([Map<String, dynamic>? dados]) async {
    if (_consultaAberta) return;
    final s = dados ?? _selecao;
    if (s == null) return;
    _consultaAberta = true;
    final id = 'c${DateTime.now().microsecondsSinceEpoch}';
    try {
      final reserva = await _web.executeScript(
        'window.parecer.reservar(${jsonEncode(id)})',
      );
      if (reserva is! Map || reserva['ok'] != true) {
        _aviso(
          reserva is Map
              ? '${reserva['motivo']}'
              : 'Não foi possível marcar o trecho no editor.',
        );
        return;
      }
      final esperado = '${reserva['texto'] ?? ''}';
      final trecho = TrechoConsultado(
        secao: widget.secao.titulo,
        texto: esperado.trim().isEmpty
            ? ''
            : ('${s['texto'] ?? ''}'.trim().isEmpty
                  ? esperado
                  : '${s['texto']}'),
        anterior: '${s['anterior'] ?? ''}',
        posterior: '${s['posterior'] ?? ''}',
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ConsultaIaDialog(
          service: widget.service,
          trecho: trecho,
          aceitar: (texto, proposta) async {
            final r = await _web.executeScript(
              'window.parecer.aplicar(${jsonEncode(id)}, '
              '${jsonEncode(texto)}, ${jsonEncode(esperado)})',
            );
            if (r is Map && r['ok'] == true) {
              await _registrarFontes(s, trecho, texto, proposta);
              return null;
            }
            return r is Map
                ? '${r['motivo']}'
                : 'O editor não confirmou a alteração.';
          },
          salvarComentario: (campos) async {
            final c = {..._ancora(s), ...campos};
            if (trecho.soCursor) {
              c['selecionado'] = '';
              c['trecho'] = 'Ponto do texto';
              c['localizado'] = false;
            }
            await widget.service.salvarComentario(c);
            _repintarComentarios();
            if (mounted) setState(() {});
          },
        ),
      );
    } finally {
      _consultaAberta = false;
      await _js('window.parecer.liberar(${jsonEncode(id)})');
    }
  }

  /// Rastreabilidade: ao aceitar uma proposta baseada em fontes, cria um
  /// comentário no texto aceito com as referências usadas (arquivo,
  /// localização e o início do trecho de cada fonte).
  Future<void> _registrarFontes(
    Map<String, dynamic> s,
    TrechoConsultado trecho,
    String texto,
    PropostaTexto proposta,
  ) async {
    if (proposta.fontes.isEmpty) return;
    // Âncora: o primeiro parágrafo do texto aceito.
    final ancora = texto
        .split(RegExp(r'\n\s*\n'))
        .first
        .trim()
        .replaceAll(RegExp(r'\s*\n\s*'), ' ');
    final editado = texto.trim() != proposta.texto.trim();
    await widget.service.salvarComentario({
      ..._ancora({...s, 'texto': ancora}),
      'categoria': 'rastreabilidade',
      'texto':
          'Texto ${trecho.soCursor ? 'inserido' : 'substituído'} com base em '
          '${proposta.fontes.length} fonte(s)'
          '${editado ? ' (proposta da IA editada pelo relator)' : ''}.',
      'referencia': proposta.fontes.map((f) => f.referencia).join('; '),
      'fontes': [
        for (final f in proposta.fontes)
          {
            'arquivo': f.arquivo,
            'localizacao': f.localizacao,
            'trecho': f.texto.length <= 400
                ? f.texto
                : '${f.texto.substring(0, 399)}…',
          },
      ],
      'explicacao_simples': proposta.justificativa,
      if (!trecho.soCursor) 'texto_anterior': trecho.texto,
      'aceito_em': DateTime.now().toIso8601String(),
    });
    _repintarComentarios();
    if (mounted) setState(() {});
  }

  /// Revisa a seção inteira contra a base de documentos e o processo:
  /// cada apontamento vira um comentário "para revisão" (o texto não muda).
  Future<void> _analisarRelato() async {
    final ai = widget.service.ia;
    if (ai == null) {
      _aviso('O Agente de IA não está disponível.');
      return;
    }
    final textoRelato = _textoHtml(widget.service.parecer.secao(widget.secao));
    if (textoRelato.trim().isEmpty) {
      _aviso('A seção está vazia.');
      return;
    }
    _aviso('Analisando a seção com a base de documentos…');
    try {
      // Fontes: os trechos mais relevantes para cada frase/parágrafo.
      final vistos = <String>{};
      final fontes = <FonteConsulta>[];
      final partes = textoRelato
          .split(RegExp(r'\n|(?<=[.;:])\s+(?=[A-Z0-9ÁÉÍÓÚÂÊÔÃÕÇ])'))
          .where((x) => x.trim().length > 30)
          .take(40);
      for (final parte in partes) {
        final achadas = await widget.service.base.fontesPara(
          parte,
          processo: widget.service.arvore.documentos,
          limiteBase: 3,
          limiteProcesso: 1,
        );
        for (final f in achadas) {
          if (vistos.add('${f.arquivo}|${f.localizacao}|${f.texto.length}')) {
            fontes.add(
              FonteConsulta(
                id: 'F${fontes.length + 1}',
                arquivo: f.arquivo,
                localizacao: f.localizacao,
                texto: f.texto,
                caminho: f.caminho,
              ),
            );
          }
        }
        if (fontes.length >= 30) break;
      }
      if (fontes.isEmpty) {
        _aviso(
          'Nenhuma fonte encontrada: escolha a pasta da base de documentos '
          'ou extraia a árvore do SEI com leitura dos documentos.',
        );
        return;
      }
      final raw = await ai.gerar(
        sistema: _sistemaAnalise,
        prompt:
            'SEÇÃO: ${widget.secao.titulo}\nTEXTO:\n$textoRelato\n\n'
            'FONTES:\n${ConsultaTrecho.fontesTexto(fontes)}',
      );
      final a = raw.indexOf('['), b = raw.lastIndexOf(']');
      if (a < 0 || b <= a) {
        throw const FormatException('a resposta não veio em JSON.');
      }
      final lista = jsonDecode(raw.substring(a, b + 1));
      if (lista is! List) throw const FormatException('JSON inválido.');
      final porId = {for (final f in fontes) f.id.toUpperCase(): f};
      var criados = 0;
      for (final item in lista.whereType<Map>()) {
        final idFonte = '${item['fonte'] ?? ''}'
            .replaceAll(RegExp(r'[\[\]\s]'), '')
            .toUpperCase();
        final fonte = porId[idFonte];
        final citacao = '${item['citacao'] ?? ''}';
        final ancora = '${item['trecho'] ?? ''}';
        final at = ancora.isEmpty ? -1 : textoRelato.indexOf(ancora);
        await widget.service.salvarComentario({
          ..._ancora({
            'texto': at < 0 ? '' : ancora,
            'anterior': at < 0 ? '' : textoRelato.substring(0, at),
            'posterior': at < 0
                ? ''
                : textoRelato.substring(at + ancora.length),
            'posicao': math.max(0, at),
          }),
          'id': '${DateTime.now().microsecondsSinceEpoch}-$criados',
          'trecho': ancora.isEmpty ? 'Análise da seção' : ancora,
          'localizado': at >= 0,
          'texto': '${item['identificacao'] ?? ''}',
          'categoria': 'analise_normativa',
          'referencia':
              fonte?.referencia ?? 'Fundamento não localizado nas fontes',
          'citacao_literal':
              fonte != null &&
                  ConsultaTrecho.citacaoNaFonte(citacao, fonte.texto)
              ? citacao
              : '',
          'explicacao_simples': '${item['explicacao_simples'] ?? ''}',
          'importancia': '${item['importancia'] ?? ''}',
          'pergunta_arguicao': '${item['pergunta'] ?? ''}',
          'resposta_oral': '${item['resposta_oral'] ?? ''}',
          'status': 'revisar',
        });
        criados++;
      }
      _repintarComentarios();
      if (mounted) setState(() {});
      _aviso(
        '$criados apontamento(s) adicionados como comentários para revisão '
        '(${fontes.length} trechos de fontes consultados).',
      );
    } catch (e) {
      _aviso('Não foi possível concluir a análise: $e');
    }
  }

  static const _sistemaAnalise = '''
Você revisa uma seção de parecer de conselho da UFU com rigor documental.
Use SOMENTE as fontes numeradas [F1], [F2]… Não invente normas, artigos,
fatos ou citações; "citacao" deve ser copiada literalmente da fonte.
Aponte: afirmações sem suporte, divergências com as normas, requisitos não
mencionados e perguntas prováveis numa arguição. Se a fonte não bastar,
diga isso em "identificacao" e deixe "fonte" vazio.
"trecho" deve ser copiado literalmente do TEXTO da seção (até 120
caracteres) para ancorar o comentário.
Responda SOMENTE com JSON: [{"trecho": "...", "identificacao": "...",
"fonte": "F1", "citacao": "...", "explicacao_simples": "...",
"importancia": "...", "pergunta": "...", "resposta_oral": "..."}]''';

  /// Texto visível da seção (o mesmo que o editor mostra), sem as tags.
  String _textoHtml(String html) => html
      .replaceAll(RegExp(r'</(p|div|li|h\d|tr)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .trim();

  void _aviso(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}
