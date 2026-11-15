import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/presentation/pages/equivalencia_alunos_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Equivalência de Alunos.
class EquivalenciaModule extends GestorModule {
  const EquivalenciaModule();

  @override
  String get id => 'equivalencia-alunos';

  @override
  String get title => 'Equivalência de Alunos';

  @override
  String get description =>
      'Organize análises de aproveitamento de disciplinas entre cursos.';

  @override
  IconData get icon => Icons.compare_arrows_rounded;

  @override
  Color get accent => Color(0xFF63C9B8);

  @override
  String get category => 'VIDA ACADÊMICA';

  @override
  String get route => '/equivalencia-alunos';

  @override
  List<RouteBase> get routes => [
      GoRoute(
        path: '/equivalencia-alunos',
        builder: (context, state) => const EquivalenciaAlunosPage(),
      ),
  ];
}
