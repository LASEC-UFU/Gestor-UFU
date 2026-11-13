import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/core/utils/debug_options.dart';
import 'package:gestor_ufu/core/utils/macro_resolver.dart';
import 'package:gestor_ufu/core/utils/text_encoding.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_config_snapshot.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/data/services/diary_automation_service.dart';
import 'package:gestor_ufu/data/services/ajusta_horarios_store.dart';
import 'package:gestor_ufu/domain/entities/academic_term.dart';
import 'package:gestor_ufu/presentation/controllers/auth_controller.dart';
import 'package:gestor_ufu/presentation/controllers/config_controller.dart';
import 'package:gestor_ufu/presentation/controllers/sync_controller.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';
import 'package:gestor_ufu/presentation/widgets/academic_term_dialog.dart';

const _entriesStorageKey = 'preenche_diarios_entries_v1';
const _diaryPeriodsKey = 'ajusta_horarios_periodos_letivos';
const _activeDiaryPeriodKey = 'ajusta_horarios_periodo_letivo';
const _diaryPeriodDataPrefix = 'preenche_diarios_period_data_v1_';
const _diaryDataMigrationKey = 'preenche_diarios_period_data_migrated_v1';
const _portalCredentialsKey = 'portal_docente_credentials_v1';
const _portalDefaultUrl = 'https://www.portaldocente.ufu.br';
const _portalAddressKey = 'portal_docente_url';

class PreencheDiariosPage extends StatefulWidget {
  const PreencheDiariosPage({super.key});

  @override
  State<PreencheDiariosPage> createState() => _PreencheDiariosPageState();
}

