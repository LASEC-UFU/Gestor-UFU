import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show RenderEditable;

import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/marca_documento.dart';

/// Trecho selecionado na visão de texto: parágrafo e posição nele.
typedef SelecaoTexto = ({int paragrafo, int inicio, int fim});

/// Comandos do app para a [SuperficieTexto] aberta.
class SuperficieTextoController {
  _SuperficieTextoState? _estado;

  /// Rola até o parágrafo da marca; false se ele não existe.
  Future<bool> irPara(MarcaDocumento m) async =>
      m.noTexto && (await _estado?._irPara(m.paragrafo) ?? false);

  /// Próxima (ou anterior) ocorrência de [termo]; false se não houver.
  bool buscar(String termo, {bool proxima = true}) =>
      _estado?._buscar(termo, proxima) ?? false;
}

/// Documento como texto (DOCX, TXT/MD, HTML ou a visão "Texto" de um PDF),
/// em folha branca, com seleção, menu de contexto e as marcações. Superfície
/// comum da camada de comentários (ver `LeitorComentado`).
class SuperficieTexto extends StatefulWidget {
  const SuperficieTexto({
    required this.paragrafos,
    required this.marcas,
    required this.controller,
    required this.aoSelecionar,
    required this.aoPedirAcao,
    required this.aoTocarMarca,
    this.selecionada,
    super.key,
  });

  final List<ParagrafoDocumento> paragrafos;
  final List<MarcaDocumento> marcas;
  final String? selecionada;
  final SuperficieTextoController controller;
  final ValueChanged<SelecaoTexto?> aoSelecionar;
  final void Function(AcaoTrecho acao, SelecaoTexto selecao) aoPedirAcao;
  final ValueChanged<String> aoTocarMarca;

  @override
  State<SuperficieTexto> createState() => _SuperficieTextoState();
}

class _SuperficieTextoState extends State<SuperficieTexto> {
  final _scroll = ScrollController();
  final _chaves = <int, GlobalKey>{};
  final _chavesTexto = <int, GlobalKey>{};
  final Map<int, ({int paragrafo, Offset ponto})> _pontosPressionados = {};
  int _ultimaBusca = -1;

  @override
  void initState() {
    super.initState();
    widget.controller._estado = this;
  }

  @override
  void didUpdateWidget(SuperficieTexto antigo) {
    super.didUpdateWidget(antigo);
    widget.controller._estado = this;
    if (!identical(antigo.paragrafos, widget.paragrafos)) {
      _chaves.clear();
      _ultimaBusca = -1;
    }
  }

  @override
  void dispose() {
    if (widget.controller._estado == this) widget.controller._estado = null;
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _irPara(int i) async {
    if (i < 0 || i >= widget.paragrafos.length) return false;
    for (var tentativa = 0; tentativa < 6; tentativa++) {
      final ctx = _chaves[i]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.25,
          duration: const Duration(milliseconds: 200),
        );
        return true;
      }
      if (!_scroll.hasClients) return false;
      // Fora da área construída: salta para a posição estimada.
      final pos = _scroll.position;
      _scroll.jumpTo(
        (pos.maxScrollExtent * i / widget.paragrafos.length).clamp(
          0.0,
          pos.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }

  bool _buscar(String termo, bool proxima) {
    final t = normalizarBusca(termo);
    final pars = widget.paragrafos;
    if (t.isEmpty || pars.isEmpty) return false;
    final n = pars.length;
    for (var k = 1; k <= n; k++) {
      final i = proxima
          ? (_ultimaBusca + k) % n
          : (_ultimaBusca - k + n * 2) % n;
      if (normalizarBusca(pars[i].texto).contains(t)) {
        setState(() => _ultimaBusca = i);
        _irPara(i);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final pars = widget.paragrafos;
    return Semantics(
      label: 'Documento em texto',
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 80),
          itemCount: pars.length,
          itemBuilder: (_, i) => _paragrafo(i),
        ),
      ),
    );
  }

  Widget _paragrafo(int i) {
    final pars = widget.paragrafos;
    final par = pars[i];
    final marcas = [
      for (final m in widget.marcas)
        if (m.paragrafo == i && m.noTexto) m,
    ];
    final temSelecionada = marcas.any((m) => m.id == widget.selecionada);
    final novaPagina =
        par.pagina > 0 && (i == 0 || pars[i - 1].pagina != par.pagina);
    final base = TextStyle(
      color: const Color(0xFF1D2230),
      fontSize: par.titulo ? 15 : 14,
      height: 1.5,
      fontWeight: par.titulo ? FontWeight.w700 : FontWeight.w400,
    );
    return Column(
      key: _chaves.putIfAbsent(i, GlobalKey.new),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (novaPagina)
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Row(
              children: [
                const Expanded(child: Divider(color: Color(0xFFD6D8DE))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Página ${par.pagina}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF7A8090),
                    ),
                  ),
                ),
                const Expanded(child: Divider(color: Color(0xFFD6D8DE))),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          decoration: BoxDecoration(
            color: _ultimaBusca == i ? const Color(0x1A1F6FD1) : null,
            // Marcador na margem do parágrafo do comentário selecionado.
            border: Border(
              left: BorderSide(
                color: temSelecionada
                    ? corContornoSelecionado
                    : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Listener(
            key: _chavesTexto.putIfAbsent(i, GlobalKey.new),
            onPointerDown: (e) => _pressionar(i, e),
            onPointerUp: (e) => _soltar(i, e, marcas),
            onPointerCancel: (e) => _pontosPressionados.remove(e.pointer),
            child: SelectableText.rich(
              TextSpan(
                style: base,
                children: [
                  for (final s in segmentarTexto(par.texto, marcas))
                    TextSpan(text: s.texto, style: _estilo(s.marca)),
                ],
              ),
              onSelectionChanged: (sel, _) => _aoSelecionar(i, sel, marcas),
              contextMenuBuilder: (context, state) =>
                  _menu(context, state, i, marcas),
            ),
          ),
        ),
      ],
    );
  }

  TextStyle? _estilo(MarcaDocumento? m) {
    if (m == null) return null;
    if (m.id == widget.selecionada) {
      return const TextStyle(
        backgroundColor: corSelecionada,
        color: Color(0xFF062A57),
        decoration: TextDecoration.underline,
        decorationColor: corContornoSelecionado,
        decorationThickness: 2.5,
      );
    }
    return TextStyle(
      backgroundColor: m.cor.withAlpha(150),
      decoration: m.comentada ? TextDecoration.underline : null,
      decorationStyle: TextDecorationStyle.dotted,
    );
  }

  void _aoSelecionar(int i, TextSelection sel, List<MarcaDocumento> marcas) {
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      widget.aoSelecionar(null);
      return;
    }
    widget.aoSelecionar((paragrafo: i, inicio: sel.start, fim: sel.end));
  }

