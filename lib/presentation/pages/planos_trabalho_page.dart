import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/services/plano_trabalho_automation_service.dart';
import 'package:gestor_ufu/data/services/planilha_trabalho_service.dart';
import 'package:gestor_ufu/data/services/planos_trabalho_store.dart';
import 'package:gestor_ufu/domain/entities/plano_trabalho.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';

class PlanosTrabalhoPage extends StatefulWidget {
  const PlanosTrabalhoPage({super.key});

  @override
  State<PlanosTrabalhoPage> createState() => _PlanosTrabalhoPageState();
}

class _PlanosTrabalhoPageState extends State<PlanosTrabalhoPage> {
  static const _urlKey = 'planos_trabalho_sei_url';
  final _store = PlanosTrabalhoStore();
  final _automation = PlanoTrabalhoAutomationService();
  final _urlController = TextEditingController(text: 'https://sei.ufu.br');
  final List<String> _logs = [];
  List<PlanoTrabalho> _plans = [];
  String? _selectedId;
  bool _loading = true;
  bool _opening = false;
  bool _sending = false;

  PlanoTrabalho? get _selected {
    for (final plan in _plans) {
      if (plan.id == _selectedId) return plan;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _reload();
    _loadUrl();
  }

  Future<void> _loadUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_urlKey);
    if (mounted && saved != null && saved.trim().isNotEmpty) {
      _urlController.text = saved;
    }
  }

  Future<void> _saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, url);
  }

  Future<void> _reload({String? selectId}) async {
    try {
      final plans = await _store.list();
      if (!mounted) return;
      setState(() {
        _plans = plans;
        _selectedId =
            selectId ??
            (_selectedId != null && plans.any((p) => p.id == _selectedId)
                ? _selectedId
                : plans.firstOrNull?.id);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message('Não foi possível carregar os planos', error.toString());
    }
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '${TimeOfDay.now().format(context)}  $message');
      if (_logs.length > 100) _logs.removeLast();
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _automation.close();
    super.dispose();
  }

  Future<String?> _pickPdf({String? initial}) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Selecione o PDF do Plano de Trabalho',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      initialDirectory: initial != null && Directory(initial).existsSync()
          ? initial
          : null,
    );
    return picked?.files.single.path;
  }

  Future<void> _editPlan([PlanoTrabalho? plan]) async {
    final name = TextEditingController(text: plan?.nome ?? '');
    final number = TextEditingController(text: plan?.numero ?? '');
    final treeName = TextEditingController(text: plan?.nomeArvore ?? '');
    final interested = TextEditingController(text: plan?.interessado ?? '');
    final pdf = TextEditingController(text: plan?.pdfPath ?? '');
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, refresh) => AlertDialog(
            title: Text(
              plan == null ? 'Novo plano de trabalho' : 'Editar plano',
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _field(
                      name,
                      'Nome para identificar o plano',
                      Icons.badge_outlined,
                    ),
                    const SizedBox(height: 12),
                    _field(number, 'Número no SEI', Icons.numbers_rounded),
                    const SizedBox(height: 12),
                    _field(
                      treeName,
                      'Nome na árvore do SEI',
                      Icons.account_tree_outlined,
                      maxLength: 50,
                    ),
                    const SizedBox(height: 12),
                    _field(
                      interested,
                      'Interessado (opcional, nome exato do SEI)',
                      Icons.person_outline,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            pdf,
                            'PDF associado (opcional)',
                            Icons.picture_as_pdf_outlined,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filledTonal(
                          tooltip: 'Selecionar PDF',
                          onPressed: () async {
                            final path = await _pickPdf(
                              initial: pdf.text.isEmpty
                                  ? null
                                  : File(pdf.text).parent.path,
                            );
                            if (path != null) refresh(() => pdf.text = path);
                          },
                          icon: const Icon(Icons.folder_open_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const _Hint(
                      text:
                          'O SEI recebe o PDF como documento externo do tipo Plano, nato-digital e público. A data será preenchida automaticamente no dia do envio.',
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.save_rounded),
                label: const Text('Salvar'),
              ),
            ],
          ),
        ),
      );
      if (saved != true) return;
      final result = await _store.save(
        id: plan?.id,
        nome: name.text,
        numero: number.text,
        nomeArvore: treeName.text,
        interessado: interested.text,
        pdfPath: pdf.text,
      );
      await _reload(selectId: result.id);
      _log('Plano "${result.nome}" salvo no armazenamento local.');
    } catch (error) {
      if (mounted) _message('Não foi possível salvar', error.toString());
    } finally {
      name.dispose();
      number.dispose();
      treeName.dispose();
      interested.dispose();
      pdf.dispose();
    }
  }

  Future<void> _deletePlan(PlanoTrabalho plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover plano?'),
        content: Text(
          'Remover "${plan.nome}" e os dados de planilha associados?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.delete(plan.id);
    await _reload();
    _log('Plano "${plan.nome}" removido.');
  }

  Future<void> _openSei() async {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        !{'http', 'https'}.contains(uri.scheme)) {
      _message(
        'Endereço inválido',
        'Informe uma URL HTTP ou HTTPS válida do SEI.',
      );
      return;
    }
    setState(() => _opening = true);
    try {
      await _saveUrl(uri.toString());
      final openedUrl = _automation.isConnected
          ? 'janela atual do SEI'
          : await _automation.openBrowser(uri.toString());
      _log('Edge pronto em $openedUrl. Entre no SEI e abra o processo.');
    } catch (error) {
      _log('Falha ao abrir o Edge: $error');
      _message('Não foi possível abrir o SEI', error.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _sendToSei() async {
    final plan = _selected;
    if (plan == null) {
      _message(
        'Selecione um plano',
        'Escolha um cadastro antes de enviar ao SEI.',
      );
      return;
    }
    if (!_automation.isConnected) {
      await _openSei();
      _message(
        'Conclua o acesso ao SEI',
        'Faça login manualmente no Edge e abra o processo que receberá o documento. Depois volte e clique em Inserir no SEI.',
      );
      return;
    }
    var pdfPath = plan.pdfPath;
    if (pdfPath.isEmpty || !await File(pdfPath).exists()) {
      final selected = await _pickPdf(
        initial: pdfPath.isEmpty ? null : File(pdfPath).parent.path,
      );
      if (selected == null) return;
      pdfPath = selected;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Inserir documento externo no SEI?'),
        content: Text(
          'Plano: ${plan.nome}\nPDF: ${File(pdfPath).uri.pathSegments.last}\n\nData de hoje, tipo Plano, nato-digital e acesso público. Confira se o processo aberto no Edge é o correto.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.upload_rounded),
            label: const Text('Inserir no SEI'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _sending = true);
    try {
      await _automation.insertPlan(
        pdfPath: pdfPath,
        numero: plan.numero,
        nomeArvore: plan.nomeArvore,
        interessado: plan.interessado,
        log: _log,
      );
      if (pdfPath != plan.pdfPath) {
        await _store.save(
          id: plan.id,
          nome: plan.nome,
          numero: plan.numero,
          nomeArvore: plan.nomeArvore,
          interessado: plan.interessado,
          pdfPath: pdfPath,
        );
        await _reload(selectId: plan.id);
      }
      if (mounted)
        _message(
          'Documento inserido',
          'O SEI confirmou o novo documento na árvore do processo. Revise o cadastro antes de assinar.',
        );
    } catch (error) {
      _log('Falha ao inserir no SEI: $error');
      if (mounted) _message('Falha na inserção', error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openSpreadsheet() async {
    final plan = _selected;
    if (plan == null) {
      _message(
        'Selecione um plano',
        'Escolha um cadastro para abrir os dados de planilha.',
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SpreadsheetDialog(plan: plan, store: _store),
    );
    await _reload(selectId: plan.id);
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    int? maxLength,
  }) => TextField(
    controller: controller,
    maxLength: maxLength,
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
  );

  void _message(String title, String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => context.go('/'),
                      tooltip: 'Voltar ao início',
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF7B8B).withAlpha(28),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.assignment_turned_in_rounded,
                        color: Color(0xFFFF7B8B),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Planos de Trabalho',
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 22,
                            ),
                          ),
                          Text(
                            'CADASTRO, PLANILHAS E ENVIO DE PDF AO SEI',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 10,
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _countPill('${_plans.length} planos'),
                    const SizedBox(width: 10),
                    const ThemeSelector(compact: true),
                  ],
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final narrow = constraints.maxWidth < 920;
                      final list = _planList();
                      final details = _detailsPanel();
                      return narrow
                          ? Column(
                              children: [
                                SizedBox(height: 270, child: list),
                                const SizedBox(height: 14),
                                Expanded(child: details),
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(width: 390, child: list),
                                const SizedBox(width: 16),
                                Expanded(child: details),
                              ],
                            );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _operationLog(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _planList() => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Planos cadastrados',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            Text(
              '${_plans.length} itens',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _plans.isEmpty
              ? const Center(
                  child: _Hint(
                    text:
                        'Cadastre cada conjunto de dados de Plano do SEI. Seus planos serão guardados no armazenamento local do Gestor UFU.',
                  ),
                )
              : ListView.separated(
                  itemCount: _plans.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final plan = _plans[index];
                    final selected = plan.id == _selectedId;
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => setState(() => _selectedId = plan.id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFFF7B8B).withAlpha(20)
                              : AppTheme.bgSurface.withAlpha(130),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFFFF7B8B).withAlpha(130)
                                : AppTheme.divider,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF7B8B).withAlpha(25),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.description_outlined,
                                color: Color(0xFFFF7B8B),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    plan.nome,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    plan.numero.isEmpty
                                        ? plan.nomeArvore
                                        : plan.numero,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (selected)
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: Color(0xFFFF7B8B),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: () => _editPlan(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Novo plano'),
        ),
      ],
    ),
  );

  Widget _detailsPanel() {
    final plan = _selected;
    return _panel(
      child: plan == null
          ? const Center(
              child: _Hint(
                text:
                    'Selecione um plano ou crie um novo para ver as ações disponíveis.',
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        plan.nome,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 19,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _editPlan(plan),
                      tooltip: 'Editar cadastro',
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      onPressed: () => _deletePlan(plan),
                      tooltip: 'Remover plano',
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Color(0xFFFF7582),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _detail('Número SEI', plan.numero),
                _detail('Nome na árvore', plan.nomeArvore),
                _detail('Interessado', plan.interessado),
                _detail(
                  'PDF associado',
                  plan.pdfPath.isEmpty
                      ? 'Nenhum'
                      : File(plan.pdfPath).uri.pathSegments.last,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _openSpreadsheet,
                        icon: const Icon(Icons.table_view_rounded),
                        label: const Text('Dados e preenchimento Excel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _sending ? null : _sendToSei,
                        icon: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.upload_rounded),
                        label: const Text('Inserir no SEI'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.account_tree_outlined,
                      color: Color(0xFFFF7B8B),
                      size: 19,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      'Processo atual no SEI',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    _statusPill(
                      _automation.isConnected ? 'EDGE ABERTO' : 'DESCONECTADO',
                      _automation.isConnected,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  onChanged: _saveUrl,
                  decoration: const InputDecoration(
                    labelText: 'Endereço do SEI',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: _opening ? null : _openSei,
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: Text(
                    _opening ? 'Abrindo Edge…' : 'Abrir Edge e entrar no SEI',
                  ),
                ),
                const SizedBox(height: 8),
                const _Hint(
                  text:
                      'O login é feito manualmente. No Edge, entre no SEI e abra o processo; depois use Inserir no SEI.',
                ),
                const Spacer(),
                const _Hint(
                  text:
                      'A cópia preenchida da planilha mantém fórmulas e layout; o Excel recalcula os resultados quando você abrir o arquivo.',
                ),
              ],
            ),
    );
  }

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 135,
          child: Text(
            label,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _operationLog() => Container(
    height: 122,
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
    decoration: BoxDecoration(
      color: AppTheme.bgSurface.withAlpha(145),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.subject_rounded,
              color: AppTheme.textSecondary,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Registro da operação',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${_logs.length} mensagens',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _logs.isEmpty
              ? Center(
                  child: Text(
                    'As etapas do envio aparecerão aqui.',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (_, index) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      _logs[index],
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    ),
  );

  Widget _panel({required Widget child}) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AppTheme.bgSurface.withAlpha(175),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AppTheme.divider),
    ),
    child: child,
  );
  Widget _countPill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
    decoration: AppTheme.glassDecoration(opacity: 0.08),
    child: Text(
      text,
      style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
    ),
  );
  Widget _statusPill(String text, bool ready) {
    final color = ready ? AppTheme.accentGreen : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(25),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SpreadsheetDialog extends StatefulWidget {
  const _SpreadsheetDialog({required this.plan, required this.store});
  final PlanoTrabalho plan;
  final PlanosTrabalhoStore store;
  @override
  State<_SpreadsheetDialog> createState() => _SpreadsheetDialogState();
}

class _SpreadsheetDialogState extends State<_SpreadsheetDialog> {
  final _service = PlanilhaTrabalhoService();
  Map<String, dynamic>? _data;
  bool _showEmpty = false;
  bool _busy = false;
  String _message = 'Importe uma planilha já preenchida para começar.';

  @override
  void initState() {
    super.initState();
    _data = widget.plan.spreadsheetData;
    _refreshMessage();
  }

  void _refreshMessage() {
    final fields = _data?['fields'] as List? ?? [];
    final filled = fields
        .whereType<Map>()
        .where((item) => item['value'] != null && item['value'] != '')
        .length;
    _message = _data == null
        ? 'Importe uma planilha já preenchida para começar.'
        : 'Origem: ${_data!['origin'] ?? 'Planilha'} · $filled valores salvos. Campos vazios não substituem dados do arquivo de destino.';
  }

  Future<String?> _pickSpreadsheet({required String title}) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: title,
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xlsm'],
    );
    return result?.files.single.path;
  }

  Future<void> _import() async {
    final path = await _pickSpreadsheet(
      title: 'Importar dados da planilha preenchida',
    );
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final data = _service.capture(path);
      setState(() {
        _data = data;
        _refreshMessage();
      });
      if (data['ignoredFormulas'] is List &&
          (data['ignoredFormulas'] as List).isNotEmpty) {
        _showMessage(
          'Fórmulas ignoradas',
          'Campos que contêm fórmulas não foram importados.',
        );
      }
    } catch (error) {
      _showMessage('Não foi possível importar', error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _updateFields() async {
    final data = _data;
    if (data == null) {
      _showMessage(
        'Importe os dados primeiro',
        'Selecione uma planilha preenchida antes de atualizar os campos.',
      );
      return;
    }
    final path = await _pickSpreadsheet(
      title: 'Selecionar nova versão do modelo',
    );
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final added = _service.newFields(data, path);
      data['fields'] = [...(data['fields'] as List? ?? []), ...added];
      data['origin'] = path.split(Platform.pathSeparator).last;
      setState(() {
        _showEmpty = true;
        _refreshMessage();
      });
      _showMessage(
        'Modelo atualizado',
        '${added.length} campos novos foram acrescentados vazios. Salve os dados para mantê-los.',
      );
    } catch (error) {
      _showMessage('Não foi possível atualizar', error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editField(int index, Map<String, dynamic> field) async {
    final controller = TextEditingController(
      text: _service.displayValue(field['value'], field['type'] as String),
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${field['sheet']} · ${field['label']}'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: (field['type'] == 'texto' && controller.text.length > 80)
                ? 5
                : 1,
            decoration: InputDecoration(
              labelText: '${field['cell']} · ${field['type']}',
              helperText: field['type'] == 'data'
                  ? 'Use DD/MM/AAAA'
                  : 'Deixe vazio para não transferir este campo',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    if (value == null || _data == null) return;
    try {
      field['value'] = _service.parseValue(value, field['type'] as String);
      final storedFields = _data!['fields'] as List;
      storedFields[index] = field;
      setState(_refreshMessage);
    } catch (error) {
      _showMessage('Valor inválido', error.toString());
    } finally {
      controller.dispose();
    }
  }

  Future<void> _saveData() async {
    final data = _data;
    if (data == null) return;
    await widget.store.saveSpreadsheetData(widget.plan.id, data);
    if (mounted)
      _showMessage(
        'Dados salvos',
        'Os valores foram guardados junto ao plano neste computador.',
      );
  }

  Future<void> _fillWorkbook() async {
    final data = _data;
    if (data == null) {
      _showMessage(
        'Sem dados salvos',
        'Importe ou salve os valores da planilha antes de preencher outro modelo.',
      );
      return;
    }
    final source = await _pickSpreadsheet(
      title: 'Selecione o novo modelo de planilha',
    );
    if (source == null) return;
    try {
      final preview = _service.preview(data, source);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Prévia do preenchimento'),
          content: SizedBox(
            width: 700,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${preview.length} campo(s) serão preenchidos. Valores vazios no cadastro serão mantidos como estão na planilha.',
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: preview.length,
                    itemBuilder: (_, i) {
                      final item = preview[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          '${item['sheet']}!${item['cell']} · ${item['label']}',
                        ),
                        subtitle: Text(
                          '${_service.displayValue(item['current'], item['type'] as String)}  →  ${_service.displayValue(item['value'], item['type'] as String)}',
                        ),
                      );
                    },
                  ),
                ),
                const _Hint(
                  text:
                      'A cópia mantém a estrutura original. O Excel recalcula fórmulas ao abrir o arquivo.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Gerar cópia'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      final extension = source.substring(source.lastIndexOf('.'));
      final output = await FilePicker.platform.saveFile(
        dialogTitle: 'Salvar cópia preenchida',
        fileName:
            'Plano_de_Trabalho_${widget.plan.nome.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}$extension',
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'xlsm'],
      );
      if (output == null) return;
      setState(() => _busy = true);
      final result = await _service.fillCopy(
        sourcePath: source,
        destinationPath: output,
        data: data,
      );
      if (mounted)
        _showMessage(
          'Cópia preenchida',
          '${result.length} campos transferidos. Abra o arquivo no Excel para recalcular as fórmulas e confira a aba Compilado antes de gerar o PDF.\n\n$output',
        );
    } catch (error) {
      _showMessage('Não foi possível preencher', error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String title, String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fields = (_data?['fields'] as List? ?? [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final visible = <(int, Map<String, dynamic>)>[];
    for (var index = 0; index < fields.length; index++) {
      if (_showEmpty ||
          fields[index]['value'] != null && fields[index]['value'] != '')
        visible.add((index, fields[index]));
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 1120,
          maxHeight: 760,
          minWidth: 650,
          minHeight: 460,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.table_view_rounded,
                    color: Color(0xFFFF7B8B),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Dados da planilha · ${widget.plan.nome}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _message,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Mostrar campos vazios'),
                    selected: _showEmpty,
                    onSelected: (value) => setState(() => _showEmpty = value),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _updateFields,
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text('Atualizar campos do modelo'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _data == null
                    ? const Center(
                        child: _Hint(
                          text:
                              'Importe uma planilha Excel preenchida. O modelo precisa conter as abas e os cabeçalhos reconhecidos.',
                        ),
                      )
                    : visible.isEmpty
                    ? const Center(
                        child: _Hint(
                          text: 'Nenhum campo com valor foi importado.',
                        ),
                      )
                    : ListView.separated(
                        itemCount: visible.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, row) {
                          final (index, field) = visible[row];
                          return ListTile(
                            dense: true,
                            title: Text(
                              '${field['sheet']} · ${field['label']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${field['cell']}  |  ${_service.displayValue(field['value'], field['type'] as String)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: 'Editar campo',
                              onPressed: () => _editField(index, field),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          );
                        },
                      ),
              ),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open_rounded),
                    label: const Text('Importar dados de planilha'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _saveData,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Salvar dados'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _fillWorkbook,
                    icon: const Icon(Icons.output_rounded),
                    label: const Text('Salvar e preencher planilha'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.info_outline_rounded, size: 17, color: AppTheme.textSecondary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
}

extension _PlanFirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
