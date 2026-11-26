import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/audita_bancas/application/audita_bancas_commands.dart';
import 'package:gestor_ufu/modules/audita_bancas/application/audita_service.dart';
import 'package:gestor_ufu/modules/audita_bancas/audita_bancas_skill.dart';
import 'package:gestor_ufu/modules/audita_bancas/pages/audita_bancas_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Audita Bancas: revisão assistida de TCCs, dissertações e teses em PDF.
/// Usa só a plataforma (camada de comentários e visualizador de PDF).
class AuditaBancasModule extends GestorModule {
  AuditaBancasModule();

  AuditaService _service = AuditaService();

  @override
  Future<void> activate(GestorServices services) async {
    _service = AuditaService(
      store: services.store,
      ia: services.contract<AiTextService>(),
    );
  }

  @override
  Future<void> onExternalDataChanged() => _service.carregar(forcar: true);

  @override
  String get id => 'audita-bancas';

  @override
  String get title => 'Audita Bancas';

  @override
  String get description =>
      'Revise TCCs, dissertações e teses em PDF com critérios da banca, '
      'observações da IA e exportação do PDF anotado.';

  @override
  IconData get icon => Icons.rate_review_outlined;

  @override
  Color get accent => const Color(0xFF6D82D8);

  @override
  String get category => 'DOCUMENTOS E PESQUISA';

  @override
  String get route => '/audita-bancas';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (_, _) => AuditaBancasPage(service: _service),
    ),
  ];

  @override
  ModuleSkill get skill => auditaBancasSkill();

  @override
  List<ModuleCommand> get commands => auditaBancasCommands(_service);
}
