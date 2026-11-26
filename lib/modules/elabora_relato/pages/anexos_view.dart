import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/marcacao_anexo_dialog.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado_controller.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/marca_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/superficie_pdf.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/superficie_texto.dart';

/// Aba "Documentos do processo": o relator anexa arquivos do processo
/// (PDF com texto, DOCX, TXT/MD, HTML) para LER — o texto não é editado —,
/// marca trechos com cores, pergunta à IA o que eles dizem e guarda
/// comentários. Usa a camada de comentários comum da plataforma
/// ([LeitorComentado], [SuperficiePdf], [SuperficieTexto]).
class AnexosView extends StatefulWidget {
  const AnexosView({required this.service, super.key});

  final ParecerService service;

  @override
  State<AnexosView> createState() => _AnexosViewState();
}

class _AnexosViewState extends State<AnexosView> {
  final _busca = TextEditingController();
  final _leitor = LeitorComentadoController();
  final _pdf = SuperficiePdfController();
  final _texto = SuperficieTextoController();
  final _selTexto = ValueNotifier<SelecaoTexto?>(null);
  final _selPdf = ValueNotifier<SelecaoPdf?>(null);

  String? _anexoId;
  List<ParagrafoFonte> _pars = const [];
  List<String> _paginasPdf = const [];
  bool _lendo = false;
  bool _anexando = false;
  bool _modoTexto = false;
  String? _erroLeitura;
  String _corPadrao = 'amarelo';
  String _pasta = '';
  int _escalaPct = 100;

  AnexosProcessoService get anexos => widget.service.anexos;
  AnexoProcesso? get _anexo =>
      anexos.anexos.where((a) => a.id == _anexoId).firstOrNull;

  /// O anexo aberto é PDF e está na visão "PDF original".
  bool get _emPdf => _anexo?.extensao == '.pdf' && !_modoTexto;

  @override
  void initState() {
    super.initState();
    _leitor
      ..navegar = _navegar
      ..aoLimpar = () {
        if (mounted) setState(() {});
      };
    anexos.pasta().then((p) {
      if (mounted) setState(() => _pasta = p);
    });
    anexos.addListener(_mudou);
    anexos.carregar().then((_) {
      if (mounted && _anexoId == null && anexos.anexos.isNotEmpty) {
        _selecionarAnexo(anexos.anexos.first.id);
      }
    });
  }

