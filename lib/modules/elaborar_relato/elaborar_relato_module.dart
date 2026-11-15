import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/elaborar_relato/application/elaborar_relato_commands.dart';
import 'package:gestor_ufu/modules/elaborar_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elaborar_relato/elaborar_relato_skill.dart';
import 'package:gestor_ufu/modules/elaborar_relato/pages/elaborar_relato_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Elaborar Relato: ferramentas para montar relatos de processos do
/// SEI. A primeira funcionalidade é extrair a árvore do processo.
class ElaborarRelatoModule extends GestorModule {
  ElaborarRelatoModule();

  SeiArvoreService _arvore = SeiArvoreService();

  @override
  Future<void> activate(GestorServices services) async {
    _arvore = SeiArvoreService(store: services.store);
  }

  @override
  String get id => 'elaborar-relato';

  @override
  String get title => 'Elaborar Relato';

  @override
  String get description =>
      'Monte relatos de processos do SEI: extraia a árvore de documentos e '
      'gere um inventário revisável.';

  @override
  IconData get icon => Icons.history_edu_rounded;

  @override
  Color get accent => const Color(0xFFFFB454);

  @override
  String get category => 'PROCESSOS E DOCUMENTOS';

  @override
  String get route => '/elaborar-relato';

  /// Mesma chave de antes da renomeação: mantém a posição e as preferências
  /// do cartão no painel.
  @override
  String get dashboardKey => '/sei';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => ElaborarRelatoPage(arvore: _arvore),
    ),
    // Endereço antigo (atalhos, histórico do agente).
    GoRoute(path: '/sei', redirect: (context, state) => route),
  ];

  @override
  ModuleSkill get skill => elaborarRelatoSkill();

  @override
  List<ModuleCommand> get commands => elaborarRelatoCommands(_arvore);
}
