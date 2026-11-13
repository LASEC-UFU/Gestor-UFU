import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/template_generator.dart';
import 'package:gestor_ufu/data/web_xlsx_picker.dart';
import 'package:gestor_ufu/domain/entities/academic_term.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/presentation/controllers/config_controller.dart';
import 'package:gestor_ufu/presentation/controllers/auth_controller.dart';
import 'package:gestor_ufu/presentation/controllers/sync_controller.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';
import 'package:gestor_ufu/presentation/widgets/word_table_dialog.dart';
import 'package:gestor_ufu/presentation/widgets/moodle_config_history_dialog.dart';
import 'package:gestor_ufu/presentation/widgets/academic_term_dialog.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _importStatus;
  bool _importStatusIsError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ConfigController>().loadAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final configCtrl = context.watch<ConfigController>();
    final authCtrl = context.watch<AuthController>();
    final df = DateFormat('dd/MM/yyyy');

    // Mostrar erro via SnackBar
    if (configCtrl.error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(configCtrl.error!),
            backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 5),
          ),
        );
      });
    }

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(context, authCtrl),
              _buildAcademicTerm(configCtrl),
              if (_importStatus != null) _buildImportStatusBanner(),
              Expanded(
                child: configCtrl.loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.primary,
                        ),
                      )
                    : configCtrl.configs.isEmpty
                    ? EmptyState(
                        icon: Icons.table_chart_outlined,
                        title: 'Nenhuma configuração',
                        subtitle:
                            'Importe uma planilha ou crie uma nova configuração para começar.',
                        action: GradientButton(
                          label: 'Começar',
                          icon: Icons.add,
                          onPressed: () => _showAddMenu(context),
                        ),
                      )
                    : _buildGrid(context, configCtrl, df),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: configCtrl.configs.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _showAddMenu(context),
              icon: const Icon(Icons.add),
              label: const Text('Novo'),
            )
          : null,
    );
  }

  Widget _buildAppBar(BuildContext context, AuthController authCtrl) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Voltar',
            onPressed: () => context.go('/'),
            icon: const Icon(Icons.arrow_back_rounded),
            color: AppTheme.textSecondary,
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.settings_suggest,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Config Moodle',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const Spacer(),
          // Status Moodle
          GlassCard(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            onTap: () => authCtrl.isLoggedIn
                ? _showMoodleStatus(context, authCtrl)
                : _showLoginDialog(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  authCtrl.isLoggedIn ? Icons.cloud_done : Icons.cloud_off,
                  color: authCtrl.isLoggedIn
                      ? AppTheme.accentGreen
                      : AppTheme.textSecondary,
                  size: 18,
                ),
                SizedBox(width: 8),
                Text(
                  authCtrl.isLoggedIn
                      ? authCtrl.credential!.fullname
                      : 'Conectar ao Moodle',
                  style: TextStyle(
                    color: authCtrl.isLoggedIn
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const ThemeSelector(compact: true),
        ],
      ),
    );
  }

  Widget _buildAcademicTerm(ConfigController controller) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
    child: Row(
      children: [
        Text(
          'Período letivo',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 330,
          child: DropdownButtonFormField<String>(
            key: ValueKey('config-moodle-period-${controller.activeTerm}'),
            initialValue: controller.terms.contains(controller.activeTerm)
                ? controller.activeTerm
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.date_range_rounded),
            ),
            items: controller.terms
                .map(
                  (term) => DropdownMenuItem(
                    value: term,
                    child: Text(
                      AcademicTerm.displayName(term),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (term) {
              if (term != null) controller.setActiveTerm(term);
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          tooltip: 'Criar período letivo',
          onPressed: () => _showCreateTermDialog(controller),
          icon: const Icon(Icons.add_rounded),
        ),
        const SizedBox(width: 8),
        Text(
          'As configurações e novas disciplinas ficam neste período.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),
      ],
    ),
  );

  Future<void> _showCreateTermDialog(ConfigController controller) async {
    final name = await AcademicTermDialog.show(context);
    if (name != null) await controller.createTerm(name);
  }

  Widget _buildImportStatusBanner() {
    final color = _importStatusIsError ? AppTheme.danger : AppTheme.accentGreen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(35),
          border: Border.all(color: color.withAlpha(120)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              _importStatusIsError ? Icons.error_outline : Icons.info_outline,
              color: color,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _importStatus!,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
            ),
            IconButton(
              tooltip: 'Fechar',
              onPressed: () => setState(() => _importStatus = null),
              icon: Icon(Icons.close, size: 18),
              color: AppTheme.textSecondary,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(
    BuildContext context,
    ConfigController ctrl,
    DateFormat df,
  ) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final crossAxisCount = constraints.maxWidth > 1200
              ? 4
              : constraints.maxWidth > 800
              ? 3
              : constraints.maxWidth > 500
              ? 2
              : 1;
          return GridView.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: 1.4,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: ctrl.configs.length,
            itemBuilder: (context, index) {
              final config = ctrl.configs[index];
              return _buildConfigCard(context, config, ctrl, df);
            },
          );
        },
      ),
    );
  }

  Widget _buildConfigCard(
    BuildContext context,
    CourseConfig config,
    ConfigController ctrl,
    DateFormat df,
  ) {
    return GlassCard(
      useGradient: true,
      onTap: () => context.push('/editor/${config.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.table_chart,
                  color: AppTheme.primary,
                  size: 20,
                ),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                color: AppTheme.bgSurface,
                onSelected: (value) async {
                  if (value == 'delete') {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Excluir configuração?'),
                        content: Text(
                          'Tem certeza que deseja excluir "${config.name}"?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancelar'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text(
                              'Excluir',
                              style: TextStyle(color: AppTheme.danger),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) ctrl.deleteConfig(config.id);
                  } else if (value == 'export') {
                    _exportSpreadsheet(context, config.id);
                  } else if (value == 'word') {
                    showWordTableDialog(context, config);
                  } else if (value == 'sync') {
                    context.push('/sync/${config.id}');
                  } else if (value == 'history') {
                    showDialog<void>(
                      context: context,
                      builder: (_) => MoodleConfigHistoryDialog(
                        config: config,
                        controller: ctrl,
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'sync',
                    child: Row(
                      children: [
                        Icon(Icons.sync, size: 18, color: AppTheme.accent),
                        SizedBox(width: 8),
                        Text('Sincronizar Moodle'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'export',
                    child: Row(
                      children: [
                        Icon(
                          Icons.download,
                          size: 18,
                          color: AppTheme.accentGreen,
                        ),
                        SizedBox(width: 8),
                        Text('Exportar XLSX'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'word',
                    child: Row(
                      children: [
                        Icon(
                          Icons.content_paste,
                          size: 18,
                          color: AppTheme.primary,
                        ),
                        SizedBox(width: 8),
                        Text('Tabela Word'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'history',
                    child: Row(
                      children: [
                        Icon(
                          Icons.history_rounded,
                          size: 18,
                          color: AppTheme.accent,
                        ),
                        SizedBox(width: 8),
                        Text('Histórico e backups'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 18, color: AppTheme.danger),
                        SizedBox(width: 8),
                        Text('Excluir'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          Text(
            config.name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            'Início: ${df.format(config.semesterStartDate)}',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              StatusChip(
                label: '${config.sections.length} seções',
                color: AppTheme.accent,
                icon: Icons.view_list,
              ),
              const SizedBox(width: 8),
              if (config.moodleCourseId != null)
                const StatusChip(
                  label: 'Moodle',
                  color: AppTheme.accentGreen,
                  icon: Icons.cloud_done,
                ),
              const Spacer(),
              InkWell(
                onTap: () => showWordTableDialog(context, config),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppTheme.accent.withAlpha(100),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.content_paste,
                        size: 14,
                        color: AppTheme.accent,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Word',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAddMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.add_box, color: AppTheme.primary),
              ),
              title: const Text('Nova Configuração Vazia'),
              subtitle: const Text('Criar do zero'),
              onTap: () {
                Navigator.pop(context);
                _showCreateDialog(context);
              },
            ),
            Divider(color: AppTheme.divider),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.upload_file, color: AppTheme.accent),
              ),
              title: const Text('Importar Planilha'),
              subtitle: const Text('Importar de arquivo .xlsx'),
              onTap: () async {
                _setImportStatus('Abrindo seletor de arquivo...', false);
                if (kIsWeb) {
                  await _importSpreadsheet(context);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  return;
                }
                Navigator.pop(sheetContext);
                await Future<void>.delayed(const Duration(milliseconds: 150));
                if (!mounted) return;
                await _importSpreadsheet(this.context);
              },
            ),
            Divider(color: AppTheme.divider),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.accentGreen.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.file_download,
                  color: AppTheme.accentGreen,
                ),
              ),
              title: const Text('Baixar Planilha Modelo'),
              subtitle: const Text('Gerar template .xlsx com formato correto'),
              onTap: () {
                Navigator.pop(context);
                _downloadTemplate(context);
              },
            ),
            Divider(color: AppTheme.divider),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.cloud_download,
                  color: AppTheme.primary,
                ),
              ),
              title: const Text('Importar do Moodle'),
              subtitle: const Text('Criar config a partir de um curso'),
              onTap: () {
                Navigator.pop(context);
                _importFromMoodle(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nova Configuração'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Nome da disciplina',
            hintText: 'Ex: ININDI 2025/2',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isNotEmpty) {
                context.read<ConfigController>().createEmpty(
                  nameCtrl.text.trim(),
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Criar'),
          ),
        ],
      ),
    );
  }

  Future<void> _importSpreadsheet(BuildContext context) async {
    if (kIsWeb) {
      await _importSpreadsheetWeb(context);
      return;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        dialogTitle: 'Selecionar planilha (.xlsx)',
        withData: true,
      );
    } catch (e) {
      if (context.mounted) {
        _setImportStatus('Erro ao abrir o seletor de arquivo: $e', true);
        _showImportSnackBar(
          context,
          'Erro ao abrir o seletor de arquivo: $e',
          isError: true,
        );
      }
      return;
    }
    if (result == null) {
      if (context.mounted) {
        _setImportStatus('Nenhum arquivo selecionado.', true);
        _showImportSnackBar(
          context,
          'Nenhum arquivo selecionado.',
          isError: true,
        );
      }
      return;
    }

    final file = result.files.single;
    final filePath = file.path;
    final fileBytes = file.bytes;
    if (context.mounted) {
      _setImportStatus(
        'Arquivo recebido: ${file.name}. Preparando importação...',
        false,
      );
      _showImportSnackBar(
        context,
        'Importando "${file.name}"...',
        isError: false,
      );
    }

    try {
      // No web, path é null; usamos bytes diretamente
      if (kIsWeb || filePath == null) {
        if (fileBytes == null) {
          if (context.mounted) {
            _setImportStatus(
              'O navegador não entregou os bytes do arquivo selecionado.',
              true,
            );
            _showImportSnackBar(
              context,
              'Não foi possível ler o arquivo selecionado.',
              isError: true,
            );
          }
          return;
        }
        if (!context.mounted) return;

        final ctrl = context.read<ConfigController>();
        try {
          final duplicates = ctrl.findDuplicatesFromBytes(fileBytes);
          if (duplicates.isNotEmpty && context.mounted) {
            final existing = duplicates.first;
            final action = await showDialog<String>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Configuração já existe'),
                content: Text(
                  'Já existe "${existing.name}" salva.\n'
                  'Deseja substituir a existente ou criar uma nova cópia?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'cancel'),
                    child: const Text('Cancelar'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'new'),
                    child: const Text('Criar nova'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, 'replace'),
                    child: const Text('Substituir'),
                  ),
                ],
              ),
            );
            if (action == null || action == 'cancel') return;
            if (action == 'replace') {
              final ok = await ctrl.importSpreadsheetBytes(
                fileBytes,
                replaceId: existing.id,
              );
              if (context.mounted) _showImportResult(context, ctrl, ok);
              return;
            }
          }
        } catch (_) {}
        final ok = await ctrl.importSpreadsheetBytes(fileBytes);
        if (context.mounted) _showImportResult(context, ctrl, ok);
        return;
      }

      // Desktop: usa filePath
      if (!context.mounted) return;

      final ctrl = context.read<ConfigController>();

      // Verificar se já existe config com mesmo nome
      try {
        final duplicates = ctrl.findDuplicates(filePath);
        if (duplicates.isNotEmpty && context.mounted) {
          final existing = duplicates.first;
          final action = await showDialog<String>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Configuração já existe'),
              content: Text(
                'Já existe "${existing.name}" salva.\n'
                'Deseja substituir a existente ou criar uma nova cópia?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'cancel'),
                  child: const Text('Cancelar'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'new'),
                  child: const Text('Criar nova'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, 'replace'),
                  child: const Text('Substituir'),
                ),
              ],
            ),
          );
          if (action == null || action == 'cancel') return;
          if (action == 'replace') {
            final ok = await ctrl.importSpreadsheet(
              filePath,
              replaceId: existing.id,
            );
            if (context.mounted) _showImportResult(context, ctrl, ok);
            return;
          }
        }
      } catch (_) {
        // Se der erro no parse, deixa seguir normalmente
      }

      final ok = await ctrl.importSpreadsheet(filePath);
      if (context.mounted) _showImportResult(context, ctrl, ok);
    } catch (e) {
      if (context.mounted) {
        _setImportStatus('Erro inesperado ao importar: $e', true);
        _showImportSnackBar(
          context,
          'Erro inesperado ao importar: $e',
          isError: true,
        );
      }
    }
  }

  Future<void> _importSpreadsheetWeb(BuildContext context) async {
    PickedXlsxFile? picked;
    try {
      picked = await pickXlsxFileForWeb();
    } catch (e) {
      if (context.mounted) {
        _setImportStatus('Erro ao ler arquivo no navegador: $e', true);
        _showImportSnackBar(
          context,
          'Erro ao ler arquivo no navegador: $e',
          isError: true,
        );
      }
      return;
    }

    if (picked == null) {
      if (context.mounted) {
        _setImportStatus('Nenhum arquivo selecionado.', true);
        _showImportSnackBar(
          context,
          'Nenhum arquivo selecionado.',
          isError: true,
        );
      }
      return;
    }

    if (!context.mounted) return;
    _setImportStatus(
      'Arquivo recebido: ${picked.name}. Preparando importação...',
      false,
    );
    _showImportSnackBar(
      context,
      'Importando "${picked.name}"...',
      isError: false,
    );

    final ctrl = context.read<ConfigController>();
    try {
      final duplicates = ctrl.findDuplicatesFromBytes(picked.bytes);
      if (duplicates.isNotEmpty && context.mounted) {
        final existing = duplicates.first;
        final action = await showDialog<String>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Configuração já existe'),
            content: Text(
              'Já existe "${existing.name}" salva.\n'
              'Deseja substituir a existente ou criar uma nova cópia?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'new'),
                child: const Text('Criar nova'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, 'replace'),
                child: const Text('Substituir'),
              ),
            ],
          ),
        );
        if (action == null || action == 'cancel') return;
        if (action == 'replace') {
          final ok = await ctrl.importSpreadsheetBytes(
            picked.bytes,
            replaceId: existing.id,
          );
          if (context.mounted) _showImportResult(context, ctrl, ok);
          return;
        }
      }
    } catch (_) {}

    try {
      final ok = await ctrl.importSpreadsheetBytes(picked.bytes);
      if (context.mounted) _showImportResult(context, ctrl, ok);
    } catch (e) {
      if (context.mounted) {
        _setImportStatus('Erro inesperado ao importar: $e', true);
        _showImportSnackBar(
          context,
          'Erro inesperado ao importar: $e',
          isError: true,
        );
      }
    }
  }

  void _showImportResult(BuildContext context, ConfigController ctrl, bool ok) {
    if (ok) {
      _setImportStatus('Planilha importada com sucesso!', false);
      _showImportSnackBar(
        context,
        'Planilha importada com sucesso!',
        isError: false,
      );
      return;
    }
    _setImportStatus(
      ctrl.error ?? 'Não foi possível importar a planilha.',
      true,
    );
    _showImportSnackBar(
      context,
      ctrl.error ?? 'Não foi possível importar a planilha.',
      isError: true,
    );
  }

  void _showImportSnackBar(
    BuildContext context,
    String message, {
    required bool isError,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.danger : AppTheme.accentGreen,
      ),
    );
  }

  void _setImportStatus(String message, bool isError) {
    if (!mounted) return;
    setState(() {
      _importStatus = message;
      _importStatusIsError = isError;
    });
  }

  Future<void> _exportSpreadsheet(BuildContext context, String id) async {
    final bytes = await context.read<ConfigController>().exportSpreadsheetBytes(
      id,
    );
    if (bytes == null || !context.mounted) return;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Salvar planilha',
      fileName: 'config_export.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      bytes: bytes,
    );
    if (result != null && context.mounted) {
      // No desktop, saveFile pode não gravar via bytes; escrever manualmente
      if (!kIsWeb) {
        File(result).writeAsBytesSync(bytes);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Planilha exportada com sucesso!'),
          backgroundColor: AppTheme.accentGreen,
        ),
      );
    }
  }

  Future<void> _downloadTemplate(BuildContext context) async {
    try {
      final bytes = TemplateGenerator.generateTemplate();
      final uint8Bytes = Uint8List.fromList(bytes);
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Salvar planilha modelo',
        fileName: 'template_gestor_ufu.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: uint8Bytes,
      );
      if (result != null && context.mounted) {
        // No desktop, saveFile pode não gravar via bytes
        if (!kIsWeb) {
          File(result).writeAsBytesSync(uint8Bytes);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template salvo com sucesso!'),
            backgroundColor: AppTheme.accentGreen,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao gerar template: $e'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _importFromMoodle(BuildContext context) async {
    final auth = context.read<AuthController>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Faça login no Moodle primeiro.'),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    final syncCtrl = context.read<SyncController>();
    final configCtrl = context.read<ConfigController>();

    // Carregar cursos
    await syncCtrl.loadCourses(auth.token, auth.baseUrl);
    if (!context.mounted) return;

    if (syncCtrl.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao carregar cursos: ${syncCtrl.error}'),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    // Dialog para escolher curso e data do semestre
    final result = await showDialog<_MoodleImportResult>(
      context: context,
      builder: (_) => _MoodleCoursePickerDialog(courses: syncCtrl.courses),
    );

    if (result == null || !context.mounted) return;

    // Construir config
    try {
      final config = await syncCtrl.buildConfigFromMoodle(
        auth.token,
        auth.baseUrl,
        result.course,
        result.semesterStart,
      );
      await configCtrl.saveNewConfig(config);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Importado "${config.name}" com ${config.sections.length} seções.',
            ),
            backgroundColor: AppTheme.accentGreen,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao importar: $e'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  void _showLoginDialog(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;
    final authController = context.read<AuthController>();
    await authController.init();
    if (!context.mounted) return;
    final savedCredential = authController.credential;
    final savedUrl =
        prefs.getString('last_moodle_url') ??
        savedCredential?.moodleUrl ??
        'https://';
    final urlCtrl = TextEditingController(text: savedUrl);
    final userCtrl = TextEditingController(
      text: savedCredential?.username ?? '',
    );
    final passCtrl = TextEditingController(
      text: savedCredential?.password ?? '',
    );

    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) {
          final auth = ctx.watch<AuthController>();
          return AlertDialog(
            title: const Text('Login Moodle'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: urlCtrl,
                    keyboardType: TextInputType.url,
                    onChanged: (value) =>
                        prefs.setString('last_moodle_url', value.trim()),
                    decoration: const InputDecoration(
                      labelText: 'URL do Moodle',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: userCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Usuário',
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Senha',
                      prefixIcon: Icon(Icons.lock),
                    ),
                  ),
                  if (auth.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      auth.error!,
                      style: const TextStyle(color: AppTheme.danger),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: auth.loading
                    ? null
                    : () async {
                        final url = urlCtrl.text.trim();
                        final ok = await auth.login(
                          url,
                          userCtrl.text.trim(),
                          passCtrl.text,
                        );
                        if (ok) {
                          prefs.setString('last_moodle_url', url);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                child: auth.loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Entrar'),
              ),
            ],
          );
        },
      ),
    );
    urlCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
  }

  void _showMoodleStatus(BuildContext context, AuthController auth) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Moodle Conectado'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.person, color: AppTheme.accent, size: 18),
                const SizedBox(width: 8),
                Text(auth.credential!.fullname),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.link, color: AppTheme.accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    auth.credential!.moodleUrl,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              auth.logout();
              Navigator.pop(context);
            },
            child: const Text(
              'Desconectar',
              style: TextStyle(color: AppTheme.danger),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }
}

