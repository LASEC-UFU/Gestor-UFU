import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/planos_ensino/application/planos_ensino_commands.dart';
import 'package:gestor_ufu/modules/planos_ensino/application/planos_ensino_service.dart';
import 'package:gestor_ufu/modules/planos_ensino/data/planos_ensino_automation_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

void main() {
  late Directory dir;
  late Map<String, ModuleCommand> commands;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('planos_ensino_cmd');
    commands = {
      for (final c in planosEnsinoCommands(
        PlanosEnsinoService(),
        PlanosEnsinoAutomationService(),
        () => null,
      ))
        c.id: c,
    };
  });

  tearDown(() => dir.delete(recursive: true));

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  test('salva, aplica cronograma colado, exporta Word e backup', () async {
    final saved = await run('planosEnsino.salvar', {
      'plano': {
        'identificacao': {'nome': 'Circuitos I', 'codigo': 'FEELT31201'},
        'ementa': 'Ementa…',
      },
    });
    final id = saved.data['id'] as String;
    expect(saved.data['faltando'], contains('Justificativa'));
    await run('planosEnsino.aplicarCronograma', {
      'id': id,
      'texto':
          'Data\tModalidade\tMatéria Lecionada\n'
          '05/03/2026\tTeórica\tApresentação\n'
          '06/03/2026\tPrática\tLaboratório 1',
    });
    final listed = await run('planosEnsino.listar', {'id': id});
    final plano = listed.data['plano'] as Map;
    expect((plano['cronograma_teorico'] as List), hasLength(1));
    expect((plano['cronograma_pratico'] as List), hasLength(1));
    final word = await run('planosEnsino.exportarWord', {
      'id': id,
      'path': '${dir.path}/plano.docx',
    });
    expect(File(word.data['path'] as String).lengthSync(), greaterThan(0));
    // Ida e volta pelo Word: o importador lê o que o exportador gerou.
    final imported = await run('planosEnsino.importarWord', {
      'path': word.data['path'],
    });
    final back = (await run('planosEnsino.listar', {
      'id': imported.data['id'],
    })).data['plano'] as Map;
    expect((back['identificacao'] as Map)['codigo'], 'FEELT31201');
    final backup = await run('planosEnsino.exportarBackup', {
      'path': '${dir.path}/backup.json',
    });
    expect(File(backup.data['path'] as String).existsSync(), isTrue);
  });

  test('inserir no SEI recusa plano incompleto e exige aprovação', () async {
    final saved = await run('planosEnsino.salvar', {
      'plano': {
        'identificacao': {'nome': 'X'},
      },
    });
    expect(
      commands['planosEnsino.inserirNoSei']!.approval,
      CommandApproval.required,
    );
    expect(
      () => run('planosEnsino.inserirNoSei', {'id': saved.data['id']}),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'plano_incompleto',
        ),
      ),
    );
  });

  test('cronograma do Moodle sem o módulo instalado', () async {
    final saved = await run('planosEnsino.salvar', {
      'plano': {'identificacao': {}},
    });
    expect(
      () => run('planosEnsino.cronogramaDoMoodle', {
        'id': saved.data['id'],
        'configId': 'c1',
      }),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'moodle_indisponivel',
        ),
      ),
    );
  });
}
