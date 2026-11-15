import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/moodle/application/moodle_commands.dart';
import 'package:gestor_ufu/modules/moodle/application/moodle_planning_impl.dart';
import 'package:gestor_ufu/modules/moodle/controllers/auth_controller.dart';
import 'package:gestor_ufu/modules/moodle/controllers/config_controller.dart';
import 'package:gestor_ufu/modules/moodle/controllers/sync_controller.dart';
import 'package:gestor_ufu/modules/moodle/data/datasources/local_datasource.dart';
import 'package:gestor_ufu/modules/moodle/data/datasources/moodle_datasource.dart';
import 'package:gestor_ufu/modules/moodle/data/repositories/config_repository_impl.dart';
import 'package:gestor_ufu/modules/moodle/data/repositories/moodle_repository_impl.dart';
import 'package:gestor_ufu/modules/moodle/moodle_skill.dart';
import 'package:gestor_ufu/modules/moodle/pages/home_page.dart';
import 'package:gestor_ufu/modules/moodle/pages/sync_preview_page.dart';
import 'package:gestor_ufu/modules/moodle/pages/table_editor_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/moodle_planning.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';

/// Módulo Config Moodle: planejamento de disciplinas e sincronização com o
/// Moodle. Oferece o contrato [MoodlePlanning] aos outros módulos.
class MoodleModule extends GestorModule {
  MoodleModule();

  final _local = LocalDatasource();
  late final config = ConfigController(ConfigRepositoryImpl(_local));
  late final _moodleRepo = MoodleRepositoryImpl(MoodleDatasource());
  late final auth = AuthController(_moodleRepo);
  late final sync = SyncController(_moodleRepo);

  @override
  Future<void> activate(GestorServices services) async {
    await _local.migrateLegacyTextEncoding();
    config.useTerms(services.terms);
    auth.init();
    services.registerContract<MoodlePlanning>(
      MoodlePlanningImpl(config, sync, auth),
    );
  }

  @override
  Future<void> onExternalDataChanged() async {
    _local.invalidateCache();
    await config.loadAll();
  }

  @override
  List<SingleChildWidget> get providers => [
    ChangeNotifierProvider.value(value: auth),
    ChangeNotifierProvider.value(value: config),
    ChangeNotifierProvider.value(value: sync),
  ];

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

  @override
  ModuleSkill get skill => moodleSkill();

  @override
  List<ModuleCommand> get commands => moodleCommands(config);

  @override
  List<ModuleTemplate> get templates => const [
    ModuleTemplate(
      id: 'moodle_planilha',
      description:
          'Config Moodle → "Novo" → "Importar Planilha": planilha .xlsx de uma '
          'disciplina (seções e atividades), abas _Datas Especiais e _Trocas '
          'de Dia.',
      build: moodleTemplate,
    ),
  ];
}
