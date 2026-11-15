import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/presentation/pages/home_page.dart';
import 'package:gestor_ufu/presentation/pages/sync_preview_page.dart';
import 'package:gestor_ufu/presentation/pages/table_editor_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Config Moodle.
class MoodleModule extends GestorModule {
  const MoodleModule();

  @override
  String get id => 'moodle';

  @override
  String get title => 'Config Moodle';

  @override
  String get description =>
      'Planeje disciplinas, organize atividades e sincronize cursos.';

  @override
  IconData get icon => Icons.settings_suggest_rounded;

  @override
  Color get accent => AppTheme.primary;

  @override
  String get category => 'PLANEJAMENTO DE DISCIPLINAS';

  @override
  String get route => '/moodle';

  @override
  List<String> get routePrefixes => const ['/moodle', '/editor', '/sync'];

  @override
  List<RouteBase> get routes => [
    GoRoute(path: '/moodle', builder: (context, state) => const HomePage()),
    GoRoute(
      path: '/editor/:id',
      builder: (context, state) => TableEditorPage(
        courseConfigId: state.pathParameters['id']!,
        autoEvaluate: state.uri.queryParameters['reeval'] == '1',
      ),
    ),
    GoRoute(
      path: '/sync/:id',
      builder: (context, state) =>
          SyncPreviewPage(courseConfigId: state.pathParameters['id']!),
    ),
  ];
}
