import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/equivalencia/application/certidao_pdf.dart';
import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_service.dart';
import 'package:gestor_ufu/modules/equivalencia/data/historico_exemplo.dart';
import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';
import 'package:gestor_ufu/modules/equivalencia/pages/equivalencia_history_window.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';

/// Cadastro de currículos e análise de transferência por blocos curriculares.
/// A tela só cuida da interface; dados e regras ficam no [EquivalenciaService]
/// (os mesmos usados pelos comandos do módulo e pelo Agente de IA).
class EquivalenciaPage extends StatefulWidget {
  const EquivalenciaPage({required this.service, super.key});

  final EquivalenciaService service;

  @override
  State<EquivalenciaPage> createState() => _EquivalenciaPageState();
}

class _EquivalenciaPageState extends State<EquivalenciaPage> {
  final _search = TextEditingController();
  bool _busy = true;
  WindowController? _historyController;
  WindowMethodChannel? _historyChannel;
  bool _openingHistory = false;
  String? _historyCaseId;
  EquivalenceCase? _historyPreview;

  EquivalenciaService get _service => widget.service;
  List<EquivalenceCase> get _cases => _service.state.cases;
  List<Curriculum> get _curricula => _service.state.curricula;
  String? get _currentId => _service.state.currentId;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    _load();
    _search.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    _search.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
    final item = _service.state.caseById(_historyCaseId ?? '');
    if (item != null) {
      _syncHistory(
        _historyPreview?.id == item.id
            ? item.copyWith(blocks: _historyPreview!.blocks)
            : item,
      );
    }
  }

  Future<void> _syncHistory(EquivalenceCase item) async {
    if (_historyCaseId != item.id || _historyChannel == null) return;
    try {
      await _historyChannel!.invokeMethod<bool>('setHistory', {
        'caseId': item.id,
        'student': item.student,
        'entries': _historyForCase(item).map((e) => e.toJson()).toList(),
      });
    } catch (_) {
      // A janela pode ter sido fechada pelo usuário.
    }
  }

  Future<void> _load() async {
    await _service.load();
    if (mounted) setState(() => _busy = false);
  }

  Curriculum? _curriculum(String? id) => _service.state.curriculum(id);

  Future<void> _printCertificate(EquivalenceCase item) async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Salvar certidão de estudos em PDF',
        fileName: CertidaoPdf.fileName(item),
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (path == null) return;
      await _service.exportCertidao(item.id, path);
      _message('PDF da certidão gerado com sucesso.');
    } catch (error) {
      _message('Não foi possível gerar o PDF: $error');
    }
  }

  Future<void> _showHistory(EquivalenceCase item) async {
    final initial = _historyForCase(item);
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (isDesktop) {
      try {
        await _openHistoryWindow(item, initial);
        return;
      } catch (error) {
        _message('Não foi possível abrir outra janela: $error');
      }
    }
    if (!mounted) return;
    var entries = initial;
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Histórico visual · ${item.student}'),
          content: SizedBox(
            width: (MediaQuery.sizeOf(context).width * .9).clamp(720.0, 1450.0),
            height: (MediaQuery.sizeOf(context).height * .78).clamp(
              440.0,
              760.0,
            ),
            child: EquivalenciaHistoryGrid(
              student: item.student,
              entries: entries,
              onChanged: (updated) async =>
                  setDialogState(() => entries = updated),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Salvar histórico'),
            ),
          ],
        ),
      ),
    );
    if (shouldSave == true) await _saveHistory(item.id, entries);
  }

  Future<void> _openHistoryWindow(
    EquivalenceCase item,
    List<HistoricalSubject> entries,
  ) async {
    _historyCaseId = item.id;
    final activeChannel = _historyChannel;
    final activeController = _historyController;
    if (activeChannel != null && activeController != null) {
      final windows = await WindowController.getAll();
      if (windows.any(
        (window) => window.windowId == activeController.windowId,
      )) {
        await activeChannel.invokeMethod<bool>('setHistory', {
          'caseId': item.id,
          'student': item.student,
          'entries': entries.map((entry) => entry.toJson()).toList(),
        });
        await activeController.show();
        return;
      }
      await activeChannel.setMethodCallHandler(null);
      _historyChannel = null;
      _historyController = null;
    }
    if (_openingHistory) return;
    _openingHistory = true;
    final channelName =
        'gestor_ufu_history_${DateTime.now().microsecondsSinceEpoch}';
    final channel = WindowMethodChannel(
      channelName,
      mode: ChannelMode.bidirectional,
    );
    try {
      await channel.setMethodCallHandler((call) async {
        if (call.method == 'saveHistory') {
          final payload = Map<String, dynamic>.from(call.arguments as Map);
          final history = (payload['entries'] as List)
              .map(
                (entry) => HistoricalSubject.fromJson(
                  Map<String, dynamic>.from(entry as Map),
                ),
              )
              .toList();
          await _saveHistory(payload['caseId'] as String, history);
          return true;
        }
        if (call.method == 'closed') return true;
        throw MissingPluginException('Método não reconhecido: ${call.method}');
      });
      _historyChannel = channel;
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({
            'type': 'equivalenciaHistory',
            'channel': channelName,
            'caseId': item.id,
            'student': item.student,
            'entries': entries.map((entry) => entry.toJson()).toList(),
            'isLight': AppTheme.isLight,
          }),
        ),
      );
      _historyController = controller;
      await controller.show();
    } catch (_) {
      await channel.setMethodCallHandler(null);
      _historyChannel = null;
      _historyController = null;
      rethrow;
    } finally {
      _openingHistory = false;
    }
  }

  Future<void> _saveHistory(
    String caseId,
    List<HistoricalSubject> history,
  ) async {
    final item = _service.state.caseById(caseId);
    if (item == null) return;
    await _service.saveCase(item.copyWith(history: history));
  }

  List<HistoricalSubject> _historyForCase(EquivalenceCase item) {
    final curriculum = _curriculum(item.currentCurriculumId);
    final saved = {
      for (final entry in item.history) subjectCatalogKey(entry.subject): entry,
    };
    return item
        .copyWith(
          history: [
            for (final subject in curriculum?.subjects ?? const <Subject>[])
              saved[subjectCatalogKey(subject)] ??
                  HistoricalSubject(
                    subject: subject,
                    status:
                        item.studentId == eca2020ExampleStudentId &&
                            eca2020ExampleApprovedCodes.contains(subject.code)
                        ? 'Aprovado'
                        : 'Não cursada',
                  ),
            ...item.history,
          ],
        )
        .historyFor(subjects: curriculum?.subjects ?? const [])
        .where(
          (entry) =>
              curriculum == null ||
              curriculum.subjects.any(
                (subject) =>
                    subjectCatalogKey(subject) ==
                    subjectCatalogKey(entry.subject),
              ),
        )
        .toList();
  }

  Future<void> _removeCase(EquivalenceCase item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remover análise?'),
        content: Text(
          'A análise de "${item.student.isEmpty ? 'aluno sem nome' : item.student}" '
          'será apagada.',
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
    if (confirmed != true) return;
    await _service.removeCase(item.id);
  }

  Future<void> _newCase({EquivalenceCase? seed}) async {
    final draft =
        seed ??
        EquivalenceCase(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          student: '',
          studentId: '',
          currentCurriculumId: _currentId!,
          priorCurriculumId: '',
          status: 'Em análise',
          notes: '',
          blocks: [],
        );
    final result = await showDialog<EquivalenceCase>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CaseDialog(
        value: draft.copyWith(history: _historyForCase(draft)),
        curricula: _curricula,
        removeCurriculumSubject: _service.removeCurriculumSubject,
        latestValue: () {
          final latest = _service.state.caseById(draft.id) ?? draft;
          return latest.copyWith(history: _historyForCase(latest));
        },
        onBlocksChanged: (blocks) {
          _historyPreview = (_service.state.caseById(draft.id) ?? draft)
              .copyWith(blocks: [...blocks]);
          return _syncHistory(_historyPreview!);
        },
      ),
    );
    _historyPreview = null;
    if (result == null || !mounted) {
      await _syncHistory(_service.state.caseById(draft.id) ?? draft);
      return;
    }
    await _service.saveCase(result);
  }

  Future<void> _curriculumDialog() async {
    final result = await showDialog<List<Curriculum>>(
      context: context,
      builder: (_) => _CurriculumDialog(initial: _curricula, service: _service),
    );
    if (result == null || result.isEmpty || !mounted) return;
    await _service.replaceCurricula(result);
  }

  Future<void> _importWorkbook() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Importar modelo de equivalência',
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xlsm'],
      withData: true,
    );
    if (picked == null) return;
    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      _message('Não foi possível ler o arquivo selecionado.');
      return;
    }
    try {
      final imported = await _service.parseAnalysis(bytes);
      await _newCase(seed: imported);
      if (mounted) {
        _message(
          '${imported.blocks.length} blocos importados. Revise os dados do aluno e as cargas horárias.',
        );
      }
    } on Object catch (e) {
      _message('Falha ao importar: $e');
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.toLowerCase().trim();
    final visible = _cases
        .where(
          (c) =>
              query.isEmpty ||
              [
                c.student,
                c.studentId,
                _curriculum(c.currentCurriculumId)?.course ?? '',
              ].join(' ').toLowerCase().contains(query),
        )
        .toList();
    return ModuleScaffold(
      moduleId: 'equivalencia-alunos',
      subtitle: 'Análise de transferência por blocos curriculares',
      // Só ícones; o texto aparece ao passar o mouse.
      actions: [
        IconButton.filled(
          onPressed: () => _newCase(),
          tooltip: 'Nova análise',
          icon: const Icon(Icons.add),
        ),
        IconButton.outlined(
          onPressed: _curriculumDialog,
          tooltip: 'Currículos',
          icon: const Icon(Icons.account_tree_outlined),
        ),
        IconButton.outlined(
          onPressed: _importWorkbook,
          tooltip: 'Importar planilha',
          icon: const Icon(Icons.upload_file),
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: [
                _curriculumSelector(),
                const SizedBox(height: 14),
                TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Buscar aluno, matrícula ou curso',
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _busy
                      ? const Center(child: CircularProgressIndicator())
                      : visible.isEmpty
                      ? _empty()
                      : ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) => _caseTile(visible[i]),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _curriculumSelector() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: AppTheme.cardGradient,
      border: Border.all(color: AppTheme.divider),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Expanded(
          child: _curriculumDrop(
            'Curso / currículo de destino',
            _currentId,
            (v) => _service.selectCurriculum(v),
          ),
        ),
        const SizedBox(width: 20),
        Flexible(
          child: Text(
            'Cadastre manualmente as disciplinas cursadas e distribua-as nos blocos de cada análise.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
      ],
    ),
  );

  Widget _curriculumDrop(
    String label,
    String? value,
    ValueChanged<String?> onChanged,
  ) => DropdownButtonFormField<String>(
    isExpanded: true,
    initialValue: _curricula.any((c) => c.id == value) ? value : null,
    decoration: InputDecoration(labelText: label),
    items: _curricula
        .map(
          (c) => DropdownMenuItem(
            value: c.id,
            child: Text(
              '${c.course} - ${c.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        )
        .toList(),
    onChanged: onChanged,
  );

  Widget _caseTile(EquivalenceCase item) {
    final current = _curriculum(item.currentCurriculumId);
    final deficits = item.blocks
        .where((b) => b.currentHours < b.priorHours)
        .length;
    final incomplete = item.blocks
        .where((b) => b.current.isEmpty || b.prior.isEmpty)
        .length;
    final color = incomplete > 0
        ? AppTheme.warning
        : deficits > 0
        ? AppTheme.danger
        : AppTheme.green;
    return Container(
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        border: Border.all(color: AppTheme.divider),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: color.withAlpha(35),
          child: Icon(Icons.person_outline, color: color),
        ),
        title: Text(
          item.student.isEmpty ? 'Aluno sem nome' : item.student,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${item.studentId.isEmpty ? 'Matrícula não informada' : 'Matrícula ${item.studentId}'} · ${current?.course ?? 'Curso atual'} · disciplinas de origem informadas manualmente\n${item.blocks.length} bloco(s) · ${deficits > 0
              ? '$deficits com CH insuficiente'
              : incomplete > 0
              ? '$incomplete incompleto(s)'
              : 'CH compatível'}',
        ),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 4,
          children: [
            Chip(label: Text(item.status)),
            IconButton(
              tooltip: 'Mostrar histórico visual em outra janela',
              onPressed: () => _showHistory(item),
              icon: const Icon(Icons.history),
            ),
            if (item.isApproved)
              IconButton(
                tooltip: 'Imprimir certidão de estudos em PDF',
                onPressed: () => _printCertificate(item),
                icon: const Icon(Icons.print_outlined),
              ),
            IconButton(
              tooltip: 'Abrir blocos',
              onPressed: () => _newCase(seed: item),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Remover análise',
              onPressed: () => _removeCase(item),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        onTap: () => _newCase(seed: item),
      ),
    );
  }

  Widget _empty() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.compare_arrows, size: 54, color: AppTheme.textSecondary),
        const SizedBox(height: 12),
        Text(
          'Nenhuma análise cadastrada',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          'Escolha o curso de destino. As disciplinas cursadas serão cadastradas manualmente nos blocos de cada análise.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      ],
    ),
  );
}

class _CurriculumDialog extends StatefulWidget {
  const _CurriculumDialog({required this.initial, required this.service});
  final List<Curriculum> initial;
  final EquivalenciaService service;
  @override
  State<_CurriculumDialog> createState() => _CurriculumDialogState();
}

class _CurriculumDialogState extends State<_CurriculumDialog> {
  late final List<Curriculum> _items = [...widget.initial];
  final _course = TextEditingController(), _name = TextEditingController();
  List<Subject> _subjects = [];
  String? _editingId;
  @override
  void dispose() {
    _course.dispose();
    _name.dispose();
    super.dispose();
  }

  void _add() {
    if (_course.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    setState(() {
      final curriculum = Curriculum(
        id: _editingId ?? DateTime.now().microsecondsSinceEpoch.toString(),
        course: _course.text.trim(),
        name: _name.text.trim(),
        subjects: List.of(_subjects),
      );
      final index = _items.indexWhere((item) => item.id == curriculum.id);
      if (index < 0) {
        _items.add(curriculum);
      } else {
        _items[index] = curriculum;
      }
      _course.clear();
      _name.clear();
      _subjects = [];
      _editingId = null;
    });
  }

  void _edit(Curriculum curriculum) {
    setState(() {
      _editingId = curriculum.id;
      _course.text = curriculum.course;
      _name.text = curriculum.name;
      _subjects = List.of(curriculum.subjects);
    });
  }

  Future<void> _importSubjects() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Importar disciplinas do currículo',
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xlsm', 'json'],
      withData: true,
    );
    if (picked == null) return;
    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      _notice('Não foi possível ler o arquivo selecionado.');
      return;
    }
    try {
      final parsed = widget.service.parseCurriculum(bytes);
      setState(() => _subjects = mergeSubjects([..._subjects, ...parsed]));
      _notice(
        picked.files.single.extension?.toLowerCase() == 'json'
            ? '${parsed.length} disciplinas importadas do JSON, incluindo os períodos.'
            : '${parsed.length} disciplinas importadas. Equivalências automáticas, estágio, atividades complementares e optativas foram ignoradas.',
      );
    } on Object catch (e) {
      _notice('Falha ao importar disciplinas: $e');
    }
  }

  void _notice(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Currículos cadastrados'),
    content: SizedBox(
      width: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _course,
            decoration: const InputDecoration(labelText: 'Curso'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Identificação do currículo (ex.: 2020/1)',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _importSubjects,
              icon: const Icon(Icons.upload_file),
              label: Text(
                _subjects.isEmpty
                    ? 'Importar disciplinas (planilha ou JSON)'
                    : 'Disciplinas carregadas · ${_subjects.length} disciplinas',
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _add,
              icon: Icon(_editingId == null ? Icons.add : Icons.save_outlined),
              label: Text(
                _editingId == null
                    ? 'Adicionar currículo'
                    : 'Salvar alterações',
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: _items
                  .map(
                    (c) => ListTile(
                      title: Text(c.course),
                      subtitle: Text(
                        '${c.name}${c.subjects.isEmpty ? '' : ' · ${c.subjects.length} disciplinas'}',
                      ),
                      trailing: Wrap(
                        spacing: 2,
                        children: [
                          IconButton(
                            tooltip: 'Editar e importar disciplinas',
                            onPressed: () => _edit(c),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: () => setState(() => _items.remove(c)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
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
        onPressed: () => Navigator.pop(context, _items),
        child: const Text('Salvar'),
      ),
    ],
  );
}

class _CaseDialog extends StatefulWidget {
  const _CaseDialog({
    required this.value,
    required this.curricula,
    required this.removeCurriculumSubject,
    required this.onBlocksChanged,
    required this.latestValue,
  });
  final EquivalenceCase value;
  final List<Curriculum> curricula;
  final Future<void> Function(List<EquivalenceBlock>) onBlocksChanged;
  final EquivalenceCase Function() latestValue;
  final Future<void> Function(String curriculumId, Subject subject)
  removeCurriculumSubject;
  @override
  State<_CaseDialog> createState() => _CaseDialogState();
}

class _CaseDialogState extends State<_CaseDialog> {
  late final _student = TextEditingController(text: widget.value.student),
      _id = TextEditingController(text: widget.value.studentId),
      _notes = TextEditingController(text: widget.value.notes);
  late String _current = widget.value.currentCurriculumId,
      _status = widget.value.status;
  late final List<EquivalenceBlock> _blocks = [...widget.value.blocks];
  late final List<Subject> _currentCatalog = mergeSubjects([
    ...?widget.curricula
        .where((c) => c.id == widget.value.currentCurriculumId)
        .firstOrNull
        ?.subjects,
    ...widget.value.currentCatalog,
    ...widget.value.blocks.expand((b) => b.current),
  ]);
  late final List<Subject> _priorCatalog = mergeSubjects([
    ...widget.value.priorCatalog,
    ...widget.value.blocks.expand((b) => b.prior),
  ]);
  Set<String> get _approvedCurrent => {
    ...widget
        .latestValue()
        .history
        .where((e) => e.status == 'Aprovado')
        .map((e) => subjectCatalogKey(e.subject)),
  };
  Set<String> get _blockedCurrent => {
    ..._approvedCurrent,
    ..._blocks.expand((b) => b.current).map(subjectCatalogKey),
  };
  @override
  void dispose() {
    _student.dispose();
    _id.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _block([EquivalenceBlock? old]) async {
    final value = await showDialog<EquivalenceBlock>(
      context: context,
      builder: (_) => _BlockDialog(
        value: old,
        currentCatalog:
            mergeSubjects([
                  ..._currentCatalog,
                  ...?widget.curricula
                      .where((c) => c.id == _current)
                      .firstOrNull
                      ?.subjects,
                ])
                .where(
                  (s) =>
                      !_approvedCurrent.contains(subjectCatalogKey(s)) &&
                      (!_blockedCurrent.contains(subjectCatalogKey(s)) ||
                          (old?.current.any(
                                (p) =>
                                    subjectCatalogKey(p) ==
                                    subjectCatalogKey(s),
                              ) ??
                              false)),
                )
                .toList(),
        priorCatalog: _priorCatalog,
        removeCurrentSubject: (subject) async {
          final key = subjectCatalogKey(subject);
          _currentCatalog.removeWhere((item) => subjectCatalogKey(item) == key);
          await widget.removeCurriculumSubject(_current, subject);
        },
      ),
    );
    if (value != null) {
      setState(() {
        addSubjects(_currentCatalog, value.current);
        addSubjects(_priorCatalog, value.prior);
        final i = _blocks.indexWhere((b) => b.id == value.id);
        if (i < 0) {
          _blocks.add(value);
        } else {
          _blocks[i] = value;
        }
      });
      await widget.onBlocksChanged(_blocks);
    }
  }

  Future<void> _manageCatalog() async {
    final curriculumSubjects =
        widget.curricula.where((c) => c.id == _current).firstOrNull?.subjects ??
        const <Subject>[];
    final result =
        await showDialog<({List<Subject> current, List<Subject> prior})>(
          context: context,
          builder: (_) => _SubjectCatalogDialog(
            current: _currentCatalog,
            prior: _priorCatalog,
            availableCurrent: curriculumSubjects,
          ),
        );
    if (result == null) return;
    setState(() {
      _currentCatalog
        ..clear()
        ..addAll(result.current);
      _priorCatalog
        ..clear()
        ..addAll(result.prior);
    });
  }

  void _save() {
    if (_student.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Informe o nome do aluno.')));
      return;
    }
    final invalid = _blocks
        .where((b) => b.current.isEmpty || b.prior.isEmpty)
        .toList();
    if (invalid.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cada bloco precisa ter pelo menos uma disciplina nos dois currículos.',
          ),
        ),
      );
      return;
    }
    final alreadyUsed = <String, String>{};
    for (final block in _blocks) {
      for (final subject in block.current) {
        final key = subjectCatalogKey(subject);
        if (_approvedCurrent.contains(key)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Esta disciplina está aprovada no histórico e não pode ser usada em um bloco de equivalência.',
              ),
            ),
          );
          return;
        }
        final firstBlock = alreadyUsed[key];
        if (firstBlock != null && firstBlock != block.id) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Uma disciplina de destino não pode ser usada em mais de um bloco.',
              ),
            ),
          );
          return;
        }
        alreadyUsed[key] = block.id;
      }
    }
    Navigator.pop(
      context,
      EquivalenceCase(
        id: widget.value.id,
        student: _student.text.trim(),
        studentId: _id.text.trim(),
        currentCurriculumId: _current,
        priorCurriculumId: '',
        status: _status,
        notes: _notes.text.trim(),
        blocks: _blocks,
        currentCatalog: mergeSubjects([
          ..._currentCatalog,
          ...?widget.curricula
              .where((c) => c.id == _current)
              .firstOrNull
              ?.subjects,
        ]),
        priorCatalog: _priorCatalog,
        history: _historyForSave(),
      ),
    );
  }

  List<HistoricalSubject> _historyForSave() {
    return widget.value
        .copyWith(blocks: _blocks, history: widget.latestValue().history)
        .historyFor(subjects: _currentCatalog);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Análise de transferência'),
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width * .82).clamp(760.0, 1050.0),
        height: (MediaQuery.sizeOf(context).height * .68).clamp(430.0, 620.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _student,
                    decoration: const InputDecoration(
                      labelText: 'Nome do aluno *',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 230,
                  child: TextField(
                    controller: _id,
                    decoration: const InputDecoration(labelText: 'Matrícula'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _current,
                    decoration: const InputDecoration(
                      labelText: 'Curso / currículo de destino',
                    ),
                    items: widget.curricula
                        .map(
                          (c) => DropdownMenuItem(
                            value: c.id,
                            child: Text(
                              '${c.course} - ${c.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _current = v ?? _current),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Blocos de equivalência',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    'Informe manualmente as disciplinas cursadas em cada bloco.',
                    style: TextStyle(color: AppTheme.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: () => _block(),
                  icon: const Icon(Icons.add),
                  label: const Text('Adicionar bloco'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _manageCatalog,
                icon: const Icon(Icons.library_add_outlined),
                label: Text(
                  'Disciplinas cadastradas: destino ${_currentCatalog.length} · origem ${_priorCatalog.length}',
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _blocks.isEmpty
                  ? Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 680),
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.cardGradient.colors.first.withAlpha(
                            90,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppTheme.divider),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Nenhum bloco adicionado',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Adicione um bloco para cadastrar manualmente as disciplinas cursadas e compará-las com as do currículo atual. Cada lado precisa ter ao menos uma disciplina.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppTheme.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _blocks.length,
                      itemBuilder: (_, i) => _blockCard(_blocks[i], i),
                    ),
            ),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Observações'),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: DropdownButton<String>(
                value: _status,
                items: const ['Em análise', 'Deferida', 'Indeferida']
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text('Situação: $s'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _status = v ?? _status),
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
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save),
          label: const Text('Salvar análise'),
        ),
      ],
    );
  }

  Widget _blockCard(EquivalenceBlock b, int index) {
    final ok = b.currentHours <= b.priorHours;
    final color = ok ? AppTheme.green : AppTheme.danger;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Bloco ${index + 1}${b.period.isEmpty ? '' : ' · Período ${b.period}'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${b.currentHours} h destino  ≤  ${b.priorHours} h cursado',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (_blocks.length > 1)
                  IconButton(
                    tooltip: 'Agrupar com outro bloco',
                    onPressed: () => _mergeBlocks(b),
                    icon: const Icon(Icons.merge_type),
                  ),
                IconButton(
                  onPressed: () => _block(b),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  onPressed: () async {
                    setState(() => _blocks.remove(b));
                    await widget.onBlocksChanged(_blocks);
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _subjectColumn('Currículo atual / destino', b.current),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: _subjectColumn(
                    'Disciplinas cursadas (origem)',
                    b.prior,
                  ),
                ),
              ],
            ),
            if (!ok)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Carga do destino superior à cursada em ${b.currentHours - b.priorHours} h; este bloco ainda não atende ao critério de dispensa.',
                  style: TextStyle(color: AppTheme.danger, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _mergeBlocks(EquivalenceBlock primary) async {
    final candidates = _blocks
        .where((block) => block.id != primary.id)
        .toList();
    if (candidates.isEmpty) return;
    String? selectedId;
    final otherId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Agrupar blocos'),
          content: SizedBox(
            width: 520,
            height: 300,
            child: Column(
              children: [
                Text(
                  'Escolha o bloco que será unido ao Bloco ${_blocks.indexOf(primary) + 1}.',
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: RadioGroup<String>(
                    groupValue: selectedId,
                    onChanged: (value) =>
                        setDialogState(() => selectedId = value),
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (_, i) {
                        final candidate = candidates[i];
                        final blockIndex = _blocks.indexOf(candidate);
                        return RadioListTile<String>(
                          value: candidate.id,
                          title: Text(
                            'Bloco ${blockIndex + 1}${candidate.period.trim().isEmpty ? '' : ' · Período ${candidate.period}'}',
                          ),
                          subtitle: Text(
                            '${candidate.currentHours} h destino · ${candidate.priorHours} h cursado',
                          ),
                        );
                      },
                    ),
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
            FilledButton.icon(
              onPressed: selectedId == null
                  ? null
                  : () => Navigator.pop(dialogContext, selectedId),
              icon: const Icon(Icons.merge_type),
              label: const Text('Agrupar em um bloco'),
            ),
          ],
        ),
      ),
    );
    if (otherId == null || !mounted) return;
    final primaryIndex = _blocks.indexWhere((block) => block.id == primary.id);
    final otherIndex = _blocks.indexWhere((block) => block.id == otherId);
    if (primaryIndex < 0 || otherIndex < 0) return;
    final other = _blocks[otherIndex];
    final periods = [
      primary.period.trim(),
      other.period.trim(),
    ].where((period) => period.isNotEmpty).toSet();
    final merged = EquivalenceBlock(
      id: primary.id,
      period: periods.join(' + '),
      current: mergeSubjects([...primary.current, ...other.current]),
      prior: mergeSubjects([...primary.prior, ...other.prior]),
    );
    setState(() {
      _blocks[primaryIndex] = merged;
      _blocks.removeAt(otherIndex);
    });
  }

  Widget _subjectColumn(String label, List<Subject> subjects) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
      ),
      ...subjects.map(
        (s) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${s.code.isEmpty ? '' : '${s.code} - '}${s.name} (${s.theoretical}T + ${s.practical}P = ${s.hours} h)',
          ),
        ),
      ),
    ],
  );
}

