import 'package:go_router/go_router.dart';

/// Navegação usada por comandos (que não têm BuildContext), ex.: o agente
/// abrir a prévia de sincronização do Moodle para o usuário conferir.
class NavigationService {
  const NavigationService._();

  static GoRouter? _router;

  static void attach(GoRouter router) => _router = router;

  /// Vai para [route]; `false` se o app ainda não tem roteador.
  static bool go(String route) {
    final router = _router;
    if (router == null) return false;
    router.go(route);
    return true;
  }

  static String? get currentRoute {
    try {
      return _router?.routerDelegate.currentConfiguration.uri.path;
    } catch (_) {
      return null;
    }
  }
}
