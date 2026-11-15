import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/diario/application/diario_commands.dart';
import 'package:gestor_ufu/modules/diario/application/diario_service.dart';
import 'package:gestor_ufu/modules/diario/diario_skill.dart';
import 'package:gestor_ufu/modules/diario/pages/preenche_diarios_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Módulo Preenche Diários.
class DiarioModule extends GestorModule {
  DiarioModule();

  DiarioService? _service;

  DiarioService get service => _service ??= DiarioService(
    KeyValueStore(),
    AcademicTermService(KeyValueStore()),
  );

  @override
  Future<void> activate(GestorServices services) async {
    _service = DiarioService(services.store, services.terms);
  }

  @override
  String get id => 'diario';

  @override
  String get title => 'Preenche Diários';

  @override
  String get description =>
      'Prepare lançamentos de aula usando planilhas ou dados do Moodle.';

  @override
  IconData get icon => Icons.edit_calendar_rounded;

  @override
  Color get accent => AppTheme.accent;

  @override
  String get category => 'ROTINA ACADÊMICA';

  @override
  String get route => '/diario';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => const PreencheDiariosPage(),
    ),
  ];

  @override
  ModuleSkill get skill => diarioSkill();

  @override
  List<ModuleCommand> get commands => diarioCommands(service);
}
