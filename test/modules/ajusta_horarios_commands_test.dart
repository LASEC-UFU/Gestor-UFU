import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/ajusta_horarios/ajusta_horarios_templates.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/application/ajusta_horarios_commands.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/data/ajusta_horarios_store.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Map<String, ModuleCommand> commands;
  late ValueNotifier<int> changes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Evita a importação inicial da grade embutida.
      'ajusta_horarios_importacao_2026_2_ca_v2': true,
    });
    dir = await Directory.systemTemp.createTemp('ajusta_cmd');
    changes = ValueNotifier(0);
    commands = {
      for (final c in ajustaHorariosCommands(
        AjustaHorariosStore(),
        AcademicTermService(KeyValueStore()),
        changes: changes,
      ))
        c.id: c,
    };
  });

  tearDown(() => dir.delete(recursive: true));

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  Future<String> template(String id) async {
    final t = ajustaHorariosTemplates().firstWhere((t) => t.id == id);
    final (name, bytes, _) = t.build(options: const {});
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return file.path;
  }

  Matcher code(String c) =>
      throwsA(isA<CommandException>().having((e) => e.code, 'code', c));

  test('importa BDados e Banco do modelo, lista e exporta a grade', () async {
    expect(
      commands['ajustaHorarios.importarPlanilha']!.approval,
      CommandApproval.required,
    );
    await run('ajustaHorarios.importarPlanilha', {
      'path': await template('ajusta_horarios_bdados'),
    });
    await run('ajustaHorarios.importarPlanilha', {
      'path': await template('ajusta_horarios_banco'),
    });
    expect(changes.value, 2);

    final resumo = await run('ajustaHorarios.listar', {});
    expect(resumo.data['disciplinas'], 2);
    expect(resumo.data['distribuicao'], 2);
    expect(resumo.data['docentes'], containsAll(['Maria Silva', 'João Souza']));

    final docente = await run('ajustaHorarios.listar', {
      'teacher': 'Maria Silva',
    });
    final linhas = (docente.data['disciplinas'] as List).cast<Map>();
    expect(linhas.single['turma'], 'A');
    expect(linhas.single['horarios'], hasLength(2));

    final curso = await run('ajustaHorarios.exportarGradeCsv', {
      'program': 1,
      'periods': [3],
      'path': '${dir.path}/grade.csv',
    });
    final csv = File(curso.data['path'] as String).readAsStringSync();
    expect(csv, contains('CIRC1'));
    expect(csv, contains('Faixa horária'));
  });

  test('filtros e período inválidos têm código', () async {
    expect(
      () => run('ajustaHorarios.exportarGradeCsv', {}),
      code('filtro_invalido'),
    );
    expect(
      () => run('ajustaHorarios.exportarGradeCsv', {'program': 1}),
      code('filtro_invalido'),
    );
    expect(
      () => run('ajustaHorarios.listar', {'term': '1999/1'}),
      code('periodo_nao_encontrado'),
    );
  });
}
