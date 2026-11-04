import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/core/utils/macro_resolver.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/presentation/controllers/config_controller.dart';
import 'package:gestor_ufu/data/services/planos_ensino_service.dart';
import 'package:gestor_ufu/data/services/planos_ensino_automation_service.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';

class PlanosEnsinoPage extends StatefulWidget {
  const PlanosEnsinoPage({super.key});
  @override
  State<PlanosEnsinoPage> createState() => _PlanosEnsinoPageState();
}

class _PlanosEnsinoPageState extends State<PlanosEnsinoPage> {
  final _service = PlanosEnsinoService();
  final _automation = PlanosEnsinoAutomationService();
  final _seiUrlController = TextEditingController(text: 'https://sei.ufu.br');
  List<Map<String, dynamic>> _plans = [];
  final List<String> _logs = [];
  bool _loading = true;
  bool _openingSei = false;
  bool _browserReady = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadSeiAddress();
  }

  Future<void> _loadSeiAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('planos_ensino_sei_url');
    if (mounted && saved != null && saved.trim().isNotEmpty) {
      _seiUrlController.text = saved;
    }
  }

  Future<void> _saveSeiAddress(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('planos_ensino_sei_url', value.trim());
  }

  @override
  void dispose() {
    _seiUrlController.dispose();
    _automation.close();
    super.dispose();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add('${TimeOfDay.now().format(context)}  $message');
      if (_logs.length > 120) _logs.removeAt(0);
    });
  }

  Future<void> _openSei() async {
    final uri = Uri.tryParse(_seiUrlController.text.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        !{'http', 'https'}.contains(uri.scheme)) {
      _message(
        'Endereço inválido',
        'Informe o endereço do SEI iniciado por https://.',
      );
      return;
    }
    setState(() => _openingSei = true);
    try {
      await _saveSeiAddress(uri.toString());
      final url = _automation.isConnected
          ? (_automation.focus().then((_) => 'janela atual do SEI'))
          : _automation.openBrowser(uri.toString());
      if (!mounted) return;
      setState(() => _browserReady = true);
      _log('Edge aberto no SEI em $url. Entre manualmente e abra o processo.');
    } catch (error) {
      _log('Falha ao abrir o Edge: $error');
      _message('Erro ao abrir o SEI', error.toString());
    } finally {
      if (mounted) setState(() => _openingSei = false);
    }
  }

  Future<void> _insertInSei(Map<String, dynamic> plan) async {
    final missing = PlanosEnsinoService.missingFields(plan);
    if (missing.isNotEmpty) {
      _message(
        'Plano incompleto',
        'Preencha estes campos antes de inserir:\n\n• ${missing.join('\n• ')}',
      );
      return;
    }
    if (!_browserReady) {
      _message(
        'Conecte ao SEI',
        'Abra o Edge, faça login e deixe aberto o processo. Depois escolha Inserir no SEI novamente.',
      );
      await _openSei();
      return;
    }
    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Inserir Plano de Ensino no SEI?'),
        content: Text(
          'Criar “${ident['nome']}” no processo atualmente aberto?\n\nO documento será salvo sem assinatura. Revise o processo e assine manualmente quando estiver pronto.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Inserir'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      _log('Inserindo Plano de Ensino: ${ident['nome']} (${ident['codigo']}).');
      await _automation.insertPlan(plan, _log);
      if (mounted)
        _message(
          'Plano enviado ao SEI',
          'O documento foi salvo sem assinatura. Confira o processo e faça a assinatura manual.',
        );
    } catch (error) {
      _log('Falha ao inserir o plano: $error');
      if (mounted) _message('Falha na inserção', error.toString());
    }
  }

  Future<void> _reload() async {
    final plans = await _service.list();
    plans.sort((a, b) => _name(a).compareTo(_name(b)));
    if (mounted)
      setState(() {
        _plans = plans;
        _loading = false;
      });
  }

  String _name(Map<String, dynamic> plan) {
    final ident = Map<String, dynamic>.from(
      plan['identificacao'] as Map? ?? {},
    );
    final name = ident['nome']?.toString().trim() ?? '';
    final code = ident['codigo']?.toString().trim() ?? '';
    return name.isNotEmpty ? name : (code.isEmpty ? 'Novo plano' : code);
  }

  Future<void> _edit([Map<String, dynamic>? current]) async {
    final plan = current == null
        ? _service.emptyPlan(DateTime.now().microsecondsSinceEpoch.toString())
        : _service.normalize(current, current['id'].toString());
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PlanoEditorDialog(plan: plan),
    );
    if (result == null) return;
    final ident = Map<String, dynamic>.from(result['identificacao'] as Map);
    if (ident['nome'].toString().trim().isEmpty ||
        ident['codigo'].toString().trim().isEmpty) {
      _message(
        'Identificação incompleta',
        'Informe o componente curricular e o código.',
      );
      return;
    }
    await _service.save(result);
    await _reload();
  }

  Future<void> _remove(Map<String, dynamic> plan) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover plano?'),
        content: Text(
          'O plano “' + _name(plan) + '” será removido deste computador.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _service.remove(plan['id'].toString());
      await _reload();
    }
  }

  Future<void> _exportBackup() async {
    final data = const JsonEncoder.withIndent('  ').convert(_plans);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar Planos de Ensino',
      fileName: 'planos_ensino.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: utf8.encode(data),
    );
    if (path != null && mounted) _message('Backup exportado', path);
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Importar Planos de Ensino',
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    final bytes = picked?.files.single.bytes;
    if (bytes == null) return;
    try {
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! List)
        throw const FormatException(
          'O arquivo precisa conter uma lista de planos.',
        );
      for (final item in data.whereType<Map>()) {
        final plan = Map<String, dynamic>.from(item);
        final id =
            plan['id']?.toString() ??
            DateTime.now().microsecondsSinceEpoch.toString();
        await _service.save(_service.normalize(plan, id));
      }
      await _reload();
      if (mounted)
        _message(
          'Backup importado',
          'Os planos foram mesclados ao cadastro atual.',
        );
    } catch (error) {
      if (mounted) _message('Falha ao importar', error.toString());
    }
  }

  Future<void> _importDocx() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Importar plano de ensino do Word',
      type: FileType.custom,
      allowedExtensions: ['docx'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file?.bytes == null) return;
    try {
      final plan = _service.importDocx(
        file!.bytes!,
        DateTime.now().microsecondsSinceEpoch.toString(),
      );
      plan['sourceDocxName'] = file.name;
      await _edit(plan);
    } catch (error) {
      if (mounted) _message('Falha ao importar Word', error.toString());
    }
  }

  Future<void> _exportWord(Map<String, dynamic> plan) async {
    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    final code = (ident['codigo']?.toString() ?? 'plano').replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
      '_',
    );
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar plano de ensino para Word',
      fileName: 'Plano_de_Ensino_' + code + '.docx',
      type: FileType.custom,
      allowedExtensions: ['docx'],
      bytes: PlanosEnsinoService.exportDocx(plan),
    );
    if (path != null && mounted) _message('Plano exportado', path);
  }

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
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: BoxDecoration(gradient: AppTheme.bgGradient),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.go('/'),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: AppTheme.green.withAlpha(35),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.menu_book_rounded, color: AppTheme.green),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Planos de Ensino',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'CADASTRO, CRONOGRAMAS E DOCUMENTOS PARA O SEI',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 10,
                            letterSpacing: 1.05,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _importBackup,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.file_open_rounded),
                    label: const Text('Importar backup'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _exportBackup,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('Exportar backup'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _importDocx,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Importar Word'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _edit(),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Novo formulário'),
                  ),
                  const SizedBox(width: 10),
                  const ThemeSelector(compact: true),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _seiUrlController,
                      keyboardType: TextInputType.url,
                      onChanged: (value) => _saveSeiAddress(value),
                      decoration: const InputDecoration(
                        labelText: 'Endereço do SEI',
                        prefixIcon: Icon(Icons.link_rounded),
                      ),
                      onSubmitted: (_) => _openSei(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _openingSei ? null : _openSei,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: _openingSei
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _browserReady
                                ? Icons.open_in_browser_rounded
                                : Icons.login_rounded,
                          ),
                    label: Text(
                      _openingSei
                          ? 'Abrindo Edge...'
                          : _browserReady
                          ? 'Abrir SEI no Edge'
                          : 'Conectar ao SEI',
                    ),
                  ),
                  if (_browserReady) ...[
                    const SizedBox(width: 10),
                    Chip(
                      avatar: Icon(
                        Icons.check_circle,
                        color: AppTheme.green,
                        size: 16,
                      ),
                      label: Text('Edge conectado'),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _plans.isEmpty
                  ? _EmptyPlans(onCreate: () => _edit())
                  : ListView.separated(
                      padding: const EdgeInsets.all(24),
                      itemCount: _plans.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => _PlanCard(
                        plan: _plans[index],
                        title: _name(_plans[index]),
                        onEdit: () => _edit(_plans[index]),
                        onRemove: () => _remove(_plans[index]),
                        onExport: () => _exportWord(_plans[index]),
                        onInsert: () => _insertInSei(_plans[index]),
                      ),
                    ),
            ),
            if (_logs.isNotEmpty)
              Container(
                height: 150,
                margin: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                decoration: BoxDecoration(
                  color: AppTheme.bgCardAlt,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  itemCount: _logs.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      _logs[_logs.length - index - 1],
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
      ),
    ),
  );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.title,
    required this.onEdit,
    required this.onRemove,
    required this.onExport,
    required this.onInsert,
  });
  final Map<String, dynamic> plan;
  final String title;
  final VoidCallback onEdit, onRemove, onExport, onInsert;

  @override
  Widget build(BuildContext context) {
    final ident = Map<String, dynamic>.from(
      plan['identificacao'] as Map? ?? {},
    );
    final count =
        ((plan['cronograma_teorico'] as List?)?.length ?? 0) +
        ((plan['cronograma_pratico'] as List?)?.length ?? 0);
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgCardAlt,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: AppTheme.divider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: Color(0x2235D39E),
          child: Icon(Icons.menu_book_rounded, color: AppTheme.green),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          (ident['codigo']?.toString() ?? 'Sem código') +
              '  ·  ' +
              count.toString() +
              ' aulas no cronograma',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(
              tooltip: 'Inserir no SEI',
              onPressed: onInsert,
              color: AppTheme.green,
              icon: const Icon(Icons.upload_file_rounded),
            ),
            IconButton(
              tooltip: 'Exportar Word (.docx)',
              onPressed: onExport,
              icon: const Icon(Icons.description_outlined),
            ),
            IconButton(
              tooltip: 'Editar plano',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_rounded),
            ),
            IconButton(
              tooltip: 'Remover plano',
              onPressed: onRemove,
              color: AppTheme.danger,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }
}

