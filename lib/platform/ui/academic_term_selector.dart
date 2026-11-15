import 'package:flutter/material.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/domain/entities/academic_term.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/ui/academic_term_dialog.dart';

/// Chamado depois que um período novo é criado pelo seletor (ex.: o Ajusta
/// Horários pergunta se copia a grade de outro período).
typedef AcademicTermCreated =
    Future<void> Function(BuildContext context, String term);

/// Seletor de período letivo do cabeçalho padrão, igual em todos os módulos:
/// mostra o período em uso e abre o diálogo "Períodos letivos".
class AcademicTermSelector extends StatelessWidget {
  const AcademicTermSelector({
    required this.service,
    this.onCreated,
    super.key,
  });

  final AcademicTermService service;
  final AcademicTermCreated? onCreated;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => Tooltip(
      message: 'Período letivo',
      child: InkWell(
        onTap: () =>
            showAcademicTermPicker(context, service, onCreated: onCreated),
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
                service.active.isEmpty
                    ? 'Período letivo'
                    : AcademicTerm.displayName(service.active),
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
    ),
  );
}

/// Diálogo "Períodos letivos": escolher o período em uso ou criar um novo.
Future<void> showAcademicTermPicker(
  BuildContext context,
  AcademicTermService service, {
  AcademicTermCreated? onCreated,
}) async {
  const createNew = '__create_new_academic_term__';
  final terms = service.terms;
  final selected = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Períodos letivos'),
      content: SizedBox(
        width: 440,
        height: 360,
        child: ListView.separated(
          itemCount: terms.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = terms[index];
            final active = item == service.active;
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
  if (selected != createNew) {
    await service.setActive(selected);
    return;
  }
  if (!context.mounted) return;
  final name = (await AcademicTermDialog.show(context))?.trim() ?? '';
  if (name.isEmpty) return;
  final before = service.terms.toSet();
  final created = await service.create(name);
  if (!before.contains(created) && onCreated != null && context.mounted) {
    await onCreated(context, created);
  }
}
