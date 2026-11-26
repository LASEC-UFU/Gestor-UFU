import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/planos_trabalho/application/planos_trabalho_commands.dart';
import 'package:gestor_ufu/modules/planos_trabalho/data/planos_trabalho_store.dart';
import 'package:gestor_ufu/modules/planos_trabalho/pages/planos_trabalho_page.dart';
import 'package:gestor_ufu/modules/planos_trabalho/planos_trabalho_skill.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

/// Módulo Planos de Trabalho.
class PlanosTrabalhoModule extends GestorModule {
  PlanosTrabalhoModule();

  PlanosTrabalhoStore _store = PlanosTrabalhoStore();
  final _sei = SeiAutomationService();
  final _changes = ValueNotifier<int>(0);

  @override
  Future<void> activate(GestorServices services) async {
    _store = PlanosTrabalhoStore(services.store);
  }

  @override
  String get id => 'planos-trabalho';

  @override
  String get title => 'Planos de Trabalho';

  @override
  String get description =>
      'Organize atividades, preencha planilhas e prepare PDFs para o SEI.';

  @override
  IconData get icon => Icons.assignment_turned_in_rounded;

  @override
  Color get accent => const Color(0xFFFF7B8B);

  @override
  String get category => 'GESTÃO DO TRABALHO';

  @override
  String get route => '/planos-trabalho';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => PlanosTrabalhoPage(
        store: _store,
        automation: _sei,
        changes: _changes,
      ),
    ),
  ];

  @override
  ModuleSkill get skill => planosTrabalhoSkill();

  @override
  List<ModuleCommand> get commands => planosTrabalhoCommands(_store, _sei);

  @override
  Future<void> onExternalDataChanged() async => _changes.value++;
}
