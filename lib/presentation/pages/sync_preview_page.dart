import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/domain/entities/moodle_entities.dart';
import 'package:config_moodle/presentation/controllers/auth_controller.dart';
import 'package:config_moodle/presentation/controllers/config_controller.dart';
import 'package:config_moodle/presentation/controllers/sync_controller.dart';
import 'package:config_moodle/presentation/controllers/theme_controller.dart';
import 'package:config_moodle/presentation/widgets/common_widgets.dart';

class SyncPreviewPage extends StatefulWidget {
  final String courseConfigId;
  const SyncPreviewPage({super.key, required this.courseConfigId});

  @override
  State<SyncPreviewPage> createState() => _SyncPreviewPageState();
}

class _SyncPreviewPageState extends State<SyncPreviewPage> {
  int _step = 0; // 0=links, 1=sync, 2=done
  bool _loading = true;
  bool _syncStarted = false;
  final List<LinkSuggestion> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final configCtrl = context.read<ConfigController>();
    final auth = context.read<AuthController>();
    final sync = context.read<SyncController>();

    await configCtrl.loadById(widget.courseConfigId);
    final config = configCtrl.current;

    if (!auth.isLoggedIn || config == null || config.moodleCourseId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    // Garantir seções Moodle carregadas
    await sync.loadMoodleSections(
      auth.token,
      auth.baseUrl,
      config.moodleCourseId!,
    );
    sync.generateMatches(config);

    // Pular direto para execução (vínculos agora são gerenciados no editor)
    if (mounted) {
      setState(() {
        _step = 1;
        _loading = false;
      });
      _startSync();
    }
  }

  void _startSync() {
    if (_syncStarted) return;
    _syncStarted = true;
    final auth = context.read<AuthController>();
    final configCtrl = context.read<ConfigController>();
    final sync = context.read<SyncController>();
    final config = configCtrl.current!;
    sync.syncToMoodle(auth.token, auth.baseUrl, config);
  }

