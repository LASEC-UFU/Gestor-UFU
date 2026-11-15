import 'package:flutter/widgets.dart';

import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_config_snapshot.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/modules/moodle/controllers/auth_controller.dart';
import 'package:gestor_ufu/modules/moodle/controllers/config_controller.dart';
import 'package:gestor_ufu/modules/moodle/controllers/sync_controller.dart';
import 'package:gestor_ufu/modules/moodle/widgets/moodle_login_dialog.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/moodle_planning.dart';

/// Contrato MoodlePlanning oferecido pelo módulo Config Moodle.
class MoodlePlanningImpl implements MoodlePlanning {
  MoodlePlanningImpl(this._config, this._sync, this._auth);

  final ConfigController _config;
  final SyncController _sync;
  final AuthController _auth;

  @override
  Future<List<CourseConfig>> savedConfigs() async {
    await _config.loadAll();
    return _config.configs;
  }

  @override
  Future<List<MoodleConfigSnapshot>> snapshots() => _config.getSnapshots();

  @override
  Future<bool> ensureConnected(BuildContext context) async {
    await _auth.init();
    if (_auth.isLoggedIn) return true;
    if (!context.mounted) return false;
    return showMoodleLoginDialog(context, _auth);
  }

  @override
  Future<List<MoodleCourse>> courses() async {
    await _sync.loadCourses(_auth.token, _auth.baseUrl);
    final error = _sync.error;
    if (error != null) throw CommandException('moodle_erro', error);
    return _sync.courses;
  }

  @override
  Future<CourseConfig> configFromCourse(
    MoodleCourse course,
    DateTime semesterStart,
  ) => _sync.buildConfigFromMoodle(
    _auth.token,
    _auth.baseUrl,
    course,
    semesterStart,
  );
}
