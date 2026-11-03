import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/data/services/ajusta_horarios_pdf_service.dart';
import 'package:config_moodle/data/services/ajusta_horarios_store.dart';
import 'package:config_moodle/domain/entities/ajusta_horarios.dart';
import 'package:config_moodle/presentation/widgets/common_widgets.dart';

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
  static const _teacherRosterKey = 'ajusta_horarios_docentes_cadastrados';
  static const _roomKey = 'ajusta_horarios_sala_selecionada';
  static const _roomRosterKey = 'ajusta_horarios_salas_cadastradas';
  static const _scrollPrefix = 'ajusta_horarios_grade_scroll_';
  final _courseVerticalScroll = ScrollController();
  final _courseHorizontalScroll = ScrollController();
  final _teacherVerticalScroll = ScrollController();
  final _teacherHorizontalScroll = ScrollController();
  final _roomVerticalScroll = ScrollController();
  final _roomHorizontalScroll = ScrollController();
  final _distributionHorizontalScroll = ScrollController();
  final Map<String, double> _scrollOffsets = {};
  WindowMethodChannel? _scheduleEditorChannel;
  WindowController? _scheduleEditorController;
  bool _openingScheduleEditor = false;
  WindowMethodChannel? _teacherEditorChannel;
  WindowController? _teacherEditorController;
  bool _openingTeacherEditor = false;
  WindowMethodChannel? _roomEditorChannel;
  WindowController? _roomEditorController;
  bool _openingRoomEditor = false;
  Timer? _scrollSaveTimer;
  List<HorarioDisciplina> _entries = [];
  List<String> _teacherRoster = [];
  List<String> _roomRoster = [];
  Map<int, String> _programs = {...horarioProgramas};
  List<_TeacherDistributionRecord> _distributionRecords = [];
  Set<String> _hiddenDistributionTeachers = {};
  bool _loading = true;
  bool _busy = false;
  int _program = 1;
  int _period = 1;
  int _view = 0;
  String? _teacher;
  String? _room;
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
      'sala_y': _roomVerticalScroll,
      'sala_x': _roomHorizontalScroll,
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
    _roomVerticalScroll.dispose();
    _roomHorizontalScroll.dispose();
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
        await prefs.setDouble(
          _termScopedKey('$_scrollPrefix${item.key}', _term),
          item.value,
        );
      }
    });
  }

  Future<void> _saveViewSelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_termScopedKey(_programKey, _term), _program);
    await prefs.setInt(_termScopedKey(_periodKey, _term), _period);
    await prefs.setInt(_termScopedKey(_viewKey, _term), _view);
    if (_teacher != null) {
      await prefs.setString(_termScopedKey(_teacherKey, _term), _teacher!);
    } else {
      await prefs.remove(_termScopedKey(_teacherKey, _term));
    }
    if (_room != null) {
      await prefs.setString(_termScopedKey(_roomKey, _term), _room!);
    } else {
      await prefs.remove(_termScopedKey(_roomKey, _term));
    }
  }

  void _restoreCurrentTableScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _view > 2) return;
      final vertical = _view == 0
          ? _courseVerticalScroll
          : _view == 1
          ? _teacherVerticalScroll
          : _roomVerticalScroll;
      final horizontal = _view == 0
          ? _courseHorizontalScroll
          : _view == 1
          ? _teacherHorizontalScroll
          : _roomHorizontalScroll;
      final prefix = switch (_view) {
        0 => 'curso',
        1 => 'docente',
        _ => 'sala',
      };
      _restoreScroll(vertical, '${prefix}_y');
      _restoreScroll(horizontal, '${prefix}_x');
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
      var rows = await _store.load(term: activeTerm);
      final inferredTeachers =
          rows.expand((entry) => entry.teacherNames).toSet().toList()..sort();
      final savedRoster = prefs.getStringList(
        _termScopedKey(_teacherRosterKey, activeTerm),
      );
      final teacherRoster = (savedRoster ?? inferredTeachers).toSet().toList()
        ..sort();
      if (savedRoster == null) {
        await prefs.setStringList(
          _termScopedKey(_teacherRosterKey, activeTerm),
          teacherRoster,
        );
      }
      final savedTeacher = prefs.getString(
        _termScopedKey(_teacherKey, activeTerm),
      );
      final inferredRooms =
          rows
              .map((entry) => entry.room.trim())
              .where((room) => room.isNotEmpty)
              .toSet()
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final savedRooms = prefs.getStringList(
        _termScopedKey(_roomRosterKey, activeTerm),
      );
      final roomRoster = (savedRooms ?? inferredRooms).toSet().toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (savedRooms == null) {
        await prefs.setStringList(
          _termScopedKey(_roomRosterKey, activeTerm),
          roomRoster,
        );
      }
      final savedRoom = prefs.getString(_termScopedKey(_roomKey, activeTerm));
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
      teacherRoster
        ..addAll(
          distribution
              .map((record) => record.teacher.trim())
              .where((name) => name.isNotEmpty),
        )
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (savedRoster == null || teacherRoster.length != savedRoster.length) {
        await prefs.setStringList(
          _termScopedKey(_teacherRosterKey, activeTerm),
          teacherRoster,
        );
      }
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
      final abiMigrationKey =
          'ajusta_horarios_abi_automacao_v1_${base64Url.encode(utf8.encode(activeTerm)).replaceAll('=', '')}';
      if (prefs.getBool(abiMigrationKey) != true) {
        final abiName = 'ABI em Automa\u00e7\u00e3o, Rob\u00f3tica e IA';
        int? abiProgram;
        for (final item in usablePrograms.entries) {
          if (item.value.trim().toLowerCase() == abiName.toLowerCase()) {
            abiProgram = item.key;
            break;
          }
        }
        if (abiProgram == null) {
          abiProgram = usablePrograms.keys.isEmpty
              ? 1
              : usablePrograms.keys.reduce((a, b) => a > b ? a : b) + 1;
          usablePrograms[abiProgram] = abiName;
        }
        final abiProgramId = abiProgram;

        var entriesChanged = false;
        final abiSubjects =
            <
              ({
                String id,
                String acronym,
                String name,
                int theory,
                int practice,
                int ead,
                int extension,
              })
            >[
              (
                id: '01',
                acronym: 'EMP',
                name: 'Empreendedorismo e Inova\u00e7\u00e3o',
                theory: 2,
                practice: 0,
                ead: 0,
                extension: 0,
              ),
              (
                id: '02',
                acronym: 'DCF',
                name: 'Dispositivos Ciberf\u00edsicos para IoT e IIoT',
                theory: 0,
                practice: 1,
                ead: 4,
                extension: 0,
              ),
              (
                id: '03',
                acronym: 'IABI',
                name:
                    'Introdu\u00e7\u00e3o \u00e0 \u00c1rea B\u00e1sica de Ingresso em Automa\u00e7\u00e3o, Rob\u00f3tica e IA',
                theory: 2,
                practice: 0,
                ead: 0,
                extension: 0,
              ),
              (
                id: '04',
                acronym: 'AMS I',
                name: 'An\u00e1lise e Modelagem de Sistemas I',
                theory: 2,
                practice: 0,
                ead: 2,
                extension: 0,
              ),
              (
                id: '05',
                acronym: 'CAME',
                name:
                    'Ci\u00eancia e Aplica\u00e7\u00e3o dos Materiais El\u00e9tricos',
                theory: 0,
                practice: 0,
                ead: 2,
                extension: 0,
              ),
              (
                id: '06',
                acronym: 'SDA',
                name: 'Sistemas Digitais para Automa\u00e7\u00e3o',
                theory: 2,
                practice: 2,
                ead: 0,
                extension: 0,
              ),
            ];

        bool belongsToAbi(HorarioDisciplina entry) => entry.coursePeriods.any(
          (item) => item.program == abiProgramId && item.period == 1,
        );
        bool sameDiscipline(HorarioDisciplina entry, String name) =>
            entry.name.trim().toLowerCase() == name.toLowerCase();

        for (final subject in abiSubjects) {
          final existingIndex = rows.indexWhere(
            (entry) => sameDiscipline(entry, subject.name),
          );
          if (existingIndex >= 0) {
            final existing = rows[existingIndex];
            if (!belongsToAbi(existing)) {
              rows[existingIndex] = existing.copyWith(
                coursePeriods: [
                  ...existing.coursePeriods,
                  CursoPeriodo(program: abiProgramId, period: 1),
                ],
              );
              entriesChanged = true;
            }
            continue;
          }
          rows.add(
            HorarioDisciplina(
              id: 'abi_${activeTerm.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}_${subject.id}',
              code: '',
              acronym: subject.acronym,
              name: subject.name,
              className: '',
              teachers: const [],
              room: '',
              theoryHours: subject.theory,
              practiceHours: subject.practice,
              eadHours: subject.ead,
              extensionHours: subject.extension,
              coursePeriods: [CursoPeriodo(program: abiProgramId, period: 1)],
              slots: const [],
            ),
          );
          entriesChanged = true;
        }

        final expressionIndex = rows.indexWhere(
          (entry) =>
              entry.acronym.trim().toUpperCase() == 'EXPG' ||
              entry.name.trim().toLowerCase().startsWith('express'),
        );
        if (expressionIndex >= 0 && !belongsToAbi(rows[expressionIndex])) {
          final expression = rows[expressionIndex];
          rows[expressionIndex] = expression.copyWith(
            coursePeriods: [
              ...expression.coursePeriods,
              CursoPeriodo(program: abiProgramId, period: 1),
            ],
          );
          entriesChanged = true;
        }

        await prefs.setString(
          _programsKey,
          jsonEncode({
            for (final entry in usablePrograms.entries)
              '${entry.key}': entry.value,
          }),
        );
        if (entriesChanged) await _store.save(rows, term: activeTerm);
        await prefs.setBool(abiMigrationKey, true);
      }
      final savedProgram =
          prefs.getInt(_termScopedKey(_programKey, activeTerm)) ?? _program;
      if (mounted) {
        setState(() {
          _entries = rows;
          _teacherRoster = teacherRoster;
          _roomRoster = roomRoster;
          _terms = terms;
          _term = activeTerm;
          _programs = usablePrograms;
          _distributionRecords = distribution;
          _hiddenDistributionTeachers = hiddenTeachers;
          _program = usablePrograms.containsKey(savedProgram)
              ? savedProgram
              : usablePrograms.keys.first;
          _period =
              (prefs.getInt(_termScopedKey(_periodKey, activeTerm)) ?? _period)
                  .clamp(1, 11)
                  .toInt();
          _view = (prefs.getInt(_termScopedKey(_viewKey, activeTerm)) ?? _view)
              .clamp(0, 3)
              .toInt();
          _teacher = savedTeacher;
          _room = savedRoom != null && roomRoster.contains(savedRoom)
              ? savedRoom
              : roomRoster.firstOrNull;
          for (final key in const [
            'curso_y',
            'curso_x',
            'docente_y',
            'docente_x',
            'sala_y',
            'sala_x',
          ]) {
            _scrollOffsets[key] =
                prefs.getDouble(
                  _termScopedKey('$_scrollPrefix$key', activeTerm),
                ) ??
                0;
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
                          leading: CircleAvatar(
                            child: Text(
                              '${(programs.keys.toList()..sort()).indexOf(entry.key) + 1}',
                            ),
                          ),
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
  List<String> get _teachers => {
    ..._teacherRoster,
    ..._entries
        .expand((entry) => entry.teacherNames)
        .where((e) => e.isNotEmpty),
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  List<String> get _rooms => {
    ..._roomRoster,
    ..._entries
        .map((entry) => entry.room.trim())
        .where((room) => room.isNotEmpty),
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  Map<String, List<HorarioDisciplina>> _schedule({
    int? program,
    int? period,
    String? teacher,
    String? room,
  }) {
    final result = <String, List<HorarioDisciplina>>{};
    for (final entry in _entries) {
      if (entry.modality == 'ead') continue;
      final include = room != null
          ? entry.room.trim().toLowerCase() == room.trim().toLowerCase()
          : teacher != null
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
                          : _view == 2
                          ? _roomView(compact)
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
            const SizedBox(width: 8),
            const ThemeSelector(compact: true),
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
                    icon: Icon(Icons.meeting_room_outlined),
                    label: Text('Grade por sala'),
                  ),
                  ButtonSegment(
                    value: 3,
                    icon: Icon(Icons.groups_2_outlined),
                    label: Text('Distribui\u00e7\u00e3o Docente'),
                  ),
                ],
                selected: {_view},
                onSelectionChanged: (v) {
                  setState(() {
                    _view = v.first;
                    if (_teachers.isNotEmpty) _teacher ??= _teachers.first;
                    if (_rooms.isNotEmpty) _room ??= _rooms.first;
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
      } else {
        await _clearTermData(term);
      }
      final updatedTerms = [..._terms, term];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_termsKey, updatedTerms);
      if (mounted) setState(() => _terms = updatedTerms);
    }
    await _activateTerm(term);
  }

  Future<void> _copyTermData(String source, String destination) async {
    if (source == destination) return;
    await _clearTermData(destination);
    final sourceEntries = await _store.load(term: source);
    final entries = sourceEntries
        .map(
          (entry) => HorarioDisciplina.fromJson(
            Map<String, dynamic>.from(entry.toJson()),
          ),
        )
        .toList();
    await _store.save(entries, term: destination);
    final prefs = await SharedPreferences.getInstance();
    final sourceDistribution = prefs.getString(
      _termScopedKey(_distributionKey, source),
    );
    var distributionTeachers = <String>{};
    if (sourceDistribution != null) {
      final decoded = (jsonDecode(sourceDistribution) as List)
          .map(
            (item) => _TeacherDistributionRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
      distributionTeachers = decoded
          .map((record) => record.teacher.trim())
          .where((name) => name.isNotEmpty)
          .toSet();
      await prefs.setString(
        _termScopedKey(_distributionKey, destination),
        jsonEncode(decoded.map((record) => record.toJson()).toList()),
      );
    }
    final sourceRoster = prefs.getStringList(
      _termScopedKey(_teacherRosterKey, source),
    );
    final roster = (sourceRoster ?? <String>[]).toSet()
      ..addAll(entries.expand((entry) => entry.teacherNames))
      ..addAll(distributionTeachers);
    await prefs.setStringList(
      _termScopedKey(_teacherRosterKey, destination),
      roster.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
    );
    final sourceRooms = prefs.getStringList(
      _termScopedKey(_roomRosterKey, source),
    );
    final copiedRooms = <String>{
      ...?sourceRooms,
      ...entries
          .map((entry) => entry.room.trim())
          .where((room) => room.isNotEmpty),
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await prefs.setStringList(
      _termScopedKey(_roomRosterKey, destination),
      copiedRooms,
    );
    final sourceHidden = prefs.getStringList(
      _termScopedKey(_hiddenDistributionTeachersKey, source),
    );
    if (sourceHidden != null) {
      await prefs.setStringList(
        _termScopedKey(_hiddenDistributionTeachersKey, destination),
        List<String>.from(sourceHidden),
      );
    }
  }

  Future<void> _clearTermData(String term) async {
    await _store.clear(term: term);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_termScopedKey(_distributionKey, term));
    await prefs.remove(_termScopedKey(_hiddenDistributionTeachersKey, term));
    await prefs.setStringList(
      _termScopedKey(_teacherRosterKey, term),
      const [],
    );
    await prefs.setStringList(_termScopedKey(_roomRosterKey, term), const []);
    for (final key in [
      _teacherKey,
      _programKey,
      _periodKey,
      _viewKey,
      ...const [
        'curso_y',
        'curso_x',
        'docente_y',
        'docente_x',
        'sala_y',
        'sala_x',
      ].map((key) => '$_scrollPrefix$key'),
      _roomKey,
    ]) {
      await prefs.remove(_termScopedKey(key, term));
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
      final inferredRoster = <String>{
        ...rows.expand((entry) => entry.teacherNames),
        ...distribution.map((record) => record.teacher.trim()),
      }..removeWhere((name) => name.isEmpty);
      final savedRoster = prefs.getStringList(
        _termScopedKey(_teacherRosterKey, term),
      );
      final roster = (savedRoster ?? inferredRoster.toList()).toSet().toList()
        ..addAll(inferredRoster)
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (savedRoster == null || roster.length != savedRoster.length) {
        await prefs.setStringList(
          _termScopedKey(_teacherRosterKey, term),
          roster,
        );
      }
      final names = <String>{
        ...roster,
        ...rows.expand((entry) => entry.teacherNames),
      };
      final inferredRooms = rows
          .map((entry) => entry.room.trim())
          .where((room) => room.isNotEmpty)
          .toSet();
      final savedRooms = prefs.getStringList(
        _termScopedKey(_roomRosterKey, term),
      );
      final roomRoster = (savedRooms ?? inferredRooms.toList()).toSet().toList()
        ..addAll(inferredRooms)
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      await prefs.setStringList(
        _termScopedKey(_roomRosterKey, term),
        roomRoster,
      );
      final savedRoom = prefs.getString(_termScopedKey(_roomKey, term));
      final savedTeacher = prefs.getString(_termScopedKey(_teacherKey, term));
      final savedProgram =
          prefs.getInt(_termScopedKey(_programKey, term)) ?? _program;
      final savedPeriod = prefs.getInt(_termScopedKey(_periodKey, term)) ?? 1;
      final savedView = prefs.getInt(_termScopedKey(_viewKey, term)) ?? _view;
      final offsets = <String, double>{
        for (final key in const [
          'curso_y',
          'curso_x',
          'docente_y',
          'docente_x',
          'sala_y',
          'sala_x',
        ])
          key: prefs.getDouble(_termScopedKey('$_scrollPrefix$key', term)) ?? 0,
      };
      if (!mounted) return;
      setState(() {
        _term = term;
        _entries = rows;
        _teacherRoster = roster;
        _distributionRecords = distribution;
        _hiddenDistributionTeachers = hidden;
        _program = _programs.containsKey(savedProgram)
            ? savedProgram
            : _programs.keys.first;
        _period = savedPeriod.clamp(1, 11).toInt();
        _view = savedView.clamp(0, 3).toInt();
        _teacher = names.contains(savedTeacher)
            ? savedTeacher
            : (names.isEmpty ? null : names.first);
        _roomRoster = roomRoster;
        _room = roomRoster.contains(savedRoom)
            ? savedRoom
            : roomRoster.firstOrNull;
        _scrollOffsets
          ..clear()
          ..addAll(offsets);
        _loading = false;
      });
      await _saveViewSelection();
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
                        child: _SearchableSelect<int>(
                          key: ValueKey('curso-$_program'),
                          value: _program,
                          options: _programs.keys.toList(),
                          label: 'Curso',
                          optionLabel: (program) => _programs[program] ?? '',
                          icon: Icons.school_rounded,
                          onSelected: (value) {
                            setState(() {
                              _program = value;
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
                  child: _SearchableSelect<String>(
                    key: ValueKey('docente-$_teacher'),
                    value: _teacher!,
                    options: teachers,
                    label: 'Docente',
                    optionLabel: (name) => name,
                    icon: Icons.person_rounded,
                    onSelected: _selectTeacher,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _editTeachers,
                  icon: const Icon(Icons.manage_accounts_rounded),
                  label: const Text('Editar docentes'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _editPeriod,
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
          Expanded(child: _timetable(schedule, compact)),
        ],
      ),
    );
  }

  Widget _roomView(bool compact) {
    final rooms = _rooms;
    final selectedRoom = rooms.contains(_room) ? _room : rooms.firstOrNull;
    if (_room != selectedRoom) _room = selectedRoom;
    final schedule = selectedRoom == null
        ? <String, List<HorarioDisciplina>>{}
        : _schedule(room: selectedRoom);
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
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 12,
              children: [
                if (selectedRoom != null)
                  SizedBox(
                    width: compact ? 280 : 440,
                    child: _SearchableSelect<String>(
                      key: ValueKey('room-$selectedRoom'),
                      value: selectedRoom,
                      options: rooms,
                      label: 'Sala',
                      optionLabel: (room) => room,
                      icon: Icons.meeting_room_outlined,
                      onSelected: _selectRoom,
                    ),
                  )
                else
                  SizedBox(
                    width: compact ? 280 : 440,
                    child: const InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Sala',
                        prefixIcon: Icon(Icons.meeting_room_outlined),
                      ),
                      child: Text('Cadastre ou vincule uma sala'),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _busy ? null : _editRooms,
                  icon: const Icon(Icons.meeting_room_outlined),
                  label: const Text('Editar Sala'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _editPeriod,
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
          Expanded(
            child: selectedRoom == null
                ? _emptyState(
                    'Nenhuma sala cadastrada',
                    'Use “Editar Sala” para cadastrar salas e vinculá-las às turmas.',
                  )
                : _timetable(schedule, compact),
          ),
        ],
      ),
    );
  }

  Future<void> _selectRoom(String room) async {
    if (mounted && _room != room) setState(() => _room = room);
    await _saveViewSelection();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_termScopedKey(_roomKey, _term), room);
    await _roomEditorChannel?.invokeMethod<bool>('selectRoom', room);
    _restoreCurrentTableScroll();
  }

  Future<void> _editRooms() async {
    final activeChannel = _roomEditorChannel;
    final activeController = _roomEditorController;
    if (activeChannel != null && activeController != null) {
      final windows = await WindowController.getAll();
      if (windows.any(
        (window) => window.windowId == activeController.windowId,
      )) {
        if (_room != null) {
          await activeChannel.invokeMethod<bool>('selectRoom', _room);
        }
        await activeController.show();
        return;
      }
      await activeChannel.setMethodCallHandler(null);
      _roomEditorChannel = null;
      _roomEditorController = null;
    }
    if (_openingRoomEditor) return;
    _openingRoomEditor = true;
    final channelName = 'gestor_ufu_rooms_${const Uuid().v4()}';
    final channel = WindowMethodChannel(
      channelName,
      mode: ChannelMode.bidirectional,
    );
    try {
      await channel.setMethodCallHandler((call) async {
        if (call.method == 'saveRooms' || call.method == 'closed') {
          final payload = Map<String, dynamic>.from(call.arguments as Map);
          await _applyRoomRosterResult(
            (payload['rooms'] as List).cast<String>(),
            (payload['entries'] as List)
                .map(
                  (item) => HorarioDisciplina.fromJson(
                    Map<String, dynamic>.from(item as Map),
                  ),
                )
                .toList(),
          );
          return true;
        }
        if (call.method == 'roomSelected') {
          final room = call.arguments as String?;
          if (room != null && room.trim().isNotEmpty) {
            if (mounted) {
              setState(() {
                if (!_roomRoster.contains(room)) _roomRoster.add(room);
                _room = room;
              });
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.setStringList(
              _termScopedKey(_roomRosterKey, _term),
              _roomRoster,
            );
            await prefs.setString(_termScopedKey(_roomKey, _term), room);
            await _saveViewSelection();
            return true;
          }
          return false;
        }
        throw MissingPluginException('Método não reconhecido: ${call.method}');
      });
      _roomEditorChannel = channel;
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({
            'type': 'roomEditor',
            'channel': channelName,
            'rooms': _rooms,
            'entries': _entries.map((entry) => entry.toJson()).toList(),
            'programs': _programs.map((key, value) => MapEntry('$key', value)),
            'initialRoom': _room,
            'isLight': AppTheme.isLight,
          }),
        ),
      );
      _roomEditorController = controller;
      await controller.show();
    } catch (_) {
      await channel.setMethodCallHandler(null);
      _roomEditorChannel = null;
      _roomEditorController = null;
      rethrow;
    } finally {
      _openingRoomEditor = false;
    }
  }

  Future<void> _applyRoomRosterResult(
    List<String> rooms,
    List<HorarioDisciplina> entries,
  ) async {
    final normalizedRooms =
        rooms
            .map((room) => room.trim())
            .where((room) => room.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    setState(() {
      _roomRoster = normalizedRooms;
      _entries = entries;
      if (!_roomRoster.contains(_room)) _room = _roomRoster.firstOrNull;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _termScopedKey(_roomRosterKey, _term),
      _roomRoster,
    );
    if (_room != null) {
      await prefs.setString(_termScopedKey(_roomKey, _term), _room!);
    } else {
      await prefs.remove(_termScopedKey(_roomKey, _term));
    }
    await _persist();
    await _saveViewSelection();
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
                    child: LayoutBuilder(
                      builder: (context, constraints) => Scrollbar(
                        controller: _distributionHorizontalScroll,
                        thumbVisibility: true,
                        notificationPredicate: (notification) =>
                            notification.metrics.axis == Axis.horizontal,
                        child: SingleChildScrollView(
                          controller: _distributionHorizontalScroll,
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth,
                            ),
                            child: Center(
                              child: _distributionTableDetailed(summaries),
                            ),
                          ),
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

  static const List<double> _distributionColumnWidths = [
    48,
    235,
    420,
    70,
    70,
    64,
    70,
    100,
    76,
    76,
    100,
  ];

  Widget _distributionTableDetailed(List<_TeacherDistribution> summaries) {
    final children = <Widget>[_distributionHeaderRow()];
    var teacherId = 0;
    for (final summary in summaries) {
      final lines = _distributionLines(
        summary.name,
      ).where((line) => line.discipline.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      teacherId++;
      final total = lines.fold<int>(0, (sum, line) => sum + line.total);
      final background = (teacherId - 1).isEven
          ? AppTheme.bgCard.withAlpha(100)
          : AppTheme.bgCardAlt.withAlpha(130);
      children.add(
        _distributionTeacherGroup(
          id: teacherId,
          name: summary.name,
          lines: lines,
          total: total,
          background: background,
        ),
      );
    }
    children.addAll(_distributionStatisticsWidgets(summaries));
    return SizedBox(
      width: _distributionColumnWidths.fold<double>(
        0,
        (sum, width) => sum + width,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _distributionHeaderRow() {
    const labels = [
      'ID',
      'Professor',
      'Disciplina',
      'CH\nTe\u00f3rica',
      'CH\nPr\u00e1tica',
      'CH\nEaD',
      'Soma',
      'Total\ndocente',
      'CH\nExtens\u00e3o',
      'Nº\nTurmas',
      'Per\u00edodos',
    ];
    return Row(
      children: [
        for (var index = 0; index < labels.length; index++)
          _distributionGridCell(
            labels[index],
            width: _distributionColumnWidths[index],
            header: true,
            centered: index == 0 || index >= 3,
            leftBorder: index == 0,
            bottomBorder: true,
            background: AppTheme.primary.withAlpha(40),
          ),
      ],
    );
  }

  Widget _distributionTeacherGroup({
    required int id,
    required String name,
    required List<_TeacherDistributionLine> lines,
    required int total,
    required Color background,
  }) {
    final onTap = () => _editTeacherDisciplines(name);
    final coreWidth = _distributionColumnWidths
        .sublist(2, 7)
        .fold<double>(0, (sum, width) => sum + width);
    final trailingWidth = _distributionColumnWidths
        .sublist(8)
        .fold<double>(0, (sum, width) => sum + width);
    final lastRow = lines.length - 1;

    Widget disciplineRows({required bool trailing}) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < lines.length; index++)
          SizedBox(
            height: 48,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: trailing
                  ? [
                      _distributionGridCell(
                        '${lines[index].extensionHours}',
                        width: _distributionColumnWidths[8],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                      _distributionGridCell(
                        '${lines[index].classCount}',
                        width: _distributionColumnWidths[9],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                      _distributionGridCell(
                        lines[index].periods.join(', '),
                        width: _distributionColumnWidths[10],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                    ]
                  : [
                      _distributionGridCell(
                        lines[index].discipline,
                        width: _distributionColumnWidths[2],
                        tooltip: lines[index].discipline,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                      _distributionGridCell(
                        '${lines[index].theoryHours}',
                        width: _distributionColumnWidths[3],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                      _distributionGridCell(
                        '${lines[index].practiceHours}',
                        width: _distributionColumnWidths[4],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                      _distributionGridCell(
                        '${lines[index].eadHours}',
                        width: _distributionColumnWidths[5],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                      _distributionGridCell(
                        '${lines[index].total}',
                        width: _distributionColumnWidths[6],
                        centered: true,
                        onTap: onTap,
                        background: background,
                        bottomBorder: index == lastRow,
                      ),
                    ],
            ),
          ),
      ],
    );

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _distributionGridCell(
            '$id',
            width: _distributionColumnWidths[0],
            centered: true,
            onTap: onTap,
            background: background,
            leftBorder: true,
            bottomBorder: true,
          ),
          _distributionGridCell(
            name,
            width: _distributionColumnWidths[1],
            onTap: onTap,
            background: background,
            bottomBorder: true,
          ),
          SizedBox(width: coreWidth, child: disciplineRows(trailing: false)),
          _distributionGridCell(
            '$total',
            width: _distributionColumnWidths[7],
            centered: true,
            onTap: onTap,
            background: background,
            bottomBorder: true,
          ),
          SizedBox(width: trailingWidth, child: disciplineRows(trailing: true)),
        ],
      ),
    );
  }

  Widget _distributionGridCell(
    String value, {
    required double width,
    bool header = false,
    bool centered = false,
    bool bold = false,
    bool leftBorder = false,
    bool bottomBorder = false,
    Color? background,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    final side = BorderSide(color: AppTheme.divider.withAlpha(150), width: 0.7);
    final text = Text(
      value,
      softWrap: true,
      maxLines: header ? 2 : 2,
      overflow: TextOverflow.ellipsis,
      textAlign: centered ? TextAlign.center : TextAlign.left,
      style: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 12,
        fontWeight: header || bold ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: background,
        border: Border(
          left: leftBorder ? side : BorderSide.none,
          right: side,
          bottom: bottomBorder ? side : BorderSide.none,
        ),
      ),
      alignment: centered ? Alignment.center : Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: header ? 9 : 10,
            vertical: header ? 9 : 7,
          ),
          child: tooltip == null
              ? text
              : Tooltip(message: tooltip, child: text),
        ),
      ),
    );
  }

  List<Widget> _distributionStatisticsWidgets(
    List<_TeacherDistribution> summaries,
  ) {
    final lines = summaries
        .expand((summary) => _distributionLines(summary.name))
        .where((line) => line.discipline.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];
    final teacherCount = summaries
        .where((summary) => _distributionLines(summary.name).isNotEmpty)
        .length;
    final theory = lines.fold<int>(0, (sum, line) => sum + line.theoryHours);
    final practice = lines.fold<int>(
      0,
      (sum, line) => sum + line.practiceHours,
    );
    final ead = lines.fold<int>(0, (sum, line) => sum + line.eadHours);
    final extension = lines.fold<int>(
      0,
      (sum, line) => sum + line.extensionHours,
    );
    final total = lines.fold<int>(0, (sum, line) => sum + line.total);
    final classes = lines.fold<int>(0, (sum, line) => sum + line.classCount);
    Widget statsRow(
      List<String> values, {
      Color? background,
      bool bold = false,
    }) => Row(
      children: [
        for (var index = 0; index < values.length; index++)
          _distributionGridCell(
            values[index],
            width: _distributionColumnWidths[index],
            centered: index == 0 || index >= 3,
            bold: bold,
            leftBorder: index == 0,
            bottomBorder: true,
            background: background,
          ),
      ],
    );
    return [
      statsRow(
        [
          '',
          'TOTAL',
          '',
          '$theory',
          '$practice',
          '$ead',
          '$total',
          '$total',
          '$extension',
          '$classes',
          '',
        ],
        background: AppTheme.primary.withAlpha(36),
        bold: true,
      ),
      statsRow([
        '',
        'M\u00c9DIA por professor',
        '',
        (theory / teacherCount).toStringAsFixed(1),
        (practice / teacherCount).toStringAsFixed(1),
        (ead / teacherCount).toStringAsFixed(1),
        (total / teacherCount).toStringAsFixed(1),
        (total / teacherCount).toStringAsFixed(1),
        (extension / teacherCount).toStringAsFixed(1),
        '',
        '',
      ], background: AppTheme.bgCardAlt.withAlpha(150)),
    ];
  }

  List<_TeacherDistributionLine> _distributionLines(String teacher) {
    if (_distributionRecords.isNotEmpty) {
      return _distributionRecords
          .where(
            (record) => record.teacher.toLowerCase() == teacher.toLowerCase(),
          )
          .map(
            (record) => _TeacherDistributionLine(
              discipline: record.discipline,
              theoryHours: record.theoryHours,
              practiceHours: record.practiceHours,
              eadHours: record.eadHours,
              extensionHours: record.extensionHours,
              classCount: 1,
              periods: [
                if (record.period.isEmpty)
                  '—'
                else if (record.period.toLowerCase().contains('optativas'))
                  'Optativas'
                else if (record.period.contains('º'))
                  record.period
                else
                  '${record.period}º',
              ],
            ),
          )
          .toList();
    }

    final grouped = <String, List<HorarioDisciplina>>{};
    for (final entry in _entries) {
      if (!entry.teacherNames.any(
            (name) => name.toLowerCase() == teacher.toLowerCase(),
          ) ||
          !const {
            'theory',
            'practice',
            'ead',
            'extension',
          }.contains(entry.modality) ||
          entry.className.trim().isEmpty) {
        continue;
      }
      grouped.putIfAbsent(entry.subjectId, () => []).add(entry);
    }
    final lines = <_TeacherDistributionLine>[];
    for (final entries in grouped.values) {
      int modalityHours(String modality) => entries
          .where((entry) => entry.modality == modality)
          .map(
            (entry) => switch (modality) {
              'theory' => entry.theoryHours,
              'practice' => entry.practiceHours,
              'ead' => entry.eadHours,
              'extension' => entry.extensionHours,
              _ => 0,
            },
          )
          .fold<int>(0, (maximum, hours) => hours > maximum ? hours : maximum);
      final subject = entries.first;
      final acronym = subject.acronym.trim();
      final discipline = acronym.isEmpty
          ? subject.name
          : '$acronym - ${subject.name}';
      final periods =
          entries
              .expand((entry) => entry.coursePeriods.map((item) => item.period))
              .toSet()
              .toList()
            ..sort();
      lines.add(
        _TeacherDistributionLine(
          discipline: discipline,
          theoryHours: modalityHours('theory'),
          practiceHours: modalityHours('practice'),
          eadHours: modalityHours('ead'),
          extensionHours: modalityHours('extension'),
          classCount: entries
              .map((entry) => '${entry.modality}:${entry.className}')
              .toSet()
              .length,
          periods: periods
              .map((period) => period == 11 ? 'Optativas' : '$periodº')
              .toList(),
        ),
      );
    }
    lines.sort(
      (a, b) =>
          a.discipline.toLowerCase().compareTo(b.discipline.toLowerCase()),
    );
    return lines;
  }

  Widget _distributionCell(
    String value, {
    bool header = false,
    bool numeric = false,
    bool bold = false,
    String? tooltip,
    VoidCallback? onTap,
    bool bottomBorder = false,
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
    return Container(
      decoration: BoxDecoration(
        border: bottomBorder
            ? Border(
                bottom: BorderSide(
                  color: AppTheme.divider.withAlpha(150),
                  width: 0.7,
                ),
              )
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: header ? 10 : 11,
          vertical: header ? 10 : 7,
        ),
        child: InkWell(
          onTap: onTap,
          child: Align(
            alignment: numeric ? Alignment.center : Alignment.centerLeft,
            child: tooltip == null
                ? text
                : Tooltip(message: tooltip, child: text),
          ),
        ),
      ),
    );
  }

  Future<void> _editTeacherDisciplines(String teacher) async {
    final candidates = [..._entries]
      ..sort(
        (a, b) => _classLabel(
          a,
        ).toLowerCase().compareTo(_classLabel(b).toLowerCase()),
      );
    final searchController = TextEditingController();
    final initiallySelected = candidates
        .where((entry) => entry.teacherNames.contains(teacher))
        .map((entry) => entry.id)
        .toSet();
    final selected = Set<String>.from(initiallySelected);
    var showOnlySelected = false;
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = searchController.text.trim().toLowerCase();
          final visible = candidates.where((entry) {
            if (showOnlySelected && !selected.contains(entry.id)) return false;
            if (query.isEmpty) return true;
            return entry.acronym.toLowerCase().contains(query) ||
                entry.name.toLowerCase().contains(query) ||
                entry.code.toLowerCase().contains(query) ||
                entry.className.toLowerCase().contains(query);
          }).toList();
          return AlertDialog(
            title: Text('Disciplinas de $teacher'),
            content: SizedBox(
              width: 620,
              height: 560,
              child: Column(
                children: [
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Buscar disciplina por sigla, nome ou turma',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${selected.length} disciplina(s) selecionada(s)',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ),
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment<bool>(
                            value: false,
                            label: Text('Todas'),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            label: Text('Selecionadas'),
                          ),
                        ],
                        selected: {showOnlySelected},
                        onSelectionChanged: (value) => setDialogState(
                          () => showOnlySelected = value.first,
                        ),
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Text(
                              showOnlySelected && selected.isEmpty
                                  ? 'Nenhuma disciplina selecionada para este professor.'
                                  : 'Nenhuma disciplina encontrada.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              final periods = entry.coursePeriods
                                  .map(
                                    (item) =>
                                        '${_programs[item.program] ?? 'Curso'} · ${item.period == 11 ? 'Optativas' : '${item.period}º período'}',
                                  )
                                  .join(' | ');
                              return CheckboxListTile(
                                dense: true,
                                value: selected.contains(entry.id),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  '${_classLabel(entry)} · ${entry.name}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${entry.code}${periods.isEmpty ? '' : ' · $periods'}',
                                  maxLines: 2,
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
                child: const Text('Salvar disciplinas'),
              ),
            ],
          );
        },
      ),
    );
    searchController.dispose();
    if (result == null || !mounted) return;

    final labels = {
      for (final entry in candidates) entry.id: _classLabel(entry),
    };
    final hadImportedRecords = _distributionRecords.isNotEmpty;
    setState(() {
      _entries = _entries.map((entry) {
        if (!labels.containsKey(entry.id)) return entry;
        final names = entry.teacherNames
            .where((name) => name.toLowerCase() != teacher.toLowerCase())
            .toList();
        if (result.contains(entry.id)) names.add(teacher);
        return entry.copyWith(teachers: names);
      }).toList();

      if (_distributionRecords.isNotEmpty) {
        final oldRecords = _distributionRecords;
        final candidateLabels = labels.values.toSet();
        final kept = oldRecords.where((record) {
          return record.teacher.toLowerCase() != teacher.toLowerCase() ||
              !candidateLabels.contains(record.discipline);
        }).toList();
        for (final entry in candidates.where(
          (item) => result.contains(item.id),
        )) {
          final label = _classLabel(entry);
          for (final coursePeriod in entry.coursePeriods) {
            final period = coursePeriod.period == 11
                ? 'Optativas'
                : '${coursePeriod.period}º';
            final prior = oldRecords
                .where(
                  (record) =>
                      record.teacher.toLowerCase() == teacher.toLowerCase() &&
                      record.discipline == label &&
                      record.period.replaceAll('º', '') ==
                          period.replaceAll('º', ''),
                )
                .firstOrNull;
            kept.add(
              _TeacherDistributionRecord(
                teacher: teacher,
                discipline: label,
                period: period,
                theoryHours: entry.theoryHours,
                practiceHours: entry.practiceHours,
                eadHours: entry.eadHours != 0
                    ? entry.eadHours
                    : prior?.eadHours ?? 0,
                extensionHours: entry.extensionHours != 0
                    ? entry.extensionHours
                    : prior?.extensionHours ?? 0,
              ),
            );
          }
        }
        _distributionRecords = kept;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    if (hadImportedRecords) {
      await prefs.setString(
        _termScopedKey(_distributionKey, _term),
        jsonEncode(
          _distributionRecords.map((record) => record.toJson()).toList(),
        ),
      );
    }
    await _persist();
  }

  List<_TeacherDistribution> _summariesFromSchedule() => _teachers.map((
    teacher,
  ) {
    final entries = _entries
        .where(
          (entry) =>
              entry.teacherNames.contains(teacher) &&
              const {
                'theory',
                'practice',
                'ead',
                'extension',
              }.contains(entry.modality) &&
              entry.className.trim().isNotEmpty,
        )
        .toList();
    final periods =
        entries
            .expand((entry) => entry.coursePeriods.map((item) => item.period))
            .toSet()
            .toList()
          ..sort();
    int hours(HorarioDisciplina entry, String modality) {
      if (entry.modality != modality) return 0;
      return switch (modality) {
        'theory' => entry.theoryHours,
        'practice' => entry.practiceHours,
        'ead' => entry.eadHours,
        'extension' => entry.extensionHours,
        _ => 0,
      };
    }

    return _TeacherDistribution(
      name: teacher,
      disciplines: entries.map(_classLabel).toSet().toList(),
      classCount: entries.length,
      theoryHours: entries.fold(
        0,
        (sum, entry) => sum + hours(entry, 'theory'),
      ),
      practiceHours: entries.fold(
        0,
        (sum, entry) => sum + hours(entry, 'practice'),
      ),
      eadHours: entries.fold(0, (sum, entry) => sum + hours(entry, 'ead')),
      extensionHours: entries.fold(
        0,
        (sum, entry) => sum + hours(entry, 'extension'),
      ),
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

  String _classLabel(HorarioDisciplina entry) => entry.timetableLabel;

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
                    : _view == 2
                    ? _roomVerticalScroll
                    : _courseVerticalScroll;
                final horizontalController = _view == 1
                    ? _teacherHorizontalScroll
                    : _view == 2
                    ? _roomHorizontalScroll
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
                    'Duplo clique em um hor\u00e1rio para editar a disciplina ou turma. Turmas simult\u00e2neas aparecem separadas por v\u00edrgula',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (_view == 1 || _view == 2) ...[
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
                    '${_periodEntries.map((entry) => entry.subjectId).toSet().length} disciplinas neste per\u00edodo',
                    style: TextStyle(color: Colors.black, fontSize: 11),
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
            onDoubleTap: (fraction) => _editTimetableCell(
              cellEntries: schedule['$weekday:$slot'] ?? const [],
              cellFraction: fraction,
              cellWidth: cellWidth,
            ),
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
    final labels = entries.map((entry) => entry.timetableLabel).toList();
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
    required ValueChanged<double> onDoubleTap,
  }) {
    final unique = <String, HorarioDisciplina>{
      for (final entry in entries) '${entry.id}:${entry.className}': entry,
    }.values.toList();
    final labels = unique.map((entry) => entry.timetableLabel).toList();
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

    var doubleTapFraction = 0.5;
    return Tooltip(
      message: labels.join(', '),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (details) {
            doubleTapFraction = (details.localPosition.dx / cellWidth).clamp(
              0.0,
              1.0,
            );
          },
          onDoubleTap: () => onDoubleTap(doubleTapFraction),
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

  Future<void> _editTimetableCell({
    required List<HorarioDisciplina> cellEntries,
    required double cellFraction,
    required double cellWidth,
  }) async {
    final unique = <String, HorarioDisciplina>{
      for (final entry in cellEntries) '${entry.id}:${entry.className}': entry,
    }.values.toList();
    if (unique.isEmpty) {
      await _editPeriod(selectDefault: true);
      return;
    }

    var selectedIndex = unique.length - 1;
    if (unique.length > 1) {
      final stops = _scheduleColorStops(unique, cellWidth);
      for (var index = 0; index < unique.length - 1; index++) {
        if (cellFraction <= stops[1 + index * 2]) {
          selectedIndex = index;
          break;
        }
      }
    }
    await _editPeriod(initialEntryId: unique[selectedIndex].id);
  }

  Future<void> _editTeachers() async {
    final activeChannel = _teacherEditorChannel;
    final activeController = _teacherEditorController;
    if (activeChannel != null && activeController != null) {
      final windows = await WindowController.getAll();
      if (windows.any(
        (window) => window.windowId == activeController.windowId,
      )) {
        final selectedTeacher = _view == 1 ? _teacher : null;
        if (selectedTeacher != null) {
          await activeChannel.invokeMethod<bool>(
            'selectTeacher',
            selectedTeacher,
          );
        }
        await activeController.show();
        return;
      }
      await activeChannel.setMethodCallHandler(null);
      _teacherEditorChannel = null;
      _teacherEditorController = null;
    }
    if (_openingTeacherEditor) return;
    _openingTeacherEditor = true;
    final channelName = 'gestor_ufu_teachers_${const Uuid().v4()}';
    final channel = WindowMethodChannel(
      channelName,
      mode: ChannelMode.bidirectional,
    );
    try {
      await channel.setMethodCallHandler((call) async {
        if (call.method == 'saveRoster' || call.method == 'closed') {
          final result = _TeacherRosterResult.fromJson(
            Map<String, dynamic>.from(call.arguments as Map),
          );
          await _applyTeacherRosterResult(result);
          return true;
        }
        if (call.method == 'teacherSelected') {
          final teacher = call.arguments as String?;
          if (teacher != null && _teacherRoster.contains(teacher)) {
            if (mounted && _teacher != teacher) {
              setState(() => _teacher = teacher);
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_termScopedKey(_teacherKey, _term), teacher);
            await _saveViewSelection();
            return true;
          }
          return false;
        }
        throw MissingPluginException(
          'M\u00e9todo n\u00e3o reconhecido: ${call.method}',
        );
      });
      _teacherEditorChannel = channel;
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({
            'type': 'teacherEditor',
            'channel': channelName,
            'teachers': _teachers,
            'entries': _entries.map((entry) => entry.toJson()).toList(),
            'programs': _programs.map((key, value) => MapEntry('$key', value)),
            'initialTeacher': _view == 1 ? _teacher : null,
            'isLight': AppTheme.isLight,
          }),
        ),
      );
      _teacherEditorController = controller;
      await controller.show();
    } catch (_) {
      await channel.setMethodCallHandler(null);
      _teacherEditorChannel = null;
      _teacherEditorController = null;
      rethrow;
    } finally {
      _openingTeacherEditor = false;
    }
  }

  Future<void> _applyTeacherRosterResult(_TeacherRosterResult result) async {
    final renamed = result.renamed;
    final hadImportedDistribution = _distributionRecords.isNotEmpty;
    setState(() {
      _teacherRoster = result.teachers;
      _entries = result.entries;
      _distributionRecords = _distributionRecords
          .map((record) {
            var teacher = record.teacher;
            final visited = <String>{};
            while (renamed.containsKey(teacher) && visited.add(teacher)) {
              teacher = renamed[teacher]!;
              if (teacher.isEmpty) return null;
            }
            if (!result.teachers.contains(teacher)) return null;
            return _TeacherDistributionRecord(
              teacher: teacher,
              discipline: record.discipline,
              period: record.period,
              theoryHours: record.theoryHours,
              practiceHours: record.practiceHours,
              eadHours: record.eadHours,
              extensionHours: record.extensionHours,
            );
          })
          .whereType<_TeacherDistributionRecord>()
          .toList();
      if (_teacher != null) {
        var selected = _teacher!;
        final visited = <String>{};
        while (renamed.containsKey(selected) && visited.add(selected)) {
          selected = renamed[selected]!;
          if (selected.isEmpty) break;
        }
        _teacher = result.teachers.contains(selected)
            ? selected
            : result.teachers.firstOrNull;
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _termScopedKey(_teacherRosterKey, _term),
      _teacherRoster,
    );
    if (hadImportedDistribution) {
      await prefs.setString(
        _termScopedKey(_distributionKey, _term),
        jsonEncode(
          _distributionRecords.map((record) => record.toJson()).toList(),
        ),
      );
    }
    await _persist();
    await _saveViewSelection();
  }

  Future<void> _selectTeacher(String teacher) async {
    if (mounted && _teacher != teacher) setState(() => _teacher = teacher);
    await _saveViewSelection();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_termScopedKey(_teacherKey, _term), teacher);
    await _teacherEditorChannel?.invokeMethod<bool>('selectTeacher', teacher);
    _restoreCurrentTableScroll();
  }

  Future<void> _editPeriod({
    String? initialEntryId,
    bool selectDefault = false,
  }) async {
    final activeChannel = _scheduleEditorChannel;
    final activeController = _scheduleEditorController;
    if (activeChannel != null && activeController != null) {
      final windows = await WindowController.getAll();
      if (windows.any(
        (window) => window.windowId == activeController.windowId,
      )) {
        if (selectDefault) {
          await activeChannel.invokeMethod<bool>('selectDefault');
        } else if (initialEntryId != null) {
          await activeChannel.invokeMethod<bool>('selectEntry', initialEntryId);
        }
        await activeController.show();
        return;
      }
      await activeChannel.setMethodCallHandler(null);
      _scheduleEditorChannel = null;
      _scheduleEditorController = null;
    }
    if (_openingScheduleEditor) return;
    _openingScheduleEditor = true;
    final channelName = 'gestor_ufu_schedule_${const Uuid().v4()}';
    final channel = WindowMethodChannel(
      channelName,
      mode: ChannelMode.bidirectional,
    );
    try {
      await channel.setMethodCallHandler((call) async {
        if (call.method == 'saveEntries') {
          final values = (call.arguments as List)
              .map(
                (value) => HorarioDisciplina.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              )
              .toList();
          await _savePeriodEntries(values);
          return true;
        }
        if (call.method == 'closed') {
          return true;
        }
        throw MissingPluginException(
          'M\u00e9todo n\u00e3o reconhecido: ${call.method}',
        );
      });
      _scheduleEditorChannel = channel;
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({
            'type': 'scheduleEditor',
            'channel': channelName,
            'entries': _entries.map((entry) => entry.toJson()).toList(),
            'teachers': _teachers,
            'programs': _programs.map((key, value) => MapEntry('$key', value)),
            'selectedProgram': _program,
            'selectedPeriod': _period,
            'initialEntryId': initialEntryId,
            'isLight': AppTheme.isLight,
          }),
        ),
      );
      _scheduleEditorController = controller;
      await controller.show();
    } catch (_) {
      await channel.setMethodCallHandler(null);
      _scheduleEditorChannel = null;
      _scheduleEditorController = null;
      rethrow;
    } finally {
      _openingScheduleEditor = false;
    }
  }

  Future<void> _savePeriodEntries(
    List<HorarioDisciplina> returnedEntries,
  ) async {
    final previousById = {for (final entry in _entries) entry.id: entry};
    var distributionChanged = false;
    setState(() {
      for (final entry in returnedEntries) {
        final previous = previousById[entry.id];
        if (previous != null &&
            (previous.theoryHours != entry.theoryHours ||
                previous.practiceHours != entry.practiceHours ||
                previous.eadHours != entry.eadHours ||
                previous.extensionHours != entry.extensionHours)) {
          distributionChanged = true;
          final label = _classLabel(entry);
          _distributionRecords = _distributionRecords.map((record) {
            if (!entry.teacherNames.contains(record.teacher) ||
                record.discipline != label) {
              return record;
            }
            return _TeacherDistributionRecord(
              teacher: record.teacher,
              discipline: record.discipline,
              period: record.period,
              theoryHours: entry.theoryHours,
              practiceHours: entry.practiceHours,
              eadHours: entry.eadHours,
              extensionHours: entry.extensionHours,
            );
          }).toList();
        }
      }
      _entries = returnedEntries;
    });
    await _persist();
    if (distributionChanged && _distributionRecords.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _termScopedKey(_distributionKey, _term),
        jsonEncode(
          _distributionRecords.map((record) => record.toJson()).toList(),
        ),
      );
    }
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
            teachers: value(row, 7)
                .split(',')
                .map((name) => name.trim())
                .where((name) => name.isNotEmpty)
                .toList(),
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
    final importedTeachers = imported
        .map((item) => item.teacher.trim())
        .where((name) => name.isNotEmpty)
        .toSet();
    final updatedRoster = {..._teacherRoster, ...importedTeachers}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await prefs.setString(
      _termScopedKey(_distributionKey, _term),
      jsonEncode(imported.map((item) => item.toJson()).toList()),
    );
    await prefs.setStringList(
      _termScopedKey(_teacherRosterKey, _term),
      updatedRoster,
    );
    if (!mounted) return;
    setState(() {
      _distributionRecords = imported;
      _teacherRoster = updatedRoster;
    });
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

  Future<List<String>?> _choosePdfTeachers() {
    final availableTeachers = _teachers;
    var scope = 0;
    final selected = <String>{if (_teacher != null) _teacher!};
    return showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) => AlertDialog(
          title: const Text('Exportar grades por docente'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<int>(
                  value: 0,
                  groupValue: scope,
                  title: Text('Professor corrente - ${_teacher ?? ""}'),
                  onChanged: (value) => dialogSetState(() => scope = value!),
                ),
                RadioListTile<int>(
                  value: 1,
                  groupValue: scope,
                  title: const Text('Todos os professores'),
                  onChanged: (value) => dialogSetState(() => scope = value!),
                ),
                RadioListTile<int>(
                  value: 2,
                  groupValue: scope,
                  title: const Text('Escolher professores'),
                  onChanged: (value) => dialogSetState(() => scope = value!),
                ),
                if (scope == 2) ...[
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => dialogSetState(
                          () => selected.addAll(availableTeachers),
                        ),
                        child: const Text('Selecionar todos'),
                      ),
                      TextButton(
                        onPressed: () => dialogSetState(selected.clear),
                        child: const Text('Limpar sele??o'),
                      ),
                      const Spacer(),
                      Text('${selected.length} selecionado(s)'),
                    ],
                  ),
                  SizedBox(
                    height: 280,
                    child: ListView.builder(
                      itemCount: availableTeachers.length,
                      itemBuilder: (context, index) {
                        final teacher = availableTeachers[index];
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          value: selected.contains(teacher),
                          title: Text(teacher),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (checked) => dialogSetState(() {
                            if (checked == true) {
                              selected.add(teacher);
                            } else {
                              selected.remove(teacher);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: scope == 2 && selected.isEmpty
                  ? null
                  : () {
                      final result = switch (scope) {
                        0 => _teacher == null ? <String>[] : [_teacher!],
                        1 => List<String>.of(availableTeachers),
                        _ => selected.toList(),
                      };
                      result.sort(
                        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                      );
                      Navigator.pop(dialogContext, result);
                    },
              icon: const Icon(Icons.picture_as_pdf_rounded),
              label: const Text('Continuar'),
            ),
          ],
        ),
      ),
    );
  }

  String _safeFileName(String value) {
    final safe = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return safe.isEmpty ? 'docente' : safe;
  }

  Map<String, List<HorarioDisciplina>> _scheduleForExportPeriod(
    int period, {
    String? teacher,
  }) {
    final selectedEntries = _entries.where((entry) {
      final matchesView = _view == 1
          ? (teacher ?? _teacher) != null &&
                entry.teacherNames.contains(teacher ?? _teacher)
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
      if (entry.modality == 'ead') continue;
      for (final slot in entry.slots) {
        result.putIfAbsent(slot.key, () => []).add(entry);
      }
    }
    return result;
  }

  String _exportTitle(List<int> periods, {String? teacher}) {
    final periodLabel = periods.map(_periodExportLabel).join(', ');
    return _view == 1
        ? 'Grade: ${teacher ?? _teacher ?? 'Docente'} ? $periodLabel'
        : '${_programs[_program]} ? $periodLabel';
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
    if (_view == 2) {
      final room = _room;
      if (room == null) {
        _message('Selecione uma sala para exportar.');
        return;
      }
      final schedule = _schedule(room: room);
      final rows = <List<String>>[
        ['Sala', room],
        ['Faixa horária', ...horarioDias],
        for (var slot = 1; slot <= horarioFaixas.length; slot++)
          [
            horarioFaixas[slot - 1],
            for (var day = 1; day <= 5; day++)
              (schedule['$day:$slot'] ?? const [])
                  .map((entry) => entry.timetableLabel)
                  .join(' | '),
          ],
      ];
      final csv = rows
          .map(
            (row) =>
                row.map((cell) => '"${cell.replaceAll('"', '""')}"').join(';'),
          )
          .join('\r\n');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Exportar grade da sala',
        fileName: 'grade-sala-${_safeFileName(room)}.csv',
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (path == null) return;
      await File(path).writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
      _message('Grade da sala exportada em CSV.');
      return;
    }
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
                .map((entry) => entry.timetableLabel)
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
    if (_view == 2) {
      final room = _room;
      if (room == null) {
        _message('Selecione uma sala para exportar.');
        return;
      }
      try {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: 'Exportar grade colorida da sala',
          fileName: 'grade-sala-${_safeFileName(room)}.pdf',
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );
        if (path == null) return;
        final bytes = await _pdfService.generate(
          term: _term,
          sheets: [_createPdfSheet('Sala: $room', _schedule(room: room))],
          isLightTheme: AppTheme.isLight,
        );
        await File(
          path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf',
        ).writeAsBytes(bytes, flush: true);
        _message('PDF colorido da sala exportado com sucesso.');
      } catch (error) {
        _message('Não foi possível exportar o PDF da sala: $error');
      }
      return;
    }
    if (teacherMode) {
      final selectedTeacher = _teacher;
      if (selectedTeacher == null) return;
      final selectedTeachers = await _choosePdfTeachers();
      if (selectedTeachers == null) return;
      final teachers = selectedTeachers;
      final exportMultiple = teachers.length > 1;
      final singleTeacher = teachers.length == 1
          ? teachers.single
          : selectedTeacher;
      if (teachers.isEmpty) {
        _message('Nenhum professor possui disciplinas para exportar.');
        return;
      }

      try {
        String? directory;
        String? singleFilePath;
        if (exportMultiple) {
          directory = await FilePicker.platform.getDirectoryPath(
            dialogTitle: 'Escolha a pasta dos PDFs dos professores',
          );
          if (directory == null) return;
        } else {
          singleFilePath = await FilePicker.platform.saveFile(
            dialogTitle: 'Exportar grade do professor',
            fileName: '${_safeFileName(singleTeacher)}.pdf',
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
          );
          if (singleFilePath == null) return;
        }

        var exported = 0;
        for (final teacher in teachers) {
          // A grade shown in the teacher view combines the teacher's classes
          // across all curriculum periods. Keep the PDF identical in scope and
          // export it as one page per selected teacher.
          final schedule = _schedule(teacher: teacher);
          if (schedule.isEmpty) continue;
          final sheets = [_createPdfSheet('Grade: $teacher', schedule)];
          final bytes = await _pdfService.generate(
            term: _term,
            sheets: sheets,
            isLightTheme: AppTheme.isLight,
          );
          final outputPath = exportMultiple
              ? '${directory!}${Platform.pathSeparator}${_safeFileName(teacher)}.pdf'
              : (singleFilePath!.toLowerCase().endsWith('.pdf')
                    ? singleFilePath
                    : '$singleFilePath.pdf');
          await File(outputPath).writeAsBytes(bytes, flush: true);
          exported++;
        }
        _message(
          exportMultiple
              ? '$exported PDF(s) exportado(s), um por professor.'
              : 'PDF da grade de $singleTeacher exportado com sucesso.',
        );
      } catch (error) {
        _message('N\u00e3o foi poss\u00edvel exportar o PDF: $error');
      }
      return;
    }

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

class _TeacherDistributionLine {
  const _TeacherDistributionLine({
    required this.discipline,
    required this.theoryHours,
    required this.practiceHours,
    required this.eadHours,
    required this.extensionHours,
    required this.classCount,
    required this.periods,
  });

  final String discipline;
  final int theoryHours;
  final int practiceHours;
  final int eadHours;
  final int extensionHours;
  final int classCount;
  final List<String> periods;

  int get total => theoryHours + practiceHours + eadHours;
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

class HorarioEditorWindowApp extends StatelessWidget {
  const HorarioEditorWindowApp({
    required this.entries,
    required this.teachers,
    required this.programs,
    required this.selectedProgram,
    required this.selectedPeriod,
    required this.channelName,
    required this.initialEntryId,
    required this.isLight,
    super.key,
  });

  final List<HorarioDisciplina> entries;
  final List<String> teachers;
  final Map<int, String> programs;
  final int selectedProgram;
  final int selectedPeriod;
  final String channelName;
  final String? initialEntryId;
  final bool isLight;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: isLight ? ThemeMode.light : ThemeMode.dark,
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: _HorarioEditorDialog(
            entries: entries,
            teachers: teachers,
            programs: programs,
            selectedProgram: selectedProgram,
            selectedPeriod: selectedPeriod,
            initialEntryId: initialEntryId,
            channelName: channelName,
            onSave: (updated) async {
              await WindowMethodChannel(
                channelName,
                mode: ChannelMode.bidirectional,
              ).invokeMethod<bool>(
                'saveEntries',
                updated.map((entry) => entry.toJson()).toList(),
              );
            },
            onClose: () async {
              try {
                await WindowMethodChannel(
                  channelName,
                  mode: ChannelMode.bidirectional,
                ).invokeMethod<bool>('closed');
              } finally {
                await (await WindowController.fromCurrentEngine()).hide();
              }
            },
          ),
        ),
      ),
    ),
  );
}

class TeacherRosterWindowApp extends StatelessWidget {
  const TeacherRosterWindowApp({
    required this.teachers,
    required this.entries,
    required this.programs,
    required this.channelName,
    required this.initialTeacher,
    required this.isLight,
    super.key,
  });

  final List<String> teachers;
  final List<HorarioDisciplina> entries;
  final Map<int, String> programs;
  final String channelName;
  final String? initialTeacher;
  final bool isLight;

  @override
  Widget build(BuildContext context) {
    final channel = WindowMethodChannel(
      channelName,
      mode: ChannelMode.bidirectional,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: isLight ? ThemeMode.light : ThemeMode.dark,
      home: _TeacherRosterPage(
        teachers: teachers,
        entries: entries,
        programs: programs,
        initialTeacher: initialTeacher,
        channelName: channelName,
        onSave: (result) =>
            channel.invokeMethod<bool>('saveRoster', result.toJson()),
        onClose: (result) async {
          try {
            await channel.invokeMethod<bool>('closed', result.toJson());
          } finally {
            await (await WindowController.fromCurrentEngine()).hide();
          }
        },
      ),
    );
  }
}

class RoomRosterWindowApp extends StatelessWidget {
  const RoomRosterWindowApp({
    required this.rooms,
    required this.entries,
    required this.programs,
    required this.channelName,
    required this.initialRoom,
    required this.isLight,
    super.key,
  });

  final List<String> rooms;
  final List<HorarioDisciplina> entries;
  final Map<int, String> programs;
  final String channelName;
  final String? initialRoom;
  final bool isLight;

  @override
  Widget build(BuildContext context) {
    final channel = WindowMethodChannel(
      channelName,
      mode: ChannelMode.bidirectional,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: isLight ? ThemeMode.light : ThemeMode.dark,
      home: _RoomRosterPage(
        rooms: rooms,
        entries: entries,
        programs: programs,
        initialRoom: initialRoom,
        channelName: channelName,
        onSelect: (room) => channel.invokeMethod<bool>('roomSelected', room),
        onSave: (result) =>
            channel.invokeMethod<bool>('saveRooms', result.toJson()),
        onClose: (result) async {
          try {
            await channel.invokeMethod<bool>('closed', result.toJson());
          } finally {
            await (await WindowController.fromCurrentEngine()).hide();
          }
        },
      ),
    );
  }
}

class _RoomRosterResult {
  const _RoomRosterResult(this.rooms, this.entries);
  final List<String> rooms;
  final List<HorarioDisciplina> entries;

  Map<String, dynamic> toJson() => {
    'rooms': rooms,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

class _RoomRosterPage extends StatefulWidget {
  const _RoomRosterPage({
    required this.rooms,
    required this.entries,
    required this.programs,
    required this.initialRoom,
    required this.channelName,
    required this.onSelect,
    required this.onSave,
    required this.onClose,
  });

  final List<String> rooms;
  final List<HorarioDisciplina> entries;
  final Map<int, String> programs;
  final String? initialRoom;
  final String channelName;
  final Future<void> Function(String room) onSelect;
  final Future<void> Function(_RoomRosterResult result) onSave;
  final Future<void> Function(_RoomRosterResult result) onClose;

  @override
  State<_RoomRosterPage> createState() => _RoomRosterPageState();
}

class _RoomRosterPageState extends State<_RoomRosterPage> {
  late final List<String> _rooms = [...widget.rooms];
  late List<HorarioDisciplina> _entries = [...widget.entries];
  final _search = TextEditingController();
  String? _selectedRoom;
  int? _program;
  int? _period;
  bool _assignedOnly = false;

  @override
  void initState() {
    super.initState();
    _selectedRoom = _rooms.contains(widget.initialRoom)
        ? widget.initialRoom
        : _rooms.firstOrNull;
    _program = widget.programs.keys.firstOrNull;
    WindowMethodChannel(
      widget.channelName,
      mode: ChannelMode.bidirectional,
    ).setMethodCallHandler((call) async {
      if (call.method == 'selectRoom') {
        final room = call.arguments as String?;
        if (room != null && _rooms.contains(room) && mounted) {
          setState(() => _selectedRoom = room);
        }
        return true;
      }
      throw MissingPluginException('Método não reconhecido: ${call.method}');
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  _RoomRosterResult get _result =>
      _RoomRosterResult(List.of(_rooms), List.of(_entries));

  Future<void> _chooseRoom(String room) async {
    setState(() => _selectedRoom = room);
    await widget.onSelect(room);
  }

  Future<void> _editRoom({String? current}) async {
    final controller = TextEditingController(text: current ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(current == null ? 'Adicionar sala' : 'Editar sala'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Nome ou código da sala',
              prefixIcon: Icon(Icons.meeting_room_outlined),
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
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
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    if (_rooms.any(
      (room) => room.toLowerCase() == trimmed.toLowerCase() && room != current,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Essa sala já está cadastrada.')),
      );
      return;
    }
    setState(() {
      if (current == null) {
        _rooms.add(trimmed);
        _rooms.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _selectedRoom = trimmed;
      } else {
        final index = _rooms.indexOf(current);
        if (index >= 0) _rooms[index] = trimmed;
        _entries = _entries
            .map(
              (entry) =>
                  entry.room.trim().toLowerCase() == current.toLowerCase()
                  ? entry.copyWith(room: trimmed)
                  : entry,
            )
            .toList();
        _selectedRoom = trimmed;
      }
    });
    await widget.onSelect(trimmed);
  }

  Future<void> _removeRoom() async {
    final room = _selectedRoom;
    if (room == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover sala?'),
        content: Text(
          'A sala "$room" será removida do cadastro e desvinculada das turmas. Os horários e demais dados das turmas serão mantidos.',
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
    if (confirmed != true || !mounted) return;
    setState(() {
      _rooms.remove(room);
      _entries = _entries
          .map(
            (entry) => entry.room.trim().toLowerCase() == room.toLowerCase()
                ? entry.copyWith(room: '')
                : entry,
          )
          .toList();
      _selectedRoom = _rooms.firstOrNull;
    });
    if (_selectedRoom != null) await widget.onSelect(_selectedRoom!);
  }

  List<HorarioDisciplina> get _visibleEntries {
    final query = _search.text.trim().toLowerCase();
    return _entries.where((entry) {
      final offeringMatches = entry.coursePeriods.any(
        (item) =>
            (_program == null || item.program == _program) &&
            (_period == null || item.period == _period),
      );
      if (!offeringMatches) return false;
      final assigned =
          entry.room.trim().toLowerCase() == _selectedRoom?.toLowerCase();
      if (_assignedOnly && !assigned) return false;
      if (query.isEmpty) return true;
      return entry.acronym.toLowerCase().contains(query) ||
          entry.name.toLowerCase().contains(query) ||
          entry.code.toLowerCase().contains(query) ||
          entry.className.toLowerCase().contains(query) ||
          entry.timetableLabel.toLowerCase().contains(query);
    }).toList()..sort(
      (a, b) => a.timetableLabel.toLowerCase().compareTo(
        b.timetableLabel.toLowerCase(),
      ),
    );
  }

  void _setAssignment(HorarioDisciplina entry, bool assigned) {
    final room = _selectedRoom;
    if (room == null) return;
    setState(() {
      _entries = _entries.map((candidate) {
        if (candidate.id != entry.id) return candidate;
        return candidate.copyWith(
          room: assigned
              ? room
              : (candidate.room == room ? '' : candidate.room),
        );
      }).toList();
    });
  }

  Future<void> _save() async {
    await widget.onSave(_result);
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Salas e vínculos salvos. Você pode continuar editando.',
          ),
        ),
      );
  }

  Future<void> _close() => widget.onClose(_result);

  @override
  Widget build(BuildContext context) {
    final periods =
        _entries
            .expand((entry) => entry.coursePeriods)
            .where((item) => _program == null || item.program == _program)
            .map((item) => item.period)
            .toSet()
            .toList()
          ..sort();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Fechar',
          onPressed: _close,
          icon: const Icon(Icons.close_rounded),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Editar salas'),
            Text(
              'Cadastre salas e vincule cada turma à sala em que ocorre.',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_rounded),
            label: const Text('Salvar'),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _close,
            icon: const Icon(Icons.close_rounded),
            label: const Text('Fechar'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 400,
                  child: _rooms.isEmpty
                      ? const InputDecorator(
                          decoration: InputDecoration(labelText: 'Sala'),
                          child: Text('Nenhuma sala cadastrada'),
                        )
                      : DropdownButtonFormField<String>(
                          value: _selectedRoom,
                          decoration: const InputDecoration(
                            labelText: 'Sala',
                            prefixIcon: Icon(Icons.meeting_room_outlined),
                          ),
                          items: _rooms
                              .map(
                                (room) => DropdownMenuItem(
                                  value: room,
                                  child: Text(room),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) _chooseRoom(value);
                          },
                        ),
                ),
                FilledButton.icon(
                  onPressed: () => _editRoom(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Nova sala'),
                ),
                OutlinedButton.icon(
                  onPressed: _selectedRoom == null
                      ? null
                      : () => _editRoom(current: _selectedRoom),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Renomear'),
                ),
                IconButton(
                  tooltip: 'Remover sala',
                  onPressed: _selectedRoom == null ? null : _removeRoom,
                  color: Colors.red,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '${_entries.length} turmas cadastradas - marque as turmas vinculadas à sala selecionada.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    value: _program,
                    decoration: const InputDecoration(labelText: 'Curso'),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('Todos os cursos'),
                      ),
                      ...widget.programs.entries.map(
                        (item) => DropdownMenuItem<int?>(
                          value: item.key,
                          child: Text(item.value),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      _program = value;
                      _period = null;
                    }),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<int?>(
                    value: _period,
                    decoration: const InputDecoration(labelText: 'Período'),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('Todos'),
                      ),
                      ...periods.map(
                        (period) => DropdownMenuItem<int?>(
                          value: period,
                          child: Text(
                            period == 11 ? 'Optativas' : '$periodº período',
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() => _period = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Filtrar disciplina, sigla ou turma',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${_visibleEntries.length} turma(s) encontrada(s)',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const Spacer(),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Todas as turmas')),
                    ButtonSegment(value: true, label: Text('Vinculadas')),
                  ],
                  selected: {_assignedOnly},
                  onSelectionChanged: (value) =>
                      setState(() => _assignedOnly = value.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _visibleEntries.isEmpty
                  ? Center(
                      child: Text(
                        _rooms.isEmpty
                            ? 'Cadastre uma sala para começar.'
                            : 'Nenhuma turma corresponde aos filtros.',
                      ),
                    )
                  : Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListView.separated(
                        itemCount: _visibleEntries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = _visibleEntries[index];
                          final assigned =
                              entry.room.trim().toLowerCase() ==
                              _selectedRoom?.toLowerCase();
                          final offerLabels = entry.coursePeriods
                              .map(
                                (item) =>
                                    '${widget.programs[item.program] ?? 'Curso'} - ${item.period == 11 ? 'Optativas' : '${item.period}º período'}',
                              )
                              .toSet()
                              .join(', ');
                          return CheckboxListTile(
                            value: assigned,
                            onChanged: _selectedRoom == null
                                ? null
                                : (value) =>
                                      _setAssignment(entry, value == true),
                            title: Text(
                              '${entry.timetableLabel} - ${entry.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${entry.modality == 'theory'
                                  ? 'Teórica'
                                  : entry.modality == 'practice'
                                  ? 'Prática'
                                  : entry.modality == 'ead'
                                  ? 'EaD'
                                  : entry.modality == 'extension'
                                  ? 'Extensão'
                                  : 'Turma'} - $offerLabels${entry.room.isNotEmpty && !assigned ? ' - Sala atual: ${entry.room}' : ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HorarioEditorDialog extends StatefulWidget {
  const _HorarioEditorDialog({
    required this.entries,
    required this.teachers,
    required this.programs,
    required this.selectedProgram,
    required this.selectedPeriod,
    required this.initialEntryId,
    required this.channelName,
    required this.onSave,
    this.onClose,
  });
  final List<HorarioDisciplina> entries;
  final List<String> teachers;
  final Map<int, String> programs;
  final int selectedProgram;
  final int selectedPeriod;
  final String? initialEntryId;
  final String channelName;
  final Future<void> Function(List<HorarioDisciplina>) onSave;
  final Future<void> Function()? onClose;
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
  final _eadHours = TextEditingController();
  final _extensionHours = TextEditingController();
  final Set<String> _slots = {};
  final List<String> _selectedTeachers = [];
  final List<CursoPeriodo> _offerings = [];
  Future<void> _closeEditor() async {
    final onClose = widget.onClose;
    if (onClose != null) {
      await onClose();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  late final List<HorarioDisciplina> _entries = [...widget.entries];
  String? _selectedId;
  String? _newEntryId;
  HorarioDisciplina? _newEntryTemplate;
  String _selectedModality = 'theory';
  bool _addingTurma = false;
  String? get _activeNewEntryId => _newEntryId;
  bool get _creating => _activeNewEntryId != null;
  bool get _hasSelectedModality =>
      _selectedModality != 'legacy' &&
      _availableModalities.contains(_selectedModality);
  HorarioDisciplina? get _selected => [
    ..._entries,
    if (_creating) _blank(),
  ].where((e) => e.id == _selectedId).firstOrNull;
  HorarioDisciplina? get _firstEntryWithClass =>
      _entries.where((entry) => entry.className.trim().isNotEmpty).firstOrNull;
  HorarioDisciplina get _defaultEntry {
    final relevant = _entries
        .where(
          (entry) => entry.coursePeriods.any(
            (item) =>
                item.program == widget.selectedProgram &&
                item.period == widget.selectedPeriod,
          ),
        )
        .toList();
    if (relevant.isEmpty) return _firstEntryWithClass ?? _entries.first;

    final firstSubject = relevant.first;
    final subjectEntries = relevant
        .where((entry) => _sameDiscipline(entry, firstSubject))
        .toList();
    return _firstConfiguredTurma(subjectEntries) ??
        relevant.where((entry) => entry.modality != 'legacy').firstOrNull ??
        relevant.first;
  }

  HorarioDisciplina _blank() =>
      _newEntryTemplate?.copyWith(
        id: _activeNewEntryId!,
        subjectId: _newEntryTemplate!.subjectId,
        slots: const [],
        coursePeriods: [
          CursoPeriodo(
            program: widget.selectedProgram,
            period: widget.selectedPeriod,
          ),
        ],
      ) ??
      HorarioDisciplina(
        id: _activeNewEntryId!,
        subjectId: _activeNewEntryId!,
        modality: _selectedModality,
        code: '',
        acronym: '',
        name: '',
        className: '',
        teachers: const [],
        room: '',
        theoryHours: 0,
        practiceHours: 0,
        eadHours: 0,
        extensionHours: 0,
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
    final requestedEntry = _entries
        .where((entry) => entry.id == widget.initialEntryId)
        .firstOrNull;
    if (requestedEntry != null) {
      _selectedId = requestedEntry.id;
      _select(requestedEntry);
    } else if (_entries.isEmpty) {
      _newEntryId = const Uuid().v4();
      _selectedId = _activeNewEntryId;
      _select(_blank());
    } else {
      final entry = _defaultEntry;
      _selectedId = entry.id;
      _select(entry);
    }
    unawaited(
      WindowMethodChannel(
        widget.channelName,
        mode: ChannelMode.bidirectional,
      ).setMethodCallHandler((call) async {
        if (call.method == 'selectEntry') {
          final id = call.arguments as String?;
          if (id != null && mounted) _switchEntry(id);
          return true;
        }
        if (call.method == 'selectDefault') {
          if (mounted && _entries.isNotEmpty) _switchEntry(_defaultEntry.id);
          return true;
        }
        throw MissingPluginException(
          'M\u00e9todo n\u00e3o reconhecido: ${call.method}',
        );
      }),
    );
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
      _eadHours,
      _extensionHours,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _modalityName(String modality) => switch (modality) {
    'theory' => 'Te\u00f3rica',
    'practice' => 'Pr\u00e1tica',
    'ead' => 'EaD',
    'extension' => 'Extens\u00e3o',
    _ => 'Cadastro anterior',
  };

  Color _modalityScheduleColor(String modality) => switch (modality) {
    'theory' => const Color(0xFF6554E8),
    'practice' => const Color(0xFF0089A8),
    'ead' => const Color(0xFFE09A00),
    'extension' => const Color(0xFF16803C),
    _ => AppTheme.textSecondary,
  };

  List<HorarioDisciplina> _otherClassesAtSlot(String slotKey) {
    final current = _selected;
    if (current == null) return const [];
    return _entries
        .where(
          (entry) =>
              entry.id != current.id &&
              _sameDiscipline(entry, current) &&
              entry.modality != 'legacy' &&
              entry.slots.any((slot) => slot.key == slotKey),
        )
        .toList();
  }

  List<String> get _availableModalities => [
    if ((int.tryParse(_theoryHours.text.trim()) ?? 0) > 0) 'theory',
    if ((int.tryParse(_practiceHours.text.trim()) ?? 0) > 0) 'practice',
    if ((int.tryParse(_eadHours.text.trim()) ?? 0) > 0) 'ead',
    if ((int.tryParse(_extensionHours.text.trim()) ?? 0) > 0) 'extension',
  ];

  List<String> _allTeachers() =>
      {
          ...widget.teachers,
          ..._entries.expand((entry) => entry.teacherNames),
          ..._selectedTeachers,
        }.where((name) => name.trim().isNotEmpty).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  Future<void> _openTeacherPicker() async {
    final search = TextEditingController();
    final selected = Set<String>.from(_selectedTeachers);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = search.text.trim().toLowerCase();
          final teachers = _allTeachers()
              .where((name) => name.toLowerCase().contains(query))
              .toList();
          return AlertDialog(
            title: const Text('Selecionar docentes'),
            content: SizedBox(
              width: 540,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: search,
                    autofocus: true,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Filtrar docentes pelo nome',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('${selected.length} docente(s) selecionado(s)'),
                  const SizedBox(height: 6),
                  Expanded(
                    child: teachers.isEmpty
                        ? const Center(
                            child: Text('Nenhum docente encontrado.'),
                          )
                        : ListView.builder(
                            itemCount: teachers.length,
                            itemBuilder: (context, index) {
                              final name = teachers[index];
                              return CheckboxListTile(
                                value: selected.contains(name),
                                title: Text(name),
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
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
                onPressed: () =>
                    Navigator.pop(dialogContext, selected.toList()),
                child: const Text('Aplicar seleção'),
              ),
            ],
          );
        },
      ),
    );
    search.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _selectedTeachers
        ..clear()
        ..addAll(result);
      _teacher.text = result.join(', ');
    });
  }

  Widget _teacherPickerField() => TextField(
    controller: _teacher,
    readOnly: true,
    maxLines: 1,
    onTap: _openTeacherPicker,
    decoration: const InputDecoration(
      labelText: 'Docentes desta turma',
      hintText: 'Clique para selecionar um ou mais docentes',
      suffixIcon: Icon(Icons.arrow_drop_down_rounded),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
  );

  void _select(HorarioDisciplina entry) {
    _code.text = entry.code;
    _acronym.text = entry.acronym;
    _name.text = entry.name;
    _class.text = entry.className;
    _selectedTeachers
      ..clear()
      ..addAll(entry.teacherNames);
    _teacher.text = _selectedTeachers.join(', ');
    _room.text = entry.room;
    _theoryHours.text = '${_sharedHours(entry, 'theory')}';
    _practiceHours.text = '${_sharedHours(entry, 'practice')}';
    _eadHours.text = '${_sharedHours(entry, 'ead')}';
    _extensionHours.text = '${_sharedHours(entry, 'extension')}';
    _selectedModality = entry.modality == 'legacy'
        ? (_availableModalities.firstOrNull ?? 'legacy')
        : entry.modality;
    final related = _creating
        ? [entry]
        : _entries.where((candidate) => _sameDiscipline(candidate, entry));
    final offerings = <String, CursoPeriodo>{};
    for (final candidate in related) {
      for (final offering in candidate.coursePeriods) {
        offerings['${offering.program}:${offering.period}'] = offering;
      }
    }
    _offerings
      ..clear()
      ..addAll(
        offerings.values.toList()..sort((a, b) {
          final course = a.program.compareTo(b.program);
          return course != 0 ? course : a.period.compareTo(b.period);
        }),
      );
    _slots
      ..clear()
      ..addAll(entry.slots.map((slot) => slot.key));
  }

  String _disciplineGroupKey(HorarioDisciplina entry) {
    final acronym = entry.acronym.trim().toLowerCase();
    final name = entry.name.trim().toLowerCase();
    return acronym.isEmpty || name.isEmpty
        ? 'id:${entry.subjectId}'
        : 'subject:$acronym|$name';
  }

  bool _sameDiscipline(HorarioDisciplina a, HorarioDisciplina b) =>
      (a.subjectId.isNotEmpty && a.subjectId == b.subjectId) ||
      _disciplineGroupKey(a) == _disciplineGroupKey(b);

  int _sharedHours(HorarioDisciplina entry, String modality) {
    final related = _entries.where(
      (candidate) => _sameDiscipline(candidate, entry),
    );
    final values = <int>[
      for (final candidate in related)
        switch (modality) {
          'theory' => candidate.theoryHours,
          'practice' => candidate.practiceHours,
          'ead' => candidate.eadHours,
          'extension' => candidate.extensionHours,
          _ => 0,
        },
      switch (modality) {
        'theory' => entry.theoryHours,
        'practice' => entry.practiceHours,
        'ead' => entry.eadHours,
        'extension' => entry.extensionHours,
        _ => 0,
      },
    ];
    return values.fold<int>(
      0,
      (maximum, value) => value > maximum ? value : maximum,
    );
  }

  HorarioDisciplina? _firstConfiguredTurma(
    List<HorarioDisciplina> subjectEntries,
  ) {
    if (subjectEntries.isEmpty) return null;
    final source = subjectEntries.first;
    for (final modality in const ['theory', 'practice', 'ead', 'extension']) {
      if (_sharedHours(source, modality) <= 0) continue;
      final groups = subjectEntries
          .where((entry) => entry.modality == modality)
          .toList();
      final identified = groups
          .where((entry) => entry.className.trim().isNotEmpty)
          .firstOrNull;
      if (identified != null) return identified;
      if (groups.isNotEmpty) return groups.first;
    }
    return null;
  }

  List<HorarioDisciplina> _disciplineOptions(HorarioDisciplina? current) {
    final entries = [..._entries, if (_creating) _blank()];
    final bySubject = <String, List<HorarioDisciplina>>{};
    for (final entry in entries) {
      bySubject.putIfAbsent(_disciplineGroupKey(entry), () => []).add(entry);
    }
    return bySubject.values.map((groups) {
      if (current != null &&
          _disciplineGroupKey(current) == _disciplineGroupKey(groups.first)) {
        if (current.modality != 'legacy') return current;
      }
      final sameMode = groups
          .where((entry) => entry.modality == _selectedModality)
          .toList();
      final sameClass = sameMode
          .where(
            (entry) =>
                entry.className.trim().isNotEmpty &&
                entry.className.trim().toLowerCase() ==
                    current?.className.trim().toLowerCase(),
          )
          .firstOrNull;
      return sameClass ??
          _firstConfiguredTurma(groups) ??
          groups.where((entry) => entry.modality != 'legacy').firstOrNull ??
          groups.first;
    }).toList()..sort((a, b) {
      final acronym = a.acronym.toLowerCase().compareTo(
        b.acronym.toLowerCase(),
      );
      return acronym != 0
          ? acronym
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  void _switchEntry(String? id) {
    if (id == null) return;
    if (id == _selectedId) return;
    final entry = _entries.where((e) => e.id == id).firstOrNull;
    if (entry == null) return;
    if (!_commitCurrent()) return;
    setState(() {
      _addingTurma = false;
      _newEntryId = null;
      _newEntryTemplate = null;
      _selectedId = id;
      _select(entry);
    });
  }

  Future<({bool blank, HorarioDisciplina? template})?> _chooseTemplate() async {
    final search = TextEditingController();
    final result = await showDialog<({bool blank, HorarioDisciplina? template})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = search.text.trim().toLowerCase();
          final visible = _entries.where((entry) {
            return query.isEmpty ||
                entry.acronym.toLowerCase().contains(query) ||
                entry.name.toLowerCase().contains(query);
          }).toList();
          return AlertDialog(
            title: const Text('Nova disciplina'),
            content: SizedBox(
              width: 560,
              height: 500,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Escolha uma disciplina para copiar ou comece em branco.',
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: search,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Filtrar por sigla ou nome',
                    ),
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.primary.withAlpha(20),
                      child: Icon(Icons.add_rounded, color: AppTheme.primary),
                    ),
                    title: const Text('Começar em branco'),
                    subtitle: const Text(
                      'Preencher todos os dados manualmente.',
                    ),
                    onTap: () => Navigator.pop(dialogContext, (
                      blank: true,
                      template: null,
                    )),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 6),
                  Expanded(
                    child: visible.isEmpty
                        ? Center(
                            child: Text(
                              _entries.isEmpty
                                  ? 'Ainda não há disciplinas para usar como modelo.'
                                  : 'Nenhuma disciplina corresponde à busca.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppTheme.textSecondary),
                            ),
                          )
                        : ListView.separated(
                            itemCount: visible.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = visible[index];
                              return ListTile(
                                title: Text(
                                  '${entry.acronym} · ${entry.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  'Turma ${entry.className}${entry.teacherNames.isEmpty ? '' : ' · ${entry.teacherNames.join(', ')}'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.pop(dialogContext, (
                                  blank: false,
                                  template: entry,
                                )),
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
            ],
          );
        },
      ),
    );
    search.dispose();
    return result;
  }

  Future<void> _startCreating() async {
    if (!_commitCurrent()) return;
    final choice = await _chooseTemplate();
    if (choice == null || !mounted) return;
    setState(() {
      _addingTurma = false;
      _newEntryId = const Uuid().v4();
      _newEntryTemplate = choice.blank ? null : choice.template;
      _selectedId = _newEntryId;
      _select(_blank());
    });
  }

  Future<void> _startAddingTurma() async {
    final selected = _selected;
    final selectedId = _selectedId;
    if (selected == null || !_commitCurrent()) return;
    final source = _entries
        .where((entry) => entry.id == selectedId)
        .firstOrNull;
    if (source == null) return;
    await _createTurmaDraft(source, _selectedModality);
  }

  Future<void> _createTurmaDraft(
    HorarioDisciplina source,
    String modality,
  ) async {
    if (modality == 'legacy') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecione uma modalidade antes de adicionar a turma.'),
        ),
      );
      return;
    }
    final classNameController = TextEditingController();
    final className = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nova turma'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: classNameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Identificação da turma',
              hintText: 'Ex.: 1, A1, B ou U',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, classNameController.text.trim()),
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );
    classNameController.dispose();
    if (className == null || className.isEmpty || !mounted) return;
    final duplicated = _entries.any(
      (entry) =>
          entry.subjectId == source.subjectId &&
          entry.modality == modality &&
          entry.className.trim().toLowerCase() == className.toLowerCase(),
    );
    if (duplicated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Essa turma já existe nesta modalidade.')),
      );
      return;
    }
    final template = source.copyWith(
      modality: modality,
      className: className,
      room: '',
      teachers: const [],
      slots: const [],
    );
    setState(() {
      _addingTurma = true;
      _selectedModality = modality;
      _newEntryId = const Uuid().v4();
      _newEntryTemplate = template;
      _selectedId = _newEntryId;
      _select(_blank());
    });
  }

  List<HorarioDisciplina> _classGroups(HorarioDisciplina? current) {
    if (current == null) return const [];
    final groups = _entries
        .where(
          (entry) =>
              _sameDiscipline(entry, current) &&
              entry.modality == _selectedModality,
        )
        .toList();
    if (_creating && current.id == _activeNewEntryId) {
      groups.add(_editedValue(current));
    } else if (!_creating) {
      final selectedIndex = groups.indexWhere(
        (entry) => entry.id == current.id,
      );
      if (selectedIndex >= 0) groups[selectedIndex] = _editedValue(current);
    }
    groups.sort(
      (a, b) => a.className.toLowerCase().compareTo(b.className.toLowerCase()),
    );
    return groups;
  }

  Future<void> _promptTurmaIdentification() async {
    final current = _selected;
    if (current == null) return;
    final controller = TextEditingController(text: _class.text.trim());
    final identification = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Identificação da turma'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Turma',
              hintText: 'Ex.: 1, A1, B ou U',
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
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
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (identification == null || !mounted) return;
    if (identification.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe a identificação da turma.')),
      );
      return;
    }
    final duplicate = _entries.any(
      (entry) =>
          entry.id != current.id &&
          _disciplineGroupKey(entry) == _disciplineGroupKey(current) &&
          entry.modality == _selectedModality &&
          entry.className.trim().toLowerCase() == identification.toLowerCase(),
    );
    if (duplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Essa turma já existe nesta modalidade da disciplina.'),
        ),
      );
      return;
    }
    setState(() => _class.text = identification);
  }

  Future<void> _changeModality(String value) async {
    if (value == _selectedModality) return;
    if (_creating) {
      setState(() {
        _selectedModality = value;
        if (value == 'ead') _slots.clear();
      });
      return;
    }
    final selected = _selected;
    final selectedId = _selectedId;
    if (selected == null || !_commitCurrent()) return;
    final source = _entries
        .where((entry) => entry.id == selectedId)
        .firstOrNull;
    if (source == null) return;
    final existing = _entries
        .where(
          (entry) =>
              entry.subjectId == source.subjectId && entry.modality == value,
        )
        .firstOrNull;
    if (existing != null) {
      setState(() {
        _addingTurma = false;
        _newEntryId = null;
        _newEntryTemplate = null;
        _selectedId = existing.id;
        _select(existing);
      });
      return;
    }
    await _createTurmaDraft(source, value);
  }

  HorarioDisciplina _editedValue(HorarioDisciplina source) => source.copyWith(
    subjectId:
        _creating &&
            _newEntryTemplate != null &&
            (_code.text.trim() != _newEntryTemplate!.code ||
                _acronym.text.trim() != _newEntryTemplate!.acronym ||
                _name.text.trim() != _newEntryTemplate!.name)
        ? source.id
        : source.subjectId,
    modality: _selectedModality,
    code: _code.text.trim(),
    acronym: _acronym.text.trim(),
    name: _name.text.trim(),
    className: _class.text.trim(),
    teachers: _teacherNamesFromField(),
    room: _room.text.trim(),
    theoryHours: int.tryParse(_theoryHours.text.trim()) ?? 0,
    practiceHours: int.tryParse(_practiceHours.text.trim()) ?? 0,
    eadHours: int.tryParse(_eadHours.text.trim()) ?? 0,
    extensionHours: int.tryParse(_extensionHours.text.trim()) ?? 0,
    coursePeriods: List<CursoPeriodo>.of(_offerings),
    slots:
        _slots.map((key) {
          final parts = key.split(':');
          return HorarioSlot(
            weekday: int.parse(parts[0]),
            slot: int.parse(parts[1]),
          );
        }).toList()..sort(
          (a, b) => a.weekday != b.weekday
              ? a.weekday.compareTo(b.weekday)
              : a.slot.compareTo(b.slot),
        ),
  );

  bool _commitCurrent() {
    final selected = _selected;
    if (selected == null) return true;
    final hasName = _name.text.trim().isNotEmpty;
    final hasAcronym = _acronym.text.trim().isNotEmpty;
    if (!hasName || !hasAcronym) {
      if (_creating && !hasName && !hasAcronym) {
        _addingTurma = false;
        _newEntryId = null;
        _newEntryTemplate = null;
        _selectedId = null;
        return true;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe ao menos o nome e a sigla da disciplina.'),
        ),
      );
      return false;
    }
    if (_offerings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Associe a disciplina a pelo menos um curso e período.',
          ),
        ),
      );
      return false;
    }
    if (_selectedModality != 'legacy' &&
        !_availableModalities.contains(_selectedModality)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Selecione uma modalidade cuja carga horária seja maior que zero.',
          ),
        ),
      );
      return false;
    }
    final requiresClassIdentification =
        _selectedModality != 'legacy' && _selectedModality != 'ead';
    if (requiresClassIdentification && _class.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe a identificação da turma, como A1, B ou U.'),
        ),
      );
      return false;
    }
    final edited = _editedValue(selected);
    final duplicateClass =
        _selectedModality != 'legacy' &&
        _class.text.trim().isNotEmpty &&
        _entries.any(
          (entry) =>
              entry.id != edited.id &&
              entry.subjectId == edited.subjectId &&
              entry.modality == _selectedModality &&
              entry.className.trim().toLowerCase() ==
                  _class.text.trim().toLowerCase(),
        );
    if (duplicateClass) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Essa turma já existe nesta modalidade da disciplina.'),
        ),
      );
      return false;
    }
    final independentCreation = _creating && !_addingTurma;
    final index = _entries.indexWhere((entry) => entry.id == edited.id);
    if (index < 0) {
      _entries.add(edited);
    } else {
      _entries[index] = edited;
    }
    if (!independentCreation) {
      for (var i = 0; i < _entries.length; i++) {
        final entry = _entries[i];
        if (_sameDiscipline(entry, edited)) {
          _entries[i] = entry.copyWith(
            code: edited.code,
            acronym: edited.acronym,
            name: edited.name,
            theoryHours: edited.theoryHours,
            practiceHours: edited.practiceHours,
            eadHours: edited.eadHours,
            extensionHours: edited.extensionHours,
            coursePeriods: List<CursoPeriodo>.of(edited.coursePeriods),
          );
        }
      }
    }
    _addingTurma = false;
    _newEntryId = null;
    _newEntryTemplate = null;
    return true;
  }

  Future<void> _deleteSelected() async {
    final selected = _selected;
    if (selected == null) return;
    if (_creating) {
      setState(() {
        _addingTurma = false;
        _newEntryId = null;
        _newEntryTemplate = null;
        final related = _entries
            .where((entry) => entry.subjectId == selected.subjectId)
            .toList();
        if (related.isNotEmpty) {
          final sameMode = related
              .where((entry) => entry.modality == _selectedModality)
              .firstOrNull;
          final next = sameMode != null && sameMode.className.trim().isNotEmpty
              ? sameMode
              : related
                        .where((entry) => entry.className.trim().isNotEmpty)
                        .firstOrNull ??
                    sameMode ??
                    related.first;
          _selectedId = next.id;
          _select(next);
        } else if (_entries.isNotEmpty) {
          final next = _defaultEntry;
          _selectedId = next.id;
          _select(next);
        } else {
          _selectedModality = 'theory';
          _newEntryId = const Uuid().v4();
          _selectedId = _newEntryId;
          _select(_blank());
        }
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover turma?'),
        content: Text(
          'A turma ${selected.acronym}-${selected.className} da modalidade ${_modalityName(selected.modality)} ser\u00e1 removida. As outras turmas da disciplina ser\u00e3o mantidas.',
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
      setState(() {
        _entries.removeWhere((entry) => entry.id == selected.id);
        final related = _entries
            .where((entry) => entry.subjectId == selected.subjectId)
            .toList();
        if (related.isNotEmpty) {
          final sameMode = related
              .where((entry) => entry.modality == _selectedModality)
              .firstOrNull;
          final next = sameMode != null && sameMode.className.trim().isNotEmpty
              ? sameMode
              : related
                        .where((entry) => entry.className.trim().isNotEmpty)
                        .firstOrNull ??
                    sameMode ??
                    related.first;
          _newEntryId = null;
          _newEntryTemplate = null;
          _selectedId = next.id;
          _select(next);
        } else if (_entries.isNotEmpty) {
          _newEntryId = null;
          _newEntryTemplate = null;
          final next = _defaultEntry;
          _selectedId = next.id;
          _select(next);
        } else {
          _newEntryId = const Uuid().v4();
          _newEntryTemplate = null;
          _selectedId = _newEntryId;
          _select(_blank());
        }
      });
    }
  }

  Future<void> _deleteDiscipline() async {
    final selected = _selected;
    if (selected == null || _creating) return;
    final groupKey = _disciplineGroupKey(selected);
    final groupCount = _entries
        .where((entry) => _disciplineGroupKey(entry) == groupKey)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover disciplina inteira?'),
        content: Text(
          'Serão removidas todas as modalidades e turmas de ${selected.acronym} · ${selected.name} ($groupCount turma(s)). Esta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Remover disciplina'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _entries.removeWhere((entry) => _disciplineGroupKey(entry) == groupKey);
      _newEntryId = null;
      _newEntryTemplate = null;
      _addingTurma = false;
      if (_entries.isEmpty) {
        _selectedModality = 'theory';
        _newEntryId = const Uuid().v4();
        _selectedId = _newEntryId;
        _select(_blank());
      } else {
        final next = _defaultEntry;
        _selectedId = next.id;
        _select(next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _selected;
    final classGroups = _classGroups(item);
    final disciplineOptions = _disciplineOptions(item);
    final selectedDisciplineId = item == null
        ? null
        : disciplineOptions
              .where(
                (entry) =>
                    _disciplineGroupKey(entry) == _disciplineGroupKey(item),
              )
              .firstOrNull
              ?.id;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      child: SizedBox.expand(
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
                          _creating
                              ? (_addingTurma
                                    ? 'Nova turma da disciplina'
                                    : 'Nova disciplina')
                              : 'Editor de horários',
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
                    onPressed: _closeEditor,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownMenu<String>(
                      // Keep this state stable while its popup is open. A
                      // changing key deactivates DropdownMenu's inherited
                      // overlay subtree during selection on some Flutter
                      // versions, which can trigger _dependents.isEmpty.
                      key: const ValueKey('schedule-discipline-selector'),
                      initialSelection: selectedDisciplineId,
                      textStyle: TextStyle(
                        color: item == null
                            ? AppTheme.textPrimary
                            : _disciplineStatusColor(item),
                        fontSize: 16,
                      ),
                      label: const Text('Disciplina'),
                      expandedInsets: EdgeInsets.zero,
                      enableFilter: true,
                      requestFocusOnTap: true,
                      menuHeight: 360,
                      filterCallback: (options, filter) {
                        final query = filter.trim().toLowerCase();
                        if (query.isEmpty) return options;
                        return options
                            .where(
                              (option) =>
                                  option.label.toLowerCase().contains(query),
                            )
                            .toList();
                      },
                      dropdownMenuEntries: [
                        ...disciplineOptions.map((entry) {
                          final currentValue = entry.id == _selectedId
                              ? _editedValue(entry)
                              : entry;
                          return DropdownMenuEntry<String>(
                            value: entry.id,
                            label:
                                '${currentValue.acronym} · ${currentValue.name}',
                            style: ButtonStyle(
                              foregroundColor: WidgetStatePropertyAll(
                                _disciplineStatusColor(currentValue),
                              ),
                            ),
                          );
                        }),
                      ],
                      onSelected: _switchEntry,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Adicionar disciplina ou copiar um modelo',
                    onPressed: _startCreating,
                    icon: const Icon(Icons.add_rounded),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: 'Remover disciplina inteira',
                    onPressed: item == null || _creating
                        ? null
                        : _deleteDiscipline,
                    style: IconButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                    ),
                    icon: const Icon(Icons.delete_outline_rounded),
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
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _field(_code, 'Código'),
                                  const SizedBox(height: 9),
                                  _field(_acronym, 'Sigla'),
                                  const SizedBox(height: 9),
                                  _field(
                                    _name,
                                    'Nome da disciplina',
                                    textColor: _disciplineStatusColor(item),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                  const SizedBox(height: 9),
                                  _offeringEditor(),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _field(
                                          _theoryHours,
                                          'CH Teórica',
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: _field(
                                          _practiceHours,
                                          'CH Prática',
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 9),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _field(
                                          _eadHours,
                                          'CH EaD',
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      Expanded(
                                        child: _field(
                                          _extensionHours,
                                          'CH Extens\u00e3o',
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setState(() {}),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 9),
                                  DropdownButtonFormField<String>(
                                    key: ValueKey(
                                      'modality-$_selectedId-$_selectedModality-${_availableModalities.join('-')}',
                                    ),
                                    initialValue:
                                        _availableModalities.contains(
                                          _selectedModality,
                                        )
                                        ? _selectedModality
                                        : null,
                                    hint: Text(
                                      _availableModalities.isEmpty
                                          ? 'Informe uma CH maior que zero'
                                          : 'Selecione a modalidade',
                                    ),
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                      labelText: 'Modalidade desta turma',
                                      isDense: true,
                                    ),
                                    items: [
                                      for (final modality
                                          in _availableModalities)
                                        DropdownMenuItem(
                                          value: modality,
                                          child: Text(_modalityName(modality)),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value != null) _changeModality(value);
                                    },
                                  ),
                                  if (_hasSelectedModality) ...[
                                    const SizedBox(height: 9),
                                    Row(
                                      children: [
                                        Expanded(
                                          flex: 5,
                                          child:
                                              _class.text.trim().isEmpty &&
                                                  classGroups.every(
                                                    (entry) => entry.className
                                                        .trim()
                                                        .isEmpty,
                                                  )
                                              ? TextField(
                                                  controller: _class,
                                                  readOnly: true,
                                                  maxLines: 1,
                                                  onTap:
                                                      _promptTurmaIdentification,
                                                  decoration: InputDecoration(
                                                    labelText:
                                                        'Turma (${_modalityName(_selectedModality)})',
                                                    hintText:
                                                        'Clique para identificar',
                                                    suffixIcon: const Icon(
                                                      Icons
                                                          .arrow_drop_down_rounded,
                                                    ),
                                                    isDense: true,
                                                  ),
                                                )
                                              : DropdownButtonFormField<String>(
                                                  key: ValueKey(
                                                    'class-$_selectedId-$_selectedModality',
                                                  ),
                                                  initialValue:
                                                      classGroups.any(
                                                        (entry) =>
                                                            entry.id ==
                                                            _selectedId,
                                                      )
                                                      ? _selectedId
                                                      : null,
                                                  hint: const Text(
                                                    'Selecione a turma',
                                                  ),
                                                  isExpanded: true,
                                                  decoration: InputDecoration(
                                                    labelText:
                                                        'Turma (${_modalityName(_selectedModality)})',
                                                    isDense: true,
                                                  ),
                                                  items: classGroups
                                                      .map(
                                                        (
                                                          entry,
                                                        ) => DropdownMenuItem(
                                                          value: entry.id,
                                                          child: Text(
                                                            entry.className
                                                                    .trim()
                                                                    .isEmpty
                                                                ? 'Turma sem identificação'
                                                                : entry
                                                                      .className,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                      )
                                                      .toList(),
                                                  onChanged: _switchEntry,
                                                ),
                                        ),
                                        const SizedBox(width: 4),
                                        IconButton.filledTonal(
                                          tooltip:
                                              'Adicionar turma nesta modalidade',
                                          onPressed: _startAddingTurma,
                                          style: IconButton.styleFrom(
                                            minimumSize: const Size(36, 36),
                                            fixedSize: const Size(36, 36),
                                            maximumSize: const Size(36, 36),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          iconSize: 18,
                                          icon: const Icon(Icons.add_rounded),
                                        ),
                                        const SizedBox(width: 2),
                                        IconButton.filledTonal(
                                          tooltip: 'Remover turma selecionada',
                                          onPressed: _deleteSelected,
                                          style: IconButton.styleFrom(
                                            foregroundColor: AppTheme.danger,
                                            minimumSize: const Size(36, 36),
                                            fixedSize: const Size(36, 36),
                                            maximumSize: const Size(36, 36),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          iconSize: 18,
                                          icon: const Icon(
                                            Icons.remove_rounded,
                                          ),
                                        ),
                                        const SizedBox(width: 3),
                                        Expanded(
                                          flex: 4,
                                          child: _field(
                                            _room,
                                            'Sala desta turma',
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 9),
                                    _teacherPickerField(),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!_hasSelectedModality)
                                  const Expanded(child: SizedBox.shrink())
                                else ...[
                                  Row(
                                    children: [
                                      Text(
                                        'HORÁRIOS DA SEMANA',
                                        style: TextStyle(
                                          color: _weeklyHoursStatusColor,
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
                                                        child: Builder(
                                                          builder: (context) {
                                                            final slotKey =
                                                                '$day:$slot';
                                                            final otherClasses =
                                                                _otherClassesAtSlot(
                                                                  slotKey,
                                                                );
                                                            final modalities =
                                                                otherClasses
                                                                    .map(
                                                                      (
                                                                        entry,
                                                                      ) => entry
                                                                          .modality,
                                                                    )
                                                                    .toSet()
                                                                    .toList();
                                                            final markerColor =
                                                                modalities
                                                                    .isEmpty
                                                                ? null
                                                                : _modalityScheduleColor(
                                                                    modalities
                                                                        .first,
                                                                  );
                                                            final tooltip =
                                                                otherClasses
                                                                    .isEmpty
                                                                ? null
                                                                : otherClasses
                                                                      .map(
                                                                        (
                                                                          entry,
                                                                        ) =>
                                                                            '${_modalityName(entry.modality)} - turma ${entry.className}',
                                                                      )
                                                                      .toSet()
                                                                      .join(
                                                                        '\r\n',
                                                                      );
                                                            return Tooltip(
                                                              message:
                                                                  tooltip ?? '',
                                                              child: SizedBox(
                                                                width: 40,
                                                                height: 40,
                                                                child: Stack(
                                                                  alignment:
                                                                      Alignment
                                                                          .center,
                                                                  children: [
                                                                    CheckboxTheme(
                                                                      data: CheckboxThemeData(
                                                                        side:
                                                                            markerColor ==
                                                                                null
                                                                            ? null
                                                                            : BorderSide(
                                                                                color: markerColor,
                                                                                width: 2,
                                                                              ),
                                                                      ),
                                                                      child: Checkbox(
                                                                        value: _slots.contains(
                                                                          slotKey,
                                                                        ),
                                                                        onChanged:
                                                                            _selectedModality ==
                                                                                'ead'
                                                                            ? null
                                                                            : (
                                                                                selected,
                                                                              ) => setState(() {
                                                                                if (selected ==
                                                                                    true) {
                                                                                  _slots.add(
                                                                                    slotKey,
                                                                                  );
                                                                                } else {
                                                                                  _slots.remove(
                                                                                    slotKey,
                                                                                  );
                                                                                }
                                                                              }),
                                                                      ),
                                                                    ),
                                                                    if (modalities
                                                                            .length >
                                                                        1)
                                                                      Positioned(
                                                                        top: 1,
                                                                        right:
                                                                            1,
                                                                        child: Row(
                                                                          mainAxisSize:
                                                                              MainAxisSize.min,
                                                                          children: [
                                                                            for (final modality
                                                                                in modalities)
                                                                              Container(
                                                                                width: 5,
                                                                                height: 5,
                                                                                margin: const EdgeInsets.only(
                                                                                  left: 1,
                                                                                ),
                                                                                decoration: BoxDecoration(
                                                                                  color: _modalityScheduleColor(
                                                                                    modality,
                                                                                  ),
                                                                                  shape: BoxShape.circle,
                                                                                ),
                                                                              ),
                                                                          ],
                                                                        ),
                                                                      ),
                                                                  ],
                                                                ),
                                                              ),
                                                            );
                                                          },
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
                                  Builder(
                                    builder: (context) {
                                      final statusColor =
                                          _disciplineStatusColor(item);
                                      return Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(11),
                                        decoration: BoxDecoration(
                                          color: statusColor.withAlpha(16),
                                          borderRadius: BorderRadius.circular(
                                            11,
                                          ),
                                        ),
                                        child: Text(
                                          _disciplineStatusMessage(item),
                                          style: TextStyle(
                                            color: statusColor,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            height: 1.35,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ],
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
                  FilledButton.icon(
                    onPressed: item == null ? null : _save,
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Salvar disciplina e horários'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _closeEditor,
                    child: const Text('Fechar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  int get _expectedWeeklyHours => switch (_selectedModality) {
    'theory' => int.tryParse(_theoryHours.text.trim()) ?? 0,
    'practice' => int.tryParse(_practiceHours.text.trim()) ?? 0,
    'ead' => 0,
    'extension' => int.tryParse(_extensionHours.text.trim()) ?? 0,
    _ =>
      (int.tryParse(_theoryHours.text.trim()) ?? 0) +
          (int.tryParse(_practiceHours.text.trim()) ?? 0),
  };

  Color get _weeklyHoursStatusColor {
    if (_selectedModality == 'extension' || _selectedModality == 'ead') {
      return const Color(0xFF16803C);
    }
    return _weeklyHoursStatusColorForValues(
      scheduled: _slots.length,
      expected: _expectedWeeklyHours,
    );
  }

  Color _weeklyHoursStatusColorFor(HorarioDisciplina entry) {
    if (entry.modality == 'extension' || entry.modality == 'ead') {
      return const Color(0xFF16803C);
    }
    return _weeklyHoursStatusColorForValues(
      scheduled: entry.slots.length,
      expected: switch (entry.modality) {
        'theory' => entry.theoryHours,
        'practice' => entry.practiceHours,
        'ead' => 0,
        'extension' => entry.extensionHours,
        _ => entry.theoryHours + entry.practiceHours,
      },
    );
  }

  Color _disciplineStatusColor(HorarioDisciplina discipline) {
    final selected = _selected;
    final editingThisDiscipline =
        selected != null && _sameDiscipline(selected, discipline);
    final groups = _entries
        .where((entry) => _sameDiscipline(entry, discipline))
        .map(
          (entry) => editingThisDiscipline && entry.id == selected.id
              ? _editedValue(selected)
              : entry,
        )
        .toList();
    if (_creating &&
        editingThisDiscipline &&
        !groups.any((entry) => entry.id == selected.id)) {
      groups.add(_editedValue(discipline));
    }
    final theory = editingThisDiscipline
        ? int.tryParse(_theoryHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'theory');
    final practice = editingThisDiscipline
        ? int.tryParse(_practiceHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'practice');
    final ead = editingThisDiscipline
        ? int.tryParse(_eadHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'ead');
    final extension = editingThisDiscipline
        ? int.tryParse(_extensionHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'extension');
    final classGroups = groups.where(_isIdentifiedModalityClass).toList();
    bool hasClassFor(String modality) =>
        classGroups.any((entry) => entry.modality == modality);
    if ((theory > 0 && !hasClassFor('theory')) ||
        (practice > 0 && !hasClassFor('practice')) ||
        (extension > 0 && !hasClassFor('extension'))) {
      return const Color(0xFFB42318);
    }
    final checkedGroups = classGroups.map(
      (entry) => entry.copyWith(
        theoryHours: theory,
        practiceHours: practice,
        eadHours: ead,
        extensionHours: extension,
      ),
    );
    final turmaColors = checkedGroups.map(_weeklyHoursStatusColorFor).toList();
    if (turmaColors.contains(const Color(0xFFB42318))) {
      return const Color(0xFFB42318);
    }
    if (turmaColors.contains(const Color(0xFF9A6700))) {
      return const Color(0xFF9A6700);
    }
    return const Color(0xFF16803C);
  }

  String _disciplineStatusMessage(HorarioDisciplina discipline) {
    final selected = _selected;
    final editingThisDiscipline =
        selected != null && _sameDiscipline(selected, discipline);
    final groups = _entries
        .where((entry) => _sameDiscipline(entry, discipline))
        .map(
          (entry) => editingThisDiscipline && entry.id == selected.id
              ? _editedValue(selected)
              : entry,
        )
        .toList();
    if (_creating &&
        editingThisDiscipline &&
        !groups.any((entry) => entry.id == selected.id)) {
      groups.add(_editedValue(discipline));
    }

    final theory = editingThisDiscipline
        ? int.tryParse(_theoryHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'theory');
    final practice = editingThisDiscipline
        ? int.tryParse(_practiceHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'practice');
    final extension = editingThisDiscipline
        ? int.tryParse(_extensionHours.text.trim()) ?? 0
        : _sharedHours(discipline, 'extension');
    final classGroups = groups.where(_isIdentifiedModalityClass).toList();
    final missingModalities = <String>[
      if (theory > 0 && !classGroups.any((entry) => entry.modality == 'theory'))
        'Teórica',
      if (practice > 0 &&
          !classGroups.any((entry) => entry.modality == 'practice'))
        'Prática',
      if (extension > 0 &&
          !classGroups.any((entry) => entry.modality == 'extension'))
        'Extensão',
    ];

    final draft = editingThisDiscipline ? _editedValue(selected) : null;
    final shortages = <String>[];
    final overages = <String>[];
    for (final storedEntry in classGroups) {
      final entry = draft != null && storedEntry.id == draft.id
          ? draft
          : storedEntry;
      if (entry.modality == 'ead' || entry.modality == 'extension') continue;
      final expected = entry.modality == 'theory' ? theory : practice;
      final scheduled = entry.slots.length;
      if (scheduled < expected) {
        shortages.add(
          '${entry.timetableLabel}: $scheduled/$expected aulas semanais',
        );
      } else if (scheduled > expected) {
        overages.add(
          '${entry.timetableLabel}: $scheduled/$expected aulas semanais',
        );
      }
    }

    final messages = <String>[
      if (missingModalities.isNotEmpty)
        'Falta cadastrar turma para CH ${missingModalities.join(' e CH ')}.',
      if (shortages.isNotEmpty)
        'Carga horária incompleta: ${shortages.join('; ')}.',
      if (overages.isNotEmpty)
        'Há mais horários que a carga horária: ${overages.join('; ')}.',
    ];
    return messages.isEmpty ? 'Disciplina ok.' : messages.join('\r\n');
  }

  bool _isIdentifiedModalityClass(HorarioDisciplina entry) =>
      const {
        'theory',
        'practice',
        'ead',
        'extension',
      }.contains(entry.modality) &&
      entry.className.trim().isNotEmpty;

  Color _weeklyHoursStatusColorForValues({
    required int scheduled,
    required int expected,
  }) {
    if (scheduled < expected) return const Color(0xFFB42318);
    if (scheduled == expected) return const Color(0xFF16803C);
    return const Color(0xFF9A6700);
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    Color? textColor,
    ValueChanged<String>? onChanged,
  }) => TextField(
    controller: controller,
    keyboardType: keyboardType,
    onChanged: onChanged,
    style: textColor == null
        ? null
        : TextStyle(color: textColor, fontWeight: FontWeight.w600),
    decoration: InputDecoration(labelText: label, isDense: true),
  );

  Future<void> _addOffering() async {
    final programIds = widget.programs.keys.toList()..sort();
    if (programIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cadastre um curso antes de associar a disciplina.'),
        ),
      );
      return;
    }

    var selectedProgram = programIds.contains(widget.selectedProgram)
        ? widget.selectedProgram
        : programIds.first;
    var selectedPeriod =
        widget.selectedPeriod >= 1 && widget.selectedPeriod <= 11
        ? widget.selectedPeriod
        : 1;
    final periods = List<int>.generate(11, (index) => index + 1);
    final offering = await showDialog<CursoPeriodo>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Adicionar oferta'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: selectedProgram,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Curso'),
                  items: [
                    for (final id in programIds)
                      DropdownMenuItem(
                        value: id,
                        child: Text(
                          widget.programs[id] ?? 'Curso $id',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedProgram = value);
                    }
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: selectedPeriod,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Per\u00edodo'),
                  items: [
                    for (final period in periods)
                      DropdownMenuItem(
                        value: period,
                        child: Text(_periodName(period)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedPeriod = value);
                    }
                  },
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
              onPressed: () => Navigator.pop(
                dialogContext,
                CursoPeriodo(program: selectedProgram, period: selectedPeriod),
              ),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Aplicar'),
            ),
          ],
        ),
      ),
    );
    if (offering == null || !mounted) return;

    final exists = _offerings.any(
      (item) =>
          item.program == offering.program && item.period == offering.period,
    );
    if (exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Esse curso j? est? associado a esse per?odo.'),
        ),
      );
      return;
    }
    setState(() {
      _offerings.add(offering);
      _offerings.sort((a, b) {
        final course = a.program.compareTo(b.program);
        return course != 0 ? course : a.period.compareTo(b.period);
      });
    });
  }

  void _removeOffering(CursoPeriodo offering) {
    if (_offerings.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A disciplina precisa permanecer ofertada em pelo menos um curso e per?odo.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _offerings.removeWhere(
        (item) =>
            item.program == offering.program && item.period == offering.period,
      );
    });
  }

  Widget _offeringEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  'Cursos e per\u00edodos de oferta',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                tooltip: 'Adicionar curso e per?odo de oferta',
                onPressed: _addOffering,
                style: IconButton.styleFrom(
                  fixedSize: const Size(34, 34),
                  padding: EdgeInsets.zero,
                ),
                iconSize: 18,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
        ),
        if (_offerings.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final offering in _offerings)
                InputChip(
                  label: Text(
                    '${widget.programs[offering.program] ?? 'Curso ${offering.program}'} - ${_periodName(offering.period)}',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onPressed: () {},
                  onDeleted: _offerings.length <= 1
                      ? null
                      : () => _removeOffering(offering),
                ),
            ],
          ),
        ],
      ],
    );
  }

  String _periodName(int period) =>
      period == 11 ? 'Optativas' : 'Per\u00edodo $period';

  List<String> _teacherNamesFromField() {
    final names = <String>[];
    final normalized = <String>{};
    for (final value in _teacher.text.split(RegExp(r'[,;\r\n]'))) {
      final name = value.trim();
      if (name.isNotEmpty && normalized.add(name.toLowerCase())) {
        names.add(name);
      }
    }
    return names;
  }

  Future<void> _save() async {
    if (!_commitCurrent()) return;
    setState(() {});
    await widget.onSave(List.of(_entries));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Disciplina e horários salvos.')),
    );
  }
}

class _ScheduleExportChoice {
  const _ScheduleExportChoice({required this.periods});

  final List<int> periods;
}

class _TermCopyChoice {
  const _TermCopyChoice.blank() : sourceTerm = null;
  const _TermCopyChoice.copy(this.sourceTerm);

  final String? sourceTerm;
}

class _TeacherRosterResult {
  const _TeacherRosterResult(this.teachers, this.renamed, this.entries);

  final List<String> teachers;
  final Map<String, String> renamed;
  final List<HorarioDisciplina> entries;

  Map<String, dynamic> toJson() => {
    'teachers': teachers,
    'renamed': renamed,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  factory _TeacherRosterResult.fromJson(Map<String, dynamic> json) =>
      _TeacherRosterResult(
        (json['teachers'] as List).cast<String>(),
        (json['renamed'] as Map).map(
          (key, value) => MapEntry(key as String, value as String),
        ),
        (json['entries'] as List)
            .map(
              (entry) => HorarioDisciplina.fromJson(
                Map<String, dynamic>.from(entry as Map),
              ),
            )
            .toList(),
      );
}

class _TeacherRosterPage extends StatefulWidget {
  const _TeacherRosterPage({
    required this.teachers,
    required this.entries,
    required this.programs,
    required this.onSave,
    this.initialTeacher,
    this.onClose,
    this.channelName,
  });

  final List<String> teachers;
  final List<HorarioDisciplina> entries;
  final Map<int, String> programs;
  final Future<void> Function(_TeacherRosterResult result) onSave;
  final String? initialTeacher;
  final Future<void> Function(_TeacherRosterResult result)? onClose;
  final String? channelName;

  @override
  State<_TeacherRosterPage> createState() => _TeacherRosterPageState();
}

class _TeacherRosterPageState extends State<_TeacherRosterPage> {
  late final List<String> _teachers = [...widget.teachers];
  late List<HorarioDisciplina> _entries = [...widget.entries];
  final Map<String, String> _renamed = {};
  String? _selectedTeacher;
  int? _selectedProgram;
  int? _selectedPeriod;
  bool _showOnlyAssignedClasses = false;
  final _disciplineSearch = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedTeacher = _teachers.contains(widget.initialTeacher)
        ? widget.initialTeacher
        : _teachers.firstOrNull;
    _selectedProgram = widget.programs.keys.firstOrNull;
    final channelName = widget.channelName;
    if (channelName != null) {
      WindowMethodChannel(
        channelName,
        mode: ChannelMode.bidirectional,
      ).setMethodCallHandler((call) async {
        if (call.method == 'selectTeacher') {
          final teacher = call.arguments as String?;
          if (teacher != null && mounted && _teachers.contains(teacher)) {
            setState(() => _selectedTeacher = teacher);
          }
          return true;
        }
        throw MissingPluginException(
          'M\u00e9todo n\u00e3o reconhecido: ${call.method}',
        );
      });
    }
  }

  @override
  void dispose() {
    _disciplineSearch.dispose();
    super.dispose();
  }

  Future<String?> _askName({String? current}) async {
    final controller = TextEditingController(text: current ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(current == null ? 'Adicionar docente' : 'Editar docente'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Nome do docente',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
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
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final duplicate = _teachers.any(
      (teacher) =>
          teacher.toLowerCase() == trimmed.toLowerCase() && teacher != current,
    );
    if (duplicate) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Já existe um docente com esse nome.')),
        );
      }
      return null;
    }
    return trimmed;
  }

  Future<void> _addTeacher() async {
    final name = await _askName();
    if (name == null || !mounted) return;
    setState(() {
      _teachers.add(name);
      _selectedTeacher = name;
    });
  }

  Future<void> _editTeacher(String oldName) async {
    final name = await _askName(current: oldName);
    if (name == null || !mounted) return;
    setState(() {
      final index = _teachers.indexOf(oldName);
      _teachers[index] = name;
      _renamed[oldName] = name;
      _entries = _entries
          .map(
            (entry) => entry.copyWith(
              teachers: entry.teacherNames
                  .map((assigned) => assigned == oldName ? name : assigned)
                  .toList(),
            ),
          )
          .toList();
      if (_selectedTeacher == oldName) _selectedTeacher = name;
    });
  }

  Future<void> _removeTeacher(String name) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover docente?'),
        content: Text(
          '“$name” será removido do cadastro e das disciplinas em que está vinculado.',
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
    if (remove != true || !mounted) return;
    setState(() {
      _teachers.remove(name);
      _renamed[name] = '';
      _entries = _entries
          .map(
            (entry) => entry.copyWith(
              teachers: entry.teacherNames
                  .where((assigned) => assigned != name)
                  .toList(),
            ),
          )
          .toList();
      _selectedTeacher = _teachers.firstOrNull;
    });
  }

  List<int> get _availablePeriods =>
      _entries
          .where(
            (entry) =>
                _selectedProgram == null ||
                entry.coursePeriods.any(
                  (offering) => offering.program == _selectedProgram,
                ),
          )
          .expand(
            (entry) => entry.coursePeriods
                .where(
                  (offering) =>
                      _selectedProgram == null ||
                      offering.program == _selectedProgram,
                )
                .map((offering) => offering.period),
          )
          .toSet()
          .toList()
        ..sort();

  List<HorarioDisciplina> get _visibleClasses {
    final query = _disciplineSearch.text.trim().toLowerCase();
    return _entries.where((entry) {
      final isAssigned = entry.teacherNames.any(
        (name) => name.toLowerCase() == _selectedTeacher?.toLowerCase(),
      );
      if (_showOnlyAssignedClasses && !isAssigned) return false;
      final offerings = entry.coursePeriods.where(
        (offering) =>
            (_selectedProgram == null ||
                offering.program == _selectedProgram) &&
            (_selectedPeriod == null || offering.period == _selectedPeriod),
      );
      if (offerings.isEmpty) return false;
      if (query.isEmpty) return true;
      return entry.acronym.toLowerCase().contains(query) ||
          entry.name.toLowerCase().contains(query) ||
          entry.code.toLowerCase().contains(query) ||
          entry.className.toLowerCase().contains(query) ||
          entry.timetableLabel.toLowerCase().contains(query);
    }).toList()..sort((a, b) {
      final course = a.acronym.toLowerCase().compareTo(b.acronym.toLowerCase());
      if (course != 0) return course;
      final modality = a.modality.compareTo(b.modality);
      if (modality != 0) return modality;
      return a.className.toLowerCase().compareTo(b.className.toLowerCase());
    });
  }

  String _modalityName(String modality) => switch (modality) {
    'theory' => 'Teórica',
    'practice' => 'Prática',
    'ead' => 'EaD',
    'extension' => 'Extensão',
    _ => 'Anterior',
  };

  void _setClassAssignment(HorarioDisciplina entry, bool assigned) {
    final teacher = _selectedTeacher;
    if (teacher == null) return;
    setState(() {
      _entries = _entries.map((candidate) {
        if (candidate.id != entry.id) return candidate;
        final names = candidate.teacherNames
            .where((name) => name.toLowerCase() != teacher.toLowerCase())
            .toList();
        if (assigned) names.add(teacher);
        return candidate.copyWith(teachers: names);
      }).toList();
    });
  }

  Future<void> _editSelectedTeacher() async {
    final selected = _selectedTeacher;
    if (selected != null) await _editTeacher(selected);
  }

  _TeacherRosterResult _currentResult() => _TeacherRosterResult(
    List.of(_teachers),
    Map.of(_renamed),
    List.of(_entries),
  );

  Future<void> _saveChanges() async {
    await widget.onSave(_currentResult());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Alterações salvas. Você pode continuar editando.'),
      ),
    );
  }

  Future<void> _closePage() async {
    final onClose = widget.onClose;
    if (onClose != null) {
      await onClose(_currentResult());
    } else if (mounted) {
      Navigator.pop(context, _currentResult());
    }
  }

  Future<void> _removeSelectedTeacher() async {
    final selected = _selectedTeacher;
    if (selected != null) await _removeTeacher(selected);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Voltar',
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: _closePage,
      ),
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Editar docentes'),
          Text(
            'Cadastre e mantenha os nomes usados nas disciplinas.',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
          ),
        ],
      ),
      actions: [
        FilledButton.icon(
          onPressed: _saveChanges,
          icon: const Icon(Icons.save_rounded),
          label: const Text('Salvar'),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: _closePage,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Fechar'),
        ),
        const SizedBox(width: 16),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _teachers.isEmpty
                        ? const Text('Nenhum docente cadastrado.')
                        : _SearchableSelect<String>(
                            key: ValueKey('teacher-roster-$_selectedTeacher'),
                            value: _selectedTeacher!,
                            options: _teachers,
                            label: 'Docente',
                            optionLabel: (name) => name,
                            icon: Icons.person_rounded,
                            onSelected: (name) {
                              setState(() => _selectedTeacher = name);
                              final channelName = widget.channelName;
                              if (channelName != null) {
                                unawaited(
                                  WindowMethodChannel(
                                    channelName,
                                    mode: ChannelMode.bidirectional,
                                  ).invokeMethod<bool>('teacherSelected', name),
                                );
                              }
                            },
                          ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _addTeacher,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('Novo docente'),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'Editar docente selecionado',
                    onPressed: _selectedTeacher == null
                        ? null
                        : _editSelectedTeacher,
                    icon: const Icon(Icons.edit_rounded),
                  ),
                  IconButton(
                    tooltip: 'Remover docente selecionado',
                    onPressed: _selectedTeacher == null
                        ? null
                        : _removeSelectedTeacher,
                    color: Theme.of(context).colorScheme.error,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${_teachers.length} docentes cadastrados - marque as turmas vinculadas ao docente selecionado.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<int>(
                      initialValue: _selectedProgram,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Curso'),
                      items: [
                        for (final program in widget.programs.keys)
                          DropdownMenuItem(
                            value: program,
                            child: Text(
                              widget.programs[program] ?? 'Curso',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (program) => setState(() {
                        _selectedProgram = program;
                        _selectedPeriod = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      initialValue: _selectedPeriod,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Período'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Todos'),
                        ),
                        for (final period in _availablePeriods)
                          DropdownMenuItem<int?>(
                            value: period,
                            child: Text(
                              period == 11 ? 'Optativas' : '$periodº período',
                            ),
                          ),
                      ],
                      onChanged: (period) =>
                          setState(() => _selectedPeriod = period),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _disciplineSearch,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Filtrar disciplina, sigla ou turma',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _showOnlyAssignedClasses
                          ? '${_visibleClasses.length} turma(s) vinculada(s)'
                          : '${_visibleClasses.length} turma(s) encontrada(s)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  SizedBox(
                    width: 250,
                    child: SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<bool>(
                          value: false,
                          label: Text('Todas', maxLines: 1, softWrap: false),
                        ),
                        ButtonSegment<bool>(
                          value: true,
                          label: Text(
                            'Vinculadas',
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                      selected: {_showOnlyAssignedClasses},
                      onSelectionChanged: (value) => setState(
                        () => _showOnlyAssignedClasses = value.first,
                      ),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _visibleClasses.isEmpty
                    ? const Center(
                        child: Text(
                          'Nenhuma turma encontrada para este curso e período.',
                        ),
                      )
                    : Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListView.separated(
                          itemCount: _visibleClasses.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final entry = _visibleClasses[index];
                            final offerings = entry.coursePeriods
                                .where(
                                  (item) =>
                                      (_selectedProgram == null ||
                                          item.program == _selectedProgram) &&
                                      (_selectedPeriod == null ||
                                          item.period == _selectedPeriod),
                                )
                                .map((item) {
                                  final course =
                                      widget.programs[item.program] ?? 'Curso';
                                  final period = item.period == 11
                                      ? 'Optativas'
                                      : '${item.period}º período';
                                  return '$course - $period';
                                })
                                .join(' | ');
                            final assigned = entry.teacherNames.any(
                              (name) =>
                                  name.toLowerCase() ==
                                  _selectedTeacher?.toLowerCase(),
                            );
                            return CheckboxListTile(
                              dense: true,
                              value: assigned,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                '${entry.timetableLabel} - ${entry.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${_modalityName(entry.modality)} - Turma ${entry.className.isEmpty ? 'sem identificação' : entry.className}${entry.room.trim().isEmpty ? '' : ' - Sala ${entry.room}'}${offerings.isEmpty ? '' : ' - $offerings'}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onChanged: _selectedTeacher == null
                                  ? null
                                  : (value) => _setClassAssignment(
                                      entry,
                                      value == true,
                                    ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SearchableSelect<T extends Object> extends StatelessWidget {
  const _SearchableSelect({
    super.key,
    required this.value,
    required this.options,
    required this.label,
    required this.optionLabel,
    required this.icon,
    required this.onSelected,
  });

  final T value;
  final List<T> options;
  final String label;
  final String Function(T option) optionLabel;
  final IconData icon;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedLabel = optionLabel(value);
    return Autocomplete<T>(
      initialValue: TextEditingValue(text: selectedLabel),
      displayStringForOption: optionLabel,
      optionsBuilder: (text) {
        final query = text.text.trim().toLowerCase();
        if (query.isEmpty) return options;
        return options.where(
          (option) => optionLabel(option).toLowerCase().contains(query),
        );
      },
      onSelected: onSelected,
      optionsViewBuilder: (context, select, filteredOptions) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280, maxWidth: 480),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              shrinkWrap: true,
              itemCount: filteredOptions.length,
              itemBuilder: (context, index) {
                final option = filteredOptions.elementAt(index);
                return ListTile(
                  dense: true,
                  title: Text(
                    optionLabel(option),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => select(option),
                );
              },
            ),
          ),
        ),
      ),
      fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
        controller: controller,
        focusNode: focusNode,
        onTap: () {
          if (controller.text == selectedLabel) controller.clear();
        },
        onSubmitted: (_) => onSubmit(),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: IconButton(
            tooltip: 'Mostrar opções',
            icon: const Icon(Icons.arrow_drop_down_rounded),
            onPressed: () {
              if (controller.text.isNotEmpty) controller.clear();
              focusNode.requestFocus();
            },
          ),
        ),
      ),
    );
  }
}
