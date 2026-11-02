import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/domain/entities/course_config.dart';
import 'package:config_moodle/domain/entities/moodle_entities.dart';
import 'package:config_moodle/presentation/controllers/config_controller.dart';
import 'package:config_moodle/presentation/controllers/auth_controller.dart';
import 'package:config_moodle/presentation/controllers/sync_controller.dart';
import 'package:config_moodle/presentation/controllers/theme_controller.dart';
import 'package:config_moodle/core/utils/macro_resolver.dart';
import 'package:config_moodle/presentation/widgets/common_widgets.dart';
import 'package:config_moodle/presentation/widgets/inline_edit_text.dart';
import 'package:config_moodle/presentation/widgets/inline_link_picker.dart';
import 'package:config_moodle/presentation/widgets/word_table_dialog.dart';

class TableEditorPage extends StatefulWidget {
  final String courseConfigId;
  final bool autoEvaluate;
  const TableEditorPage({
    super.key,
    required this.courseConfigId,
    this.autoEvaluate = false,
  });

  @override
  State<TableEditorPage> createState() => _TableEditorPageState();
}

class _TableEditorPageState extends State<TableEditorPage> {
  final _df = DateFormat('dd/MM/yyyy');
  final _dfh = DateFormat('dd/MM/yyyy HH:mm');
  final _scrollController = ScrollController();
  String? _hoveringSectionId;
  bool _allExpanded = true;
  int _expandToggleKey = 0;
  bool _isDraggingSelection = false;
  bool _isDraggingSingle = false;
  String? _hoveringActivityId;
  bool _evaluated = false;
  bool _evaluating = false;
  bool _fabOpen = false;

  // Auto-scroll during drag
  bool _autoScrolling = false;
  double _autoScrollSpeed = 0;

  static const _typesWithTime = {
    'Tarefa',
    'Questionário',
    'Pesquisa',
    'Escolha',
  };

  bool _needsTime(String type) => _typesWithTime.contains(type);

