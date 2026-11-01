import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

class PreferencesBackupService {
  static const _format = 'gestor_ufu_shared_preferences';
  static const _version = 1;

  Future<String?> exportBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final values = <String, Object?>{};
    for (final key in prefs.getKeys()) {
      values[key] = prefs.get(key);
    }
    final payload = const JsonEncoder.withIndent('  ').convert({
      'format': _format,
      'version': _version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'preferences': values,
    });
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar backup dos dados',
      fileName:
          'gestor_ufu_backup_${DateTime.now().toIso8601String().substring(0, 10)}.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: Uint8List.fromList(utf8.encode(payload)),
    );
    if (result == null) return null;
    // On Windows saveFile writes the supplied bytes itself. The path is returned
    // for confirmation only; avoid writing twice or assuming a path on web.
    return result;
  }

  Future<PreferencesImportResult?> importBackup() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Selecionar backup do Gestor UFU',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: kIsWeb,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null)
      throw const FormatException(
        'Não foi possível ler o arquivo selecionado.',
      );

    final decoded = json.decode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != _format ||
        decoded['version'] != _version ||
        decoded['preferences'] is! Map) {
      throw const FormatException(
        'O arquivo não é um backup válido do Gestor UFU.',
      );
    }
    final values = Map<String, dynamic>.from(decoded['preferences'] as Map);
    // Validate all values before modifying local data.
    for (final entry in values.entries) {
      final value = entry.value;
      if (value != null &&
          value is! String &&
          value is! bool &&
          value is! int &&
          value is! double &&
          value is! List) {
        throw FormatException('Tipo de dado inválido na chave "${entry.key}".');
      }
      if (value is List && value.any((item) => item is! String)) {
        throw FormatException('Lista inválida na chave "${entry.key}".');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    var previousCount = 0;
    for (final key in prefs.getKeys()) {
      await prefs.remove(key);
      previousCount++;
    }
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is String) {
        await prefs.setString(entry.key, value);
      } else if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is List) {
        await prefs.setStringList(entry.key, value.cast<String>());
      }
    }
    return PreferencesImportResult(file.name, previousCount, values.length);
  }
}

class PreferencesImportResult {
  const PreferencesImportResult(
    this.fileName,
    this.previousCount,
    this.importedCount,
  );
  final String fileName;
  final int previousCount;
  final int importedCount;
}
