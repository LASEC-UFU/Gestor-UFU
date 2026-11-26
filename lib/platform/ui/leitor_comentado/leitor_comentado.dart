import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado_controller.dart';

/// Documento (HTML ou PDF) com a camada de comentários comum a todos os
/// módulos:
/// - desktop: painel lateral que abre/fecha e é redimensionável;
/// - tela estreita: o documento ocupa a tela e os comentários ficam numa
///   folha inferior (lista ou só o comentário ativo), sem perder a posição
///   de leitura;
/// - cartões que expandem no próprio painel; selecionar um comentário (pelo
///   cartão, pela busca ou por anterior/próximo) leva o documento ao trecho
///   e o destaca, pelo [LeitorComentadoController.navegar].
class LeitorComentado extends StatefulWidget {
  const LeitorComentado({
    required this.documento,
    required this.comentarios,
    required this.controller,
    this.titulo = 'Comentários',
    this.acoesPainel = const [],
    this.vazio,
    this.larguraPadrao = 360,
    this.limiteEstreito = 900,
    this.onSelectionChanged,
    this.somentePainel = false,
    this.ocultarPainel = false,
    super.key,
  });

  final Widget documento;

  /// Na ordem em que aparecem no documento.
  final List<ComentarioDocumento> comentarios;
  final LeitorComentadoController controller;
  final String titulo;

  /// Botões extras no topo do painel (ex.: "Analisar com IA").
  final List<Widget> acoesPainel;

  /// Texto quando não há comentários.
  final String? vazio;
  final double larguraPadrao;

  /// Abaixo desta largura, usa a folha inferior.
  final double limiteEstreito;

  /// Informa também seleções iniciadas no próprio documento. Útil para manter
  /// uma janela de comentários destacada no mesmo comentário ativo.
  final ValueChanged<String?>? onSelectionChanged;

  /// Exibe somente o painel. Usado pela janela destacável para preservar
  /// exatamente os mesmos cartões, busca e comandos do painel acoplado.
  final bool somentePainel;

  /// Quando o painel foi destacado para outra janela, mantém apenas o
  /// documento nesta janela principal.
  final bool ocultarPainel;

  static const larguraMinima = 280.0;
  static const larguraMaximaAbsoluta = 640.0;

  @override
  State<LeitorComentado> createState() => _LeitorComentadoState();
}

class _LeitorComentadoState extends State<LeitorComentado> {
  final _lista = ScrollController();
  final _busca = TextEditingController();
  final _chaves = <String, GlobalKey>{};
  final _foco = FocusNode(debugLabel: 'Leitor com comentários');
  String? _ultimoVisto;

