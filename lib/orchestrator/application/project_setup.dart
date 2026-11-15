import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/orchestrator/application/bundled_skills.dart';

/// "Preparar projeto (.ai)" (port de `prepareProject` do Orchestrator-AI):
/// cria `.ai/` com README, `specs/`, as skills genéricas e
/// `orchestrator.json`, só quando `.ai` ainda não existe. Monta numa pasta
/// temporária e renomeia no fim; nunca altera arquivos existentes.
Future<String> prepareOrchestratorProject(String projectPath) async {
  final root = projectPath.trim();
  if (root.isEmpty || !await Directory(root).exists()) {
    throw StateError('Escolha uma pasta de projeto existente.');
  }
  final ai = p.join(root, '.ai');
  final type = await FileSystemEntity.type(ai, followLinks: false);
  if (type != FileSystemEntityType.notFound) {
    return type == FileSystemEntityType.directory
        ? 'A pasta .ai já existe. Nenhum arquivo foi alterado.'
        : 'Já existe um item chamado .ai que não é uma pasta. Nenhum arquivo '
              'foi alterado.';
  }
  final suffix = Random().nextInt(1 << 32).toRadixString(16);
  final staging = Directory(p.join(root, '.ai.orquestrador-$suffix'));
  try {
    await Directory(p.join(staging.path, 'specs')).create(recursive: true);
    await File(p.join(staging.path, 'README.md')).writeAsString(
      '# Espaço de IA do projeto\n\n'
      '- `specs/`: requisitos, arquitetura e critérios de aceitação do '
      'projeto.\n'
      '- `skills/`: procedimentos reutilizáveis para os agentes que trabalham '
      'neste projeto.\n'
      '- Decisões do projeto ficam aqui; preferências pessoais ficam no perfil '
      'do AI Memory.\n',
    );
    await File(p.join(staging.path, 'specs', 'README.md')).writeAsString(
      '# Especificações do projeto\n\n'
      'Guarde aqui requisitos do produto, decisões de arquitetura, '
      'procedimentos de produção e critérios de aceitação. Mantenha cada '
      'especificação com escopo claro.\n',
    );
    for (final entry in orqBundledSkills.entries) {
      final file = File(p.join(staging.path, 'skills', entry.key, 'SKILL.md'));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    await File(p.join(staging.path, 'orchestrator.json')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'build': null, 'upstreams': [], 'tools': {}, 'orchestration': {}, 'workerDefaults': {}, 'aiMemory': {}})}\n',
    );
    if (await FileSystemEntity.type(ai, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await staging.delete(recursive: true);
      return 'A pasta .ai foi criada por outra ação. Nenhum arquivo existente '
          'foi alterado.';
    }
    await staging.rename(ai);
    return 'Projeto preparado em $ai com specs, skills e configuração inicial.';
  } on Object {
    if (await staging.exists()) await staging.delete(recursive: true);
    rethrow;
  }
}
