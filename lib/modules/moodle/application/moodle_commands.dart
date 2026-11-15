import 'dart:io';

import 'package:gestor_ufu/modules/moodle/controllers/config_controller.dart';
import 'package:gestor_ufu/modules/moodle/data/template_generator.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/navigation_service.dart';

const _configId = {
  'configId': {'type': 'string', 'description': 'id de moodle.listar'},
};

/// Comandos do Config Moodle (tela, menu "/" e Agente de IA).
List<ModuleCommand> moodleCommands(ConfigController config) {
  Future<void> requireConfig(String id) async {
    await config.loadAll();
    if (!config.configs.any((c) => c.id == id)) {
      throw CommandException(
        'configuracao_nao_encontrada',
        'Configuração "$id" não encontrada no período ${config.activeTerm}.',
      );
    }
  }

  return [
    ModuleCommand(
      id: 'moodle.listar',
      title: 'Listar configurações do Moodle',
      description:
          'Configurações do período ativo: id, nome, curso no Moodle, início '
          'do semestre, nº de seções e de atividades.',
      run: (input, origin) async {
        await config.loadAll();
        return CommandResult.ok(
          data: {
            'periodo': config.activeTerm,
            'configuracoes': [
              for (final c in config.configs)
                {
                  'id': c.id,
                  'nome': c.name,
                  'moodleCourseId': c.moodleCourseId,
                  'moodleCourseName': c.moodleCourseName,
                  'inicioSemestre': c.semesterStartDate.toIso8601String(),
                  'secoes': c.sections.length,
                  'atividades': c.sections.fold<int>(
                    0,
                    (sum, s) => sum + s.activities.length,
                  ),
                },
            ],
          },
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.importarPlanilha',
      title: 'Importar planilha de disciplina (.xlsx)',
      description:
          'Importa a planilha no formato do Config Moodle (modelo '
          'moodle_planilha): cada aba vira uma configuração. substituirId '
          'troca uma configuração existente.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'substituirId': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (input, origin) async {
        final path = input.requireString('path');
        await GestorPaths.readInput(path);
        final ok = await config.importSpreadsheet(
          path,
          replaceId: input.optionalString('substituirId'),
        );
        if (!ok) {
          throw CommandException(
            'importacao_falhou',
            config.error ?? 'Não foi possível importar a planilha.',
          );
        }
        return CommandResult.ok(
          message:
              'Planilha importada; ${config.configs.length} configuração(ões) '
              'no período ${config.activeTerm}.',
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.exportarPlanilha',
      title: 'Exportar configuração para planilha (.xlsx)',
      description: 'Exporta no mesmo formato da importação (path opcional).',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._configId,
          'path': {'type': 'string'},
        },
        'required': ['configId'],
      },
      run: (input, origin) async {
        final id = input.requireString('configId');
        await requireConfig(id);
        final bytes = await config.exportSpreadsheetBytes(id);
        if (bytes == null) {
          throw CommandException(
            'exportacao_falhou',
            config.error ?? 'Falha ao exportar.',
          );
        }
        final name = config.configs.firstWhere((c) => c.id == id).name;
        final path = await GestorPaths.outputPath(
          input.optionalString('path'),
          '${name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.xlsx',
          sub: 'moodle',
        );
        await File(path).writeAsBytes(bytes);
        return CommandResult.ok(
          message: 'Planilha exportada.',
          data: {'path': path},
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.excluir',
      title: 'Excluir configuração',
      description:
          'Exclui uma configuração do Config Moodle. Pede confirmação.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': _configId,
        'required': ['configId'],
      },
      run: (input, origin) async {
        final id = input.requireString('configId');
        await requireConfig(id);
        await config.deleteConfig(id);
        return const CommandResult.ok(message: 'Configuração excluída.');
      },
    ),
    ModuleCommand(
      id: 'moodle.abrirEditor',
      title: 'Abrir o editor da configuração',
      description: 'Mostra ao usuário a tabela de seções e atividades.',
      inputSchema: {
        'type': 'object',
        'properties': _configId,
        'required': ['configId'],
      },
      run: (input, origin) async {
        final id = input.requireString('configId');
        await requireConfig(id);
        NavigationService.go('/editor/$id');
        return const CommandResult.ok(
          message: 'Editor aberto na janela principal.',
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.abrirSincronizacao',
      title: 'Abrir a sincronização com o Moodle',
      description:
          'Abre a prévia da sincronização da configuração com o curso no '
          'Moodle; o usuário confere as mudanças e aplica na tela.',
      inputSchema: {
        'type': 'object',
        'properties': _configId,
        'required': ['configId'],
      },
      run: (input, origin) async {
        final id = input.requireString('configId');
        await requireConfig(id);
        NavigationService.go('/sync/$id');
        return const CommandResult.ok(
          message:
              'Prévia de sincronização aberta. O usuário confere e aplica na tela.',
        );
      },
    ),
  ];
}

/// Modelo da planilha de importação (botão "Baixar Planilha Modelo" e
/// `create_template`).
(String, List<int>, String) moodleTemplate({
  List<List<Object?>>? rows,
  Object? data,
  Map<String, dynamic> options = const {},
}) {
  final swaps = <DateTime, int>{};
  final rawSwaps = options['day_swaps'];
  if (rawSwaps is Map) {
    for (final entry in rawSwaps.entries) {
      final date = DateTime.tryParse('${entry.key}');
      final weekday = int.tryParse('${entry.value}');
      if (date != null && weekday != null) swaps[date] = weekday;
    }
  }
  return (
    'config_moodle_modelo.xlsx',
    TemplateGenerator.generateTemplate(
      sheetName: '${options['sheet_name'] ?? 'Disciplina'}',
      courseName: '${options['course_name'] ?? 'NOME DA DISCIPLINA NO MOODLE'}',
      moodleCourseId: options['moodle_course_id'],
      semesterStart: DateTime.tryParse('${options['semester_start'] ?? ''}'),
      rows: rows,
      holidays: [
        for (final date in (options['holidays'] as List? ?? const []))
          ?DateTime.tryParse('$date'),
      ],
      daySwaps: swaps,
    ),
    'Config Moodle → "Novo" → "Importar Planilha (.xlsx)". Cada aba com a '
        'linha de cabeçalho "Ordem … Tipo" vira uma configuração.',
  );
}