  @override
  void dispose() {
    anexos.removeListener(_mudou);
    _busca.dispose();
    _leitor.dispose();
    _selTexto.dispose();
    _selPdf.dispose();
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

  // ------------------------------------------------------------- anexos

  Future<void> _selecionarAnexo(String id) async {
    _leitor.limparSelecao();
    setState(() {
      _anexoId = id;
      _pars = const [];
      _paginasPdf = const [];
      _erroLeitura = null;
      _lendo = true;
      _modoTexto = false;
    });
    _selTexto.value = null;
    _selPdf.value = null;
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
    if (ultimo != null) await _selecionarAnexo(ultimo.id);
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

  // --------------------------------------------- marcações e comentários

  MarcaDocumento _marca(MarcacaoAnexo m) => MarcaDocumento(
    id: m.id,
    cor: Color(coresMarcacao[m.cor] ?? coresMarcacao['amarelo']!),
    comentada: m.comentario.isNotEmpty,
    paragrafo: m.paragrafo,
    inicio: m.inicio,
    fim: m.fim,
    pdfPagina: m.pdfPagina,
    pdfInicio: m.pdfInicio,
    pdfFim: m.pdfFim,
  );

  /// Leva o documento aberto (PDF ou texto) ao trecho do comentário.
  Future<bool> _navegar(ComentarioDocumento c, bool rolar) async {
    if (mounted) setState(() {});
    final m = _anexo?.marcacoes.where((x) => x.id == c.id).firstOrNull;
    if (m == null) return false;
    final marca = _marca(m);
    if (_emPdf) {
      if (!marca.noPdf) return false;
      return rolar ? _pdf.irPara(marca) : true;
    }
    if (!marca.noTexto) return false;
    return rolar ? _texto.irPara(marca) : true;
  }

  /// Comentário (cartão do painel) de uma marcação.
  ComentarioDocumento _comentario(AnexoProcesso a, MarcacaoAnexo m) {
    return ComentarioDocumento(
      id: m.id,
      titulo: m.comentario.isNotEmpty
          ? m.comentario
          : 'Trecho marcado, ainda sem comentário. Use "Comentar e perguntar '
                'à IA" para registrar o que observar.',
      cor: Color(coresMarcacao[m.cor] ?? coresMarcacao['amarelo']!),
      local: AnexosProcessoService.localMarcacao(m, _pars),
      ancorado: _emPdf ? m.pdfPagina > 0 : m.paragrafo >= 0,
      trechoMarcado: m.texto,
      secoes: [
        if (m.pergunta.isNotEmpty)
          SecaoComentario(
            'Pergunta feita à IA',
            m.pergunta,
            icone: Icons.help_outline,
          ),
        if (m.explicacaoIa.isNotEmpty)
          SecaoComentario(
            'O que a IA explicou',
            m.explicacaoIa,
            icone: Icons.auto_awesome_outlined,
          ),
      ],
      acoes: [
        AcaoComentario(
          rotulo: m.comentario.isEmpty
              ? 'Comentar e perguntar à IA'
              : 'Editar e perguntar à IA',
          icone: Icons.edit_note,
          aoAcionar: () => _editarMarcacao(m),
        ),
        AcaoComentario(
          rotulo: 'Cor',
          icone: Icons.palette_outlined,
          aoAcionar: () => _mudarCor(a, m),
        ),
        AcaoComentario(
          rotulo: 'Copiar trecho',
          icone: Icons.copy,
          aoAcionar: () => Clipboard.setData(
            ClipboardData(
              text:
                  '“${m.texto.trim()}” (${a.nome}, '
                  '${AnexosProcessoService.localMarcacao(m, _pars)})',
            ),
          ),
        ),
        AcaoComentario(
          rotulo: 'Citar no parecer',
          icone: Icons.format_quote,
          aoAcionar: () => _citar(a, m),
        ),
        AcaoComentario(
          rotulo: 'Excluir',
          icone: Icons.delete_outline,
          destrutiva: true,
          aoAcionar: () => anexos.excluirMarcacao(a.id, m.id),
        ),
      ],
    );
  }

  /// Cria a marcação da seleção atual (PDF ou texto).
  Future<void> _marcar(AcaoTrecho acao) async {
    final a = _anexo;
    if (a == null) return;
    MarcacaoAnexo? m;
    if (_emPdf) {
      final s = _selPdf.value;
      if (s != null && s.pagina >= 1 && s.pagina <= _paginasPdf.length) {
        m = AnexosProcessoService.novaMarcacaoPdf(
          pagina: s.pagina,
          textoPagina: _paginasPdf[s.pagina - 1],
          inicio: s.inicio,
          fim: s.fim,
          pars: _pars,
          cor: _corPadrao,
        );
      }
      _selPdf.value = null;
    } else {
      final s = _selTexto.value;
      if (s != null && s.fim > s.inicio && s.paragrafo < _pars.length) {
        var nova = AnexosProcessoService.novaMarcacao(
          paragrafo: s.paragrafo,
          textoParagrafo: _pars[s.paragrafo].texto,
          inicio: s.inicio,
          fim: s.fim,
          cor: _corPadrao,
        );
        if (_paginasPdf.isNotEmpty) {
          nova =
              AnexosProcessoService.ancorarNoPdf(nova, _paginasPdf, _pars) ??
              nova;
        }
        m = nova;
      }
      _selTexto.value = null;
    }
    if (m == null) return;
    if (acao == AcaoTrecho.marcar) {
      await anexos.salvarMarcacao(a.id, m);
      await _leitor.selecionar(m.id, rolar: false);
      return;
    }
    await _editarMarcacao(m, perguntar: acao == AcaoTrecho.perguntar);
  }

  /// Comentário e perguntas à IA (diálogo de edição; ver/navegar não abre
  /// diálogo: é feito no próprio painel).
  Future<void> _editarMarcacao(
    MarcacaoAnexo m, {
    bool perguntar = false,
  }) async {
    final a = _anexo;
    if (a == null) return;
    final ctx = m.pdfPagina > 0 && _paginasPdf.isNotEmpty
        ? AnexosProcessoService.contextoPdf(
            _paginasPdf,
            m.pdfPagina,
            m.pdfInicio,
            m.pdfFim,
          )
        : AnexosProcessoService.contexto(_pars, m.paragrafo);
    final r = await showDialog<MarcacaoAnexo>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MarcacaoAnexoDialog(
        service: widget.service,
        documento: a.nome,
        local: AnexosProcessoService.localMarcacao(m, _pars),
        marcacao: m,
        antes: ctx.antes,
        depois: ctx.depois,
        perguntarAoAbrir: perguntar,
      ),
    );
    if (r == null) return;
    await anexos.salvarMarcacao(a.id, r);
    await _leitor.selecionar(r.id, rolar: false);
  }

  Future<void> _mudarCor(AnexoProcesso a, MarcacaoAnexo m) async {
    final cor = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Cor da marcação'),
        children: [
          for (final e in coresMarcacao.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.key),
              child: Row(
                children: [
                  CircleAvatar(radius: 10, backgroundColor: Color(e.value)),
                  const SizedBox(width: 10),
                  Text(e.key),
                  if (e.key == m.cor) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.check, size: 16),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (cor != null) await anexos.salvarMarcacao(a.id, m.copyWith(cor: cor));
  }

  Future<void> _citar(AnexoProcesso a, MarcacaoAnexo m) async {
    final secao = await showDialog<ParecerSecao>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Citar o trecho em qual seção?'),
        children: [
          for (final s in ParecerSecao.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text(s.titulo),
            ),
        ],
      ),
    );
    if (secao == null) return;
    String esc(String t) => t
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final local = AnexosProcessoService.localMarcacao(m, _pars);
    widget.service.inserirNoEditor(
      secao,
      '<p class="Citacao">“${esc(m.texto.trim())}” (${esc(a.nome)}, '
      '${esc(local)})</p>',
    );
    _mensagem('Citação inserida em ${secao.titulo}.');
  }

  /// Páginas do PDF lidas: guarda o texto e ancora no PDF as marcações
  /// feitas na visão "Texto" (ou pelo agente).
  Future<void> _aoLerPaginas(List<String> paginas) async {
    final a = _anexo;
    if (a == null) return;
    setState(() => _paginasPdf = paginas);
    final novas = <MarcacaoAnexo>[];
    var naoAchadas = 0;
    for (final m in a.marcacoes) {
      if (m.pdfPagina > 0) continue;
      final r = AnexosProcessoService.ancorarNoPdf(m, paginas, _pars);
      if (r == null) {
        naoAchadas++;
      } else {
        novas.add(r);
      }
    }
    await anexos.atualizarMarcacoes(a.id, novas);
    if (naoAchadas > 0) {
      _mensagem(
        '$naoAchadas marcação(ões) não foram localizadas no PDF; aparecem só '
        'na visão "Texto".',
      );
    }
    // Comentário já selecionado: leva o PDF até ele.
    final sel = _leitor.selecionado;
    if (sel != null) await _leitor.selecionar(sel);
  }

  void _buscarNoDocumento({bool proxima = true}) {
    final termo = _busca.text.trim();
    if (termo.isEmpty) return;
    if (_emPdf) {
      _pdf.buscar(termo, proxima: proxima);
    } else if (!_texto.buscar(termo, proxima: proxima)) {
      _mensagem('"$termo" não aparece no documento.');
    }
  }

  void _trocarVisao(bool texto) {
    setState(() {
      _modoTexto = texto;
      _selTexto.value = null;
      _selPdf.value = null;
    });
    final sel = _leitor.selecionado;
    if (sel != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _leitor.selecionar(sel),
      );
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final largo = c.maxWidth >= 1150;
        final leitor = _leitorDoAnexo();
        if (!largo) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _seletorCompacto(),
              const SizedBox(height: 8),
              Expanded(child: leitor),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 240, child: _listaAnexos()),
            const SizedBox(width: 12),
            Expanded(child: leitor),
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
          onChanged: (id) => id == null ? null : _selecionarAnexo(id),
        ),
      ),
      const SizedBox(width: 8),
      _botaoAnexar(),
    ],
  );

  Widget _listaAnexos() => Container(
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
            'Documentos do processo',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
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
                            '${a.marcacoes.length} comentário(s)',
                            if (a.aviso.isNotEmpty) '⚠',
                          ].join(' · '),
                        ),
                        onTap: () => _selecionarAnexo(a.id),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Ações do documento',
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'abrir',
                              child: Text('Abrir original'),
                            ),
                            PopupMenuItem(
                              value: 'renomear',
                              child: Text('Renomear'),
                            ),
                            PopupMenuItem(
                              value: 'remover',
                              child: Text('Remover'),
                            ),
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
        ),
        Padding(padding: const EdgeInsets.all(10), child: _botaoAnexar()),
      ],
    ),
  );

  static IconData _icone(String ext) => switch (ext) {
    '.pdf' => Icons.picture_as_pdf_outlined,
    '.docx' => Icons.description_outlined,
    '.html' || '.htm' => Icons.language,
    _ => Icons.article_outlined,
  };

  Widget _leitorDoAnexo() {
    final a = _anexo;
    if (a == null) {
      return Center(
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
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _barraDocumento(a),
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
          child: LeitorComentado(
            controller: _leitor,
            comentarios: [for (final m in a.marcacoes) _comentario(a, m)],
            vazio:
                'Selecione um trecho do documento e use "Marcar", "Comentar" '
                'ou "Perguntar à IA" (também pelo botão direito).',
            documento: _folha(a),
          ),
        ),
      ],
    );
  }

  Widget _barraDocumento(AnexoProcesso a) => Wrap(
    spacing: 8,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Text(
          a.nome,
          style: const TextStyle(fontWeight: FontWeight.w700),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (a.extensao == '.pdf')
        SegmentedButton<bool>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.picture_as_pdf_outlined, size: 17),
              label: Text('PDF original'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.notes_rounded, size: 17),
              label: Text('Texto'),
            ),
          ],
          selected: {_modoTexto},
          onSelectionChanged: (s) => _trocarVisao(s.first),
        ),
      if (_emPdf) ...[
        IconButton(
          tooltip: 'Diminuir o zoom',
          onPressed: () => _pdf.zoom('-'),
          icon: const Icon(Icons.zoom_out),
        ),
        Text('$_escalaPct%', style: const TextStyle(fontSize: 12)),
        IconButton(
          tooltip: 'Aumentar o zoom (ou Ctrl + roda do mouse)',
          onPressed: () => _pdf.zoom('+'),
          icon: const Icon(Icons.zoom_in),
        ),
        IconButton(
          tooltip: 'Ajustar à largura',
          onPressed: () => _pdf.zoom('largura'),
          icon: const Icon(Icons.fit_screen_outlined),
        ),
      ],
      SizedBox(
        width: 230,
        child: TextField(
          controller: _busca,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Buscar no documento',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: IconButton(
              tooltip: 'Ocorrência anterior',
              icon: const Icon(Icons.keyboard_arrow_up, size: 18),
              onPressed: () => _buscarNoDocumento(proxima: false),
            ),
          ),
          onSubmitted: (_) => _buscarNoDocumento(),
        ),
      ),
      IconButton(
        tooltip: 'Abrir o arquivo original',
        onPressed: () => _abrirOriginal(a),
        icon: const Icon(Icons.open_in_new),
      ),
    ],
  );

  Widget _barraSelecao() => ListenableBuilder(
    listenable: Listenable.merge([_selTexto, _selPdf]),
    builder: (context, _) {
      final ativo = _emPdf ? _selPdf.value != null : _selTexto.value != null;
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final e in coresMarcacao.entries)
            Tooltip(
              message: 'Cor das novas marcações: ${e.key}',
              child: InkResponse(
                onTap: () => setState(() => _corPadrao = e.key),
                radius: 18,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: CircleAvatar(
                    radius: 10,
                    backgroundColor: Color(e.value),
                    child: _corPadrao == e.key
                        ? const Icon(
                            Icons.check,
                            size: 12,
                            color: Colors.black87,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: ativo ? () => _marcar(AcaoTrecho.marcar) : null,
            icon: const Icon(Icons.border_color_outlined, size: 18),
            label: const Text('Marcar'),
          ),
          OutlinedButton.icon(
            onPressed: ativo ? () => _marcar(AcaoTrecho.comentar) : null,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text('Comentar'),
          ),
          FilledButton.tonalIcon(
            onPressed: ativo ? () => _marcar(AcaoTrecho.perguntar) : null,
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

  /// O documento em folha branca: PDF original ou texto.
  Widget _folha(AnexoProcesso a) {
    final marcas = [for (final m in a.marcacoes) _marca(m)];
    final Widget conteudo;
    if (_emPdf) {
      conteudo = _pasta.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SuperficiePdf(
              key: ValueKey('pdf-${a.id}'),
              pasta: _pasta,
              arquivo: a.arquivoGuardado,
              marcas: marcas,
              selecionada: _leitor.selecionado,
              controller: _pdf,
              aoLerPaginas: _aoLerPaginas,
              aoSelecionar: (s) => _selPdf.value = s,
              aoPedirAcao: (acao, s) {
                _selPdf.value = s;
                _marcar(acao);
              },
              aoTocarMarca: (id) => _leitor.selecionar(id, rolar: false),
              aoBuscar: (achou, _) {
                if (!achou) {
                  _mensagem(
                    '"${_busca.text.trim()}" não aparece no documento.',
                  );
                }
              },
              aoMudarEscala: (e) =>
                  setState(() => _escalaPct = (e * 100).round()),
            );
    } else if (_lendo) {
      conteudo = const Center(child: CircularProgressIndicator());
    } else if (_erroLeitura != null) {
      conteudo = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _erroLeitura!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black87),
          ),
        ),
      );
    } else if (_pars.isEmpty) {
      conteudo = const Center(
        child: Text(
          'Sem texto para exibir. Use "Abrir original".',
          style: TextStyle(color: Colors.black87),
        ),
      );
    } else {
      conteudo = SuperficieTexto(
        key: ValueKey('texto-${a.id}'),
        paragrafos: _pars,
        marcas: marcas,
        selecionada: _leitor.selecionado,
        controller: _texto,
        aoSelecionar: (s) => _selTexto.value = s,
        aoPedirAcao: (acao, s) {
          _selTexto.value = s;
          _marcar(acao);
        },
        aoTocarMarca: (id) => _leitor.selecionar(id, rolar: false),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: conteudo,
    );
  }
}
