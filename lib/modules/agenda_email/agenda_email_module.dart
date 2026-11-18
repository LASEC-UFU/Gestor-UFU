import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/agenda_email/agenda_email_skill.dart';
import 'package:gestor_ufu/modules/agenda_email/application/agenda_email_commands.dart';
import 'package:gestor_ufu/modules/agenda_email/application/integration_service.dart';
import 'package:gestor_ufu/modules/agenda_email/application/preferencias_agenda.dart';
import 'package:gestor_ufu/modules/agenda_email/pages/agenda_email_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Agendas e E-mails: contas Google e Microsoft (OAuth), agendas e
/// e-mails, com a mesma instância do serviço na tela e nos comandos.
class AgendaEmailModule extends GestorModule {
  AgendaEmailModule();

  // Recriados em activate() com o banco da plataforma.
  final IntegrationService _api = IntegrationService();
  PreferenciasAgenda _preferencias = PreferenciasAgenda();

  @override
  Future<void> activate(GestorServices services) async {
    _preferencias = PreferenciasAgenda(services.store);
  }

  @override
  String get id => 'agenda-email';

  @override
  String get title => 'Agendas e E-mails';

  @override
  String get description =>
      'Agendas e e-mails das contas Google e Microsoft: eventos, '
      'classificação Pessoal/Profissional e mensagens.';

  @override
  IconData get icon => Icons.calendar_month_outlined;

  @override
  Color get accent => const Color(0xFF4A8C79);

  @override
  String get category => 'ORGANIZAÇÃO PESSOAL';

  @override
  String get route => '/agendas-e-emails';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) =>
          AgendaEmailPage(api: _api, preferencias: _preferencias),
    ),
  ];

  @override
  ModuleSkill get skill => agendaEmailSkill();

  @override
  List<ModuleCommand> get commands => agendaEmailCommands(_api, _preferencias);
}