class _BlockDialog extends StatefulWidget {
  const _BlockDialog({
    this.value,
    required this.currentCatalog,
    required this.priorCatalog,
    required this.removeCurrentSubject,
  });
  final EquivalenceBlock? value;
  final List<Subject> currentCatalog, priorCatalog;
  final Future<void> Function(Subject subject) removeCurrentSubject;
  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  late final _period = TextEditingController(text: widget.value?.period ?? '');
  late final List<Subject> _current = [...?widget.value?.current],
      _prior = [...?widget.value?.prior];
  @override
  void dispose() {
    _period.dispose();
    super.dispose();
  }

  Future<void> _subject(bool currentSide, [Subject? old]) async {
    final result = await showDialog<Subject>(
      context: context,
      builder: (_) => _SubjectDialog(value: old),
    );
    if (result == null) return;
    setState(() {
      final list = currentSide ? _current : _prior;
      final i = old == null ? -1 : list.indexOf(old);
      if (i < 0) {
        list.add(result);
      } else {
        list[i] = result;
      }
    });
  }

  Future<void> _pickSubjects(bool currentSide) async {
    final list = currentSide ? _current : _prior;
    final catalog = currentSide ? widget.currentCatalog : widget.priorCatalog;
    final selected = await showDialog<List<Subject>>(
      context: context,
      builder: (_) => _SubjectPickerDialog(
        catalog: catalog,
        selected: list,
        onRemoveFromCurriculum: currentSide
            ? widget.removeCurrentSubject
            : null,
      ),
    );
    if (selected != null) {
      setState(
        () => list
          ..clear()
          ..addAll(selected),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.value == null ? 'Novo bloco' : 'Editar bloco'),
    content: SizedBox(
      width: 900,
      height: 500,
      child: Column(
        children: [
          TextField(
            controller: _period,
            decoration: const InputDecoration(
              labelText: 'Período no currículo atual (opcional)',
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: _side(
                    'Disciplinas do curso atual (destino)',
                    _current,
                    true,
                    widget.currentCatalog,
                  ),
                ),
                const VerticalDivider(),
                Expanded(
                  child: _side(
                    'Disciplinas cursadas (origem)',
                    _prior,
                    false,
                    widget.priorCatalog,
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
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          if (_current.isEmpty || _prior.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Inclua pelo menos uma disciplina em cada lado do bloco.',
                ),
              ),
            );
            return;
          }
          Navigator.pop(
            context,
            EquivalenceBlock(
              id:
                  widget.value?.id ??
                  DateTime.now().microsecondsSinceEpoch.toString(),
              period: _period.text.trim(),
              current: _current,
              prior: _prior,
            ),
          );
        },
        child: const Text('Aplicar bloco'),
      ),
    ],
  );
  Widget _side(
    String title,
    List<Subject> list,
    bool currentSide,
    List<Subject> catalog,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: Text(
                  'Nenhuma disciplina',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              )
            : ListView(
                children: list
                    .map(
                      (s) => ListTile(
                        dense: true,
                        title: Text(
                          '${s.code.isEmpty ? '' : '${s.code} - '}${s.name}',
                        ),
                        subtitle: Text(
                          '${s.theoretical} h teóricas + ${s.practical} h práticas = ${s.hours} h',
                        ),
                        onTap: () => _subject(currentSide, s),
                        trailing: IconButton(
                          onPressed: () => setState(() => list.remove(s)),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                    )
                    .toList(),
              ),
      ),
      OutlinedButton.icon(
        onPressed: () => _subject(currentSide),
        icon: const Icon(Icons.add),
        label: const Text('Cadastrar manualmente'),
      ),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: catalog.isEmpty ? null : () => _pickSubjects(currentSide),
        icon: const Icon(Icons.playlist_add_check),
        label: Text('Alocar do catálogo (${catalog.length})'),
      ),
    ],
  );
}

