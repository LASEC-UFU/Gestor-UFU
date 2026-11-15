import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulos instalados. Preenchido pela composição (`app/installed_modules.dart`)
/// antes de o app iniciar; painel, rotas, agente e janelas secundárias leem
/// daqui.
class ModuleRegistry {
  ModuleRegistry._();

  static final instance = ModuleRegistry._();

  final _modules = <GestorModule>[];
  bool _activated = false;

  List<GestorModule> get modules => List.unmodifiable(_modules);

  void register(GestorModule module) {
    if (_modules.any((m) => m.id == module.id)) {
      throw StateError('Módulo "${module.id}" registrado duas vezes.');
    }
    final duplicated = module.commands
        .map((c) => c.id)
        .where((id) => commandById(id) != null);
    if (duplicated.isNotEmpty) {
      throw StateError('Comando duplicado: ${duplicated.join(', ')}.');
    }
    _modules.add(module);
  }

  /// Remove todos (apenas para testes).
  void clear() {
    _modules.clear();
    _activated = false;
  }

  Future<void> activateAll(GestorServices services) async {
    if (_activated) return;
    _activated = true;
    for (final module in _modules) {
      await module.activate(services);
    }
  }

  GestorModule? byId(String id) {
    for (final module in _modules) {
      if (module.id == id) return module;
    }
    return null;
  }

  /// Módulo dono de uma rota (prefixo mais longo vence).
  GestorModule? byRoute(String? route) {
    if (route == null) return null;
    GestorModule? best;
    var bestLength = 0;
    for (final module in _modules) {
      for (final prefix in module.routePrefixes) {
        final matches = route == prefix || route.startsWith('$prefix/');
        if (matches && prefix.length > bestLength) {
          best = module;
          bestLength = prefix.length;
        }
      }
    }
    return best;
  }

  Iterable<ModuleCommand> get commands =>
      _modules.expand((module) => module.commands);

  ModuleCommand? commandById(String id) {
    for (final command in commands) {
      if (command.id == id) return command;
    }
    return null;
  }

  /// Construtor da janela secundária de um `type`, se algum módulo a oferece.
  ModuleWindowBuilder? windowFor(String type) {
    for (final module in _modules) {
      final builder = module.windows[type];
      if (builder != null) return builder;
    }
    return null;
  }
}
