import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/data/datasources/moodle_datasource.dart';
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';
import 'package:gestor_ufu/domain/repositories/i_moodle_repository.dart';

class MoodleRepositoryImpl implements IMoodleRepository {
  final MoodleDatasource _datasource;
  static const _credKey = 'moodle_credential';

  MoodleRepositoryImpl(this._datasource);

  @override
  Future<MoodleCredential> login(
    String baseUrl,
    String username,
    String password,
  ) async {
    return _datasource.login(baseUrl, username, password);
  }

  @override
  Future<MoodleCredential?> getSavedCredential() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_credKey);
    if (raw == null) return null;
    final cred = MoodleCredential.fromJson(
      json.decode(raw) as Map<String, dynamic>,
    );
    // Disponibilizar credenciais para sessão AJAX sob demanda
    if (cred.password.isNotEmpty) {
      _datasource.setCredentials(cred.username, cred.password);
    }
    return cred;
  }

  @override
  Future<void> saveCredential(MoodleCredential credential) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_credKey, json.encode(credential.toJson()));
  }

  @override
  Future<void> clearCredential() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_credKey);
  }

  @override
  Future<List<MoodleCourse>> getCourses(String token, String baseUrl) async {
    final cred = await getSavedCredential();
    if (cred == null) throw Exception('Usuário não autenticado');
    return _datasource.getCourses(token, baseUrl, cred.userId);
  }

  @override
  Future<List<MoodleSection>> getCourseContents(
    String token,
    String baseUrl,
    int courseId,
  ) async {
    return _datasource.getCourseContents(token, baseUrl, courseId);
  }

  @override
  Future<void> updateSectionName(
    String token,
    String baseUrl,
    int sectionId,
    String newName,
  ) async {
    return _datasource.updateSectionName(token, baseUrl, sectionId, newName);
  }

  @override
  Future<void> updateModuleVisibility(
    String token,
    String baseUrl,
    int moduleId,
    int visibility,
  ) async {
    return _datasource.updateModuleVisibility(
      token,
      baseUrl,
      moduleId,
      visibility,
    );
  }

  @override
  Future<void> updateModuleName(
    String token,
    String baseUrl,
    int moduleId,
    String newName,
  ) async {
    return _datasource.updateModuleName(token, baseUrl, moduleId, newName);
  }

  @override
  Future<void> updateLabelContent(
    String token,
    String baseUrl,
    int moduleId,
    int instanceId,
    String htmlContent,
  ) async {
    return _datasource.updateLabelContent(
      token,
      baseUrl,
      moduleId,
      instanceId,
      htmlContent,
    );
  }

  @override
  Future<String> moveModule(
    String token,
    String baseUrl,
    int courseId,
    int moduleId,
    int? targetCmId,
    int targetSectionId,
  ) async {
    return _datasource.moveModule(
      token,
      baseUrl,
      courseId,
      moduleId,
      targetCmId,
      targetSectionId,
    );
  }

  @override
  Future<String> updateModuleDates(
    String token,
    String baseUrl,
    int cmid,
    String modname,
    DateTime? openDate,
    DateTime? closeDate,
  ) async {
    return _datasource.updateModuleDates(
      baseUrl,
      cmid,
      modname,
      openDate,
      closeDate,
    );
  }
}
