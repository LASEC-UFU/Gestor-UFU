import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:gestor_ufu/modules/sei/application/sei_arvore_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';

class SeiTreePage extends StatefulWidget {
  const SeiTreePage({required this.service, super.key});

  final SeiArvoreService service;

  @override
  State<SeiTreePage> createState() => _SeiTreePageState();
}

class _SeiTreePageState extends State<SeiTreePage> {
  final _urlController = TextEditingController(
    text: SeiArvoreService.defaultAddress,
  );
  final _documentTableScroll = ScrollController();
  String? _error;
  bool _openingBrowser = false;

  SeiArvoreService get _service => widget.service;
  bool get _extracting => _service.extraindo;
  bool get _browserOpened => _service.conectado;

  @override
  void initState() {
    super.initState();
    _service.addListener(_refresh);
    _service.enderecoSalvo().then((url) {
      if (mounted) _urlController.text = url;
    });
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    _urlController.dispose();
    _documentTableScroll.dispose();
    super.dispose();
  }

  String get _status {
    if (_openingBrowser) return 'Abrindo o Edge…';
    if (_extracting) return 'Consultando documentos do processo';
    if (_browserOpened) return 'Edge conectado';
    return 'Navegador não conectado';
  }

  String _message(Object error) =>
      error is CommandException ? error.message : '$error';