class _SubjectCatalogDialog extends StatefulWidget {
  const _SubjectCatalogDialog({
    required this.current,
    required this.prior,
    this.availableCurrent = const [],
  });
  final List<Subject> current, prior;
  final List<Subject> availableCurrent;

  @override
  State<_SubjectCatalogDialog> createState() => _SubjectCatalogDialogState();
}

class _SubjectCatalogDialogState extends State<_SubjectCatalogDialog> {
  late final _current = [...widget.current];
  late final _prior = [...widget.prior];

  Future<void> _edit(List<Subject> list, [Subject? old]) async {
    final subject = await showDialog<Subject>(
      context: context,
      builder: (_) => _SubjectDialog(value: old),
    );
    if (subject == null) return;
    setState(() {
      final i = old == null ? -1 : list.indexOf(old);
      if (i < 0) {
        list.add(subject);
      } else {
        list[i] = subject;
      }
      final normalized = mergeSubjects(list);
      list
        ..clear()
        ..addAll(normalized);
    });
  }

  Future<void> _selectFromCurriculum() async {
    if (widget.availableCurrent.isEmpty) return;
    final availableKeys = widget.availableCurrent
        .map(subjectCatalogKey)
        .toSet();
    final selectedFromCurriculum = await showDialog<List<Subject>>(
      context: context,
      builder: (_) => _SubjectPickerDialog(
        catalog: widget.availableCurrent,
        selected: _current
            .where((s) => availableKeys.contains(subjectCatalogKey(s)))
            .toList(),
        title: 'Selecionar disciplinas do currículo',
        applyLabel: 'Adicionar selecionadas',
        emptyMessage: 'O currículo selecionado não tem disciplinas importadas.',
      ),
    );
    if (selectedFromCurriculum == null) return;
    final manual = _current
        .where((s) => !availableKeys.contains(subjectCatalogKey(s)))
        .toList();
    setState(() {
      _current
        ..clear()
        ..addAll(mergeSubjects([...manual, ...selectedFromCurriculum]));
    });
  }

