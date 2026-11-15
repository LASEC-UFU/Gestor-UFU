import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/app/installed_modules.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_templates.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/modules/diario/application/diario_commands.dart';
import 'package:gestor_ufu/modules/diario/application/diario_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

void main() {
  // create_template usa os modelos declarados pelos módulos instalados.
  setUpAll(() {
    ModuleRegistry.instance.clear();
    installModules();
  });

  late Directory dir;
  late Map<String, ModuleCommand> commands;
  const term = '1º semestre de 2026';
  final key = KeyValueStore.termScoped(DiarioService.periodPrefix, term);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      AcademicTermService.termsKey: [term],
      AcademicTermService.activeKey: term,
      key: jsonEncode({
        'draftEntries': {'02/03/2026 -T': 'Aula antiga'},
        'selectedDiaryId': 'd1',
        'savedDiaries': [
          {
            'id': 'd1',
            'name': 'Circuitos',
            'entries': {'02/03/2026 -T': 'Aula antiga'},
          },
        ],
      }),
    });
    dir = await Directory.systemTemp.createTemp('diario_cmd');
    final store = KeyValueStore();
    final service = DiarioService(store, AcademicTermService(store));
    commands = {for (final c in diarioCommands(service)) c.id: c};
  });

  tearDown(() => dir.delete(recursive: true));

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  Future<Map<String, dynamic>> stored() async {
    final prefs = await SharedPreferences.getInstance();
    return Map<String, dynamic>.from(jsonDecode(prefs.getString(key)!) as Map);
  }

  test(
    'importa o modelo de planilha e espelha no diário selecionado',
    () async {
      final path =
          (await AgentTemplates.create(
                'diario_planilha',
                folder: dir.path,
              ))['path']
              as String;
      final result = await run('diario.importarPlanilha', {'path': path});
      expect(result.ok, isTrue);
      final data = await stored();
      final draft = Map<String, dynamic>.from(data['draftEntries'] as Map);
      // Mesclou: a aula antiga continua e entraram as 3 do modelo.
      expect(
        draft.keys,
        containsAll(['02/03/2026 -T', '05/03/2026 -T', '05/03/2026 -P']),
      );
      final diary = (data['savedDiaries'] as List).single as Map;
      expect((diary['entries'] as Map).length, draft.length);
    },
  );

  test('carregar JSON substitui e salvar JSON exporta', () async {
    final path =
        (await AgentTemplates.create('diario_json', folder: dir.path))['path']
            as String;
    await run('diario.carregarJson', {'path': path});
    final draft = Map<String, dynamic>.from(
      (await stored())['draftEntries'] as Map,
    );
    expect(draft.containsKey('02/03/2026 -T'), isFalse);
    final saved = await run('diario.salvarJson', {
      'path': '${dir.path}/out.json',
    });
    final exported =
        jsonDecode(File(saved.data['path'] as String).readAsStringSync())
            as Map;
    expect(exported.length, 3);
  });

  test('definir lançamentos normaliza datas e valor vazio remove', () async {
    await run('diario.definirLancamentos', {
      'lancamentos': {'9/3/26 -P': 'Lab 2', '02/03/2026 -T': ''},
    });
    final draft = Map<String, dynamic>.from(
      (await stored())['draftEntries'] as Map,
    );
    expect(draft, {'09/03/2026 -P': 'Lab 2'});
  });

  test('preencher o Portal exige aprovação e o Edge aberto', () async {
    expect(
      commands['diario.preencherPortal']!.approval,
      CommandApproval.required,
    );
    expect(
      () => run('diario.preencherPortal', {}),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'code', 'portal_fechado'),
      ),
    );
  });

  test('período inexistente tem código estável', () async {
    expect(
      () => run('diario.listar', {'periodo': '1990/1'}),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'periodo_inexistente',
        ),
      ),
    );
  });
}