  Future<void> _openBrowser() async {
    setState(() {
      _error = null;
      _openingBrowser = true;
    });
    try {
      await _service.abrir(_urlController.text);
    } catch (error) {
      _service.log('Erro ao abrir o Edge: ${_message(error)}');
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _openingBrowser = false);
    }
  }

  Future<void> _extractTree() async {
    if (!_browserOpened) {
      setState(
        () =>
            _error = 'Abra o Edge pelo aplicativo antes de consultar a árvore.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Extrair árvore do processo?'),
        content: const Text(
          'A consulta lê cada documento para tentar identificar tipo e número, '
          'código SEI, data e um resumo. Confirme que o Edge está no processo correto. '
          'Esses campos são extraídos do texto visível e precisam ser revisados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Consultar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _error = null);
    try {
      await _service.extrair();
    } catch (error) {
      _service.log('Erro na consulta: ${_message(error)}');
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _saveReport() async {
    if (_service.documentos.isEmpty) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Salvar inventário da árvore do processo',
      fileName: 'relatorio_arvore_sei.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (path == null || path.isEmpty) return;
    try {
      await _service.salvarRelatorio(path);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Inventário salvo em $path')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Não foi possível salvar o inventário: $error');
    }
  }

  Future<void> _copyReport() async {
    if (_service.documentos.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _service.relatorio()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Relatório copiado no formato para parecer.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final canExtract = _browserOpened && !_extracting && !_openingBrowser;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(context),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1380),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
                      children: [
                        _buildIntro(),
                        const SizedBox(height: 20),
                        _buildConnectionCard(),
                        const SizedBox(height: 16),
                        _buildQueryCard(canExtract),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _buildErrorBanner(_error!),
                        ],
                        if (_extracting) ...[
                          const SizedBox(height: 16),
                          _buildProgressCard(),
                        ],
                        if (_service.documentos.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          _buildResults(),
                        ],
                        const SizedBox(height: 16),
                        _buildLogPanel(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 28, 8),
    child: ModuleHeader(
      title: 'SEI',
      subtitle: 'Extrair árvore de processo',
      icon: Icons.account_tree_rounded,
      accent: const Color(0xFFFFB454),
      onBack: () => context.go('/'),
      actions: [
        _StatusPill(label: _status, busy: _openingBrowser || _extracting),
      ],
    ),
  );

  Widget _buildIntro() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Extrair Árvore de Processo',
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 29,
          fontWeight: FontWeight.w700,
        ),
      ),
      SizedBox(height: 7),
      Text(
        'Leia os documentos da árvore aberta no SEI e gere uma relação '
        'revisável para apoiar seus relatórios.',
        style: TextStyle(
          color: AppTheme.textSecondary.withAlpha(240),
          fontSize: 13,
          height: 1.5,
        ),
      ),
    ],
  );

  Widget _buildConnectionCard() => _PanelCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeading(
          icon: Icons.language_rounded,
          title: 'Conectar ao SEI',
          subtitle: 'O login permanece manual no Edge.',
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final stack = constraints.maxWidth < 700;
            final address = TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              enabled: !_openingBrowser && !_extracting,
              decoration: const InputDecoration(
                labelText: 'Endereço do SEI',
                hintText: 'https://sei.ufu.br',
                prefixIcon: Icon(Icons.link_rounded),
              ),
              onSubmitted: (_) => _openBrowser(),
            );
            final openButton = FilledButton.icon(
              onPressed: _openingBrowser || _extracting ? null : _openBrowser,
              icon: _openingBrowser
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded),
              label: Text(!_browserOpened ? 'Abrir Edge' : 'Ir para o SEI'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB87524),
                foregroundColor: Colors.white,
                minimumSize: const Size(150, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            );
            if (stack) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [address, const SizedBox(height: 12), openButton],
              );
            }
            return Row(
              children: [
                Expanded(child: address),
                const SizedBox(width: 12),
                openButton,
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        const _HintRow(
          icon: Icons.info_outline_rounded,
          text:
              'Depois de abrir o Edge, entre no SEI e deixe na tela do processo que deseja consultar.',
        ),
      ],
    ),
  );

  Widget _buildQueryCard(bool canExtract) => _PanelCard(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 700;
        final action = FilledButton.icon(
          onPressed: canExtract ? _extractTree : null,
          icon: _extracting
              ? const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.account_tree_rounded),
          label: Text(_extracting ? 'Extraindo…' : 'Extrair árvore'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFFB454),
            foregroundColor: const Color(0xFF241606),
            minimumSize: const Size(190, 50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
        final heading = const _SectionHeading(
          icon: Icons.manage_search_rounded,
          title: 'Extrair árvore do processo',
          subtitle:
              'Percorre as pastas e lê o conteúdo visível de cada documento.',
        );
        if (stack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 16),
              action,
              const SizedBox(height: 12),
              const _HintRow(
                icon: Icons.fact_check_outlined,
                text:
                    'Confira tipo, código, data e resumo antes de usar o inventário.',
              ),
            ],
          );
        }
        return Row(
          children: [
            const Expanded(
              child: _SectionHeading(
                icon: Icons.manage_search_rounded,
                title: 'Extrair árvore do processo',
                subtitle:
                    'Percorre as pastas e lê o conteúdo visível de cada documento.',
              ),
            ),
            const SizedBox(width: 16),
            action,
          ],
        );
      },
    ),
  );

  Widget _buildProgressCard() => _PanelCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.hourglass_top_rounded,
              color: Color(0xFFFFB454),
              size: 19,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _service.total > 0
                    ? 'Documento ${_service.progresso} de ${_service.total}'
                    : 'Preparando a árvore…',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_service.total > 0)
              Text(
                '${((_service.progresso / _service.total) * 100).round()}%',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
          ],
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: _service.total > 0
              ? _service.progresso / _service.total
              : null,
          color: Color(0xFFFFB454),
          backgroundColor: AppTheme.divider,
          borderRadius: BorderRadius.circular(8),
        ),
        if (_service.etapa.isNotEmpty) ...[
          const SizedBox(height: 9),
          Text(
            _service.etapa,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ],
    ),
  );

  Widget _buildResults() => _PanelCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.article_outlined,
                    color: Color(0xFFFFB454),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Documentos encontrados · ${_service.documentos.length}',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _copyReport,
                    icon: const Icon(Icons.copy_rounded, size: 17),
                    label: const Text('Copiar relatório'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFFB454),
                      foregroundColor: const Color(0xFF241606),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _saveReport,
                    icon: const Icon(Icons.download_rounded, size: 17),
                    label: const Text('Exportar .txt'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Container(
          width: double.infinity,
          color: AppTheme.warning.withAlpha(18),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: AppTheme.warning,
                size: 17,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Os campos foram inferidos do texto visível. Revise antes de usar em um parecer.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_service.documentos.isEmpty)
          Padding(
            padding: EdgeInsets.all(22),
            child: Text(
              'A consulta terminou, mas não encontrou documentos na árvore.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.bgDark.withAlpha(150),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.divider),
              ),
              child: SelectableText(
                _service.relatorio(),
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  height: 1.6,
                  fontFamily: 'Consolas',
                ),
              ),
            ),
          ),
          ExpansionTile(
            title: Text(
              'Ver campos identificados por documento',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
            ),
            collapsedIconColor: AppTheme.textSecondary,
            iconColor: AppTheme.textSecondary,
            children: [_buildDocumentTable()],
          ),
        ],
      ],
    ),
  );

  Widget _buildDocumentTable() => LayoutBuilder(
    builder: (context, constraints) => Scrollbar(
      controller: _documentTableScroll,
      thumbVisibility: true,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.horizontal,
      child: SingleChildScrollView(
        controller: _documentTableScroll,
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(AppTheme.bgCardAlt),
            dataRowMinHeight: 56,
            dataRowMaxHeight: 92,
            columnSpacing: 24,
            columns: const [
              DataColumn(label: Text('#')),
              DataColumn(label: Text('Nome na árvore')),
              DataColumn(label: Text('Tipo / número')),
              DataColumn(label: Text('Código SEI')),
              DataColumn(label: Text('Data')),
              DataColumn(label: Text('Resumo')),
            ],
            rows: _service.documentos.map((document) {
              return DataRow(
                cells: [
                  DataCell(Text('${document.ordem}')),
                  DataCell(_LimitedCell(document.nomeArvore, width: 210)),
                  DataCell(_LimitedCell(document.tipoNumero, width: 220)),
                  DataCell(
                    Text(document.codigoSei.isEmpty ? '—' : document.codigoSei),
                  ),
                  DataCell(_LimitedCell(document.data, width: 150)),
                  DataCell(_LimitedCell(document.resumo, width: 320)),
                ],
              );
            }).toList(),
          ),
        ),
      ),
    ),
  );

  Widget _buildErrorBanner(String message) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.danger.withAlpha(24),
      border: Border.all(color: AppTheme.danger.withAlpha(100)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.error_outline_rounded,
          color: AppTheme.danger,
          size: 19,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
          ),
        ),
        IconButton(
          tooltip: 'Fechar',
          onPressed: () => setState(() => _error = null),
          icon: Icon(Icons.close_rounded, size: 17),
          color: AppTheme.textSecondary,
          visualDensity: VisualDensity.compact,
        ),
      ],
    ),
  );

  Widget _buildLogPanel() => ExpansionTile(
    initiallyExpanded: _service.logs.isNotEmpty,
    tilePadding: EdgeInsets.symmetric(horizontal: 18),
    collapsedShape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    backgroundColor: AppTheme.bgSurface.withAlpha(190),
    collapsedBackgroundColor: AppTheme.bgSurface.withAlpha(190),
    iconColor: AppTheme.textSecondary,
    collapsedIconColor: AppTheme.textSecondary,
    title: Text(
      'Registro da consulta',
      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
    ),
    subtitle: Text(
      '${_service.logs.length} mensagens',
      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
    ),
    children: [
      Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 210),
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _service.logs.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              _service.logs[index],
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      gradient: AppTheme.cardGradient,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppTheme.divider),
    ),
    child: child,
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: const Color(0xFFFFB454).withAlpha(25),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, color: const Color(0xFFFFB454), size: 19),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _HintRow extends StatelessWidget {
  const _HintRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: AppTheme.textSecondary, size: 15),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.busy});

  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 300),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: AppTheme.glassDecoration(opacity: 0.06),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          )
        else
          Icon(Icons.circle, color: AppTheme.textSecondary, size: 9),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 10),
          ),
        ),
      ],
    ),
  );
}

class _LimitedCell extends StatelessWidget {
  const _LimitedCell(this.text, {required this.width});

  final String text;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Tooltip(
      message: text,
      child: Text(
        text.isEmpty ? '—' : text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: AppTheme.textPrimary, fontSize: 11),
      ),
    ),
  );
}
