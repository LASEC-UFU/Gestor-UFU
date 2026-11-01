import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/data/services/ajusta_horarios_pdf_service.dart';
import 'package:config_moodle/data/services/ajusta_horarios_store.dart';
import 'package:config_moodle/domain/entities/ajusta_horarios.dart';

class AjustaHorariosPage extends StatefulWidget {
  const AjustaHorariosPage({super.key});
  @override
  State<AjustaHorariosPage> createState() => _AjustaHorariosPageState();
}

class _AjustaHorariosPageState extends State<AjustaHorariosPage> {
  final _store = AjustaHorariosStore();
  final _pdfService = AjustaHorariosPdfService();
  static const _termKey = 'ajusta_horarios_periodo_letivo';
  static const _termsKey = 'ajusta_horarios_periodos_letivos';
  static const _distributionKey = 'ajusta_horarios_distribuicao_docente';
  static const _hiddenDistributionTeachersKey =
      'ajusta_horarios_docentes_ocultos_distribuicao';
  static const _programKey = 'ajusta_horarios_curso_selecionado';
  static const _programsKey = 'ajusta_horarios_cursos';
  static const _periodKey = 'ajusta_horarios_periodo_selecionado';
  static const _viewKey = 'ajusta_horarios_visao_selecionada';
  static const _teacherKey = 'ajusta_horarios_docente_selecionado';
  static const _scrollPrefix = 'ajusta_horarios_grade_scroll_';
  final _courseVerticalScroll = ScrollController();
  final _courseHorizontalScroll = ScrollController();
  final _teacherVerticalScroll = ScrollController();
  final _teacherHorizontalScroll = ScrollController();
  final _distributionHorizontalScroll = ScrollController();
  final Map<String, double> _scrollOffsets = {};
  Timer? _scrollSaveTimer;
  List<HorarioDisciplina> _entries = [];
  Map<int, String> _programs = {...horarioProgramas};
  List<_TeacherDistributionRecord> _distributionRecords = [];
  Set<String> _hiddenDistributionTeachers = {};
  bool _loading = true;
  bool _busy = false;
  int _program = 1;
  int _period = 1;
  int _view = 0;
  String? _teacher;
  List<String> _terms = [AjustaHorariosStore.defaultTerm];
  String _term = AjustaHorariosStore.defaultTerm;

  String _termScopedKey(String key, String term) {
    final token = base64Url
        .encode(utf8.encode(term.trim()))
        .replaceAll('=', '');
    return '${key}_$token';
  }

  @override
  void initState() {
    super.initState();
    for (final entry in <String, ScrollController>{
      'curso_y': _courseVerticalScroll,
      'curso_x': _courseHorizontalScroll,
      'docente_y': _teacherVerticalScroll,
      'docente_x': _teacherHorizontalScroll,
    }.entries) {
      entry.value.addListener(() => _trackScroll(entry.key, entry.value));
    }
    _load();
  }

  @override
  void dispose() {
    _scrollSaveTimer?.cancel();
    _courseVerticalScroll.dispose();
    _courseHorizontalScroll.dispose();
    _teacherVerticalScroll.dispose();
    _teacherHorizontalScroll.dispose();
    _distributionHorizontalScroll.dispose();
    super.dispose();
  }

  void _trackScroll(String key, ScrollController controller) {
    if (!controller.hasClients) return;
    _scrollOffsets[key] = controller.offset;
    _scrollSaveTimer?.cancel();
    _scrollSaveTimer = Timer(const Duration(milliseconds: 300), () async {
      final prefs = await SharedPreferences.getInstance();
      for (final item in _scrollOffsets.entries) {
        await prefs.setDouble('$_scrollPrefix${item.key}', item.value);
      }
    });
  }

