import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/planos_trabalho/application/planos_trabalho_commands.dart';
import 'package:gestor_ufu/modules/planos_trabalho/data/planos_trabalho_store.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

void main() {
  late Map<String, ModuleCommand> commands;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    commands = {
      for (final c in planosTrabalhoCommands(
        PlanosTrabalhoStore(),
        SeiAutomationService(),
      ))
        c.id: c,
    };
  });

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  test('cadastro valida regras e lista', () async {
    expect(
      () => run('planosTrabalho.salvarCadastro', {'nome': 'Plano 2026'}),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'code', 'entrada_invalida'),
      ),
    );
    final saved = await run('planosTrabalho.salvarCadastro', {
      'nome': 'Plano 2026',
      'numero': '23117.000001/2026-01',
    });
    final listed = await run('planosTrabalho.listar', {});
    expect((listed.data['planos'] as List).single['id'], saved.data['id']);
  });

  test('alterar campo sem planilha importada tem código estável', () async {
    final saved = await run('planosTrabalho.salvarCadastro', {
      'nome': 'P',
      'nomeArvore': 'Plano',
    });
    expect(
      () => run('planosTrabalho.definirCampo', {
        'id': saved.data['id'],
        'section': 'aulas',
        'cell': 'C15',
        'value': 4,
      }),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'campo_nao_encontrado',
        ),
      ),
    );
  });

  test('inserir no SEI exige aprovação e o PDF', () async {
    final saved = await run('planosTrabalho.salvarCadastro', {
      'nome': 'P',
      'nomeArvore': 'Plano',
    });
    expect(
      commands['planosTrabalho.inserirNoSei']!.approval,
      CommandApproval.required,
    );
    expect(
      () => run('planosTrabalho.inserirNoSei', {'id': saved.data['id']}),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'pdf_nao_encontrado',
        ),
      ),
    );
  });
}
