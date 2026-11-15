import 'package:flutter/material.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/_modelo/application/modelo_service.dart';
import 'package:gestor_ufu/modules/_modelo/domain/nota.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';

/// Tela do módulo. Usa o [ModuleScaffold] (Voltar · título · ações ·
/// Agente e Tema) e só cuida de interação: diálogos e seletores ficam aqui;
/// a regra fica no [ModeloService].
class ModeloPage extends StatefulWidget {
  const ModeloPage({required this.service, super.key});

  final ModeloService service;

  @override
  State<ModeloPage> createState() => _ModeloPageState();
}

class _ModeloPageState extends State<ModeloPage> {
  late Future<List<Nota>> _notas = widget.service.listar();

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_recarregar);
  }

  @override
  void dispose() {
    widget.service.removeListener(_recarregar);
    super.dispose();
  }

  void _recarregar() {
    if (mounted) setState(() => _notas = widget.service.listar());
  }

  Future<void> _adicionar() async {
    final controller = TextEditingController();
    final texto = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nova nota'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (texto == null) return;
    try {
      await widget.service.adicionar(texto);
    } on CommandException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) => ModuleScaffold(
    moduleId: 'modelo',
    actions: [
      FilledButton.icon(
        onPressed: _adicionar,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nova nota'),
      ),
    ],
    body: FutureBuilder<List<Nota>>(
      future: _notas,
      builder: (context, snapshot) {
        final notas = snapshot.data ?? const <Nota>[];
        if (notas.isEmpty) {
          return Center(
            child: Text(
              'Nenhuma nota.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            for (final nota in notas)
              ListTile(
                title: Text(nota.texto),
                trailing: IconButton(
                  tooltip: 'Remover',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => widget.service.remover(nota.id),
                ),
              ),
          ],
        );
      },
    ),
  );
}
