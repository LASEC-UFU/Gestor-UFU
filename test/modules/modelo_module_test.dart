import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/_modelo/modelo_module.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// O módulo-modelo funciona de ponta a ponta: registro, ativação, rota,
/// skill, modelo de arquivo e comandos (como o agente os executa).
void main() {
  test('registro, ativação e comandos do módulo-modelo', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = ModuleRegistry.instance..clear();
    registry.register(ModeloModule());
    final store = KeyValueStore();
    await registry.activateAll(
      GestorServices(store: store, terms: AcademicTermService(store)),
    );

    expect(registry.byRoute('/modelo')?.id, 'modelo');
    expect(registry.byId('modelo')!.skill, isNotNull);
    expect(registry.byId('modelo')!.templates.single.id, 'modelo_notas');

    Future<CommandResult> run(String id, [Map<String, dynamic>? input]) =>
        registry.commandById(id)!.run(input ?? {}, CommandOrigin.test);

    final criada = await run('modelo.adicionar', {'texto': ' Olá '});
    final lista = await run('modelo.listar');
    expect((lista.data['notas'] as List).single['texto'], 'Olá');

    expect(
      registry.commandById('modelo.remover')!.approval,
      CommandApproval.required,
    );
    await run('modelo.remover', {'id': criada.data['id']});
    expect((await run('modelo.listar')).data['notas'], isEmpty);

    expect(
      () => run('modelo.adicionar', {'texto': '  '}),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'c', 'entrada_invalida'),
      ),
    );
    registry.clear();
  });
}
