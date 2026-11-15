import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/presentation/pages/planos_trabalho_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Planos de Trabalho.
class PlanosTrabalhoModule extends GestorModule {
  const PlanosTrabalhoModule();

  @override
  String get id => 'planos-trabalho';

  @override
  String get title => 'Planos de Trabalho';

  @override
  String get description =>
      'Organize atividades, preencha planilhas e prepare PDFs para o SEI.';

  @override
  IconData get icon => Icons.assignment_turned_in_rounded;

  @override
  Color get accent => Color(0xFFFF7B8B);

  @override
  String get category => 'GESTÃO DO TRABALHO';

  @override
  String get route => '/planos-trabalho';

  @override
  List<RouteBase> get routes => [
      GoRoute(
        path: '/planos-trabalho',
        builder: (context, state) => const PlanosTrabalhoPage(),
      ),
  ];
}
