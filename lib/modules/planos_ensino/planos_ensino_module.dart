import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/presentation/pages/planos_ensino_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Planos de Ensino.
class PlanosEnsinoModule extends GestorModule {
  const PlanosEnsinoModule();

  @override
  String get id => 'planos-ensino';

  @override
  String get title => 'Planos de Ensino';

  @override
  String get description =>
      'Cadastre planos, organize cronogramas e prepare documentos para o SEI.';

  @override
  IconData get icon => Icons.menu_book_rounded;

  @override
  Color get accent => Color(0xFF5DD39E);

  @override
  String get category => 'ENSINO';

  @override
  String get route => '/planos-ensino';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: '/planos-ensino',
      builder: (context, state) => const PlanosEnsinoPage(),
    ),
  ];
}
