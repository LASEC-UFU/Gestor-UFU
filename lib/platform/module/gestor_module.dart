import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/single_child_widget.dart';

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

  /// Providers que o módulo publica para as SUAS telas (ex.: controllers
  /// do Config Moodle). Outros módulos não devem lê-los — usam contratos.
  List<SingleChildWidget> get providers => const [];

  /// Modelos de arquivo das importações do módulo (ferramenta
  /// `create_template` do agente e botões "baixar modelo").
  List<ModuleTemplate> get templates => const [];

  /// O banco foi alterado por fora da tela (agente, outro computador):
  /// descarte caches e recarregue.
  Future<void> onExternalDataChanged() async {}

  bool get enabled => route != null;

  /// Chave usada pelo painel para guardar ordem/ocultos (compatível com as
  /// preferências já salvas).
  String get dashboardKey => route ?? 'module:$title';

  /// Chamado uma vez ao iniciar o app, com os serviços da plataforma.
  Future<void> activate(GestorServices services) async {}
}

/// Trecho padrão das skills para dados que dependem do período letivo.
String termScopedSkillNote(String prefix) =>
    'Chave por período letivo: `$prefix<token>` — obtenha com '
    '`term_storage_key(prefix: "$prefix", term: <período>)` ou use os '
    'comandos do módulo. O período ativo vem de `get_app_context` (ex.: '
    '"2º semestre de 2026").';

/// Modelo de arquivo aceito por uma importação do módulo.
class ModuleTemplate {
  const ModuleTemplate({
    required this.id,
    required this.description,
    required this.build,
  });

  final String id;

  /// Onde importar (tela e botão).
  final String description;

  /// Gera o arquivo: (nome sugerido, bytes, como importar). [rows] substitui
  /// os exemplos; [data] é o conteúdo completo em modelos JSON.
  final (String, List<int>, String) Function({
    List<List<Object?>>? rows,
    Object? data,
    Map<String, dynamic> options,
  })
  build;
}
