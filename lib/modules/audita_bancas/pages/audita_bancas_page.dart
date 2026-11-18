import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/audita_bancas/application/audita_service.dart';
import 'package:gestor_ufu/modules/audita_bancas/domain/auditoria.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado_controller.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/marca_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/superficie_pdf.dart';

/// Audita Bancas: revisão assistida de TCCs, dissertações e teses em PDF,
/// com a camada de comentários comum da plataforma (o PDF como no original,
/// observações no painel, navegação até o trecho).
class AuditaBancasPage extends StatefulWidget {
  const AuditaBancasPage({required this.service, super.key});

  final AuditaService service;

  @override
  State<AuditaBancasPage> createState() => _AuditaBancasPageState();
}

class _AuditaBancasPageState extends State<AuditaBancasPage> {
  final _criterios = TextEditingController();
  final _leitor = LeitorComentadoController();
  final _pdf = SuperficiePdfController();
  final _selecao = ValueNotifier<SelecaoPdf?>(null);

  String? _docId;
  String _pasta = '';
  List<String> _paginas = const [];
  bool _ocupado = false;
  String _etapa = '';
  String? _aviso;

  AuditaService get service => widget.service;
  DocumentoAuditado? get _doc =>
      _docId == null ? null : service.documento(_docId!);

  @override
  void initState() {
    super.initState();
    _leitor
      ..navegar = _navegar
      ..aoLimpar = () {
        if (mounted) setState(() {});
      };
    service.addListener(_mudou);
    service.pasta().then((p) {
      if (mounted) setState(() => _pasta = p);
    });
    service.carregar();
  }

  @override
  void dispose() {
    service.removeListener(_mudou);
    _criterios.dispose();
    _leitor.dispose();
    _selecao.dispose();
    super.dispose();
  }

  void _mudou() {
    if (mounted) setState(() {});
  }

  void _mensagem(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  // ---------------------------------------------------------- documento

  Future<void> _escolherPdf() async {
    final r = await FilePicker.platform.pickFiles(
      dialogTitle: 'PDF do trabalho para auditar',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final caminho = r?.files.single.path;
    if (caminho == null) return;
    try {
      final d = await service.abrirPdf(caminho);
      _abrir(d.id);
    } catch (e) {
      setState(() => _aviso = e is CommandException ? e.message : '$e');
    }
  }

  void _abrir(String id) {
    _leitor.limparSelecao();
    _selecao.value = null;
    setState(() {
      _docId = id;
      _paginas = const [];
      _aviso = null;
      _criterios.text = service.documento(id)?.criterios ?? '';
    });
  }

  Future<void> _analisar() async {
    final d = _doc;
    if (d == null) return;
    setState(() {
      _ocupado = true;
      _aviso = null;
      _etapa = 'Preparando a análise…';
    });
    try {
      final r = await service.analisar(
        d.id,
        _paginas,
        criterios: _criterios.text,
        progresso: (e) {
          if (mounted) setState(() => _etapa = e);
        },
      );
      if (!mounted) return;
      setState(() {
        _aviso = r.criadas == 0
            ? 'A análise não encontrou observações novas que atendam aos '
                  'critérios informados.'
            : r.naoAncoradas > 0
            ? '${r.criadas} observação(ões) criada(s); ${r.naoAncoradas} não '
                  'puderam ser ligadas a um trecho do PDF.'
            : null;
      });
      if (r.criadas > 0) {
        _mensagem('${r.criadas} observação(ões) criada(s) para revisão.');
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _aviso =
              'Falha na análise: ${e is CommandException ? e.message : e}',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _etapa = '';
        });
      }
    }
  }

  Future<void> _exportarRelatorio() async {
    final d = _doc;
    if (d == null) return;
    try {
      final destino = await service.exportarRelatorio(d.id);
      _mensagem('Relatório salvo em $destino. O PDF original foi preservado.');
    } catch (e) {
      setState(() => _aviso = 'Não foi possível salvar o relatório: $e');
    }
  }

  Future<void> _exportarPdf() async {
    final d = _doc;
    if (d == null) return;
    final aceitas = d.observacoes
        .where((o) => o.revisao == Revisao.aceita)
        .length;
    if (aceitas == 0) {
      setState(
        () => _aviso =
            'Aceite pelo menos uma observação antes de exportar o PDF anotado.',
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exportar PDF anotado'),
        content: Text(
          '$aceitas observação(ões) aceita(s) serão destacadas nas páginas e '
          'descritas em páginas de notas. O PDF original não será alterado. '
          'O arquivo anotado é rasterizado e não mantém a seleção de texto.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _ocupado = true;
      _aviso = null;
    });
    try {
      final destino = await service.exportarPdf(
        d.id,
        progresso: (e) {
          if (mounted) setState(() => _etapa = e);
        },
      );
      _mensagem('PDF anotado salvo em $destino');
    } catch (e) {
      if (mounted) {
        setState(
          () => _aviso =
              'Não foi possível exportar o PDF: '
              '${e is CommandException ? e.message : e}',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _etapa = '';
        });
      }
    }
  }

