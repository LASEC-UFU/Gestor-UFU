import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/ajusta_horarios_skill.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/ajusta_horarios_templates.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/application/ajusta_horarios_commands.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/data/ajusta_horarios_store.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/domain/ajusta_horarios.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/pages/ajusta_horarios_page.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo Ajusta Horários.
class AjustaHorariosModule extends GestorModule {
  AjustaHorariosModule();

  final _store = AjustaHorariosStore();

  /// Avisa a tela quando o banco muda por fora (agente, outro computador).
  final _changes = ValueNotifier<int>(0);
  AcademicTermService? _terms;

  @override
  String get id => 'ajusta-horarios';

  @override
  String get title => 'Ajusta Horários';

  @override
  String get description =>
      'Monte grades semanais por curso, período e docente.';

  @override
  IconData get icon => Icons.schedule_rounded;

  @override
  Color get accent => AppTheme.primary;

  @override
  String get category => 'PLANEJAMENTO DE DISCIPLINAS';

  @override
  String get route => '/ajusta-horarios';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: '/ajusta-horarios',
      builder: (context, state) => AjustaHorariosPage(changes: _changes),
    ),
  ];

  /// Importa a grade 2026/2 de Controle e Automação na primeira abertura
  /// e aplica as migrações de dados do módulo.
  @override
  Future<void> activate(GestorServices services) async {
    _terms = services.terms;
    await _store.load();
  }

  @override
  Future<void> onExternalDataChanged() async => _changes.value++;

  @override
  ModuleSkill get skill => ajustaHorariosSkill();

  @override
  List<ModuleTemplate> get templates => ajustaHorariosTemplates();

  @override
  List<ModuleCommand> get commands {
    final terms = _terms;
    if (terms == null) return const [];
    return ajustaHorariosCommands(_store, terms, changes: _changes);
  }

  @override
  Map<String, ModuleWindowBuilder> get windows => {
    'scheduleEditor': (payload) => ModuleWindow(
      title: 'Editar disciplinas',
      size: const Size(1100, 780),
      minimumSize: const Size(1000, 760),
      app: HorarioEditorWindowApp(
        entries: _entries(payload),
        teachers: (payload['teachers'] as List).cast<String>(),
        programs: _programs(payload),
        selectedProgram: payload['selectedProgram'] as int,
        selectedPeriod: payload['selectedPeriod'] as int,
        channelName: payload['channel'] as String,
        initialEntryId: payload['initialEntryId'] as String?,
        term: payload['term'] as String? ?? '',
        terms: (payload['terms'] as List? ?? const []).cast<String>(),
        isLight: payload['isLight'] as bool? ?? false,
      ),
    ),
    'teacherEditor': (payload) => ModuleWindow(
      title: 'Editar docentes',
      size: const Size(1120, 820),
      minimumSize: const Size(900, 650),
      app: TeacherRosterWindowApp(
        teachers: (payload['teachers'] as List).cast<String>(),
        entries: _entries(payload),
        programs: _programs(payload),
        channelName: payload['channel'] as String,
        initialTeacher: payload['initialTeacher'] as String?,
        isLight: payload['isLight'] as bool? ?? false,
      ),
    ),
    'roomEditor': (payload) => ModuleWindow(
      title: 'Editar salas',
      size: const Size(1120, 820),
      minimumSize: const Size(900, 650),
      app: RoomRosterWindowApp(
        rooms: (payload['rooms'] as List).cast<String>(),
        entries: _entries(payload),
        programs: _programs(payload),
        channelName: payload['channel'] as String,
        initialRoom: payload['initialRoom'] as String?,
        isLight: payload['isLight'] as bool? ?? false,
      ),
    ),
  };

  static List<HorarioDisciplina> _entries(Map<String, dynamic> payload) => [
    for (final item in payload['entries'] as List)
      HorarioDisciplina.fromJson(Map<String, dynamic>.from(item as Map)),
  ];

  static Map<int, String> _programs(Map<String, dynamic> payload) =>
      (payload['programs'] as Map).map(
        (key, value) => MapEntry(int.parse(key as String), value as String),
      );
}