  Future<void> _saveViewSelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_programKey, _program);
    await prefs.setInt(_periodKey, _period);
    await prefs.setInt(_viewKey, _view);
    if (_teacher != null) await prefs.setString(_teacherKey, _teacher!);
  }

  void _restoreCurrentTableScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _view > 1) return;
      final vertical = _view == 0
          ? _courseVerticalScroll
          : _teacherVerticalScroll;
      final horizontal = _view == 0
          ? _courseHorizontalScroll
          : _teacherHorizontalScroll;
      _restoreScroll(vertical, _view == 0 ? 'curso_y' : 'docente_y');
      _restoreScroll(horizontal, _view == 0 ? 'curso_x' : 'docente_x');
    });
  }

  void _restoreScroll(ScrollController controller, String key) {
    if (!controller.hasClients) return;
    final offset = (_scrollOffsets[key] ?? 0)
        .clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        )
        .toDouble();
    controller.jumpTo(offset);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedTerm = prefs.getString(_termKey)?.trim();
      final terms = (prefs.getStringList(_termsKey) ?? const <String>[])
          .map((term) => term.trim())
          .where((term) => term.isNotEmpty)
          .toSet()
          .toList();
      if (savedTerm?.isNotEmpty == true && !terms.contains(savedTerm)) {
        terms.add(savedTerm!);
      }
      if (terms.isEmpty) terms.add(AjustaHorariosStore.defaultTerm);
      final activeTerm = savedTerm != null && terms.contains(savedTerm)
          ? savedTerm
          : terms.first;
      await prefs.setStringList(_termsKey, terms);
      await prefs.setString(_termKey, activeTerm);
      final rows = await _store.load(term: activeTerm);
      final savedTeacher = prefs.getString(_teacherKey);
      final savedDistribution = prefs.getString(
        _termScopedKey(_distributionKey, activeTerm),
      );
      final distribution = savedDistribution == null
          ? <_TeacherDistributionRecord>[]
          : (jsonDecode(savedDistribution) as List)
                .map(
                  (item) => _TeacherDistributionRecord.fromJson(
                    Map<String, dynamic>.from(item as Map),
                  ),
                )
                .toList();
      final hiddenTeachers =
          prefs
              .getStringList(
                _termScopedKey(_hiddenDistributionTeachersKey, activeTerm),
              )
              ?.toSet() ??
          {};
      final savedPrograms = prefs.getString(_programsKey);
      final programs = savedPrograms == null
          ? {...horarioProgramas}
          : (jsonDecode(savedPrograms) as Map<String, dynamic>).map(
              (key, value) => MapEntry(int.parse(key), value.toString()),
            );
      final usablePrograms = programs.isEmpty
          ? {...horarioProgramas}
          : programs;
      final savedProgram = prefs.getInt(_programKey) ?? _program;
      if (mounted) {
        setState(() {
          _entries = rows;
          _terms = terms;
          _term = activeTerm;
          _programs = usablePrograms;
          _distributionRecords = distribution;
          _hiddenDistributionTeachers = hiddenTeachers;
          _program = usablePrograms.containsKey(savedProgram)
              ? savedProgram
              : usablePrograms.keys.first;
          _period = (prefs.getInt(_periodKey) ?? _period).clamp(1, 11).toInt();
          _view = (prefs.getInt(_viewKey) ?? _view).clamp(0, 2).toInt();
          _teacher = savedTeacher;
          for (final key in const [
            'curso_y',
            'curso_x',
            'docente_y',
            'docente_x',
          ]) {
            _scrollOffsets[key] = prefs.getDouble('$_scrollPrefix$key') ?? 0;
          }
          _loading = false;
        });
        _restoreCurrentTableScroll();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      _message('Não foi possível carregar a base de horários: $e');
    }
  }

  Future<void> _persist() async {
    setState(() => _busy = true);
    try {
      await _store.save(_entries, term: _term);
    } catch (e) {
      _message('Não foi possível salvar as alterações: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePrograms() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _programsKey,
      jsonEncode({
        for (final entry in _programs.entries) '${entry.key}': entry.value,
      }),
    );
  }

  Future<void> _managePrograms() async {
    final programs = Map<int, String>.from(_programs);
    final controller = TextEditingController();
    void addProgram(StateSetter setDialogState) {
      final name = controller.text.trim();
      if (name.isEmpty) return;
      if (programs.values.any(
        (value) => value.toLowerCase() == name.toLowerCase(),
      )) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Esse curso já está cadastrado.')),
        );
        return;
      }
      setDialogState(() {
        final id = programs.keys.isEmpty
            ? 1
            : programs.keys.reduce((a, b) => a > b ? a : b) + 1;
        programs[id] = name;
        controller.clear();
      });
    }

    final result = await showDialog<Map<int, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Editar cursos'),
          content: SizedBox(
            width: 520,
            height: 460,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        decoration: const InputDecoration(
                          labelText: 'Nome do curso',
                          prefixIcon: Icon(Icons.school_outlined),
                        ),
                        onSubmitted: (_) => addProgram(setDialogState),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Adicionar curso',
                      onPressed: () => addProgram(setDialogState),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      for (final entry
                          in programs.entries.toList()
                            ..sort((a, b) => a.key.compareTo(b.key)))
                        ListTile(
                          leading: CircleAvatar(child: Text('${entry.key}')),
                          title: Text(entry.value),
                          trailing: IconButton(
                            tooltip: 'Remover curso',
                            onPressed: programs.length <= 1
                                ? null
                                : () async {
                                    final confirmed = await showDialog<bool>(
                                      context: dialogContext,
                                      builder: (confirmContext) => AlertDialog(
                                        title: const Text('Remover curso?'),
                                        content: Text(
                                          'O curso "${entry.value}" será removido das grades. As disciplinas e os demais cursos serão mantidos.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(
                                              confirmContext,
                                              false,
                                            ),
                                            child: const Text('Cancelar'),
                                          ),
                                          FilledButton(
                                            onPressed: () => Navigator.pop(
                                              confirmContext,
                                              true,
                                            ),
                                            child: const Text('Remover'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed == true) {
                                      setDialogState(
                                        () => programs.remove(entry.key),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, programs),
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    final removed = _programs.keys.toSet().difference(result.keys.toSet());
    setState(() {
      _programs = result;
      if (!_programs.containsKey(_program)) _program = _programs.keys.first;
      _entries = _entries
          .map(
            (entry) => removed.isEmpty
                ? entry
                : entry.copyWith(
                    coursePeriods: entry.coursePeriods
                        .where((item) => !removed.contains(item.program))
                        .toList(),
                  ),
          )
          .toList();
    });
    await _savePrograms();
    await _saveViewSelection();
    if (removed.isNotEmpty) await _persist();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  List<HorarioDisciplina> get _periodEntries => _entries
      .where(
        (entry) => entry.coursePeriods.any(
          (item) => item.program == _program && item.period == _period,
        ),
      )
      .toList();
  List<String> get _teachers =>
      _entries
          .expand((entry) => entry.teacherNames)
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  Map<String, List<HorarioDisciplina>> _schedule({
    int? program,
    int? period,
    String? teacher,
  }) {
    final result = <String, List<HorarioDisciplina>>{};
    for (final entry in _entries) {
      final include = teacher != null
          ? entry.teacherNames.contains(teacher)
          : entry.coursePeriods.any(
              (item) => item.program == program && item.period == period,
            );
      if (!include) continue;
      for (final slot in entry.slots) {
        result.putIfAbsent(slot.key, () => []).add(entry);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _header(compact),
                    Expanded(
                      child: _view == 0
                          ? _courseView(compact)
                          : _view == 1
                          ? _teacherView(compact)
                          : _distributionView(compact),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header(bool compact) => Padding(
    padding: EdgeInsets.fromLTRB(compact ? 16 : 30, 14, compact ? 16 : 30, 8),
    child: Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Voltar',
              onPressed: () => context.go('/'),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            _icon(Icons.calendar_month_rounded, AppTheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ajusta Hor\u00e1rios',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'MONTAGEM E EDI\u00c7\u00c3O DE GRADES',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 9,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (!compact) _termSelector(),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _busy ? null : _importDatabase,
              tooltip: 'Importar base da planilha',
              icon: const Icon(Icons.upload_file_rounded),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(
              onPressed: _busy ? null : _exportPdf,
              tooltip: 'Exportar grade em PDF',
              icon: const Icon(Icons.download_rounded),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(
              onPressed: _busy ? null : _exportSchedule,
              tooltip: 'Exportar grade em CSV',
              icon: const Icon(Icons.table_chart_rounded),
            ),
          ],
        ),
        if (compact)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 54, top: 8),
              child: _termSelector(),
            ),
          ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.grid_view_rounded),
                    label: Text('Grade por curso'),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.person_outline_rounded),
                    label: Text('Grade por docente'),
                  ),
                  ButtonSegment(
                    value: 2,
                    icon: Icon(Icons.groups_2_outlined),
                    label: Text('Distribui\u00e7\u00e3o Docente'),
                  ),
                ],
                selected: {_view},
                onSelectionChanged: (v) {
                  setState(() {
                    _view = v.first;
                    if (_teachers.isNotEmpty) _teacher ??= _teachers.first;
                  });
                  _saveViewSelection();
                  _restoreCurrentTableScroll();
                },
              ),
            ),
            const SizedBox(width: 12),
            _infoPill(
              Icons.menu_book_rounded,
              '${_entries.length} disciplinas',
            ),
          ],
        ),
      ],
    ),
  );

  Widget _termSelector() => InkWell(
    onTap: _manageTerms,
    borderRadius: BorderRadius.circular(14),
    child: _infoPill(Icons.date_range_rounded, _term),
  );

  Future<void> _manageTerms() async {
    const createNew = '__create_new_term__';
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Per\u00edodos letivos'),
        content: SizedBox(
          width: 440,
          height: 360,
          child: ListView.separated(
            itemCount: _terms.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final term = _terms[index];
              final active = term == _term;
              return ListTile(
                leading: Icon(
                  active ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: active ? AppTheme.primary : AppTheme.textSecondary,
                ),
                title: Text(term),
                subtitle: active ? const Text('Em uso') : null,
                onTap: () => Navigator.pop(dialogContext, term),
              );
            },
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, createNew),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Novo per\u00edodo letivo'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    if (selected != createNew) {
      await _activateTerm(selected);
      return;
    }
    if (!mounted) return;

    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Criar per\u00edodo letivo'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nome do per\u00edodo letivo',
              hintText: 'Ex.: 1\u00ba semestre de 2027',
            ),
            onSubmitted: (text) => Navigator.pop(dialogContext, text.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Criar e usar'),
          ),
        ],
      ),
    );
    controller.dispose();
    final newTerm = value?.trim() ?? '';
    if (newTerm.isEmpty || !mounted) return;

    final existing = _terms.cast<String?>().firstWhere(
      (term) => term?.toLowerCase() == newTerm.toLowerCase(),
      orElse: () => null,
    );
    final term = existing ?? newTerm;
    if (existing == null) {
      final copyChoice = await showDialog<_TermCopyChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Como iniciar $term?'),
          content: SizedBox(
            width: 440,
            height: 360,
            child: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.note_add_outlined),
                  title: const Text('Começar em branco'),
                  subtitle: const Text('Criar uma grade sem disciplinas.'),
                  onTap: () => Navigator.pop(
                    dialogContext,
                    const _TermCopyChoice.blank(),
                  ),
                ),
                const Divider(height: 1),
                for (final sourceTerm in _terms)
                  ListTile(
                    leading: const Icon(Icons.content_copy_rounded),
                    title: Text('Copiar de $sourceTerm'),
                    subtitle: const Text(
                      'Usar a grade atual como ponto de partida.',
                    ),
                    onTap: () => Navigator.pop(
                      dialogContext,
                      _TermCopyChoice.copy(sourceTerm),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      );
      if (copyChoice == null || !mounted) return;
      if (copyChoice.sourceTerm != null) {
        await _copyTermData(copyChoice.sourceTerm!, term);
      }
      final updatedTerms = [..._terms, term];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_termsKey, updatedTerms);
      if (mounted) setState(() => _terms = updatedTerms);
    }
    await _activateTerm(term);
  }

  Future<void> _copyTermData(String source, String destination) async {
    final entries = await _store.load(term: source);
    await _store.save(entries, term: destination);
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      _distributionKey,
      _hiddenDistributionTeachersKey,
    ]) {
      final value = prefs.get(_termScopedKey(key, source));
      if (value is String) {
        await prefs.setString(_termScopedKey(key, destination), value);
      } else if (value is List<String>) {
        await prefs.setStringList(_termScopedKey(key, destination), value);
      }
    }
  }

  Future<void> _activateTerm(String term) async {
    if (term == _term) return;
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_termKey, term);
      final rows = await _store.load(term: term);
      final savedDistribution = prefs.getString(
        _termScopedKey(_distributionKey, term),
      );
      final distribution = savedDistribution == null
          ? <_TeacherDistributionRecord>[]
          : (jsonDecode(savedDistribution) as List)
                .map(
                  (item) => _TeacherDistributionRecord.fromJson(
                    Map<String, dynamic>.from(item as Map),
                  ),
                )
                .toList();
      final hidden =
          prefs
              .getStringList(
                _termScopedKey(_hiddenDistributionTeachersKey, term),
              )
              ?.toSet() ??
          <String>{};
      final names = rows.expand((entry) => entry.teacherNames).toSet();
      final savedTeacher = prefs.getString(_teacherKey);
      if (!mounted) return;
      setState(() {
        _term = term;
        _entries = rows;
        _distributionRecords = distribution;
        _hiddenDistributionTeachers = hidden;
        _period = 1;
        _teacher = names.contains(savedTeacher)
            ? savedTeacher
            : (names.isEmpty ? null : names.first);
        _loading = false;
      });
      await prefs.setInt(_periodKey, 1);
      if (_teacher != null) await prefs.setString(_teacherKey, _teacher!);
      _restoreCurrentTableScroll();
    } catch (error) {
      if (mounted) setState(() => _loading = false);
      _message('N\u00e3o foi poss\u00edvel abrir este per\u00edodo: $error');
    }
  }

  Widget _courseView(bool compact) {
    final schedule = _schedule(program: _program, period: _period);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 30,
        12,
        compact ? 16 : 30,
        24,
      ),
      child: Column(
        children: [
          _controlPanel(compact),
          const SizedBox(height: 16),
          Expanded(
            child: _entries.isEmpty
                ? _emptyState(
                    'Nenhuma disciplina cadastrada',
                    'Cadastre disciplinas para começar a montar esta grade.',
                  )
                : _timetable(schedule, compact),
          ),
        ],
      ),
    );
  }

  Widget _controlPanel(bool compact) => LayoutBuilder(
    builder: (context, constraints) {
      final panelWidth = constraints.maxWidth < 1000
          ? constraints.maxWidth
          : 1000.0;
      return Center(
        child: SizedBox(
          width: panelWidth,
          child: _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runAlignment: WrapAlignment.center,
                    runSpacing: 12,
                    spacing: 14,
                    children: [
                      SizedBox(
                        width: compact ? 280 : 400,
                        child: DropdownButtonFormField<int>(
                          initialValue: _program,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Curso',
                            prefixIcon: Icon(Icons.school_rounded),
                          ),
                          items: _programs.entries
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(
                                    entry.value,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            setState(() {
                              _program = value ?? _programs.keys.first;
                              _period = 1;
                            });
                            _saveViewSelection();
                            _restoreCurrentTableScroll();
                          },
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _managePrograms,
                        icon: const Icon(Icons.school_outlined),
                        label: const Text('Editar cursos'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _editPeriod(),
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Editar disciplinas'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var p = 1; p <= 10; p++)
                          Padding(
                            padding: const EdgeInsets.only(right: 7),
                            child: ChoiceChip(
                              label: Text('Per\u00edodo $p'),
                              selected: _period == p,
                              onSelected: (_) {
                                setState(() => _period = p);
                                _saveViewSelection();
                              },
                            ),
                          ),
                        if (_entries.any(
                          (entry) => entry.coursePeriods.any(
                            (item) =>
                                item.program == _program && item.period == 11,
                          ),
                        ))
                          ChoiceChip(
                            label: const Text('Optativas'),
                            selected: _period == 11,
                            onSelected: (_) {
                              setState(() => _period = 11);
                              _saveViewSelection();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _teacherView(bool compact) {
    final teachers = _teachers;
    if (teachers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: _emptyState(
          'Nenhum docente cadastrado',
          'Adicione o nome do docente às disciplinas para gerar a grade.',
        ),
      );
    }
    _teacher ??= teachers.first;
    if (!teachers.contains(_teacher)) _teacher = teachers.first;
    final schedule = _schedule(teacher: _teacher);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 30,
        12,
        compact ? 16 : 30,
        24,
      ),
      child: Column(
        children: [
          _panel(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: compact ? 300 : 440,
                  child: DropdownButtonFormField<String>(
                    initialValue: _teacher,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Docente',
                      prefixIcon: Icon(Icons.person_rounded),
                    ),
                    items: teachers
                        .map(
                          (name) => DropdownMenuItem(
                            value: name,
                            child: Text(name, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() => _teacher = value);
                      _saveViewSelection();
                      _restoreCurrentTableScroll();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _generateTeachers,
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('Gerar grades de docentes'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(child: _timetable(schedule, compact)),
        ],
      ),
    );
  }

  Future<void> _filterDistributionTeachers(
    List<_TeacherDistribution> summaries,
  ) async {
    final names = summaries.map((summary) => summary.name).toList();
    final selected = names
        .where((name) => !_hiddenDistributionTeachers.contains(name))
        .toSet();
    final search = TextEditingController();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final visibleNames = names
              .where(
                (name) => name.toLowerCase().contains(
                  search.text.trim().toLowerCase(),
                ),
              )
              .toList();
          return AlertDialog(
            title: const Text('Docentes na distribuição'),
            content: SizedBox(
              width: 460,
              height: 520,
              child: Column(
                children: [
                  TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      labelText: 'Buscar docente',
                      isDense: true,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () =>
                            setDialogState(() => selected.addAll(names)),
                        child: const Text('Selecionar todos'),
                      ),
                      TextButton(
                        onPressed: () => setDialogState(selected.clear),
                        child: const Text('Limpar seleção'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: visibleNames.length,
                      itemBuilder: (context, index) {
                        final name = visibleNames[index];
                        return CheckboxListTile(
                          dense: true,
                          value: selected.contains(name),
                          title: Text(name),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (checked) => setDialogState(() {
                            if (checked == true) {
                              selected.add(name);
                            } else {
                              selected.remove(name);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, selected),
                child: const Text('Aplicar'),
              ),
            ],
          );
        },
      ),
    );
    search.dispose();
    if (result == null || !mounted) return;
    final hidden = names.where((name) => !result.contains(name)).toSet();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _termScopedKey(_hiddenDistributionTeachersKey, _term),
      hidden.toList(),
    );
    if (mounted) setState(() => _hiddenDistributionTeachers = hidden);
  }

  Widget _distributionView(bool compact) {
    final allSummaries = _distributionRecords.isNotEmpty
        ? _summariesFromImportedRecords()
        : _summariesFromSchedule();
    final summaries = allSummaries
        .where((summary) => !_hiddenDistributionTeachers.contains(summary.name))
        .toList();
    final totalTheory = summaries.fold<int>(
      0,
      (sum, teacher) => sum + teacher.theoryHours,
    );
    final totalPractice = summaries.fold<int>(
      0,
      (sum, teacher) => sum + teacher.practiceHours,
    );
    final totalEad = summaries.fold<int>(
      0,
      (sum, teacher) => sum + teacher.eadHours,
    );
    final totalExtension = summaries.fold<int>(
      0,
      (sum, teacher) => sum + teacher.extensionHours,
    );
    final totalClasses = summaries.fold<int>(
      0,
      (sum, teacher) => sum + teacher.classCount,
    );
    final totalHours = totalTheory + totalPractice + totalEad;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 30,
        12,
        compact ? 16 : 30,
        24,
      ),
      child: _panel(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Distribui\u00e7\u00e3o Docente',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _distributionRecords.isEmpty
                              ? 'Resumo calculado a partir das disciplinas cadastradas.'
                              : 'Dados importados da aba Banco da planilha de horários.',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Filtrar docentes',
                    onPressed: allSummaries.isEmpty
                        ? null
                        : () => _filterDistributionTeachers(allSummaries),
                    icon: const Icon(Icons.filter_list_rounded),
                  ),
                  const SizedBox(width: 8),
                  _infoPill(
                    Icons.groups_2_outlined,
                    '${summaries.length} docentes',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: AppTheme.divider),
            if (allSummaries.isEmpty)
              Expanded(
                child: _emptyState(
                  'Nenhum docente cadastrado',
                  'Preencha o docente nas disciplinas para montar a distribuição.',
                ),
              )
            else if (summaries.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Nenhum docente selecionado',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            _filterDistributionTeachers(allSummaries),
                        child: const Text('Alterar filtro'),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: Scrollbar(
                      controller: _distributionHorizontalScroll,
                      thumbVisibility: true,
                      notificationPredicate: (notification) =>
                          notification.metrics.axis == Axis.horizontal,
                      child: SingleChildScrollView(
                        controller: _distributionHorizontalScroll,
                        scrollDirection: Axis.horizontal,
                        child: _distributionTable(
                          summaries,
                          totalTheory,
                          totalPractice,
                          totalEad,
                          totalExtension,
                          totalHours,
                          totalClasses,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _distributionTable(
    List<_TeacherDistribution> summaries,
    int totalTheory,
    int totalPractice,
    int totalEad,
    int totalExtension,
    int totalHours,
    int totalClasses,
  ) {
    TableRow makeRow(List<String> values, {Color? color, bool bold = false}) =>
        TableRow(
          decoration: BoxDecoration(color: color),
          children: [
            for (var index = 0; index < values.length; index++)
              _distributionCell(
                values[index],
                numeric: index == 0 || (index >= 3 && index <= 9),
                bold: bold,
              ),
          ],
        );

    return Table(
      border: TableBorder.all(
        color: AppTheme.divider.withAlpha(150),
        width: 0.7,
      ),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: const {
        0: FixedColumnWidth(48),
        1: FixedColumnWidth(245),
        2: FixedColumnWidth(480),
        3: FixedColumnWidth(78),
        4: FixedColumnWidth(78),
        5: FixedColumnWidth(66),
        6: FixedColumnWidth(70),
        7: FixedColumnWidth(82),
        8: FixedColumnWidth(76),
        9: FixedColumnWidth(96),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: AppTheme.primary.withAlpha(40)),
          children: [
            for (var index = 0; index < 10; index++)
              _distributionCell(
                [
                  'ID',
                  'Professor',
                  'Disciplinas (Sigla Turma)',
                  'CH\nTeórica',
                  'CH\nPrática',
                  'CH\nEaD',
                  'Total',
                  'CH\nExtensão',
                  'Nº\nTurmas',
                  'Períodos',
                ][index],
                header: true,
                numeric: index >= 3,
              ),
          ],
        ),
        for (var index = 0; index < summaries.length; index++)
          TableRow(
            decoration: BoxDecoration(
              color: index.isEven
                  ? AppTheme.bgCard.withAlpha(100)
                  : AppTheme.bgCardAlt.withAlpha(130),
            ),
            children: [
              _distributionCell('${index + 1}', numeric: true),
              _distributionCell(summaries[index].name),
              _distributionCell(
                summaries[index].disciplines.join(', '),
                tooltip: summaries[index].disciplines.join(', '),
              ),
              _distributionCell(
                '${summaries[index].theoryHours}',
                numeric: true,
              ),
              _distributionCell(
                '${summaries[index].practiceHours}',
                numeric: true,
              ),
              _distributionCell('${summaries[index].eadHours}', numeric: true),
              _distributionCell(
                '${summaries[index].theoryHours + summaries[index].practiceHours + summaries[index].eadHours}',
                numeric: true,
              ),
              _distributionCell(
                '${summaries[index].extensionHours}',
                numeric: true,
              ),
              _distributionCell(
                '${summaries[index].classCount}',
                numeric: true,
              ),
              _distributionCell(
                summaries[index].periods.join(', '),
                numeric: true,
              ),
            ],
          ),
        makeRow(
          [
            '',
            'TOTAL',
            '',
            '$totalTheory',
            '$totalPractice',
            '$totalEad',
            '$totalHours',
            '$totalExtension',
            '$totalClasses',
            '',
          ],
          color: AppTheme.primary.withAlpha(36),
          bold: true,
        ),
        makeRow([
          '',
          'MÉDIA por professor',
          '',
          (totalTheory / summaries.length).toStringAsFixed(1),
          (totalPractice / summaries.length).toStringAsFixed(1),
          (totalEad / summaries.length).toStringAsFixed(1),
          (totalHours / summaries.length).toStringAsFixed(1),
          (totalExtension / summaries.length).toStringAsFixed(1),
          '',
          '',
        ], color: AppTheme.bgCardAlt.withAlpha(150)),
      ],
    );
  }

  Widget _distributionCell(
    String value, {
    bool header = false,
    bool numeric = false,
    bool bold = false,
    String? tooltip,
  }) {
    final text = Text(
      value,
      softWrap: true,
      style: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 12,
        fontWeight: header || bold ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: header ? 10 : 11,
        vertical: header ? 10 : 7,
      ),
      child: Align(
        alignment: numeric ? Alignment.center : Alignment.centerLeft,
        child: tooltip == null ? text : Tooltip(message: tooltip, child: text),
      ),
    );
  }

  List<_TeacherDistribution> _summariesFromSchedule() => _teachers.map((
    teacher,
  ) {
    final entries = _entries
        .where((entry) => entry.teacherNames.contains(teacher))
        .toList();
    final periods =
        entries
            .expand((entry) => entry.coursePeriods.map((item) => item.period))
            .toSet()
            .toList()
          ..sort();
    return _TeacherDistribution(
      name: teacher,
      disciplines: entries.map(_classLabel).toList(),
      classCount: entries.length,
      theoryHours: entries.fold(0, (sum, entry) => sum + entry.theoryHours),
      practiceHours: entries.fold(0, (sum, entry) => sum + entry.practiceHours),
      eadHours: 0,
      extensionHours: 0,
      periods: periods
          .map((period) => period == 11 ? 'Optativas' : '$periodº')
          .toList(),
    );
  }).toList();

  List<_TeacherDistribution> _summariesFromImportedRecords() {
    final grouped = <String, List<_TeacherDistributionRecord>>{};
    for (final record in _distributionRecords) {
      grouped.putIfAbsent(record.teacher, () => []).add(record);
    }
    final names = grouped.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [
      for (final name in names)
        () {
          final records = grouped[name]!;
          final periods =
              records.map((record) => record.period).toSet().toList()
                ..sort((a, b) {
                  final aNumber = int.tryParse(a);
                  final bNumber = int.tryParse(b);
                  if (aNumber != null && bNumber != null) {
                    return aNumber.compareTo(bNumber);
                  }
                  if (aNumber != null) {
                    return -1;
                  }
                  if (bNumber != null) {
                    return 1;
                  }
                  return a.compareTo(b);
                });
          return _TeacherDistribution(
            name: name,
            disciplines: records.map((record) => record.discipline).toList(),
            classCount: records.length,
            theoryHours: records.fold(
              0,
              (sum, record) => sum + record.theoryHours,
            ),
            practiceHours: records.fold(
              0,
              (sum, record) => sum + record.practiceHours,
            ),
            eadHours: records.fold(0, (sum, record) => sum + record.eadHours),
            extensionHours: records.fold(
              0,
              (sum, record) => sum + record.extensionHours,
            ),
            periods: periods
                .map((period) => period.endsWith('º') ? period : '$periodº')
                .toList(),
          );
        }(),
    ];
  }

  String _classLabel(HorarioDisciplina entry) {
    final label = entry.acronym.trim().isEmpty ? entry.name : entry.acronym;
    return '${label.trim()}${entry.className.trim().isEmpty ? '' : ' ${entry.className.trim()}'}';
  }

  Widget _timetable(
    Map<String, List<HorarioDisciplina>> schedule,
    bool compact,
  ) {
    final minWidth = compact ? 900.0 : 1080.0;
    final disciplineColors = _colorsForSchedule(schedule);
    final weeklyLessonCount = schedule.values.fold<int>(
      0,
      (sum, entries) => sum + entries.map((entry) => entry.id).toSet().length,
    );
    return _panel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tableWidth = constraints.maxWidth < minWidth
                    ? minWidth
                    : constraints.maxWidth;
                final verticalController = _view == 1
                    ? _teacherVerticalScroll
                    : _courseVerticalScroll;
                final horizontalController = _view == 1
                    ? _teacherHorizontalScroll
                    : _courseHorizontalScroll;
                return Scrollbar(
                  controller: verticalController,
                  thumbVisibility: true,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.vertical,
                  child: SingleChildScrollView(
                    controller: verticalController,
                    child: Scrollbar(
                      controller: horizontalController,
                      thumbVisibility: true,
                      notificationPredicate: (notification) =>
                          notification.metrics.axis == Axis.horizontal,
                      child: SingleChildScrollView(
                        controller: horizontalController,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: tableWidth,
                          child: Table(
                            border: TableBorder.all(
                              color: AppTheme.divider.withAlpha(150),
                              width: 0.7,
                            ),
                            defaultVerticalAlignment:
                                TableCellVerticalAlignment.middle,
                            columnWidths: const {
                              0: FixedColumnWidth(136),
                              1: FlexColumnWidth(),
                              2: FlexColumnWidth(),
                              3: FlexColumnWidth(),
                              4: FlexColumnWidth(),
                              5: FlexColumnWidth(),
                            },
                            children: [
                              TableRow(
                                decoration: BoxDecoration(
                                  color: AppTheme.primary.withAlpha(40),
                                ),
                                children: [
                                  _scheduleHeaderCell('Faixa hor\u00e1ria'),
                                  for (final day in horarioDias)
                                    _scheduleHeaderCell(day),
                                ],
                              ),
                              for (
                                var slot = 1;
                                slot <= horarioFaixas.length;
                                slot++
                              )
                                _scheduleDataRow(
                                  slot,
                                  schedule,
                                  disciplineColors,
                                  tableWidth,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Duplo clique em um hor\u00e1rio para escolher as disciplinas. Turmas simult\u00e2neas aparecem separadas por v\u00edrgula',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (_view == 1) ...[
                  const SizedBox(width: 10),
                  Text(
                    '$weeklyLessonCount aulas por semana',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (_view == 0) ...[
                  Text(
                    '${_periodEntries.length} disciplinas neste per\u00edodo',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  TableRow _scheduleDataRow(
    int slot,
    Map<String, List<HorarioDisciplina>> schedule,
    Map<String, Color> disciplineColors,
    double tableWidth,
  ) {
    final cellWidth = (tableWidth - 136) / 5;
    const rowHeight = 34.0;

    return TableRow(
      decoration: BoxDecoration(
        color: slot.isEven
            ? AppTheme.bgCard.withAlpha(90)
            : AppTheme.bgCardAlt.withAlpha(105),
      ),
      children: [
        _scheduleTimeCell(slot, rowHeight),
        for (var weekday = 1; weekday <= 5; weekday++)
          _slotCell(
            schedule['$weekday:$slot'] ?? const [],
            disciplineColors,
            height: rowHeight,
            cellWidth: cellWidth,
            onDoubleTap: () => _editTimetableCell(weekday, slot),
          ),
      ],
    );
  }

  Widget _scheduleHeaderCell(String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    child: Center(
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  Widget _scheduleTimeCell(int slot, double height) => SizedBox(
    height: height,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Center(
        child: Text(
          horarioFaixas[slot - 1],
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            height: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );

  Map<String, Color> _colorsForSchedule(
    Map<String, List<HorarioDisciplina>> schedule,
  ) {
    final keys =
        schedule.values
            .expand((entries) => entries)
            .map(_scheduleColorKey)
            .toSet()
            .toList()
          ..sort();
    return {
      for (var index = 0; index < keys.length; index++)
        keys[index]: HSLColor.fromAHSL(
          1,
          index * 360 / keys.length,
          AppTheme.isLight ? 0.68 : 0.72,
          AppTheme.isLight ? 0.55 : 0.69,
        ).toColor(),
    };
  }

  String _scheduleColorKey(HorarioDisciplina entry) =>
      '${entry.id}:${entry.className.trim().toLowerCase()}';

  List<double> _scheduleColorStops(
    List<HorarioDisciplina> entries,
    double cellWidth,
  ) {
    if (entries.length < 2) return const [0, 1];
    final labels = entries
        .map(
          (entry) =>
              '${entry.acronym}${entry.className.isNotEmpty ? ' · ${entry.className}' : ''}',
        )
        .toList();
    final textStyle = TextStyle(
      color: AppTheme.textPrimary,
      fontSize: 13,
      height: 1.05,
      fontWeight: FontWeight.w600,
    );
    List<InlineSpan> spansThrough(int lastLabel, {bool includeComma = false}) {
      final spans = <InlineSpan>[];
      for (var index = 0; index <= lastLabel; index++) {
        spans.add(TextSpan(text: labels[index], style: textStyle));
        if (index < lastLabel || includeComma && index == lastLabel) {
          spans.add(
            TextSpan(
              text: index == lastLabel ? ',' : ', ',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
          );
        }
      }
      return spans;
    }

    double measureSpans(List<InlineSpan> spans) {
      final painter = TextPainter(
        text: TextSpan(style: textStyle, children: spans),
        textDirection: Directionality.of(context),
      )..layout();
      return painter.width;
    }

    final textWidth = measureSpans(spansThrough(labels.length - 1));
    final textStart = (cellWidth - textWidth) / 2;
    final stops = <double>[0];
    for (var index = 0; index < labels.length - 1; index++) {
      final prefixWidth = measureSpans(spansThrough(index, includeComma: true));
      final boundary = ((textStart + prefixWidth) / cellWidth).clamp(0.0, 1.0);
      stops
        ..add(boundary)
        ..add(boundary);
    }
    stops.add(1);
    return stops;
  }

  Widget _slotCell(
    List<HorarioDisciplina> entries,
    Map<String, Color> disciplineColors, {
    required double height,
    required double cellWidth,
    required VoidCallback onDoubleTap,
  }) {
    final unique = <String, HorarioDisciplina>{
      for (final entry in entries) '${entry.id}:${entry.className}': entry,
    }.values.toList();
    final labels = unique
        .map(
          (entry) =>
              '${entry.acronym}${entry.className.isNotEmpty ? ' \u00b7 ${entry.className}' : ''}',
        )
        .toList();
    final colorOpacity = AppTheme.isLight ? 70 : 100;
    final colors = unique
        .map(
          (entry) =>
              (disciplineColors[_scheduleColorKey(entry)] ?? AppTheme.primary)
                  .withAlpha(colorOpacity),
        )
        .toList();
    final fillStops = _scheduleColorStops(unique, cellWidth);
    final fillColors = <Color>[];
    if (colors.length == 1) {
      fillColors
        ..add(colors.single)
        ..add(colors.single);
    } else if (colors.length > 1) {
      fillColors.add(colors.first);
      for (var index = 0; index < colors.length - 1; index++) {
        fillColors
          ..add(colors[index])
          ..add(colors[index + 1]);
      }
      fillColors.add(colors.last);
    }

    return Tooltip(
      message: labels.join(', '),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onDoubleTap: onDoubleTap,
          child: Container(
            width: double.infinity,
            height: height,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: unique.isEmpty
                ? null
                : BoxDecoration(
                    gradient: LinearGradient(
                      colors: fillColors,
                      stops: fillStops,
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                  ),
            child: unique.isEmpty
                ? const SizedBox(height: 26)
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          for (
                            var index = 0;
                            index < unique.length;
                            index++
                          ) ...[
                            TextSpan(
                              text: labels[index],
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 13,
                                height: 1.05,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (index < unique.length - 1)
                              TextSpan(
                                text: ', ',
                                style: TextStyle(color: AppTheme.textPrimary),
                              ),
                          ],
                        ],
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        height: 1.05,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _editTimetableCell(int weekday, int slot) async {
    final candidates = [..._entries]
      ..sort((a, b) {
        final acronymOrder = a.acronym.toLowerCase().compareTo(
          b.acronym.toLowerCase(),
        );
        return acronymOrder != 0
            ? acronymOrder
            : a.className.toLowerCase().compareTo(b.className.toLowerCase());
      });
    if (candidates.isEmpty) {
      _message('N\u00e3o h\u00e1 disciplinas cadastradas para selecionar.');
      return;
    }

    bool belongsToCurrentView(HorarioDisciplina entry) => _view == 1
        ? _teacher != null && entry.teacherNames.contains(_teacher)
        : entry.coursePeriods.any(
            (item) => item.program == _program && item.period == _period,
          );
    final selected = candidates
        .where(
          (entry) =>
              belongsToCurrentView(entry) &&
              entry.slots.any(
                (item) => item.weekday == weekday && item.slot == slot,
              ),
        )
        .map((entry) => entry.id)
        .toSet();
    final searchController = TextEditingController();
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = searchController.text.trim().toLowerCase();
          final visible = candidates.where((entry) {
            if (query.isEmpty) return true;
            return entry.name.toLowerCase().contains(query) ||
                entry.code.toLowerCase().contains(query) ||
                entry.acronym.toLowerCase().contains(query);
          }).toList();
          return AlertDialog(
            title: Text(
              '${horarioDias[weekday - 1]} \u00b7 ${horarioFaixas[slot - 1]}',
            ),
            content: SizedBox(
              width: 560,
              height: 540,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Buscar por nome ou c\u00f3digo',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Limpar busca',
                              onPressed: () {
                                searchController.clear();
                                setDialogState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setDialogState(
                          () =>
                              selected.addAll(visible.map((entry) => entry.id)),
                        ),
                        child: const Text('Selecionar resultados'),
                      ),
                      TextButton(
                        onPressed: () => setDialogState(selected.clear),
                        child: const Text('Limpar sele\u00e7\u00e3o'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Text(
                              'Nenhuma disciplina encontrada',
                              style: TextStyle(color: AppTheme.textSecondary),
                            ),
                          )
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              final label = entry.acronym.isEmpty
                                  ? entry.name
                                  : entry.acronym;
                              return CheckboxListTile(
                                dense: true,
                                value: selected.contains(entry.id),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  '$label \u00b7 Turma ${entry.className}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  [
                                    entry.name,
                                    ...entry.teacherNames,
                                  ].join(' \u00b7 '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onChanged: (checked) => setDialogState(() {
                                  if (checked == true) {
                                    selected.add(entry.id);
                                  } else {
                                    selected.remove(entry.id);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, selected),
                child: const Text('Aplicar ao hor\u00e1rio'),
              ),
            ],
          );
        },
      ),
    );
    searchController.dispose();
    if (result == null || !mounted) return;

    setState(() {
      _entries = _entries.map((entry) {
        final inCurrentView = belongsToCurrentView(entry);
        final isSelected = result.contains(entry.id);
        if (!inCurrentView && !isSelected) return entry;

        var updated = entry;
        final slots = entry.slots
            .where((item) => item.weekday != weekday || item.slot != slot)
            .toList();
        if (isSelected) {
          slots.add(HorarioSlot(weekday: weekday, slot: slot));
        }
        slots.sort(
          (a, b) => a.weekday != b.weekday
              ? a.weekday.compareTo(b.weekday)
              : a.slot.compareTo(b.slot),
        );
        updated = updated.copyWith(slots: slots);

        if (isSelected &&
            _view == 0 &&
            !updated.coursePeriods.any(
              (item) => item.program == _program && item.period == _period,
            )) {
          updated = updated.copyWith(
            coursePeriods: [
              ...updated.coursePeriods,
              CursoPeriodo(program: _program, period: _period),
            ],
          );
        }
        if (isSelected &&
            _view == 1 &&
            _teacher != null &&
            !updated.teacherNames.any(
              (name) => name.toLowerCase() == _teacher!.toLowerCase(),
            )) {
          if (updated.teacher.trim().isEmpty) {
            updated = updated.copyWith(teacher: _teacher);
          } else {
            updated = updated.copyWith(
              coTeachers: [...updated.coTeachers, _teacher!],
            );
          }
        }
        return updated;
      }).toList();
    });
    await _persist();
    _message('Hor\u00e1rio atualizado e salvo na base de dados.');
  }

  Future<void> _generateTeachers() async {
    final teachers = _teachers;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Grades por docente'),
        content: SizedBox(
          width: 560,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: teachers.length,
            itemBuilder: (context, index) {
              final teacher = teachers[index];
              final courses = _entries
                  .where((entry) => entry.teacherNames.contains(teacher))
                  .toList();
              final blocks = courses.fold<int>(
                0,
                (sum, entry) => sum + entry.slots.length,
              );
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.accent.withAlpha(25),
                  child: Icon(
                    Icons.person_rounded,
                    color: AppTheme.accent,
                    size: 19,
                  ),
                ),
                title: Text(teacher),
                subtitle: Text(
                  '${courses.length} disciplinas · $blocks blocos semanais',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(dialogContext, teacher),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    if (selected != null) {
      setState(() {
        _teacher = selected;
        _view = 1;
      });
      _saveViewSelection();
      _restoreCurrentTableScroll();
    }
  }

  Future<void> _editPeriod() async {
    final candidates = _periodEntries;
    final result = await showDialog<_HorarioEditorResult>(
      context: context,
      builder: (_) => _HorarioEditorDialog(
        entries: candidates,
        selectedProgram: _program,
        selectedPeriod: _period,
      ),
    );
    if (result == null) return;
    if (result.action == _HorarioEditorAction.delete) {
      setState(() => _entries.removeWhere((entry) => entry.id == result.id));
    } else {
      final updated = result.entry!;
      setState(() {
        final index = _entries.indexWhere((entry) => entry.id == updated.id);
        if (index < 0) {
          _entries = [..._entries, updated];
        } else {
          _entries = [
            for (var i = 0; i < _entries.length; i++)
              if (i == index) updated else _entries[i],
          ];
        }
      });
    }
    await _persist();
  }

  Future<void> _importDatabase() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Importar a base de disciplinas',
      type: FileType.custom,
      allowedExtensions: const ['xlsm', 'xlsx'],
    );
    final bytes =
        picked?.files.single.bytes ??
        (picked?.files.single.path != null
            ? await File(picked!.files.single.path!).readAsBytes()
            : null);
    if (bytes == null) return;
    try {
      final book = xls.Excel.decodeBytes(bytes);
      final banco = book.tables['Banco'];
      if (banco != null) {
        await _importDistributionBanco(banco);
        return;
      }
      final sheet = book.tables['BDados'];
      if (sheet == null) {
        throw const FormatException('A planilha não contém a aba BDados.');
      }
      String value(int row, int col) =>
          sheet
              .cell(
                xls.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
              )
              .value
              ?.toString()
              .trim() ??
          '';
      List<T> parsePairs<T>(String raw, T Function(int a, int b) create) =>
          raw.split(';').where((item) => item.contains(',')).map((item) {
            final parts = item.split(',');
            return create(
              int.tryParse(parts[0].trim()) ?? 0,
              int.tryParse(parts[1].trim()) ?? 0,
            );
          }).toList();
      final imported = <HorarioDisciplina>[];
      for (var row = 2; row < sheet.maxRows; row++) {
        final code = value(row, 3),
            acronym = value(row, 4),
            name = value(row, 5);
        if (code.isEmpty && acronym.isEmpty && name.isEmpty) continue;
        imported.add(
          HorarioDisciplina(
            id: 'import_${const Uuid().v4()}',
            code: code,
            acronym: acronym,
            name: name,
            className: value(row, 6),
            teacher: value(row, 7),
            room: value(row, 8),
            theoryHours: int.tryParse(value(row, 9)) ?? 0,
            practiceHours: int.tryParse(value(row, 10)) ?? 0,
            coursePeriods:
                parsePairs(
                      value(row, 1),
                      (period, program) =>
                          CursoPeriodo(program: program, period: period),
                    )
                    .where(
                      (v) =>
                          v.program >= 1 &&
                          v.program <= 5 &&
                          v.period >= 1 &&
                          v.period <= 11,
                    )
                    .toList(),
            slots:
                parsePairs(
                      value(row, 2),
                      (slot, weekdayEncoded) =>
                          HorarioSlot(weekday: weekdayEncoded - 1, slot: slot),
                    )
                    .where(
                      (v) =>
                          v.weekday >= 1 &&
                          v.weekday <= 5 &&
                          v.slot >= 1 &&
                          v.slot <= horarioFaixas.length,
                    )
                    .toList(),
          ),
        );
      }
      if (imported.isEmpty) {
        throw const FormatException(
          'Nenhuma disciplina foi encontrada em BDados.',
        );
      }
      if (!mounted) return;
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Aplicar base importada?'),
          content: Text(
            'Foram encontradas ${imported.length} disciplinas na aba BDados. Substituirá a base atual do Ajusta Horários.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Substituir base'),
            ),
          ],
        ),
      );
      if (replace != true) return;
      setState(() {
        _entries = imported;
        _distributionRecords = [];
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_termScopedKey(_distributionKey, _term));
      await _persist();
      _message('${imported.length} disciplinas importadas.');
    } catch (e) {
      _message('Não foi possível importar a base: $e');
    }
  }

  Future<void> _importDistributionBanco(xls.Sheet sheet) async {
    String cell(int row, int column) {
      if (column < 0 || row >= sheet.maxRows) return '';
      return sheet
              .cell(
                xls.CellIndex.indexByColumnRow(
                  columnIndex: column,
                  rowIndex: row,
                ),
              )
              .value
              ?.toString()
              .trim() ??
          '';
    }

    String normalize(String value) => value
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('à', 'a')
        .replaceAll('ã', 'a')
        .replaceAll('â', 'a')
        .replaceAll('é', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ô', 'o')
        .replaceAll('õ', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    final headers = [
      for (var column = 0; column < sheet.maxColumns; column++)
        normalize(cell(0, column)),
    ];
    int column(String name, [String? alternative]) {
      final result = headers.indexOf(normalize(name));
      return result >= 0 || alternative == null
          ? result
          : headers.indexOf(normalize(alternative));
    }

    final periodColumn = column('Período');
    final acronymColumn = column('Sigla');
    final subjectColumn = column('Disciplina');
    final classColumn = column('Turma');
    final teacherColumn = column('Docente');
    final optionColumn = column('Opção (Sigla Turma)');
    final theoryColumn = column('CH_T');
    final practiceColumn = column('CH_P');
    final eadColumn = column('CH EAD');
    final extensionColumn = column('CH Extensão');
    if (teacherColumn < 0 || (optionColumn < 0 && subjectColumn < 0)) {
      throw const FormatException(
        'A aba Banco precisa conter Docente e uma coluna de disciplina.',
      );
    }

    final imported = <_TeacherDistributionRecord>[];
    for (var row = 1; row < sheet.maxRows; row++) {
      final teacher = cell(row, teacherColumn);
      if (teacher.isEmpty) continue;
      final option = cell(row, optionColumn);
      final acronym = cell(row, acronymColumn);
      final className = cell(row, classColumn);
      final subject = cell(row, subjectColumn);
      final discipline = option.isNotEmpty
          ? option
          : '${acronym.isEmpty ? subject : acronym}${className.isEmpty ? '' : ' $className'}';
      if (discipline.trim().isEmpty) continue;
      imported.add(
        _TeacherDistributionRecord(
          teacher: teacher,
          discipline: discipline.trim(),
          period: cell(row, periodColumn),
          theoryHours: int.tryParse(cell(row, theoryColumn)) ?? 0,
          practiceHours: int.tryParse(cell(row, practiceColumn)) ?? 0,
          eadHours: int.tryParse(cell(row, eadColumn)) ?? 0,
          extensionHours: int.tryParse(cell(row, extensionColumn)) ?? 0,
        ),
      );
    }
    if (imported.isEmpty) {
      throw const FormatException(
        'Nenhuma distribuição docente encontrada na aba Banco.',
      );
    }
    if (!mounted) return;
    final replace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Importar distribuição docente?'),
        content: Text(
          'A aba Banco contém ${imported.length} turma(s) e ${imported.map((item) => item.teacher).toSet().length} docente(s). A importação atualiza esta aba e mantém as grades semanais existentes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Importar'),
          ),
        ],
      ),
    );
    if (replace != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _termScopedKey(_distributionKey, _term),
      jsonEncode(imported.map((item) => item.toJson()).toList()),
    );
    if (!mounted) return;
    setState(() => _distributionRecords = imported);
    _message('Distribuição docente importada: ${imported.length} turmas.');
  }

  List<int> _availableExportPeriods() {
    final entries = _view == 1
        ? _entries.where((entry) => entry.teacherNames.contains(_teacher))
        : _entries.where(
            (entry) =>
                entry.coursePeriods.any((item) => item.program == _program),
          );
    final periods =
        entries
            .expand((entry) => entry.coursePeriods)
            .where((item) => _view == 1 || item.program == _program)
            .map((item) => item.period)
            .toSet()
            .toList()
          ..sort();
    return periods.isEmpty ? List.generate(10, (index) => index + 1) : periods;
  }

  Future<_ScheduleExportChoice?> _chooseExportPeriods({
    required bool pdf,
  }) async {
    final periods = _availableExportPeriods();
    final initiallySelected = _view == 0 && periods.contains(_period)
        ? <int>{_period}
        : periods.toSet();
    var selected = {...initiallySelected};
    return showDialog<_ScheduleExportChoice>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: const Text('Escolha os períodos'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Todos os períodos'),
                  subtitle: Text('${periods.length} períodos disponíveis'),
                  value: selected.length == periods.length,
                  onChanged: (value) => dialogSetState(() {
                    selected = value == true
                        ? periods.toSet()
                        : (initiallySelected.isNotEmpty
                              ? {...initiallySelected}
                              : {periods.first});
                  }),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final period in periods)
                      FilterChip(
                        label: Text(_periodLabel(period)),
                        selected: selected.contains(period),
                        onSelected: (value) => dialogSetState(() {
                          if (value) {
                            selected.add(period);
                          } else if (selected.length > 1) {
                            selected.remove(period);
                          }
                        }),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      _ScheduleExportChoice(periods: selected.toList()..sort()),
                    ),
              icon: Icon(pdf ? Icons.picture_as_pdf_rounded : Icons.table_view),
              label: Text(pdf ? 'Continuar para PDF' : 'Exportar CSV'),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, List<HorarioDisciplina>> _scheduleForExportPeriod(int period) {
    final selectedEntries = _entries.where((entry) {
      final matchesView = _view == 1
          ? _teacher != null && entry.teacherNames.contains(_teacher)
          : entry.coursePeriods.any((item) => item.program == _program);
      return matchesView &&
          entry.coursePeriods.any(
            (item) =>
                item.period == period &&
                (_view == 1 || item.program == _program),
          );
    });
    final result = <String, List<HorarioDisciplina>>{};
    for (final entry in selectedEntries) {
      for (final slot in entry.slots) {
        result.putIfAbsent(slot.key, () => []).add(entry);
      }
    }
    return result;
  }

  String _exportTitle(List<int> periods) {
    final periodLabel = periods.map(_periodExportLabel).join(', ');
    return _view == 1
        ? 'Grade: ${_teacher ?? 'Docente'} \u00b7 $periodLabel'
        : '${_programs[_program]} \u00b7 $periodLabel';
  }

  String _periodLabel(int period) =>
      period == 11 ? 'Optativas' : 'Período $period';

  String _periodExportLabel(int period) =>
      period == 11 ? 'Optativas' : 'Período $periodº';

  AjustaHorariosPdfSheet _createPdfSheet(
    String title,
    Map<String, List<HorarioDisciplina>> schedule,
  ) {
    final colors = _colorsForSchedule(
      schedule,
    ).map((key, color) => MapEntry(key, PdfColor(color.r, color.g, color.b)));
    const pdfPageMargin = 20.0;
    final pdfCellWidth =
        ((PdfPageFormat.a4.landscape.width - pdfPageMargin * 2) / 0.75 - 136) /
        5;
    final cellColorStops = <String, List<double>>{
      for (var weekday = 1; weekday <= 5; weekday++)
        for (var slot = 1; slot <= horarioFaixas.length; slot++)
          '$weekday:$slot': _scheduleColorStops(
            <String, HorarioDisciplina>{
              for (final entry in schedule['$weekday:$slot'] ?? const [])
                '${entry.id}:${entry.className}': entry,
            }.values.toList(),
            pdfCellWidth,
          ),
    };
    return AjustaHorariosPdfSheet(
      title: title,
      schedule: schedule,
      disciplineColors: colors,
      cellColorStops: cellColorStops,
    );
  }

  Future<void> _exportSchedule() async {
    final teacherMode = _view == 1;
    final choice = await _chooseExportPeriods(pdf: false);
    if (choice == null) return;
    final rows = <List<String>>[];
    for (var index = 0; index < choice.periods.length; index++) {
      final period = choice.periods[index];
      final schedule = _scheduleForExportPeriod(period);
      if (choice.periods.length > 1) {
        rows.add([_periodExportLabel(period)]);
      }
      rows.add(['Faixa hor\u00e1ria', ...horarioDias]);
      for (var slot = 1; slot <= horarioFaixas.length; slot++) {
        rows.add([
          horarioFaixas[slot - 1],
          for (var day = 1; day <= 5; day++)
            (schedule['$day:$slot'] ?? const [])
                .map(
                  (entry) =>
                      '${entry.acronym}${entry.className.isEmpty ? '' : ' - ${entry.className}'}',
                )
                .join(' | '),
        ]);
      }
      if (index < choice.periods.length - 1) rows.add([]);
    }
    final csv = rows
        .map(
          (row) =>
              row.map((cell) => '"${cell.replaceAll('"', '""')}"').join(';'),
        )
        .join('\r\n');
    final periodSuffix = choice.periods.join('-');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar grade',
      fileName: teacherMode
          ? 'grade-${_teacher ?? 'docente'}-periodos-$periodSuffix.csv'
          : 'grade-curso-$_program-periodos-$periodSuffix.csv',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    if (path == null) return;
    await File(path).writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
    _message('Grade exportada em CSV.');
  }

  Future<void> _exportPdf() async {
    final teacherMode = _view == 1;
    final choice = await _chooseExportPeriods(pdf: true);
    if (choice == null) return;
    final selectedSchedules = choice.periods
        .map(_scheduleForExportPeriod)
        .toList();
    final sheets = [
      for (var index = 0; index < choice.periods.length; index++)
        _createPdfSheet(
          _exportTitle([choice.periods[index]]),
          selectedSchedules[index],
        ),
    ];
    final periodSuffix = choice.periods.join('-');
    final suggestedName = teacherMode
        ? 'grade-docente-${_teacher ?? 'docente'}-periodos-$periodSuffix.pdf'
        : 'grade-curso-$_program-periodos-$periodSuffix.pdf';
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Exportar grade colorida em PDF',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (path == null) return;
      final bytes = await _pdfService.generate(
        term: _term,
        sheets: sheets,
        isLightTheme: AppTheme.isLight,
      );
      final outputPath = path.toLowerCase().endsWith('.pdf')
          ? path
          : '$path.pdf';
      await File(outputPath).writeAsBytes(bytes, flush: true);
      _message('PDF colorido exportado com sucesso.');
    } catch (error) {
      _message('N\u00e3o foi poss\u00edvel exportar o PDF: $error');
    }
  }

  Widget _emptyState(String title, String detail) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            color: AppTheme.primary.withAlpha(22),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Icon(
            Icons.calendar_view_week_rounded,
            size: 34,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _panel({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(18),
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      gradient: AppTheme.cardGradient,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppTheme.divider.withAlpha(180)),
    ),
    child: child,
  );
  Widget _icon(IconData icon, Color color) => Container(
    width: 46,
    height: 46,
    decoration: BoxDecoration(
      color: color.withAlpha(35),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Icon(icon, color: color),
  );
  Widget _infoPill(IconData icon, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: AppTheme.bgCard.withAlpha(160),
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AppTheme.textSecondary),
        const SizedBox(width: 7),
        Text(
          value,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _TeacherDistribution {
  const _TeacherDistribution({
    required this.name,
    required this.disciplines,
    required this.classCount,
    required this.theoryHours,
    required this.practiceHours,
    required this.eadHours,
    required this.extensionHours,
    required this.periods,
  });

  final String name;
  final List<String> disciplines;
  final int classCount;
  final int theoryHours;
  final int practiceHours;
  final int eadHours;
  final int extensionHours;
  final List<String> periods;
}

class _TeacherDistributionRecord {
  const _TeacherDistributionRecord({
    required this.teacher,
    required this.discipline,
    required this.period,
    required this.theoryHours,
    required this.practiceHours,
    this.eadHours = 0,
    this.extensionHours = 0,
  });

  final String teacher;
  final String discipline;
  final String period;
  final int theoryHours;
  final int practiceHours;
  final int eadHours;
  final int extensionHours;

  Map<String, Object> toJson() => {
    'teacher': teacher,
    'discipline': discipline,
    'period': period,
    'theoryHours': theoryHours,
    'practiceHours': practiceHours,
    'eadHours': eadHours,
    'extensionHours': extensionHours,
  };

  factory _TeacherDistributionRecord.fromJson(Map<String, dynamic> json) =>
      _TeacherDistributionRecord(
        teacher: json['teacher'] as String? ?? '',
        discipline: json['discipline'] as String? ?? '',
        period: json['period'] as String? ?? '',
        theoryHours: (json['theoryHours'] as num?)?.toInt() ?? 0,
        practiceHours: (json['practiceHours'] as num?)?.toInt() ?? 0,
        eadHours: (json['eadHours'] as num?)?.toInt() ?? 0,
        extensionHours: (json['extensionHours'] as num?)?.toInt() ?? 0,
      );
}

class _HorarioEditorDialog extends StatefulWidget {
  const _HorarioEditorDialog({
    required this.entries,
    required this.selectedProgram,
    required this.selectedPeriod,
  });
  final List<HorarioDisciplina> entries;
  final int selectedProgram;
  final int selectedPeriod;
  @override
  State<_HorarioEditorDialog> createState() => _HorarioEditorDialogState();
}

class _HorarioEditorDialogState extends State<_HorarioEditorDialog> {
  final _code = TextEditingController();
  final _acronym = TextEditingController();
  final _name = TextEditingController();
  final _class = TextEditingController();
  final _teacher = TextEditingController();
  final _room = TextEditingController();
  final _theoryHours = TextEditingController();
  final _practiceHours = TextEditingController();
  final Set<String> _slots = {};
  String? _selectedId;
  String? _newEntryId;
  String? get _activeNewEntryId => _newEntryId;
  bool get _creating => _activeNewEntryId != null;
  HorarioDisciplina? get _selected => [
    ...widget.entries,
    if (_creating) _blank(),
  ].where((e) => e.id == _selectedId).firstOrNull;

  HorarioDisciplina _blank() => HorarioDisciplina(
    id: _activeNewEntryId!,
    code: '',
    acronym: '',
    name: '',
    className: '',
    teacher: '',
    room: '',
    theoryHours: 0,
    practiceHours: 0,
    coursePeriods: [
      CursoPeriodo(
        program: widget.selectedProgram,
        period: widget.selectedPeriod,
      ),
    ],
    slots: const [],
  );

  @override
  void initState() {
    super.initState();
    if (_creating || widget.entries.isEmpty) {
      _newEntryId ??= const Uuid().v4();
      _selectedId = _activeNewEntryId;
      _select(_blank());
    } else if (widget.entries.isNotEmpty) {
      _selectedId = widget.entries.first.id;
      _select(widget.entries.first);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _code,
      _acronym,
      _name,
      _class,
      _teacher,
      _room,
      _theoryHours,
      _practiceHours,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _select(HorarioDisciplina entry) {
    _code.text = entry.code;
    _acronym.text = entry.acronym;
    _name.text = entry.name;
    _class.text = entry.className;
    _teacher.text = entry.teacherNames.join(', ');
    _room.text = entry.room;
    _theoryHours.text = '${entry.theoryHours}';
    _practiceHours.text = '${entry.practiceHours}';
    _slots
      ..clear()
      ..addAll(entry.slots.map((slot) => slot.key));
  }

  void _switchEntry(String? id) {
    if (id == null) return;
    final entry = [
      ...widget.entries,
      if (_creating) _blank(),
    ].where((e) => e.id == id).firstOrNull;
    if (entry == null) return;
    setState(() {
      _selectedId = id;
      _select(entry);
    });
  }

  void _startCreating() {
    setState(() {
      _newEntryId = const Uuid().v4();
      _selectedId = _newEntryId;
      _select(_blank());
    });
  }

  void _returnToExisting() {
    if (widget.entries.isEmpty) return;
    setState(() {
      _newEntryId = null;
      _selectedId = widget.entries.first.id;
      _select(widget.entries.first);
    });
  }

  Future<void> _deleteSelected() async {
    final selected = _selected;
    if (selected == null || _creating) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apagar disciplina?'),
        content: Text(
          'A disciplina ${selected.acronym} - ${selected.name}, turma ${selected.className}, ser\u00e1 removida da grade deste per\u00edodo letivo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, _HorarioEditorResult.delete(selected.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _selected;
    return Dialog(
      child: SizedBox(
        width: 1000,
        height: 760,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _creating ? 'Nova disciplina' : 'Editor de horários',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Edite o cadastro e marque os blocos da semana.',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (!_creating && widget.entries.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: DropdownMenu<String>(
                        initialSelection: _selectedId,
                        label: const Text('Disciplina do período'),
                        expandedInsets: EdgeInsets.zero,
                        enableFilter: true,
                        requestFocusOnTap: true,
                        menuHeight: 360,
                        filterCallback: (entries, filter) {
                          final query = filter.trim().toLowerCase();
                          if (query.isEmpty) return entries;
                          return entries
                              .where(
                                (entry) =>
                                    entry.label.toLowerCase().contains(query),
                              )
                              .toList();
                        },
                        dropdownMenuEntries: widget.entries
                            .map(
                              (entry) => DropdownMenuEntry<String>(
                                value: entry.id,
                                label:
                                    '${entry.acronym} · ${entry.name} · turma ${entry.className}',
                                style: const ButtonStyle(),
                              ),
                            )
                            .toList(),
                        onSelected: _switchEntry,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Adicionar disciplina',
                      onPressed: _startCreating,
                      icon: const Icon(Icons.add_rounded),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      tooltip: 'Apagar disciplina selecionada',
                      onPressed: _deleteSelected,
                      style: IconButton.styleFrom(
                        foregroundColor: AppTheme.danger,
                      ),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                )
              else if (_creating && widget.entries.isNotEmpty)
                Row(
                  children: [
                    Chip(
                      avatar: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Nova disciplina'),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _returnToExisting,
                      icon: const Icon(Icons.list_rounded),
                      label: const Text('Voltar para a lista'),
                    ),
                  ],
                ),
              const SizedBox(height: 14),
              Expanded(
                child: item == null
                    ? const Center(child: CircularProgressIndicator())
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 335,
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _field(_code, 'Código'),
                                  const SizedBox(height: 9),
                                  _field(_acronym, 'Sigla'),
                                  const SizedBox(height: 9),
                                  _field(_name, 'Nome da disciplina'),
                                  const SizedBox(height: 9),
                                  Row(
                                    children: [
                                      Expanded(child: _field(_class, 'Turma')),
                                      const SizedBox(width: 9),
                                      Expanded(child: _field(_room, 'Sala')),
                                    ],
                                  ),
                                  const SizedBox(height: 9),
                                  _field(
                                    _teacher,
                                    'Docente(s), separados por vírgula',
                                  ),
                                  const SizedBox(height: 9),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _field(
                                          _theoryHours,
                                          'CH Teórica',
                                          keyboardType: TextInputType.number,
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: _field(
                                          _practiceHours,
                                          'CH Prática',
                                          keyboardType: TextInputType.number,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'HORÁRIOS DA SEMANA',
                                      style: TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 10,
                                        letterSpacing: 1.1,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      '${_slots.length} blocos selecionados',
                                      style: TextStyle(
                                        color: AppTheme.primaryLight,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: Column(
                                      children: [
                                        Row(
                                          children: [
                                            const SizedBox(width: 105),
                                            for (final day in horarioDias)
                                              Expanded(
                                                child: Center(
                                                  child: Text(
                                                    day.substring(0, 3),
                                                    style: TextStyle(
                                                      color: AppTheme
                                                          .textSecondary,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        for (
                                          var slot = 1;
                                          slot <= horarioFaixas.length;
                                          slot++
                                        )
                                          SizedBox(
                                            height: 42,
                                            child: Row(
                                              children: [
                                                SizedBox(
                                                  width: 105,
                                                  child: Text(
                                                    horarioFaixas[slot - 1],
                                                    style: TextStyle(
                                                      color: AppTheme
                                                          .textSecondary,
                                                      fontSize: 10,
                                                    ),
                                                  ),
                                                ),
                                                for (
                                                  var day = 1;
                                                  day <= 5;
                                                  day++
                                                )
                                                  Expanded(
                                                    child: Center(
                                                      child: Checkbox(
                                                        value: _slots.contains(
                                                          '$day:$slot',
                                                        ),
                                                        onChanged: (selected) =>
                                                            setState(() {
                                                              if (selected ==
                                                                  true) {
                                                                _slots.add(
                                                                  '$day:$slot',
                                                                );
                                                              } else {
                                                                _slots.remove(
                                                                  '$day:$slot',
                                                                );
                                                              }
                                                            }),
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 9),
                                Container(
                                  padding: const EdgeInsets.all(11),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primary.withAlpha(16),
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Text(
                                    'Os blocos usam a mesma codificação da planilha original. Sobreposições são mantidas e destacadas na grade para revisão.',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 10,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: item == null ? null : _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Salvar disciplina e horários'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
  }) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    decoration: InputDecoration(labelText: label, isDense: true),
  );

  List<String> _teacherNamesFromField() {
    final names = <String>[];
    final normalized = <String>{};
    for (final value in _teacher.text.split(RegExp(r'[,;\n]'))) {
      final name = value.trim();
      if (name.isNotEmpty && normalized.add(name.toLowerCase())) {
        names.add(name);
      }
    }
    return names;
  }

  void _save() {
    if (_name.text.trim().isEmpty || _acronym.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe ao menos o nome e a sigla da disciplina.'),
        ),
      );
      return;
    }
    final source = _selected ?? _blank();
    Navigator.pop(
      context,
      _HorarioEditorResult.save(
        source.copyWith(
          code: _code.text.trim(),
          acronym: _acronym.text.trim(),
          name: _name.text.trim(),
          className: _class.text.trim(),
          teacher: _teacherNamesFromField().firstOrNull ?? '',
          coTeachers: _teacherNamesFromField().skip(1).toList(),
          room: _room.text.trim(),
          theoryHours: int.tryParse(_theoryHours.text.trim()) ?? 0,
          practiceHours: int.tryParse(_practiceHours.text.trim()) ?? 0,
          slots:
              _slots.map((key) {
                final p = key.split(':');
                return HorarioSlot(
                  weekday: int.parse(p[0]),
                  slot: int.parse(p[1]),
                );
              }).toList()..sort(
                (a, b) => a.weekday != b.weekday
                    ? a.weekday.compareTo(b.weekday)
                    : a.slot.compareTo(b.slot),
              ),
        ),
      ),
    );
  }
}

class _ScheduleExportChoice {
  const _ScheduleExportChoice({required this.periods});

  final List<int> periods;
}

enum _HorarioEditorAction { save, delete }

class _HorarioEditorResult {
  const _HorarioEditorResult.save(this.entry)
    : action = _HorarioEditorAction.save,
      id = null;

  const _HorarioEditorResult.delete(this.id)
    : action = _HorarioEditorAction.delete,
      entry = null;

  final _HorarioEditorAction action;
  final HorarioDisciplina? entry;
  final String? id;
}

class _TermCopyChoice {
  const _TermCopyChoice.blank() : sourceTerm = null;
  const _TermCopyChoice.copy(this.sourceTerm);

  final String? sourceTerm;
}
