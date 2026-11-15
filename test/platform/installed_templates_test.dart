import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_ufu/app/installed_modules.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_skills.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_templates.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';

void main() {
  setUpAll(() {
    ModuleRegistry.instance.clear();
    installModules();
  });

  test('os módulos instalados oferecem todos os modelos de importação', () {
    expect(
      AgentTemplates.all.keys,
      containsAll([
        'moodle_planilha',
        'diario_planilha',
        'diario_json',
        'ajusta_horarios_bdados',
        'ajusta_horarios_banco',
        'equivalencia_curriculo',
        'equivalencia_analise',
        'plano_ensino_json',
        'plano_ensino_cronograma',
      ]),
    );
  });

  test('cada módulo com tela tem skill e os ids de comando são únicos', () {
    for (final module in ModuleRegistry.instance.modules) {
      if (module.enabled) {
        expect(AgentSkills.byId(module.id), isNotNull, reason: module.id);
      }
    }
    final ids = ModuleRegistry.instance.commands.map((c) => c.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}
