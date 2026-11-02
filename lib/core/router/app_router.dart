import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:config_moodle/presentation/pages/dashboard_page.dart';
import 'package:config_moodle/presentation/pages/home_page.dart';
import 'package:config_moodle/presentation/pages/sei_tree_page.dart';
import 'package:config_moodle/presentation/pages/table_editor_page.dart';
import 'package:config_moodle/presentation/pages/sync_preview_page.dart';
import 'package:config_moodle/presentation/pages/preenche_diarios_page.dart';
import 'package:config_moodle/presentation/pages/planos_ensino_page.dart';
import 'package:config_moodle/presentation/pages/planos_trabalho_page.dart';
import 'package:config_moodle/presentation/pages/ajusta_horarios_page.dart';

class AppRouter {
  static final rootNavigatorKey = GlobalKey<NavigatorState>();
  static final GoRouter router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (context, state) => const DashboardPage()),
      GoRoute(path: '/moodle', builder: (context, state) => const HomePage()),
      GoRoute(path: '/sei', builder: (context, state) => const SeiTreePage()),
      GoRoute(
        path: '/diario',
        builder: (context, state) => const PreencheDiariosPage(),
      ),
      GoRoute(
        path: '/planos-ensino',
        builder: (context, state) => const PlanosEnsinoPage(),
      ),
      GoRoute(
        path: '/planos-trabalho',
        builder: (context, state) => const PlanosTrabalhoPage(),
      ),
      GoRoute(
        path: '/ajusta-horarios',
        builder: (context, state) => const AjustaHorariosPage(),
      ),
      GoRoute(
        path: '/editor/:id',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          final reeval = state.uri.queryParameters['reeval'] == '1';
          return TableEditorPage(courseConfigId: id, autoEvaluate: reeval);
        },
      ),
      GoRoute(
        path: '/sync/:id',
        builder: (context, state) {
          final id = state.pathParameters['id']!;
          return SyncPreviewPage(courseConfigId: id);
        },
      ),
    ],
  );
}
