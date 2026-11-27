import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Workspace and public Gestor UFU variables shared by the local PowerShell
/// terminal and CLI agents. Provider/account credentials remain provider-only.
class GestorProcessEnvironment {
  GestorProcessEnvironment._();

  static const workspacePreferenceKey = 'gestor.shared_workspace_directory';

  static String get gestorHome => p.join(
    Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path,
    'GestorUFU',
  );

  static String get defaultWorkspace => p.join(
    Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path,
    'Documents',
    'GestorUFU Agente',
  );

  static Map<String, String> variablesFor(String workingDirectory) => {
    'GESTOR_UFU_HOME': gestorHome,
    'GESTOR_UFU_WORKSPACE': workingDirectory,
    'GESTOR_UFU_OUTPUT': workingDirectory,
  };

  static Future<String> workspaceDirectory({String? preferred}) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(workspacePreferenceKey)?.trim();
    final requested = preferred?.trim();
    final candidate = saved != null && saved.isNotEmpty
        ? saved
        : requested != null && requested.isNotEmpty
        ? requested
        : defaultWorkspace;
    final directory = Directory(candidate);
    await directory.create(recursive: true);
    return directory.path;
  }

  static Future<String> setWorkspaceDirectory(String path) async {
    final directory = Directory(path.trim());
    if (path.trim().isEmpty) {
      throw ArgumentError.value(
        path,
        'path',
        'O caminho não pode ficar vazio.',
      );
    }
    await directory.create(recursive: true);
    await (await SharedPreferences.getInstance()).setString(
      workspacePreferenceKey,
      directory.path,
    );
    return directory.path;
  }
}
