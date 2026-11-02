import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:config_moodle/presentation/controllers/theme_controller.dart';
import 'package:config_moodle/presentation/widgets/common_widgets.dart';

class SeiTreePage extends StatefulWidget {
  const SeiTreePage({super.key});

  @override
  State<SeiTreePage> createState() => _SeiTreePageState();
}

class _SeiTreePageState extends State<SeiTreePage> {
  static const _addressKey = 'sei_tree_address_url';
  final _urlController = TextEditingController(text: 'https://sei.ufu.br');
  final _documentTableScroll = ScrollController();
  final List<_SeiDocument> _documents = [];
  final List<String> _logs = [];
  Process? _bridge;
  StreamSubscription<String>? _stdoutSubscription;
  String _status = 'Navegador não conectado';
  String? _error;
  String _progressLabel = '';
  int _progress = 0;
  int _progressTotal = 0;
  bool _openingBrowser = false;
  bool _browserReady = false;
  bool _extracting = false;

  bool get _browserOpened => _bridge != null && _browserReady;

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_addressKey);
    if (mounted && saved != null && saved.trim().isNotEmpty) {
      _urlController.text = saved;
    }
  }

  Future<void> _saveAddress(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_addressKey, value.trim());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _documentTableScroll.dispose();
    _stdoutSubscription?.cancel();
    final process = _bridge;
    if (process != null) {
      try {
        process.stdin.writeln(jsonEncode({'command': 'shutdown'}));
        Future<void>.delayed(const Duration(seconds: 2), () {
          try {
            process.kill();
          } catch (_) {}
        });
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _openBrowser() async {
    final url = _urlController.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(
        () => _error =
            'Informe um endereço válido iniciado por http:// ou https://.',
      );
      return;
    }

    setState(() {
      _error = null;
      _openingBrowser = true;
      _browserReady = false;
      _status = 'Iniciando Edge e automação…';
    });
    await _saveAddress(uri.toString());
    _addLog(
      'Abrindo o SEI no Edge. Faça login e navegue até o processo desejado.',
    );

    try {
      final process = await _startBridge();
      if (!mounted) return;
      _bridge = process;
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            _handleBridgeEvent,
            onError: (Object error) {
              if (mounted) {
                setState(() {
                  _error = 'Falha na comunicação com a automação: $error';
                });
              }
            },
            onDone: () {
              if (mounted && !_extracting) {
                setState(() {
                  _bridge = null;
                  _openingBrowser = false;
                  _browserReady = false;
                  _status = 'Automação encerrada';
                });
              }
            },
          );
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _addLog('Automação: $line'));
      process.stdin.writeln(
        jsonEncode({'command': 'open_browser', 'url': url}),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _openingBrowser = false;
        _status = 'Não foi possível iniciar';
        _error = error.toString();
      });
      _addLog('Erro ao iniciar a automação: $error');
    }
  }

  Future<Process> _startBridge() async {
    final script = File(
      'automation${Platform.pathSeparator}sei_tree_bridge.py',
    );
    if (!await script.exists()) {
      throw StateError(
        'Arquivo da automação não encontrado: ${script.absolute.path}. '
        'Inicie o aplicativo a partir da pasta do projeto.',
      );
    }

    final candidates = <String?>[
      Platform.environment['PREENCHE_DIARIO_PYTHON'],
      r'C:\SourceCode\PreencheDiario-UFU\.venv\Scripts\python.exe',
    ].whereType<String>().where((path) => path.trim().isNotEmpty);
    String? python;
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        python = candidate;
        break;
      }
    }
    python ??= 'python';

    final env = Map<String, String>.from(Platform.environment)
      ..['PYTHONIOENCODING'] = 'utf-8';
    final projectRoot = Directory.current.parent;
    final siblingLegacyProject = Directory(
      '${projectRoot.path}${Platform.pathSeparator}PreencheDiario-UFU',
    );
    if (await siblingLegacyProject.exists()) {
      env['PREENCHE_DIARIO_ROOT'] = siblingLegacyProject.path;
    }
    return Process.start(
      python,
      ['-u', script.absolute.path],
      environment: env,
      runInShell: true,
    );
  }

  void _handleBridgeEvent(String line) {
    Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      _addLog(line);
      return;
    }
    final type = event['type'];
    if (type == 'log') {
      _addLog(event['message']?.toString() ?? '');
      return;
    }
    if (!mounted) return;

    switch (type) {
      case 'browser_opened':
        setState(() {
          _openingBrowser = false;
          _browserReady = true;
          _status = 'Edge aberto · faça login e abra um processo';
        });
        _addLog('Edge pronto em ${event['url'] ?? _urlController.text}.');
      case 'started':
        setState(() {
          _extracting = true;
          _error = null;
          _documents.clear();
          _progress = 0;
          _progressTotal = 0;
          _progressLabel = 'Preparando a leitura da árvore…';
          _status = 'Consultando documentos do processo';
        });
      case 'progress':
        setState(() {
          _progress = (event['current'] as num?)?.toInt() ?? 0;
          _progressTotal = (event['total'] as num?)?.toInt() ?? 0;
          _progressLabel = event['name']?.toString() ?? '';
        });
        _addLog('Documento $_progress/$_progressTotal: $_progressLabel');
      case 'result':
        final rows = (event['documents'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(_SeiDocument.fromJson)
            .toList();
        setState(() {
          _documents
            ..clear()
            ..addAll(rows);
          _extracting = false;
          _progressLabel = '';
          _status = 'Consulta concluída';
        });
        _addLog('${rows.length} documento(s) encontrados na árvore.');
      case 'error':
      case 'fatal':
        final message = event['message']?.toString() ?? 'Erro desconhecido.';
        setState(() {
          _error = message;
          if (_openingBrowser || type == 'fatal') _browserReady = false;
          _openingBrowser = false;
          _extracting = false;
          _status = 'A consulta precisa de atenção';
        });
        _addLog('Erro: $message');
      case 'stopping':
        _addLog('Encerrando automação.');
    }
  }

  void _addLog(String message) {
    if (message.trim().isEmpty || !mounted) return;
    setState(() {
      _logs.add(message.trim());
      if (_logs.length > 250) _logs.removeAt(0);
    });
  }

  Future<void> _extractTree() async {
    if (_bridge == null || !_browserOpened) {
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
          'A consulta abrirá cada documento para tentar identificar tipo e número, '
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

    setState(() {
      _error = null;
      _extracting = true;
      _documents.clear();
      _progress = 0;
      _progressTotal = 0;
      _progressLabel = 'Iniciando leitura da árvore…';
      _status = 'Consultando documentos do processo';
    });
    _addLog('Iniciando consulta da árvore do processo atual.');
    _bridge!.stdin.writeln(jsonEncode({'command': 'extract_tree'}));
  }

  Future<void> _saveReport() async {
    if (_documents.isEmpty) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Salvar inventário da árvore do processo',
      fileName: 'relatorio_arvore_sei.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (path == null || path.isEmpty) return;

    try {
      await File(path).writeAsString(_formatReport(), encoding: utf8);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Inventário salvo em $path')));
      _addLog('Inventário salvo em $path');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Não foi possível salvar o inventário: $error');
    }
  }

  Future<void> _copyReport() async {
    if (_documents.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _formatReport()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Relatório copiado no formato para parecer.'),
      ),
    );
  }

  String _formatReport() => _documents
      .map((doc) {
        final identification = doc.typeNumber.isNotEmpty
            ? doc.typeNumber
            : doc.treeName;
        final code = doc.seiCode.isNotEmpty ? ' (${doc.seiCode})' : '';
        final date = doc.date.isNotEmpty ? ', de ${doc.date}' : '';
        final summary = doc.summary.isNotEmpty ? ' – ${doc.summary}' : '';
        return '${doc.order}. $identification$code$date$summary';
      })
      .join('\n');

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
                        if (_documents.isNotEmpty) ...[
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
    child: Row(
      children: [
        IconButton(
          tooltip: 'Voltar ao painel de funcionalidades',
          onPressed: () => context.go('/'),
          icon: Icon(Icons.arrow_back_rounded),
          color: AppTheme.textSecondary,
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFFB454).withAlpha(35),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.account_tree_rounded,
            color: Color(0xFFFFB454),
            size: 21,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SEI',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'EXTRAIR ÁRVORE DE PROCESSO',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 9,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const Spacer(),
        _StatusPill(label: _status, busy: _openingBrowser || _extracting),
        const SizedBox(width: 10),
        const ThemeSelector(compact: true),
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
              onChanged: _saveAddress,
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
              label: Text(_bridge == null ? 'Abrir Edge' : 'Ir para o SEI'),
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
                _progressTotal > 0
                    ? 'Documento $_progress de $_progressTotal'
                    : 'Preparando a árvore…',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_progressTotal > 0)
              Text(
                '${((_progress / _progressTotal) * 100).round()}%',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
          ],
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: _progressTotal > 0 ? _progress / _progressTotal : null,
          color: Color(0xFFFFB454),
          backgroundColor: AppTheme.divider,
          borderRadius: BorderRadius.circular(8),
        ),
        if (_progressLabel.isNotEmpty) ...[
          const SizedBox(height: 9),
          Text(
            _progressLabel,
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
                    'Documentos encontrados · ${_documents.length}',
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
        if (_documents.isEmpty)
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
                _formatReport(),
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
            rows: _documents.map((document) {
              return DataRow(
                cells: [
                  DataCell(Text('${document.order}')),
                  DataCell(_LimitedCell(document.treeName, width: 210)),
                  DataCell(_LimitedCell(document.typeNumber, width: 220)),
                  DataCell(
                    Text(document.seiCode.isEmpty ? '—' : document.seiCode),
                  ),
                  DataCell(_LimitedCell(document.date, width: 150)),
                  DataCell(_LimitedCell(document.summary, width: 320)),
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
    initiallyExpanded: _logs.isNotEmpty,
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
      '${_logs.length} mensagens',
      style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
    ),
    children: [
      Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 210),
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _logs.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(
              _logs[index],
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

class _SeiDocument {
  const _SeiDocument({
    required this.order,
    required this.treeName,
    required this.seiCode,
    required this.typeNumber,
    required this.date,
    required this.summary,
  });

  final int order;
  final String treeName;
  final String seiCode;
  final String typeNumber;
  final String date;
  final String summary;

  factory _SeiDocument.fromJson(Map<String, dynamic> json) => _SeiDocument(
    order: (json['ordem'] as num?)?.toInt() ?? 0,
    treeName: json['nome_arvore']?.toString() ?? '',
    seiCode: json['codigo_sei']?.toString() ?? '',
    typeNumber: json['tipo_numero']?.toString() ?? '',
    date: json['data']?.toString() ?? '',
    summary: json['resumo']?.toString() ?? '',
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
