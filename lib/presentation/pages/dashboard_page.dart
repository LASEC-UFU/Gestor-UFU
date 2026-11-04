import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/services/preferences_backup_service.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';
import 'package:gestor_ufu/data/services/shared_preferences_sync_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static const _orderKey = 'dashboard.module_order.v1';
  static const _hiddenKey = 'dashboard.hidden_modules.v1';
  static const _modules = <_ModuleInfo>[
    _ModuleInfo(
      title: 'Config Moodle',
      description:
          'Planeje disciplinas, organize atividades e sincronize cursos.',
      icon: Icons.settings_suggest_rounded,
      accent: AppTheme.primary,
      enabled: true,
      route: '/moodle',
      category: 'PLANEJAMENTO DE DISCIPLINAS',
    ),
    _ModuleInfo(
      title: 'Preenche Diários',
      description:
          'Prepare lançamentos de aula usando planilhas ou dados do Moodle.',
      icon: Icons.edit_calendar_rounded,
      accent: AppTheme.accent,
      enabled: true,
      route: '/diario',
      category: 'ROTINA ACADÊMICA',
    ),
    _ModuleInfo(
      title: 'Extrair \u00c1rvore de Processo',
      description:
          'Consulte os documentos de um processo e gere um inventário revisável.',
      icon: Icons.account_tree_rounded,
      accent: Color(0xFFFFB454),
      enabled: true,
      route: '/sei',
      category: 'PROCESSOS E DOCUMENTOS',
    ),

    _ModuleInfo(
      title: 'Planos de Ensino',
      description:
          'Cadastre planos, organize cronogramas e prepare documentos para o SEI.',
      icon: Icons.menu_book_rounded,
      accent: Color(0xFF5DD39E),
      enabled: true,
      route: '/planos-ensino',
      category: 'ENSINO',
    ),
    _ModuleInfo(
      title: 'Planos de Trabalho',
      description:
          'Organize atividades, preencha planilhas e prepare PDFs para o SEI.',
      icon: Icons.assignment_turned_in_rounded,
      accent: Color(0xFFFF7B8B),
      enabled: true,
      route: '/planos-trabalho',
      category: 'GESTÃO DO TRABALHO',
    ),
    _ModuleInfo(
      title: 'Ajusta Horários',
      description: 'Monte grades semanais por curso, período e docente.',
      icon: Icons.schedule_rounded,
      accent: AppTheme.primary,
      enabled: true,
      route: '/ajusta-horarios',
      category: 'PLANEJAMENTO DE DISCIPLINAS',
    ),
    _ModuleInfo(
      title: 'Equivalência de Alunos',
      description:
          'Organize análises de aproveitamento de disciplinas entre cursos.',
      icon: Icons.compare_arrows_rounded,
      accent: Color(0xFF63C9B8),
      enabled: true,
      route: '/equivalencia-alunos',
      category: 'VIDA ACADÊMICA',
    ),
    _ModuleInfo(
      title: 'Inserir Documentos no SEI',
      description:
          'Insira fichas de componentes curriculares no processo do SEI.',
      icon: Icons.topic_rounded,
      accent: Color(0xFFFFB454),
      category: 'PROCESSOS E DOCUMENTOS',
    ),
  ];

  late List<_ModuleInfo> _orderedModules = List.of(_modules);
  Set<String> _hiddenModules = <String>{};

  @override
  void initState() {
    super.initState();
    _loadModuleSettings();
  }

  Future<void> _loadModuleSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedOrder = prefs.getStringList(_orderKey) ?? const <String>[];
    final savedHidden = prefs.getStringList(_hiddenKey) ?? const <String>[];
    final byId = {for (final module in _modules) module.id: module};
    final ordered = <_ModuleInfo>[];
    for (final id in savedOrder) {
      final module = byId.remove(id);
      if (module != null) ordered.add(module);
    }
    ordered.addAll(byId.values);
    if (!mounted) return;
    setState(() {
      _orderedModules = ordered;
      _hiddenModules = savedHidden.toSet();
    });
  }

  Future<void> _openSettings() async {
    final connection = await showDialog<_DatabaseConnectionRequest>(
      context: context,
      builder: (_) => _SharedDatabaseDialog(
        modules: _orderedModules,
        hiddenModules: _hiddenModules,
        onModulesChanged: (modules, hidden) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(
            _orderKey,
            modules.map((module) => module.id).toList(),
          );
          await prefs.setStringList(_hiddenKey, hidden.toList());
          if (!mounted) return;
          setState(() {
            _orderedModules = modules;
            _hiddenModules = hidden;
          });
        },
      ),
    );
    if (connection == null || !mounted) return;
    try {
      await context.read<SharedPreferencesSyncService>().connectToFile(
        filePath: connection.path,
        password: connection.password,
        useSharedFile: connection.useSharedFile,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao conectar o banco: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final horizontalPadding = compact ? 20.0 : 48.0;

              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _DashboardHeader(
                      compact: compact,
                      onSettingsPressed: _openSettings,
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      compact ? 24 : 36,
                      horizontalPadding,
                      28,
                    ),
                    sliver: SliverLayoutBuilder(
                      builder: (context, sliverConstraints) {
                        final width = sliverConstraints.crossAxisExtent;
                        final columns = width >= 1000
                            ? 3
                            : width >= 620
                            ? 2
                            : 1;
                        return SliverGrid.builder(
                          itemCount: _orderedModules
                              .where(
                                (module) => !_hiddenModules.contains(module.id),
                              )
                              .length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 18,
                                crossAxisSpacing: 18,
                                mainAxisExtent: compact ? 232 : 250,
                              ),
                          itemBuilder: (context, index) => _ModuleCard(
                            module: _orderedModules
                                .where(
                                  (module) =>
                                      !_hiddenModules.contains(module.id),
                                )
                                .elementAt(index),
                          ),
                        );
                      },
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1240),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            0,
                            horizontalPadding,
                            30,
                          ),
                          child: const _DashboardFooter(),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({
    required this.compact,
    required this.onSettingsPressed,
  });

  final bool compact;
  final VoidCallback onSettingsPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 20 : 36, 22, compact ? 20 : 36, 0),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withAlpha(65),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ),
          SizedBox(width: 13),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Gestor UFU',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              Text(
                'CENTRAL DE UTILIDADES',
                style: TextStyle(
                  color: AppTheme.textSecondary.withAlpha(210),
                  fontSize: 9,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: onSettingsPressed,
                icon: const Icon(Icons.storage_rounded, size: 17),
                label: const Text('Configurações'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              const SizedBox(width: 10),
              const ThemeSelector(),
            ],
          ),
        ],
      ),
    );
  }
}

