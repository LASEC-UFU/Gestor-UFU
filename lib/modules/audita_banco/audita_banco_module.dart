import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gestor_ufu/modules/audita_banco/audita_banco_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';

class AuditaBancoModule extends GestorModule {
  AuditaBancoModule();
  AiTextService? _ai;
  ParecerService? _reviewService;
  @override
  Future<void> activate(GestorServices services) async {
    _ai = services.contract<AiTextService>();
    _reviewService = ParecerService(
      store: services.store,
      arvore: SeiArvoreService(store: services.store, ia: _ai),
      ia: _ai,
      anexos: AnexosProcessoService(store: services.store),
    );
    await _reviewService!.usarProcesso('audita-banco');
  }

  @override
  String get id => 'audita-banco';
  @override
  String get title => 'Audita Banco';
  @override
  String get description =>
      'Analise TCCs, dissertações e teses em PDF com critérios configuráveis e revisão assistida.';
  @override
  IconData get icon => Icons.rate_review_outlined;
  @override
  Color get accent => const Color(0xFF6D82D8);
  @override
  String get category => 'DOCUMENTOS E PESQUISA';
  @override
  String get route => '/audita-banco';
  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (_, _) => AuditaBancoPage(ai: _ai, service: _reviewService),
    ),
  ];
  @override
  ModuleSkill get skill => const ModuleSkill(
    title: 'Audita Banco',
    summary: 'Analise acadêmica de PDFs com critérios fornecidos pelo usuário.',
    body:
        'O módulo Audita Banco permite selecionar PDFs de TCC, dissertação ou tese e solicitar análise ao modelo configurado. O texto selecionado será enviado ao modelo. Configure critérios e normas no campo próprio. Confirme toda observação com as regras efetivamente fornecidas; não invente normas institucionais.',
  );
}
