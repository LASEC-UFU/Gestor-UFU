import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integracoes_pessoais_page.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integration_commands.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integration_service.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

class IntegracoesPessoaisModule extends GestorModule {
  const IntegracoesPessoaisModule();
  static final _integrationApi = IntegrationService();
  @override
  String get id => 'agenda-email';
  @override
  String get title => 'Agendas e E-mails';
  @override
  String get description =>
      'Centralize o estado de configuração das contas Google e Microsoft.';
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
    GoRoute(path: route, builder: (_, _) => const IntegracoesPessoaisPage()),
  ];
  @override
  ModuleSkill get skill => const ModuleSkill(
    title: 'Agendas e E-mails',
    summary: 'Status das integrações externas.',
    body:
        'Integração de calendário: para pedidos ambíguos sobre Pessoal/Profissional, pergunte qual categoria. Consulte agenda.listar_calendarios e agenda.listar_eventos antes de atualizar/excluir. Antes de criar/alterar/excluir, apresente título, horário com fuso, conta, provedor e calendário e peça confirmação. Use apenas os eventos da origem informada. Para Teams, agenda.criar_evento online_teams=true cria reunião online apenas na conta Microsoft.\n\nE-mail: email.listar devolve só metadados; para ler conteúdo, avise que será compartilhado com o modelo configurado, identifique assunto/remetente/conta e obtenha consentimento; use email.ler. Antes de mudar estado lido, confirme assunto/remetente/conta e use email.alterar_lido. Não envie, exclua, arquive, mova nem responda mensagens. Tokens ficam internos ao adaptador e nunca devem ser pedidos ou exibidos. Consulte docs/integracoes-agenda-email-audita-powershell.md para OAuth e aprovação do CTIC.',
  );
  @override
  List<ModuleCommand> get commands => integrationCommands(_integrationApi);
}
