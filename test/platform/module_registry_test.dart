import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/app/installed_modules.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_skills.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';

void main() {
  final registry = ModuleRegistry.instance;

  setUp(() {
    registry.clear();
    installModules(registry);
  });

  test('registra os módulos na ordem padrão do painel', () {
    expect(registry.modules.map((m) => m.id), [
      'moodle',
      'diario',
      'elabora-relato',
      'planos-ensino',
      'planos-trabalho',
      'ajusta-horarios',
      'equivalencia-alunos',
      'progressao',
      'inserir-documentos-sei',
    ]);
  });

  test('chaves do painel continuam as mesmas das preferências salvas', () {
    expect(registry.byId('diario')!.dashboardKey, '/diario');
    // Renomeado de "Extrair Árvore de Processo" (rota /sei).
    expect(registry.byId('elabora-relato')!.dashboardKey, '/sei');
    expect(registry.byRoute('/elabora-relato')!.id, 'elabora-relato');
    expect(
      registry.byId('inserir-documentos-sei')!.dashboardKey,
      'module:Inserir Documentos no SEI',
    );
    expect(registry.byId('inserir-documentos-sei')!.enabled, isFalse);
  });

  test('cada rota pertence ao módulo certo (foco do agente)', () {
    expect(registry.byRoute('/editor/abc')!.id, 'moodle');
    expect(registry.byRoute('/sync/abc')!.id, 'moodle');
    expect(registry.byRoute('/diario')!.id, 'diario');
    expect(registry.byRoute('/progressao')!.id, 'progressao');
    expect(registry.byRoute('/'), isNull);
    expect(AgentSkills.idForRoute('/editor/1'), 'moodle');
    expect(AgentSkills.idForRoute('/'), AgentSkills.general);
  });

  test('rotas dos módulos não se repetem', () {
    final paths = [
      for (final module in registry.modules)
        for (final route in module.routes) (route as GoRoute).path,
    ];
    expect(paths.toSet().length, paths.length);
    expect(paths, containsAll(['/moodle', '/editor/:id', '/sync/:id']));
  });

  test('janelas secundárias do Ajusta Horários vêm do registro', () {
    for (final type in ['scheduleEditor', 'teacherEditor', 'roomEditor']) {
      expect(registry.windowFor(type), isNotNull, reason: type);
    }
    expect(registry.windowFor('desconhecida'), isNull);
  });

  test('registrar o mesmo módulo duas vezes é erro', () {
    expect(() => registry.register(registry.byId('diario')!), throwsStateError);
  });
}
