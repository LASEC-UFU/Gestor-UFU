import 'dart:convert';
import 'dart:io';

import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:gestor_ufu/modules/planos_ensino/application/cronograma_do_moodle.dart';
import 'package:gestor_ufu/modules/planos_ensino/application/planos_ensino_service.dart';
import 'package:gestor_ufu/modules/planos_ensino/data/planos_ensino_automation_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/moodle_planning.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

const _planoId = {
  'id': {'type': 'string', 'description': 'id de planosEnsino.listar'},
};

String _nome(Map<String, dynamic> plan) =>
    '${(plan['identificacao'] as Map?)?['nome'] ?? ''}';

/// Comandos dos Planos de Ensino (tela, menu "/" e Agente de IA).
List<ModuleCommand> planosEnsinoCommands(
  PlanosEnsinoService service,
  PlanosEnsinoAutomationService sei,
  MoodlePlanning? Function() moodle,
) {
  Future<Map<String, dynamic>> plano(String id) async {
    for (final p in await service.list()) {
      if (p['id'] == id) return p;
    }
    throw CommandException(
      'plano_nao_encontrado',
      'Plano "$id" não encontrado.',
    );
  }

  return [
    ModuleCommand(
      id: 'planosEnsino.listar',
      title: 'Listar planos de ensino',
      description:
          'Planos (id, nome, código, turma, campos faltantes). Com id, devolve '
          'o plano completo.',
      inputSchema: {'type': 'object', 'properties': _planoId},
      run: (input, origin) async {
        final id = input.optionalString('id');
        if (id != null) {
          return CommandResult.ok(data: {'plano': await plano(id)});
        }
        return CommandResult.ok(
          data: {
            'planos': [
              for (final p in await service.list())
                {
                  'id': p['id'],
                  'nome': _nome(p),
                  'codigo': (p['identificacao'] as Map?)?['codigo'],
                  'turma': (p['identificacao'] as Map?)?['turma'],
                  'faltando': PlanosEnsinoService.missingFields(p),
                },
            ],
          },
        );
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.salvar',
      title: 'Salvar plano de ensino',
      description:
          'Cria ou atualiza um plano (objeto no formato da skill; sem id cria '
          'um novo). Campos ausentes recebem valor vazio.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'plano': {'type': 'object'},
        },
        'required': ['plano'],
      },
      run: (input, origin) async {
        final raw = input['plano'];
        if (raw is! Map) {
          throw const CommandException('entrada_invalida', 'Informe "plano".');
        }
        final map = Map<String, dynamic>.from(raw);
        final id = '${map['id'] ?? DateTime.now().microsecondsSinceEpoch}'
            .trim();
        final normalized = service.normalize(map, id);
        await service.save(normalized);
        return CommandResult.ok(
          message: 'Plano "${_nome(normalized)}" salvo.',
          data: {
            'id': id,
            'faltando': PlanosEnsinoService.missingFields(normalized),
          },
        );
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.importarWord',
      title: 'Importar plano de ensino do Word (.docx)',
      description:
          'Lê o .docx (seções Ementa, Justificativa, Cronograma…) e grava como '
          'novo plano.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (input, origin) async {
        final path = input.requireString('path');
        final Map<String, dynamic> plan;
        try {
          plan = service.importDocx(
            await GestorPaths.readInput(path),
            DateTime.now().microsecondsSinceEpoch.toString(),
          );
        } on FormatException catch (error) {
          throw CommandException('arquivo_invalido', error.message);
        }
        plan['sourceDocxName'] = File(path).uri.pathSegments.last;
        await service.save(plan);
        return CommandResult.ok(
          message: 'Plano "${_nome(plan)}" importado.',
          data: {
            'id': plan['id'],
            'faltando': PlanosEnsinoService.missingFields(plan),
          },
        );
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.exportarWord',
      title: 'Exportar plano para Word (.docx)',
      description: 'Gera o .docx do plano (path opcional).',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'path': {'type': 'string'},
        },
        'required': ['id'],
      },
      run: (input, origin) async {
        final plan = await plano(input.requireString('id'));
        final code = '${(plan['identificacao'] as Map?)?['codigo'] ?? 'plano'}'
            .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
        final path = await GestorPaths.outputPath(
          input.optionalString('path'),
          'Plano_de_Ensino_$code.docx',
          sub: 'planos_ensino',
        );
        await File(path).writeAsBytes(PlanosEnsinoService.exportDocx(plan));
        return CommandResult.ok(message: 'Word gerado.', data: {'path': path});
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.importarBackup',
      title: 'Importar backup de planos (JSON)',
      description: 'Lista de planos em JSON; mescla pelo id.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (input, origin) async {
        final data = jsonDecode(
          utf8.decode(await GestorPaths.readInput(input.requireString('path'))),
        );
        if (data is! List) {
          throw const CommandException(
            'json_invalido',
            'O arquivo precisa conter uma lista de planos.',
          );
        }
        var count = 0;
        for (final item in data.whereType<Map>()) {
          final plan = Map<String, dynamic>.from(item);
          final id =
              plan['id']?.toString() ??
              DateTime.now().microsecondsSinceEpoch.toString();
          await service.save(service.normalize(plan, id));
          count++;
        }
        return CommandResult.ok(message: '$count plano(s) mesclado(s).');
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.exportarBackup',
      title: 'Exportar backup de planos (JSON)',
      description: 'Salva todos os planos em JSON (path opcional).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
      run: (input, origin) async {
        final path = await GestorPaths.outputPath(
          input.optionalString('path'),
          'planos_ensino.json',
          sub: 'planos_ensino',
        );
        await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert(await service.list()),
        );
        return CommandResult.ok(message: 'Backup salvo.', data: {'path': path});
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.aplicarCronograma',
      title: 'Aplicar cronograma colado',
      description:
          'Aplica um cronograma em texto com colunas separadas por TAB (Data, '
          'Modalidade, Matéria Lecionada/Atividades…) ao plano.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'texto': {'type': 'string'},
        },
        'required': ['id', 'texto'],
      },
      run: (input, origin) async {
        final plan = await plano(input.requireString('id'));
        final Map<String, dynamic> updated;
        try {
          updated = PlanosEnsinoService.applyPastedSchedule(
            plan,
            input.requireString('texto'),
          );
        } on FormatException catch (error) {
          throw CommandException('cronograma_invalido', error.message);
        }
        await service.save(updated);
        return CommandResult.ok(
          message:
              '${(updated['cronograma_teorico'] as List).length} aula(s) '
              'teórica(s) e ${(updated['cronograma_pratico'] as List).length} '
              'prática(s).',
        );
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.cronogramaDoMoodle',
      title: 'Extrair cronograma do Config Moodle',
      description:
          'Monta os cronogramas teórico e prático a partir de uma configuração '
          'do Config Moodle (configId de moodle.listar). substituir=false '
          'mescla com o cronograma atual.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'configId': {'type': 'string'},
          'substituir': {'type': 'boolean'},
        },
        'required': ['id', 'configId'],
      },
      run: (input, origin) async {
        final planning = moodle();
        if (planning == null) {
          throw const CommandException(
            'moodle_indisponivel',
            'O módulo Config Moodle não está instalado.',
          );
        }
        final configId = input.requireString('configId');
        CourseConfig? config;
        for (final c in await planning.savedConfigs()) {
          if (c.id == configId) config = c;
        }
        if (config == null) {
          throw CommandException(
            'configuracao_nao_encontrada',
            'Configuração "$configId" não encontrada.',
          );
        }
        final plan = await plano(input.requireString('id'));
        final schedule = CronogramaDoMoodle.extrair(config);
        final replace = input.flag('substituir', fallback: true);
        plan['cronograma_teorico'] = replace
            ? schedule.teorico
            : CronogramaDoMoodle.mesclar(
                (plan['cronograma_teorico'] as List).whereType<Map>(),
                schedule.teorico,
              );
        plan['cronograma_pratico'] = replace
            ? schedule.pratico
            : CronogramaDoMoodle.mesclar(
                (plan['cronograma_pratico'] as List).whereType<Map>(),
                schedule.pratico,
              );
        await service.save(plan);
        return CommandResult.ok(
          message:
              '${schedule.teorico.length} aula(s) teórica(s) e '
              '${schedule.pratico.length} prática(s) de ${config.name}.',
        );
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.remover',
      title: 'Remover plano de ensino',
      description: 'Remove o plano. Pede confirmação.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': _planoId,
        'required': ['id'],
      },
      run: (input, origin) async {
        final plan = await plano(input.requireString('id'));
        await service.remove('${plan['id']}');
        return CommandResult.ok(message: 'Plano "${_nome(plan)}" removido.');
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.abrirSei',
      title: 'Abrir o SEI no Edge (planos de ensino)',
      description:
          'Abre o Edge do SEI dos planos (url opcional). O usuário faz login e '
          'abre o processo.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
      },
      run: (input, origin) async {
        final opened = await sei.openBrowser(
          input.optionalString('url') ?? 'https://sei.ufu.br',
        );
        return CommandResult.ok(
          message:
              'SEI aberto em $opened. Peça ao usuário para entrar e abrir o '
              'processo antes de inserir.',
        );
      },
    ),
    ModuleCommand(
      id: 'planosEnsino.inserirNoSei',
      title: 'Inserir plano de ensino no SEI',
      description:
          'Cria o documento do plano no processo aberto no Edge (salvo sem '
          'assinatura). Exige o plano completo. Pede confirmação.',
      approval: CommandApproval.required,
      inputSchema: {
        'type': 'object',
        'properties': _planoId,
        'required': ['id'],
      },
      run: (input, origin) async {
        final plan = await plano(input.requireString('id'));
        final missing = PlanosEnsinoService.missingFields(plan);
        if (missing.isNotEmpty) {
          throw CommandException(
            'plano_incompleto',
            'Preencha antes de inserir: ${missing.join(', ')}.',
          );
        }
        if (!sei.isConnected) {
          throw const CommandException(
            'sei_fechado',
            'Abra o SEI (planosEnsino.abrirSei) e o processo antes de inserir.',
          );
        }
        final logs = <String>[];
        await sei.insertPlan(plan, logs.add);
        return CommandResult.ok(
          message:
              'Plano inserido no SEI (sem assinatura). Peça ao usuário para '
              'conferir e assinar.',
          data: {'log': logs.take(40).toList()},
        );
      },
    ),
  ];
}
