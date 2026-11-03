import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:config_moodle/core/theme/app_theme.dart';

/// Organiza análises de equivalência curricular sem depender de uma base externa.
class EquivalenciaAlunosPage extends StatefulWidget {
  const EquivalenciaAlunosPage({super.key});

  @override
  State<EquivalenciaAlunosPage> createState() => _EquivalenciaAlunosPageState();
}

class _EquivalenciaAlunosPageState extends State<EquivalenciaAlunosPage> {
  static const _storageKey = 'student_equivalencies.v1';
  final _searchController = TextEditingController();
  List<_EquivalencyRecord> _records = [];
  bool _loading = true;
  String _filter = 'Todas';

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _records = list
            .map(
              (item) => _EquivalencyRecord.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
      } on Object {
        _records = [];
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(_records.map((record) => record.toJson()).toList()),
    );
  }

  Future<void> _edit([_EquivalencyRecord? existing]) async {
    final result = await showDialog<_EquivalencyRecord>(
      context: context,
      builder: (_) => _EquivalencyDialog(existing: existing),
    );
    if (result == null || !mounted) return;
    setState(() {
      final index = _records.indexWhere((record) => record.id == result.id);
      if (index < 0) {
        _records.insert(0, result);
      } else {
        _records[index] = result;
      }
    });
    await _persist();
  }

  Future<void> _delete(_EquivalencyRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover análise?'),
        content: Text('A análise de ${record.student} será removida.'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _records.removeWhere((item) => item.id == record.id));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final visible = _records.where((record) {
      final matchesFilter = _filter == 'Todas' || record.status == _filter;
      final text = [
        record.student,
        record.studentId,
        record.sourceCourse,
        record.destinationCourse,
        record.sourceSubject,
        record.destinationSubject,
      ].join(' ').toLowerCase();
      return matchesFilter && (query.isEmpty || text.contains(query));
    }).toList();
    final pending = _records.where((item) => item.status == 'Pendente').length;
    final approved = _records.where((item) => item.status == 'Deferida').length;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Column(
            children: [
              _Header(onAdd: _edit),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1420),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _MetricCard(
                                  icon: Icons.people_alt_outlined,
                                  label: 'Análises registradas',
                                  value: '${_records.length}',
                                  accent: AppTheme.primary,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _MetricCard(
                                  icon: Icons.pending_actions_rounded,
                                  label: 'Pendentes',
                                  value: '$pending',
                                  accent: AppTheme.warning,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _MetricCard(
                                  icon: Icons.task_alt_rounded,
                                  label: 'Deferidas',
                                  value: '$approved',
                                  accent: AppTheme.green,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: AppTheme.cardGradient,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(color: AppTheme.divider),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final narrow =
                                            constraints.maxWidth < 760;
                                        final search = TextField(
                                          controller: _searchController,
                                          decoration: const InputDecoration(
                                            prefixIcon: Icon(Icons.search),
                                            hintText:
                                                'Buscar aluno, curso ou disciplina',
                                          ),
                                        );
                                        final filters = Wrap(
                                          spacing: 8,
                                          children:
                                              [
                                                    'Todas',
                                                    'Pendente',
                                                    'Deferida',
                                                    'Indeferida',
                                                  ]
                                                  .map(
                                                    (option) => ChoiceChip(
                                                      label: Text(option),
                                                      selected:
                                                          _filter == option,
                                                      onSelected: (_) =>
                                                          setState(
                                                            () => _filter =
                                                                option,
                                                          ),
                                                    ),
                                                  )
                                                  .toList(),
                                        );
                                        if (narrow) {
                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              search,
                                              const SizedBox(height: 12),
                                              filters,
                                            ],
                                          );
                                        }
                                        return Row(
                                          children: [
                                            Expanded(child: search),
                                            const SizedBox(width: 16),
                                            filters,
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                  Divider(height: 1, color: AppTheme.divider),
                                  Expanded(
                                    child: _loading
                                        ? const Center(
                                            child: CircularProgressIndicator(),
                                          )
                                        : visible.isEmpty
                                        ? _EmptyState(
                                            hasRecords: _records.isNotEmpty,
                                            onAdd: _edit,
                                          )
                                        : ListView.separated(
                                            padding: const EdgeInsets.all(16),
                                            itemCount: visible.length,
                                            separatorBuilder: (_, _) =>
                                                const SizedBox(height: 10),
                                            itemBuilder: (context, index) {
                                              final item = visible[index];
                                              return _RecordTile(
                                                record: item,
                                                onEdit: () => _edit(item),
                                                onDelete: () => _delete(item),
                                              );
                                            },
                                          ),
                                  ),
                                ],
                              ),
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
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 18, 28, 8),
    child: Row(
      children: [
        IconButton(
          tooltip: 'Voltar',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 8),
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF63C9B8).withAlpha(35),
            borderRadius: BorderRadius.circular(15),
          ),
          child: const Icon(
            Icons.compare_arrows_rounded,
            color: Color(0xFF63C9B8),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Equivalência de Alunos',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                'ANÁLISE DE APROVEITAMENTO CURRICULAR',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nova análise'),
        ),
      ],
    ),
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      gradient: AppTheme.cardGradient,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Row(
      children: [
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: accent.withAlpha(28),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });
  final _EquivalencyRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (record.status) {
      'Deferida' => AppTheme.green,
      'Indeferida' => AppTheme.danger,
      _ => AppTheme.warning,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      decoration: BoxDecoration(
        color: AppTheme.bgCardAlt.withAlpha(AppTheme.isLight ? 190 : 110),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: statusColor.withAlpha(25),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.school_outlined, color: statusColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      record.student,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (record.studentId.isNotEmpty)
                      Text(
                        'Matrícula ${record.studentId}',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    _StatusBadge(text: record.status, color: statusColor),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  '${record.sourceSubject}  →  ${record.destinationSubject}',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                ),
                const SizedBox(height: 3),
                Text(
                  '${record.sourceCourse}  →  ${record.destinationCourse}  ·  ${record.hours} h',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                if (record.notes.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    record.notes,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Editar',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Remover',
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline_rounded, color: AppTheme.danger),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withAlpha(22),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withAlpha(70)),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasRecords, required this.onAdd});
  final bool hasRecords;
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasRecords
                ? Icons.search_off_rounded
                : Icons.compare_arrows_rounded,
            size: 48,
            color: AppTheme.textSecondary.withAlpha(150),
          ),
          const SizedBox(height: 14),
          Text(
            hasRecords
                ? 'Nenhuma análise encontrada'
                : 'Nenhuma análise cadastrada',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            hasRecords
                ? 'Altere a busca ou o filtro para ver outros registros.'
                : 'Cadastre o aluno e compare a disciplina cursada com a disciplina de destino.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          if (!hasRecords) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Criar primeira análise'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _EquivalencyDialog extends StatefulWidget {
  const _EquivalencyDialog({this.existing});
  final _EquivalencyRecord? existing;
  @override
  State<_EquivalencyDialog> createState() => _EquivalencyDialogState();
}

class _EquivalencyDialogState extends State<_EquivalencyDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _student = TextEditingController(
    text: widget.existing?.student ?? '',
  );
  late final _studentId = TextEditingController(
    text: widget.existing?.studentId ?? '',
  );
  late final _sourceCourse = TextEditingController(
    text: widget.existing?.sourceCourse ?? '',
  );
  late final _destinationCourse = TextEditingController(
    text: widget.existing?.destinationCourse ?? '',
  );
  late final _sourceSubject = TextEditingController(
    text: widget.existing?.sourceSubject ?? '',
  );
  late final _destinationSubject = TextEditingController(
    text: widget.existing?.destinationSubject ?? '',
  );
  late final _hours = TextEditingController(text: widget.existing?.hours ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late String _status = widget.existing?.status ?? 'Pendente';

  @override
  void dispose() {
    for (final controller in [
      _student,
      _studentId,
      _sourceCourse,
      _destinationCourse,
      _sourceSubject,
      _destinationSubject,
      _hours,
      _notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Preencha este campo.' : null;

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final old = widget.existing;
    Navigator.pop(
      context,
      _EquivalencyRecord(
        id: old?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        student: _student.text.trim(),
        studentId: _studentId.text.trim(),
        sourceCourse: _sourceCourse.text.trim(),
        destinationCourse: _destinationCourse.text.trim(),
        sourceSubject: _sourceSubject.text.trim(),
        destinationSubject: _destinationSubject.text.trim(),
        hours: _hours.text.trim(),
        status: _status,
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null
          ? 'Nova análise de equivalência'
          : 'Editar análise',
    ),
    content: SizedBox(
      width: 620,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            children: [
              _field(_student, 'Nome do aluno', validator: _required),
              const SizedBox(height: 12),
              _field(_studentId, 'Matrícula (opcional)'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _sourceCourse,
                      'Curso de origem',
                      validator: _required,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _destinationCourse,
                      'Curso de destino',
                      validator: _required,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _sourceSubject,
                      'Disciplina cursada',
                      validator: _required,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _destinationSubject,
                      'Disciplina equivalente',
                      validator: _required,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _hours,
                      'Carga horária (h)',
                      validator: _required,
                      keyboard: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: const InputDecoration(labelText: 'Situação'),
                      items: const ['Pendente', 'Deferida', 'Indeferida']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _status = value ?? 'Pendente'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _field(_notes, 'Observações / justificativa', maxLines: 3),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton.icon(
        onPressed: _save,
        icon: const Icon(Icons.save_outlined),
        label: const Text('Salvar análise'),
      ),
    ],
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? Function(String?)? validator,
    int maxLines = 1,
    TextInputType? keyboard,
  }) => TextFormField(
    controller: controller,
    validator: validator,
    maxLines: maxLines,
    keyboardType: keyboard,
    decoration: InputDecoration(labelText: label),
  );
}

class _EquivalencyRecord {
  const _EquivalencyRecord({
    required this.id,
    required this.student,
    required this.studentId,
    required this.sourceCourse,
    required this.destinationCourse,
    required this.sourceSubject,
    required this.destinationSubject,
    required this.hours,
    required this.status,
    required this.notes,
  });
  final String id;
  final String student;
  final String studentId;
  final String sourceCourse;
  final String destinationCourse;
  final String sourceSubject;
  final String destinationSubject;
  final String hours;
  final String status;
  final String notes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'student': student,
    'studentId': studentId,
    'sourceCourse': sourceCourse,
    'destinationCourse': destinationCourse,
    'sourceSubject': sourceSubject,
    'destinationSubject': destinationSubject,
    'hours': hours,
    'status': status,
    'notes': notes,
  };

  factory _EquivalencyRecord.fromJson(Map<String, dynamic> json) =>
      _EquivalencyRecord(
        id: json['id'] as String? ?? '',
        student: json['student'] as String? ?? '',
        studentId: json['studentId'] as String? ?? '',
        sourceCourse: json['sourceCourse'] as String? ?? '',
        destinationCourse: json['destinationCourse'] as String? ?? '',
        sourceSubject: json['sourceSubject'] as String? ?? '',
        destinationSubject: json['destinationSubject'] as String? ?? '',
        hours: json['hours'] as String? ?? '',
        status: json['status'] as String? ?? 'Pendente',
        notes: json['notes'] as String? ?? '',
      );
}
