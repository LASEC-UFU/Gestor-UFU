import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

import 'package:gestor_ufu/platform/ui/leitor_comentado/marca_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/webview_local.dart';

/// Trecho selecionado no PDF: página e posição no texto da página (pdf.js).
typedef SelecaoPdf = ({int pagina, int inicio, int fim, String texto});

/// Comandos do app para a [SuperficiePdf] aberta.
class SuperficiePdfController {
  _SuperficiePdfState? _estado;

  /// Rola até a marca e confirma se o trecho foi encontrado na página.
  Future<bool> irPara(MarcaDocumento m) async {
    final e = _estado;
    if (e == null || !m.noPdf) return false;
    return e._irPara(m);
  }

  Future<void> irParaPagina(int pagina) async =>
      _estado?._js('window.pdfv.irPara(${jsonEncode({'pagina': pagina})})');

  /// Busca a próxima (ou anterior) ocorrência; responde em `aoBuscar`.
  Future<void> buscar(String termo, {bool proxima = true}) async =>
      _estado?._js(
        'window.pdfv.buscar(${jsonEncode(termo)}, ${proxima ? 'true' : 'false'})',
      );

  /// "+", "-", "largura" ou um fator (1 = 100%).
  Future<void> zoom(String valor) async =>
      _estado?._js('window.pdfv.zoom(${jsonEncode(valor)})');
}

/// PDF como no arquivo (pdf.js num WebView2), com texto selecionável e as
/// marcações desenhadas por cima. Superfície comum da camada de comentários
/// (ver `LeitorComentado`).
class SuperficiePdf extends StatefulWidget {
  const SuperficiePdf({
    required this.pasta,
    required this.arquivo,
    required this.marcas,
    required this.controller,
    required this.aoLerPaginas,
    required this.aoSelecionar,
    required this.aoPedirAcao,
    required this.aoTocarMarca,
    this.selecionada,
    this.aoBuscar,
    this.aoMudarEscala,
    super.key,
  });

  /// Pasta servida ao WebView2 (o visualizador é copiado para
  /// `<pasta>/_visualizador`).
  final String pasta;

  /// Nome do PDF dentro de [pasta].
  final String arquivo;
  final List<MarcaDocumento> marcas;

  /// Id da marca do comentário selecionado (destaque próprio).
  final String? selecionada;
  final SuperficiePdfController controller;

  /// Texto de cada página (para âncoras e contexto).
  final ValueChanged<List<String>> aoLerPaginas;
  final ValueChanged<SelecaoPdf?> aoSelecionar;
  final void Function(AcaoTrecho acao, SelecaoPdf selecao) aoPedirAcao;

  /// Clique/toque numa marca do documento.
  final ValueChanged<String> aoTocarMarca;
  final void Function(bool achou, int pagina)? aoBuscar;
  final ValueChanged<double>? aoMudarEscala;

  @override
  State<SuperficiePdf> createState() => _SuperficiePdfState();
}

class _SuperficiePdfState extends State<SuperficiePdf> {
  static const _host = 'anexos.gestor';

  final _web = WebviewController();
  StreamSubscription<dynamic>? _sub;
  bool _criado = false;
  bool _iniciado = false;
  bool _aberto = false;
  String? _erro;
  final _navegacoes = <int, Completer<bool>>{};
  int _proximaNavegacao = 0;
  MarcaDocumento? _pendente;

  @override
  void initState() {
    super.initState();
    widget.controller._estado = this;
    _iniciar();
  }

  @override
  void didUpdateWidget(SuperficiePdf antigo) {
    super.didUpdateWidget(antigo);
    widget.controller._estado = this;
    if (_aberto &&
        (!identical(antigo.marcas, widget.marcas) ||
            antigo.selecionada != widget.selecionada)) {
      _enviarMarcas();
    }
  }

