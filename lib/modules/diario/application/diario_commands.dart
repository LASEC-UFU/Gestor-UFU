import 'package:gestor_ufu/modules/diario/application/diario_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

const _periodo = {
  'periodo': {
    'type': 'string',
    'description': 'Período letivo (padrão: o ativo).',
  },
};

/// Comandos do Preenche Diários (tela, menu "/" e Agente de IA).
List<ModuleCommand> diarioCommands(DiarioService service) => [
  ModuleCommand(
    id: 'diario.listar',
    title: 'Listar diários e lançamentos',
    description:
        'Períodos, diários salvos e o rascunho do período; com '
        'lancamentos=true devolve os lançamentos {"DD/MM/AAAA -T": conteúdo}.',
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._periodo,
        'lancamentos': {'type': 'boolean'},
      },
    },
    run: (input, origin) async => CommandResult.ok(
      data: await service.list(
        term: input.optionalString('periodo'),
        entries: input.flag('lancamentos'),
      ),
    ),
  ),
  ModuleCommand(
    id: 'diario.importarPlanilha',
    title: 'Importar planilha de aulas (.xlsx)',
    description:
        'Lê Data | Modalidade | Matéria Lecionada (modelo diario_planilha) da '
        'aba informada (padrão: primeira) e MESCLA no rascunho do período '
        '(substituir=true troca tudo).',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'aba': {'type': 'string'},
        'substituir': {'type': 'boolean'},
        ..._periodo,
      },
      'required': ['path'],
    },
    run: (input, origin) async {
      final r = await service.importWorkbook(
        input.requireString('path'),
        sheet: input.optionalString('aba'),
        term: input.optionalString('periodo'),
        replace: input.flag('substituir'),
      );
      return CommandResult.ok(
        message:
            '${r.valid.length} lançamento(s) importado(s), ${r.skipped} '
            'ignorado(s), ${r.duplicates} repetido(s) na planilha.',
      );
    },
  ),
  ModuleCommand(
    id: 'diario.carregarJson',
    title: 'Carregar lançamentos de JSON',
    description:
        'Carrega {"DD/MM/AAAA -T": "conteúdo"} SUBSTITUINDO o rascunho.',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        ..._periodo,
      },
      'required': ['path'],
    },
    run: (input, origin) async {
      final r = await service.importJson(
        input.requireString('path'),
        term: input.optionalString('periodo'),
      );
      return CommandResult.ok(
        message:
            '${r.valid.length} lançamento(s) carregado(s), '
            '${r.errors.length} inválido(s).',
        data: {'invalidos': r.errors},
      );
    },
  ),
  ModuleCommand(
    id: 'diario.salvarJson',
    title: 'Salvar lançamentos em JSON',
    description: 'Exporta o rascunho do período (path opcional).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        ..._periodo,
      },
    },
    run: (input, origin) async {
      final path = await service.exportJson(
        path: input.optionalString('path'),
        term: input.optionalString('periodo'),
      );
      return CommandResult.ok(message: 'JSON salvo.', data: {'path': path});
    },
  ),
  ModuleCommand(
    id: 'diario.definirLancamentos',
    title: 'Definir lançamentos',
    description:
        'Grava lançamentos {"DD/MM/AAAA -T": "conteúdo"} no rascunho (valor '
        'vazio remove a aula; substituir=true apaga os demais).',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'lancamentos': {'type': 'object'},
        'substituir': {'type': 'boolean'},
        ..._periodo,
      },
      'required': ['lancamentos'],
    },
    run: (input, origin) async {
      final entries = input['lancamentos'];
      if (entries is! Map) {
        throw const CommandException(
          'entrada_invalida',
          'Informe "lancamentos" como objeto.',
        );
      }
      final r = await service.setEntries(
        Map<String, dynamic>.from(entries),
        term: input.optionalString('periodo'),
        replace: input.flag('substituir'),
      );
      return CommandResult.ok(
        message: '${r.valid.length} lançamento(s) gravado(s).',
        data: {'invalidos': r.errors},
      );
    },
  ),
  ModuleCommand(
    id: 'diario.abrirPortal',
    title: 'Abrir o Portal do Docente no Edge',
    description:
        'Abre o Edge do Portal (login automático se o usuário salvou as '
        'credenciais na tela). O usuário escolhe a turma e o diário.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      final opened = await service.openPortal(url: input.optionalString('url'));
      return CommandResult.ok(
        message:
            'Portal aberto em $opened. Peça ao usuário para abrir a turma e '
            'o diário antes de preencher.',
      );
    },
  ),
  ModuleCommand(
    id: 'diario.preencherPortal',
    title: 'Preencher o diário aberto no Portal',
    description:
        'Preenche o diário aberto no Edge com o rascunho do período (somente '
        '"T" ou "P" opcional; preservarPreenchidos=true não sobrescreve). '
        'Pede confirmação.',
    approval: CommandApproval.required,
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._periodo,
        'somente': {
          'type': 'string',
          'enum': ['T', 'P'],
        },
        'preservarPreenchidos': {'type': 'boolean'},
      },
    },
    run: (input, origin) async {
      final logs = <String>[];
      final r = await service.fillPortal(
        term: input.optionalString('periodo'),
        only: input.optionalString('somente'),
        requireEmpty: input.flag('preservarPreenchidos', fallback: true),
        log: logs.add,
      );
      return CommandResult.ok(
        message:
            '${r.filled} preenchido(s), ${r.notFound} não localizado(s), '
            '${r.skipped} preservado(s). Confira e salve no Portal.',
        data: {'log': logs.take(40).toList()},
      );
    },
  ),
];
