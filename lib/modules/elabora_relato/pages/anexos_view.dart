import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/marcacao_anexo_dialog.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

/// Seleção atual no documento: parágrafo e posição dentro dele.
typedef _Selecao = ({int par, int ini, int fim});

/// Aba "Documentos do processo": o relator anexa arquivos do processo
/// (PDF com texto, DOCX, TXT/MD, HTML) para LER — o texto não é editado —,
/// marca trechos com cores, pergunta à IA o que eles dizem e guarda
/// comentários (que a IA ajuda a redigir). Uma marcação pode virar citação
/// numa seção do parecer.
class AnexosView extends StatefulWidget {
  const AnexosView({required this.service, super.key});

  final ParecerService service;

  @override
  State<AnexosView> createState() => _AnexosViewState();
}

class _AnexosViewState extends State<AnexosView> {
  final _scroll = ScrollController();
  final _busca = TextEditingController();
  final _selecao = ValueNotifier<_Selecao?>(null);
  final _chaves = <int, GlobalKey>{};

  String? _anexoId;
  List<ParagrafoFonte> _pars = const [];
  bool _lendo = false;
  bool _anexando = false;
  String? _erroLeitura;
  String? _ativa;
  int _ultimaBusca = -1;
  String _corPadrao = 'amarelo';

  AnexosProcessoService get anexos => widget.service.anexos;
  AnexoProcesso? get _anexo =>
      anexos.anexos.where((a) => a.id == _anexoId).firstOrNull;

  @override
  void initState() {
    super.initState();
    anexos.addListener(_mudou);
    anexos.carregar().then((_) {
      if (mounted && _anexoId == null && anexos.anexos.isNotEmpty) {
        _selecionar(anexos.anexos.first.id);
      }
    });
  }

  @override
  void dispose() {
    anexos.removeListener(_mudou);
    _scroll.dispose();
    _busca.dispose();
    _selecao.dispose();
    super.dispose();
  }

  void _mudou() {
    if (!mounted) return;
    if (_anexoId != null && _anexo == null) {
      _anexoId = null;
      _pars = const [];
    }
    setState(() {});
  }

