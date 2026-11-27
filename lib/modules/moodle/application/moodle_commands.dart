import 'dart:io';

import 'package:gestor_ufu/modules/moodle/controllers/config_controller.dart';
import 'package:gestor_ufu/modules/moodle/controllers/auth_controller.dart';
import 'package:gestor_ufu/modules/moodle/controllers/sync_controller.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/modules/moodle/data/template_generator.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/navigation_service.dart';

const _configId = {
  'configId': {'type': 'string', 'description': 'id de moodle.listar'},
};

/// Comandos do Config Moodle (tela, menu "/" e Agente de IA).
List<ModuleCommand> moodleCommands(
  ConfigController config, {
  AuthController? auth,
  SyncController? sync,
}) {
  Future<void> requireConfig(String id) async {
    await config.loadAll();
    if (!config.configs.any((c) => c.id == id)) {
      throw CommandException(
        'configuracao_nao_encontrada',
        'Configuração "$id" não encontrada no período ${config.activeTerm}.',
      );
    }
  }

  Future<CommandResult> synchronize(
    CommandInput input, {
    CommandExecutionContext? context,
  }) async {
    final moodleAuth = auth;
    final syncController = sync;
    if (moodleAuth == null || syncController == null) {
      throw const CommandException(
        'moodle_indisponivel',
        'A sincronização não foi configurada nesta instância.',
      );
    }
    final id = input.requireString('configId');
    if (!moodleAuth.isLoggedIn) {
      throw const CommandException(
        'moodle_desconectado',
        'Faça login no Moodle pela instalação Windows antes de sincronizar.',
      );
    }
    await config.loadById(id);
    final selected = config.current;
    if (selected == null || selected.moodleCourseId == null) {
      throw const CommandException(
        'curso_nao_vinculado',
        'Consulte e edite a configuração para vinculá-la a um curso do Moodle antes de sincronizar.',
      );
    }
    context?.checkCancellation();
    await syncController.loadMoodleSections(
      moodleAuth.token,
      moodleAuth.baseUrl,
      selected.moodleCourseId!,
    );
    context?.checkCancellation();
    if (syncController.error != null) {
      throw CommandException('moodle_leitura_falhou', syncController.error!);
    }
    syncController.generateMatches(selected);
    void reportProgress() => context?.reportProgress(
      syncController.progressMessage,
      fraction: syncController.progress,
    );
    if (context != null) syncController.addListener(reportProgress);
    try {
      await syncController.syncToMoodle(
        moodleAuth.token,
        moodleAuth.baseUrl,
        selected,
        isCancellationRequested: context == null
            ? null
            : () => context.cancellationRequested,
      );
      context?.checkCancellation();
      if (syncController.error != null) {
        return CommandResult.fail(
          'moodle_sync_com_problemas',
          syncController.progressMessage,
          data: {
            'detalhes': syncController.error,
            'log': syncController.syncLog,
            'secoes': syncController.matches.length,
          },
        );
      }
      return CommandResult.ok(
        message: syncController.progressMessage,
        data: {
          'log': syncController.syncLog,
          'secoes': syncController.matches.length,
        },
      );
    } finally {
      if (context != null) syncController.removeListener(reportProgress);
    }
  }

  return [
    ModuleCommand(
      id: 'moodle.listarPeriodos',
      title: 'Listar períodos letivos',
      description:
          'Mostra os períodos existentes e o período atualmente ativo.',
      run: (input, origin) async {
        await config.loadAll();
        return CommandResult.ok(
          data: {'periodoAtivo': config.activeTerm, 'periodos': config.terms},
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.selecionarPeriodo',
      title: 'Selecionar período letivo',
      description:
          'Troca o período ativo do Config Moodle neste computador Windows.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'periodo': {'type': 'string'},
        },
        'required': ['periodo'],
      },
      run: (input, origin) async {
        await config.loadAll();
        final term = input.requireString('periodo');
        if (!config.terms.contains(term)) {
          throw const CommandException(
            'periodo_nao_encontrado',
            'O período informado não existe. Consulte moodle.listarPeriodos.',
          );
        }
        await config.setActiveTerm(term);
        return CommandResult.ok(
          message: 'Período ativo: ${config.activeTerm}.',
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.criarPeriodo',
      title: 'Criar período letivo',
      description: 'Cria e seleciona um novo período letivo no Config Moodle.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'nome': {'type': 'string'},
        },
        'required': ['nome'],
      },
      run: (input, origin) async {
        final name = input.requireString('nome');
        await config.createTerm(name);
        return CommandResult.ok(
          message: 'Período ativo: ${config.activeTerm}.',
          data: {'periodos': config.terms},
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.criarConfiguracao',
      title: 'Criar configuração vazia',
      description: 'Cria uma configuração no período letivo ativo.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'nome': {'type': 'string'},
        },
        'required': ['nome'],
      },
      run: (input, origin) async {
        final name = input.requireString('nome');
        await config.loadAll();
        final existingIds = config.configs.map((item) => item.id).toSet();
        await config.createEmpty(name);
        final created = config.configs.firstWhere(
          (item) => !existingIds.contains(item.id),
        );
        return CommandResult.ok(
          message: 'Configuração criada.',
          data: {'configuracao': created.toJson()},
        );
      },
    ),
    ModuleCommand(
      id: 'moodle.obterConfiguracao',
      title: 'Consultar configuração completa',
      description:
          'Retorna em JSON a configuração completa, com seções, atividades, vínculos e datas.',
      inputSchema: {
        'type': 'object',
        'properties': _configId,
        'required': ['configId'],
      },
      run: (input, origin) async {
        final id = input.requireString('configId');
        await config.loadAll();
        final matches = config.configs.where((item) => item.id == id);
        if (matches.isEmpty) {
          throw CommandException(
            'configuracao_nao_encontrada',
            'Configuração "$id" não encontrada no período ${config.activeTerm}.',
          );
        }
        return CommandResult.ok(data: {'configuracao': matches.first.toJson()});
      },
    ),
    ModuleCommand(
      id: 'moodle.salvarConfiguracao',
      title: 'Salvar configuração completa (JSON)',
      description:
          'Atualiza a configuração existente usando o objeto retornado por moodle.obterConfiguracao. Permite editar seções, atividades, datas e vínculos.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'configuracao': {'type': 'object'},
        },
        'required': ['configuracao'],
      },
      run: (input, origin) async {
        final raw = input['configuracao'];
        if (raw is! Map) {
          throw const CommandException(
            'entrada_invalida',
            'Envie configuracao como um objeto JSON.',
          );
        }
        try {
          final updated = CourseConfig.fromJson(Map<String, dynamic>.from(raw));
          await config.loadAll();
          if (!config.configs.any((item) => item.id == updated.id)) {
            throw CommandException(
              'configuracao_nao_encontrada',
              'A configuração ${updated.id} não existe no período ativo.',
            );
          }
          await config.saveNewConfig(updated);
          return CommandResult.ok(
            message: 'Configuração salva.',
            data: {'id': updated.id},
          );
        } on CommandException {
          rethrow;
        } catch (error) {
          throw CommandException(
            'configuracao_invalida',
            'JSON de configuração inválido: $error',
          );
        }
      },
    ),
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
      remoteEnabled: false,
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
      remoteEnabled: false,
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
    ModuleCommand(
      id: 'moodle.sincronizarAgora',
      title: 'Sincronizar configuração com o Moodle',
      description:
          'Atualiza no Moodle seções, atividades, visibilidade e datas usando os vínculos atuais. Operação externa que exige confirmação.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': _configId,
        'required': ['configId'],
      },
      run: (input, origin) => synchronize(input),
      runRemote: (input, origin, context) =>
          synchronize(input, context: context),
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
