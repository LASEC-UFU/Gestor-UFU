import 'package:gestor_ufu/modules/elaborar_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

/// Comandos do módulo Elaborar Relato (tela, menu "/" e agente).
List<ModuleCommand> elaborarRelatoCommands(SeiArvoreService service) => [
  ModuleCommand(
    id: 'relato.abrirSei',
    title: 'Abrir o SEI no Edge',
    description:
        'Abre o Edge controlado pelo app no SEI (url opcional; padrão o '
        'último endereço usado). O usuário faz login e abre o processo.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      final url = input.optionalString('url') ?? await service.enderecoSalvo();
      final opened = await service.abrir(url);
      return CommandResult.ok(
        message:
            'SEI aberto em $opened. Peça ao usuário para entrar e abrir o '
            'processo antes de extrair.',
      );
    },
  ),
  ModuleCommand(
    id: 'relato.extrairArvore',
    title: 'Extrair árvore do processo',
    description:
        'Lê os documentos do processo aberto no Edge: ordem, nome na árvore, '
        'tipo/número, código SEI e (lendo o texto de cada documento) data e '
        'resumo. lerConteudo=false lê só a árvore (mais rápido). Os campos '
        'data/resumo são estimados do texto e precisam de revisão.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'lerConteudo': {'type': 'boolean'},
      },
    },
    run: (input, origin) async {
      final docs = await service.extrair(
        lerConteudo: input['lerConteudo'] != false,
      );
      return CommandResult.ok(
        message: '${docs.length} documento(s) lido(s).',
        data: {
          'documentos': [for (final d in docs) d.toJson()],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'relato.relatorioArvore',
    title: 'Relatório da última extração',
    description:
        'Inventário da última extração no formato para parecer ("1. Ofício '
        '12 (1234567), de 03/03/2025 – resumo"). Com path, salva em .txt.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      if (service.documentos.isEmpty) {
        throw const CommandException(
          'sem_extracao',
          'Nenhuma árvore extraída ainda (relato.extrairArvore).',
        );
      }
      final requested = input.optionalString('path');
      if (requested == null) {
        return CommandResult.ok(data: {'relatorio': service.relatorio()});
      }
      final path = await GestorPaths.outputPath(
        requested,
        'relatorio_arvore_sei.txt',
        sub: 'elaborar_relato',
      );
      await service.salvarRelatorio(path);
      return CommandResult.ok(
        message: 'Relatório salvo.',
        data: {'path': path},
      );
    },
  ),
];
