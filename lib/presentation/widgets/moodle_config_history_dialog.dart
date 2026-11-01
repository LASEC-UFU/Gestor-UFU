import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/domain/entities/course_config.dart';
import 'package:config_moodle/domain/entities/moodle_config_snapshot.dart';
import 'package:config_moodle/presentation/controllers/config_controller.dart';

class MoodleConfigHistoryDialog extends StatefulWidget {
  const MoodleConfigHistoryDialog({
    required this.config,
    required this.controller,
    super.key,
  });

  final CourseConfig config;
  final ConfigController controller;

  @override
  State<MoodleConfigHistoryDialog> createState() =>
      _MoodleConfigHistoryDialogState();
}

class _MoodleConfigHistoryDialogState extends State<MoodleConfigHistoryDialog> {
  List<MoodleConfigSnapshot> _snapshots = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snapshots = await widget.controller.getSnapshots(
      configId: widget.config.id,
    );
    if (!mounted) return;
    setState(() {
      _snapshots = snapshots;
      _loading = false;
    });
  }

  Future<void> _createManualBackup() async {
    final controller = TextEditingController(
      text: 'Backup ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
    );
    final label = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Salvar versão desta configuração'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome do backup',
            hintText: 'Ex.: Semestre 2025/2',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Salvar backup'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label == null) return;
    await widget.controller.createSnapshot(widget.config.id, label: label);
    await _load();
  }

  Future<void> _restore(MoodleConfigSnapshot snapshot) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restaurar esta versão?'),
        content: Text(
          'A configuração atual será substituída por “${snapshot.label}”. A versão atual será arquivada automaticamente antes da restauração.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restaurar versão'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await widget.controller.restoreSnapshot(snapshot.configId, snapshot.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppTheme.bgSurface,
    title: Row(
      children: [
        const Icon(Icons.history_rounded, color: AppTheme.accent),
        const SizedBox(width: 12),
        Expanded(child: Text('Histórico · ${widget.config.name}')),
      ],
    ),
    content: SizedBox(
      width: 650,
      height: 500,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'As versões automáticas são criadas antes de cada alteração. Você também pode nomear um backup para identificar o semestre.',
            style: TextStyle(color: AppTheme.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _createManualBackup,
              icon: const Icon(Icons.bookmark_add_rounded),
              label: const Text('Salvar versão agora'),
            ),
          ),
          const Divider(height: 24),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _snapshots.isEmpty
                ? Center(
                    child: Text(
                      'Nenhuma versão anterior ainda. Faça um backup nomeado ou altere a configuração para iniciar o histórico.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  )
                : ListView.separated(
                    itemCount: _snapshots.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: AppTheme.divider),
                    itemBuilder: (context, index) {
                      final snapshot = _snapshots[index];
                      final config = snapshot.toCourseConfig();
                      final activityCount = config.sections.fold<int>(
                        0,
                        (sum, section) => sum + section.activities.length,
                      );
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        leading: const CircleAvatar(
                          backgroundColor: Color(0x2236D6B2),
                          child: Icon(
                            Icons.history_rounded,
                            color: AppTheme.accent,
                          ),
                        ),
                        title: Text(
                          snapshot.label,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${DateFormat('dd/MM/yyyy HH:mm').format(snapshot.createdAt)} · semestre ${DateFormat('MM/yyyy').format(snapshot.semesterStartDate)} · ${config.sections.length} seções · $activityCount atividades',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Restaurar versão',
                          onPressed: () => _restore(snapshot),
                          icon: const Icon(
                            Icons.restore_rounded,
                            color: AppTheme.accent,
                          ),
                        ),
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
        child: const Text('Fechar'),
      ),
    ],
  );
}