  void _mensagem(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _selecionar(String id) async {
    setState(() {
      _anexoId = id;
      _pars = const [];
      _erroLeitura = null;
      _lendo = true;
      _ativa = null;
      _ultimaBusca = -1;
      _chaves.clear();
    });
    _selecao.value = null;
    try {
      final pars = await anexos.paragrafos(anexos.exigir(id));
      if (mounted && _anexoId == id) setState(() => _pars = pars);
    } catch (e) {
      if (mounted && _anexoId == id) {
        setState(() => _erroLeitura = e is CommandException ? e.message : '$e');
      }
    } finally {
      if (mounted && _anexoId == id) setState(() => _lendo = false);
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _anexar() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: 'Anexar documentos do processo',
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'docx', 'txt', 'md', 'html', 'htm'],
    );
    final caminhos = [
      for (final f in r?.files ?? const <PlatformFile>[])
        if (f.path != null) f.path!,
    ];
    if (caminhos.isEmpty) return;
    setState(() => _anexando = true);
    AnexoProcesso? ultimo;
    final erros = <String>[];
    for (final c in caminhos) {
      try {
        ultimo = await anexos.anexar(c);
        if (ultimo.aviso.isNotEmpty) {
          erros.add('${ultimo.nome}: ${ultimo.aviso}');
        }
      } catch (e) {
        erros.add(
          '${c.split(RegExp(r'[\\/]')).last}: '
          '${e is CommandException ? e.message : e}',
        );
      }
    }
    if (!mounted) return;
    setState(() => _anexando = false);
    if (ultimo != null) await _selecionar(ultimo.id);
    if (erros.isNotEmpty && mounted) {
      // ignore: use_build_context_synchronously
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Avisos ao anexar'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(child: Text(erros.join('\n\n'))),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _abrirOriginal(AnexoProcesso a) async {
    final caminho = await anexos.caminho(a);
    if (!File(caminho).existsSync()) {
      _mensagem('A cópia do arquivo não está neste computador.');
      return;
    }
    await Process.start('explorer.exe', [caminho]);
  }

  Future<void> _renomear(AnexoProcesso a) async {
    final ctrl = TextEditingController(text: a.nome);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renomear documento'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            onSubmitted: (_) => Navigator.pop(ctx, true),
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
    if (ok == true) await anexos.renomear(a.id, ctrl.text);
    ctrl.dispose();
  }

  Future<void> _remover(AnexoProcesso a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover documento'),
        content: Text(
          'Remover "${a.nome}" deste processo? As ${a.marcacoes.length} '
          'marcação(ões) e comentários dele serão apagados. O arquivo '
          'original não é alterado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (ok == true) await anexos.remover(a.id);
  }

  // ------------------------------------------------------------ marcações

  Future<void> _marcar({bool dialogo = false, bool perguntar = false}) async {
    final s = _selecao.value;
    final a = _anexo;
    if (s == null || a == null || s.fim <= s.ini || s.par >= _pars.length) {
      return;
    }
    final m = AnexosProcessoService.novaMarcacao(
      paragrafo: s.par,
      textoParagrafo: _pars[s.par].texto,
      inicio: s.ini,
      fim: s.fim,
      cor: _corPadrao,
    );
    _selecao.value = null;
    if (!dialogo) {
      await anexos.salvarMarcacao(a.id, m);
      setState(() => _ativa = m.id);
      return;
    }
    await _abrirMarcacao(m, nova: true, perguntar: perguntar);
  }

  Future<void> _abrirMarcacao(
    MarcacaoAnexo m, {
    bool nova = false,
    bool perguntar = false,
  }) async {
    final a = _anexo;
    if (a == null) return;
    final ctx = AnexosProcessoService.contexto(_pars, m.paragrafo);
    final r = await showDialog<MarcacaoAnexo>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MarcacaoAnexoDialog(
        service: widget.service,
        documento: a.nome,
        local: AnexosProcessoService.local(_pars, m.paragrafo),
        marcacao: m,
        antes: ctx.antes,
        depois: ctx.depois,
        perguntarAoAbrir: perguntar,
      ),
    );
    if (r == null) return;
    await anexos.salvarMarcacao(a.id, r);
    if (mounted) setState(() => _ativa = r.id);
  }

  Future<void> _citar(MarcacaoAnexo m, ParecerSecao secao) async {
    final a = _anexo;
    if (a == null) return;
    String esc(String t) => t
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final local = AnexosProcessoService.local(_pars, m.paragrafo);
    widget.service.inserirNoEditor(
      secao,
      '<p class="Citacao">“${esc(m.texto.trim())}” (${esc(a.nome)}, '
      '${esc(local)})</p>',
    );
    _mensagem('Citação inserida em ${secao.titulo}.');
  }

  // ------------------------------------------------------- navegação/busca

  Future<void> _irPara(int i) async {
    if (i < 0 || i >= _pars.length || !_scroll.hasClients) return;
    for (var tentativa = 0; tentativa < 5; tentativa++) {
      final ctx = _chaves[i]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.25,
          duration: const Duration(milliseconds: 250),
        );
        return;
      }
      // Fora da área construída: salta para a posição estimada.
      final pos = _scroll.position;
      final alvo = (pos.maxScrollExtent * i / _pars.length).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      _scroll.jumpTo(alvo);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _buscar({bool proxima = true}) {
    final termo = TextoBusca.semAcentos(_busca.text.trim());
    if (termo.isEmpty || _pars.isEmpty) return;
    final n = _pars.length;
    for (var k = 1; k <= n; k++) {
      final i = proxima
          ? (_ultimaBusca + k) % n
          : (_ultimaBusca - k + n * 2) % n;
      if (TextoBusca.semAcentos(_pars[i].texto).contains(termo)) {
        setState(() => _ultimaBusca = i);
        _irPara(i);
        return;
      }
    }
    _mensagem('"${_busca.text.trim()}" não aparece no documento.');
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final largo = c.maxWidth >= 1100;
        final documento = _documento();
        if (!largo) {
          return Column(
            children: [
              _seletorCompacto(),
              const SizedBox(height: 8),
              Expanded(child: documento),
              const SizedBox(height: 8),
              SizedBox(height: 190, child: _painelMarcacoes()),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 250, child: _listaAnexos()),
            const SizedBox(width: 12),
            Expanded(child: documento),
            const SizedBox(width: 12),
            SizedBox(width: 320, child: _painelMarcacoes()),
          ],
        );
      },
    );
  }

  Widget _botaoAnexar() => FilledButton.icon(
    onPressed: _anexando ? null : _anexar,
    icon: _anexando
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.attach_file, size: 18),
    label: Text(_anexando ? 'Lendo…' : 'Anexar documento'),
  );

  Widget _seletorCompacto() => Row(
    children: [
      Expanded(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _anexoId,
          hint: const Text('Nenhum documento anexado'),
          items: [
            for (final a in anexos.anexos)
              DropdownMenuItem(value: a.id, child: Text(a.nome)),
          ],
          onChanged: (id) => id == null ? null : _selecionar(id),
        ),
      ),
      const SizedBox(width: 8),
      _botaoAnexar(),
    ],
  );

  Widget _listaAnexos() => _Painel(
    titulo: 'Documentos do processo',
    rodape: _botaoAnexar(),
    child: anexos.anexos.isEmpty
        ? const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Anexe ofícios, pareceres, PPCs, atas… para ler, marcar e '
              'comentar com a ajuda da IA. O arquivo não é alterado.',
              textAlign: TextAlign.center,
            ),
          )
        : ListView(
            children: [
              for (final a in anexos.anexos)
                ListTile(
                  dense: true,
                  selected: a.id == _anexoId,
                  leading: Icon(_icone(a.extensao), size: 20),
                  title: Text(
                    a.nome,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    [
                      if (a.paginas > 0) '${a.paginas} p.',
                      '${a.marcacoes.length} marcação(ões)',
                      if (a.aviso.isNotEmpty) '⚠',
                    ].join(' · '),
                  ),
                  onTap: () => _selecionar(a.id),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Ações',
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'abrir',
                        child: Text('Abrir original'),
                      ),
                      PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                      PopupMenuItem(value: 'remover', child: Text('Remover')),
                    ],
                    onSelected: (v) => switch (v) {
                      'abrir' => _abrirOriginal(a),
                      'renomear' => _renomear(a),
                      _ => _remover(a),
                    },
                  ),
                ),
            ],
          ),
  );

  static IconData _icone(String ext) => switch (ext) {
    '.pdf' => Icons.picture_as_pdf_outlined,
    '.docx' => Icons.description_outlined,
    '.html' || '.htm' => Icons.language,
    _ => Icons.article_outlined,
  };

  Widget _documento() {
    final a = _anexo;
    if (a == null) {
      return _Painel(
        titulo: 'Leitura',
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: 48,
                color: AppTheme.textSecondary,
              ),
              const SizedBox(height: 10),
              const Text(
                'Anexe um documento do processo para ler, marcar trechos e '
                'perguntar à IA.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              _botaoAnexar(),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                a.nome,
                style: const TextStyle(fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: 240,
              child: TextField(
                controller: _busca,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Buscar no documento',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: IconButton(
                    tooltip: 'Anterior',
                    icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                    onPressed: () => _buscar(proxima: false),
                  ),
                ),
                onSubmitted: (_) => _buscar(),
              ),
            ),
            IconButton(
              tooltip: 'Abrir o arquivo original',
              onPressed: () => _abrirOriginal(a),
              icon: const Icon(Icons.open_in_new),
            ),
          ],
        ),
        if (a.aviso.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              a.aviso,
              style: TextStyle(color: AppTheme.warning, fontSize: 12),
            ),
          ),
        const SizedBox(height: 6),
        _barraSelecao(),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.divider),
            ),
            child: _lendo
                ? const Center(child: CircularProgressIndicator())
                : _erroLeitura != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        _erroLeitura!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black87),
                      ),
                    ),
                  )
                : _pars.isEmpty
                ? const Center(
                    child: Text(
                      'Sem texto para exibir. Use "Abrir original".',
                      style: TextStyle(color: Colors.black87),
                    ),
                  )
                : Scrollbar(
                    controller: _scroll,
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(28, 18, 28, 40),
                      itemCount: _pars.length,
                      itemBuilder: (_, i) => _paragrafo(i, a),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _barraSelecao() => ValueListenableBuilder<_Selecao?>(
    valueListenable: _selecao,
    builder: (context, s, _) {
      final ativo = s != null && s.fim > s.ini;
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final e in coresMarcacao.entries)
            InkWell(
              onTap: () => setState(() => _corPadrao = e.key),
              customBorder: const CircleBorder(),
              child: Tooltip(
                message: 'Cor das novas marcações: ${e.key}',
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: Color(e.value),
                  child: _corPadrao == e.key
                      ? const Icon(Icons.check, size: 12, color: Colors.black87)
                      : null,
                ),
              ),
            ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            onPressed: ativo ? () => _marcar() : null,
            icon: const Icon(Icons.border_color_outlined, size: 18),
            label: const Text('Marcar'),
          ),
          OutlinedButton.icon(
            onPressed: ativo ? () => _marcar(dialogo: true) : null,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text('Comentar'),
          ),
          FilledButton.tonalIcon(
            onPressed: ativo
                ? () => _marcar(dialogo: true, perguntar: true)
                : null,
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: const Text('Perguntar à IA'),
          ),
          if (!ativo)
            Text(
              'Selecione um trecho (ou use o botão direito sobre ele).',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
        ],
      );
    },
  );

  Widget _paragrafo(int i, AnexoProcesso a) {
    final par = _pars[i];
    final marcacoes = [
      for (final m in a.marcacoes)
        if (m.paragrafo == i) m,
    ];
    final novaPagina =
        par.pagina > 0 && (i == 0 || _pars[i - 1].pagina != par.pagina);
    final base = TextStyle(
      color: const Color(0xFF1D2230),
      fontSize: par.titulo ? 15 : 14,
      height: 1.5,
      fontWeight: par.titulo ? FontWeight.w700 : FontWeight.w400,
    );
    final destaque = _ultimaBusca == i;
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
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          color: destaque ? const Color(0x1A1F6FD1) : null,
          child: SelectableText.rich(
            TextSpan(
              style: base,
              children: [
                for (final s in segmentarParagrafo(par.texto, marcacoes))
                  TextSpan(
                    text: s.texto,
                    style: s.marcacao == null
                        ? null
                        : TextStyle(
                            backgroundColor: Color(
                              coresMarcacao[s.marcacao!.cor]!,
                            ).withAlpha(s.marcacao!.id == _ativa ? 255 : 150),
                            decoration: s.marcacao!.comentario.isEmpty
                                ? null
                                : TextDecoration.underline,
                            decorationStyle: TextDecorationStyle.dotted,
                          ),
                  ),
              ],
            ),
            onSelectionChanged: (sel, _) => _aoSelecionar(i, sel, marcacoes),
            contextMenuBuilder: (context, state) =>
                _menu(context, state, i, marcacoes),
          ),
        ),
      ],
    );
  }

  void _aoSelecionar(int i, TextSelection sel, List<MarcacaoAnexo> marcacoes) {
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      final m = marcacoes
          .where((x) => sel.baseOffset >= x.inicio && sel.baseOffset < x.fim)
          .lastOrNull;
      if (m != null && m.id != _ativa) setState(() => _ativa = m.id);
      return;
    }
    _selecao.value = (par: i, ini: sel.start, fim: sel.end);
  }

  Widget _menu(
    BuildContext context,
    EditableTextState state,
    int i,
    List<MarcacaoAnexo> marcacoes,
  ) {
    final sel = state.textEditingValue.selection;
    final temSelecao = sel.isValid && !sel.isCollapsed;
    final sobre = sel.isValid
        ? marcacoes
              .where((x) => sel.start < x.fim && sel.end > x.inicio)
              .lastOrNull
        : null;
    void fechar() => state.hideToolbar();
    final itens = <ContextMenuButtonItem>[
      if (temSelecao) ...[
        ContextMenuButtonItem(
          label: 'Marcar',
          onPressed: () {
            fechar();
            _selecao.value = (par: i, ini: sel.start, fim: sel.end);
            _marcar();
          },
        ),
        ContextMenuButtonItem(
          label: 'Comentar…',
          onPressed: () {
            fechar();
            _selecao.value = (par: i, ini: sel.start, fim: sel.end);
            _marcar(dialogo: true);
          },
        ),
        ContextMenuButtonItem(
          label: 'Perguntar à IA…',
          onPressed: () {
            fechar();
            _selecao.value = (par: i, ini: sel.start, fim: sel.end);
            _marcar(dialogo: true, perguntar: true);
          },
        ),
      ],
      if (sobre != null)
        ContextMenuButtonItem(
          label: 'Abrir marcação',
          onPressed: () {
            fechar();
            _abrirMarcacao(sobre);
          },
        ),
      ...state.contextMenuButtonItems,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: itens,
    );
  }

  Widget _painelMarcacoes() {
    final a = _anexo;
    final ms = a?.marcacoes ?? const <MarcacaoAnexo>[];
    return _Painel(
      titulo: 'Marcações e comentários (${ms.length})',
      child: ms.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Selecione um trecho do documento e use "Marcar", '
                '"Comentar" ou "Perguntar à IA".',
                textAlign: TextAlign.center,
              ),
            )
          : ListView(
              children: [
                for (final m in ms)
                  Card(
                    margin: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    color: m.id == _ativa
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    child: InkWell(
                      onTap: () {
                        setState(() => _ativa = m.id);
                        _irPara(m.paragrafo);
                      },
                      onDoubleTap: () => _abrirMarcacao(m),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 5,
                              height: 44,
                              color: Color(coresMarcacao[m.cor]!),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: _resumoMarcacao(m)),
                            _menuMarcacao(m),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _resumoMarcacao(MarcacaoAnexo m) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '“${m.texto.trim()}”',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 12.5),
      ),
      if (m.comentario.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            m.comentario,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          [
            AnexosProcessoService.local(_pars, m.paragrafo),
            if (m.explicacaoIa.isNotEmpty) 'explicação da IA',
          ].join(' · '),
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),
      ),
    ],
  );

  Widget _menuMarcacao(MarcacaoAnexo m) => PopupMenuButton<String>(
    tooltip: 'Ações',
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'abrir', child: Text('Comentário e IA…')),
      const PopupMenuItem(value: 'copiar', child: Text('Copiar trecho')),
      for (final s in ParecerSecao.values)
        PopupMenuItem(
          value: 'citar:${s.id}',
          child: Text('Citar em ${s.titulo}'),
        ),
      const PopupMenuItem(value: 'excluir', child: Text('Excluir marcação')),
    ],
    onSelected: (v) async {
      final a = _anexo;
      if (a == null) return;
      if (v == 'abrir') {
        await _abrirMarcacao(m);
      } else if (v == 'copiar') {
        await Clipboard.setData(
          ClipboardData(
            text:
                '“${m.texto.trim()}” (${a.nome}, '
                '${AnexosProcessoService.local(_pars, m.paragrafo)})',
          ),
        );
      } else if (v.startsWith('citar:')) {
        final secao = ParecerSecao.porId(v.substring(6));
        if (secao != null) await _citar(m, secao);
      } else if (v == 'excluir') {
        await anexos.excluirMarcacao(a.id, m.id);
      }
    },
  );
}

/// Painel com título (e rodapé opcional) usado nas colunas da aba.
class _Painel extends StatelessWidget {
  const _Painel({required this.titulo, required this.child, this.rodape});

  final String titulo;
  final Widget child;
  final Widget? rodape;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: AppTheme.cardGradient,
      border: Border.all(color: AppTheme.divider),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Text(
            titulo,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
        if (rodape != null)
          Padding(padding: const EdgeInsets.all(10), child: rodape),
      ],
    ),
  );
}