  TextPosition? _posicaoRender(RenderObject? atual, Offset global) {
    if (atual is RenderEditable) return atual.getPositionForPoint(global);
    TextPosition? encontrado;
    atual?.visitChildren((filho) {
      encontrado ??= _posicaoRender(filho, global);
    });
    return encontrado;
  }

  void _pressionar(int i, PointerDownEvent e) {
    if ((e.buttons & kPrimaryButton) == 0) return;
    _pontosPressionados[e.pointer] = (paragrafo: i, ponto: e.position);
  }

  void _soltar(int i, PointerUpEvent e, List<MarcaDocumento> marcas) {
    final pressionado = _pontosPressionados.remove(e.pointer);
    if (pressionado == null || pressionado.paragrafo != i) return;
    if ((e.position - pressionado.ponto).distance > 12) return;
    final contexto = _chavesTexto[i]?.currentContext;
    final posicao = _posicaoRender(contexto?.findRenderObject(), e.position);
    if (posicao == null) return;
    final marca = marcas
        .where((m) => posicao.offset >= m.inicio && posicao.offset < m.fim)
        .lastOrNull;
    if (marca != null) widget.aoTocarMarca(marca.id);
  }

  Widget _menu(
    BuildContext context,
    EditableTextState state,
    int i,
    List<MarcaDocumento> marcas,
  ) {
    final sel = state.textEditingValue.selection;
    final temSelecao = sel.isValid && !sel.isCollapsed;
    final sobre = sel.isValid
        ? marcas
              .where((x) => sel.start < x.fim && sel.end > x.inicio)
              .lastOrNull
        : null;
    void pedir(AcaoTrecho a) {
      state.hideToolbar();
      widget.aoPedirAcao(a, (paragrafo: i, inicio: sel.start, fim: sel.end));
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        if (temSelecao) ...[
          ContextMenuButtonItem(
            label: 'Marcar',
            onPressed: () => pedir(AcaoTrecho.marcar),
          ),
          ContextMenuButtonItem(
            label: 'Comentar…',
            onPressed: () => pedir(AcaoTrecho.comentar),
          ),
          ContextMenuButtonItem(
            label: 'Perguntar à IA…',
            onPressed: () => pedir(AcaoTrecho.perguntar),
          ),
        ],
        if (sobre != null)
          ContextMenuButtonItem(
            label: 'Ver o comentário',
            onPressed: () {
              state.hideToolbar();
              widget.aoTocarMarca(sobre.id);
            },
          ),
        ...state.contextMenuButtonItems,
      ],
    );
  }
}