  @override
  void dispose() {
    if (widget.controller._estado == this) widget.controller._estado = null;
    for (final c in _navegacoes.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _sub?.cancel();
    if (_criado) _web.dispose();
    super.dispose();
  }

  Future<void> _iniciar() async {
    try {
      await WebviewLocal.exigirRuntime();
      await WebviewLocal.copiarAssets(
        'assets/pdf_viewer/',
        p.join(widget.pasta, '_visualizador'),
      );
      await WebviewLocal.ambiente();
      await _web.initialize();
      _criado = true;
      _sub = _web.webMessage.listen(_mensagem);
      await _web.setBackgroundColor(const Color(0xFFE9EAEE));
      await _web.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _web.addVirtualHostNameMapping(
        _host,
        widget.pasta,
        WebviewHostResourceAccessKind.allow,
      );
      await _web.loadUrl('https://$_host/_visualizador/viewer.html');
      if (mounted) setState(() => _iniciado = true);
    } catch (e) {
      if (mounted) setState(() => _erro = e is StateError ? e.message : '$e');
    }
  }

  Future<void> _js(String script) async {
    if (!_criado) return;
    try {
      await _web.executeScript(script);
    } catch (_) {}
  }

  Future<bool> _irPara(MarcaDocumento m) async {
    if (!_aberto) {
      // Ainda abrindo: navega quando as páginas estiverem prontas.
      _pendente = m;
      return true;
    }
    final id = _proximaNavegacao++;
    final c = Completer<bool>();
    _navegacoes[id] = c;
    await _js(
      'window.pdfv.irPara(${jsonEncode({'pagina': m.pdfPagina, 'inicio': m.pdfInicio, 'fim': m.pdfFim, 'pedido': id})})',
    );
    return c.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () => false,
    ).whenComplete(() => _navegacoes.remove(id));
  }

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  List<Map<String, Object?>> _marcasJs() => [
    for (final m in widget.marcas)
      if (m.noPdf)
        {
          'id': m.id,
          'pagina': m.pdfPagina,
          'inicio': m.pdfInicio,
          'fim': m.pdfFim,
          'cor': _hex(m.cor),
          'comentario': m.comentada,
        },
  ];

  void _enviarMarcas() => _js(
    'window.pdfv.definirMarcacoes(${jsonEncode(_marcasJs())}, '
    '${jsonEncode(widget.selecionada)})',
  );

  static SelecaoPdf? _selecao(Map msg) {
    final pagina = (msg['pagina'] as num?)?.toInt();
    final inicio = (msg['inicio'] as num?)?.toInt();
    final fim = (msg['fim'] as num?)?.toInt();
    if (pagina == null || inicio == null || fim == null || fim <= inicio) {
      return null;
    }
    return (
      pagina: pagina,
      inicio: inicio,
      fim: fim,
      texto: '${msg['texto'] ?? ''}',
    );
  }

  void _mensagem(dynamic msg) {
    if (msg is! Map || !mounted) return;
    switch (msg['tipo']) {
      case 'carregado':
        _js(
          'window.pdfv.abrir(${jsonEncode({'url': '../${widget.arquivo}', 'marcacoes': _marcasJs(), 'ativa': widget.selecionada, 'escala': 'largura'})})',
        );
      case 'aberto':
        _aberto = true;
        setState(() {});
        widget.aoLerPaginas([
          for (final t in (msg['textos'] as List? ?? const [])) '$t',
        ]);
        final pendente = _pendente;
        _pendente = null;
        if (pendente != null) unawaited(_irPara(pendente));
      case 'navegou':
        final id = (msg['pedido'] as num?)?.toInt();
        final c = id == null ? null : _navegacoes[id];
        if (c != null && !c.isCompleted) c.complete(msg['ok'] == true);
      case 'selecao':
        widget.aoSelecionar(msg['vazio'] == true ? null : _selecao(msg));
      case 'acao':
        final s = _selecao(msg);
        final acao = switch ('${msg['acao']}') {
          'marcar' => AcaoTrecho.marcar,
          'comentar' => AcaoTrecho.comentar,
          _ => AcaoTrecho.perguntar,
        };
        if (s != null) widget.aoPedirAcao(acao, s);
      case 'marcacao':
        widget.aoTocarMarca('${msg['id']}');
      case 'busca':
        widget.aoBuscar?.call(
          msg['achou'] == true,
          (msg['pagina'] as num?)?.toInt() ?? 0,
        );
      case 'escala':
        widget.aoMudarEscala?.call((msg['escala'] as num?)?.toDouble() ?? 1);
      case 'erro':
        // Depois de aberto, falhas de uma página não derrubam a visão.
        if (!_aberto) setState(() => _erro = '${msg['mensagem']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_erro != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _erro!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black87),
          ),
        ),
      );
    }
    return Semantics(
      label: 'Documento PDF',
      child: Stack(
        children: [
          if (_iniciado) Positioned.fill(child: Webview(_web)),
          if (!_aberto)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xFFE9EAEE),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
