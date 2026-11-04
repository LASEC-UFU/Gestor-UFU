import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/presentation/controllers/config_controller.dart';
import 'package:gestor_ufu/presentation/controllers/sync_controller.dart';
import 'package:gestor_ufu/presentation/controllers/auth_controller.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';

class MoodleLinkPage extends StatefulWidget {
  final String courseConfigId;
  const MoodleLinkPage({super.key, required this.courseConfigId});

  @override
  State<MoodleLinkPage> createState() => _MoodleLinkPageState();
}

class _MoodleLinkPageState extends State<MoodleLinkPage> {
  bool _moodleLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctrl = context.read<ConfigController>();
      ctrl.loadById(widget.courseConfigId).then((_) => _loadMoodleContents());
    });
  }

  Future<void> _loadMoodleContents() async {
    final config = context.read<ConfigController>().current;
    final auth = context.read<AuthController>();
    final sync = context.read<SyncController>();

    if (config == null || !auth.isLoggedIn || config.moodleCourseId == null) {
      return;
    }

    await sync.loadMoodleSections(
      auth.token,
      auth.baseUrl,
      config.moodleCourseId!,
    );
    if (mounted) setState(() => _moodleLoaded = true);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final ctrl = context.watch<ConfigController>();
    final sync = context.watch<SyncController>();
    final auth = context.watch<AuthController>();
    final config = ctrl.current;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context, config),
              Expanded(child: _buildBody(context, config, sync, auth, ctrl)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, CourseConfig? config) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Voltar',
            icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
            onPressed: () => context.pop(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Vincular ao Moodle',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          if (config?.moodleCourseName != null)
            StatusChip(
              label: config!.moodleCourseName!,
              color: AppTheme.accent,
              icon: Icons.school,
            ),
          const SizedBox(width: 10),
          const ThemeSelector(compact: true),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    CourseConfig? config,
    SyncController sync,
    AuthController auth,
    ConfigController ctrl,
  ) {
    if (config == null) {
      return const EmptyState(
        icon: Icons.error_outline,
        title: 'Configuração não encontrada',
        subtitle: 'Volte à tela anterior.',
      );
    }

    if (!auth.isLoggedIn) {
      return const EmptyState(
        icon: Icons.lock_outline,
        title: 'Não autenticado',
        subtitle: 'Faça login no Moodle antes de vincular.',
      );
    }

    if (config.moodleCourseId == null) {
      return EmptyState(
        icon: Icons.link_off,
        title: 'Curso não vinculado',
        subtitle: 'Vincule um curso Moodle primeiro na tela de sincronização.',
        action: GradientButton(
          label: 'Ir para Sincronização',
          icon: Icons.sync,
          onPressed: () => context.push('/sync/${config.id}'),
        ),
      );
    }

    if (sync.loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.primary),
            SizedBox(height: 16),
            Text(
              'Carregando conteúdo do Moodle...',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    if (sync.error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Erro ao carregar',
        subtitle: sync.error!,
        action: GradientButton(
          label: 'Tentar novamente',
          icon: Icons.refresh,
          onPressed: _loadMoodleContents,
        ),
      );
    }

    if (!_moodleLoaded || sync.moodleSections.isEmpty) {
      return const EmptyState(
        icon: Icons.cloud_off,
        title: 'Sem conteúdo',
        subtitle: 'Nenhuma seção encontrada no curso Moodle.',
      );
    }

    return _buildLinkList(context, config, sync.moodleSections, ctrl);
  }

  Widget _buildLinkList(
    BuildContext context,
    CourseConfig config,
    List<MoodleSection> moodleSections,
    ConfigController ctrl,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 80),
      itemCount: config.sections.length,
      itemBuilder: (context, index) {
        final section = config.sections[index];
        return _buildSectionLinkCard(
          context,
          config,
          section,
          moodleSections,
          ctrl,
        );
      },
    );
  }

  Widget _buildSectionLinkCard(
    BuildContext context,
    CourseConfig config,
    SectionEntry section,
    List<MoodleSection> moodleSections,
    ConfigController ctrl,
  ) {
    final linkedMoodleSection = moodleSections
        .where((ms) => ms.id == section.moodleSectionId)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        useGradient: true,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: 8),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: linkedMoodleSection != null
                    ? AppTheme.accentGreen.withAlpha(30)
                    : AppTheme.warning.withAlpha(30),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                linkedMoodleSection != null ? Icons.link : Icons.link_off,
                color: linkedMoodleSection != null
                    ? AppTheme.accentGreen
                    : AppTheme.warning,
                size: 20,
              ),
            ),
            title: Text(
              section.name,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            subtitle: _buildSectionDropdown(
              section,
              moodleSections,
              ctrl,
              linkedMoodleSection,
            ),
            children: [
              if (linkedMoodleSection != null)
                ...section.activities.map(
                  (activity) => _buildActivityLinkRow(
                    context,
                    section,
                    activity,
                    linkedMoodleSection,
                    ctrl,
                  ),
                ),
              if (linkedMoodleSection == null && section.activities.isNotEmpty)
                Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Vincule a seção primeiro para vincular as atividades.',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionDropdown(
    SectionEntry section,
    List<MoodleSection> moodleSections,
    ConfigController ctrl,
    MoodleSection? currentLinked,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: DropdownButtonFormField<int?>(
        initialValue: section.moodleSectionId,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppTheme.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppTheme.divider),
          ),
          filled: true,
          fillColor: AppTheme.bgSurface,
          prefixIcon: Icon(Icons.school, size: 16, color: AppTheme.accent),
        ),
        dropdownColor: AppTheme.bgSurface,
        style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        hint: Text(
          'Selecione a seção do Moodle',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
        isExpanded: true,
        items: [
          DropdownMenuItem<int?>(
            value: null,
            child: Text(
              'Nenhuma (desvincular)',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontStyle: FontStyle.italic,
                fontSize: 12,
              ),
            ),
          ),
          ...moodleSections.map(
            (ms) => DropdownMenuItem<int?>(
              value: ms.id,
              child: Text(
                '${ms.section} - ${ms.name}',
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: (moodleId) {
          ctrl.linkSectionToMoodle(section.id, moodleId);
        },
      ),
    );
  }

  Widget _buildActivityLinkRow(
    BuildContext context,
    SectionEntry section,
    ActivityEntry activity,
    MoodleSection moodleSection,
    ConfigController ctrl,
  ) {
    final linked = moodleSection.modules
        .where((m) => m.id == activity.moodleModuleId)
        .firstOrNull;

    return Padding(
      padding: EdgeInsets.only(left: 12, right: 4, bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            linked != null ? Icons.check_circle : Icons.radio_button_unchecked,
            color: linked != null
                ? AppTheme.accentGreen
                : AppTheme.textSecondary,
            size: 16,
          ),
          const SizedBox(width: 8),
          StatusChip(label: activity.activityType, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.name,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                DropdownButtonFormField<int?>(
                  initialValue: activity.moodleModuleId,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: AppTheme.divider),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: AppTheme.divider),
                    ),
                    filled: true,
                    fillColor: AppTheme.bgCard,
                  ),
                  dropdownColor: AppTheme.bgSurface,
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 11),
                  hint: Text(
                    'Selecione módulo Moodle',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  isExpanded: true,
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(
                        'Nenhum (desvincular)',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontStyle: FontStyle.italic,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    ...moodleSection.modules.map(
                      (mod) => DropdownMenuItem<int?>(
                        value: mod.id,
                        child: Text(
                          '${mod.name} (${mod.modname})',
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (moduleId) {
                    final modName = moduleId == null
                        ? null
                        : moodleSection.modules
                              .where((m) => m.id == moduleId)
                              .map((m) => m.name)
                              .firstOrNull;
                    ctrl.linkActivityToMoodle(
                      section.id,
                      activity.id,
                      moduleId,
                      moodleModuleName: modName,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