class _PreencheDiariosPageState extends State<PreencheDiariosPage> {
  final _urlController = TextEditingController(text: _portalDefaultUrl);
  final Map<String, String> _entries = {};
  final List<String> _logs = [];
  final _automation = DiaryAutomationService.instance;
  final _uuid = const Uuid();
  List<String> _terms = [AjustaHorariosStore.defaultTerm];
  String _term = AjustaHorariosStore.defaultTerm;
  List<_SavedDiary> _savedDiaries = [];
  String? _selectedDiaryId;
  String? _selectedSnapshotId;
  List<MoodleConfigSnapshot> _moodleSnapshots = [];
  String? _sourceLabel;
  String _portalUsername = '';
  String _portalPassword = '';
  bool _portalCredentialsFromMoodle = false;
  bool _searchingPortalDates = false;
  List<String> _missingPortalDates = [];
  bool _loading = true;
  bool _openingBrowser = false;
  bool _browserReady = false;
  bool _filling = false;
  bool _importingPortalDiary = false;
  bool _extractingDiaries = false;
  bool _scanningDiaries = false;
  bool _loadingMoodleCourses = false;
  bool _requireEmpty = false;
  bool _highlight = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final controller = context.read<ConfigController>();
      await controller.loadAll();
      final snapshots = await controller.getSnapshots();
      if (mounted) setState(() => _moodleSnapshots = snapshots);
      await _loadPortalAddress();
      await _loadPortalCredentials();
      await _loadSavedEntries();
      if (kDebugMode && diaryAutomationDebugEnabled && mounted) {
        for (
          var attempt = 0;
          attempt < 40 && !_automation.isConnected;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (mounted) {
          setState(() => _browserReady = _automation.isConnected);
        }
      }
    });
  }

  Future<void> _loadPortalAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_portalAddressKey);
    if (mounted && saved != null && saved.trim().isNotEmpty) {
      _urlController.text = saved;
    }
  }

  Future<void> _saveAddress(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value.trim());
  }

  @override
  void dispose() {
    _urlController.dispose();
    unawaited(_automation.close());
    super.dispose();
  }

  Future<void> _loadSavedEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _terms = AcademicTerm.newestFirst(
        (prefs.getStringList(_diaryPeriodsKey) ?? const <String>[])
            .map((term) => term.trim())
            .where((term) => term.isNotEmpty),
      );
      if (_terms.isEmpty) _terms = [AjustaHorariosStore.defaultTerm];
      final savedTerm = prefs.getString(_activeDiaryPeriodKey)?.trim();
      _term = savedTerm != null && _terms.contains(savedTerm)
          ? savedTerm
          : _terms.first;
      if (savedTerm == null || !_terms.contains(savedTerm)) {
        await prefs.setString(_activeDiaryPeriodKey, _term);
      }
      await prefs.setStringList(_diaryPeriodsKey, _terms);
      final migrateLegacy = prefs.getBool(_diaryDataMigrationKey) != true;
      await _loadPeriodWorkspace(
        _term,
        prefs: prefs,
        allowLegacy: migrateLegacy,
      );
      await prefs.setBool(_diaryDataMigrationKey, true);
      if (migrateLegacy) await _persist();
    } catch (error) {
      _log('Failed loading saved diary data: $error');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadPortalCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_portalCredentialsKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _portalUsername = decoded['username'] as String? ?? '';
          _portalPassword = decoded['password'] as String? ?? '';
        }
      } catch (_) {}
    } else {
      final moodleRaw = prefs.getString('moodle_credential');
      if (moodleRaw != null) {
        try {
          final credential = jsonDecode(moodleRaw) as Map<String, dynamic>;
          _portalUsername = credential['username'] as String? ?? '';
          _portalPassword = credential['password'] as String? ?? '';
          _portalCredentialsFromMoodle =
              _portalUsername.isNotEmpty && _portalPassword.isNotEmpty;
        } catch (_) {}
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _configurePortalCredentials() async {
    final username = TextEditingController(text: _portalUsername);
    final password = TextEditingController(text: _portalPassword);
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Acesso ao Portal do Docente'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: username,
                autofocus: true,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Usuário',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Senha',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'As credenciais ficam salvas localmente no Gestor UFU e são usadas ao abrir o portal no Edge.',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_portalUsername.isNotEmpty || _portalPassword.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'clear'),
              child: const Text('Remover'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'save'),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (!mounted) {
      username.dispose();
      password.dispose();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      username.dispose();
      password.dispose();
      return;
    }
    if (action == 'save') {
      final savedUsername = username.text.trim();
      final savedPassword = password.text;
      if (savedUsername.isEmpty || savedPassword.isEmpty) {
        _showMessage('Dados incompletos', 'Informe o usuário e a senha.');
      } else {
        await prefs.setString(
          _portalCredentialsKey,
          jsonEncode({'username': savedUsername, 'password': savedPassword}),
        );
        setState(() {
          _portalUsername = savedUsername;
          _portalPassword = savedPassword;
          _portalCredentialsFromMoodle = false;
        });
        _log('Credenciais do Portal do Docente salvas neste computador.');
      }
    } else if (action == 'clear') {
      await prefs.setString(
        _portalCredentialsKey,
        jsonEncode({'username': '', 'password': ''}),
      );
      setState(() {
        _portalUsername = '';
        _portalPassword = '';
        _portalCredentialsFromMoodle = false;
      });
      _log('Credenciais do Portal do Docente removidas.');
    }
    username.dispose();
    password.dispose();
  }

  String _periodDataKey(String term) {
    final token = base64Url
        .encode(utf8.encode(term.trim()))
        .replaceAll('=', '');
    return '$_diaryPeriodDataPrefix$token';
  }

  Future<void> _loadPeriodWorkspace(
    String term, {
    required SharedPreferences prefs,
    bool allowLegacy = false,
  }) async {
    Map<String, dynamic>? data;
    final raw = prefs.getString(_periodDataKey(term));
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    }
    if (data == null && allowLegacy) {
      final legacy = prefs.getString(_entriesStorageKey);
      if (legacy != null) {
        final decoded = jsonDecode(legacy);
        if (decoded is Map) {
          data = {
            'draftEntries': decoded,
            'sourceLabel': 'Dados locais salvos',
          };
        }
      }
    }

    final diaries = <_SavedDiary>[];
    final rawDiaries = data?['savedDiaries'];
    if (rawDiaries is List) {
      for (final item in rawDiaries.whereType<Map>()) {
        try {
          diaries.add(_SavedDiary.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          // Keep usable diaries when one stored record is malformed.
        }
      }
    }
    final selectedId = data?['selectedDiaryId'] as String?;
    var removedDuplicateNames = false;
    final uniqueDiaries = <_SavedDiary>[];
    for (final diary in diaries) {
      final normalizedName = _normalizeDiaryName(diary.name);
      final duplicateIndex = uniqueDiaries.indexWhere(
        (saved) => _normalizeDiaryName(saved.name) == normalizedName,
      );
      if (normalizedName.isEmpty || duplicateIndex < 0) {
        uniqueDiaries.add(diary);
        continue;
      }

      removedDuplicateNames = true;
      final existing = uniqueDiaries[duplicateIndex];
      final keepCurrent = diary.id == selectedId;
      final keeper = keepCurrent ? diary : existing;
      final other = keepCurrent ? existing : diary;
      uniqueDiaries[duplicateIndex] = _SavedDiary(
        id: keeper.id,
        name: keeper.name,
        entries: {...other.entries, ...keeper.entries},
        sourceLabel: keeper.sourceLabel ?? other.sourceLabel,
      );
    }

    final rawEntries = data?['draftEntries'];
    final validated = rawEntries is Map
        ? _validateMap(rawEntries)
        : _validateMap(const <String, String>{});
    final workspaceEntries = <String, String>{...validated.valid};
    if (removedDuplicateNames && selectedId != null) {
      final selectedDiary = uniqueDiaries.where(
        (diary) => diary.id == selectedId,
      );
      if (selectedDiary.isNotEmpty) {
        workspaceEntries
          ..clear()
          ..addAll(selectedDiary.first.entries)
          ..addAll(validated.valid);
      }
    }
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(_sortMap(workspaceEntries));
      _sourceLabel = data?['sourceLabel'] as String?;
      _savedDiaries = uniqueDiaries;
      _selectedDiaryId = uniqueDiaries.any((diary) => diary.id == selectedId)
          ? selectedId
          : null;
    });
    if (removedDuplicateNames) await _persist();
  }

  String _normalizeDiaryName(String name) =>
      _stripAccents(name).trim().replaceAll(RegExp(r'\s+'), ' ');

  bool _diaryNameExists(String name) {
    final normalized = _normalizeDiaryName(name);
    return normalized.isNotEmpty &&
        _savedDiaries.any(
          (diary) => _normalizeDiaryName(diary.name) == normalized,
        );
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedDiaryId != null) {
      final index = _savedDiaries.indexWhere(
        (diary) => diary.id == _selectedDiaryId,
      );
      if (index >= 0) {
        _savedDiaries[index] = _savedDiaries[index].copyWith(
          entries: _entries,
          sourceLabel: _sourceLabel,
        );
      }
    }
    await prefs.setString(
      _periodDataKey(_term),
      jsonEncode({
        'draftEntries': _entries,
        'sourceLabel': _sourceLabel,
        'selectedDiaryId': _selectedDiaryId,
        'savedDiaries': _savedDiaries.map((diary) => diary.toJson()).toList(),
      }),
    );
  }

  Future<void> _changeTerm(String? term) async {
    if (term == null || term == _term) return;
    await _persist();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeDiaryPeriodKey, term);
    setState(() => _term = term);
    await _loadPeriodWorkspace(term, prefs: prefs);
    _log('Periodo letivo alterado para ${AcademicTerm.displayName(term)}.');
  }

  Future<void> _createTerm() async {
    final value = await AcademicTermDialog.show(context);
    final name = value?.trim() ?? '';
    if (name.isEmpty) return;
    final existing =
        AcademicTerm.findEquivalent(_terms, name) ??
        _terms.cast<String?>().firstWhere(
          (term) => term?.toLowerCase() == name.toLowerCase(),
          orElse: () => null,
        );
    if (existing != null) {
      await _changeTerm(existing);
      return;
    }
    await _persist();
    final prefs = await SharedPreferences.getInstance();
    final updated = AcademicTerm.newestFirst([..._terms, name]);
    await prefs.setStringList(_diaryPeriodsKey, updated);
    await prefs.setString(_activeDiaryPeriodKey, name);
    setState(() {
      _terms = updated;
      _term = name;
      _entries.clear();
      _sourceLabel = null;
      _selectedDiaryId = null;
      _savedDiaries = [];
    });
    await _persist();
  }

  Future<void> _manageTerms() async {
    const createNew = '__create_new_academic_term__';
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Períodos letivos'),
        content: SizedBox(
          width: 440,
          height: 360,
          child: ListView.separated(
            itemCount: _terms.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = _terms[index];
              final active = item == _term;
              return ListTile(
                leading: Icon(
                  active ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: active ? AppTheme.primary : AppTheme.textSecondary,
                ),
                title: Text(AcademicTerm.displayName(item)),
                subtitle: active ? const Text('Em uso') : null,
                onTap: () => Navigator.pop(dialogContext, item),
              );
            },
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(dialogContext, createNew),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Novo período letivo'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    if (selected == null) return;
    if (selected == createNew) {
      await _createTerm();
    } else {
      await _changeTerm(selected);
    }
  }

  Future<void> _selectSavedDiary(String? id) async {
    if (id == null || id == _selectedDiaryId) return;
    await _persist();
    final diary = _savedDiaries.firstWhere((item) => item.id == id);
    setState(() {
      _selectedDiaryId = diary.id;
      _entries
        ..clear()
        ..addAll(_sortMap(diary.entries));
      _sourceLabel =
          diary.sourceLabel ??
          '${AcademicTerm.displayName(_term)} - ${diary.name}';
    });
    await _persist();
  }

  Future<void> _deleteSelectedDiary() async {
    final selectedId = _selectedDiaryId;
    if (selectedId == null) return;
    final index = _savedDiaries.indexWhere((diary) => diary.id == selectedId);
    if (index < 0) return;
    final diary = _savedDiaries[index];
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Remover disciplina?'),
            content: Text(
              'O diário "${diary.name}" e seus lançamentos serão removidos deste período.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Remover'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    final remainingDiaries = [..._savedDiaries]..removeAt(index);
    final nextDiary = remainingDiaries.isEmpty
        ? null
        : remainingDiaries[index < remainingDiaries.length ? index : 0];
    setState(() {
      _savedDiaries = remainingDiaries;
      _selectedDiaryId = nextDiary?.id;
      _entries
        ..clear()
        ..addAll(
          nextDiary == null ? const <String, String>{} : nextDiary.entries,
        );
      _sourceLabel = nextDiary == null
          ? null
          : nextDiary.sourceLabel ??
                '${AcademicTerm.displayName(_term)} - ${nextDiary.name}';
    });
    await _persist();
    _log(
      'Disciplina "${diary.name}" removida do período ${AcademicTerm.displayName(_term)}.',
    );
  }

  Future<void> _saveDiary({bool createNew = false}) async {
    if (_entries.isEmpty) return;
    if (!createNew && _selectedDiaryId != null) {
      await _persist();
      final name = _savedDiaries
          .firstWhere((diary) => diary.id == _selectedDiaryId)
          .name;
      _log('Diario salvo: $name.');
      return;
    }
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(createNew ? 'Salvar outro diario' : 'Salvar diario'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Disciplina / nome do diario',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmedName = name?.trim() ?? '';
    if (trimmedName.isEmpty) return;
    if (!mounted) return;
    if (_diaryNameExists(trimmedName)) {
      await _showMessage(
        'Disciplina j\u00e1 cadastrada',
        'J\u00e1 existe um di\u00e1rio chamado "$trimmedName" no per\u00edodo ${AcademicTerm.displayName(_term)}. Remova o existente ou escolha outro nome.',
      );
      return;
    }
    final diary = _SavedDiary(
      id: _uuid.v4(),
      name: trimmedName,
      entries: Map<String, String>.from(_entries),
      sourceLabel: _sourceLabel,
    );
    setState(() {
      _savedDiaries = [..._savedDiaries, diary];
      _selectedDiaryId = diary.id;
    });
    await _persist();
    _log(
      'Diario "$trimmedName" salvo no periodo ${AcademicTerm.displayName(_term)}.',
    );
  }

  Future<List<_SavedDiary>> _loadDiariesForTerm(String term) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_periodDataKey(term));
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['savedDiaries'] is! List) return [];
      return (decoded['savedDiaries'] as List)
          .whereType<Map>()
          .map((item) => _SavedDiary.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _copyDiary() async {
    await _persist();
    final sourceTerm = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Copiar diário de qual período?'),
        content: SizedBox(
          width: 440,
          height: 360,
          child: ListView.separated(
            itemCount: _terms.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final term = _terms[index];
              return ListTile(
                leading: const Icon(Icons.date_range_rounded),
                title: Text(AcademicTerm.displayName(term)),
                subtitle: term == _term ? const Text('Período atual') : null,
                onTap: () => Navigator.pop(dialogContext, term),
              );
            },
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
    if (sourceTerm == null) return;
    final sourceDiaries = await _loadDiariesForTerm(sourceTerm);
    if (!mounted) return;
    if (sourceDiaries.isEmpty) {
      await _showMessage(
        'Nenhum diário salvo',
        'Não há diários salvos no período $sourceTerm para copiar.',
      );
      return;
    }
    final sourceDiary = await showDialog<_SavedDiary>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Copiar de $sourceTerm'),
        content: SizedBox(
          width: 500,
          height: 400,
          child: ListView.separated(
            itemCount: sourceDiaries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final diary = sourceDiaries[index];
              return ListTile(
                leading: const Icon(Icons.menu_book_rounded),
                title: Text(diary.name),
                subtitle: Text('${diary.entries.length} aula(s)'),
                onTap: () => Navigator.pop(dialogContext, diary),
              );
            },
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
    if (sourceDiary == null || !mounted) return;

    final nameController = TextEditingController(text: sourceDiary.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Salvar cópia no período atual'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Disciplina / nome do novo diário',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, nameController.text),
            child: const Text('Copiar'),
          ),
        ],
      ),
    );
    nameController.dispose();
    final targetName = name?.trim() ?? '';
    if (targetName.isEmpty) return;
    if (!mounted) return;
    if (_diaryNameExists(targetName)) {
      await _showMessage(
        'Disciplina j\u00e1 cadastrada',
        'J\u00e1 existe um di\u00e1rio chamado "$targetName" no per\u00edodo ${AcademicTerm.displayName(_term)}. Remova o existente ou escolha outro nome.',
      );
      return;
    }

    final copy = _SavedDiary(
      id: _uuid.v4(),
      name: targetName,
      entries: Map<String, String>.from(sourceDiary.entries),
      sourceLabel: 'Cópia de $sourceTerm · ${sourceDiary.name}',
    );
    setState(() {
      _savedDiaries = [..._savedDiaries, copy];
      _selectedDiaryId = copy.id;
      _entries
        ..clear()
        ..addAll(_sortMap(copy.entries));
      _sourceLabel = copy.sourceLabel;
    });
    await _persist();
    _log(
      'Diário copiado para "$targetName" no período ${AcademicTerm.displayName(_term)}.',
    );
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add('${DateFormat('HH:mm:ss').format(DateTime.now())}  $message');
      if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
    });
  }

  Future<void> _copyOperationLog() async {
    if (_logs.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _logs.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Log copiado para a área de transferência.'),
      ),
    );
  }

  Future<void> _selectExcel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'xlsm', 'xltx', 'xltm'],
        withData: true,
        dialogTitle: 'Importar planilha do diário',
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null)
        throw StateError('Não foi possível ler o arquivo selecionado.');
      final workbook = Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty)
        throw const FormatException('O arquivo não contém abas legíveis.');
      String? sheetName = workbook.tables.keys.first;
      if (workbook.tables.length > 1) {
        sheetName = await _chooseSheet(workbook.tables.keys.toList());
      }
      if (sheetName == null || !mounted) return;
      final sheet = workbook.tables[sheetName];
      if (sheet == null)
        throw const FormatException('A aba selecionada não foi encontrada.');
      final resultMap = _parseWorksheet(sheet);
      if (resultMap.valid.isEmpty) {
        _showMessage(
          'Nenhum lançamento válido',
          'Não encontrei linhas com Data, Modalidade e Matéria Lecionada (ou Conteúdo). Confira os cabeçalhos e os dados da aba.',
        );
        _log('Planilha ${picked.name}: nenhum lançamento válido.');
        return;
      }
      final overwritten = resultMap.valid.keys
          .where(_entries.containsKey)
          .length;
      final mergedEntries = _sortMap({..._entries, ...resultMap.valid});
      setState(() {
        _entries
          ..clear()
          ..addAll(mergedEntries);
        _sourceLabel = 'Excel · ${picked.name} · $sheetName';
      });
      await _persist();
      _log(
        'Planilha importada: ${resultMap.valid.length} válido(s), ${resultMap.skipped} ignorado(s), ${resultMap.duplicates} repetido(s) na planilha e $overwritten sobrescrito(s) na mesclagem.',
      );
      if (resultMap.errors.isNotEmpty)
        _log('Chaves inválidas descartadas: ${resultMap.errors.length}.');
    } catch (error) {
      _showMessage('Falha na importação Excel', '$error');
      _log('Falha ao importar Excel: $error');
    }
  }

  Future<void> _importFromPortal() async {
    if (_importingPortalDiary) return;
    if (!_automation.isConnected) {
      await _showMessage(
        'Portal Docente desconectado',
        'Abra o formulário do diário no Edge antes de importar.',
      );
      return;
    }
    setState(() => _importingPortalDiary = true);
    try {
      final portalDiary = await _automation.readCurrentDiaryContents();
      final imported = _validateMap(portalDiary.entries);
      if (imported.valid.isEmpty) {
        throw const FormatException(
          'Não encontrei lançamentos válidos no diário aberto.',
        );
      }
      final overwritten = imported.valid.keys
          .where(_entries.containsKey)
          .length;
      final merged = _sortMap({..._entries, ...imported.valid});
      setState(() {
        _entries
          ..clear()
          ..addAll(merged);
        _sourceLabel = portalDiary.disciplineName == null
            ? 'Portal Docente · Diário aberto'
            : 'Portal Docente · ${portalDiary.disciplineName}';
      });
      await _persist();
      _log(
        'Diário importado do Portal Docente: ${imported.valid.length} lançamento(s), $overwritten sobrescrito(s), ${imported.errors.length} inválido(s).',
      );
      if (imported.errors.isNotEmpty) {
        _log('Chaves inválidas descartadas: ${imported.errors.length}.');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${imported.valid.length} lançamento(s) importado(s) do Portal Docente.',
            ),
          ),
        );
      }
    } catch (error) {
      _log('Falha ao importar do Portal Docente: $error');
      if (mounted) {
        await _showMessage('Falha ao importar do Portal Docente', '$error');
      }
    } finally {
      if (mounted) setState(() => _importingPortalDiary = false);
    }
  }

  Future<String?> _chooseSheet(List<String> names) async {
    String selected = names.first;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Escolher aba da planilha'),
          content: DropdownButtonFormField<String>(
            value: selected,
            items: names
                .map((name) => DropdownMenuItem(value: name, child: Text(name)))
                .toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selected = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const Text('Importar aba'),
            ),
          ],
        ),
      ),
    );
  }

  _ImportResult _parseWorksheet(Sheet sheet) {
    final rows = sheet.rows;
    final int? headerIndex = _findHeaderRow(rows);
    final header = headerIndex == null
        ? const {'data': 0, 'modality': 1, 'content': 3}
        : _columnMap(rows[headerIndex]);
    if (headerIndex == null)
      _log(
        'Cabeçalho não encontrado nas 10 primeiras linhas; tentando o formato original (colunas A, B e D).',
      );
    final imported = <String, String>{};
    final errors = <String, String>{};
    var skipped = 0;
    var duplicates = 0;
    for (
      var rowIndex = (headerIndex ?? 0) + 1;
      rowIndex < rows.length;
      rowIndex++
    ) {
      final row = rows[rowIndex];
      final date = _parseWorksheetDate(_cell(row, header['data']!), rows);
      final modality = _cellText(_cell(row, header['modality']!)).toLowerCase();
      final content = _cellText(_cell(row, header['content']!)).trim();
      final suffix = _stripAccents(modality).contains('teor')
          ? 'T'
          : _stripAccents(modality).contains('prat')
          ? 'P'
          : null;
      if (date == null || suffix == null || content.isEmpty) {
        if (modality.isNotEmpty || content.isNotEmpty) skipped++;
        continue;
      }
      final key = '${_formatDate(date)} -$suffix';
      if (imported.containsKey(key)) duplicates++;
      imported[key] = content;
    }
    final validated = _validateMap(imported);
    errors.addAll(validated.errors);
    return _ImportResult(validated.valid, errors, skipped, duplicates);
  }

  int? _findHeaderRow(List<List<Data?>> rows) {
    for (var i = 0; i < rows.length && i < 10; i++) {
      final map = _columnMap(rows[i]);
      if (map.containsKey('data') &&
          map.containsKey('modality') &&
          map.containsKey('content'))
        return i;
    }
    return null;
  }

  Map<String, int> _columnMap(List<Data?> row) {
    final map = <String, int>{};
    for (var i = 0; i < row.length; i++) {
      final text = _stripAccents(
        _cellText(row[i]).toLowerCase().trim(),
      ).replaceAll(RegExp(r'\s+'), ' ');
      if (text == 'data' || text == 'dia') map['data'] = i;
      if (text.startsWith('modalidade')) map['modality'] = i;
      if ({
        'materia lecionada',
        'materia',
        'conteudo',
        'conteudo lecionado',
        'descricao',
      }.contains(text))
        map['content'] = i;
    }
    return map;
  }

  Data? _cell(List<Data?> row, int column) =>
      column < row.length ? row[column] : null;

  String _cellText(Data? cell) {
    final value = cell?.value;
    if (value == null) return '';
    if (value is TextCellValue) return value.value.text ?? '';
    if (value is FormulaCellValue) return value.formula;
    return value.toString();
  }

  DateTime? _parseExcelDate(Data? cell) {
    final value = cell?.value;
    if (value is DateCellValue) return value.asDateTimeLocal();
    if (value is DateTimeCellValue) return value.asDateTimeLocal();
    if (value is IntCellValue)
      return DateTime(1899, 12, 30).add(Duration(days: value.value));
    if (value is DoubleCellValue)
      return DateTime(1899, 12, 30).add(Duration(days: value.value.floor()));
    final text = _cellText(cell).trim();
    final match = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(text);
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    final date = DateTime(year, month, day);
    return date.year == year && date.month == month && date.day == day
        ? date
        : null;
  }

  DateTime? _parseWorksheetDate(
    Data? cell,
    List<List<Data?>> rows, [
    Set<String>? references,
  ]) {
    final value = cell?.value;
    if (value is! FormulaCellValue) return _parseExcelDate(cell);

    final formula = value.formula
        .trim()
        .replaceFirst(RegExp(r'^='), '')
        .replaceAll(r'$', '')
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase();
    final match = RegExp(
      r'^([A-Z]{1,3})(\d+)(?:([+-])(\d+(?:\.\d+)?))?$',
    ).firstMatch(formula);
    if (match == null) return null;

    var column = 0;
    for (final character in match.group(1)!.codeUnits) {
      column = column * 26 + character - 64;
    }
    final rowIndex = int.parse(match.group(2)!) - 1;
    final columnIndex = column - 1;
    if (rowIndex < 0 || rowIndex >= rows.length || columnIndex < 0) {
      return null;
    }

    final address = '${match.group(1)}${match.group(2)}';
    final visited = references ?? <String>{};
    if (!visited.add(address)) return null;
    final referencedRows = rows[rowIndex];
    final baseDate = _parseWorksheetDate(
      _cell(referencedRows, columnIndex),
      rows,
      visited,
    );
    visited.remove(address);
    if (baseDate == null) return null;

    final offset = double.tryParse(match.group(4) ?? '0');
    if (offset == null) return null;
    final signedOffset = match.group(3) == '-' ? -offset : offset;
    return baseDate.add(
      Duration(
        microseconds: (signedOffset * Duration.microsecondsPerDay).round(),
      ),
    );
  }

  Future<void> _importJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
        dialogTitle: 'Carregar dados do diário (JSON)',
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) throw StateError('Não foi possível ler o arquivo.');
      final raw = jsonDecode(utf8.decode(bytes));
      final validated = _validateMap(raw);
      if (validated.valid.isEmpty && validated.errors.isNotEmpty)
        throw FormatException(
          validated.errors.entries
              .map((e) => '${e.key}: ${e.value}')
              .join('\n'),
        );
      setState(() {
        _entries
          ..clear()
          ..addAll(_sortMap(validated.valid));
        _sourceLabel = 'JSON · ${file.name}';
      });
      await _persist();
      _log(
        'JSON carregado: ${validated.valid.length} item(ns) válido(s), ${validated.errors.length} inválido(s).',
      );
      if (validated.errors.isNotEmpty)
        _showMessage(
          'Alguns registros foram ignorados',
          validated.errors.entries
              .take(12)
              .map((e) => '${e.key}: ${e.value}')
              .join('\n'),
        );
    } catch (error) {
      _showMessage('Falha ao carregar JSON', '$error');
      _log('Falha ao carregar JSON: $error');
    }
  }

  Future<void> _exportJson() async {
    if (_entries.isEmpty) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Salvar dados do diário',
      fileName: 'dados_diario.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (path == null) return;
    try {
      final filePath = path.toLowerCase().endsWith('.json')
          ? path
          : '$path.json';
      await File(filePath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(_entries),
        encoding: utf8,
      );
      _log('JSON exportado para $filePath.');
    } catch (error) {
      _showMessage('Falha ao salvar JSON', '$error');
    }
  }

  _ValidationResult _validateMap(dynamic raw) {
    if (raw is! Map)
      return const _ValidationResult({}, {
        '__root__':
            'O JSON precisa ser um objeto {"DD/MM/AAAA -P": "conteúdo"}.',
      });
    final valid = <String, String>{};
    final errors = <String, String>{};
    for (final entry in raw.entries) {
      final originalKey = '${entry.key}';
      if (entry.value is! String) {
        errors[originalKey] = 'O conteúdo precisa ser texto.';
        continue;
      }
      final normalized = _normalizeKey(originalKey);
      if (normalized == null) {
        errors[originalKey] =
            'Use uma data válida no formato DD/MM/AAAA -P (ou -T).';
      } else if (valid.containsKey(normalized)) {
        errors[originalKey] =
            'A chave duplicou após a normalização: $normalized.';
      } else {
        valid[normalized] = entry.value as String;
      }
    }
    return _ValidationResult(valid, errors);
  }

  String? _normalizeKey(String key) {
    final normalized = key
        .replaceAll(RegExp('[\\u2013\\u2014\\u2212]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final match = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{2,4})(?:\s*-\s*(.*))?$',
    ).firstMatch(normalized);
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    var year = int.parse(match.group(3)!);
    if (year < 100) year += 2000;
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day)
      return null;
    final suffix = (match.group(4) ?? '').trim();
    return '${_formatDate(date)} -${suffix.isEmpty ? 'P' : suffix}';
  }

  String _stripAccents(String value) => repairMojibake(value)
      .toLowerCase()
      .replaceAll(RegExp(r'[\u00e1\u00e0\u00e2\u00e3\u00e4]'), 'a')
      .replaceAll(RegExp(r'[\u00e9\u00e8\u00ea\u00eb]'), 'e')
      .replaceAll(RegExp(r'[\u00ed\u00ec\u00ee\u00ef]'), 'i')
      .replaceAll(RegExp(r'[\u00f3\u00f2\u00f4\u00f5\u00f6]'), 'o')
      .replaceAll(RegExp(r'[\u00fa\u00f9\u00fb\u00fc]'), 'u')
      .replaceAll('\u00e7', 'c');

  String? _lessonModality(ActivityEntry activity) {
    final normalizedName = _stripAccents(activity.name);
    final normalizedModality = _stripAccents(activity.modality ?? '');
    if (normalizedModality.contains('teor') ||
        RegExp(r'^\s*(?:aula\s+)?teor').hasMatch(normalizedName)) {
      return 'T';
    }
    if (normalizedModality.contains('prat') ||
        RegExp(r'^\s*(?:aula\s+)?prat').hasMatch(normalizedName)) {
      return 'P';
    }
    return null;
  }

  DateTime? _lessonDate(
    ActivityEntry activity,
    SectionEntry section,
    CourseConfig config,
  ) {
    final resolvedName = MacroResolver.resolve(
      activity.name,
      config.semesterStartDate,
      section.date,
      activity.computeOpenDate(section.date),
      activity.computeCloseDate(section.date),
    );
    final dateMatch = RegExp(
      r'realizar-se-a\s*:\s*(\d{1,2}/\d{1,2}/\d{4})',
      caseSensitive: false,
    ).firstMatch(_stripAccents(resolvedName));
    if (dateMatch != null) {
      final parts = dateMatch.group(1)!.split('/').map(int.parse).toList();
      final date = DateTime(parts[2], parts[1], parts[0]);
      if (date.year == parts[2] &&
          date.month == parts[1] &&
          date.day == parts[0]) {
        return date;
      }
    }

    final weekdayMatch = RegExp(
      r'\b(segunda|terca|quarta|quinta|sexta|sabado|domingo)(?:-feira)?\b',
    ).firstMatch(_stripAccents(activity.name));
    final weekday = weekdayMatch == null
        ? activity.expectedWeekday
        : const {
            'segunda': DateTime.monday,
            'terca': DateTime.tuesday,
            'quarta': DateTime.wednesday,
            'quinta': DateTime.thursday,
            'sexta': DateTime.friday,
            'sabado': DateTime.saturday,
            'domingo': DateTime.sunday,
          }[weekdayMatch.group(1)];
    if (weekday == null ||
        weekday < DateTime.monday ||
        weekday > DateTime.sunday) {
      return null;
    }
    final offset = (weekday - section.date.weekday + 7) % 7;
    return DateTime(
      section.date.year,
      section.date.month,
      section.date.day,
    ).add(Duration(days: offset));
  }

  String _lessonDescription(String name) {
    var description = repairMojibake(name.trim());
    description = description.replaceFirst(
      RegExp(r'\s*\([^)]*realizar-se-.[^)]*\)\.?\s*$', caseSensitive: false),
      '',
    );
    description = description.replaceFirst(
      RegExp(
        r'\s*[-\u2013\u2014]?\s*realizar-se-.\s*:.*$',
        caseSensitive: false,
      ),
      '',
    );
    final separator = description.indexOf(':');
    if (separator >= 0) description = description.substring(separator + 1);
    return description
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.\s]+$'), '')
        .trim();
  }

  String _formatDate(DateTime date) => DateFormat('dd/MM/yyyy').format(date);

  Map<String, String> _sortMap(Map<String, String> map) {
    final entries = map.entries.toList()
      ..sort((a, b) {
        final aDate = _dateFromKey(a.key);
        final bDate = _dateFromKey(b.key);
        if (aDate == null) return bDate == null ? a.key.compareTo(b.key) : 1;
        if (bDate == null) return -1;
        final cmp = aDate.compareTo(bDate);
        return cmp == 0 ? a.key.compareTo(b.key) : cmp;
      });
    return Map.fromEntries(entries);
  }

  DateTime? _dateFromKey(String key) {
    final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})\s*-').firstMatch(key);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(3)!),
      int.parse(match.group(2)!),
      int.parse(match.group(1)!),
    );
  }

  DateTime? _parseDateInput(String value) {
    try {
      return DateFormat('dd/MM/yyyy').parseStrict(value.trim());
    } on FormatException {
      return null;
    }
  }

  Future<void> _useMoodleConfig(
    CourseConfig config, {
    String? sourceLabel,
  }) async {
    final generated = <String, String>{};
    for (final section in config.sections.where((item) => item.visible)) {
      for (final activity in section.activities.where(
        (item) => item.visibility != 0,
      )) {
        final normalizedName = _stripAccents(activity.name);
        // Moodle sections are weekly folders; only explicitly scheduled class activities become diary rows.
        if (!normalizedName.contains('realizar-se-a')) continue;
        final modality = _lessonModality(activity);
        final date = _lessonDate(activity, section, config);
        final description = _lessonDescription(activity.name);
        if (modality == null || date == null || description.isEmpty) continue;

        final key = '${_formatDate(date)} -$modality';
        final previous = generated[key];
        generated[key] = previous == null
            ? description
            : '$previous\n$description';
      }
    }
    if (generated.isEmpty) {
      await _showMessage(
        'Nenhuma aula encontrada',
        'N\u00e3o encontrei aulas com modalidade Te\u00f3rica/Pr\u00e1tica e data "Realizar-se-\u00e1" no cronograma desta disciplina. Os blocos semanais n\u00e3o s\u00e3o importados como aulas.',
      );
      return;
    }
    final ordered = _sortMap(generated);
    final overwrite = _entries.isEmpty
        ? true
        : await _askReplaceOrMerge(config.name, ordered.length);
    if (overwrite == null) return;
    setState(() {
      if (overwrite) _entries.clear();
      _entries.addAll(ordered);
      final sorted = _sortMap(_entries);
      _entries
        ..clear()
        ..addAll(sorted);
      _sourceLabel = '${sourceLabel ?? 'Config Moodle'} \u00b7 ${config.name}';
    });
    await _persist();
    _log(
      'Aulas importadas: ${ordered.length} lan\u00e7amento(s), ${overwrite ? 'substituindo' : 'mesclando'} os dados anteriores.',
    );
  }

  Future<void> _importFromSavedConfig() async {
    final configs = context.read<ConfigController>().configs;
    if (configs.isEmpty) {
      await _showMessage(
        'Nenhuma configuração disponível',
        'Crie ou importe uma disciplina em Config Moodle para usá-la aqui.',
      );
      return;
    }
    final config = await showDialog<CourseConfig>(
      context: context,
      builder: (_) => _SavedMoodleConfigDialog(configs: configs),
    );
    if (config == null || !mounted) return;
    await _useMoodleConfig(config, sourceLabel: 'Config Moodle');
  }

  Future<void> _importFromLiveMoodle() async {
    final auth = context.read<AuthController>();
    if (!auth.isLoggedIn) {
      final loggedIn = await _showMoodleLoginDialog();
      if (!loggedIn || !mounted) return;
    }

    setState(() => _loadingMoodleCourses = true);
    final sync = context.read<SyncController>();
    try {
      await sync.loadCourses(auth.token, auth.baseUrl);
      if (!mounted) return;
      if (sync.error != null) {
        await _showMessage('Falha ao consultar Moodle', sync.error!);
        return;
      }
      if (sync.courses.isEmpty) {
        await _showMessage(
          'Nenhuma disciplina encontrada',
          'A conta conectada não possui disciplinas disponíveis no Moodle.',
        );
        return;
      }

      final course = await showDialog<MoodleCourse>(
        context: context,
        builder: (dialogContext) =>
            _MoodleDiaryCourseDialog(courses: sync.courses),
      );
      if (course == null || !mounted) return;

      final configs = context.read<ConfigController>().configs;
      final matching = configs.where(
        (item) => item.moodleCourseId == course.id,
      );
      final semesterStart =
          course.startDate ??
          (matching.isNotEmpty ? matching.first.semesterStartDate : null);
      if (semesterStart == null) {
        await _showMessage(
          'Data de início não encontrada',
          'O Moodle não retornou a data de início desta disciplina e não existe uma configuração local correspondente. Configure a data de início do curso no Moodle e tente novamente.',
        );
        return;
      }

      final config = await sync.buildConfigFromMoodle(
        auth.token,
        auth.baseUrl,
        course,
        semesterStart,
      );
      if (!mounted) return;
      setState(() => _loadingMoodleCourses = false);
      await _useMoodleConfig(config, sourceLabel: 'Moodle ao vivo');
    } catch (error) {
      if (mounted) {
        await _showMessage('Falha ao importar do Moodle', '$error');
      }
    } finally {
      if (mounted) setState(() => _loadingMoodleCourses = false);
    }
  }

  Future<bool> _showMoodleLoginDialog() async {
    final auth = context.read<AuthController>();
    await auth.init();
    if (!mounted) return false;
    final savedCredential = auth.credential;
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return false;
    final url = TextEditingController(
      text:
          prefs.getString('last_moodle_url') ??
          savedCredential?.moodleUrl ??
          'https://moodle.ufu.br',
    );
    final username = TextEditingController(
      text: savedCredential?.username ?? '',
    );
    final password = TextEditingController(
      text: savedCredential?.password ?? '',
    );
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Conectar ao Moodle'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  onChanged: (value) =>
                      prefs.setString('last_moodle_url', value.trim()),
                  decoration: const InputDecoration(
                    labelText: 'Endereço do Moodle',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: 'Usuário'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Senha'),
                  onSubmitted: (_) async {
                    final ok = await auth.login(
                      url.text.trim(),
                      username.text.trim(),
                      password.text,
                    );
                    if (ok && dialogContext.mounted)
                      Navigator.pop(dialogContext, true);
                    setDialogState(() {});
                  },
                ),
                if (auth.error != null) ...[
                  const SizedBox(height: 8),
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
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: auth.loading
                  ? null
                  : () async {
                      final ok = await auth.login(
                        url.text.trim(),
                        username.text.trim(),
                        password.text,
                      );
                      if (ok) {
                        await prefs.setString(
                          'last_moodle_url',
                          url.text.trim(),
                        );
                        if (dialogContext.mounted)
                          Navigator.pop(dialogContext, true);
                      } else {
                        setDialogState(() {});
                      }
                    },
              child: auth.loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Entrar'),
            ),
          ],
        ),
      ),
    );
    url.dispose();
    username.dispose();
    password.dispose();
    return result == true;
  }

  Future<bool?> _askReplaceOrMerge(
    String configName,
    int count,
  ) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Como aplicar os dados?'),
      content: Text(
        'A configuração "$configName" contém $count lançamento(s). Mesclar mantém os itens atuais e substitui chaves iguais. Substituir remove a lista atual antes da importação.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Mesclar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Substituir'),
        ),
      ],
    ),
  );

  Future<void> _addOrEdit({String? oldKey}) async {
    final dateController = TextEditingController(
      text: oldKey == null
          ? _formatDate(DateTime.now())
          : oldKey.substring(0, 10),
    );
    final textController = TextEditingController(
      text: oldKey == null ? '' : _entries[oldKey] ?? '',
    );
    var modality = oldKey?.toUpperCase().endsWith('-T') == true ? 'T' : 'P';
    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(oldKey == null ? 'Adicionar aula' : 'Editar aula'),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: dateController,
                        keyboardType: TextInputType.datetime,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Data da aula',
                          prefixIcon: Icon(Icons.calendar_month_rounded),
                          hintText: 'DD/MM/AAAA',
                          suffixIcon: IconButton(
                            tooltip: 'Escolher no calendário',
                            icon: const Icon(Icons.edit_calendar_rounded),
                            onPressed: () async {
                              final selected = await showDatePicker(
                                context: context,
                                initialDate:
                                    _parseDate(dateController.text) ??
                                    DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (selected != null) {
                                dateController.text = _formatDate(selected);
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: modality,
                        decoration: const InputDecoration(
                          labelText: 'Modalidade',
                        ),
                        items: const [
                          DropdownMenuItem(value: 'T', child: Text('Teórica')),
                          DropdownMenuItem(value: 'P', child: Text('Prática')),
                        ],
                        onChanged: (value) {
                          if (value != null)
                            setDialogState(() => modality = value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: textController,
                  minLines: 4,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    labelText: 'Descrição da aula',
                    alignLabelWithHint: true,
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
              onPressed: () => Navigator.pop(dialogContext, (
                dateController.text,
                modality,
                textController.text,
              )),
              child: const Text('Salvar aula'),
            ),
          ],
        ),
      ),
    );
    dateController.dispose();
    textController.dispose();
    if (result == null) return;
    final date = _parseDate(result.$1);
    final normalized = date == null
        ? null
        : '${_formatDate(date)} -${result.$2}';
    if (normalized == null) {
      _showMessage('Data inválida', 'Escolha uma data válida para a aula.');
      return;
    }
    if (normalized != oldKey && _entries.containsKey(normalized)) {
      _showMessage('Aula duplicada', 'Já existe uma aula em $normalized.');
      return;
    }
    setState(() {
      if (oldKey != null) _entries.remove(oldKey);
      _entries[normalized] = result.$3;
      final sorted = _sortMap(_entries);
      _entries
        ..clear()
        ..addAll(sorted);
    });
    await _persist();
    _log(
      oldKey == null
          ? 'Aula adicionada: $normalized.'
          : 'Aula atualizada: $normalized.',
    );
  }

  DateTime? _parseDate(String value) {
    final parts = value.trim().split('/');
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return null;
    final date = DateTime(year, month, day);
    return date.day == day && date.month == month && date.year == year
        ? date
        : null;
  }

  Future<void> _findMissingPortalDates() async {
    if (_searchingPortalDates || !_browserReady) return;
    setState(() => _searchingPortalDates = true);
    try {
      final portalDates = await _automation.findPortalDiaryDates();
      final known = _entries.keys
          .map(_normalizeKey)
          .whereType<String>()
          .toSet();
      final missing =
          portalDates
              .map(_normalizeKey)
              .whereType<String>()
              .where((date) => !known.contains(date))
              .toSet()
              .toList()
            ..sort((a, b) {
              final aDate = _dateFromKey(a);
              final bDate = _dateFromKey(b);
              return aDate == null || bDate == null
                  ? a.compareTo(b)
                  : aDate.compareTo(bDate);
            });
      setState(() => _missingPortalDates = missing);
      if (missing.isEmpty) {
        _log('Busca concluída: nenhuma data ausente da lista atual.');
      } else {
        _log('Datas encontradas no portal que não estão na lista atual:');
        for (final date in missing) {
          _log(date);
        }
      }
    } catch (error) {
      _log('Não foi possível buscar datas no portal: $error');
    } finally {
      if (mounted) setState(() => _searchingPortalDates = false);
    }
  }

  Future<void> _copyMissingPortalDates() async {
    if (_missingPortalDates.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: _missingPortalDates.join('\n')),
    );
    _log('Datas ausentes copiadas para a área de transferência.');
  }

  Future<void> _clearEntries() async {
    if (_entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Limpar lançamentos?'),
        content: Text(
          'Serão removidos ${_entries.length} lançamento(s) do diário.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _entries.clear();
      _sourceLabel = null;
      _selectedSnapshotId = null;
    });
    await _persist();
    _log('Lançamentos do diário limpos.');
  }

  Future<void> _remove(String key) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover lançamento?'),
        content: Text('A entrada $key será removida.'),
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
    if (yes != true) return;
    setState(() => _entries.remove(key));
    await _persist();
    _log('Lançamento removido: $key.');
  }

  Future<void> _shiftDates({String? entryKey}) async {
    if (_entries.isEmpty) return;
    final amountController = TextEditingController(text: '1');
    final initialDate = entryKey == null ? null : _dateFromKey(entryKey);
    final originalDateController = TextEditingController(
      text: initialDate == null ? '' : _formatDate(initialDate),
    );
    final targetDateController = TextEditingController(
      text: initialDate == null ? '' : _formatDate(initialDate),
    );
    var shiftMode = entryKey == null ? 'amount' : 'targetDate';
    var unit = 'Dias';
    final initialModality = entryKey?.toUpperCase().contains('-P') == true
        ? 'practical'
        : entryKey == null
        ? 'all'
        : 'theoretical';
    var filter = initialModality;
    DateTime? startDate = initialDate;
    DateTime? targetDate = initialDate;
    final selectedKeys = <String>{};
    final params = await showDialog<(String, int, String, DateTime?, Set<String>)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final calculatedOffset = startDate == null || targetDate == null
              ? null
              : DateUtils.dateOnly(
                  targetDate!,
                ).difference(DateUtils.dateOnly(startDate!)).inDays;
          return AlertDialog(
            title: const Text('Ajustar datas'),
            content: SizedBox(
              width: 430,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: shiftMode,
                    decoration: const InputDecoration(
                      labelText: 'Como definir a mudança',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'amount',
                        child: Text('Informar quantidade'),
                      ),
                      DropdownMenuItem(
                        value: 'targetDate',
                        child: Text('Escolher nova data'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => shiftMode = v);
                    },
                  ),
                  if (shiftMode == 'amount') ...[
                    DropdownButtonFormField<String>(
                      value: unit,
                      decoration: const InputDecoration(labelText: 'Unidade'),
                      items: const ['Dias', 'Meses', 'Anos']
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setDialogState(() => unit = v);
                      },
                    ),
                    TextField(
                      controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Quantidade (pode ser negativa)',
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: originalDateController,
                      keyboardType: TextInputType.datetime,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                        LengthLimitingTextInputFormatter(10),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Data original (dd/MM/aaaa)',
                        suffixIcon: IconButton(
                          tooltip: 'Escolher data original no calendário',
                          icon: const Icon(Icons.calendar_month_rounded),
                          onPressed: () async {
                            final selected = await showDatePicker(
                              context: context,
                              initialDate: startDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (selected != null) {
                              setDialogState(() {
                                startDate = selected;
                                originalDateController.text = _formatDate(
                                  selected,
                                );
                              });
                            }
                          },
                        ),
                      ),
                      onChanged: (value) => setDialogState(
                        () => startDate = _parseDateInput(value),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: targetDateController,
                      keyboardType: TextInputType.datetime,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                        LengthLimitingTextInputFormatter(10),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Nova data (dd/MM/aaaa)',
                        suffixIcon: IconButton(
                          tooltip: 'Escolher nova data no calendário',
                          icon: const Icon(Icons.event_available_rounded),
                          onPressed: () async {
                            final selected = await showDatePicker(
                              context: context,
                              initialDate:
                                  targetDate ?? startDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (selected != null) {
                              setDialogState(() {
                                targetDate = selected;
                                targetDateController.text = _formatDate(
                                  selected,
                                );
                              });
                            }
                          },
                        ),
                      ),
                      onChanged: (value) => setDialogState(
                        () => targetDate = _parseDateInput(value),
                      ),
                    ),
                    Text(
                      calculatedOffset == null
                          ? 'Selecione as duas datas para calcular o deslocamento.'
                          : 'Deslocamento calculado: ${calculatedOffset > 0 ? '+' : ''}$calculatedOffset dias',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                  DropdownButtonFormField<String>(
                    value: filter,
                    decoration: const InputDecoration(labelText: 'Aplicar em'),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('Todas')),
                      DropdownMenuItem(
                        value: 'theoretical',
                        child: Text('S\u00f3 T (Te\u00f3ricas)'),
                      ),
                      DropdownMenuItem(
                        value: 'practical',
                        child: Text('S\u00f3 P (Pr\u00e1ticas)'),
                      ),
                      DropdownMenuItem(
                        value: 'selected',
                        child: Text('Selecionadas'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => filter = v);
                    },
                  ),
                  if (filter == 'selected') ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text('${selectedKeys.length} selecionada(s)'),
                        ),
                        TextButton(
                          onPressed: () => setDialogState(
                            () => selectedKeys.addAll(_entries.keys),
                          ),
                          child: const Text('Todas'),
                        ),
                        TextButton(
                          onPressed: () => setDialogState(selectedKeys.clear),
                          child: const Text('Limpar'),
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 190,
                      child: ListView(
                        children: _sortMap(_entries).entries.map((entry) {
                          final isPractical = entry.key.toUpperCase().contains(
                            '-P',
                          );
                          return Material(
                            color: Colors.transparent,
                            child: CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              value: selectedKeys.contains(entry.key),
                              title: Text(entry.key),
                              subtitle: Text(
                                entry.value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              secondary: Text(isPractical ? 'P' : 'T'),
                              onChanged: (checked) => setDialogState(() {
                                if (checked == true) {
                                  selectedKeys.add(entry.key);
                                } else {
                                  selectedKeys.remove(entry.key);
                                }
                              }),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                  if (shiftMode == 'amount') ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            startDate == null
                                ? 'A partir do início'
                                : 'A partir de: ${_formatDate(startDate!)}',
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final dates = _entries.keys
                                .map(_dateFromKey)
                                .whereType<DateTime>()
                                .toList();
                            final selected = await showDatePicker(
                              context: context,
                              initialDate:
                                  startDate ??
                                  (dates.isEmpty
                                      ? DateTime.now()
                                      : dates.reduce(
                                          (a, b) => a.isBefore(b) ? a : b,
                                        )),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (selected != null) {
                              setDialogState(() => startDate = selected);
                            }
                          },
                          icon: const Icon(Icons.calendar_month_rounded),
                          label: const Text('Escolher'),
                        ),
                        if (startDate != null)
                          IconButton(
                            tooltip: 'Remover data inicial',
                            onPressed: () =>
                                setDialogState(() => startDate = null),
                            icon: const Icon(Icons.close_rounded),
                          ),
                      ],
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
              FilledButton(
                onPressed: shiftMode == 'targetDate' && calculatedOffset == null
                    ? null
                    : () {
                        final amount = shiftMode == 'targetDate'
                            ? calculatedOffset
                            : int.tryParse(amountController.text);
                        if (amount != null) {
                          Navigator.pop(context, (
                            shiftMode == 'targetDate' ? 'Dias' : unit,
                            amount,
                            filter,
                            startDate,
                            selectedKeys,
                          ));
                        }
                      },
                child: const Text('Aplicar'),
              ),
            ],
          );
        },
      ),
    );
    amountController.dispose();
    originalDateController.dispose();
    targetDateController.dispose();
    if (params == null) return;
    final result = _shiftMap(
      _entries,
      params.$1,
      params.$2,
      params.$3,
      params.$4,
      params.$5,
    );
    setState(() {
      _entries
        ..clear()
        ..addAll(result.entries);
    });
    await _persist();
    _log(
      'Datas ajustadas: ${result.changed} alterada(s), ${result.filtered} filtrada(s), ${result.overwritten} mesclada(s).',
    );
  }

  _ShiftResult _shiftMap(
    Map<String, String> map,
    String unit,
    int amount,
    String filter,
    DateTime? startDate,
    Set<String> selectedKeys,
  ) {
    final output = <String, String>{};
    var changed = 0;
    var filtered = 0;
    var overwritten = 0;
    for (final entry in map.entries) {
      final date = _dateFromKey(entry.key);
      final suffixMatch = RegExp(r'\s*-\s*(.+)$').firstMatch(entry.key);
      if (date == null || suffixMatch == null) {
        output[entry.key] = entry.value;
        continue;
      }
      final suffix = suffixMatch.group(1)!.trim();
      final first = suffix.isEmpty ? '' : suffix[0].toUpperCase();
      final beforeStartDate =
          startDate != null &&
          DateUtils.dateOnly(date).isBefore(DateUtils.dateOnly(startDate));
      final excludedBySelection =
          filter == 'selected' && !selectedKeys.contains(entry.key);
      if (beforeStartDate ||
          excludedBySelection ||
          (filter == 'theoretical' && first != 'T') ||
          (filter == 'practical' && first != 'P')) {
        output[entry.key] = entry.value;
        filtered++;
        continue;
      }
      DateTime target;
      if (unit == 'Dias') {
        target = date.add(Duration(days: amount));
      } else if (unit == 'Meses') {
        final monthIndex = date.year * 12 + date.month - 1 + amount;
        final year = monthIndex ~/ 12;
        final month = monthIndex % 12 + 1;
        target = DateTime(
          year,
          month,
          date.day.clamp(1, DateUtils.getDaysInMonth(year, month)),
        );
      } else {
        final year = date.year + amount;
        target = DateTime(
          year,
          date.month,
          date.day.clamp(1, DateUtils.getDaysInMonth(year, date.month)),
        );
      }
      final key = '${_formatDate(target)} -$suffix';
      if (output.containsKey(key)) overwritten++;
      output[key] = entry.value;
      changed++;
    }
    return _ShiftResult(_sortMap(output), changed, filtered, overwritten);
  }

  Future<void> _openBrowser() async {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(
        () => _error =
            'Informe um endereço válido, iniciado por http:// ou https://.',
      );
      return;
    }
    setState(() {
      _error = null;
      _openingBrowser = true;
      _browserReady = false;
    });
    await _saveAddress(_portalAddressKey, uri.toString());
    _log(
      'Abrindo o Edge. Faça login manualmente e entre na turma e no diário desejados.',
    );
    try {
      final openedUrl = await _automation.openBrowser(
        uri.toString(),
        username: kDebugMode && diaryAutomationDebugEnabled
            ? null
            : _portalUsername,
        password: kDebugMode && diaryAutomationDebugEnabled
            ? null
            : _portalPassword,
        log: _log,
      );
      if (!mounted) return;
      setState(() {
        _openingBrowser = false;
        _browserReady = true;
      });
      _log('Edge/Puppeteer aberto em $openedUrl. Faça login manualmente.');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _openingBrowser = false;
        _error = '$error';
      });
      _log('Falha ao iniciar o Edge com Puppeteer/Dart: $error');
    }
  }

  Future<void> _fillPortal() async {
    if (!_browserReady || !_automation.isConnected || _entries.isEmpty) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar preenchimento'),
        content: Text(
          'O Gestor UFU vai preencher ${_entries.length} campo(s) no formulário atualmente aberto no Edge. Confira a turma, o diário e o conteúdo antes de continuar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Preencher diário'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    if (!mounted) return;
    setState(() => _filling = true);
    try {
      _log('Iniciando Puppeteer para ${_entries.length} lançamento(s).');
      final result = await _automation.fillEntries(
        _sortMap(_entries),
        requireEmpty: _requireEmpty,
        highlight: _highlight,
        log: _log,
      );
      _log(
        'Concluído: ${result.filled} preenchido(s), ${result.notFound} não localizado(s), ${result.skipped} preservado(s).',
      );
    } catch (error) {
      _log('Falha no preenchimento: $error');
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  Future<void> _clearPortalDiary() async {
    if (!_browserReady || !_automation.isConnected || _filling) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Limpar di\u00e1rio no Portal?'),
        content: const Text(
          'O Portal remove espa\u00e7os comuns ao salvar e restaura o conte\u00fado anterior. Para deix\u00e1-lo visualmente em branco, o Gestor vai inserir um caractere de largura zero (U+200B). Esse marcador invis\u00edvel ficar\u00e1 armazenado no Portal. A p\u00e1gina n\u00e3o ser\u00e1 recarregada; confira e clique em Salvar no Portal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Limpar com marcador invis\u00edvel'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _filling = true);
    try {
      _log('Varrendo as datas do di\u00e1rio aberto no Portal.');
      final result = await _automation.clearDiaryFields(log: _log);
      _log(
        'Campos visualmente limpos: ${result.marked} marcador(es) invis\u00edvel(is) inserido(s), ${result.notFound} n\u00e3o localizado(s). Confira e clique em Salvar no Portal para gravar.',
      );
    } catch (error) {
      _log('Falha ao limpar o di\u00e1rio no Portal: $error');
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _filling = false);
    }
  }

  Future<void> _extractPortalDiaries() async {
    if (_extractingDiaries) return;
    setState(() {
      _extractingDiaries = true;
      _error = null;
    });
    try {
      const archiveUrl = 'https://www.portaldocente.ufu.br/diarioEletronico';
      _urlController.text = archiveUrl;
      await _saveAddress(_portalAddressKey, archiveUrl);
      _log('Abrindo Diário Eletrônico para ler a coluna Baixar.');
      final openedUrl = await _automation.openBrowser(
        archiveUrl,
        username: kDebugMode && diaryAutomationDebugEnabled
            ? null
            : _portalUsername,
        password: kDebugMode && diaryAutomationDebugEnabled
            ? null
            : _portalPassword,
        log: _log,
      );
      if (!mounted) return;
      setState(() => _browserReady = true);
      final host = Uri.tryParse(openedUrl)?.host.toLowerCase() ?? '';
      if (host != 'www.portaldocente.ufu.br' &&
          host != 'portaldocente.ufu.br') {
        _log(
          'O Portal redirecionou para autenticação. Entre no Portal no Edge e clique em Extrair diários novamente.',
        );
        return;
      }

      final available = await _automation.findPortalDiaryDownloads();
      final terms = AcademicTerm.newestFirst(
        available
            .map((diary) => diary.term)
            .where((term) => AcademicTerm.parse(term) != null),
      );
      if (terms.isEmpty) {
        throw StateError('A tabela não contém períodos reconhecíveis.');
      }
      final selection = await _showDiaryDownloadRange(terms, available);
      if (selection == null || !mounted) return;
      final directoryPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Escolha a pasta para salvar os diários originais',
      );
      if (directoryPath == null || !mounted) return;

      final startOrder = _academicTermOrder(selection.$1);
      final endOrder = selection.$2 == null
          ? _academicTermOrder(terms.first)
          : _academicTermOrder(selection.$2!);
      final selectedDiaries = available.where((diary) {
        final order = _academicTermOrder(diary.term);
        return order >= startOrder && order <= endOrder;
      }).toList();
      if (selectedDiaries.isEmpty) {
        throw StateError('Não há diários na faixa de períodos escolhida.');
      }
      _log(
        '${selectedDiaries.length} diário(s) selecionado(s), dos períodos ${selection.$1} a ${selection.$2 ?? terms.first}.',
      );
      final result = await _automation.downloadPortalDiaries(
        selectedDiaries,
        directoryPath,
        log: _log,
      );
      _log(
        'Extração concluída: ${result.downloaded} arquivo(s) salvo(s), ${result.failed} falha(s). Pasta: ${result.directoryPath}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.downloaded} diário(s) salvo(s) em ${result.directoryPath}.',
            ),
          ),
        );
      }
    } catch (error) {
      _log('Falha ao extrair diários do Portal: $error');
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _extractingDiaries = false);
    }
  }

  Future<void> _scanPortalDiaries() async {
    if (_scanningDiaries || _extractingDiaries || _filling) return;
    setState(() {
      _scanningDiaries = true;
      _error = null;
      _logs.clear();
    });
    try {
      const archiveUrl = 'https://www.portaldocente.ufu.br/diarioEletronico';
      _log(
        'Abrindo a lista do Portal para verificar preenchimento dos diários.',
      );
      final openedUrl = await _automation.openBrowser(
        archiveUrl,
        username: kDebugMode && diaryAutomationDebugEnabled
            ? null
            : _portalUsername,
        password: kDebugMode && diaryAutomationDebugEnabled
            ? null
            : _portalPassword,
        log: _log,
      );
      if (!mounted) return;
      setState(() => _browserReady = true);
      final host = Uri.tryParse(openedUrl)?.host.toLowerCase() ?? '';
      if (host != 'www.portaldocente.ufu.br' &&
          host != 'portaldocente.ufu.br') {
        _log(
          'O Portal redirecionou para autenticação. Entre no Portal no Edge e inicie a verificação novamente.',
        );
        return;
      }

      final available = await _automation.findPortalDiaryDownloads();
      final terms = AcademicTerm.newestFirst(
        available
            .map((diary) => diary.term)
            .where((term) => AcademicTerm.parse(term) != null),
      );
      if (terms.isEmpty) {
        throw StateError(
          'A lista do Portal não contém períodos reconhecíveis.',
        );
      }
      final selection = await _showDiaryScanRange(terms, available);
      if (selection == null || !mounted) return;
      final startOrder = _academicTermOrder(selection.$1);
      final endTerm = selection.$2 ?? terms.first;
      final endOrder = _academicTermOrder(endTerm);
      final selectedDiaries = available.where((diary) {
        final order = _academicTermOrder(diary.term);
        return order >= startOrder && order <= endOrder;
      }).toList();
      if (selectedDiaries.isEmpty) {
        throw StateError('Não há diários na faixa de períodos escolhida.');
      }

      _log(
        'Iniciando verificação de ${selectedDiaries.length} diário(s), de ${selection.$1} a $endTerm. Qualquer campo em branco será marcado como sem preenchimento.',
      );
      final result = await _automation.scanPortalDiariesForEmptyContent(
        selectedDiaries,
        log: _log,
      );
      _log(
        'Verificação concluída: ${result.checked} conferido(s), ${result.incomplete} com campo(s) sem preenchimento, ${result.failed} não verificado(s).',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.incomplete} diário(s) com campo(s) sem preenchimento; veja o log.',
            ),
          ),
        );
      }
    } catch (error) {
      _log('Falha ao verificar os diários do Portal: $error');
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _scanningDiaries = false);
    }
  }

  Future<(String, String?)?> _showDiaryScanRange(
    List<String> terms,
    List<PortalDiaryDownload> diaries,
  ) {
    var startTerm = terms.last;
    String? endTerm;
    return showDialog<(String, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final startOrder = _academicTermOrder(startTerm);
          final endChoices = terms
              .where((term) => _academicTermOrder(term) >= startOrder)
              .toList();
          final effectiveEnd = endTerm ?? terms.first;
          final count = diaries.where((diary) {
            final order = _academicTermOrder(diary.term);
            return order >= startOrder &&
                order <= _academicTermOrder(effectiveEnd);
          }).length;
          return AlertDialog(
            title: const Text('Verificar diários sem preenchimento'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: startTerm,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Período inicial',
                    ),
                    items: terms.reversed
                        .map(
                          (term) =>
                              DropdownMenuItem(value: term, child: Text(term)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        startTerm = value;
                        if (endTerm != null &&
                            _academicTermOrder(endTerm!) <
                                _academicTermOrder(startTerm)) {
                          endTerm = null;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    initialValue: endTerm,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Período final',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Até o último período disponível'),
                      ),
                      ...endChoices.map(
                        (term) => DropdownMenuItem<String?>(
                          value: term,
                          child: Text(term),
                        ),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() => endTerm = value),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '$count diário(s) serão verificados. Basta um campo de conteúdo em branco para o diário aparecer no log como sem preenchimento.',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
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
              FilledButton(
                onPressed: count == 0
                    ? null
                    : () => Navigator.pop(context, (startTerm, endTerm)),
                child: const Text('Iniciar verificação'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<(String, String?)?> _showDiaryDownloadRange(
    List<String> terms,
    List<PortalDiaryDownload> diaries,
  ) {
    var startTerm = terms.first;
    String? endTerm;
    return showDialog<(String, String?)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final startOrder = _academicTermOrder(startTerm);
          final endChoices = terms
              .where((term) => _academicTermOrder(term) >= startOrder)
              .toList();
          final effectiveEnd = endTerm ?? terms.first;
          final count = diaries.where((diary) {
            final order = _academicTermOrder(diary.term);
            return order >= _academicTermOrder(startTerm) &&
                order <= _academicTermOrder(effectiveEnd);
          }).length;
          return AlertDialog(
            title: const Text('Extrair diários do Portal'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: startTerm,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Período inicial',
                    ),
                    items: terms.reversed
                        .map(
                          (term) =>
                              DropdownMenuItem(value: term, child: Text(term)),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        startTerm = value;
                        if (endTerm != null &&
                            _academicTermOrder(endTerm!) <
                                _academicTermOrder(startTerm)) {
                          endTerm = null;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    initialValue: endTerm,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Período final',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Até o último período disponível'),
                      ),
                      ...endChoices.map(
                        (term) => DropdownMenuItem<String?>(
                          value: term,
                          child: Text(term),
                        ),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() => endTerm = value),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '$count diário(s) serão baixados como arquivos originais para a pasta escolhida.',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
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
              FilledButton(
                onPressed: count == 0
                    ? null
                    : () => Navigator.pop(context, (startTerm, endTerm)),
                child: const Text('Escolher pasta'),
              ),
            ],
          );
        },
      ),
    );
  }

  int _academicTermOrder(String value) {
    final term = AcademicTerm.parse(value);
    return term == null ? -1 : term.year * 2 + term.semester;
  }

  Future<void> _showMessage(String title, String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    MoodleConfigSnapshot? selectedSnapshot;
    for (final snapshot in _moodleSnapshots) {
      if (snapshot.id == _selectedSnapshotId) selectedSnapshot = snapshot;
    }
    final moodleSource = selectedSnapshot?.toCourseConfig();
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _PageHeader(
                onBack: () => context.go('/'),
                entryCount: _entries.length,
                term: _term,
                onManageTerms: _manageTerms,
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 1000;
                          final left = _WorkspacePanel(
                            entryCount: _entries.length,
                            browserReady: _browserReady,
                            savedDiaries: _savedDiaries,
                            selectedDiaryId: _selectedDiaryId,
                            onSelectDiary: _selectSavedDiary,
                            onSaveDiary: _saveDiary,
                            onCreateDiary: () => _saveDiary(createNew: true),
                            onCopyDiary: _copyDiary,
                            onDeleteDiary: _deleteSelectedDiary,
                            sourceLabel: _sourceLabel,
                            entries: _sortMap(_entries),
                            snapshots: _moodleSnapshots,
                            selectedSnapshotId: _selectedSnapshotId,
                            onSelectSnapshot: (id) => setState(() {
                              _selectedSnapshotId = id;
                            }),
                            onUseMoodle: moodleSource == null
                                ? null
                                : () => _useMoodleConfig(
                                    moodleSource,
                                    sourceLabel: selectedSnapshot == null
                                        ? null
                                        : 'Backup · ${selectedSnapshot.label}',
                                  ),
                            onImportExcel: _selectExcel,
                            onImportPortal: _importFromPortal,
                            importingPortalDiary: _importingPortalDiary,
                            onImportJson: _importJson,
                            onImportLiveMoodle: _importFromLiveMoodle,
                            onImportSavedConfig: _importFromSavedConfig,
                            loadingMoodleCourses: _loadingMoodleCourses,
                            onExportJson: _exportJson,
                            onAdd: () => _addOrEdit(),
                            onClear: _clearEntries,
                            onFindPortalDates: _findMissingPortalDates,
                            onCopyMissingPortalDates: _copyMissingPortalDates,
                            searchingPortalDates: _searchingPortalDates,
                            missingPortalDates: _missingPortalDates,
                            onEdit: (key) => _addOrEdit(oldKey: key),
                            onRemove: _remove,
                            onShift: _shiftDates,
                            onShiftFromEntry: (key) =>
                                _shiftDates(entryKey: key),
                          );
                          final browser = _BrowserPanel(
                            urlController: _urlController,
                            onAddressChanged: (value) =>
                                _saveAddress(_portalAddressKey, value),
                            credentialsSaved:
                                _portalUsername.isNotEmpty &&
                                _portalPassword.isNotEmpty,
                            credentialsFromMoodle: _portalCredentialsFromMoodle,
                            logs: _logs,
                            onCopyLog: _copyOperationLog,
                            entryCount: _entries.length,
                            opening: _openingBrowser,
                            browserReady: _browserReady,
                            filling: _filling,
                            extractingDiaries: _extractingDiaries,
                            scanningDiaries: _scanningDiaries,
                            highlight: _highlight,
                            requireEmpty: _requireEmpty,
                            error: _error,
                            onOpen: _openBrowser,
                            onConfigureCredentials: _configurePortalCredentials,
                            onFill: _fillPortal,
                            onClearPortalDiary: _clearPortalDiary,
                            onExtractDiaries: _extractPortalDiaries,
                            onScanDiaries: _scanPortalDiaries,
                            onHighlight: (value) =>
                                setState(() => _highlight = value),
                            onRequireEmpty: (value) =>
                                setState(() => _requireEmpty = value),
                          );
                          if (compact)
                            return ListView(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                12,
                                24,
                                28,
                              ),
                              children: [
                                SizedBox(height: 680, child: left),
                                const SizedBox(height: 18),
                                SizedBox(height: 610, child: browser),
                              ],
                            );
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 6, child: left),
                                const SizedBox(width: 18),
                                Expanded(flex: 4, child: browser),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.onBack,
    required this.entryCount,
    required this.term,
    required this.onManageTerms,
  });
  final VoidCallback onBack;
  final int entryCount;
  final String term;
  final VoidCallback onManageTerms;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
    child: Row(
      children: [
        IconButton(
          onPressed: onBack,
          tooltip: 'Voltar ao início',
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 10),
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppTheme.accent.withAlpha(27),
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(
            Icons.edit_calendar_rounded,
            color: AppTheme.accent,
          ),
        ),
        const SizedBox(width: 13),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Preenche Diários',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'PREPARAÇÃO E LANÇAMENTO DE AULAS',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 9,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const Spacer(),
        InkWell(
          onTap: onManageTerms,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppTheme.bgCard.withAlpha(160),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: AppTheme.divider),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.date_range_rounded,
                  size: 16,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: 7),
                Text(
                  AcademicTerm.displayName(term),
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        _StatusPill(count: entryCount),
        const SizedBox(width: 10),
        const ThemeSelector(compact: true),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: AppTheme.glassDecoration(opacity: .06),
      child: Text(
        '$count lançamento${count == 1 ? '' : 's'}',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
      ),
    );
  }
}

