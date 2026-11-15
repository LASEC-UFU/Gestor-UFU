import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_commands.dart';
import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_service.dart';
import 'package:gestor_ufu/modules/equivalencia/data/equivalencia_repository.dart';
import 'package:gestor_ufu/modules/equivalencia/equivalencia_skill.dart';
import 'package:gestor_ufu/modules/equivalencia/pages/equivalencia_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Módulo Equivalência de Alunos (módulo piloto da plataforma).
class EquivalenciaModule extends GestorModule {
  EquivalenciaModule();

  EquivalenciaService? _service;

  /// Serviço do módulo. Criado na ativação com o banco da plataforma; fora
  /// da janela principal (ex.: janela do agente) usa o banco padrão.
  EquivalenciaService get service =>
      _service ??= EquivalenciaService(EquivalenciaRepository(KeyValueStore()));

  @override
  Future<void> activate(GestorServices services) async {
    _service = EquivalenciaService(EquivalenciaRepository(services.store));
  }

  @override
  String get id => 'equivalencia-alunos';

  @override
  String get title => 'Equivalência de Alunos';

  @override
  String get description =>
      'Organize análises de aproveitamento de disciplinas entre cursos.';

  @override
  IconData get icon => Icons.compare_arrows_rounded;

  @override
  Color get accent => const Color(0xFF63C9B8);

  @override
  String get category => 'VIDA ACADÊMICA';

  @override
  String get route => '/equivalencia-alunos';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => EquivalenciaPage(service: service),
    ),
  ];

  @override
  ModuleSkill get skill => equivalenciaSkill;

  @override
  List<ModuleCommand> get commands => equivalenciaCommands(service);
}
