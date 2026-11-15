import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Conhecimento do módulo entregue ao Agente de IA (a "skill").
class ModuleSkill {
  const ModuleSkill({
    required this.title,
    required this.summary,
    required this.body,
  });

  final String title;
  final String summary;

  /// Guia do módulo: onde fica cada ação, importações, dados no banco.
  final String body;
}

/// Janela secundária aberta pelo módulo (ex.: editor de disciplinas).
class ModuleWindow {
  const ModuleWindow({
    required this.title,
    required this.size,
    required this.minimumSize,
    required this.app,
  });

  /// Título (o `main.dart` acrescenta " - Gestor UFU vX").
  final String title;
  final Size size;
  final Size minimumSize;
  final Widget app;
}

/// Monta a janela secundária a partir do payload recebido pelo `main.dart`
/// quando o `type` do payload é o registrado em [GestorModule.windows].
typedef ModuleWindowBuilder =
    ModuleWindow Function(Map<String, dynamic> payload);

/// Contrato de um módulo do Gestor UFU — o equivalente a uma extensão do
/// VS Code, mas compilado junto com o app. O módulo apenas DECLARA o que tem;
/// a plataforma monta o painel, as rotas, a skill do agente e os comandos a
/// partir dessas declarações.
abstract class GestorModule {
  const GestorModule();

  /// Identificador estável (também usado como foco do agente).
  String get id;
  String get title;
  String get description;
  IconData get icon;
  Color get accent;

  /// Categoria do cartão no painel (ex.: "ROTINA ACADÊMICA").
  String get category;

  /// Rota principal (abre ao clicar no cartão). `null` = módulo ainda não
  /// disponível (cartão desativado).
  String? get route;

  /// Todas as rotas do módulo (principal e telas internas).
  List<RouteBase> get routes => const [];

  /// Prefixos de rota que pertencem a este módulo (para o foco do agente).
  List<String> get routePrefixes => [?route];

  /// Janelas secundárias, por `type` do payload.
  Map<String, ModuleWindowBuilder> get windows => const {};

  /// Skill entregue ao Agente de IA.
  ModuleSkill? get skill => null;

  /// Ações do módulo executáveis pela tela, pelo menu e pelo agente.
  List<ModuleCommand> get commands => const [];

  bool get enabled => route != null;

  /// Chave usada pelo painel para guardar ordem/ocultos (compatível com as
  /// preferências já salvas).
  String get dashboardKey => route ?? 'module:$title';

  /// Chamado uma vez ao iniciar o app, com os serviços da plataforma.
  Future<void> activate(GestorServices services) async {}
}
