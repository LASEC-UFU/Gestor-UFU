import 'package:gestor_ufu/modules/progressao/application/progressao_pdf_service.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_service.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/modules/progressao/domain/resolucao_condir_03_2017.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

const _processoId = {
  'processoId': {'type': 'string', 'description': 'id de progressao.listar'},
};

Map<String, Object?> _resumo(ProgressaoDocente p) => {
  'id': p.id,
  'docente': p.docente,
  'movimento': p.alvo.denominacao(p.titulacao),
  'pontos': p.total,
  'referencia': p.referencia,
  'atingeReferencia': p.atingeReferencia,
  'lancamentos': p.lancamentos.length,
  'pastaComprovantes': p.pastaComprovantes,
};

DateTime? _date(String? value) =>
    value == null ? null : DateTime.tryParse(value);

/// Comandos da Progressão / Promoção (tela, menu "/" e Agente de IA).
List<ModuleCommand> progressaoCommands(ProgressaoService service) => [
  ModuleCommand(
    id: 'progressao.listar',
    title: 'Listar processos de progressão',
    description:
        'Processos (id, docente, movimento, pontos x referência, nº de '
        'lançamentos). Com processoId, devolve também os lançamentos.',
    inputSchema: {'type': 'object', 'properties': _processoId},
    run: (input, origin) async {
      final items = await service.load();
      final id = input.optionalString('processoId');
      if (id != null) {
        final p = service.byId(id);
        if (p == null) {
          throw CommandException(
            'processo_nao_encontrado',
            'Processo "$id" não encontrado.',
          );
        }
        return CommandResult.ok(
          data: {
            ..._resumo(p),
            'itens': [
              for (final l in p.lancamentos)
                {
                  'id': l.id,
                  'item': l.item,
                  'quantidade': l.quantidade,
                  'periodo': l.periodo,
                  'descricao': l.descricao,
                  'comprovante': l.comprovante,
                },
            ],
          },
        );
      }
      return CommandResult.ok(
        data: {
          'processos': [for (final p in items) _resumo(p)],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.itensAnexo1',
    title: 'Buscar itens do Anexo 1',
    description:
        'Busca no catálogo do Anexo 1 (Res. 03/2017 CONDIR) por texto (busca) '
        'e/ou tabela (A1.1 … A1.7). Devolve número, descrição e regra.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'busca': {'type': 'string'},
        'tabela': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      String norm(String s) => s.toLowerCase();
      final busca = norm(input.optionalString('busca') ?? '');
      final tabela = input.optionalString('tabela');
      final itens = [
        for (final item in anexo1)
          if ((tabela == null || item.tabela.codigo == tabela) &&
              (busca.isEmpty || norm(item.descricao).contains(busca)))
            {
              'item': item.numero,
              'tabela': item.tabela.codigo,
              'descricao': item.descricao,
              'regra': item.regra,
            },
      ];
      return CommandResult.ok(
        data: {'total': itens.length, 'itens': itens.take(60).toList()},
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.criar',
    title: 'Criar processo',
    description:
        'Cria um processo. No acesso móvel, a pasta de comprovantes é criada automaticamente no computador Windows; arquivos podem ser anexados depois pelo celular.',
    mutates: true,
    remoteInputSchema: {
      'type': 'object',
      'properties': {
        'docente': {'type': 'string'},
      },
    },
    inputSchema: {
      'type': 'object',
      'properties': {
        'pastaComprovantes': {'type': 'string'},
        'docente': {'type': 'string'},
      },
      'required': ['pastaComprovantes'],
    },
    run: (input, origin) async {
      final p = await service.create(
        pastaComprovantes: input.requireString('pastaComprovantes'),
        docente: input.optionalString('docente') ?? '',
      );
      return CommandResult.ok(
        message: 'Processo criado.',
        data: {'processoId': p.id},
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.lancar',
    title: 'Lançar item do Anexo 1',
    description:
        'Acrescenta um lançamento (item do Anexo 1, quantidade na unidade do '
        'item, período "2024/01", descrição, início/fim AAAA-MM-DD) e, se '
        'comprovante (caminho) for informado, copia o arquivo para a pasta do '
        'processo.',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._processoId,
        'item': {'type': 'integer'},
        'quantidade': {'type': 'number'},
        'periodo': {'type': 'string'},
        'descricao': {'type': 'string'},
        'inicio': {'type': 'string'},
        'fim': {'type': 'string'},
        'comprovante': {'type': 'string'},
      },
      'required': ['processoId', 'item'],
    },
    run: (input, origin) async {
      final id = input.requireString('processoId');
      final item = (input['item'] as num?)?.toInt();
      if (item == null) {
        throw const CommandException('entrada_invalida', 'Informe "item".');
      }
      var lancamento = await service.addLancamento(
        id,
        item: item,
        quantidade: (input['quantidade'] as num?)?.toDouble() ?? 0,
        periodo: input.optionalString('periodo') ?? '',
        descricao: input.optionalString('descricao') ?? '',
        inicio: _date(input.optionalString('inicio')),
        fim: _date(input.optionalString('fim')),
      );
      final comprovante = input.optionalString('comprovante');
      if (comprovante != null) {
        lancamento = await service.attachComprovante(
          id,
          lancamento.id,
          comprovante,
        );
      }
      final p = service.byId(id)!;
      return CommandResult.ok(
        message:
            'Item ${lancamento.item} lançado. Total: '
            '${ProgressaoPdfService.pontos(p.total)} de ${p.referencia ?? '—'} '
            'pontos.',
        data: {'lancamentoId': lancamento.id, 'pontos': p.total},
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.removerLancamento',
    title: 'Remover lançamento',
    description:
        'Remove um lançamento (e descarta a cópia do comprovante). Pede '
        'confirmação.',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._processoId,
        'lancamentoId': {'type': 'string'},
      },
      'required': ['processoId', 'lancamentoId'],
    },
    run: (input, origin) async {
      await service.removeLancamento(
        input.requireString('processoId'),
        input.requireString('lancamentoId'),
      );
      return const CommandResult.ok(message: 'Lançamento removido.');
    },
  ),
  ModuleCommand(
    id: 'progressao.anexarComprovante',
    title: 'Anexar comprovante a um lançamento',
    description:
        'Copia o arquivo (PDF/JPG/PNG) para a pasta do processo, renomeado na '
        'subpasta da tabela, e vincula ao lançamento.',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._processoId,
        'lancamentoId': {'type': 'string'},
        'path': {'type': 'string'},
      },
      'required': ['processoId', 'lancamentoId', 'path'],
    },
    run: (input, origin) async {
      final l = await service.attachComprovante(
        input.requireString('processoId'),
        input.requireString('lancamentoId'),
        input.requireString('path'),
      );
      return CommandResult.ok(
        message: 'Comprovante salvo como ${l.comprovante}.',
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.gerarPdf',
    title: 'Gerar requerimento e relatório (PDF)',
    description:
        'Gera o PDF do processo. path opcional; padrão Documentos/GestorUFU '
        'Agente/progressao.',
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._processoId,
        'path': {'type': 'string'},
      },
      'required': ['processoId'],
    },
    run: (input, origin) async {
      final id = input.requireString('processoId');
      await service.load();
      final p = service.byId(id);
      if (p == null) {
        throw CommandException(
          'processo_nao_encontrado',
          'Processo "$id" não encontrado.',
        );
      }
      final path = await GestorPaths.outputPath(
        input.optionalString('path'),
        ProgressaoService.pdfFileName(p),
        sub: 'progressao',
      );
      final saved = await service.exportPdf(id, path);
      return CommandResult.ok(message: 'PDF gerado.', data: {'path': saved});
    },
  ),
  ModuleCommand(
    id: 'progressao.duplicar',
    title: 'Duplicar processo',
    description: 'Cria uma cópia do processo (para o próximo interstício).',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': _processoId,
      'required': ['processoId'],
    },
    run: (input, origin) async {
      final p = await service.duplicate(input.requireString('processoId'));
      return CommandResult.ok(
        message: 'Processo duplicado.',
        data: {'processoId': p.id},
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.excluir',
    title: 'Excluir processo',
    description: 'Exclui o processo (os arquivos da pasta não são apagados).',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': _processoId,
      'required': ['processoId'],
    },
    run: (input, origin) async {
      await service.remove(input.requireString('processoId'));
      return const CommandResult.ok(message: 'Processo excluído.');
    },
  ),
  ModuleCommand(
    id: 'progressao.abrirSei',
    title: 'Abrir o SEI no Edge (comprovantes)',
    description:
        'Abre o Edge do envio de comprovantes no endereço do SEI (url '
        'opcional). O usuário faz o login e abre o processo.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      final aberto = await service.abrirSei(input.optionalString('url'));
      return CommandResult.ok(
        message:
            'Edge aberto em $aberto. Peça ao usuário para entrar no SEI e '
            'abrir o processo antes de enviar.',
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.enviarComprovantesSei',
    title: 'Enviar comprovantes ao SEI',
    description:
        'Inclui os comprovantes do processo como documentos externos no '
        'processo aberto no Edge (os que já estão na árvore são mantidos). '
        'Pede confirmação.',
    approval: CommandApproval.required,
    inputSchema: {
      'type': 'object',
      'properties': _processoId,
      'required': ['processoId'],
    },
    run: (input, origin) async {
      final r = await service.enviarComprovantes(
        input.requireString('processoId'),
      );
      return CommandResult.ok(
        message:
            '${r.criados.length} incluído(s), ${r.existentes.length} já '
            'existente(s), ${r.erros.length} erro(s).',
        data: {'erros': r.erros},
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.verificarSei',
    title: 'Verificar as etapas do dossiê no SEI',
    description:
        'Abre o processo salvo no Edge controlado e lê a árvore do SEI: '
        'informa login, processo, requerimento, comprovantes (presentes/total), '
        'titulação e relatório. Não grava nada no SEI.',
    inputSchema: {
      'type': 'object',
      'properties': {..._processoId},
      'required': ['processoId'],
    },
    run: (input, origin) async {
      final s = await service.verificarSei(input.requireString('processoId'));
      return CommandResult.ok(
        message: !s.logado
            ? 'O Edge não está logado no SEI; peça ao usuário para entrar.'
            : s.numeroProcesso.isEmpty
            ? 'Processo do cadastro não aberto no SEI'
                  '${s.numeroAberto.isEmpty ? '' : ' (aberto no Edge: ${s.numeroAberto})'}.'
            : 'Processo ${s.numeroProcesso}: requerimento '
                  '${s.requerimento ? 'presente' : 'pendente'}; comprovantes '
                  '${s.comprovantesNoSei}/${s.comprovantesTotal}; titulação '
                  '${s.titulacao ? 'presente' : 'pendente'}; relatório '
                  '${s.relatorio ? 'presente' : 'pendente'}.',
        data: {
          'logado': s.logado,
          'numeroProcesso': s.numeroProcesso,
          'numeroAberto': s.numeroAberto,
          'etapas': {
            for (final e in EtapaSei.values)
              e.name: {
                'concluida': s.concluida(e),
                'disponivel': s.disponivel(e),
              },
          },
          'comprovantesFaltantes': s.comprovantesFaltantes,
        },
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.executarEtapaSei',
    title: 'Executar uma etapa do dossiê no SEI',
    description:
        'Executa só a etapa indicada no processo salvo (processo, '
        'requerimento, comprovantes, titulacao, relatorio) — ou "pendentes" '
        'para todas as que faltam, em ordem, ou "atualizarRelatorio" para gerar '
        'de novo o relatório e trocar o PDF do documento já existente no SEI. '
        'Documentos presentes não são duplicados. Pede confirmação.',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._processoId,
        'etapa': {
          'type': 'string',
          'enum': [
            ...EtapaSei.values.map((e) => e.name),
            'pendentes',
            'atualizarRelatorio',
          ],
        },
      },
      'required': ['processoId', 'etapa'],
    },
    run: (input, origin) async {
      final id = input.requireString('processoId');
      final nome = input.requireString('etapa');
      if (nome == 'pendentes') {
        await service.executarEtapasPendentes(id);
      } else if (nome == 'atualizarRelatorio') {
        await service.atualizarRelatorioSei(id);
      } else {
        final etapa = EtapaSei.values.where((e) => e.name == nome).firstOrNull;
        if (etapa == null) {
          throw CommandException('etapa_invalida', 'Etapa desconhecida: $nome');
        }
        final s = service.envio.situacoes[id];
        if (etapa != EtapaSei.processo && !(s?.disponivel(etapa) ?? false)) {
          throw CommandException(
            'etapa_bloqueada',
            'Conclua as etapas anteriores (use progressao.verificarSei).',
          );
        }
        await service.executarEtapaSei(id, etapa);
      }
      final s = service.envio.situacoes[id];
      return CommandResult.ok(
        message: s == null
            ? 'Etapa executada.'
            : 'Etapa executada. Requerimento ${s.requerimento ? 'presente' : 'pendente'}; '
                  'comprovantes ${s.comprovantesNoSei}/${s.comprovantesTotal}; '
                  'titulação ${s.titulacao ? 'presente' : 'pendente'}; '
                  'relatório ${s.relatorio ? 'presente' : 'pendente'}.',
      );
    },
  ),
  ModuleCommand(
    id: 'progressao.montarProcessoSei',
    title: 'Montar dossiê de progressão/promoção no SEI',
    description:
        'Cria um processo docente no SEI ou usa um existente; preenche o '
        'requerimento, inclui comprovantes e titulação e envia o relatório '
        'por último. Requer confirmação do usuário antes de qualquer gravação '
        'externa. O usuário precisa estar logado no Edge controlado.',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        ..._processoId,
        'criarNovo': {'type': 'boolean', 'default': false},
        'numeroProcesso': {'type': 'string'},
        'especificacao': {'type': 'string'},
        'interessado': {'type': 'string'},
        'acessoComprovantes': {
          'type': 'string',
          'enum': ['restrito', 'publico'],
          'default': 'restrito',
        },
        'incluirRequerimento': {'type': 'boolean', 'default': true},
        'incluirComprovantes': {'type': 'boolean', 'default': true},
        'incluirTitulacao': {'type': 'boolean', 'default': true},
        'incluirRelatorio': {'type': 'boolean', 'default': true},
        'confirmarNovoComProcessoSalvo': {'type': 'boolean', 'default': false},
      },
      'required': ['processoId'],
    },
    run: (input, origin) async {
      final acesso = input.optionalString('acessoComprovantes') == 'publico'
          ? AcessoComprovantesSei.publico
          : AcessoComprovantesSei.restrito;
      final r = await service.montarProcessoSei(
        input.requireString('processoId'),
        ProgressaoDossieSeiOpcoes(
          criarNovo: input.flag('criarNovo'),
          numeroProcesso: input.optionalString('numeroProcesso') ?? '',
          especificacao: input.optionalString('especificacao') ?? '',
          interessado: input.optionalString('interessado') ?? '',
          acessoComprovantes: acesso,
          incluirRequerimento: input.flag(
            'incluirRequerimento',
            fallback: true,
          ),
          incluirComprovantes: input.flag(
            'incluirComprovantes',
            fallback: true,
          ),
          incluirTitulacao: input.flag('incluirTitulacao', fallback: true),
          incluirRelatorio: input.flag('incluirRelatorio', fallback: true),
          confirmarNovoComProcessoSalvo: input.flag(
            'confirmarNovoComProcessoSalvo',
          ),
        ),
      );
      return CommandResult.ok(
        message:
            'Processo ${r.numeroProcesso} montado: requerimento ${r.requerimento}; '
            '${r.comprovantesNovos} comprovantes novos, ${r.comprovantesExistentes} já existentes; '
            'titulação ${r.titulacao}; relatório ${r.relatorio}. '
            'O requerimento não foi assinado; o docente deve conferir e assinar no SEI.',
        data: {
          'numeroProcesso': r.numeroProcesso,
          'requerimento': r.requerimento,
          'comprovantesNovos': r.comprovantesNovos,
          'comprovantesExistentes': r.comprovantesExistentes,
          'titulacao': r.titulacao,
          'relatorio': r.relatorio,
        },
      );
    },
  ),
];
