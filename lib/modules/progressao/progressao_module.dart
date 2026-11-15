import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/presentation/pages/progressao_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Progressão / Promoção.
class ProgressaoModule extends GestorModule {
  const ProgressaoModule();

  @override
  String get id => 'progressao';

  @override
  String get title => 'Progressão / Promoção';

  @override
  String get description =>
      'Lance atividades do Anexo 1 (Res. 03/2017 CONDIR) e gere requerimento e relatório em PDF.';

  @override
  IconData get icon => Icons.trending_up_rounded;

  @override
  Color get accent => Color(0xFF9D97FF);

  @override
  String get category => 'CARREIRA DOCENTE';

  @override
  String get route => '/progressao';

  @override
  List<RouteBase> get routes => [
      GoRoute(
        path: '/progressao',
        builder: (context, state) => const ProgressaoPage(),
      ),
  ];
}