// ── Helper classes para importação do Moodle ──────────────────────────────

class _MoodleImportResult {
  final MoodleCourse course;
  final DateTime semesterStart;

  _MoodleImportResult({required this.course, required this.semesterStart});
}

class _MoodleCoursePickerDialog extends StatefulWidget {
  final List<MoodleCourse> courses;

  const _MoodleCoursePickerDialog({required this.courses});

  @override
  State<_MoodleCoursePickerDialog> createState() =>
      _MoodleCoursePickerDialogState();
}

class _MoodleCoursePickerDialogState extends State<_MoodleCoursePickerDialog> {
  MoodleCourse? _selected;
  DateTime _semesterStart = DateTime.now();
  String _filter = '';
  final _df = DateFormat('dd/MM/yyyy');

  List<MoodleCourse> get _filtered {
    if (_filter.isEmpty) return widget.courses;
    final lower = _filter.toLowerCase();
    return widget.courses
        .where(
          (c) =>
              c.fullname.toLowerCase().contains(lower) ||
              c.shortname.toLowerCase().contains(lower),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Importar do Moodle'),
      content: SizedBox(
        width: 500,
        height: 450,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'Filtrar cursos',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _filtered.isEmpty
                  ? Center(
                      child: Text(
                        'Nenhum curso encontrado.',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filtered.length,
                      itemBuilder: (_, i) {
                        final course = _filtered[i];
                        final isSelected = _selected?.id == course.id;
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          selectedTileColor: AppTheme.primary.withAlpha(30),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          leading: Icon(
                            isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: isSelected
                                ? AppTheme.primary
                                : AppTheme.textSecondary,
                            size: 20,
                          ),
                          title: Text(
                            course.fullname,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            course.shortname,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          onTap: () => setState(() => _selected = course),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today, color: AppTheme.accent),
              title: Text(_df.format(_semesterStart)),
              subtitle: const Text('Início do semestre'),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _semesterStart,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2035),
                );
                if (picked != null) {
                  setState(() => _semesterStart = picked);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(
                  context,
                  _MoodleImportResult(
                    course: _selected!,
                    semesterStart: _semesterStart,
                  ),
                ),
          child: const Text('Importar'),
        ),
      ],
    );
  }
}