  LeitorComentadoController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.definirComentarios(widget.comentarios);
    _busca.text = c.busca;
    c.addListener(_mudou);
  }

  @override
  void didUpdateWidget(LeitorComentado antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.controller != widget.controller) {
      antigo.controller.removeListener(_mudou);
      widget.controller.addListener(_mudou);
    }
    widget.controller.definirComentarios(widget.comentarios);
  }

  @override
  void dispose() {
    c.removeListener(_mudou);
    _lista.dispose();
    _busca.dispose();
    _foco.dispose();
    super.dispose();
  }

  void _mudou() {
    if (!mounted) return;
    setState(() {});
    final sel = c.selecionado;
    final mudouSelecao = sel != _ultimoVisto;
    if (mudouSelecao) widget.onSelectionChanged?.call(sel);
    if (sel != null && mudouSelecao) {
      // Uma seleção vinda do documento também passa a navegação por teclado
      // para o painel. Sem isso, ←/→ pode continuar no TabBar da página e
      // trocar Relatório/Fundamentação em vez de trocar o comentário.
      _assumirFocoDoPainel();
      _mostrarCartao(sel);
    }
    _ultimoVisto = sel;
  }

  /// O TabBar do editor também conhece ←/→. Não basta o painel ter um foco
  /// ancestral: um cartão, botão ou marca clicado pode manter o foco primário
  /// em outro controle durante o mesmo gesto. Tornamos o painel o foco
  /// primário antes da seleção/navegação para que nenhuma seta residual seja
  /// interpretada como troca de aba.
  void _assumirFocoDoPainel() {
    if (!_foco.hasPrimaryFocus) _foco.requestFocus();
  }

  /// Rola a lista até o cartão [id]. A lista só monta os cartões perto da
  /// área visível: se o cartão ainda não existe, salta para a posição
  /// estimada e tenta de novo no quadro seguinte.
  Future<void> _mostrarCartao(String id) async {
    for (var tentativa = 0; tentativa < 8; tentativa++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || c.selecionado != id) return;
      final ctx = _chaves[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.1,
          duration: const Duration(milliseconds: 150),
        );
        return;
      }
      if (!_lista.hasClients) return;
      final visiveis = c.visiveis;
      final i = visiveis.indexWhere((x) => x.id == id);
      if (i < 0) return;
      final pos = _lista.position;
      _lista.jumpTo(
        (pos.maxScrollExtent * i / (visiveis.length - 1).clamp(1, 1 << 30))
            .clamp(0.0, pos.maxScrollExtent),
      );
    }
  }

  /// A navegação por teclado fica restrita ao painel que está com foco.
  /// Paisagem usa ←/→; retrato usa ↑/↓. Campos editáveis mantêm suas setas.
  KeyEventResult _tecla(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final ctx = FocusManager.instance.primaryFocus?.context;
    final emTexto =
        ctx != null &&
        (ctx.widget is EditableText ||
            ctx.findAncestorWidgetOfExactType<EditableText>() != null);
    if (emTexto) return KeyEventResult.ignored;

    // No painel, ↑/↓ percorrem os comentários. ←/→ ficam livres para os
    // controles que tiverem foco (inclusive a edição do texto).
    final setaVertical =
        e.logicalKey == LogicalKeyboardKey.arrowUp ||
        e.logicalKey == LogicalKeyboardKey.arrowDown;
    final anterior = e.logicalKey == LogicalKeyboardKey.arrowUp;
    final proximo = e.logicalKey == LogicalKeyboardKey.arrowDown;
    if (anterior || proximo) {
      if (anterior) {
        if (c.temAnterior) c.anterior();
      } else if (c.temProximo) {
        c.proximo();
      }
      return KeyEventResult.handled;
    }
    if (setaVertical) return KeyEventResult.handled;
    if (e.logicalKey == LogicalKeyboardKey.escape && c.selecionado != null) {
      c.limparSelecao();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.somentePainel) {
      return _painelComFoco(_painel(estreito: false));
    }
    if (widget.ocultarPainel) return widget.documento;
    return LayoutBuilder(
      builder: (context, box) =>
          box.maxWidth < widget.limiteEstreito ? _estreito(box) : _largo(box),
    );
  }

  Widget _painelComFoco(Widget child) =>
      Focus(focusNode: _foco, onKeyEvent: _tecla, child: child);

  // --------------------------------------------------------------- desktop

  Widget _largo(BoxConstraints box) {
    final maxima = (box.maxWidth * 0.55).clamp(
      LeitorComentado.larguraMinima,
      LeitorComentado.larguraMaximaAbsoluta,
    );
    final largura = (c.largura ?? widget.larguraPadrao).clamp(
      LeitorComentado.larguraMinima,
      maxima,
    );
    if (!c.painelAberto) {
      return Stack(
        children: [
          Positioned.fill(child: widget.documento),
          Positioned(
            top: 10,
            right: 10,
            child: _BotaoAbrir(
              total: widget.comentarios.length,
              aoAbrir: c.abrirPainel,
            ),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: widget.documento),
        _Divisor(
          largura: largura,
          minima: LeitorComentado.larguraMinima,
          maxima: maxima,
          aoMudar: c.definirLargura,
        ),
        SizedBox(
          width: largura,
          child: _painelComFoco(_painel(estreito: false)),
        ),
      ],
    );
  }

  // ---------------------------------------------------------- tela estreita

  Widget _estreito(BoxConstraints box) {
    final ativo = c.comentarioSelecionado;
    final compacta = c.folhaCompacta && ativo != null;
    final altura = compacta ? null : box.maxHeight * 0.62;
    return Stack(
      children: [
        Positioned.fill(child: widget.documento),
        if (!c.painelAberto)
          Positioned(
            right: 12,
            bottom: 12,
            child: _BotaoAbrir(
              total: widget.comentarios.length,
              aoAbrir: c.abrirPainel,
            ),
          )
        else
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 150),
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  height: altura,
                  child: _painelComFoco(
                    compacta ? _folhaCompacta(ativo) : _painel(estreito: true),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Folha recolhida: só o comentário ativo, com anterior/próximo, para ler
  /// o documento e o comentário ao mesmo tempo.
  Widget _folhaCompacta(ComentarioDocumento ativo) {
    final tema = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.my_location,
                  size: 16,
                  color: tema.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Comentário ${c.indiceSelecionado + 1} de '
                    '${c.visiveis.length}${ativo.local.isEmpty ? '' : ' · ${ativo.local}'}',
                    style: tema.textTheme.labelMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Ver a lista de comentários',
                  icon: const Icon(Icons.expand_less),
                  onPressed: () => c.definirFolhaCompacta(false),
                ),
                IconButton(
                  tooltip: 'Fechar comentários',
                  icon: const Icon(Icons.close),
                  onPressed: c.fecharPainel,
                ),
              ],
            ),
            Text(
              ativo.titulo,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: tema.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (c.aviso(ativo.id) != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _Aviso(c.aviso(ativo.id)!),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: c.temAnterior ? c.anterior : null,
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('Anterior'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () => c.definirFolhaCompacta(false),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: const Text('Ler comentário'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: c.temProximo ? c.proximo : null,
                    icon: const Icon(Icons.arrow_downward),
                    label: const Text('Próximo'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- painel

  Widget _painel({required bool estreito}) {
    final tema = Theme.of(context);
    final visiveis = c.visiveis;
    final total = widget.comentarios.length;
    final buscando = c.busca.trim().isNotEmpty;
    return Container(
      decoration: estreito
          ? null
          : BoxDecoration(
              gradient: AppTheme.cardGradient,
              border: Border.all(color: AppTheme.divider),
              borderRadius: BorderRadius.circular(12),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (estreito)
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: tema.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      '${widget.titulo} ($total)',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
                ...widget.acoesPainel,
                IconButton(
                  tooltip: estreito
                      ? 'Fechar comentários'
                      : 'Fechar o painel de comentários',
                  icon: Icon(estreito ? Icons.close : Icons.chevron_right),
                  onPressed: c.fecharPainel,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
            child: TextField(
              controller: _busca,
              onChanged: c.definirBusca,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Buscar nos comentários e trechos',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: buscando
                    ? IconButton(
                        tooltip: 'Limpar a busca',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _busca.clear();
                          c.definirBusca('');
                        },
                      )
                    : null,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 6, 2),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      buscando
                          ? (visiveis.isEmpty
                                ? 'Nenhum comentário encontrado'
                                : '${visiveis.length} de $total '
                                      'comentário(s) encontrado(s)')
                          : c.indiceSelecionado >= 0
                          ? 'Comentário ${c.indiceSelecionado + 1} de $total'
                          : '$total comentário(s)',
                      style: tema.textTheme.bodySmall,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Comentário anterior (↑)',
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: c.temAnterior
                      ? () {
                          _assumirFocoDoPainel();
                          c.anterior();
                        }
                      : null,
                ),
                IconButton(
                  tooltip: 'Próximo comentário (↓)',
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: c.temProximo
                      ? () {
                          _assumirFocoDoPainel();
                          c.proximo();
                        }
                      : null,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: total == 0
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        widget.vazio ??
                            'Nenhum comentário neste documento ainda.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : visiveis.isEmpty
                ? Center(
                    child: TextButton(
                      onPressed: () {
                        _busca.clear();
                        c.definirBusca('');
                      },
                      child: const Text('Limpar a busca'),
                    ),
                  )
                : ListView.builder(
                    controller: _lista,
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                    itemCount: visiveis.length,
                    itemBuilder: (_, i) {
                      final com = visiveis[i];
                      return Padding(
                        key: _chaves.putIfAbsent(com.id, GlobalKey.new),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Cartao(
                          comentario: com,
                          selecionado: c.selecionado == com.id,
                          expandido: c.expandido(com.id),
                          aviso: c.aviso(com.id),
                          numero: widget.comentarios.indexOf(com) + 1,
                          aoTocar: () async {
                            _assumirFocoDoPainel();
                            await c.alternar(com.id);
                            // No celular, depois de escolher, mostra o
                            // documento com o comentário ativo embaixo.
                            if (estreito && c.selecionado == com.id) {
                              c.definirFolhaCompacta(true);
                            }
                          },
                          aoExpandir: () {
                            _assumirFocoDoPainel();
                            c.alternarExpansao(com.id);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Botão para reabrir os comentários.
class _BotaoAbrir extends StatelessWidget {
  const _BotaoAbrir({required this.total, required this.aoAbrir});

  final int total;
  final VoidCallback aoAbrir;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Mostrar os comentários',
    child: FilledButton.tonalIcon(
      onPressed: aoAbrir,
      style: FilledButton.styleFrom(minimumSize: const Size(48, 44)),
      icon: const Icon(Icons.forum_outlined, size: 18),
      label: Text('Comentários ($total)'),
    ),
  );
}

/// Alça para redimensionar o painel (arrastar ou setas ←/→ com foco).
class _Divisor extends StatefulWidget {
  const _Divisor({
    required this.largura,
    required this.minima,
    required this.maxima,
    required this.aoMudar,
  });

  final double largura;
  final double minima;
  final double maxima;
  final ValueChanged<double> aoMudar;

  @override
  State<_Divisor> createState() => _DivisorState();
}

class _DivisorState extends State<_Divisor> {
  bool _foco = false;
  bool _sobre = false;

  void _mudar(double nova) =>
      widget.aoMudar(nova.clamp(widget.minima, widget.maxima).toDouble());

  @override
  Widget build(BuildContext context) {
    final cor = Theme.of(context).colorScheme.primary;
    final destaque = _foco || _sobre;
    return Semantics(
      label: 'Redimensionar o painel de comentários',
      value: '${widget.largura.round()} pixels',
      increasedValue: '${(widget.largura + 24).round()} pixels',
      decreasedValue: '${(widget.largura - 24).round()} pixels',
      onIncrease: () => _mudar(widget.largura + 24),
      onDecrease: () => _mudar(widget.largura - 24),
      child: Focus(
        onFocusChange: (f) => setState(() => _foco = f),
        onKeyEvent: (_, e) {
          if (e is KeyUpEvent) return KeyEventResult.ignored;
          if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _mudar(widget.largura + 24);
            return KeyEventResult.handled;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
            _mudar(widget.largura - 24);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _sobre = true),
          onExit: (_) => setState(() => _sobre = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => _mudar(widget.largura - d.delta.dx),
            child: SizedBox(
              width: 12,
              child: Center(
                child: Container(
                  width: destaque ? 4 : 2,
                  height: 44,
                  decoration: BoxDecoration(
                    color: destaque ? cor : Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) {
    final cor = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.link_off, size: 16, color: cor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(texto, style: TextStyle(color: cor, fontSize: 12.5)),
        ),
      ],
    );
  }
}

/// Cartão de um comentário: recolhido mostra o ponto de atenção; expandido
/// (no próprio painel) mostra as explicações e as ações.
class _Cartao extends StatelessWidget {
  const _Cartao({
    required this.comentario,
    required this.selecionado,
    required this.expandido,
    required this.numero,
    required this.aoTocar,
    required this.aoExpandir,
    this.aviso,
  });

  final ComentarioDocumento comentario;
  final bool selecionado;
  final bool expandido;
  final int numero;
  final String? aviso;
  final VoidCallback aoTocar;
  final VoidCallback aoExpandir;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final c = comentario;
    final primaria = tema.colorScheme.primary;
    return Semantics(
      button: true,
      selected: selecionado,
      expanded: expandido,
      label: 'Comentário $numero${c.local.isEmpty ? '' : ', ${c.local}'}',
      child: Material(
        color: selecionado
            ? tema.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : tema.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selecionado ? primaria : tema.dividerColor,
            width: selecionado ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: aoTocar,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: c.cor, width: 6)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _cabecalho(tema),
                        const SizedBox(height: 4),
                        Text(
                          c.titulo.trim().isEmpty
                              ? '(comentário sem texto)'
                              : c.titulo.trim(),
                          maxLines: expandido ? null : 3,
                          overflow: expandido ? null : TextOverflow.ellipsis,
                          style: tema.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                        if (aviso != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: _Aviso(aviso!),
                          )
                        else if (!c.ancorado)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: _Aviso(
                              'Sem trecho correspondente no documento.',
                            ),
                          ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 150),
                          alignment: Alignment.topCenter,
                          child: expandido
                              ? _detalhes(tema)
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cabecalho(ThemeData tema) {
    final c = comentario;
    return Row(
      children: [
        if (selecionado) ...[
          Icon(Icons.my_location, size: 15, color: tema.colorScheme.primary),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Wrap(
            spacing: 4,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '#$numero',
                style: tema.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              for (final e in c.etiquetas)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: tema.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(e, style: tema.textTheme.labelSmall),
                ),
              if (c.local.isNotEmpty)
                Text(c.local, style: tema.textTheme.labelSmall),
            ],
          ),
        ),
        IconButton(
          tooltip: expandido ? 'Recolher' : 'Expandir',
          visualDensity: VisualDensity.compact,
          icon: Icon(expandido ? Icons.expand_less : Icons.expand_more),
          onPressed: aoExpandir,
        ),
      ],
    );
  }

  Widget _detalhes(ThemeData tema) {
    final c = comentario;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in c.secoes)
            if (s.texto.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      s.icone ?? Icons.notes_rounded,
                      size: 17,
                      color: tema.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.rotulo,
                            style: tema.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            s.texto.trim(),
                            style: tema.textTheme.bodyMedium?.copyWith(
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          if (c.acoes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final a in c.acoes)
                  TextButton.icon(
                    onPressed: a.aoAcionar,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 40),
                      foregroundColor: a.destrutiva
                          ? tema.colorScheme.error
                          : null,
                    ),
                    icon: Icon(a.icone, size: 18),
                    label: Text(a.rotulo),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