  Future<void> _confirmLinks() async {
    final configCtrl = context.read<ConfigController>();
    final sync = context.read<SyncController>();

    // Salvar os vínculos escolhidos pelo usuário
    for (final s in _suggestions) {
      if (s.suggestedMoodleId == null) continue;
      if (s.type == LinkSuggestionType.section) {
        await configCtrl.linkSectionToMoodle(s.sectionId, s.suggestedMoodleId!);
      } else if (s.activityId != null) {
        await configCtrl.linkActivityToMoodle(
          s.sectionId,
          s.activityId!,
          s.suggestedMoodleId!,
          moodleModuleName: s.suggestedMoodleName,
        );
      }
    }

    // Recarregar config e regenerar matches com vínculos atualizados
    await configCtrl.loadById(widget.courseConfigId);
    final config = configCtrl.current!;
    sync.generateMatches(config);

    if (mounted) {
      setState(() => _step = 1);
      _startSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final auth = context.watch<AuthController>();
    final configCtrl = context.watch<ConfigController>();
    final syncCtrl = context.watch<SyncController>();
    final config = configCtrl.current;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context, config),
              Expanded(
                child: !auth.isLoggedIn
                    ? const EmptyState(
                        icon: Icons.cloud_off,
                        title: 'Não conectado ao Moodle',
                        subtitle:
                            'Faça login no Moodle pela tela inicial primeiro.',
                      )
                    : _loading || config == null
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.primary,
                        ),
                      )
                    : config.moodleCourseId == null
                    ? const EmptyState(
                        icon: Icons.link_off,
                        title: 'Disciplina não vinculada',
                        subtitle:
                            'Vincule esta configuração a um curso do Moodle primeiro.',
                      )
                    : _step == 0
                    ? _buildLinkConfirmation(context)
                    : _buildSyncProgress(context, syncCtrl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, dynamic config) {
    final stepLabel = _step == 0 ? 'Vincular' : 'Sincronizar';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Voltar',
            icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
            onPressed: () => context.go('/editor/${widget.courseConfigId}'),
          ),
          const SizedBox(width: 8),
          Text(
            'Sincronizar — $stepLabel',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const Spacer(),
          if (config?.moodleCourseName != null)
            StatusChip(
              label: config!.moodleCourseName!,
              color: AppTheme.accentGreen,
              icon: Icons.school,
            ),
        ],
      ),
    );
  }

  // ── Step 0: Confirmação de vínculos ────────────────────────────────────

  Widget _buildLinkConfirmation(BuildContext context) {
    final sync = context.read<SyncController>();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(
            'Itens sem vínculo encontrados. Confirme ou altere as sugestões abaixo:',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            itemCount: _suggestions.length,
            itemBuilder: (context, index) {
              final s = _suggestions[index];
              return _buildSuggestionCard(s, sync, index);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      context.go('/editor/${widget.courseConfigId}'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Cancelar'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: GradientButton(
                  label: 'Confirmar e Sincronizar',
                  icon: Icons.check,
                  onPressed: _confirmLinks,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSuggestionCard(
    LinkSuggestion suggestion,
    SyncController sync,
    int index,
  ) {
    final isSection = suggestion.type == LinkSuggestionType.section;
    final hasMatch = suggestion.suggestedMoodleId != null;
    final scoreColor = suggestion.score > 0.8
        ? AppTheme.accentGreen
        : suggestion.score > 0.5
        ? AppTheme.warning
        : AppTheme.danger;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isSection ? Icons.folder_outlined : Icons.extension,
                  size: 18,
                  color: isSection ? AppTheme.primary : AppTheme.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSection ? 'SEÇÃO' : 'ATIVIDADE',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        suggestion.localName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasMatch)
                  StatusChip(
                    label: '${(suggestion.score * 100).toStringAsFixed(0)}%',
                    color: scoreColor,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.arrow_forward,
                  size: 16,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () => _showMoodlePicker(suggestion, sync, index),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCardAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: hasMatch
                              ? AppTheme.accentGreen.withAlpha(80)
                              : AppTheme.divider,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            hasMatch ? Icons.link : Icons.link_off,
                            size: 16,
                            color: hasMatch
                                ? AppTheme.accentGreen
                                : AppTheme.textSecondary,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              hasMatch
                                  ? suggestion.suggestedMoodleName!
                                  : 'Nenhum — toque para selecionar',
                              style: TextStyle(
                                fontSize: 12,
                                color: hasMatch
                                    ? AppTheme.textPrimary
                                    : AppTheme.textSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: 18,
                            color: AppTheme.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (hasMatch)
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      size: 16,
                      color: AppTheme.danger,
                    ),
                    onPressed: () {
                      setState(() {
                        suggestion.suggestedMoodleId = null;
                        suggestion.suggestedMoodleName = null;
                      });
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showMoodlePicker(
    LinkSuggestion suggestion,
    SyncController sync,
    int index,
  ) async {
    if (suggestion.type == LinkSuggestionType.section) {
      final sections = sync.moodleSections;
      final result = await _showSectionPicker(
        context,
        sections,
        suggestion.suggestedMoodleId,
      );
      if (result != null && mounted) {
        setState(() {
          suggestion.suggestedMoodleId = result.id;
          suggestion.suggestedMoodleName = result.name;
        });
      }
    } else {
      // Atividade — pegar módulos da seção Moodle vinculada
      final configCtrl = context.read<ConfigController>();
      final config = configCtrl.current!;
      final section = config.sections.firstWhere(
        (s) => s.id == suggestion.sectionId,
      );
      MoodleSection? moodleSection;
      if (section.moodleSectionId != null) {
        for (final ms in sync.moodleSections) {
          if (ms.id == section.moodleSectionId) {
            moodleSection = ms;
            break;
          }
        }
      }
      if (moodleSection == null) return;

      final result = await _showModulePicker(
        context,
        moodleSection.modules,
        suggestion.suggestedMoodleId,
      );
      if (result != null && mounted) {
        setState(() {
          suggestion.suggestedMoodleId = result.id;
          suggestion.suggestedMoodleName = result.name;
        });
      }
    }
  }

  Future<MoodleSection?> _showSectionPicker(
    BuildContext context,
    List<MoodleSection> sections,
    int? currentId,
  ) {
    String filter = '';
    return showDialog<MoodleSection>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final lf = filter.toLowerCase();
          final filtered = sections
              .where((s) => lf.isEmpty || s.name.toLowerCase().contains(lf))
              .toList();
          return AlertDialog(
            title: const Text('Selecionar Seção do Moodle'),
            content: SizedBox(
              width: 450,
              height: 350,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Buscar...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setDialogState(() => filter = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final sec = filtered[i];
                        final isSel = sec.id == currentId;
                        return ListTile(
                          dense: true,
                          selected: isSel,
                          leading: Icon(
                            Icons.folder_outlined,
                            size: 20,
                            color: isSel
                                ? AppTheme.accentGreen
                                : AppTheme.textSecondary,
                          ),
                          title: Text(
                            sec.name,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            'Seção ${sec.section} • ${sec.modules.length} atividades',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => Navigator.pop(ctx, sec),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<MoodleModule?> _showModulePicker(
    BuildContext context,
    List<MoodleModule> modules,
    int? currentId,
  ) {
    String filter = '';
    return showDialog<MoodleModule>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final lf = filter.toLowerCase();
          final filtered = modules
              .where(
                (m) =>
                    lf.isEmpty ||
                    m.name.toLowerCase().contains(lf) ||
                    m.modname.toLowerCase().contains(lf),
              )
              .toList();
          return AlertDialog(
            title: const Text('Selecionar Atividade do Moodle'),
            content: SizedBox(
              width: 450,
              height: 350,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Buscar...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setDialogState(() => filter = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final mod = filtered[i];
                        final isSel = mod.id == currentId;
                        return ListTile(
                          dense: true,
                          selected: isSel,
                          leading: Icon(
                            Icons.extension,
                            size: 18,
                            color: isSel
                                ? AppTheme.accentGreen
                                : AppTheme.textSecondary,
                          ),
                          title: Text(
                            mod.name,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '${mod.modname} • ID: ${mod.id}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => Navigator.pop(ctx, mod),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Step 1: Progresso da sincronização ─────────────────────────────────

  Widget _buildSyncProgress(BuildContext context, SyncController syncCtrl) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(40),
        child: GlassCard(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (syncCtrl.syncing)
                const SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(color: AppTheme.primary),
                )
              else
                Icon(
                  syncCtrl.error != null
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle,
                  size: 60,
                  color: syncCtrl.error != null
                      ? Colors.orange
                      : AppTheme.accentGreen,
                ),
              const SizedBox(height: 24),
              Text(
                syncCtrl.progressMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: syncCtrl.progress,
                  backgroundColor: AppTheme.bgCardAlt,
                  color: AppTheme.primary,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(syncCtrl.progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              if (syncCtrl.error != null) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      syncCtrl.error!,
                      style: const TextStyle(
                        color: AppTheme.danger,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: syncCtrl.error!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Log copiado para a área de transferência',
                        ),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text('Copiar log'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                  ),
                ),
              ],
              if (!syncCtrl.syncing) ...[
                const SizedBox(height: 24),
                GradientButton(
                  label: 'Concluído',
                  icon: Icons.done,
                  onPressed: () =>
                      context.go('/editor/${widget.courseConfigId}?reeval=1'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
