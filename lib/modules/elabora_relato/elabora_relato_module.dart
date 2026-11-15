import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/elabora_relato_commands.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/elabora_relato_skill.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/elabora_relato_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Elabora Relato: ferramentas para montar relatos de processos do
/// SEI. A primeira funcionalidade é extrair a árvore do processo.
class ElaboraRelatoModule extends GestorModule {
  ElaboraRelatoModule();

  SeiArvoreService _arvore = SeiArvoreService();

  @override
  Future<void> activate(GestorServices services) async {
    _arvore = SeiArvoreService(store: services.store);
  }

  @override
  String get id => 'elabora-relato';

  @override
  String get title => 'Elabora Relato';

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
  String get route => '/elabora-relato';

  /// Mesma chave de antes da renomeação: mantém a posição e as preferências
  /// do cartão no painel.
  @override
  String get dashboardKey => '/sei';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => ElaboraRelatoPage(arvore: _arvore),
    ),
    // Endereços antigos (atalhos, histórico do agente): "Extrair Árvore de
    // Processo" e "Elaborar Relato" (v1.1.42).
    GoRoute(path: '/sei', redirect: (context, state) => route),
    GoRoute(path: '/elaborar-relato', redirect: (context, state) => route),
  ];

  @override
  ModuleSkill get skill => elaboraRelatoSkill();

  @override
  List<ModuleCommand> get commands => elaboraRelatoCommands(_arvore);
}
