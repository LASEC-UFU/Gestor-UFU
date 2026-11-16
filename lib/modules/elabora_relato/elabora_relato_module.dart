import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/elabora_relato_commands.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/elabora_relato_skill.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/elabora_relato_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Parecer / Relato (antes "Elabora Relato"): monta pareceres no
/// modelo "Parecer" do SEI — I. RELATÓRIO (com a extração da árvore do
/// processo e resumos pelo Agente de IA), II. FUNDAMENTAÇÃO E ANÁLISE e
/// III. CONCLUSÃO — e insere o documento no SEI.
///
/// O id, a rota e as chaves do banco continuam os do "Elabora Relato"
/// (compatibilidade com atalhos, painel e dados sincronizados).
class ElaboraRelatoModule extends GestorModule {
  ElaboraRelatoModule();

  SeiArvoreService _arvore = SeiArvoreService();
  late ParecerService _parecer = ParecerService(arvore: _arvore);

  @override
  Future<void> activate(GestorServices services) async {
    _arvore = SeiArvoreService(
      store: services.store,
      ia: services.contract<AiTextService>(),
    );
    _parecer = ParecerService(store: services.store, arvore: _arvore);
  }

  @override
  String get id => 'elabora-relato';

  @override
  String get title => 'Parecer / Relato';

  @override
  String get description =>
      'Monte pareceres no modelo do SEI: relatório com a árvore do processo '
      'e resumos por IA, fundamentação e conclusão, e insira no SEI.';

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
      builder: (context, state) => ElaboraRelatoPage(parecer: _parecer),
    ),
    // Endereços antigos (atalhos, histórico do agente): "Extrair Árvore de
    // Processo" e "Elaborar Relato" (v1.1.42).
    GoRoute(path: '/sei', redirect: (context, state) => route),
    GoRoute(path: '/elaborar-relato', redirect: (context, state) => route),
    GoRoute(path: '/parecer-relato', redirect: (context, state) => route),
  ];

  @override
  ModuleSkill get skill => elaboraRelatoSkill();

  @override
  List<ModuleCommand> get commands =>
      elaboraRelatoCommands(_arvore, _parecer);
}
