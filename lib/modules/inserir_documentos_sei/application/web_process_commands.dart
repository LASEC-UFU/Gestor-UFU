import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

const webStepSchema = {
  'type': 'object',
  'properties': {
    'id': {'type': 'string'},
    'name': {'type': 'string'},
    'action': {
      'type': 'string',
      'enum': [
        'fill',
        'click',
        'select',
        'check',
        'uncheck',
        'wait',
        'waitText',
        'read',
        'upload',
        'navigate',
        'pause',
      ],
    },
    'selector': {
      'type': 'string',
      'description': 'ID, #id ou seletor CSS do componente HTML.',
    },
    'value': {
      'type': 'string',
      'description':
          'Texto fixo ou {{campo}} do lote. Em click, texto exato do botão se houver vários; em pause, segundos.',
    },
    'transform': {
      'type': 'string',
      'enum': ['none', 'digits', 'trim', 'upper', 'lower'],
    },
    'framePath': {
      'type': 'array',
      'items': {'type': 'integer'},
    },
    'timeoutSeconds': {'type': 'integer', 'minimum': 1, 'maximum': 120},
  },
  'required': ['action'],
};

List<String>? _ids(CommandInput input) =>
    (input['recordIds'] as List?)?.cast<String>();

List<ModuleCommand> webProcessCommands(WebProcessService service) {
  ModuleCommand command(
    String action,
    String title,
    Future<CommandResult> Function(CommandInput) run, {
    Map<String, Object?> properties = const {},
    List<String> required = const [],
    bool mutates = false,
    bool approval = false,
    bool remote = true,
  }) => ModuleCommand(
    id: 'acoesWeb.$action',
    title: title,
    description: title,
    mutates: mutates,
    remoteEnabled: remote,
    approval: approval ? CommandApproval.required : CommandApproval.none,
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
    run: (input, origin) async {
      await service.load();
      return run(input);
    },
  );
  const pid = {'type': 'string', 'description': 'ID de acoesWeb.listar.'};
  return [
    command(
      'listar',
      'Listar processos de automação web',
      (input) async => CommandResult.ok(
        data: {
          'processes': service.projects.map((p) => p.toJson()).toList(),
          'busy': service.busy,
          'stage': service.stage,
        },
      ),
    ),
    command(
      'salvarProcesso',
      'Criar ou configurar processo web',
      (input) async {
        final json = input['process'];
        if (json is! Map) {
          throw const CommandException('entrada_invalida', 'Informe process.');
        }
        final item = await service.saveProcess(Map<String, dynamic>.from(json));
        return CommandResult.ok(
          message: 'Processo salvo.',
          data: {'processId': item.id},
        );
      },
      properties: {
        'process': {
          'type': 'object',
          'properties': {
            'id': pid,
            'name': {'type': 'string'},
            'url': {'type': 'string'},
            'steps': {'type': 'array', 'items': webStepSchema},
            'successText': {'type': 'string'},
            'outputDirectory': {'type': 'string'},
            'captureArtifacts': {'type': 'boolean'},
            'delayMinMs': {'type': 'integer'},
            'delayMaxMs': {'type': 'integer'},
          },
          'required': ['name', 'url'],
        },
      },
      required: ['process'],
      mutates: true,
    ),
    command(
      'adicionarEtapa',
      'Adicionar uma ação à sequência do processo',
      (input) async {
        final item = service.project(input.requireString('processId'));
        final data = Map<String, dynamic>.from(input['step'] as Map);
        data.putIfAbsent('id', () => const Uuid().v4());
        final step = WebStep.fromJson(data);
        await service.saveSteps(item.id, [...item.steps, step]);
        return CommandResult.ok(
          message: 'Etapa adicionada.',
          data: {'stepId': step.id},
        );
      },
      properties: {'processId': pid, 'step': webStepSchema},
      required: ['processId', 'step'],
      mutates: true,
    ),
    command(
      'atualizarEtapa',
      'Alterar ação, componente HTML e valor de uma etapa',
      (input) async {
        final item = service.project(input.requireString('processId'));
        final id = input.requireString('stepId');
        final old = item.steps.where((s) => s.id == id).firstOrNull;
        if (old == null) {
          throw const CommandException(
            'etapa_nao_encontrada',
            'Etapa não encontrada.',
          );
        }
        final step = WebStep.fromJson({
          ...old.toJson(),
          ...Map<String, dynamic>.from(input['step'] as Map),
          'id': id,
        });
        await service.saveSteps(item.id, [
          for (final s in item.steps) s.id == id ? step : s,
        ]);
        return const CommandResult.ok(message: 'Etapa atualizada.');
      },
      properties: {
        'processId': pid,
        'stepId': {'type': 'string'},
        'step': {...webStepSchema, 'required': <String>[]},
      },
      required: ['processId', 'stepId', 'step'],
      mutates: true,
    ),
    command(
      'reordenarEtapas',
      'Definir a ordem das ações de um processo',
      (input) async {
        final item = service.project(input.requireString('processId'));
        final order = (input['stepIds'] as List).cast<String>();
        final byId = {for (final s in item.steps) s.id: s};
        if (order.length != byId.length ||
            order.toSet().length != order.length ||
            order.any((id) => !byId.containsKey(id))) {
          throw const CommandException(
            'ordem_invalida',
            'Informe cada etapa exatamente uma vez.',
          );
        }
        await service.saveSteps(item.id, order.map((id) => byId[id]!).toList());
        return const CommandResult.ok(message: 'Ordem atualizada.');
      },
      properties: {
        'processId': pid,
        'stepIds': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      required: ['processId', 'stepIds'],
      mutates: true,
    ),
    command(
      'removerEtapa',
      'Remover uma ação do processo',
      (input) async {
        final item = service.project(input.requireString('processId'));
        await service.saveSteps(
          item.id,
          item.steps
              .where((s) => s.id != input.requireString('stepId'))
              .toList(),
        );
        return const CommandResult.ok(message: 'Etapa removida.');
      },
      properties: {
        'processId': pid,
        'stepId': {'type': 'string'},
      },
      required: ['processId', 'stepId'],
      mutates: true,
      approval: true,
    ),
    command(
      'duplicarProcesso',
      'Criar processo usando qualquer processo existente como modelo',
      (input) async {
        final item = await service.duplicateProcess(
          input.requireString('processId'),
          name: input.optionalString('name'),
          includeData: input.flag('includeData'),
        );
        return CommandResult.ok(
          message: 'Processo criado a partir do modelo.',
          data: {'processId': item.id},
        );
      },
      properties: {
        'processId': pid,
        'name': {'type': 'string'},
        'includeData': {
          'type': 'boolean',
          'description':
              'Copiar o lote com novos IDs e todos os registros pendentes. Padrão: false.',
        },
      },
      required: ['processId'],
      mutates: true,
    ),
    command('modeloPalmelo', 'Criar processo a partir do modelo Palmelo', (
      input,
    ) async {
      final item = await service.addPalmeloTemplate();
      return CommandResult.ok(
        message: 'Modelo criado sem dados pessoais.',
        data: {'processId': item.id},
      );
    }, mutates: true),
    command(
      'importarDados',
      'Importar lote dados.json para um processo',
      (input) async => CommandResult.ok(
        data: {
          'imported': await service.importData(
            input.requireString('processId'),
            input.requireString('path'),
          ),
        },
      ),
      properties: {
        'processId': pid,
        'path': {'type': 'string'},
      },
      required: ['processId', 'path'],
      mutates: true,
    ),
    command(
      'salvarRegistro',
      'Cadastrar ou editar um registro do lote',
      (input) async {
        await service.saveRecord(
          input.requireString('processId'),
          stringValues(input['values'] as Map),
          recordId: input.optionalString('recordId'),
        );
        return const CommandResult.ok(message: 'Registro salvo como pendente.');
      },
      properties: {
        'processId': pid,
        'recordId': {'type': 'string'},
        'values': {
          'type': 'object',
          'additionalProperties': {'type': 'string'},
        },
      },
      required: ['processId', 'values'],
      mutates: true,
    ),
    command(
      'removerRegistro',
      'Remover um registro do lote',
      (input) async {
        await service.removeRecord(
          input.requireString('processId'),
          input.requireString('recordId'),
        );
        return const CommandResult.ok(message: 'Registro removido.');
      },
      properties: {
        'processId': pid,
        'recordId': {'type': 'string'},
      },
      required: ['processId', 'recordId'],
      mutates: true,
      approval: true,
    ),
    command(
      'reabrirRegistro',
      'Marcar registro como pendente para executar novamente',
      (input) async {
        await service.resetRecord(
          input.requireString('processId'),
          input.requireString('recordId'),
        );
        return const CommandResult.ok(
          message: 'Registro marcado como pendente.',
        );
      },
      properties: {
        'processId': pid,
        'recordId': {'type': 'string'},
      },
      required: ['processId', 'recordId'],
      mutates: true,
      approval: true,
    ),
    command(
      'abrirSite',
      'Abrir o navegador do processo para login e configuração',
      (input) async {
        await service.openSite(input.requireString('processId'));
        return const CommandResult.ok(
          message:
              'Navegador aberto. Faça login manualmente quando necessário.',
        );
      },
      properties: {'processId': pid},
      required: ['processId'],
      remote: false,
    ),
    command(
      'selecionarElemento',
      'Selecionar visualmente um componente HTML no navegador',
      (input) async {
        final picked = await service.pickElement(
          input.requireString('processId'),
        );
        return CommandResult.ok(data: picked.toJson());
      },
      properties: {'processId': pid},
      required: ['processId'],
      remote: false,
    ),
    ModuleCommand(
      id: 'acoesWeb.executarProcesso',
      title: 'Executar processo web',
      description:
          'Executa as etapas em ordem, uma vez por registro pendente. Pode preencher, clicar, anexar e enviar dados ao site. Requer confirmação.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: const {
        'type': 'object',
        'properties': {
          'processId': pid,
          'recordIds': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['processId'],
      },
      run: (input, origin) async {
        await service.load();
        return CommandResult.ok(
          data: await service.run(
            input.requireString('processId'),
            recordIds: _ids(input),
          ),
        );
      },
      runRemote: (input, origin, context) async {
        await service.load();
        return CommandResult.ok(
          data: await service.run(
            input.requireString('processId'),
            recordIds: _ids(input),
            context: context,
          ),
        );
      },
    ),
    command('parar', 'Parar a execução após a etapa atual', (input) async {
      service.stop();
      return const CommandResult.ok(message: 'Parada solicitada.');
    }),
    command(
      'exportarProcesso',
      'Exportar configuração e etapas de um processo',
      (input) async => CommandResult.ok(
        data: {
          'path': await service.exportProcess(
            input.requireString('processId'),
            input.optionalString('path'),
          ),
        },
      ),
      properties: {
        'processId': pid,
        'path': {'type': 'string'},
      },
      required: ['processId'],
    ),
    command(
      'importarProcesso',
      'Importar processo exportado sem executar ações',
      (input) async {
        final item = await service.importProcess(input.requireString('path'));
        return CommandResult.ok(data: {'processId': item.id});
      },
      properties: {
        'path': {'type': 'string'},
      },
      required: ['path'],
      mutates: true,
    ),
    command(
      'exportarDados',
      'Exportar os dados do lote como JSON',
      (input) async => CommandResult.ok(
        data: {
          'path': await service.exportData(
            input.requireString('processId'),
            input.optionalString('path'),
          ),
        },
      ),
      properties: {
        'processId': pid,
        'path': {'type': 'string'},
      },
      required: ['processId'],
    ),
    command(
      'removerProcesso',
      'Remover processo e seus registros',
      (input) async {
        await service.removeProcess(input.requireString('processId'));
        return const CommandResult.ok(message: 'Processo removido.');
      },
      properties: {'processId': pid},
      required: ['processId'],
      mutates: true,
      approval: true,
    ),
  ];
}
