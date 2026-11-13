import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gestor_ufu/domain/entities/academic_term.dart';

class AcademicTermDialog {
  static Future<String?> show(BuildContext context) async {
    final now = DateTime.now();
    final yearController = TextEditingController(text: '${now.year}');
    var semester = now.month <= 6 ? 1 : 2;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final year = int.tryParse(yearController.text);
          final validYear = year != null && year >= 1900 && year <= 9999;
          return AlertDialog(
            title: const Text('Novo período letivo'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: yearController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Ano',
                      hintText: '2026',
                      counterText: '',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: semester,
                    decoration: const InputDecoration(labelText: 'Semestre'),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1º semestre')),
                      DropdownMenuItem(value: 2, child: Text('2º semestre')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => semester = value);
                      }
                    },
                  ),
                  if (validYear) ...[
                    const SizedBox(height: 14),
                    Text('Será salvo como ${year}_$semester'),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: validYear
                    ? () => Navigator.pop(
                        dialogContext,
                        AcademicTerm(year: year, semester: semester).key,
                      )
                    : null,
                child: const Text('Criar e usar'),
              ),
            ],
          );
        },
      ),
    );
    yearController.dispose();
    return result;
  }
}
