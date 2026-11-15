import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/presentation/pages/sei_tree_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Extrair Árvore de Processo.
class SeiModule extends GestorModule {
  const SeiModule();

  @override
  String get id => 'sei';

  @override
  String get title => 'Extrair \u00c1rvore de Processo';

  @override
  String get description =>
      'Consulte os documentos de um processo e gere um inventário revisável.';

  @override
  IconData get icon => Icons.account_tree_rounded;

  @override
  Color get accent => Color(0xFFFFB454);

  @override
  String get category => 'PROCESSOS E DOCUMENTOS';

  @override
  String get route => '/sei';

  @override
  List<RouteBase> get routes => [
    GoRoute(path: '/sei', builder: (context, state) => const SeiTreePage()),
  ];
}
