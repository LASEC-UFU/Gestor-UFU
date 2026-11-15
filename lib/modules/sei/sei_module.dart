import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/sei/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/sei/application/sei_commands.dart';
import 'package:gestor_ufu/modules/sei/pages/sei_tree_page.dart';
import 'package:gestor_ufu/modules/sei/sei_skill.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Extrair Árvore de Processo (SEI).
class SeiModule extends GestorModule {
  SeiModule();

  SeiArvoreService _service = SeiArvoreService();

  @override
  Future<void> activate(GestorServices services) async {
    _service = SeiArvoreService(store: services.store);
  }

  @override
  String get id => 'sei';

  @override
  String get title => 'Extrair Árvore de Processo';

  @override
  String get description =>
      'Consulte os documentos de um processo e gere um inventário revisável.';

  @override
  IconData get icon => Icons.account_tree_rounded;

  @override
  Color get accent => const Color(0xFFFFB454);

  @override
  String get category => 'PROCESSOS E DOCUMENTOS';

  @override
  String get route => '/sei';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => SeiTreePage(service: _service),
    ),
  ];

  @override
  ModuleSkill get skill => seiSkill();

  @override
  List<ModuleCommand> get commands => seiCommands(_service);
}