  static const _modnameToType = {
    'assign': 'Tarefa',
    'quiz': 'Questionário',
    'feedback': 'Pesquisa',
    'choice': 'Escolha',
    'forum': 'Fórum',
    'resource': 'Arquivo',
    'url': 'URL',
    'page': 'Página',
    'folder': 'Pasta',
    'wiki': 'Wiki',
    'glossary': 'Glossário',
    'lesson': 'Lição',
    'h5pactivity': 'H5P',
    'data': 'Base de dados',
    'journal': 'Diário',
    'attendance': 'Presença',
    'bigbluebuttonbn': 'ConferênciaWeb',
    'jitsi': 'Jitsi',
    'book': 'Livro',
    'scorm': 'Pacote SCORM',
    'imscp': 'Conteúdo do pacote IMS',
    'simplecertificate': 'Certificado Simples',
    'checklist': 'Checklist',
    'geogebra': 'GeoGebra',
    'workshop': 'Laboratório de Avaliação',
    'survey': 'Pesquisa',
    'hotpot': 'Atividade Hot Potatoes',
    'label': 'Área de texto e mídia',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctrl = context.read<ConfigController>();
      await ctrl.loadById(widget.courseConfigId);
      if (!mounted) return;
      final config = ctrl.current;
      final auth = context.read<AuthController>();
      if (config != null && config.moodleCourseId != null && auth.isLoggedIn) {
        final sync = context.read<SyncController>();
        if (sync.moodleSections.isEmpty) {
          await sync.loadMoodleSections(
            auth.token,
            auth.baseUrl,
            config.moodleCourseId!,
          );
        }
        // Auto-avaliar quando voltando da sincronização
        if (widget.autoEvaluate) {
          await sync.loadMoodleSections(
            auth.token,
            auth.baseUrl,
            config.moodleCourseId!,
          );
          sync.generateMatches(ctrl.current ?? config);
          if (mounted) {
            setState(() {
              _evaluated = true;
              _evaluating = false;
            });
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isDragging => _isDraggingSelection || _isDraggingSingle;

  void _stopAutoScroll() {
    _autoScrolling = false;
    _autoScrollSpeed = 0;
  }

  void _handlePointerMoveDuringDrag(PointerEvent event) {
    if (!_isDragging) {
      _stopAutoScroll();
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    final localY = renderBox.globalToLocal(event.position).dy;
    const edgeZone = 80.0;
    const maxSpeed = 15.0;

    if (localY < edgeZone) {
      // Near top — scroll up
      final ratio = (edgeZone - localY) / edgeZone;
      _autoScrollSpeed = -maxSpeed * ratio;
      _startAutoScroll();
    } else if (localY > size.height - edgeZone) {
      // Near bottom — scroll down
      final ratio = (localY - (size.height - edgeZone)) / edgeZone;
      _autoScrollSpeed = maxSpeed * ratio;
      _startAutoScroll();
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll() {
    if (_autoScrolling) return;
    _autoScrolling = true;
    _autoScrollTick();
  }

  void _autoScrollTick() {
    if (!_autoScrolling || !mounted) return;
    if (!_isDragging) {
      _stopAutoScroll();
      return;
    }
    final sc = _scrollController;
    if (!sc.hasClients) return;
    final newOffset = (sc.offset + _autoScrollSpeed).clamp(
      sc.position.minScrollExtent,
      sc.position.maxScrollExtent,
    );
    sc.jumpTo(newOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoScrollTick());
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final ctrl = context.watch<ConfigController>();
    final config = ctrl.current;
    final auth = context.watch<AuthController>();

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context, config, ctrl, auth),
              if (config != null) _buildDateHeader(context, config, ctrl),
              Expanded(
                child: ctrl.loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.primary,
                        ),
                      )
                    : config == null
                    ? const EmptyState(
                        icon: Icons.error_outline,
                        title: 'Configuração não encontrada',
                        subtitle: 'Volte à tela inicial.',
                      )
                    : config.sections.isEmpty
                    ? EmptyState(
                        icon: Icons.view_list,
                        title: 'Sem seções',
                        subtitle: 'Adicione a primeira seção.',
                        action: GradientButton(
                          label: 'Adicionar Seção',
                          icon: Icons.add,
                          onPressed: () => _showAddSectionDialog(context, ctrl),
                        ),
                      )
                    : Listener(
                        onPointerMove: _handlePointerMoveDuringDrag,
                        child: _buildSectionsList(context, config, ctrl),
                      ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: ctrl.hasSelection
          ? FloatingActionButton.extended(
              heroTag: 'selection_info',
              backgroundColor: AppTheme.accent,
              icon: const Icon(Icons.close),
              label: Text(
                '${ctrl.selectedActivityIds.length} selecionada(s) — arraste pelo handle',
              ),
              onPressed: () => ctrl.clearSelection(),
            )
          : config?.sections.isNotEmpty == true
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Opções expandidas
                if (_fabOpen) ...[
                  _buildFabOption(
                    heroTag: 'add_activity',
                    icon: Icons.post_add,
                    label: 'Adicionar Atividade',
                    color: AppTheme.accent,
                    onPressed: () {
                      setState(() => _fabOpen = false);
                      final firstSection = config!.sections.first;
                      final sectionRefDate = config.semesterStartDate.add(
                        Duration(days: firstSection.referenceDaysOffset),
                      );
                      _showAddActivityDialog(
                        context,
                        firstSection.id,
                        ctrl,
                        sectionRefDate,
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  _buildFabOption(
                    heroTag: 'add_section',
                    icon: Icons.playlist_add,
                    label: 'Adicionar Seção',
                    color: AppTheme.accentGreen,
                    onPressed: () {
                      setState(() => _fabOpen = false);
                      _showAddSectionDialog(context, ctrl);
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                // Botão principal
                FloatingActionButton(
                  heroTag: 'fab_main',
                  onPressed: () => setState(() => _fabOpen = !_fabOpen),
                  child: AnimatedRotation(
                    turns: _fabOpen ? 0.125 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.add),
                  ),
                ),
              ],
            )
          : null,
    );
  }

  Widget _buildFabOption({
    required String heroTag,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(60),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FloatingActionButton.small(
          heroTag: heroTag,
          backgroundColor: color,
          onPressed: onPressed,
          child: Icon(icon, size: 20),
        ),
      ],
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    CourseConfig? config,
    ConfigController ctrl,
    AuthController auth,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Voltar',
            icon: Icon(Icons.arrow_back_rounded, color: AppTheme.textPrimary),
            onPressed: () => context.go('/moodle'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: config != null
                  ? () => _showRenameDialog(context, config, ctrl)
                  : null,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      config != null
                          ? MacroResolver.resolve(
                              config.name,
                              config.semesterStartDate,
                            )
                          : 'Carregando...',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (config != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.edit_outlined,
                        color: AppTheme.accentGreen,
                        size: 18,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (config != null) ...[
            _buildCourseChip(context, config, ctrl, auth),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Tabela Word',
              child: GradientButton(
                icon: Icons.content_paste,
                label: '',
                compact: true,
                gradient: const LinearGradient(
                  colors: [Color(0xFF7E57C2), Color(0xFF5E35B1)],
                ),
                onPressed: () => showWordTableDialog(context, config),
              ),
            ),
            const SizedBox(width: 4),
            if (_evaluating)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.accent,
                ),
              )
            else if (auth.isLoggedIn) ...[
              Tooltip(
                message: 'Desvincular Todos',
                child: GradientButton(
                  icon: Icons.link_off,
                  label: '',
                  compact: true,
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEF5350), Color(0xFFE53935)],
                  ),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Desvincular Todos'),
                        content: const Text(
                          'Remover todos os v\u00ednculos Moodle (se\u00e7\u00f5es e atividades)?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancelar'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.danger,
                            ),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Desvincular'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && mounted) {
                      await ctrl.unlinkAll();
                      setState(() => _evaluated = false);
                    }
                  },
                ),
              ),
              const SizedBox(width: 4),
            ],
            Tooltip(
              message: 'Datas Especiais',
              child: GradientButton(
                icon: Icons.event_busy,
                label: '',
                compact: true,
                gradient: LinearGradient(
                  colors: ctrl.holidayDates.isEmpty
                      ? [const Color(0xFF78909C), const Color(0xFF546E7A)]
                      : [const Color(0xFFFF7043), const Color(0xFFE64A19)],
                ),
                onPressed: () => _showHolidayDatesDialog(context, ctrl),
              ),
            ),
            if (auth.isLoggedIn) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'Avaliar',
                child: GradientButton(
                  icon: Icons.fact_check_outlined,
                  label: '',
                  compact: true,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF42A5F5), Color(0xFF1E88E5)],
                  ),
                  onPressed: () => _runEvaluation(config, auth),
                ),
              ),
              const SizedBox(width: 4),
            ],
            if (auth.isLoggedIn) ...[
              Tooltip(
                message: 'Sincronizar',
                child: Opacity(
                  opacity: _evaluated ? 1.0 : 0.4,
                  child: GradientButton(
                    icon: Icons.sync,
                    label: '',
                    compact: true,
                    gradient: AppTheme.accentGradient,
                    onPressed: _evaluated ? () => _runSync(config, auth) : null,
                  ),
                ),
              ),
            ] else
              Tooltip(
                message: 'Conecte ao Moodle para avaliar e sincronizar',
                child: GradientButton(
                  icon: Icons.cloud_off,
                  label: '',
                  compact: true,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF546E7A), Color(0xFF37474F)],
                  ),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Conecte ao Moodle para avaliar e sincronizar.',
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(width: 8),
            const ThemeSelector(compact: true),
          ],
        ],
      ),
    );
  }

  Future<void> _runEvaluation(CourseConfig config, AuthController auth) async {
    if (config.moodleCourseId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vincule esta configuração a uma disciplina primeiro.',
            ),
          ),
        );
      }
      return;
    }
    setState(() => _evaluating = true);
    try {
      final sync = context.read<SyncController>();
      await sync.loadMoodleSections(
        auth.token,
        auth.baseUrl,
        config.moodleCourseId!,
      );
      sync.generateMatches(config);
      if (mounted) {
        setState(() {
          _evaluated = true;
          _evaluating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _evaluating = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao avaliar: $e')));
      }
    }
  }

  void _runSync(CourseConfig config, AuthController auth) {
    context.push('/sync/${config.id}');
  }

  Widget _buildCourseChip(
    BuildContext context,
    CourseConfig config,
    ConfigController ctrl,
    AuthController auth,
  ) {
    final hasLinked = config.moodleCourseId != null;
    return ActionChip(
      avatar: Icon(
        hasLinked ? Icons.school : Icons.school_outlined,
        size: 18,
        color: hasLinked ? AppTheme.accentGreen : AppTheme.textSecondary,
      ),
      label: Text(
        hasLinked ? (config.moodleCourseName ?? 'Disciplina') : 'Disciplina',
        style: TextStyle(
          fontSize: 12,
          color: hasLinked ? AppTheme.textPrimary : AppTheme.textSecondary,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      onPressed: () => _showCoursePickerDialog(context, config, ctrl, auth),
    );
  }

  void _showCoursePickerDialog(
    BuildContext context,
    CourseConfig config,
    ConfigController ctrl,
    AuthController auth,
  ) async {
    final syncCtrl = context.read<SyncController>();

    // Carregar cursos se ainda não carregados
    if (syncCtrl.courses.isEmpty) {
      await syncCtrl.loadCourses(auth.token, auth.baseUrl);
    }

    if (!context.mounted) return;
    final courses = syncCtrl.courses;
    if (courses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nenhuma disciplina encontrada.')),
      );
      return;
    }

    String filter = '';
    final selected = await showDialog<MoodleCourse>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) {
          final lowerFilter = filter.toLowerCase();
          final filtered = courses
              .where(
                (c) =>
                    lowerFilter.isEmpty ||
                    c.fullname.toLowerCase().contains(lowerFilter) ||
                    c.shortname.toLowerCase().contains(lowerFilter),
              )
              .toList();
          return AlertDialog(
            title: const Text('Selecionar Disciplina'),
            content: SizedBox(
              width: 500,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Buscar...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (v) => setState(() => filter = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        final isSelected = c.id == config.moodleCourseId;
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          leading: Icon(
                            Icons.school,
                            size: 20,
                            color: isSelected
                                ? AppTheme.accentGreen
                                : AppTheme.textSecondary,
                          ),
                          title: Text(
                            c.fullname,
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            c.shortname,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => Navigator.pop(ctx, c),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
            ],
          );
        },
      ),
    );

    if (selected != null && context.mounted) {
      await ctrl.linkMoodleCourse(selected.id, selected.shortname);
      await syncCtrl.loadMoodleSections(auth.token, auth.baseUrl, selected.id);
    }
  }

  Widget _buildDateHeader(
    BuildContext context,
    CourseConfig config,
    ConfigController ctrl,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.calendar_today, color: AppTheme.accent, size: 22),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DATA DE INÍCIO DO SEMESTRE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _df.format(config.semesterStartDate),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accent,
                  ),
                ),
              ],
            ),
            const Spacer(),
            IconButton(
              tooltip: _allExpanded ? 'Recolher todas' : 'Expandir todas',
              icon: Icon(
                _allExpanded ? Icons.unfold_less : Icons.unfold_more,
                color: AppTheme.accent,
              ),
              onPressed: () {
                setState(() {
                  _allExpanded = !_allExpanded;
                  _expandToggleKey++;
                });
              },
            ),
            SizedBox(width: 4),
            GradientButton(
              label: 'Alterar',
              icon: Icons.edit_calendar,
              compact: true,
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: config.semesterStartDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2030),
                  builder: (context, child) {
                    return Theme(
                      data: Theme.of(context).copyWith(
                        datePickerTheme: DatePickerThemeData(
                          backgroundColor: AppTheme.bgSurface,
                          headerBackgroundColor: AppTheme.primary,
                          dayForegroundColor: WidgetStateProperty.all(
                            AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      child: child!,
                    );
                  },
                );
                if (picked != null) {
                  ctrl.updateSemesterStartDate(picked);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  SectionMatch? _findSectionMatch(String sectionId) {
    if (!_evaluated) return null;
    final sync = context.read<SyncController>();
    for (final m in sync.matches) {
      if (m.local.id == sectionId) return m;
    }
    return null;
  }

  ActivityMatch? _findActivityMatch(String sectionId, String activityId) {
    final sm = _findSectionMatch(sectionId);
    if (sm == null) return null;
    for (final am in sm.activityMatches) {
      if (am.local.id == activityId) return am;
    }
    return null;
  }

  Widget _buildMatchChip(
    double score, {
    bool small = false,
    double linkScore = 0,
    double nameScore = 0,
    double posScore = 0,
    bool hasMatch = true,
  }) {
    final pct = (score * 100).toStringAsFixed(0);
    final color = score >= 0.8
        ? AppTheme.accentGreen
        : score > 0.5
        ? AppTheme.warning
        : AppTheme.danger;
    final icon = score >= 0.8
        ? Icons.check_circle
        : score > 0
        ? Icons.warning_amber_rounded
        : Icons.help_outline;

    // Montar hint com os fatores
    final String tooltip;
    if (!hasMatch) {
      tooltip = 'Módulo não encontrado no Moodle';
    } else {
      final hints = <String>[];
      if (linkScore < 1.0) hints.add('Vínculo');
      if (nameScore < 1.0) hints.add('Nome');
      if (posScore < 1.0) hints.add('Posição');
      tooltip = hints.isEmpty ? 'Tudo OK' : 'Pendente: ${hints.join(', ')}';
    }

    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: small ? 14 : 16, color: color),
          const SizedBox(width: 2),
          Text(
            '$pct%',
            style: TextStyle(
              fontSize: small ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionsList(
    BuildContext context,
    CourseConfig config,
    ConfigController ctrl,
  ) {
    return ReorderableListView.builder(
      scrollController: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 80),
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) =>
          Material(color: Colors.transparent, elevation: 0, child: child),
      onReorder: (oldIndex, newIndex) =>
          ctrl.reorderSections(oldIndex, newIndex),
      itemCount: config.sections.length,
      itemBuilder: (context, index) {
        final section = config.sections[index];
        final previousSection = index > 0 ? config.sections[index - 1] : null;
        return KeyedSubtree(
          key: ValueKey(section.id),
          child: _buildSectionTile(
            context,
            section,
            ctrl,
            config.semesterStartDate,
            index,
            previousSection,
          ),
        );
      },
    );
  }

  Widget _buildSectionTile(
    BuildContext context,
    SectionEntry section,
    ConfigController ctrl,
    DateTime semesterStart,
    int index,
    SectionEntry? previousSection,
  ) {
    final isLinked = section.moodleSectionId != null;
    final isHovering = _hoveringSectionId == section.id;
    return DragTarget<Map<String, String>>(
      onWillAcceptWithDetails: (details) {
        if (_hoveringSectionId != section.id) {
          setState(() => _hoveringSectionId = section.id);
        }
        return true;
      },
      onLeave: (_) {
        if (_hoveringSectionId == section.id) {
          setState(() => _hoveringSectionId = null);
        }
      },
      onAcceptWithDetails: (details) {
        setState(() {
          _hoveringSectionId = null;
          _isDraggingSelection = false;
          _isDraggingSingle = false;
          _hoveringActivityId = null;
        });
        _stopAutoScroll();
        final data = details.data;
        final fromSectionId = data['fromSectionId']!;
        final activityId = data['activityId']!;
        if (ctrl.hasSelection) {
          // Append to end of section (row-level targets handle positional drops)
          ctrl.moveSelectedActivities(section.id);
        } else {
          ctrl.moveActivity(fromSectionId, section.id, activityId);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: isHovering
                  ? Border.all(color: AppTheme.accent, width: 2.5)
                  : isLinked
                  ? Border.all(
                      color: AppTheme.accentGreen.withAlpha(120),
                      width: 1.5,
                    )
                  : null,
              boxShadow: isHovering
                  ? [
                      BoxShadow(
                        color: AppTheme.accent.withAlpha(60),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
            child: GlassCard(
              useGradient: true,
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: ValueKey('section_${section.id}_$_expandToggleKey'),
                  initiallyExpanded: _allExpanded,
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: section.visible
                            ? AppTheme.primary.withAlpha(30)
                            : AppTheme.danger.withAlpha(30),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          '${section.orderIndex}',
                          style: TextStyle(
                            color: section.visible
                                ? AppTheme.primary
                                : AppTheme.danger,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  title: InlineEditText(
                    text: MacroResolver.resolve(
                      section.name,
                      semesterStart,
                      semesterStart.add(
                        Duration(days: section.referenceDaysOffset),
                      ),
                    ),
                    editText: section.name,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: section.visible
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      decoration: section.visible
                          ? null
                          : TextDecoration.lineThrough,
                    ),
                    onChanged: (newName) {
                      // Converter datas de volta para macros antes de salvar
                      final sectionRefDate = semesterStart.add(
                        Duration(days: section.referenceDaysOffset),
                      );
                      final macroName = MacroResolver.replaceDatesWithMacros(
                        newName,
                        sectionRefDate,
                      );
                      ctrl.updateSection(section.id, name: macroName);
                    },
                  ),
                  subtitle: Builder(
                    builder: (_) {
                      final sync = context.read<SyncController>();
                      String? moodleSectionName;
                      if (isLinked) {
                        for (final ms in sync.moodleSections) {
                          if (ms.id == section.moodleSectionId) {
                            moodleSectionName = ms.name;
                            break;
                          }
                        }
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            onTap: () => _showSectionLinkPicker(
                              context,
                              section,
                              ctrl,
                              sync,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.link,
                                  size: 13,
                                  color: isLinked
                                      ? AppTheme.accentGreen
                                      : AppTheme.textSecondary.withAlpha(100),
                                ),
                                SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    isLinked
                                        ? (moodleSectionName ??
                                              'ID: ${section.moodleSectionId}')
                                        : 'Sem vínculo — toque para vincular',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isLinked
                                          ? AppTheme.textSecondary
                                          : AppTheme.textSecondary.withAlpha(
                                              100,
                                            ),
                                      fontStyle: isLinked
                                          ? FontStyle.normal
                                          : FontStyle.italic,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isLinked)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: InkWell(
                                      onTap: () => ctrl.linkSectionToMoodle(
                                        section.id,
                                        null,
                                      ),
                                      child: const Icon(
                                        Icons.close,
                                        size: 12,
                                        color: AppTheme.danger,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                Icons.calendar_today,
                                size: 12,
                                color: AppTheme.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _df.format(
                                  semesterStart.add(
                                    Duration(days: section.referenceDaysOffset),
                                  ),
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              if (section.referenceDaysOffset != 0) ...[
                                const SizedBox(width: 8),
                                StatusChip(
                                  label: previousSection == null
                                      ? '+${section.referenceDaysOffset}d'
                                      : '+${section.referenceDaysOffset - previousSection.referenceDaysOffset}d',
                                  color: AppTheme.accent,
                                ),
                              ],
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_evaluated) ...[
                        Builder(
                          builder: (_) {
                            final sm = _findSectionMatch(section.id);
                            if (sm == null) {
                              return const Icon(
                                Icons.help_outline,
                                size: 16,
                                color: AppTheme.danger,
                              );
                            }
                            return _buildMatchChip(
                              sm.score,
                              linkScore: sm.linkScore,
                              nameScore: sm.nameScore,
                              posScore: sm.posScore,
                              hasMatch: sm.moodleSection != null,
                            );
                          },
                        ),
                        SizedBox(width: 4),
                      ],
                      IconButton(
                        icon: Icon(
                          section.visible
                              ? Icons.visibility
                              : Icons.visibility_off,
                          color: section.visible
                              ? AppTheme.accentGreen
                              : AppTheme.textSecondary,
                          size: 20,
                        ),
                        onPressed: () => ctrl.updateSection(
                          section.id,
                          visible: !section.visible,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.calendar_month_outlined,
                          color: AppTheme.accentGreen,
                          size: 20,
                        ),
                        onPressed: () => _showEditSectionDialog(
                          context,
                          section,
                          ctrl,
                          previousSection,
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(
                          Icons.more_vert,
                          color: AppTheme.textSecondary,
                          size: 20,
                        ),
                        color: AppTheme.bgSurface,
                        onSelected: (v) {
                          if (v == 'edit') {
                            _showEditSectionDialog(
                              context,
                              section,
                              ctrl,
                              previousSection,
                            );
                          } else if (v == 'delete') {
                            ctrl.removeSection(section.id);
                          } else if (v == 'add_activity') {
                            _showAddActivityDialog(
                              context,
                              section.id,
                              ctrl,
                              semesterStart.add(
                                Duration(days: section.referenceDaysOffset),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Text('Editar'),
                          ),
                          const PopupMenuItem(
                            value: 'add_activity',
                            child: Text('Adicionar Atividade'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              'Excluir',
                              style: TextStyle(color: AppTheme.danger),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark.withAlpha(120),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: (ctrl.hasSelection || _isDraggingSingle)
                          ? Column(
                              children: [
                                for (
                                  int i = 0;
                                  i < section.activities.length;
                                  i++
                                ) ...[
                                  _buildActivityRowWithDropTarget(
                                    context,
                                    section.id,
                                    section.activities[i],
                                    ctrl,
                                    semesterStart.add(
                                      Duration(
                                        days: section.referenceDaysOffset,
                                      ),
                                    ),
                                    index: i,
                                  ),
                                ],
                                // Drop zone at the bottom of the section
                                DragTarget<Map<String, String>>(
                                  onWillAcceptWithDetails: (_) => true,
                                  onAcceptWithDetails: (details) {
                                    setState(() {
                                      _isDraggingSelection = false;
                                      _isDraggingSingle = false;
                                      _hoveringActivityId = null;
                                    });
                                    _stopAutoScroll();
                                    final data = details.data;
                                    final fromSectionId =
                                        data['fromSectionId']!;
                                    final activityId = data['activityId']!;
                                    if (ctrl.hasSelection) {
                                      ctrl.moveSelectedActivitiesAtIndex(
                                        section.id,
                                        section.activities.length,
                                      );
                                    } else {
                                      ctrl.moveActivityToIndex(
                                        fromSectionId,
                                        section.id,
                                        activityId,
                                        section.activities.length,
                                      );
                                    }
                                  },
                                  builder: (context, candidateData, _) {
                                    return Container(
                                      height: candidateData.isNotEmpty ? 32 : 8,
                                      decoration: candidateData.isNotEmpty
                                          ? BoxDecoration(
                                              border: Border(
                                                top: BorderSide(
                                                  color: AppTheme.accent,
                                                  width: 2,
                                                ),
                                              ),
                                            )
                                          : null,
                                    );
                                  },
                                ),
                              ],
                            )
                          : ReorderableListView(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              buildDefaultDragHandles: false,
                              onReorder: (oldIdx, newIdx) =>
                                  ctrl.reorderActivities(
                                    section.id,
                                    oldIdx,
                                    newIdx,
                                  ),
                              children: [
                                for (
                                  int i = 0;
                                  i < section.activities.length;
                                  i++
                                )
                                  _buildActivityRow(
                                    context,
                                    section.id,
                                    section.activities[i],
                                    ctrl,
                                    semesterStart.add(
                                      Duration(
                                        days: section.referenceDaysOffset,
                                      ),
                                    ),
                                    index: i,
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Wraps _buildActivityRow with a DragTarget for positional drop (selection mode).
  Widget _buildActivityRowWithDropTarget(
    BuildContext context,
    String sectionId,
    ActivityEntry activity,
    ConfigController ctrl,
    DateTime sectionRefDate, {
    required int index,
  }) {
    final isSelected = ctrl.selectedActivityIds.contains(activity.id);

    // Selected items don't need a drop target (they are the dragged items)
    if (isSelected) {
      return _buildActivityRow(
        context,
        sectionId,
        activity,
        ctrl,
        sectionRefDate,
        index: index,
      );
    }

    final isHoveringHere = _hoveringActivityId == activity.id;

    return DragTarget<Map<String, String>>(
      onWillAcceptWithDetails: (details) {
        if (_hoveringActivityId != activity.id) {
          setState(() => _hoveringActivityId = activity.id);
        }
        return true;
      },
      onLeave: (_) {
        if (_hoveringActivityId == activity.id) {
          setState(() => _hoveringActivityId = null);
        }
      },
      onAcceptWithDetails: (details) {
        setState(() {
          _isDraggingSelection = false;
          _isDraggingSingle = false;
          _hoveringActivityId = null;
        });
        _stopAutoScroll();
        final data = details.data;
        final fromSectionId = data['fromSectionId']!;
        final activityId = data['activityId']!;
        if (ctrl.hasSelection) {
          ctrl.moveSelectedActivitiesAtIndex(sectionId, index);
        } else {
          // Single activity positional move
          ctrl.moveActivityToIndex(fromSectionId, sectionId, activityId, index);
        }
      },
      builder: (context, candidateData, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isHoveringHere)
              Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppTheme.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            _buildActivityRow(
              context,
              sectionId,
              activity,
              ctrl,
              sectionRefDate,
              index: index,
            ),
          ],
        );
      },
    );
  }

  Widget _buildActivityRow(
    BuildContext context,
    String sectionId,
    ActivityEntry activity,
    ConfigController ctrl,
    DateTime sectionRefDate, {
    required int index,
  }) {
    final isSelected = ctrl.selectedActivityIds.contains(activity.id);
    final hasSelection = ctrl.hasSelection;

    // Resolver o nome da atividade para verificar datas de feriado
    final resolvedName = MacroResolver.resolve(
      activity.name,
      sectionRefDate,
      null,
      activity.computeOpenDate(sectionRefDate),
      activity.computeCloseDate(sectionRefDate),
    );
    final isHoliday = ctrl.activityMatchesHoliday(resolvedName);
    final isWeekdayMismatch = ctrl.activityWeekdayMismatch(
      activity,
      sectionRefDate,
      resolvedName: resolvedName,
    );

    // During multi-drag, hide all selected items (they appear in the feedback)
    if (_isDraggingSelection && isSelected) {
      return SizedBox(key: ValueKey(activity.id));
    }

    Widget rowContent = Container(
      decoration: isSelected
          ? BoxDecoration(
              color: AppTheme.accent.withAlpha(30),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.accent.withAlpha(100)),
            )
          : isHoliday
          ? BoxDecoration(
              color: AppTheme.danger.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.danger.withAlpha(80)),
            )
          : isWeekdayMismatch
          ? BoxDecoration(
              color: Colors.amber.withAlpha(40),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withAlpha(80)),
            )
          : null,
      padding: (isSelected || isHoliday || isWeekdayMismatch)
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (!hasSelection)
            ReorderableDragStartListener(
              index: index,
              child: Icon(
                Icons.drag_handle,
                size: 18,
                color: AppTheme.textSecondary,
              ),
            )
          else
            Icon(
              isSelected ? Icons.drag_indicator : Icons.drag_handle,
              size: 18,
              color: isSelected ? AppTheme.accent : AppTheme.textSecondary,
            ),
          if (hasSelection)
            Padding(
              padding: EdgeInsets.only(right: 2),
              child: Icon(
                isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 16,
                color: isSelected ? AppTheme.accent : AppTheme.textSecondary,
              ),
            ),
          const SizedBox(width: 4),
          Expanded(
            child: Builder(
              builder: (_) {
                final sync = context.read<SyncController>();
                final isActivityLinked = activity.moodleModuleId != null;
                String? moodleModName;
                if (isActivityLinked) {
                  for (final sec in sync.moodleSections) {
                    for (final mod in sec.modules) {
                      if (mod.id == activity.moodleModuleId) {
                        moodleModName = mod.name;
                        break;
                      }
                    }
                    if (moodleModName != null) break;
                  }
                  // Fallback to stored name when offline
                  moodleModName ??= activity.moodleModuleName;
                }

                // Build available link options (unlinked modules only)
                final config = ctrl.current;
                final usedIds = <int>{};
                if (config != null) {
                  for (final s in config.sections) {
                    for (final a in s.activities) {
                      if (a.id != activity.id && a.moodleModuleId != null) {
                        usedIds.add(a.moodleModuleId!);
                      }
                    }
                  }
                }
                final linkOptions = <LinkOption>[];
                for (final sec in sync.moodleSections) {
                  for (final mod in sec.modules) {
                    if (!usedIds.contains(mod.id)) {
                      linkOptions.add(
                        LinkOption(
                          id: mod.id,
                          label: mod.name,
                          subtitle:
                              '${_modnameToType[mod.modname] ?? mod.modname} • ${sec.name}',
                        ),
                      );
                    }
                  }
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InlineEditText(
                      text: MacroResolver.resolve(
                        activity.name,
                        sectionRefDate,
                        null,
                        activity.computeOpenDate(sectionRefDate),
                        activity.computeCloseDate(sectionRefDate),
                      ),
                      editText: activity.name,
                      style: TextStyle(
                        color: activity.visibility == 1
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 13,
                        decoration: activity.visibility == 0
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                      onChanged: (newName) {
                        final openDate = activity.computeOpenDate(
                          sectionRefDate,
                        );
                        final closeDate = activity.computeCloseDate(
                          sectionRefDate,
                        );
                        final macroName = MacroResolver.replaceDatesWithMacros(
                          newName,
                          sectionRefDate,
                          activityOpenDate: openDate,
                          activityCloseDate: closeDate,
                        );
                        ctrl.updateActivity(
                          sectionId,
                          activity.id,
                          name: macroName,
                        );
                      },
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (isActivityLinked &&
                            activity.activityType.isNotEmpty) ...[
                          StatusChip(
                            label: activity.activityType,
                            color: _activityColor(activity.activityType),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: InlineLinkPicker(
                            currentId: activity.moodleModuleId,
                            currentLabel: moodleModName,
                            isLinked: isActivityLinked,
                            options: linkOptions,
                            onChanged: (newId) {
                              String? type;
                              String? modName;
                              if (newId != null) {
                                for (final sec in sync.moodleSections) {
                                  for (final mod in sec.modules) {
                                    if (mod.id == newId) {
                                      type =
                                          _modnameToType[mod.modname] ??
                                          mod.modname;
                                      modName = mod.name;
                                      break;
                                    }
                                  }
                                  if (type != null) break;
                                }
                              }
                              ctrl.updateActivity(
                                sectionId,
                                activity.id,
                                moodleModuleId: newId,
                                type: newId == null ? '' : type,
                                moodleModuleName: newId == null
                                    ? null
                                    : modName,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          if (activity.openOffsetDays != null) ...[
            Text(
              _formatActivityDate(
                activity.computeOpenDate(sectionRefDate),
                _needsTime(activity.activityType),
              ),
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
            if (activity.closeOffsetDays != null) ...[
              Text(
                ' → ',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
              Text(
                _formatActivityDate(
                  activity.computeCloseDate(sectionRefDate),
                  _needsTime(activity.activityType),
                ),
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            ],
          ],
          if (_evaluated) ...[
            const SizedBox(width: 4),
            Builder(
              builder: (_) {
                final am = _findActivityMatch(sectionId, activity.id);
                if (am == null) {
                  return const Icon(
                    Icons.help_outline,
                    size: 14,
                    color: AppTheme.danger,
                  );
                }
                return _buildMatchChip(
                  am.score,
                  small: true,
                  linkScore: am.linkScore,
                  nameScore: am.nameScore,
                  posScore: am.posScore,
                  hasMatch: am.moodleModule != null,
                );
              },
            ),
          ],
          IconButton(
            icon: Icon(
              switch (activity.visibility) {
                0 => Icons.visibility_off,
                2 => Icons.link,
                _ => Icons.visibility,
              },
              size: 16,
              color: switch (activity.visibility) {
                0 => AppTheme.textSecondary,
                2 => AppTheme.accent,
                _ => AppTheme.accentGreen,
              },
            ),
            tooltip: switch (activity.visibility) {
              0 => 'Oculto na página',
              2 => 'Disponível via link',
              _ => 'Visível na página',
            },
            onPressed: () => ctrl.updateActivity(
              sectionId,
              activity.id,
              visibility: (activity.visibility + 1) % 3,
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.calendar_month_outlined,
              size: 16,
              color: AppTheme.accent,
            ),
            onPressed: () => _showEditActivityDialog(
              context,
              sectionId,
              activity,
              ctrl,
              sectionRefDate,
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              size: 16,
              color: AppTheme.danger,
            ),
            onPressed: () => ctrl.removeActivity(sectionId, activity.id),
          ),
        ],
      ),
    );

    Widget tappableRow = GestureDetector(
      onTap: () {
        final ctrlPressed = HardwareKeyboard.instance.logicalKeysPressed.any(
          (k) =>
              k == LogicalKeyboardKey.controlLeft ||
              k == LogicalKeyboardKey.controlRight,
        );
        if (ctrlPressed || hasSelection) {
          ctrl.toggleActivitySelection(activity.id);
        }
      },
      child: rowContent,
    );

    Widget finalChild;

    if (hasSelection && isSelected) {
      // Selected items are Draggable for cross-section moves
      finalChild = Draggable<Map<String, String>>(
        data: {'fromSectionId': sectionId, 'activityId': activity.id},
        onDragStarted: () => setState(() => _isDraggingSelection = true),
        onDragEnd: (_) {
          setState(() => _isDraggingSelection = false);
          _stopAutoScroll();
        },
        onDraggableCanceled: (_, _) {
          setState(() => _isDraggingSelection = false);
          _stopAutoScroll();
        },
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.accent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.drag_indicator, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  '${ctrl.selectedActivityIds.length} atividade(s)',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        childWhenDragging: const SizedBox.shrink(),
        child: tappableRow,
      );
    } else {
      // Single activity: LongPressDraggable for cross-section moves
      finalChild = LongPressDraggable<Map<String, String>>(
        data: {'fromSectionId': sectionId, 'activityId': activity.id},
        delay: const Duration(milliseconds: 300),
        onDragStarted: () => setState(() => _isDraggingSingle = true),
        onDragEnd: (_) {
          setState(() => _isDraggingSingle = false);
          _stopAutoScroll();
        },
        onDraggableCanceled: (_, _) {
          setState(() => _isDraggingSingle = false);
          _stopAutoScroll();
        },
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.accent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.drag_indicator, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  activity.name.length > 30
                      ? '${activity.name.substring(0, 30)}...'
                      : activity.name,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: tappableRow),
        child: tappableRow,
      );
    }

    return Padding(
      key: ValueKey(activity.id),
      padding: EdgeInsets.only(left: 4, right: 4, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index > 0)
            Divider(height: 1, thickness: 0.5, color: AppTheme.divider),
          if (index > 0) const SizedBox(height: 6),
          finalChild,
        ],
      ),
    );
  }

  Color _activityColor(String type) {
    switch (type) {
      case 'Tarefa':
        return const Color(0xFFFF7043);
      case 'Questionário':
        return const Color(0xFFAB47BC);
      case 'Pesquisa':
        return const Color(0xFF26A69A);
      case 'Escolha':
        return const Color(0xFFEF5350);
      case 'Fórum':
        return AppTheme.primary;
      case 'Arquivo':
        return AppTheme.accent;
      case 'URL':
        return const Color(0xFF42A5F5);
      case 'Página':
        return const Color(0xFF66BB6A);
      case 'Pasta':
        return const Color(0xFFFFCA28);
      case 'Wiki':
        return const Color(0xFF8D6E63);
      case 'Glossário':
        return const Color(0xFF78909C);
      case 'Lição':
        return const Color(0xFF5C6BC0);
      case 'H5P':
      case 'Conteúdo interativo':
        return const Color(0xFF29B6F6);
      case 'Base de dados':
        return const Color(0xFFEC407A);
      case 'Diário':
        return const Color(0xFF9CCC65);
      case 'Presença':
        return const Color(0xFF26C6DA);
      case 'ConferênciaWeb':
      case 'Jitsi':
        return const Color(0xFF7E57C2);
      default:
        return AppTheme.textSecondary;
    }
  }

  static const _activityTypes = [
    DropdownMenuItem(value: 'Tarefa', child: Text('Tarefa')),
    DropdownMenuItem(value: 'Questionário', child: Text('Questionário')),
    DropdownMenuItem(value: 'Pesquisa', child: Text('Pesquisa')),
    DropdownMenuItem(value: 'Escolha', child: Text('Escolha')),
    DropdownMenuItem(value: 'Fórum', child: Text('Fórum')),
    DropdownMenuItem(value: 'Arquivo', child: Text('Arquivo')),
    DropdownMenuItem(value: 'URL', child: Text('URL')),
    DropdownMenuItem(value: 'Página', child: Text('Página')),
    DropdownMenuItem(value: 'Pasta', child: Text('Pasta')),
    DropdownMenuItem(value: 'Wiki', child: Text('Wiki')),
    DropdownMenuItem(value: 'Glossário', child: Text('Glossário')),
    DropdownMenuItem(value: 'Lição', child: Text('Lição')),
    DropdownMenuItem(value: 'H5P', child: Text('H5P')),
    DropdownMenuItem(
      value: 'Conteúdo interativo',
      child: Text('Conteúdo interativo'),
    ),
    DropdownMenuItem(value: 'Base de dados', child: Text('Base de dados')),
    DropdownMenuItem(value: 'Diário', child: Text('Diário')),
    DropdownMenuItem(value: 'Presença', child: Text('Presença')),
    DropdownMenuItem(value: 'ConferênciaWeb', child: Text('ConferênciaWeb')),
    DropdownMenuItem(value: 'Jitsi', child: Text('Jitsi')),
    DropdownMenuItem(value: 'Livro', child: Text('Livro')),
    DropdownMenuItem(value: 'Pacote SCORM', child: Text('Pacote SCORM')),
    DropdownMenuItem(
      value: 'Conteúdo do pacote IMS',
      child: Text('Conteúdo do pacote IMS'),
    ),
    DropdownMenuItem(
      value: 'Certificado Simples',
      child: Text('Certificado Simples'),
    ),
    DropdownMenuItem(value: 'Checklist', child: Text('Checklist')),
    DropdownMenuItem(value: 'GeoGebra', child: Text('GeoGebra')),
    DropdownMenuItem(
      value: 'Laboratório de Avaliação',
      child: Text('Laboratório de Avaliação'),
    ),
    DropdownMenuItem(
      value: 'Laboratório Virtual',
      child: Text('Laboratório Virtual'),
    ),
    DropdownMenuItem(value: 'Quizventure', child: Text('Quizventure')),
    DropdownMenuItem(
      value: 'Atividade Hot Potatoes',
      child: Text('Atividade Hot Potatoes'),
    ),
    DropdownMenuItem(
      value: 'Área de texto e mídia',
      child: Text('Área de texto e mídia'),
    ),
    DropdownMenuItem(value: 'Outro', child: Text('Outro')),
  ];

  void _showAddSectionDialog(BuildContext context, ConfigController ctrl) {
    final nameCtrl = TextEditingController();
    DateTime selectedDate = ctrl.current!.semesterStartDate;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Nova Seção'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nome da seção',
                    hintText: 'Ex: SEMANA 1 - Introdução',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.calendar_today,
                    color: AppTheme.accent,
                  ),
                  title: Text(_df.format(selectedDate)),
                  subtitle: const Text('Data da seção'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: selectedDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                    );
                    if (picked != null) {
                      setState(() => selectedDate = picked);
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
              onPressed: () {
                if (nameCtrl.text.trim().isNotEmpty) {
                  ctrl.addSection(nameCtrl.text.trim(), selectedDate);
                  Navigator.pop(context);
                }
              },
              child: const Text('Adicionar'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditSectionDialog(
    BuildContext context,
    SectionEntry section,
    ConfigController ctrl,
    SectionEntry? previousSection,
  ) {
    final nameCtrl = TextEditingController(text: section.name);
    final isFirst = previousSection == null;
    final displayOffset = isFirst
        ? section.referenceDaysOffset
        : section.referenceDaysOffset - previousSection.referenceDaysOffset;
    final daysCtrl = TextEditingController(text: displayOffset.toString());

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Editar Seção'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Nome'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: daysCtrl,
                  decoration: InputDecoration(
                    labelText: isFirst
                        ? 'Dias a partir do início do semestre'
                        : 'Dias depois do início da sessão anterior',
                    hintText: '0',
                  ),
                  keyboardType: TextInputType.number,
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
              onPressed: () {
                final enteredDays = int.tryParse(daysCtrl.text.trim()) ?? 0;
                final absoluteOffset = isFirst
                    ? enteredDays
                    : previousSection.referenceDaysOffset + enteredDays;
                ctrl.updateSection(
                  section.id,
                  name: nameCtrl.text.trim(),
                  referenceDaysOffset: absoluteOffset,
                );
                Navigator.pop(context);
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatActivityDate(DateTime? date, bool withTime) {
    if (date == null) return 'Sem data';
    return withTime ? _dfh.format(date) : _df.format(date);
  }

  Widget _buildTimeSelector(
    BuildContext context, {
    required String label,
    required int? minutes,
    required ValueChanged<int?> onChanged,
  }) {
    final h = minutes != null ? minutes ~/ 60 : null;
    final m = minutes != null ? minutes % 60 : null;
    final display = minutes != null
        ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}'
        : 'Selecionar';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 28),
      leading: const Icon(Icons.access_time, size: 18, color: AppTheme.accent),
      title: Text(
        display,
        style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
      ),
      subtitle: Text(
        label,
        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
      trailing: minutes != null
          ? IconButton(
              icon: const Icon(Icons.close, size: 16, color: AppTheme.danger),
              onPressed: () => onChanged(null),
            )
          : null,
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: minutes != null
              ? TimeOfDay(hour: h!, minute: m!)
              : const TimeOfDay(hour: 8, minute: 0),
        );
        if (picked != null) {
          onChanged(picked.hour * 60 + picked.minute);
        }
      },
    );
  }

  void _showAddActivityDialog(
    BuildContext context,
    String sectionId,
    ConfigController ctrl,
    DateTime sectionRefDate,
  ) {
    final nameCtrl = TextEditingController();
    final openOffsetCtrl = TextEditingController();
    final closeOffsetCtrl = TextEditingController();
    String type = 'Tarefa';
    String? modality;
    int? openTimeMinutes;
    int? closeTimeMinutes;

    const modalityItems = [
      DropdownMenuItem<String?>(value: null, child: Text('Não informado')),
      DropdownMenuItem<String?>(value: 'Prática', child: Text('Prática')),
      DropdownMenuItem<String?>(value: 'Teórica', child: Text('Teórica')),
    ];

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) {
          final withTime = _needsTime(type);
          final openOffset = int.tryParse(openOffsetCtrl.text);
          final closeOffset = int.tryParse(closeOffsetCtrl.text);
          final openPreview = openOffset != null
              ? sectionRefDate.add(Duration(days: openOffset))
              : null;
          final closePreview = closeOffset != null
              ? sectionRefDate.add(Duration(days: closeOffset))
              : null;
          return AlertDialog(
            title: const Text('Nova Atividade'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nome da atividade',
                      ),
                      autofocus: true,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: type,
                      decoration: InputDecoration(labelText: 'Tipo'),
                      dropdownColor: AppTheme.bgSurface,
                      items: _activityTypes,
                      onChanged: (v) => setState(() => type = v!),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: modality,
                      decoration: InputDecoration(
                        labelText: 'Modalidade',
                        helperText: 'Usada na tabela para Word',
                      ),
                      dropdownColor: AppTheme.bgSurface,
                      items: modalityItems,
                      onChanged: (v) => setState(() => modality = v),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.event,
                          color: AppTheme.accentGreen,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: openOffsetCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Abertura (dias após ref.)',
                              helperText: openPreview != null
                                  ? _df.format(openPreview)
                                  : 'Ref: ${_df.format(sectionRefDate)}',
                              helperStyle: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 11,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    if (withTime && openOffset != null) ...[
                      const SizedBox(height: 4),
                      _buildTimeSelector(
                        ctx,
                        label: 'Hora de abertura',
                        minutes: openTimeMinutes,
                        onChanged: (m) => setState(() => openTimeMinutes = m),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.event_busy,
                          color: AppTheme.danger,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: closeOffsetCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Encerramento (dias após ref.)',
                              helperText: closePreview != null
                                  ? _df.format(closePreview)
                                  : null,
                              helperStyle: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 11,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    if (withTime && closeOffset != null) ...[
                      const SizedBox(height: 4),
                      _buildTimeSelector(
                        ctx,
                        label: 'Hora de encerramento',
                        minutes: closeTimeMinutes,
                        onChanged: (m) => setState(() => closeTimeMinutes = m),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (nameCtrl.text.trim().isNotEmpty) {
                    ctrl.addActivity(
                      sectionId,
                      nameCtrl.text.trim(),
                      type,
                      openOffsetDays: int.tryParse(openOffsetCtrl.text),
                      closeOffsetDays: int.tryParse(closeOffsetCtrl.text),
                      openTimeMinutes: withTime ? openTimeMinutes : null,
                      closeTimeMinutes: withTime ? closeTimeMinutes : null,
                      modality: modality,
                    );
                    Navigator.pop(context);
                  }
                },
                child: const Text('Adicionar'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditActivityDialog(
    BuildContext context,
    String sectionId,
    ActivityEntry activity,
    ConfigController ctrl,
    DateTime sectionRefDate,
  ) {
    final openOffsetCtrl = TextEditingController(
      text: activity.openOffsetDays?.toString() ?? '',
    );
    final closeOffsetCtrl = TextEditingController(
      text: activity.closeOffsetDays?.toString() ?? '',
    );
    final type = activity.activityType;
    int? openTimeMinutes = activity.openTimeMinutes;
    int? closeTimeMinutes = activity.closeTimeMinutes;
    int? expectedWeekday = activity.expectedWeekday;
    String? modality = activity.modality;

    const modalityItems = [
      DropdownMenuItem<String?>(value: null, child: Text('Não informado')),
      DropdownMenuItem<String?>(value: 'Prática', child: Text('Prática')),
      DropdownMenuItem<String?>(value: 'Teórica', child: Text('Teórica')),
    ];

    const weekdayItems = [
      DropdownMenuItem<int?>(value: null, child: Text('Nenhum')),
      DropdownMenuItem<int?>(value: 1, child: Text('Segunda')),
      DropdownMenuItem<int?>(value: 2, child: Text('Terça')),
      DropdownMenuItem<int?>(value: 3, child: Text('Quarta')),
      DropdownMenuItem<int?>(value: 4, child: Text('Quinta')),
      DropdownMenuItem<int?>(value: 5, child: Text('Sexta')),
      DropdownMenuItem<int?>(value: 6, child: Text('Sábado')),
      DropdownMenuItem<int?>(value: 7, child: Text('Domingo')),
    ];

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) {
          final withTime = _needsTime(type);
          final openOffset = int.tryParse(openOffsetCtrl.text);
          final closeOffset = int.tryParse(closeOffsetCtrl.text);
          final openPreview = openOffset != null
              ? sectionRefDate.add(Duration(days: openOffset))
              : null;
          final closePreview = closeOffset != null
              ? sectionRefDate.add(Duration(days: closeOffset))
              : null;
          return AlertDialog(
            title: const Text('Editar Atividade'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      activity.name,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.category_outlined,
                          color: AppTheme.accent,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String?>(
                            initialValue: modality,
                            decoration: InputDecoration(
                              labelText: 'Modalidade',
                              helperText: 'Usada na tabela para Word',
                              helperStyle: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                            items: modalityItems,
                            onChanged: (v) => setState(() => modality = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.event,
                          color: AppTheme.accentGreen,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: openOffsetCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Abertura (dias após ref.)',
                              helperText: openPreview != null
                                  ? _df.format(openPreview)
                                  : 'Ref: ${_df.format(sectionRefDate)}',
                              helperStyle: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 11,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    if (withTime && openOffset != null) ...[
                      const SizedBox(height: 4),
                      _buildTimeSelector(
                        ctx,
                        label: 'Hora de abertura',
                        minutes: openTimeMinutes,
                        onChanged: (m) => setState(() => openTimeMinutes = m),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.event_busy,
                          color: AppTheme.danger,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: closeOffsetCtrl,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Encerramento (dias após ref.)',
                              helperText: closePreview != null
                                  ? _df.format(closePreview)
                                  : null,
                              helperStyle: const TextStyle(
                                color: AppTheme.accent,
                                fontSize: 11,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                    if (withTime && closeOffset != null) ...[
                      const SizedBox(height: 4),
                      _buildTimeSelector(
                        ctx,
                        label: 'Hora de encerramento',
                        minutes: closeTimeMinutes,
                        onChanged: (m) => setState(() => closeTimeMinutes = m),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(
                          Icons.calendar_month,
                          color: Colors.amber,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            initialValue: expectedWeekday,
                            decoration: InputDecoration(
                              labelText: 'Dia da semana esperado',
                              helperText: 'Se não bater, fica amarelo',
                              helperStyle: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                            items: weekdayItems,
                            onChanged: (v) =>
                                setState(() => expectedWeekday = v),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () {
                  ctrl.updateActivity(
                    sectionId,
                    activity.id,
                    openOffsetDays: int.tryParse(openOffsetCtrl.text),
                    closeOffsetDays: int.tryParse(closeOffsetCtrl.text),
                    openTimeMinutes: withTime ? openTimeMinutes : null,
                    closeTimeMinutes: withTime ? closeTimeMinutes : null,
                    expectedWeekday: expectedWeekday,
                    modality: modality,
                  );
                  Navigator.pop(context);
                },
                child: const Text('Salvar'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Shows a picker for linking a section to a Moodle section.
  /// Only shows sections NOT already linked by other config sections.
  void _showSectionLinkPicker(
    BuildContext context,
    SectionEntry section,
    ConfigController ctrl,
    SyncController sync,
  ) {
    final config = ctrl.current;
    if (config == null) return;
    final allMoodleSections = sync.moodleSections;
    if (allMoodleSections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nenhuma seção do Moodle carregada. Faça login primeiro.',
          ),
        ),
      );
      return;
    }

    // Collect already-linked moodle section IDs (excluding this section)
    final usedIds = <int>{};
    for (final s in config.sections) {
      if (s.id != section.id && s.moodleSectionId != null) {
        usedIds.add(s.moodleSectionId!);
      }
    }

    final available = allMoodleSections
        .where((ms) => !usedIds.contains(ms.id))
        .toList();

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Todas as seções já estão vinculadas.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) {
        String filter = '';
        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            final lf = filter.toLowerCase();
            final filtered = available
                .where((s) => lf.isEmpty || s.name.toLowerCase().contains(lf))
                .toList();
            return AlertDialog(
              title: const Text('Vincular Seção'),
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
                      onChanged: (v) => setDlgState(() => filter = v),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final ms = filtered[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.folder_outlined,
                              size: 20,
                              color: AppTheme.textSecondary,
                            ),
                            title: Text(
                              ms.name,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              'Seção ${ms.section} • ${ms.modules.length} atividades',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () {
                              ctrl.linkSectionToMoodle(section.id, ms.id);
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRenameDialog(
    BuildContext context,
    CourseConfig config,
    ConfigController ctrl,
  ) {
    final nameCtrl = TextEditingController(text: config.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Renomear'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Nome'),
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
                ctrl.updateConfigName(nameCtrl.text.trim());
                Navigator.pop(context);
              }
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  void _showHolidayDatesDialog(BuildContext context, ConfigController ctrl) {
    showDialog(
      context: context,
      builder: (_) => _HolidayDatesDialog(ctrl: ctrl),
    );
  }
}

class _HolidayDatesDialog extends StatefulWidget {
  final ConfigController ctrl;
  const _HolidayDatesDialog({required this.ctrl});

  @override
  State<_HolidayDatesDialog> createState() => _HolidayDatesDialogState();
}

class _HolidayDatesDialogState extends State<_HolidayDatesDialog>
    with SingleTickerProviderStateMixin {
  final _df = DateFormat('dd/MM/yyyy');
  late TabController _tabCtrl;

  static const _weekdayNames = [
    '',
    'Segunda',
    'Terça',
    'Quarta',
    'Quinta',
    'Sexta',
    'Sábado',
    'Domingo',
  ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) {
        final holidays = widget.ctrl.holidayDates;
        final swaps = widget.ctrl.daySwapDates;
        final sortedSwapKeys = swaps.keys.toList()
          ..sort((a, b) => a.compareTo(b));
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.event_busy, color: AppTheme.danger),
              const SizedBox(width: 8),
              Text('Datas Especiais'),
            ],
          ),
          content: SizedBox(
            width: 420,
            height: 400,
            child: Column(
              children: [
                TabBar(
                  controller: _tabCtrl,
                  indicatorColor: AppTheme.accent,
                  labelColor: AppTheme.textPrimary,
                  unselectedLabelColor: AppTheme.textSecondary,
                  tabs: const [
                    Tab(text: 'Feriados / Sem aula'),
                    Tab(text: 'Troca de dia'),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TabBarView(
                    controller: _tabCtrl,
                    children: [
                      // ── Tab 1: Feriados ──
                      Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Datas em que não haverá aula.\n'
                                  'Atividades nessas datas ficam em vermelho.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle,
                                  color: AppTheme.accentGreen,
                                ),
                                tooltip: 'Adicionar feriado',
                                onPressed: () => _pickHolidayDate(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Expanded(
                            child: holidays.isEmpty
                                ? Center(
                                    child: Text(
                                      'Nenhum feriado adicionado.',
                                      style: TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: holidays.length,
                                    itemBuilder: (context, index) {
                                      final date = holidays[index];
                                      return ListTile(
                                        dense: true,
                                        leading: const Icon(
                                          Icons.block,
                                          size: 18,
                                          color: AppTheme.danger,
                                        ),
                                        title: Text(
                                          _df.format(date),
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                        subtitle: Text(
                                          _weekdayNames[date.weekday],
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.textSecondary,
                                          ),
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                            color: AppTheme.danger,
                                            size: 20,
                                          ),
                                          onPressed: () => widget.ctrl
                                              .removeHolidayDate(date),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                      // ── Tab 2: Troca de dia ──
                      Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Datas que funcionam como outro dia\n'
                                  'da semana no calendário acadêmico.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle,
                                  color: AppTheme.accentGreen,
                                ),
                                tooltip: 'Adicionar troca de dia',
                                onPressed: () => _pickDaySwapDate(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Expanded(
                            child: sortedSwapKeys.isEmpty
                                ? Center(
                                    child: Text(
                                      'Nenhuma troca de dia adicionada.',
                                      style: TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: sortedSwapKeys.length,
                                    itemBuilder: (context, index) {
                                      final date = sortedSwapKeys[index];
                                      final effectiveWd = swaps[date]!;
                                      final realWd = date.weekday;
                                      return ListTile(
                                        dense: true,
                                        leading: const Icon(
                                          Icons.swap_horiz,
                                          size: 18,
                                          color: Colors.amber,
                                        ),
                                        title: Text(
                                          _df.format(date),
                                          style: const TextStyle(fontSize: 14),
                                        ),
                                        subtitle: Text(
                                          '${_weekdayNames[realWd]} → funciona como ${_weekdayNames[effectiveWd]}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.textSecondary,
                                          ),
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(
                                            Icons.remove_circle_outline,
                                            color: AppTheme.danger,
                                            size: 20,
                                          ),
                                          onPressed: () => widget.ctrl
                                              .removeDaySwapDate(date),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickHolidayDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 3),
      helpText: 'Selecione uma data de feriado',
    );
    if (picked != null) {
      widget.ctrl.addHolidayDate(picked);
    }
  }

  Future<void> _pickDaySwapDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 3),
      helpText: 'Selecione a data que será trocada',
    );
    if (picked == null || !mounted) return;

    // Pedir o dia da semana efetivo
    final weekday = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          'Qual dia da semana ${_df.format(picked)} vai funcionar como?',
          style: const TextStyle(fontSize: 15),
        ),
        children: List.generate(5, (i) {
          final wd = i + 1; // 1=Seg..5=Sex
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, wd),
            child: Text(_weekdayNames[wd]),
          );
        }),
      ),
    );
    if (weekday != null) {
      widget.ctrl.addDaySwapDate(picked, weekday);
    }
  }
}
