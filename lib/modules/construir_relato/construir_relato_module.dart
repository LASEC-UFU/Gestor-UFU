import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/construir_relato/application/construir_relato_commands.dart';
import 'package:gestor_ufu/modules/construir_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/construir_relato/construir_relato_skill.dart';
import 'package:gestor_ufu/modules/construir_relato/pages/construir_relato_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Construir Relato: ferramentas para montar relatos de processos do
/// SEI. A primeira funcionalidade é extrair a árvore do processo.
class ConstruirRelatoModule extends GestorModule {
  ConstruirRelatoModule();

  SeiArvoreService _arvore = SeiArvoreService();

  @override
  Future<void> activate(GestorServices services) async {
    _arvore = SeiArvoreService(store: services.store);
  }

  @override
  String get id => 'construir-relato';

  @override
  String get title => 'Construir Relato';

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
  String get route => '/construir-relato';

  /// Mesma chave de antes da renomeação: mantém a posição e as preferências
  /// do cartão no painel.
  @override
  String get dashboardKey => '/sei';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => ConstruirRelatoPage(arvore: _arvore),
    ),
    // Endereço antigo (atalhos, histórico do agente).
    GoRoute(path: '/sei', redirect: (context, state) => route),
  ];

  @override
  ModuleSkill get skill => construirRelatoSkill();

  @override
  List<ModuleCommand> get commands => construirRelatoCommands(_arvore);
}
