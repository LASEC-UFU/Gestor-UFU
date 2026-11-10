import 'dart:convert';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cadastro de currículos e análise de transferência por blocos curriculares.
class EquivalenciaAlunosPage extends StatefulWidget {
  const EquivalenciaAlunosPage({super.key});

  @override
  State<EquivalenciaAlunosPage> createState() => _EquivalenciaAlunosPageState();
}

class _EquivalenciaAlunosPageState extends State<EquivalenciaAlunosPage> {
  static const _key = 'student_equivalencies.blocks.v1';
  final _search = TextEditingController();
  List<_Case> _cases = [];
  List<_Curriculum> _curricula = [
    const _Curriculum(
      id: 'eca-2020',
      course: 'Engenharia de Controle e Automação',
      name: 'Currículo Proposto (2020/1)',
    ),
  ];
  String? _currentId = 'eca-2020';
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _curricula = (data['curricula'] as List? ?? const [])
            .map(
              (e) => _Curriculum.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        _curricula.removeWhere(
          (c) => c.id == 'eca-2013' || c.name == 'Currículo Anterior (2013/2)',
        );
        _cases = (data['cases'] as List? ?? const [])
            .map((e) => _Case.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _currentId = data['currentId'] as String?;
      } on Object {
        /* Mantém o catálogo inicial se o JSON estiver inválido. */
      }
    } else {
      // Migra análises simples da versão anterior para blocos de uma disciplina
      // em cada lado, sem apagar a chave original do SharedPreferences.
      final legacy = prefs.getString('student_equivalencies.v1');
      if (legacy != null) {
        try {
          final entries = jsonDecode(legacy) as List<dynamic>;
          for (final entry in entries) {
            final old = Map<String, dynamic>.from(entry as Map);
            final currentCourse = (old['destinationCourse'] as String? ?? '')
                .trim();
            String profile(String course, String suffix, String label) {
              final match = _curricula.where(
                (c) => c.course == course && c.name == label,
              );
              if (match.isNotEmpty) return match.first.id;
              final id =
                  'legacy-$suffix-${DateTime.now().microsecondsSinceEpoch}-${_curricula.length}';
              _curricula.add(
                _Curriculum(
                  id: id,
                  course: course.isEmpty ? 'Curso não informado' : course,
                  name: label,
                ),
              );
              return id;
            }

            final hoursText = (old['hours'] as String? ?? '0').trim();
            final hours = int.tryParse(hoursText) ?? 0;
            final currentId = profile(
              currentCourse,
              'current',
              'Currículo de destino',
            );
            _cases.add(
              _Case(
                id:
                    old['id'] as String? ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                student: old['student'] as String? ?? '',
                studentId: old['studentId'] as String? ?? '',
                currentCurriculumId: currentId,
                priorCurriculumId: '',
                status: old['status'] as String? ?? 'Em análise',
                notes: old['notes'] as String? ?? '',
                blocks: [
                  _Block(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    period: '',
                    current: [
                      _Subject(
                        code: '',
                        name: old['destinationSubject'] as String? ?? '',
                        theoretical: hours,
                        practical: 0,
                      ),
                    ],
                    prior: [
                      _Subject(
                        code: '',
                        name: old['sourceSubject'] as String? ?? '',
                        theoretical: hours,
                        practical: 0,
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
          if (_cases.isNotEmpty) await _persist();
        } on Object {
          // Um JSON legado inválido não impede o uso dos novos cadastros.
        }
      }
    }
    if (_curricula.isEmpty)
      _curricula = [
        const _Curriculum(
          id: 'eca-2020',
          course: 'Engenharia de Controle e Automação',
          name: 'Currículo Proposto (2020/1)',
        ),
      ];
    _currentId ??= _curricula.first.id;
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'curricula': _curricula.map((e) => e.toJson()).toList(),
        'cases': _cases.map((e) => e.toJson()).toList(),
        'currentId': _currentId,
      }),
    );
  }

  _Curriculum? _curriculum(String? id) {
    for (final c in _curricula) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _newCase({_Case? seed}) async {
    final draft =
        seed ??
        _Case(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          student: '',
          studentId: '',
          currentCurriculumId: _currentId!,
          priorCurriculumId: '',
          status: 'Em análise',
          notes: '',
          blocks: [],
        );
    final result = await showDialog<_Case>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CaseDialog(value: draft, curricula: _curricula),
    );
    if (result == null || !mounted) return;
    setState(() {
      final i = _cases.indexWhere((e) => e.id == result.id);
      if (i < 0) {
        _cases.insert(0, result);
      } else {
        _cases[i] = result;
      }
    });
    await _persist();
  }

  Future<void> _curriculumDialog() async {
    final result = await showDialog<List<_Curriculum>>(
      context: context,
      builder: (_) => _CurriculumDialog(initial: _curricula),
    );
    if (result == null || result.isEmpty || !mounted) return;
    setState(() {
      _curricula = result;
      if (!_curricula.any((e) => e.id == _currentId))
        _currentId = _curricula.first.id;
    });
    await _persist();
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
      final book = xls.Excel.decodeBytes(bytes);
      final sheet =
          book.tables['Equivalencia'] ??
          (book.tables.isNotEmpty ? book.tables.values.first : null);
      if (sheet == null)
        throw const FormatException('A planilha não contém uma aba legível.');
      String cell(int r, int c) {
        if (r >= sheet.maxRows || c >= sheet.maxColumns) return '';
        final v = sheet
            .cell(xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
            .value;
        return v?.toString().trim() ?? '';
      }

      // The workbook's merged Saldo cells identify multi-row blocks. Unmerged
      // course rows become individual blocks.
      final blockRows = <int, int>{};
      for (final span in sheet.spannedItems) {
        final match = RegExp(r'^G(\d+):G(\d+)$').firstMatch(span);
        if (match != null) {
          final start = int.parse(match.group(1)!) - 1;
          final end = int.parse(match.group(2)!) - 1;
          if (end >= 6) blockRows[start] = end;
        }
      }
      final starts = <int, int>{};
      for (var r = 6; r < sheet.maxRows; r++) {
        final hasCourse = [
          cell(r, 1),
          cell(r, 2),
          cell(r, 7),
          cell(r, 8),
        ].any((e) => e.isNotEmpty);
        if (!hasCourse) continue;
        final parent = blockRows.entries
            .where((e) => r >= e.key && r <= e.value)
            .map((e) => e.key)
            .firstOrNull;
        starts[parent ?? r] = blockRows[parent ?? r] ?? r;
      }
      final blocks = <_Block>[];
      for (final entry in starts.entries) {
        final left = <_Subject>[];
        final right = <_Subject>[];
        for (var r = entry.key; r <= entry.value; r++) {
          final curCode = cell(r, 1), curName = cell(r, 2);
          if (curCode.isNotEmpty || curName.isNotEmpty) {
            left.add(
              _Subject(
                code: curCode,
                name: curName,
                theoretical: _number(cell(r, 3)),
                practical: _number(cell(r, 4)),
              ),
            );
          }
          final oldCode = cell(r, 7), oldName = cell(r, 8);
          if (oldCode.isNotEmpty || oldName.isNotEmpty) {
            right.add(
              _Subject(
                code: oldCode,
                name: oldName,
                theoretical: _number(cell(r, 9)),
                practical: _number(cell(r, 10)),
              ),
            );
          }
        }
        if (left.isNotEmpty && right.isNotEmpty) {
          blocks.add(
            _Block(
              id:
                  DateTime.now().microsecondsSinceEpoch.toString() +
                  '${blocks.length}',
              period: cell(entry.key, 0),
              current: left,
              prior: right,
            ),
          );
        }
      }
      if (blocks.isEmpty)
        throw const FormatException(
          'Não encontrei blocos com disciplinas nos dois currículos. Confira se selecionou a planilha modelo.',
        );
      final student = cell(0, 0);
      final studentId = cell(1, 0);
      final imported = _Case(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        student: student,
        studentId: studentId,
        currentCurriculumId: _currentId!,
        priorCurriculumId: '',
        status: 'Em análise',
        notes: '',
        blocks: blocks,
      );
      await _newCase(seed: imported);
      if (mounted)
        _message(
          '${blocks.length} blocos importados. Revise os dados do aluno e as cargas horárias.',
        );
    } on Object catch (e) {
      _message('Falha ao importar: $e');
    }
  }

  int _number(String value) =>
      int.tryParse(value.replaceAll(',', '.').split('.').first) ?? 0;
  void _message(String text) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1800),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          onPressed: () => context.go('/'),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.compare_arrows_rounded,
                          color: AppTheme.accent,
                          size: 30,
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 480,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Equivalência de Alunos',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                'Análise de transferência por blocos curriculares',
                                style: TextStyle(color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        IntrinsicWidth(
                          child: OutlinedButton.icon(
                            onPressed: _curriculumDialog,
                            icon: const Icon(Icons.account_tree_outlined),
                            label: const Text('Currículos'),
                          ),
                        ),
                        IntrinsicWidth(
                          child: OutlinedButton.icon(
                            onPressed: _importWorkbook,
                            icon: const Icon(Icons.upload_file),
                            label: const Text('Importar planilha'),
                          ),
                        ),
                        IntrinsicWidth(
                          child: FilledButton.icon(
                            onPressed: () => _newCase(),
                            icon: const Icon(Icons.add),
                            label: const Text('Nova análise'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
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
                                    ? const Center(
                                        child: CircularProgressIndicator(),
                                      )
                                    : visible.isEmpty
                                    ? _empty()
                                    : ListView.separated(
                                        itemCount: visible.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(height: 10),
                                        itemBuilder: (context, i) =>
                                            _caseTile(visible[i]),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
            (v) => setState(() => _currentId = v),
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
    value: _curricula.any((c) => c.id == value) ? value : null,
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

  Widget _caseTile(_Case item) {
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
              tooltip: 'Abrir blocos',
              onPressed: () => _newCase(seed: item),
              icon: const Icon(Icons.edit_outlined),
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

class _Curriculum {
  const _Curriculum({
    required this.id,
    required this.course,
    required this.name,
    this.subjects = const [],
  });
  final String id, course, name;
  final List<_Subject> subjects;
  Map<String, dynamic> toJson() => {
    'id': id,
    'course': course,
    'name': name,
    'subjects': subjects.map((e) => e.toJson()).toList(),
  };
  factory _Curriculum.fromJson(Map<String, dynamic> j) => _Curriculum(
    id: j['id'] ?? '',
    course: j['course'] ?? '',
    name: j['name'] ?? '',
    subjects: (j['subjects'] as List? ?? const [])
        .map((e) => _Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class _Subject {
  const _Subject({
    required this.code,
    required this.name,
    required this.theoretical,
    required this.practical,
  });
  final String code, name;
  final int theoretical, practical;
  int get hours => theoretical + practical;
  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'theoretical': theoretical,
    'practical': practical,
  };
  factory _Subject.fromJson(Map<String, dynamic> j) => _Subject(
    code: j['code'] ?? '',
    name: j['name'] ?? '',
    theoretical: j['theoretical'] ?? 0,
    practical: j['practical'] ?? 0,
  );
}

class _Block {
  const _Block({
    required this.id,
    required this.period,
    required this.current,
    required this.prior,
  });
  final String id, period;
  final List<_Subject> current, prior;
  int get currentHours => current.fold(0, (sum, s) => sum + s.hours);
  int get priorHours => prior.fold(0, (sum, s) => sum + s.hours);
  Map<String, dynamic> toJson() => {
    'id': id,
    'period': period,
    'current': current.map((e) => e.toJson()).toList(),
    'prior': prior.map((e) => e.toJson()).toList(),
  };
  factory _Block.fromJson(Map<String, dynamic> j) => _Block(
    id: j['id'] ?? '',
    period: j['period'] ?? '',
    current: (j['current'] as List? ?? const [])
        .map((e) => _Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    prior: (j['prior'] as List? ?? const [])
        .map((e) => _Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class _Case {
  const _Case({
    required this.id,
    required this.student,
    required this.studentId,
    required this.currentCurriculumId,
    required this.priorCurriculumId,
    required this.status,
    required this.notes,
    required this.blocks,
    this.currentCatalog = const [],
    this.priorCatalog = const [],
  });
  final String id,
      student,
      studentId,
      currentCurriculumId,
      priorCurriculumId,
      status,
      notes;
  final List<_Block> blocks;
  final List<_Subject> currentCatalog, priorCatalog;
  Map<String, dynamic> toJson() => {
    'id': id,
    'student': student,
    'studentId': studentId,
    'currentCurriculumId': currentCurriculumId,
    'priorCurriculumId': priorCurriculumId,
    'status': status,
    'notes': notes,
    'blocks': blocks.map((e) => e.toJson()).toList(),
    'currentCatalog': currentCatalog.map((e) => e.toJson()).toList(),
    'priorCatalog': priorCatalog.map((e) => e.toJson()).toList(),
  };
  factory _Case.fromJson(Map<String, dynamic> j) {
    final blocks = (j['blocks'] as List? ?? const [])
        .map((e) => _Block.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    List<_Subject> catalog(String key, bool current) {
      final stored = j[key] as List?;
      final values = stored == null
          ? blocks.expand((b) => current ? b.current : b.prior).toList()
          : stored
                .map((e) => _Subject.fromJson(Map<String, dynamic>.from(e)))
                .toList();
      final unique = <String, _Subject>{};
      for (final subject in values) {
        unique['${subject.code.trim().toLowerCase()}|${subject.name.trim().toLowerCase()}'] =
            subject;
      }
      return unique.values.toList();
    }

    return _Case(
      id: j['id'] ?? '',
      student: j['student'] ?? '',
      studentId: j['studentId'] ?? '',
      currentCurriculumId: j['currentCurriculumId'] ?? '',
      priorCurriculumId: '',
      status: j['status'] ?? 'Em análise',
      notes: j['notes'] ?? '',
      blocks: blocks,
      currentCatalog: catalog('currentCatalog', true),
      priorCatalog: catalog('priorCatalog', false),
    );
  }
}

class _CurriculumDialog extends StatefulWidget {
  const _CurriculumDialog({required this.initial});
  final List<_Curriculum> initial;
  @override
  State<_CurriculumDialog> createState() => _CurriculumDialogState();
}

class _CurriculumDialogState extends State<_CurriculumDialog> {
  late final List<_Curriculum> _items = [...widget.initial];
  final _course = TextEditingController(), _name = TextEditingController();
  List<_Subject> _subjects = [];
  @override
  void dispose() {
    _course.dispose();
    _name.dispose();
    super.dispose();
  }

  void _add() {
    if (_course.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    setState(() {
      _items.add(
        _Curriculum(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          course: _course.text.trim(),
          name: _name.text.trim(),
          subjects: List.of(_subjects),
        ),
      );
      _course.clear();
      _name.clear();
      _subjects = [];
    });
  }

  Future<void> _importSubjects() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Importar disciplinas do currículo',
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xlsm'],
      withData: true,
    );
    if (picked == null) return;
    final bytes = picked.files.single.bytes;
    if (bytes == null) {
      _notice('Não foi possível ler o arquivo selecionado.');
      return;
    }
    try {
      final book = xls.Excel.decodeBytes(bytes);
      List<_Subject>? parsed;
      for (final sheet in book.tables.values) {
        String value(int r, int c) {
          if (r >= sheet.maxRows || c >= sheet.maxColumns) return '';
          return sheet
                  .cell(
                    xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
                  )
                  .value
                  ?.toString()
                  .trim() ??
              '';
        }

        String norm(String s) => s
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
        for (
          var headerRow = 0;
          headerRow < sheet.maxRows && headerRow < 30;
          headerRow++
        ) {
          final columnsByKey = <String, int>{};
          for (var c = 0; c < sheet.maxColumns; c++) {
            final key = norm(value(headerRow, c));
            if (key.isNotEmpty) columnsByKey.putIfAbsent(key, () => c);
          }
          int column(List<String> keys) {
            for (final key in keys) {
              final index = columnsByKey[key];
              if (index != null) return index;
            }
            return -1;
          }

          // Resolve source fields by header key; column order is irrelevant.
          final codeKey = column([
            'codigodisciplina',
            'coddisc',
            'coddisciplina',
            'codigocomponente',
            'codigo',
            'codcomponente',
            'codcomponenteorganizacional',
            'sigla',
          ]);
          final nameKey = column([
            'nomedisciplina',
            'disciplina',
            'nomecomponente',
            'componente',
            'nomedocomponente',
          ]);
          if (nameKey < 0) continue;
          final theorKey = column([
            'chteorica',
            'cargahorariateorica',
            'horasteoricas',
            'ch',
          ]);
          final pracKey = column([
            'chpratica',
            'cargahorariapratica',
            'horaspraticas',
          ]);
          final typeKey = column([
            'tipo',
            'natureza',
            'categoria',
            'classificacao',
          ]);
          Map<String, String> rowByKey(int rowIndex) => {
            for (final entry in columnsByKey.entries)
              entry.key: value(rowIndex, entry.value),
          };
          String number(String raw) => raw
              .replaceAll(',', '.')
              .replaceAll(RegExp(r'[^0-9.]'), '')
              .split('.')
              .first;
          final result = <_Subject>[];
          for (var r = headerRow + 1; r < sheet.maxRows; r++) {
            final row = rowByKey(r);
            String field(int key) => key < 0
                ? ''
                : row[columnsByKey.entries
                          .firstWhere((entry) => entry.value == key)
                          .key] ??
                      '';
            final subjectName = field(nameKey);
            if (subjectName.isEmpty) continue;
            final details = '$subjectName ${field(typeKey)}'.toLowerCase();
            if (RegExp(
              r'equival|est[aá]gio|atividade complementar|optativa',
            ).hasMatch(details))
              continue;
            final code = field(codeKey);
            if (code.isEmpty && subjectName.toLowerCase().contains('total'))
              continue;
            result.add(
              _Subject(
                code: code,
                name: subjectName,
                theoretical: int.tryParse(number(field(theorKey))) ?? 0,
                practical: int.tryParse(number(field(pracKey))) ?? 0,
              ),
            );
          }
          if (result.isNotEmpty) {
            parsed = result;
            break;
          }
        }
        if (parsed != null) break;
      }
      if (parsed == null)
        throw const FormatException(
          'Não encontrei colunas de disciplina e nome. Confira se a planilha contém o código/nome das disciplinas.',
        );
      setState(() => _subjects = _mergeSubjects(parsed!));
      _notice(
        '${_subjects.length} disciplinas importadas. Equivalências automáticas, estágio, atividades complementares e optativas foram ignoradas.',
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
                    ? 'Carregar disciplinas da planilha'
                    : 'Planilha carregada · ${_subjects.length} disciplinas',
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Adicionar currículo'),
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
                      trailing: IconButton(
                        onPressed: () => setState(() => _items.remove(c)),
                        icon: const Icon(Icons.delete_outline),
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
  const _CaseDialog({required this.value, required this.curricula});
  final _Case value;
  final List<_Curriculum> curricula;
  @override
  State<_CaseDialog> createState() => _CaseDialogState();
}

class _CaseDialogState extends State<_CaseDialog> {
  late final _student = TextEditingController(text: widget.value.student),
      _id = TextEditingController(text: widget.value.studentId),
      _notes = TextEditingController(text: widget.value.notes);
  late String _current = widget.value.currentCurriculumId,
      _status = widget.value.status;
  late List<_Block> _blocks = [...widget.value.blocks];
  late final List<_Subject> _currentCatalog = _mergeSubjects([
    ...?widget.curricula
        .where((c) => c.id == widget.value.currentCurriculumId)
        .firstOrNull
        ?.subjects,
    ...widget.value.currentCatalog,
    ...widget.value.blocks.expand((b) => b.current),
  ]);
  late final List<_Subject> _priorCatalog = _mergeSubjects([
    ...widget.value.priorCatalog,
    ...widget.value.blocks.expand((b) => b.prior),
  ]);
  @override
  void dispose() {
    _student.dispose();
    _id.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _block([_Block? old]) async {
    final value = await showDialog<_Block>(
      context: context,
      builder: (_) => _BlockDialog(
        value: old,
        currentCatalog: _mergeSubjects([
          ..._currentCatalog,
          ...?widget.curricula
              .where((c) => c.id == _current)
              .firstOrNull
              ?.subjects,
        ]),
        priorCatalog: _priorCatalog,
      ),
    );
    if (value != null)
      setState(() {
        _addSubjects(_currentCatalog, value.current);
        _addSubjects(_priorCatalog, value.prior);
        final i = _blocks.indexWhere((b) => b.id == value.id);
        if (i < 0)
          _blocks.add(value);
        else
          _blocks[i] = value;
      });
  }

  Future<void> _manageCatalog() async {
    final result =
        await showDialog<({List<_Subject> current, List<_Subject> prior})>(
          context: context,
          builder: (_) => _SubjectCatalogDialog(
            current: _currentCatalog,
            prior: _priorCatalog,
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
    Navigator.pop(
      context,
      _Case(
        id: widget.value.id,
        student: _student.text.trim(),
        studentId: _id.text.trim(),
        currentCurriculumId: _current,
        priorCurriculumId: '',
        status: _status,
        notes: _notes.text.trim(),
        blocks: _blocks,
        currentCatalog: _mergeSubjects([
          ..._currentCatalog,
          ...?widget.curricula
              .where((c) => c.id == _current)
              .firstOrNull
              ?.subjects,
        ]),
        priorCatalog: _priorCatalog,
      ),
    );
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
                    value: _current,
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

  Widget _blockCard(_Block b, int index) {
    final ok = b.currentHours >= b.priorHours;
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
                  '${b.currentHours} h destino  ≥  ${b.priorHours} h cursado',
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                IconButton(
                  onPressed: () => _block(b),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  onPressed: () => setState(() => _blocks.remove(b)),
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
                  'Carga do destino inferior em ${b.priorHours - b.currentHours} h; este bloco ainda não atende ao critério de transferência.',
                  style: TextStyle(color: AppTheme.danger, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _subjectColumn(String label, List<_Subject> subjects) => Column(
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
  });
  final _Block? value;
  final List<_Subject> currentCatalog, priorCatalog;
  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  late final _period = TextEditingController(text: widget.value?.period ?? '');
  late List<_Subject> _current = [...?widget.value?.current],
      _prior = [...?widget.value?.prior];
  @override
  void dispose() {
    _period.dispose();
    super.dispose();
  }

  Future<void> _subject(bool currentSide, [_Subject? old]) async {
    final result = await showDialog<_Subject>(
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
    final selected = await showDialog<List<_Subject>>(
      context: context,
      builder: (_) => _SubjectPickerDialog(catalog: catalog, selected: list),
    );
    if (selected != null)
      setState(
        () => list
          ..clear()
          ..addAll(selected),
      );
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
            _Block(
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
    List<_Subject> list,
    bool currentSide,
    List<_Subject> catalog,
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

List<_Subject> _mergeSubjects(Iterable<_Subject> subjects) {
  final result = <String, _Subject>{};
  for (final subject in subjects) {
    final key =
        '${subject.code.trim().toLowerCase()}|${subject.name.trim().toLowerCase()}';
    result[key] = subject;
  }
  return result.values.toList();
}

void _addSubjects(List<_Subject> catalog, Iterable<_Subject> subjects) {
  final merged = _mergeSubjects([...catalog, ...subjects]);
  catalog
    ..clear()
    ..addAll(merged);
}

class _SubjectCatalogDialog extends StatefulWidget {
  const _SubjectCatalogDialog({required this.current, required this.prior});
  final List<_Subject> current, prior;

  @override
  State<_SubjectCatalogDialog> createState() => _SubjectCatalogDialogState();
}

class _SubjectCatalogDialogState extends State<_SubjectCatalogDialog> {
  late final _current = [...widget.current];
  late final _prior = [...widget.prior];

  Future<void> _edit(List<_Subject> list, [_Subject? old]) async {
    final subject = await showDialog<_Subject>(
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
      final normalized = _mergeSubjects(list);
      list
        ..clear()
        ..addAll(normalized);
    });
  }

  Widget _side(String title, List<_Subject> list) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(
              tooltip: 'Cadastrar disciplina',
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
        OutlinedButton.icon(
          onPressed: () => _edit(list),
          icon: const Icon(Icons.add),
          label: const Text('Adicionar disciplina'),
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
          _side('Curso de destino', _current),
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
  const _SubjectPickerDialog({required this.catalog, required this.selected});
  final List<_Subject> catalog, selected;

  @override
  State<_SubjectPickerDialog> createState() => _SubjectPickerDialogState();
}

class _SubjectPickerDialogState extends State<_SubjectPickerDialog> {
  late final Set<String> _selected = widget.selected.map(_key).toSet();
  String _key(_Subject s) =>
      '${s.code.trim().toLowerCase()}|${s.name.trim().toLowerCase()}';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Alocar disciplinas ao bloco'),
    content: SizedBox(
      width: 620,
      height: 480,
      child: widget.catalog.isEmpty
          ? const Center(
              child: Text('Cadastre disciplinas no catálogo desta análise.'),
            )
          : ListView.builder(
              itemCount: widget.catalog.length,
              itemBuilder: (_, i) {
                final subject = widget.catalog[i];
                final key = _key(subject);
                return CheckboxListTile(
                  value: _selected.contains(key),
                  title: Text(
                    '${subject.code.isEmpty ? 'Sem código' : subject.code} - ${subject.name}',
                  ),
                  subtitle: Text(
                    '${subject.theoretical} h teóricas + ${subject.practical} h práticas = ${subject.hours} h',
                  ),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(key);
                    } else {
                      _selected.remove(key);
                    }
                  }),
                );
              },
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
          widget.catalog.where((s) => _selected.contains(_key(s))).toList(),
        ),
        child: const Text('Aplicar ao bloco'),
      ),
    ],
  );
}

class _SubjectDialog extends StatefulWidget {
  const _SubjectDialog({this.value});
  final _Subject? value;
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
            _Subject(
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