class _WorkspacePanel extends StatelessWidget {
  const _WorkspacePanel({
    required this.entryCount,
    required this.browserReady,
    required this.savedDiaries,
    required this.selectedDiaryId,
    required this.onSelectDiary,
    required this.onSaveDiary,
    required this.onCreateDiary,
    required this.onCopyDiary,
    required this.onDeleteDiary,
    required this.sourceLabel,
    required this.entries,
    required this.snapshots,
    required this.selectedSnapshotId,
    required this.onSelectSnapshot,
    required this.onUseMoodle,
    required this.onImportExcel,
    required this.onImportPortal,
    required this.importingPortalDiary,
    required this.onImportJson,
    required this.onImportLiveMoodle,
    required this.onImportSavedConfig,
    required this.loadingMoodleCourses,
    required this.onExportJson,
    required this.onAdd,
    required this.onClear,
    required this.onFindPortalDates,
    required this.onCopyMissingPortalDates,
    required this.searchingPortalDates,
    required this.missingPortalDates,
    required this.onEdit,
    required this.onRemove,
    required this.onShift,
    required this.onShiftFromEntry,
  });
  final int entryCount;
  final bool browserReady;
  final List<_SavedDiary> savedDiaries;
  final String? selectedDiaryId;
  final ValueChanged<String?> onSelectDiary;
  final VoidCallback onSaveDiary, onCreateDiary;
  final VoidCallback onCopyDiary;
  final VoidCallback onDeleteDiary;
  final String? sourceLabel;
  final Map<String, String> entries;
  final List<MoodleConfigSnapshot> snapshots;
  final String? selectedSnapshotId;
  final ValueChanged<String?> onSelectSnapshot;
  final VoidCallback? onUseMoodle;
  final VoidCallback onImportExcel, onImportJson, onExportJson, onAdd, onShift;
  final ValueChanged<String> onShiftFromEntry;
  final VoidCallback onImportLiveMoodle;
  final VoidCallback onImportSavedConfig;
  final VoidCallback onImportPortal;
  final bool importingPortalDiary;
  final VoidCallback onClear;
  final VoidCallback onFindPortalDates, onCopyMissingPortalDates;
  final bool searchingPortalDates;
  final List<String> missingPortalDates;
  final bool loadingMoodleCourses;
  final ValueChanged<String> onEdit, onRemove;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: AppTheme.cardGradient,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.source_rounded, color: AppTheme.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Dados do diário',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '$entryCount itens',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (sourceLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    'Fonte atual: $sourceLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.accent,
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue:
                          savedDiaries.any(
                            (diary) => diary.id == selectedDiaryId,
                          )
                          ? selectedDiaryId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Diário / disciplina',
                        prefixIcon: Icon(Icons.menu_book_rounded),
                      ),
                      hint: const Text('Rascunho atual'),
                      items: savedDiaries
                          .map(
                            (diary) => DropdownMenuItem(
                              value: diary.id,
                              child: Text(
                                diary.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: onSelectDiary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: onCopyDiary,
                    tooltip:
                        'Copiar di\u00e1rio de outro per\u00edodo ou disciplina',
                    icon: const Icon(Icons.content_copy_rounded),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    onPressed: selectedDiaryId == null ? null : onDeleteDiary,
                    tooltip: 'Remover disciplina selecionada',
                    style: IconButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                    ),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    onPressed: entryCount == 0 ? null : onSaveDiary,
                    tooltip: 'Salvar diário atual',
                    icon: const Icon(Icons.save_rounded),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    onPressed: entryCount == 0 ? null : onCreateDiary,
                    tooltip: 'Salvar como outro diário',
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onImportJson,
                      icon: const Icon(Icons.data_object_rounded, size: 17),
                      label: const Text(
                        'Carregar JSON',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: loadingMoodleCourses
                          ? null
                          : onImportLiveMoodle,
                      icon: loadingMoodleCourses
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_rounded, size: 17),
                      label: Text(
                        loadingMoodleCourses
                            ? 'Buscando...'
                            : 'Buscar no Moodle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onImportSavedConfig,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.green,
                        foregroundColor: AppTheme.isLight
                            ? Colors.white
                            : const Color(0xFF10251C),
                      ),
                      icon: const Icon(Icons.school_rounded, size: 17),
                      label: const Text(
                        'Buscar Config Moodle',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onImportExcel,
                      icon: const Icon(Icons.table_view_rounded, size: 17),
                      label: const Text('Importar Excel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: browserReady && !importingPortalDiary
                          ? onImportPortal
                          : null,
                      icon: importingPortalDiary
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined, size: 17),
                      label: const Text(
                        'Importar do Portal Docente',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: entryCount == 0 ? null : onExportJson,
                    tooltip: 'Salvar JSON',
                    icon: const Icon(Icons.save_alt_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: entryCount == 0 ? null : onShift,
                    tooltip: 'Ajustar datas',
                    icon: const Icon(Icons.event_repeat_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: onAdd,
                    tooltip: 'Adicionar aula manualmente',
                    icon: const Icon(Icons.add_rounded),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: searchingPortalDates || !browserReady
                        ? null
                        : onFindPortalDates,
                    tooltip: searchingPortalDates
                        ? 'Buscando datas no diario aberto...'
                        : browserReady
                        ? 'Buscar datas ausentes no diario aberto'
                        : 'Abra o Edge pelo painel Portal e entre no diario para habilitar a busca',
                    icon: searchingPortalDates
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.manage_search_rounded),
                  ),
                  if (missingPortalDates.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: onCopyMissingPortalDates,
                      tooltip: 'Copiar datas ausentes',
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ],
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: entryCount == 0 ? null : onClear,
                    tooltip: 'Limpar todos os lançamentos',
                    style: IconButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                    ),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              if (snapshots.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selectedSnapshotId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText:
                              'Vers\u00e3o hist\u00f3rica / backup de outro semestre',
                          prefixIcon: Icon(Icons.history_rounded),
                        ),
                        hint: const Text(
                          'Selecionar vers\u00e3o hist\u00f3rica',
                        ),
                        items: snapshots
                            .map(
                              (snapshot) => DropdownMenuItem(
                                value: snapshot.id,
                                child: Text(
                                  '${snapshot.courseName} ? ${snapshot.label} ? ${DateFormat('dd/MM/yyyy').format(snapshot.semesterStartDate)}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: onSelectSnapshot,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: onUseMoodle,
                      icon: const Icon(Icons.history_rounded),
                      label: const Text('Usar vers\u00e3o'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 9),
              Text(
                'O cronograma é convertido em data, modalidade e conteúdo; você pode revisar cada item antes do preenchimento.',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const _EmptyEntries()
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = entries.entries.elementAt(index);
                    return _EntryTile(
                      entry: item,
                      onEdit: () => onEdit(item.key),
                      onRemove: () => onRemove(item.key),
                      onDateDoubleTap: () => onShiftFromEntry(item.key),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onEdit,
    required this.onRemove,
    required this.onDateDoubleTap,
  });
  final MapEntry<String, String> entry;
  final VoidCallback onEdit, onRemove;
  final VoidCallback onDateDoubleTap;
  @override
  Widget build(BuildContext context) {
    final practical = entry.key.toUpperCase().contains('-P');
    return Container(
      padding: EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.divider.withAlpha(160)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onDoubleTap: onDateDoubleTap,
            child: Tooltip(
              message: 'Clique duas vezes para ajustar as datas a partir daqui',
              child: Container(
                width: 76,
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: (practical ? AppTheme.accent : AppTheme.primaryLight)
                      .withAlpha(22),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  children: [
                    Text(
                      entry.key.substring(0, 10),
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      practical ? 'PRÁTICA' : 'TEÓRICA',
                      style: TextStyle(
                        color: practical
                            ? AppTheme.accent
                            : AppTheme.primaryLight,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Text(
              entry.value,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Editar',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded, size: 18),
          ),
          IconButton(
            tooltip: 'Remover',
            onPressed: onRemove,
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: AppTheme.danger,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyEntries extends StatelessWidget {
  const _EmptyEntries();
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.event_note_rounded,
            size: 44,
            color: AppTheme.textSecondary.withAlpha(130),
          ),
          const SizedBox(height: 14),
          Text(
            'Nenhum lançamento carregado',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'Importe uma planilha ou JSON, escolha dados do Moodle ou adicione itens manualmente.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    ),
  );
}

class _BrowserPanel extends StatelessWidget {
  const _BrowserPanel({
    required this.urlController,
    required this.onAddressChanged,
    required this.credentialsSaved,
    required this.credentialsFromMoodle,
    required this.logs,
    required this.onCopyLog,
    required this.entryCount,
    required this.opening,
    required this.browserReady,
    required this.filling,
    required this.extractingDiaries,
    required this.scanningDiaries,
    required this.highlight,
    required this.requireEmpty,
    required this.error,
    required this.onOpen,
    required this.onConfigureCredentials,
    required this.onFill,
    required this.onClearPortalDiary,
    required this.onExtractDiaries,
    required this.onScanDiaries,
    required this.onHighlight,
    required this.onRequireEmpty,
  });
  final TextEditingController urlController;
  final ValueChanged<String> onAddressChanged;
  final bool credentialsSaved;
  final bool credentialsFromMoodle;
  final List<String> logs;
  final VoidCallback onCopyLog;
  final int entryCount;
  final bool opening,
      browserReady,
      filling,
      extractingDiaries,
      scanningDiaries,
      highlight,
      requireEmpty;
  final String? error;
  final VoidCallback onOpen, onConfigureCredentials, onFill;
  final VoidCallback onClearPortalDiary;
  final VoidCallback onExtractDiaries;
  final VoidCallback onScanDiaries;
  final ValueChanged<bool> onHighlight, onRequireEmpty;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppTheme.bgCardAlt,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.web_rounded,
                    color: browserReady ? Colors.greenAccent : AppTheme.accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Portal do docente',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  _ConnectionLabel(opening: opening, ready: browserReady),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                onChanged: onAddressChanged,
                decoration: const InputDecoration(
                  labelText: 'Endereço do portal',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
                onSubmitted: (_) => onOpen(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onConfigureCredentials,
                  icon: Icon(
                    credentialsSaved
                        ? Icons.key_rounded
                        : Icons.key_off_rounded,
                    size: 17,
                  ),
                  label: Text(
                    credentialsSaved
                        ? credentialsFromMoodle
                              ? 'Usando login salvo do Moodle · Editar'
                              : 'Login do portal salvo · Editar'
                        : 'Configurar login do portal',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: opening ? null : onOpen,
                  icon: opening
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_browser_rounded),
                  label: Text(
                    opening
                        ? 'Abrindo Edge…'
                        : browserReady
                        ? 'Abrir endereço no Edge'
                        : 'Abrir Edge e entrar no portal',
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(top: 9),
                child: Text(
                  credentialsSaved
                      ? credentialsFromMoodle
                            ? 'O Gestor UFU usa as credenciais já salvas do Moodle. Se o Portal usar outro login, edite acima.'
                            : 'O Gestor UFU tenta preencher o login salvo ao abrir o portal. Depois, abra a turma e deixe visível o formulário do diário.'
                      : 'Configure o login do portal ou entre manualmente no Edge. Depois, abra a turma e deixe visível o formulário do diário.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 10,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: requireEmpty,
                onChanged: onRequireEmpty,
                title: const Text(
                  'Não sobrescrever campos preenchidos',
                  style: TextStyle(fontSize: 12),
                ),
                subtitle: const Text(
                  'Mantém o que já estiver preenchido no portal.',
                  style: TextStyle(fontSize: 10),
                ),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: highlight,
                onChanged: onHighlight,
                title: const Text(
                  'Destacar campos preenchidos',
                  style: TextStyle(fontSize: 12),
                ),
                subtitle: Text(
                  'Realça cada campo durante o preenchimento.',
                  style: TextStyle(fontSize: 10),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: browserReady && !filling && entryCount > 0
                      ? onFill
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: AppTheme.bgDark,
                  ),
                  icon: filling
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(filling ? 'Preenchendo…' : 'Preencher diário'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: 'Limpar o diário aberto no Portal Docente',
                      child: OutlinedButton.icon(
                        onPressed:
                            browserReady &&
                                !filling &&
                                !extractingDiaries &&
                                !scanningDiaries
                            ? onClearPortalDiary
                            : null,
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                          foregroundColor: AppTheme.danger,
                          side: BorderSide(
                            color: AppTheme.danger.withValues(alpha: 0.65),
                          ),
                        ),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: const Text(
                          'Limpar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Tooltip(
                      message:
                          'Verificar por período e listar diários com ao menos um campo de conteúdo vazio',
                      child: OutlinedButton.icon(
                        onPressed:
                            filling || scanningDiaries || extractingDiaries
                            ? null
                            : onScanDiaries,
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                        ),
                        icon: scanningDiaries
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fact_check_outlined, size: 16),
                        label: Text(
                          scanningDiaries ? 'Verificando' : 'Verificar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Tooltip(
                      message: 'Extrair os PDFs dos diários por período',
                      child: OutlinedButton.icon(
                        onPressed:
                            filling || scanningDiaries || extractingDiaries
                            ? null
                            : onExtractDiaries,
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 7),
                        ),
                        icon: extractingDiaries
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.download_for_offline_outlined,
                                size: 16,
                              ),
                        label: Text(
                          extractingDiaries ? 'Extraindo' : 'Extrair',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
          child: Row(
            children: [
              Icon(
                Icons.subject_rounded,
                size: 17,
                color: AppTheme.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Registro da operação',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${logs.length} mensagens',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 10),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Copiar log',
                onPressed: logs.isEmpty ? null : onCopyLog,
                icon: const Icon(Icons.copy_rounded, size: 17),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? Center(
                  child: Text(
                    'As etapas e os resultados aparecerão aqui.',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                    itemCount: logs.length,
                    itemBuilder: (context, i) {
                      final line = logs[logs.length - i - 1];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          line,
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 10,
                            height: 1.4,
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    ),
  );
}

class _ConnectionLabel extends StatelessWidget {
  const _ConnectionLabel({required this.opening, required this.ready});
  final bool opening, ready;
  @override
  Widget build(BuildContext context) {
    final color = ready
        ? Colors.greenAccent
        : opening
        ? AppTheme.accent
        : AppTheme.textSecondary;
    final text = ready
        ? 'EDGE ABERTO'
        : opening
        ? 'INICIANDO'
        : 'DESCONECTADO';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withAlpha(22),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: .6,
        ),
      ),
    );
  }
}

class _ValidationResult {
  const _ValidationResult(this.valid, this.errors);
  final Map<String, String> valid;
  final Map<String, String> errors;
}

class _ImportResult extends _ValidationResult {
  const _ImportResult(super.valid, super.errors, this.skipped, this.duplicates);
  final int skipped, duplicates;
}

class _ShiftResult {
  const _ShiftResult(
    this.entries,
    this.changed,
    this.filtered,
    this.overwritten,
  );
  final Map<String, String> entries;
  final int changed, filtered, overwritten;
}

class _SavedDiary {
  const _SavedDiary({
    required this.id,
    required this.name,
    required this.entries,
    this.sourceLabel,
  });

  final String id;
  final String name;
  final Map<String, String> entries;
  final String? sourceLabel;

  factory _SavedDiary.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    if (rawEntries is! Map)
      throw const FormatException('Invalid diary entries');
    return _SavedDiary(
      id: json['id'] as String,
      name: json['name'] as String,
      entries: rawEntries.map<String, String>(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      sourceLabel: json['sourceLabel'] as String?,
    );
  }

  _SavedDiary copyWith({Map<String, String>? entries, String? sourceLabel}) =>
      _SavedDiary(
        id: id,
        name: name,
        entries: entries ?? this.entries,
        sourceLabel: sourceLabel ?? this.sourceLabel,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'entries': entries,
    'sourceLabel': sourceLabel,
  };
}

class _MoodleDiaryCourseDialog extends StatelessWidget {
  const _MoodleDiaryCourseDialog({required this.courses});

  final List<MoodleCourse> courses;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Escolha uma disciplina do Moodle'),
    content: SizedBox(
      width: 520,
      height: 440,
      child: ListView.separated(
        itemCount: courses.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final course = courses[index];
          return ListTile(
            leading: const Icon(
              Icons.menu_book_rounded,
              color: AppTheme.accent,
            ),
            title: Text(
              course.fullname,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if (course.shortname.isNotEmpty) course.shortname,
                if (course.startDate != null)
                  'Início: ${DateFormat('dd/MM/yyyy').format(course.startDate!)}',
              ].join(' · '),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.pop(context, course),
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

class _SavedMoodleConfigDialog extends StatelessWidget {
  const _SavedMoodleConfigDialog({required this.configs});

  final List<CourseConfig> configs;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Escolha uma configuração salva'),
    content: SizedBox(
      width: 520,
      height: 440,
      child: ListView.separated(
        itemCount: configs.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final config = configs[index];
          return ListTile(
            leading: const Icon(
              Icons.school_rounded,
              color: AppTheme.accentGreen,
            ),
            title: Text(
              config.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${config.sections.length} seções · início ${DateFormat('dd/MM/yyyy').format(config.semesterStartDate)}',
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
