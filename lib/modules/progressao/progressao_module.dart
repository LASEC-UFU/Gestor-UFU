import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/progressao/application/progressao_commands.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_service.dart';
import 'package:gestor_ufu/modules/progressao/data/progressao_store.dart';
import 'package:gestor_ufu/modules/progressao/pages/progressao_page.dart';
import 'package:gestor_ufu/modules/progressao/progressao_skill.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Progressão / Promoção docente.
class ProgressaoModule extends GestorModule {
  ProgressaoModule();

  ProgressaoService? _service;

  ProgressaoService get service =>
      _service ??= ProgressaoService(ProgressaoStore());

  @override
  Future<void> activate(GestorServices services) async {
    _service = ProgressaoService(ProgressaoStore(services.store));
  }

  @override
  String get id => 'progressao';

  @override
  String get title => 'Progressão / Promoção';

  @override
  String get description =>
      'Lance atividades do Anexo 1 (Res. 03/2017 CONDIR) e gere requerimento '
      'e relatório em PDF.';

  @override
  IconData get icon => Icons.trending_up_rounded;

  @override
  Color get accent => const Color(0xFF9D97FF);

  @override
  String get category => 'CARREIRA DOCENTE';

  @override
  String get route => '/progressao';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => ProgressaoPage(service: service),
    ),
  ];

  @override
  ModuleSkill get skill => progressaoSkill();

  @override
  List<ModuleCommand> get commands => progressaoCommands(service);
}