  /// Texto das páginas lido pelo visualizador: guarda e confere as âncoras
  /// (análises feitas pelo agente usam o texto do Poppler).
  Future<void> _aoLerPaginas(List<String> paginas) async {
    final d = _doc;
    setState(() => _paginas = paginas);
    if (d == null) return;
    final semTrecho = await service.reancorar(d.id, paginas);
    if (semTrecho > 0 && mounted) {
      setState(
        () => _aviso =
            '$semTrecho observação(ões) não puderam ser ligadas a um trecho '
            'do PDF.',
      );
    }
  }

  // ---------------------------------------------------------- observações

  static const _corPendente = Color(0xFFFFD54F);
  static const _corAceita = Color(0xFF81C784);
  static const _corRejeitada = Color(0xFFB0BEC5);

  Color _cor(Observacao o) => switch (o.revisao) {
    Revisao.pendente => _corPendente,
    Revisao.aceita => _corAceita,
    Revisao.rejeitada => _corRejeitada,
  };

  MarcaDocumento _marca(Observacao o) => MarcaDocumento(
    id: o.id,
    cor: _cor(o),
    comentada: true,
    pdfPagina: o.pagina,
    pdfInicio: o.inicio,
    pdfFim: o.fim,
  );

  Future<bool> _navegar(ComentarioDocumento c, bool rolar) async {
    if (mounted) setState(() {});
    final o = _doc?.observacoes.where((x) => x.id == c.id).firstOrNull;
    if (o == null || !o.ancorada) return false;
    return rolar ? _pdf.irPara(_marca(o)) : true;
  }

  ComentarioDocumento _comentario(DocumentoAuditado d, Observacao o) =>
      ComentarioDocumento(
        id: o.id,
        titulo: o.problema.isNotEmpty ? o.problema : '(observação sem texto)',
        cor: _cor(o),
        local: o.ancorada ? 'p. ${o.pagina}' : '',
        ancorado: o.ancorada,
        trechoMarcado: o.trecho,
        etiquetas: [
          if (o.categoria.isNotEmpty) o.categoria,
          o.revisao.rotulo,
          if (o.manual) 'Sua observação',
        ],
        secoes: [
          if (o.importancia.isNotEmpty)
            SecaoComentario(
              'Por que merece atenção',
              o.importancia,
              icone: Icons.priority_high_rounded,
            ),
          if (o.melhoria.isNotEmpty)
            SecaoComentario(
              'Como melhorar',
              o.melhoria,
              icone: Icons.lightbulb_outline,
            ),
        ],
        acoes: [
          if (o.revisao != Revisao.aceita)
            AcaoComentario(
              rotulo: 'Aceitar',
              icone: Icons.check_circle_outline,
              aoAcionar: () =>
                  service.definirRevisao(d.id, o.id, Revisao.aceita),
            ),
          if (o.revisao != Revisao.rejeitada)
            AcaoComentario(
              rotulo: 'Rejeitar',
              icone: Icons.cancel_outlined,
              aoAcionar: () =>
                  service.definirRevisao(d.id, o.id, Revisao.rejeitada),
            ),
          if (o.revisao != Revisao.pendente)
            AcaoComentario(
              rotulo: 'Voltar a pendente',
              icone: Icons.undo,
              aoAcionar: () =>
                  service.definirRevisao(d.id, o.id, Revisao.pendente),
            ),
          AcaoComentario(
            rotulo: 'Editar',
            icone: Icons.edit_outlined,
            aoAcionar: () => _editar(d, o),
          ),
          AcaoComentario(
            rotulo: 'Copiar trecho',
            icone: Icons.copy,
            aoAcionar: () => Clipboard.setData(
              ClipboardData(
                text:
                    '“${o.trecho}” (${d.nome}'
                    '${o.ancorada ? ', p. ${o.pagina}' : ''})',
              ),
            ),
          ),
          AcaoComentario(
            rotulo: 'Excluir',
            icone: Icons.delete_outline,
            destrutiva: true,
            aoAcionar: () => service.excluirObservacao(d.id, o.id),
          ),
        ],
      );

  /// Observação escrita pelo usuário sobre o trecho selecionado no PDF.
  Future<void> _novaObservacao() async {
    final d = _doc, s = _selecao.value;
    if (d == null || s == null || s.pagina > _paginas.length) return;
    final o = AuditaService.novaObservacao(
      pagina: s.pagina,
      textoPagina: _paginas[s.pagina - 1],
      inicio: s.inicio,
      fim: s.fim,
    );
    _selecao.value = null;
    await _editar(d, o, nova: true);
  }

