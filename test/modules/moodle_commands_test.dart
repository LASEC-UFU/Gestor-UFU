import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/moodle/application/moodle_commands.dart';
import 'package:gestor_ufu/modules/moodle/controllers/config_controller.dart';
import 'package:gestor_ufu/modules/moodle/data/datasources/local_datasource.dart';
import 'package:gestor_ufu/modules/moodle/data/repositories/config_repository_impl.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

void main() {
  late Directory dir;
  late Map<String, ModuleCommand> commands;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('moodle_cmd');
    final config = ConfigController(ConfigRepositoryImpl(LocalDatasource()));
    commands = {for (final c in moodleCommands(config)) c.id: c};
  });

  tearDown(() => dir.delete(recursive: true));

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  test('importa o modelo, lista e exporta de volta', () async {
    final (name, bytes, _) = moodleTemplate(
      options: {'sheet_name': 'Circuitos', 'semester_start': '2026-03-09'},
    );
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    await run('moodle.importarPlanilha', {'path': file.path});
    final listed = await run('moodle.listar', {});
    final configs = (listed.data['configuracoes'] as List).cast<Map>();
    expect(configs.single['nome'], 'Circuitos');
    expect(configs.single['secoes'], 2);
    expect(configs.single['atividades'], 6);
    final exported = await run('moodle.exportarPlanilha', {
      'configId': configs.single['id'],
      'path': '${dir.path}/export.xlsx',
    });
    expect(File(exported.data['path'] as String).existsSync(), isTrue);
  });

  test(
    'excluir exige aprovação e configuração inexistente tem código',
    () async {
      expect(commands['moodle.excluir']!.approval, CommandApproval.required);
      expect(
        () => run('moodle.exportarPlanilha', {'configId': 'x'}),
        throwsA(
          isA<CommandException>().having(
            (e) => e.code,
            'code',
            'configuracao_nao_encontrada',
          ),
        ),
      );
    },
  );
}
