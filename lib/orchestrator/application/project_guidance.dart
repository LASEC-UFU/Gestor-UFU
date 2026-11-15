import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/orchestrator/domain/secret_redaction.dart';

/// Lê as orientações do projeto para o coordenador e os trabalhadores (port
/// de `projectGuidance.js`): `AGENTS.md`, `.github/copilot-instructions.md`
/// e os Markdown de `.ai/specs`, `.ai/skills` e `.github/instructions`, com
/// limites de tamanho e sem seguir atalhos para fora do projeto.
class ProjectGuidance {
  static const maxFiles = 40;
  static const maxFileBytes = 64 * 1024;
  static const maxFileChars = 6000;
  static const maxChars = 18000;

  static Future<String> load(String projectRoot) async {
    if (projectRoot.trim().isEmpty) return '';
    final root = Directory(projectRoot);
    if (!await root.exists()) return '';
    final rootPath = await root.resolveSymbolicLinks();
    final files = <(String, String)>[];
    for (final relative in ['AGENTS.md', '.github/copilot-instructions.md']) {
      final file = File(p.join(rootPath, relative));
      if (await file.exists() &&
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file) {
        files.add((file.path, relative));
      }
    }
    for (final dir in ['.ai/specs', '.ai/skills', '.github/instructions']) {
      await _collect(rootPath, p.join(rootPath, dir), dir, files, 0);
    }
    final unique = <String, (String, String)>{
      for (final f in files) f.$2: f,
    }.values.take(maxFiles).toList();
    final sections = <String>[];
    var used = 0;
    var truncated = files.length > unique.length;
    for (final (absolute, relative) in unique) {
      final file = File(absolute);
      if (await file.length() > maxFileBytes) {
        truncated = true;
        continue;
      }
      var text = redactSensitiveText(
        await file.readAsString(),
        max: maxFileChars,
      );
      if (text.length >= maxFileChars) truncated = true;
      final section = '--- $relative ---\n$text';
      if (used + section.length > maxChars) {
        truncated = true;
        break;
      }
      used += section.length;
      sections.add(section);
    }
    if (sections.isEmpty) return '';
    return [
      'Instruções, especificações e skills do projeto (do próprio projeto; '
          'siga as regras relevantes, salvo conflito com o pedido do usuário ou '
          'com a segurança):',
      ...sections,
      if (truncated)
        '[Alguns arquivos de orientação foram omitidos ou cortados para manter '
            'o contexto limitado.]',
    ].join('\n');
  }

  static Future<void> _collect(
    String root,
    String directory,
    String relativeDir,
    List<(String, String)> output,
    int depth,
  ) async {
    if (depth > 6 || output.length >= maxFiles) return;
    final dir = Directory(directory);
    if (!await dir.exists()) return;
    if (await FileSystemEntity.isLink(directory)) return;
    final real = await dir.resolveSymbolicLinks();
    if (!p.isWithin(root, real) && !p.equals(root, real)) return;
    final entries = await dir.list(followLinks: false).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final entry in entries) {
      if (output.length >= maxFiles) return;
      final name = p.basename(entry.path);
      final relative = '$relativeDir/$name';
      if (entry is Directory) {
        if (name == '.git' || name == 'node_modules') continue;
        await _collect(root, entry.path, relative, output, depth + 1);
      } else if (entry is File && name.toLowerCase().endsWith('.md')) {
        output.add((entry.path, relative));
      }
    }
  }
}
