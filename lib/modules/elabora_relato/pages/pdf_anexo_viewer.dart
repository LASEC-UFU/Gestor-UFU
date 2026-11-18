import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/webview_local.dart';

/// Trecho selecionado na visão "PDF original": página e posição no texto
/// da página (pdf.js).
typedef SelecaoPdf = ({int pagina, int inicio, int fim, String texto});

/// Comandos do app para o visualizador aberto.
class PdfViewerController {
  _PdfAnexoViewerState? _estado;

  Future<void> irPara(MarcacaoAnexo m) async => _estado?._js(
    'window.pdfv.irPara(${jsonEncode({'pagina': m.pdfPagina, 'inicio': m.pdfInicio, 'fim': m.pdfFim})})',
  );

  Future<void> irParaPagina(int pagina) async =>
      _estado?._js('window.pdfv.irPara(${jsonEncode({'pagina': pagina})})');

  /// Busca a próxima (ou anterior) ocorrência; responde em `onBusca`.
  Future<void> buscar(
    String termo, {
    bool proxima = true,
  }) async => _estado?._js(
    'window.pdfv.buscar(${jsonEncode(termo)}, ${proxima ? 'true' : 'false'})',
  );

  /// "+", "-", "largura" ou um fator (1 = 100%).
  Future<void> zoom(String valor) async =>
      _estado?._js('window.pdfv.zoom(${jsonEncode(valor)})');
}

/// Visão "PDF original" de um documento anexado: as páginas como no
/// arquivo (pdf.js num WebView2), com texto selecionável e as marcações
/// desenhadas por cima.
class PdfAnexoViewer extends StatefulWidget {
  const PdfAnexoViewer({
    required this.pasta,
    required this.arquivo,
    required this.marcacoes,
    required this.controller,
    required this.onPaginas,
    required this.onSelecao,
    required this.onAcao,
    required this.onMarcacao,
    this.ativa,
    this.onBusca,
    this.onEscala,
    super.key,
  });

  /// Pasta dos anexos guardados (servida ao WebView2).
  final String pasta;

  /// Nome do PDF guardado nessa pasta.
  final String arquivo;
  final List<MarcacaoAnexo> marcacoes;
  final String? ativa;
  final PdfViewerController controller;

  /// Texto de cada página (para as âncoras e o contexto da IA).
  final ValueChanged<List<String>> onPaginas;
  final ValueChanged<SelecaoPdf?> onSelecao;

  /// Ação do menu do botão direito: "marcar", "comentar" ou "perguntar".
  final void Function(String acao, SelecaoPdf selecao) onAcao;

  /// Clique numa marcação (abrir = duplo clique ou "Abrir marcação").
  final void Function(String id, bool abrir) onMarcacao;
  final void Function(bool achou, int pagina)? onBusca;
  final ValueChanged<double>? onEscala;

  @override
  State<PdfAnexoViewer> createState() => _PdfAnexoViewerState();
}

class _PdfAnexoViewerState extends State<PdfAnexoViewer> {
  static const _host = 'anexos.gestor';

  final _web = WebviewController();
  StreamSubscription<dynamic>? _sub;
  bool _criado = false;
  bool _iniciado = false;
  bool _aberto = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    widget.controller._estado = this;
    _iniciar();
  }

  @override
  void didUpdateWidget(PdfAnexoViewer antigo) {
    super.didUpdateWidget(antigo);
    widget.controller._estado = this;
    if (_aberto &&
        (!identical(antigo.marcacoes, widget.marcacoes) ||
            antigo.ativa != widget.ativa)) {
      _enviarMarcacoes();
    }
  }

  @override
  void dispose() {
    if (widget.controller._estado == this) widget.controller._estado = null;
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

  List<Map<String, Object?>> _marcacoesJs() => [
    for (final m in widget.marcacoes)
      if (m.pdfPagina > 0)
        {
          'id': m.id,
          'pagina': m.pdfPagina,
          'inicio': m.pdfInicio,
          'fim': m.pdfFim,
          'cor': m.cor,
          'comentario': m.comentario.isNotEmpty,
        },
  ];

  void _enviarMarcacoes() => _js(
    'window.pdfv.definirMarcacoes(${jsonEncode(_marcacoesJs())}, '
    '${jsonEncode(widget.ativa)})',
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
          'window.pdfv.abrir(${jsonEncode({'url': '../${widget.arquivo}', 'marcacoes': _marcacoesJs(), 'ativa': widget.ativa, 'escala': 'largura'})})',
        );
      case 'aberto':
        _aberto = true;
        widget.onPaginas([
          for (final t in (msg['textos'] as List? ?? const [])) '$t',
        ]);
      case 'selecao':
        widget.onSelecao(msg['vazio'] == true ? null : _selecao(msg));
      case 'acao':
        final s = _selecao(msg);
        if (s != null) widget.onAcao('${msg['acao']}', s);
      case 'marcacao':
        widget.onMarcacao('${msg['id']}', msg['abrir'] == true);
      case 'busca':
        widget.onBusca?.call(
          msg['achou'] == true,
          (msg['pagina'] as num?)?.toInt() ?? 0,
        );
      case 'escala':
        widget.onEscala?.call((msg['escala'] as num?)?.toDouble() ?? 1);
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
    return Stack(
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
    );
  }
}
