import 'package:gestor_ufu/domain/entities/moodle_entities.dart';

abstract class IMoodleRepository {
  Future<MoodleCredential> login(
    String baseUrl,
    String username,
    String password,
  );
  Future<MoodleCredential?> getSavedCredential();
  Future<void> saveCredential(MoodleCredential credential);
  Future<void> clearCredential();
  Future<List<MoodleCourse>> getCourses(String token, String baseUrl);
  Future<List<MoodleSection>> getCourseContents(
    String token,
    String baseUrl,
    int courseId,
  );
  Future<void> updateSectionName(
    String token,
    String baseUrl,
    int sectionId,
    String newName,
  );
  Future<void> updateModuleVisibility(
    String token,
    String baseUrl,
    int moduleId,
    int visibility,
  );
  Future<void> updateModuleName(
    String token,
    String baseUrl,
    int moduleId,
    String newName,
  );
  Future<void> updateLabelContent(
    String token,
    String baseUrl,
    int moduleId,
    int instanceId,
    String htmlContent,
  );
  Future<String> moveModule(
    String token,
    String baseUrl,
    int courseId,
    int moduleId,
    int? targetCmId,
    int targetSectionId,
  );
  Future<String> updateModuleDates(
    String token,
    String baseUrl,
    int cmid,
    String modname,
    DateTime? openDate,
    DateTime? closeDate,
  );
}