  Widget _side(
    String title,
    List<Subject> list, {
    bool destination = false,
  }) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(
              tooltip: 'Cadastrar disciplina manualmente',
              onPressed: () => _edit(list),
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                    'Nenhuma disciplina cadastrada',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final s = list[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${s.code.isEmpty ? 'Sem código' : s.code} - ${s.name}',
                      ),
                      subtitle: Text(
                        '${s.theoretical} h teóricas + ${s.practical} h práticas = ${s.hours} h',
                      ),
                      onTap: () => _edit(list, s),
                      trailing: IconButton(
                        tooltip: 'Remover do catálogo',
                        onPressed: () => setState(() => list.removeAt(i)),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    );
                  },
                ),
        ),
        if (destination && widget.availableCurrent.isNotEmpty) ...[
          OutlinedButton.icon(
            onPressed: _selectFromCurriculum,
            icon: const Icon(Icons.playlist_add_check),
            label: Text(
              'Selecionar do currículo (${widget.availableCurrent.length})',
            ),
          ),
          const SizedBox(height: 6),
        ],
        OutlinedButton.icon(
          onPressed: () => _edit(list),
          icon: const Icon(Icons.add),
          label: const Text('Cadastrar manualmente'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Disciplinas desta análise'),
    content: SizedBox(
      width: 920,
      height: 500,
      child: Row(
        children: [
          _side('Curso de destino', _current, destination: true),
          const VerticalDivider(width: 28),
          _side('Curso cursado (origem)', _prior),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (current: _current, prior: _prior)),
        child: const Text('Aplicar catálogo'),
      ),
    ],
  );
}