  Future<void> _editar(
    DocumentoAuditado d,
    Observacao o, {
    bool nova = false,
  }) async {
    final problema = TextEditingController(text: o.problema);
    final importancia = TextEditingController(text: o.importancia);
    final melhoria = TextEditingController(text: o.melhoria);
    final categoria = TextEditingController(text: o.categoria);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(nova ? 'Nova observação' : 'Editar observação'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: problema,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'O que precisa de atenção',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: importancia,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Por que merece revisão',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: melhoria,
                  minLines: 1,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Como melhorar'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: categoria,
                  decoration: const InputDecoration(
                    labelText: 'Categoria (opcional)',
                    hintText: 'Editorial, Metodológica, Norma a confirmar…',
                  ),
                ),
              ],
            ),
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
    if (ok == true && problema.text.trim().isNotEmpty) {
      await service.salvarObservacao(
        d.id,
        o.copyWith(
          problema: problema.text.trim(),
          importancia: importancia.text.trim(),
          melhoria: melhoria.text.trim(),
          categoria: categoria.text.trim(),
        ),
      );
      await _leitor.selecionar(o.id, rolar: false);
    }
    problema.dispose();
    importancia.dispose();
    melhoria.dispose();
    categoria.dispose();
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return ModuleScaffold(
      moduleId: 'audita-bancas',
      subtitle: 'Revisão assistida de TCCs, dissertações e teses',
      actions: [
        if (d != null) ...[
          TextButton.icon(
            onPressed: _ocupado ? null : _exportarRelatorio,
            icon: const Icon(Icons.save_alt),
            label: const Text('Exportar relatório'),
          ),
          FilledButton.tonalIcon(
            onPressed: _ocupado ? null : _exportarPdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Exportar PDF anotado'),
          ),
        ],
        FilledButton.icon(
          onPressed: _ocupado ? null : _escolherPdf,
          icon: const Icon(Icons.upload_file),
          label: const Text('Abrir PDF'),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _barra(d),
            if (_ocupado) ...[
              const SizedBox(height: 6),
              const LinearProgressIndicator(),
              if (_etapa.isNotEmpty)
                Text(_etapa, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_aviso != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _aviso!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: d == null ? _inicio() : _leitorDoc(d)),
          ],
        ),
      ),
    );
  }

  Widget _barra(DocumentoAuditado? d) => Wrap(
    spacing: 10,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (service.documentos.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DropdownButton<String>(
            isExpanded: true,
            value: d?.id,
            hint: const Text('Documentos já auditados'),
            items: [
              for (final x in service.documentos)
                DropdownMenuItem(
                  value: x.id,
                  child: Text(
                    '${x.nome} (${x.observacoes.length})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (id) => id == null ? null : _abrir(id),
          ),
        ),
      if (d != null) ...[
        SizedBox(
          width: 420,
          child: TextField(
            controller: _criterios,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Critérios, rubrica ou normas (opcional)',
              hintText: 'Cole orientações da banca ou critérios específicos',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        FilledButton.icon(
          onPressed: _ocupado || _paginas.isEmpty ? null : _analisar,
          icon: const Icon(Icons.manage_search),
          label: Text(
            _paginas.isEmpty ? 'Carregando o PDF…' : 'Analisar com IA',
          ),
        ),
        ValueListenableBuilder<SelecaoPdf?>(
          valueListenable: _selecao,
          builder: (_, s, _) => OutlinedButton.icon(
            onPressed: s == null ? null : _novaObservacao,
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('Observação no trecho selecionado'),
          ),
        ),
      ],
    ],
  );

  Widget _inicio() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.rate_review_outlined,
          size: 52,
          color: AppTheme.textSecondary,
        ),
        const SizedBox(height: 10),
        const Text(
          'Abra o PDF de um TCC, dissertação ou tese. O texto só é enviado ao '
          'modelo de IA quando você clicar em "Analisar com IA".',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _escolherPdf,
          icon: const Icon(Icons.upload_file),
          label: const Text('Abrir PDF'),
        ),
      ],
    ),
  );

  Widget _leitorDoc(DocumentoAuditado d) => LeitorComentado(
    controller: _leitor,
    titulo: 'Observações',
    comentarios: [for (final o in d.observacoes) _comentario(d, o)],
    vazio:
        'Clique em "Analisar com IA" ou selecione um trecho do PDF e use '
        '"Observação no trecho selecionado" (ou o botão direito).',
    documento: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: _pasta.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SuperficiePdf(
              key: ValueKey('audita-${d.id}'),
              pasta: _pasta,
              arquivo: d.arquivo,
              marcas: [for (final o in d.observacoes) _marca(o)],
              selecionada: _leitor.selecionado,
              controller: _pdf,
              aoLerPaginas: _aoLerPaginas,
              aoSelecionar: (s) => _selecao.value = s,
              aoPedirAcao: (_, s) {
                _selecao.value = s;
                _novaObservacao();
              },
              aoTocarMarca: (id) => _leitor.selecionar(id, rolar: false),
            ),
    ),
  );
}
