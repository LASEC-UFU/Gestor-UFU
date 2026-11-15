import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/platform/command/module_command.dart';

/// Pastas e leitura de arquivos usadas pelos comandos dos módulos.
class GestorPaths {
  const GestorPaths._();

  static String get _home =>
      Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;

  /// Pasta padrão dos arquivos gerados por comandos (Documentos\GestorUFU
  /// Agente\<subpasta>).
  static Future<String> outputDir([String sub = '']) async {
    final dir = Directory(p.join(_home, 'Documents', 'GestorUFU Agente', sub));
    await dir.create(recursive: true);
    return dir.path;
  }

  /// Caminho de saída: [requested] se informado; senão a pasta padrão com
  /// [defaultName].
  static Future<String> outputPath(
    String? requested,
    String defaultName, {
    String sub = '',
  }) async {
    if (requested != null && requested.trim().isNotEmpty) {
      final file = File(requested.trim());
      await file.parent.create(recursive: true);
      return file.path;
    }
    return p.join(await outputDir(sub), defaultName);
  }

  /// Lê um arquivo de entrada de comando, com erro legível.
  static Future<Uint8List> readInput(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw CommandException(
        'arquivo_nao_encontrado',
        'Arquivo não encontrado: $path',
      );
    }
    return file.readAsBytes();
  }
}