class _EmptyPlans extends StatelessWidget {
  const _EmptyPlans({required this.onCreate});
  final VoidCallback onCreate;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.menu_book_rounded,
          size: 54,
          color: AppTheme.textSecondary.withAlpha(100),
        ),
        const SizedBox(height: 16),
        Text(
          'Nenhum plano cadastrado',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Crie um formulário ou importe um backup para começar.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Novo formulário'),
        ),
      ],
    ),
  );
}

class _PlanoEditorDialog extends StatefulWidget {
  const _PlanoEditorDialog({required this.plan});
  final Map<String, dynamic> plan;
  @override
  State<_PlanoEditorDialog> createState() => _PlanoEditorDialogState();
}

enum _ScheduleImportMode { merge, replace }

class _PlanMoodleConfigDialog extends StatelessWidget {
  const _PlanMoodleConfigDialog({required this.configs});

  final List<CourseConfig> configs;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Escolha uma configuração do Config Moodle'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: ListView.separated(
        itemCount: configs.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final config = configs[index];
          final lessonCount = config.sections
              .where((section) => section.visible)
              .expand((section) => section.activities)
              .where((activity) => activity.visibility != 0)
              .where(
                (activity) => _planScheduleNormalize(
                  activity.name,
                ).contains('realizar-se-a'),
              )
              .length;
          return ListTile(
            leading: Icon(Icons.school_rounded, color: AppTheme.green),
            title: Text(config.name),
            subtitle: Text(
              '${config.moodleCourseName ?? 'Configuração local'} · $lessonCount atividade(s) com data',
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.pop(context, config),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
    ],
  );
}

