import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:go_router/go_router.dart';
import 'package:gestor_ufu/core/utils/debug_options.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/platform/services/navigation_service.dart';
import 'package:gestor_ufu/presentation/pages/dashboard_page.dart';
import 'package:gestor_ufu/presentation/pages/remote_access_page.dart';

/// Rotas do app: o painel ('/') mais as rotas declaradas por cada módulo
/// instalado (`app/installed_modules.dart`). Os módulos precisam estar
/// registrados antes do primeiro acesso a [router].
class AppRouter {
  static final rootNavigatorKey = GlobalKey<NavigatorState>();
  static final GoRouter router = _build();

  static GoRouter _build() {
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: kDebugMode && diaryAutomationDebugEnabled
          ? '/diario'
          : '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const DashboardPage()),
        GoRoute(
          path: '/remote-access',
          builder: (context, state) => const RemoteAccessPage(),
        ),
        for (final module in ModuleRegistry.instance.modules) ...module.routes,
      ],
    );
    NavigationService.attach(router);
    return router;
  }
}
