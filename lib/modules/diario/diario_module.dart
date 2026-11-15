import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/presentation/pages/preenche_diarios_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Preenche Diários.
class DiarioModule extends GestorModule {
  const DiarioModule();

  @override
  String get id => 'diario';

  @override
  String get title => 'Preenche Diários';

  @override
  String get description =>
      'Prepare lançamentos de aula usando planilhas ou dados do Moodle.';

  @override
  IconData get icon => Icons.edit_calendar_rounded;

  @override
  Color get accent => AppTheme.accent;

  @override
  String get category => 'ROTINA ACADÊMICA';

  @override
  String get route => '/diario';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: '/diario',
      builder: (context, state) => const PreencheDiariosPage(),
    ),
  ];
}
