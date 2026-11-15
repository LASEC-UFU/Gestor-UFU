import 'package:gestor_ufu/modules/_modelo/application/modelo_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

/// Comandos do módulo: o que a tela faz, exposto ao menu "/" e ao Agente de
/// IA (ferramentas list_commands/run_command). Cada comando valida a
/// entrada, chama o serviço e devolve um [CommandResult].
List<ModuleCommand> modeloCommands(ModeloService service) => [
  ModuleCommand(
    id: 'modelo.listar',
    title: 'Listar notas',
    description: 'Notas salvas (id, texto, data).',
    run: (input, origin) async => CommandResult.ok(
      data: {
        'notas': [for (final n in await service.listar()) n.toJson()],
      },
    ),
  ),
  ModuleCommand(
    id: 'modelo.adicionar',
    title: 'Adicionar nota',
    description: 'Cria uma nota com o texto informado.',
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'texto': {'type': 'string'},
      },
      'required': ['texto'],
    },
    run: (input, origin) async {
      final nota = await service.adicionar(input.requireString('texto'));
      return CommandResult.ok(message: 'Nota criada.', data: {'id': nota.id});
    },
  ),
  ModuleCommand(
    id: 'modelo.remover',
    title: 'Remover nota',
    description: 'Apaga uma nota. Pede confirmação.',
    // Ações destrutivas ou externas: o agente mostra um cartão de
    // aprovação antes de executar.
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'id de modelo.listar'},
      },
      'required': ['id'],
    },
    run: (input, origin) async {
      final nota = await service.remover(input.requireString('id'));
      return CommandResult.ok(message: 'Nota "${nota.texto}" removida.');
    },
  ),
];
