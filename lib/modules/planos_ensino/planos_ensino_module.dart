import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/planos_ensino/application/planos_ensino_commands.dart';
import 'package:gestor_ufu/modules/planos_ensino/application/planos_ensino_service.dart';
import 'package:gestor_ufu/modules/planos_ensino/data/planos_ensino_automation_service.dart';
import 'package:gestor_ufu/modules/planos_ensino/pages/planos_ensino_page.dart';
import 'package:gestor_ufu/modules/planos_ensino/planos_ensino_skill.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/moodle_planning.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/modules/planos_ensino/planos_ensino_templates.dart';

/// Módulo Planos de Ensino.
class PlanosEnsinoModule extends GestorModule {
  PlanosEnsinoModule();

  PlanosEnsinoService _service = PlanosEnsinoService();
  final _sei = PlanosEnsinoAutomationService();
  final _changes = ValueNotifier<int>(0);
  GestorServices? _services;

  MoodlePlanning? _moodle() => _services?.contract<MoodlePlanning>();

  @override
  Future<void> activate(GestorServices services) async {
    _services = services;
    _service = PlanosEnsinoService(services.store);
  }

  @override
  String get id => 'planos-ensino';

  @override
  String get title => 'Planos de Ensino';

  @override
  String get description =>
      'Cadastre planos, organize cronogramas e prepare documentos para o SEI.';

  @override
  IconData get icon => Icons.menu_book_rounded;

  @override
  Color get accent => const Color(0xFF5DD39E);

  @override
  String get category => 'ENSINO';

  @override
  String get route => '/planos-ensino';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => PlanosEnsinoPage(
        service: _service,
        automation: _sei,
        moodle: _moodle(),
        changes: _changes,
      ),
    ),
  ];

  @override
  ModuleSkill get skill => planosEnsinoSkill();

  @override
  List<ModuleCommand> get commands =>
      planosEnsinoCommands(_service, _sei, _moodle);

  @override
  List<ModuleTemplate> get templates => planosEnsinoTemplates();

  @override
  Future<void> onExternalDataChanged() async => _changes.value++;
}
