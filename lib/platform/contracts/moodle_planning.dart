import 'package:flutter/widgets.dart';

import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/domain/entities/moodle_config_snapshot.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';

/// Planejamento de disciplinas do Config Moodle, oferecido a outros módulos
/// (Preenche Diários, Planos de Ensino). Implementado pelo módulo Moodle e
/// registrado na composição; quem usa trata a ausência (dependência opcional).
abstract interface class MoodlePlanning {
  /// Configurações salvas do período letivo ativo (recarregadas).
  Future<List<CourseConfig>> savedConfigs();

  /// Versões salvas das configurações (histórico).
  Future<List<MoodleConfigSnapshot>> snapshots();

  /// Garante a sessão no Moodle; abre a tela de login do módulo se preciso.
  Future<bool> ensureConnected(BuildContext context);

  /// Disciplinas da conta conectada.
  Future<List<MoodleCourse>> courses();

  /// Monta uma configuração a partir de um curso real do Moodle.
  Future<CourseConfig> configFromCourse(
    MoodleCourse course,
    DateTime semesterStart,
  );
}