class _SubjectPickerDialog extends StatefulWidget {
  const _SubjectPickerDialog({
    required this.catalog,
    required this.selected,
    this.onRemoveFromCurriculum,
    this.title = 'Alocar disciplinas ao bloco',
    this.applyLabel = 'Aplicar ao bloco',
    this.emptyMessage = 'Nenhuma disciplina disponível no catálogo.',
  });
  final List<Subject> catalog, selected;
  final Future<void> Function(Subject subject)? onRemoveFromCurriculum;
  final String title, applyLabel, emptyMessage;

  @override
  State<_SubjectPickerDialog> createState() => _SubjectPickerDialogState();
}

class _SubjectPickerDialogState extends State<_SubjectPickerDialog> {
  late final Set<String> _selected = widget.selected.map(_key).toSet();
  late final List<Subject> _catalog = [...widget.catalog];
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  String _key(Subject s) =>
      '${s.code.trim().toLowerCase()}|${s.name.trim().toLowerCase()}';

  @override
  void dispose() {
    _search.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _removeFromCurriculum(Subject subject) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover disciplina do currículo?'),
        content: Text(
          '“${subject.name}” será removida do currículo e não aparecerá mais no catálogo de destino.',
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
    await widget.onRemoveFromCurriculum?.call(subject);
    if (!mounted) return;
    setState(() {
      final key = _key(subject);
      _catalog.removeWhere((item) => _key(item) == key);
      _selected.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 620,
      height: 480,
      child: Column(
        children: [
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar disciplina ou código',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_catalog.length} disciplinas no currículo · ${_visibleSubjects.length} exibidas',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _catalog.isEmpty
                ? Center(child: Text(widget.emptyMessage))
                : _visibleSubjects.isEmpty
                ? const Center(child: Text('Nenhuma disciplina encontrada.'))
                : Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    trackVisibility: true,
                    child: ListView.builder(
                      controller: _scrollController,
                      itemCount: _visibleSubjects.length,
                      itemBuilder: (_, i) {
                        final subject = _visibleSubjects[i];
                        final key = _key(subject);
                        return ListTile(
                          dense: true,
                          leading: Checkbox(
                            value: _selected.contains(key),
                            onChanged: (checked) => setState(() {
                              if (checked == true) {
                                _selected.add(key);
                              } else {
                                _selected.remove(key);
                              }
                            }),
                          ),
                          title: Text(
                            '${subject.code.isEmpty ? 'Sem código' : subject.code} - ${subject.name}',
                          ),
                          subtitle: Text(
                            '${subject.theoretical} h teóricas + ${subject.practical} h práticas = ${subject.hours} h',
                          ),
                          trailing: widget.onRemoveFromCurriculum == null
                              ? null
                              : IconButton(
                                  tooltip: 'Remover disciplina do currículo',
                                  onPressed: () =>
                                      _removeFromCurriculum(subject),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                        );
                      },
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
        onPressed: () => Navigator.pop(
          context,
          _catalog.where((s) => _selected.contains(_key(s))).toList(),
        ),
        child: Text(widget.applyLabel),
      ),
    ],
  );

  List<Subject> get _visibleSubjects {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _catalog;
    return _catalog
        .where(
          (subject) =>
              '${subject.code} ${subject.name}'.toLowerCase().contains(query),
        )
        .toList();
  }
}

class _SubjectDialog extends StatefulWidget {
  const _SubjectDialog({this.value});
  final Subject? value;
  @override
  State<_SubjectDialog> createState() => _SubjectDialogState();
}

class _SubjectDialogState extends State<_SubjectDialog> {
  late final _code = TextEditingController(text: widget.value?.code ?? ''),
      _name = TextEditingController(text: widget.value?.name ?? ''),
      _theory = TextEditingController(
        text: '${widget.value?.theoretical ?? 0}',
      ),
      _practice = TextEditingController(
        text: '${widget.value?.practical ?? 0}',
      );
  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _theory.dispose();
    _practice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.value == null ? 'Disciplina do bloco' : 'Editar disciplina',
    ),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Código'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nome *'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _theory,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'CH teórica'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _practice,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'CH prática'),
                ),
              ),
            ],
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
        onPressed: () {
          if (_name.text.trim().isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Informe o nome da disciplina.')),
            );
            return;
          }
          Navigator.pop(
            context,
            Subject(
              code: _code.text.trim(),
              name: _name.text.trim(),
              theoretical: int.tryParse(_theory.text) ?? 0,
              practical: int.tryParse(_practice.text) ?? 0,
            ),
          );
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}