class _DatabaseConnectionRequest {
  const _DatabaseConnectionRequest({
    required this.path,
    required this.password,
    required this.useSharedFile,
  });
  final String path;
  final String password;
  final bool useSharedFile;
}

class _SharedDatabaseDialog extends StatefulWidget {
  const _SharedDatabaseDialog({
    required this.modules,
    required this.hiddenModules,
    required this.onModulesChanged,
  });

  final List<_ModuleInfo> modules;
  final Set<String> hiddenModules;
  final Future<void> Function(List<_ModuleInfo>, Set<String>) onModulesChanged;

  @override
  State<_SharedDatabaseDialog> createState() => _SharedDatabaseDialogState();
}

class _SharedDatabaseDialogState extends State<_SharedDatabaseDialog> {
  final _password = TextEditingController();
  String? _path;
  bool _creating = false;
  bool _busy = false;
  String? _message;
  late final List<_ModuleInfo> _modules = List.of(widget.modules);
  late final Set<String> _hiddenModules = Set.of(widget.hiddenModules);

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickExisting() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Escolher banco compartilhado no OneDrive',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: false,
    );
    if (result == null || result.files.single.path == null) return;
    setState(() {
      _path = result.files.single.path;
      _creating = false;
      _message =
          'Ao conectar, escolha usar os dados do arquivo ou publicar os dados deste computador.';
    });
  }

  Future<void> _createFile() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Criar banco compartilhado no OneDrive',
      fileName: 'gestor_ufu_banco_compartilhado.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null) return;
    setState(() {
      _path = path.toLowerCase().endsWith('.json') ? path : '$path.json';
      _creating = true;
      _message =
          'O conteúdo atual deste computador será publicado no novo arquivo.';
    });
  }

  Future<void> _connect({required bool useSharedFile}) async {
    if (_path == null || _password.text.trim().length < 8) {
      setState(
        () => _message =
            'Escolha um arquivo e informe uma senha com pelo menos 8 caracteres.',
      );
      return;
    }
    setState(() => _busy = true);
    Navigator.of(context).pop(
      _DatabaseConnectionRequest(
        path: _path!,
        password: _password.text,
        useSharedFile: useSharedFile,
      ),
    );
  }

  Future<void> _saveModuleSettings() async {
    await widget.onModulesChanged(List.of(_modules), Set.of(_hiddenModules));
    if (mounted) {
      setState(() => _message = 'Prefer\u00eancias da tela inicial salvas.');
    }
  }

  void _reorderModules(int oldIndex, int newIndex) {
    setState(() {
      final module = _modules.removeAt(oldIndex);
      _modules.insert(newIndex, module);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SharedPreferencesSyncService>();
    return AlertDialog(
      title: const Text('Configura\u00e7\u00f5es'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 700,
          maxHeight: MediaQuery.sizeOf(context).height * .76,
        ),
        child: SingleChildScrollView(
          child: SizedBox(
            width: 680,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sync.isConnected
                      ? sync.statusLabel
                      : 'Banco local neste computador',
                ),
                if (sync.filePath != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    sync.filePath!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (sync.status == SharedPreferencesSyncStatus.conflict) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Os dois computadores alteraram os dados desde a última sincronização. Escolha qual versão manter.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () async {
                          await sync.resolveConflict(useSharedFile: true);
                          if (mounted) setState(() {});
                        },
                        child: const Text('Usar arquivo compartilhado'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          await sync.resolveConflict(useSharedFile: false);
                          if (mounted) setState(() {});
                        },
                        child: const Text('Publicar dados deste PC'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pickExisting,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: const Text('Escolher arquivo existente'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _createFile,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Criar banco novo'),
                    ),
                  ],
                ),
                if (_path != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    _path!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Senha compartilhada',
                    helperText:
                        'Use a mesma senha nos dois computadores. Ela protege os dados e credenciais no arquivo.',
                  ),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 10),
                  Text(_message!, style: Theme.of(context).textTheme.bodySmall),
                ],
                const Divider(height: 24),
                Text(
                  'Recursos da tela inicial',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                Text(
                  'Marque os recursos que deseja exibir e arraste para ordenar. Cada linha mostra até três, da esquerda para a direita.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 220,
                  child: ReorderableListView.builder(
                    itemCount: _modules.length,
                    onReorderItem: _reorderModules,
                    buildDefaultDragHandles: false,
                    itemBuilder: (context, index) {
                      final module = _modules[index];
                      final visible = !_hiddenModules.contains(module.id);
                      return ListTile(
                        key: ValueKey(module.id),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Checkbox(
                          value: visible,
                          onChanged: (value) => setState(() {
                            if (value ?? false) {
                              _hiddenModules.remove(module.id);
                            } else {
                              _hiddenModules.add(module.id);
                            }
                          }),
                        ),
                        title: Text(module.title),
                        subtitle: Text(visible ? 'Visível' : 'Oculto'),
                        trailing: ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle_rounded),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (sync.isConnected)
          TextButton(
            onPressed: () async {
              await sync.disconnect();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Desconectar'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fechar'),
        ),
        FilledButton(
          onPressed: _saveModuleSettings,
          child: const Text('Salvar preferências'),
        ),
        if (_path != null && !_creating)
          OutlinedButton(
            onPressed: _busy ? null : () => _connect(useSharedFile: true),
            child: const Text('Usar banco compartilhado'),
          ),
        if (_path != null)
          FilledButton(
            onPressed: _busy ? null : () => _connect(useSharedFile: false),
            child: Text(
              _creating ? 'Criar e conectar' : 'Publicar dados locais',
            ),
          ),
      ],
    );
  }
}

class _ModuleCard extends StatefulWidget {
  const _ModuleCard({required this.module});

  final _ModuleInfo module;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final module = widget.module;
    final enabled = module.enabled;
    final accent = module.accent;

    return MouseRegion(
      onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: enabled ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 180),
        transform: Matrix4.translationValues(0, _hovered ? -4 : 0, 0),
        decoration: BoxDecoration(
          gradient: enabled ? AppTheme.cardGradient : null,
          color: enabled ? null : AppTheme.bgCard.withAlpha(150),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: enabled
                ? accent.withAlpha(_hovered ? 150 : 75)
                : AppTheme.divider.withAlpha(170),
          ),
          boxShadow: enabled && _hovered
              ? [
                  BoxShadow(
                    color: accent.withAlpha(22),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? () => context.go(module.route!) : null,
            borderRadius: BorderRadius.circular(22),
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: accent.withAlpha(enabled ? 36 : 22),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          module.icon,
                          color: enabled ? accent : accent.withAlpha(150),
                          size: 24,
                        ),
                      ),
                      const Spacer(),
                      _ModuleStatus(enabled: enabled),
                    ],
                  ),
                  Spacer(),
                  Text(
                    module.category,
                    style: TextStyle(
                      color: enabled ? accent : AppTheme.textSecondary,
                      fontSize: 9,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 7),
                  Text(
                    module.title,
                    style: TextStyle(
                      color: enabled
                          ? AppTheme.textPrimary
                          : AppTheme.textPrimary.withAlpha(205),
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 7),
                  Text(
                    module.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary.withAlpha(
                        enabled ? 255 : 190,
                      ),
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  SizedBox(height: 15),
                  Row(
                    children: [
                      Text(
                        enabled ? 'Acessar módulo' : 'Disponível em breve',
                        style: TextStyle(
                          color: enabled ? accent : AppTheme.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Spacer(),
                      Icon(
                        enabled
                            ? Icons.arrow_forward_rounded
                            : Icons.lock_outline_rounded,
                        size: 17,
                        color: enabled ? accent : AppTheme.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModuleStatus extends StatelessWidget {
  const _ModuleStatus({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppTheme.accentGreen : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(enabled ? 24 : 18),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withAlpha(enabled ? 75 : 40)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled ? Icons.check_circle_rounded : Icons.schedule_rounded,
            color: color,
            size: 12,
          ),
          const SizedBox(width: 5),
          Text(
            enabled ? 'Disponível' : 'Em breve',
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardFooter extends StatelessWidget {
  const _DashboardFooter();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 12,
      children: [
        SizedBox(
          width: 620,
          child: Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppTheme.accentGreen,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Seus dados ficam armazenados localmente neste computador.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: () => _export(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Exportar dados'),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: () => _import(context),
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('Importar backup'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exportar todos os dados?'),
        content: const Text(
          'O backup inclui configurações, históricos, dados dos diários e credenciais Moodle salvas. Guarde o arquivo em local seguro.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final path = await PreferencesBackupService().exportBackup();
      if (path == null || !context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backup exportado: $path')));
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao exportar backup: $error')),
        );
    }
  }

  Future<void> _import(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Importar backup completo?'),
        content: const Text(
          'A importação substitui todos os dados locais atuais pelos dados do arquivo, inclusive configurações, histórico, diários e credenciais Moodle. Exporte um backup atual antes de continuar, se precisar preservá-lo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Selecionar arquivo'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final result = await PreferencesBackupService().importBackup();
      if (result == null || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Backup ${result.fileName} restaurado. Reinicie o Gestor UFU para recarregar ${result.importedCount} itens.',
          ),
        ),
      );
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao importar backup: $error')),
        );
    }
  }
}

class _ModuleInfo {
  const _ModuleInfo({
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
    required this.category,
    this.enabled = false,
    this.route,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color accent;
  final String category;
  final bool enabled;
  final String? route;

  String get id => route ?? 'module:$title';
}