class _ScheduleImportDialog extends StatelessWidget {
  const _ScheduleImportDialog({
    required this.configName,
    required this.theoreticalCount,
    required this.practicalCount,
  });

  final String configName;
  final int theoreticalCount;
  final int practicalCount;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Como importar as aulas?'),
    content: Text(
      '“$configName” contém $theoreticalCount aula(s) teóricas e $practicalCount prática(s). Escolha como aplicar ao cronograma atual.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      OutlinedButton(
        onPressed: () => Navigator.pop(context, _ScheduleImportMode.merge),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        child: const Text('Mesclar'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _ScheduleImportMode.replace),
        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
        child: const Text('Substituir'),
      ),
    ],
  );
}

String _planScheduleNormalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[áàâãä]'), 'a')
    .replaceAll(RegExp(r'[éèêë]'), 'e')
    .replaceAll(RegExp(r'[íìîï]'), 'i')
    .replaceAll(RegExp(r'[óòôõö]'), 'o')
    .replaceAll(RegExp(r'[úùûü]'), 'u')
    .replaceAll('ç', 'c');

class _PlanoEditorDialogState extends State<_PlanoEditorDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late Map<String, dynamic> _plan;
  final _controllers = <String, TextEditingController>{};
  final _service = PlanosEnsinoService();
  final _pastedSchedule = TextEditingController();

  static const _bodyFields = <String, String>{
    'ementa': 'Ementa',
    'justificativa': 'Justificativa',
    'objetivo_geral': 'Objetivo geral',
    'objetivos_especificos': 'Objetivos específicos',
    'programa_teorico': 'Dimensão teórica',
    'programa_pratico': 'Dimensão prática',
    'metodologia_tecnicas': 'Técnicas de ensino',
    'metodologia_recursos': 'Recursos didáticos',
    'metodologia_audiovisuais': 'Recursos audiovisuais',
    'avaliacao_geral': 'Avaliação',
    'avaliacao_provas': 'Calendário e distribuição de pontos',
    'horario_atendimento': 'Horário de atendimento',
    'atividade_recuperacao': 'Atividade de recuperação',
    'atendimento_especial': 'Atendimento especial',
  };
  static const _identFields = <String, String>{
    'nome': 'Componente curricular',
    'codigo': 'Código',
    'unidade_ofertante': 'Unidade ofertante',
    'periodo_serie': 'Período/Série',
    'turma': 'Turma',
    'carga_teorica': 'Carga horária teórica',
    'carga_pratica': 'Carga horária prática',
    'carga_total': 'Carga horária total',
    'professor': 'Professor(a)',
    'ano_semestre': 'Ano/Semestre',
    'observacoes': 'Observações',
  };

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 7, vsync: this);
    _plan = _service.normalize(widget.plan, widget.plan['id'].toString());
    final ident = Map<String, dynamic>.from(_plan['identificacao'] as Map);
    for (final key in _identFields.keys) {
      _controllers['identificacao.' + key] = TextEditingController(
        text: ident[key]?.toString() ?? '',
      );
    }
    for (final key in _bodyFields.keys) {
      _controllers[key] = TextEditingController(
        text: _plan[key]?.toString() ?? '',
      );
    }
    for (final kind in ['teorico', 'pratico']) {
      final key = 'cronograma_' + kind;
      final rows = (_plan[key] as List).whereType<Map>();
      _controllers[key] = TextEditingController(
        text: rows
            .map(
              (row) =>
                  row['data'].toString() + '\t' + row['atividade'].toString(),
            )
            .join('\n'),
      );
    }
    for (final kind in ['basica', 'complementar']) {
      final key = 'bibliografia_' + kind;
      _controllers[key] = TextEditingController(
        text: (_plan[key] as List).join('\n'),
      );
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _pastedSchedule.dispose();
    super.dispose();
  }

  TextEditingController _c(String key) => _controllers[key]!;
  Map<String, dynamic> _readPlan() {
    final plan = jsonDecode(jsonEncode(_plan)) as Map<String, dynamic>;
    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    for (final key in _identFields.keys) {
      ident[key] = _c('identificacao.' + key).text.trim();
    }
    plan['identificacao'] = ident;
    for (final key in _bodyFields.keys) {
      plan[key] = _c(key).text.trim();
    }
    for (final kind in ['teorico', 'pratico']) {
      final key = 'cronograma_' + kind;
      plan[key] = _parseSchedule(_c(key).text);
    }
    for (final kind in ['basica', 'complementar']) {
      plan['bibliografia_' + kind] = _c('bibliografia_' + kind).text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return plan;
  }

  List<Map<String, String>> _parseSchedule(String text) {
    final result = <Map<String, String>>[];
    for (final line in text.split('\n')) {
      final cells = line.split('\t');
      if (cells.length < 2 ||
          !RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(cells.first.trim()))
        continue;
      result.add({
        'data': cells.first.trim(),
        'atividade': cells.skip(1).join(' — ').trim(),
      });
    }
    return result;
  }

  void _applyPastedSchedule() {
    try {
      final updated = PlanosEnsinoService.applyPastedSchedule(
        _readPlan(),
        _pastedSchedule.text,
      );
      for (final key in ['cronograma_teorico', 'cronograma_pratico']) {
        final rows = (updated[key] as List).whereType<Map>();
        _c(key).text = rows
            .map(
              (row) =>
                  row['data'].toString() + '\t' + row['atividade'].toString(),
            )
            .join('\n');
      }
      _c('avaliacao_provas').text =
          updated['avaliacao_provas']?.toString() ??
          _c('avaliacao_provas').text;
      setState(() => _plan = updated);
      _snack('Cronogramas teórico e prático atualizados.');
    } catch (error) {
      _snack(error.toString());
    }
  }

  Future<void> _importScheduleFromConfigMoodle() async {
    final controller = context.read<ConfigController>();
    await controller.loadAll();
    if (!mounted) return;
    final configs = controller.configs;
    if (configs.isEmpty) {
      _snack('Nenhuma configuração salva no Config Moodle.');
      return;
    }
    final config = await showDialog<CourseConfig>(
      context: context,
      builder: (_) => _PlanMoodleConfigDialog(configs: configs),
    );
    if (config == null || !mounted) return;

    final theoretical = <Map<String, String>>[];
    final practical = <Map<String, String>>[];
    for (final section in config.sections.where((item) => item.visible)) {
      for (final activity in section.activities.where(
        (item) => item.visibility != 0,
      )) {
        final normalizedName = _normalizeScheduleText(activity.name);
        if (!normalizedName.contains('realizar-se-a')) continue;
        final modalityText = _normalizeScheduleText(
          '${activity.modality ?? ''} ${activity.name}',
        );
        final target = modalityText.contains('teor')
            ? theoretical
            : modalityText.contains('prat')
            ? practical
            : null;
        if (target == null) continue;
        final resolvedName = MacroResolver.resolve(
          activity.name,
          config.semesterStartDate,
          section.date,
          activity.computeOpenDate(section.date),
          activity.computeCloseDate(section.date),
        );
        final match = RegExp(
          r'realizar-se-a\s*:\s*(\d{1,2}/\d{1,2}/\d{4})',
        ).firstMatch(_normalizeScheduleText(resolvedName));
        if (match == null) continue;
        final pieces = match.group(1)!.split('/').map(int.tryParse).toList();
        if (pieces.length != 3 || pieces.any((part) => part == null)) continue;
        final date = DateTime(pieces[2]!, pieces[1]!, pieces[0]!);
        if (date.year != pieces[2] ||
            date.month != pieces[1] ||
            date.day != pieces[0]) {
          continue;
        }
        final description = _scheduleDescription(activity.name);
        if (description.isEmpty) continue;
        target.add({
          'data': DateFormat('dd/MM/yyyy').format(date),
          'atividade': description,
        });
      }
    }
    int compareRows(Map<String, String> a, Map<String, String> b) {
      final dateA = DateFormat('dd/MM/yyyy').parseStrict(a['data']!);
      final dateB = DateFormat('dd/MM/yyyy').parseStrict(b['data']!);
      final dateOrder = dateA.compareTo(dateB);
      return dateOrder != 0
          ? dateOrder
          : a['atividade']!.compareTo(b['atividade']!);
    }

    theoretical.sort(compareRows);
    practical.sort(compareRows);
    if (theoretical.isEmpty && practical.isEmpty) {
      _snack(
        'Não encontrei aulas teóricas ou práticas com data definida no Config Moodle selecionado.',
      );
      return;
    }

    final previous = _readPlan();
    final hasExisting =
        (previous['cronograma_teorico'] as List).isNotEmpty ||
        (previous['cronograma_pratico'] as List).isNotEmpty;
    var replace = true;
    if (hasExisting) {
      final choice = await showDialog<_ScheduleImportMode>(
        context: context,
        builder: (_) => _ScheduleImportDialog(
          configName: config.name,
          theoreticalCount: theoretical.length,
          practicalCount: practical.length,
        ),
      );
      if (choice == null || !mounted) return;
      replace = choice == _ScheduleImportMode.replace;
    }

    List<Map<String, String>> applyMode(
      String key,
      List<Map<String, String>> imported,
    ) {
      if (replace) return imported;
      final combined = <Map<String, String>>[
        for (final row in (previous[key] as List).whereType<Map>())
          {
            'data': row['data'].toString(),
            'atividade': row['atividade'].toString(),
          },
        ...imported,
      ];
      final unique = <String, Map<String, String>>{};
      for (final row in combined) {
        unique['${row['data']}\u0000${row['atividade']}'] = row;
      }
      final result = unique.values.toList()..sort(compareRows);
      return result;
    }

    final importedTheory = applyMode('cronograma_teorico', theoretical);
    final importedPractice = applyMode('cronograma_pratico', practical);
    previous['cronograma_teorico'] = importedTheory;
    previous['cronograma_pratico'] = importedPractice;
    void updateController(String key, List<Map<String, String>> rows) {
      _c(key).text = rows
          .map((row) => '${row['data']}\t${row['atividade']}')
          .join('\n');
    }

    updateController('cronograma_teorico', importedTheory);
    updateController('cronograma_pratico', importedPractice);
    setState(() => _plan = previous);
    _snack(
      'Importadas ${theoretical.length} aulas teóricas e ${practical.length} práticas de ${config.name}.',
    );
  }

  String _normalizeScheduleText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[áàâãä]'), 'a')
      .replaceAll(RegExp(r'[éèêë]'), 'e')
      .replaceAll(RegExp(r'[íìîï]'), 'i')
      .replaceAll(RegExp(r'[óòôõö]'), 'o')
      .replaceAll(RegExp(r'[úùûü]'), 'u')
      .replaceAll('ç', 'c');

  String _scheduleDescription(String name) {
    var value = name.trim();
    value = value.replaceFirst(
      RegExp(r'\s*\([^)]*realizar-se-.[^)]*\)\.?\s*$', caseSensitive: false),
      '',
    );
    value = value.replaceFirst(
      RegExp(r'\s*[-–—]?\s*realizar-se-.:.*$', caseSensitive: false),
      '',
    );
    final separator = value.indexOf(':');
    if (separator >= 0) value = value.substring(separator + 1);
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.\s]+$'), '')
        .trim();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Widget _field(String key, String label, {int lines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: _c(key),
      minLines: lines,
      maxLines: lines == 1 ? 1 : null,
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: lines > 1,
      ),
    ),
  );

  Widget _scroll(List<Widget> children) => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(24),
    child: SizedBox(
      width: 1040,
      height: 760,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Formulário de Plano de Ensino',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 19,
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
          ),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabs: const [
              Tab(text: 'Identificação'),
              Tab(text: 'Ementa'),
              Tab(text: 'Objetivos'),
              Tab(text: 'Programa'),
              Tab(text: 'Metodologia'),
              Tab(text: 'Cronogramas'),
              Tab(text: 'Avaliação e bibliografia'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _scroll([
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final twoColumns = constraints.maxWidth > 700;
                      return Wrap(
                        spacing: 14,
                        runSpacing: 2,
                        children: [
                          for (final field in _identFields.entries)
                            SizedBox(
                              width: twoColumns
                                  ? (constraints.maxWidth - 14) / 2
                                  : constraints.maxWidth,
                              child: _field(
                                'identificacao.' + field.key,
                                field.value,
                                lines: field.key == 'observacoes' ? 3 : 1,
                              ),
                            ),
                          SizedBox(
                            width: twoColumns
                                ? (constraints.maxWidth - 14) / 2
                                : constraints.maxWidth,
                            child: DropdownButtonFormField<String>(
                              initialValue:
                                  _plan['identificacao']['natureza']
                                      as String? ??
                                  'Obrigatória',
                              decoration: const InputDecoration(
                                labelText: 'Natureza',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'Obrigatória',
                                  child: Text('Obrigatória'),
                                ),
                                DropdownMenuItem(
                                  value: 'Optativa',
                                  child: Text('Optativa'),
                                ),
                              ],
                              onChanged: (value) => setState(
                                () => _plan['identificacao']['natureza'] =
                                    value ?? 'Obrigatória',
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ]),
                _scroll([
                  _field('ementa', 'Ementa', lines: 8),
                  _field('justificativa', 'Justificativa', lines: 10),
                ]),
                _scroll([
                  _field('objetivo_geral', 'Objetivo geral', lines: 8),
                  _field(
                    'objetivos_especificos',
                    'Objetivos específicos',
                    lines: 12,
                  ),
                ]),
                _scroll([
                  _field('programa_teorico', 'Dimensão teórica', lines: 13),
                  _field('programa_pratico', 'Dimensão prática', lines: 10),
                ]),
                _scroll([
                  _field(
                    'metodologia_tecnicas',
                    'Técnicas de ensino',
                    lines: 7,
                  ),
                  _field(
                    'metodologia_recursos',
                    'Recursos didáticos',
                    lines: 6,
                  ),
                  _field(
                    'metodologia_audiovisuais',
                    'Recursos audiovisuais',
                    lines: 5,
                  ),
                ]),
                _scroll([
                  _field(
                    'cronograma_teorico',
                    'Cronograma teórico — data e atividade por linha, separadas por TAB',
                    lines: 8,
                  ),
                  _field(
                    'cronograma_pratico',
                    'Cronograma prático — data e atividade por linha, separadas por TAB',
                    lines: 7,
                  ),
                  TextField(
                    controller: _pastedSchedule,
                    minLines: 5,
                    maxLines: 9,
                    decoration: const InputDecoration(
                      labelText: 'Cole a tabela completa do Moodle/Excel (TSV)',
                      alignLabelWithHint: true,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _importScheduleFromConfigMoodle,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.green,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                          ),
                          icon: const Icon(Icons.school_rounded),
                          label: const Text('Extrair do Config Moodle'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonalIcon(
                        onPressed: _applyPastedSchedule,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        icon: const Icon(Icons.playlist_add_check_rounded),
                        label: const Text('Aplicar tabela colada'),
                      ),
                    ],
                  ),
                ]),
                _scroll([
                  _field('avaliacao_geral', 'Avaliação', lines: 7),
                  _field(
                    'avaliacao_provas',
                    'Calendário e distribuição de pontos',
                    lines: 7,
                  ),
                  _field(
                    'horario_atendimento',
                    'Horário de atendimento',
                    lines: 4,
                  ),
                  _field(
                    'atividade_recuperacao',
                    'Atividade de recuperação',
                    lines: 5,
                  ),
                  _field(
                    'atendimento_especial',
                    'Atendimento especial',
                    lines: 5,
                  ),
                  _field(
                    'bibliografia_basica',
                    'Bibliografia básica — uma referência por linha',
                    lines: 8,
                  ),
                  _field(
                    'bibliografia_complementar',
                    'Bibliografia complementar — uma referência por linha',
                    lines: 8,
                  ),
                ]),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'O item Aprovação será gerado em branco, conforme o modelo do SEI.',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, _readPlan()),
                  icon: const Icon(Icons.save_rounded),
                  label: const Text('Salvar no cadastro'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
