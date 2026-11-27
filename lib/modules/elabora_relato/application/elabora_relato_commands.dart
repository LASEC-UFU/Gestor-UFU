import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/checklist_sei.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/processos_parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

/// Comandos do módulo Parecer / Relato (tela, menu "/" e agente). Os
/// comandos de um processo agem no processo aberto; aceitam `processo` (id)
/// para escolher outro e, sem nenhum aberto, abrem o mais recente.
List<ModuleCommand> elaboraRelatoCommands(
  SeiArvoreService service,
  ParecerService parecer,
  ProcessosParecerService processos,
) => [
  ..._comandosDeProcessos(processos),
  for (final c in _comandosDoProcesso(service, parecer))
    ModuleCommand(
      id: c.id,
      title: c.title,
      description: c.description,
      approval: c.approval,
      mutates: c.mutates,
      inputSchema: {
        ...c.inputSchema,
        'properties': {
          ...(c.inputSchema['properties'] as Map? ?? const {}),
          'processo': {
            'type': 'string',
            'description': 'Id do processo (parecer.processos.listar).',
          },
        },
      },
      run: (input, origin) async {
        await processos.garantirAtivo(input.optionalString('processo'));
        return c.run(input, origin);
      },
    ),
];

List<ModuleCommand> _comandosDeProcessos(ProcessosParecerService processos) => [
  ModuleCommand(
    id: 'parecer.processos.listar',
    title: 'Listar os processos de parecer',
    description:
        'Processos do módulo Parecer / Relato (id, nome, número SEI, '
        'assunto, documentos na árvore, comentários pendentes) e qual está '
        'aberto.',
    inputSchema: {'type': 'object', 'properties': {}},
    run: (input, origin) async {
      await processos.carregar(forcar: true);
      return CommandResult.ok(
        message: '${processos.processos.length} processo(s).',
        data: {
          'aberto': processos.ativo?.id,
          'processos': [
            for (final p in processos.processos)
              {
                ...p.toJson(),
                'assunto': processos.resumo(p.id).assunto,
                'documentos': processos.resumo(p.id).documentos,
                'pendentes': processos.resumo(p.id).pendentes,
              },
          ],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.processos.abrir',
    title: 'Abrir um processo de parecer',
    description: 'Abre o processo {id}: os demais comandos passam a agir nele.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
    },
    run: (input, origin) async {
      await processos.abrir(input.requireString('id'));
      return CommandResult.ok(
        message: 'Processo "${processos.ativo!.nome}" aberto.',
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.processos.criar',
    title: 'Criar um processo de parecer',
    description:
        'Cria um processo {nome, numeroSei?} e o abre. Com copiarDe (id), '
        'cria uma cópia daquele processo (rascunho, comentários, árvore e '
        'pasta da base).',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'nome': {'type': 'string'},
        'numeroSei': {'type': 'string'},
        'copiarDe': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      final origem = input.optionalString('copiarDe');
      final p = origem == null
          ? await processos.criar(
              nome: input.optionalString('nome') ?? 'Novo processo',
              numeroSei: input.optionalString('numeroSei') ?? '',
            )
          : await processos.duplicar(
              origem,
              nome: input.optionalString('nome'),
            );
      await processos.abrir(p.id);
      return CommandResult.ok(
        message: 'Processo "${p.nome}" criado e aberto.',
        data: {'id': p.id},
      );
    },
  ),
];

/// Comandos que agem no processo aberto.
List<ModuleCommand> _comandosDoProcesso(
  SeiArvoreService service,
  ParecerService parecer,
) => [
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
    runRemote: (input, origin, context) async {
      final docs = await service.extrair(
        lerConteudo: input['lerConteudo'] != false,
        context: context,
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
        sub: 'elabora_relato',
      );
      await service.salvarRelatorio(path);
      return CommandResult.ok(
        message: 'Relatório salvo.',
        data: {'path': path},
      );
    },
  ),
  ModuleCommand(
    id: 'relato.textoDocumento',
    title: 'Texto de um documento extraído',
    description:
        'Texto visível do documento de ordem N lido na última extração '
        '(vazio para PDFs ou se o inventário veio de outra sessão). Use para '
        'escrever o resumo do documento.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'ordem': {'type': 'integer'},
      },
      'required': ['ordem'],
    },
    run: (input, origin) async {
      final ordem = (input['ordem'] as num?)?.toInt() ?? 0;
      return CommandResult.ok(data: {'texto': service.textoDe(ordem)});
    },
  ),
  ModuleCommand(
    id: 'relato.atualizarResumos',
    title: 'Corrigir resumos/datas do inventário',
    description:
        'Grava resumos (e/ou datas dd/mm/aaaa) de documentos do inventário. '
        'Resumo no estilo do relatório: uma frase curta em minúsculas, sem '
        'tipo/número/data e sem ponto final (ex.: "encaminhamento do processo '
        'pela PROGRAD à SEGER indicando relatoria").',
    inputSchema: {
      'type': 'object',
      'properties': {
        'itens': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'ordem': {'type': 'integer'},
              'resumo': {'type': 'string'},
              'data': {'type': 'string'},
            },
            'required': ['ordem'],
          },
        },
      },
      'required': ['itens'],
    },
    run: (input, origin) async {
      var n = 0;
      for (final item
          in (input['itens'] as List? ?? const []).whereType<Map>()) {
        final ordem = (item['ordem'] as num?)?.toInt();
        if (ordem == null) continue;
        await service.atualizarDocumento(
          ordem,
          resumo: item['resumo'] as String?,
          data: item['data'] as String?,
        );
        n++;
      }
      return CommandResult.ok(message: '$n documento(s) atualizados.');
    },
  ),
  ModuleCommand(
    id: 'relato.resumirComIa',
    title: 'Resumir documentos com IA',
    description:
        'Gera o resumo de cada documento do inventário com o provedor do '
        'Agente de IA (pedido avulso, em lotes). apenasVazios=true mantém os '
        'resumos já preenchidos.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'apenasVazios': {'type': 'boolean'},
      },
    },
    run: (input, origin) async {
      final n = await service.resumirComIa(
        apenasVazios: input['apenasVazios'] == true,
      );
      return CommandResult.ok(message: '$n resumo(s) gerados.');
    },
  ),
  ModuleCommand(
    id: 'parecer.ler',
    title: 'Ler o rascunho do parecer',
    description:
        'Campos do parecer (assunto, ementa, vocativo, abertura, fecho, '
        'signatário) e o HTML das seções relatorio, fundamentacao e '
        'conclusao.',
    inputSchema: {'type': 'object', 'properties': {}},
    run: (input, origin) async {
      await parecer.carregar();
      return CommandResult.ok(data: parecer.parecer.toJson());
    },
  ),
  ModuleCommand(
    id: 'parecer.definir',
    title: 'Alterar o rascunho do parecer',
    description:
        'Altera campos do parecer e/ou substitui o HTML de uma seção. Campos: '
        'assunto, ementa, vocativo e abertura (uma linha por parágrafo), '
        'fecho, nome_signatario, cargo_signatario, descricao_sei. Seções '
        '(HTML do editor do SEI, parágrafos <p class="Texto_Justificado_'
        'Recuo_Primeira_Linha">, links SEI <a class="ancora_sei" '
        'id="lnkSei{id_documento}">{número}</a>): relatorio, fundamentacao, '
        'conclusao. Campos omitidos não mudam. Depois de gravar uma seção, '
        'crie as anotações de defesa do voto (parecer.comentarios.adicionar, '
        'categoria "defesa"), como manda a skill do módulo.',
    inputSchema: {
      'type': 'object',
      'properties': {
        for (final k in [
          'assunto',
          'ementa',
          'vocativo',
          'abertura',
          'fecho',
          'nome_signatario',
          'cargo_signatario',
          'descricao_sei',
          'relatorio',
          'fundamentacao',
          'conclusao',
        ])
          k: {'type': 'string'},
      },
    },
    run: (input, origin) async {
      await parecer.carregar();
      final atual = parecer.parecer.toJson();
      for (final k in atual.keys) {
        if (input[k] is String && ParecerSecao.porId(k) == null) {
          atual[k] = input[k];
        }
      }
      final novo = Parecer.fromJson(atual);
      parecer.atualizar(
        novo.copyWith(
          relatorio: parecer.parecer.relatorio,
          fundamentacao: parecer.parecer.fundamentacao,
          conclusao: parecer.parecer.conclusao,
        ),
      );
      for (final s in ParecerSecao.values) {
        final html = input[s.id];
        if (html is String) await parecer.substituirSecao(s, html);
      }
      await parecer.salvarAgora();
      return CommandResult.ok(message: 'Rascunho do parecer atualizado.');
    },
  ),
  ModuleCommand(
    id: 'parecer.comentarios.listar',
    title: 'Listar os comentários do parecer',
    description:
        'Comentários (anotações privadas, fora do texto do SEI) de todas as '
        'seções ou de uma {secao}: id, trecho, categoria, status, texto, '
        'pergunta_arguicao e resposta_oral.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'secao': {
          'type': 'string',
          'enum': ['relatorio', 'fundamentacao', 'conclusao'],
        },
      },
    },
    run: (input, origin) async {
      await parecer.carregar();
      final secao = input.optionalString('secao');
      final lista = [
        for (final c in parecer.parecer.comentarios)
          if (secao == null || '${c['secao']}' == secao)
            {
              for (final k in [
                'id',
                'secao',
                'trecho',
                'localizado',
                ...ParecerService.camposAnotacao,
              ])
                if (c[k] != null && '${c[k]}'.isNotEmpty) k: c[k],
            },
      ];
      return CommandResult.ok(
        message: '${lista.length} comentário(s).',
        data: {'comentarios': lista},
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.comentarios.adicionar',
    title: 'Anotar um trecho do parecer',
    description:
        'Cria um comentário ancorado num trecho do parecer, sem alterar o '
        'texto nem o que vai ao SEI. {secao (relatorio, fundamentacao, '
        'conclusao), trecho (cópia literal de uma frase da seção, sem tags, '
        'até ~150 caracteres), texto (o ponto que precisa de atenção, em '
        'frase completa)}, importancia (por que merece revisão) e sugestao '
        '(o que fazer para melhorar), sem rótulos soltos; para DEFESA DO VOTO '
        '(categoria "defesa"): referencia (norma/documento e artigo/página), '
        'citacao_literal (copiada da fonte), explicacao_simples, importancia, '
        'pergunta_arguicao (o que um conselheiro pode perguntar ou objetar), '
        'resposta_oral (resposta curta para falar em plenário) e '
        'contra_argumento (se insistirem). status: anotacao (padrão), '
        'confirmado (fato conferido na base) ou revisar (fato não conferido). '
        'As perguntas entram no "Simulado de arguição".',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'secao': {
          'type': 'string',
          'enum': ['relatorio', 'fundamentacao', 'conclusao'],
        },
        'trecho': {'type': 'string'},
        'texto': {'type': 'string'},
        'categoria': {'type': 'string'},
        'status': {
          'type': 'string',
          'enum': ['anotacao', 'confirmado', 'revisar'],
        },
        'referencia': {'type': 'string'},
        'citacao_literal': {'type': 'string'},
        'explicacao_simples': {'type': 'string'},
        'importancia': {'type': 'string'},
        'sugestao': {'type': 'string'},
        'pergunta_arguicao': {'type': 'string'},
        'resposta_oral': {'type': 'string'},
        'contra_argumento': {'type': 'string'},
      },
      'required': ['secao', 'trecho', 'texto'],
    },
    run: (input, origin) async {
      final secao = ParecerSecao.porId(input.requireString('secao'));
      if (secao == null) {
        throw const CommandException(
          'secao_invalida',
          'Use relatorio, fundamentacao ou conclusao.',
        );
      }
      final campos = Map<String, dynamic>.from(input);
      if (campos['status'] == 'anotacao') campos.remove('status');
      final c = await parecer.anotarTrecho(
        secao,
        input.requireString('trecho'),
        campos,
      );
      return CommandResult.ok(
        message: 'Comentário criado em ${secao.titulo}.',
        data: {'id': c['id']},
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.comentarios.excluir',
    title: 'Excluir um comentário do parecer',
    description: 'Exclui o comentário {id} (parecer.comentarios.listar).',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
    },
    run: (input, origin) async {
      final ok = await parecer.excluirAnotacao(input.requireString('id'));
      if (!ok) {
        throw const CommandException(
          'comentario_inexistente',
          'Comentário não encontrado.',
        );
      }
      return CommandResult.ok(message: 'Comentário excluído.');
    },
  ),
  ModuleCommand(
    id: 'parecer.inserirInventario',
    title: 'Inserir a lista de documentos no relatório',
    description:
        'Insere no I. RELATÓRIO (no cursor do editor, ou ao final) a lista '
        'numerada dos documentos extraídos, com links SEI. porPastas separa '
        '"Pasta I/II…" a cada 20; introducao é um parágrafo inicial opcional.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'porPastas': {'type': 'boolean'},
        'introducao': {'type': 'string'},
      },
    },
    run: (input, origin) async {
      if (service.documentos.isEmpty) {
        throw const CommandException(
          'sem_extracao',
          'Nenhuma árvore extraída ainda (relato.extrairArvore).',
        );
      }
      await parecer.carregar();
      parecer.inserirNoEditor(
        ParecerSecao.relatorio,
        parecer.inventarioHtml(
          porPastas: input['porPastas'] != false,
          introducao: input.optionalString('introducao') ?? '',
        ),
      );
      return CommandResult.ok(
        message: '${service.documentos.length} documento(s) inseridos.',
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.anexos.listar',
    title: 'Listar os documentos anexados ao processo',
    description:
        'Documentos do processo aberto anexados para leitura (id, nome, '
        'páginas, parágrafos, marcações com comentário).',
    inputSchema: {'type': 'object', 'properties': {}},
    run: (input, origin) async {
      await parecer.anexos.carregar();
      return CommandResult.ok(
        message: '${parecer.anexos.anexos.length} documento(s) anexado(s).',
        data: {
          'anexos': [
            for (final a in parecer.anexos.anexos)
              {
                'id': a.id,
                'nome': a.nome,
                'paginas': a.paginas,
                'paragrafos': a.paragrafos,
                if (a.aviso.isNotEmpty) 'aviso': a.aviso,
                'marcacoes': [
                  for (final m in a.marcacoes)
                    {
                      'paragrafo': m.paragrafo,
                      if (m.pdfPagina > 0) 'pagina': m.pdfPagina,
                      'texto': m.texto,
                      if (m.comentario.isNotEmpty) 'comentario': m.comentario,
                    },
                ],
              },
          ],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.anexos.ler',
    title: 'Ler um documento anexado',
    description:
        'Texto de um documento anexado {anexo (id), inicio?, quantidade? '
        '(padrão 60)} em parágrafos numerados (índice e página). Use o '
        'índice em parecer.anexos.marcar.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'anexo': {'type': 'string'},
        'inicio': {'type': 'integer'},
        'quantidade': {'type': 'integer'},
      },
      'required': ['anexo'],
    },
    run: (input, origin) async {
      await parecer.anexos.carregar();
      final a = parecer.anexos.exigir(input.requireString('anexo'));
      final pars = await parecer.anexos.paragrafos(a);
      final inicio = ((input['inicio'] as num?)?.toInt() ?? 0).clamp(
        0,
        pars.length,
      );
      final qtd = ((input['quantidade'] as num?)?.toInt() ?? 60).clamp(1, 200);
      final fim = (inicio + qtd).clamp(0, pars.length);
      return CommandResult.ok(
        message:
            '${a.nome}: parágrafos $inicio a ${fim - 1} de ${pars.length}.',
        data: {
          'paragrafos': [
            for (var i = inicio; i < fim; i++)
              {
                'indice': i,
                if (pars[i].pagina > 0) 'pagina': pars[i].pagina,
                'texto': pars[i].texto,
              },
          ],
          if (fim < pars.length) 'continua': 'Use inicio=$fim.',
        },
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.anexos.marcar',
    title: 'Marcar um trecho de documento anexado',
    description:
        'Marca {anexo, paragrafo (índice), trecho (texto literal do '
        'parágrafo), comentario?, cor? (amarelo, verde, azul, rosa, '
        'laranja)}. O documento não é alterado.',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'anexo': {'type': 'string'},
        'paragrafo': {'type': 'integer'},
        'trecho': {'type': 'string'},
        'comentario': {'type': 'string'},
        'cor': {'type': 'string'},
      },
      'required': ['anexo', 'paragrafo', 'trecho'],
    },
    run: (input, origin) async {
      await parecer.anexos.carregar();
      final a = parecer.anexos.exigir(input.requireString('anexo'));
      final pars = await parecer.anexos.paragrafos(a);
      final i = (input['paragrafo'] as num?)?.toInt() ?? -1;
      if (i < 0 || i >= pars.length) {
        throw CommandException(
          'paragrafo_invalido',
          'Parágrafo $i não existe (0 a ${pars.length - 1}).',
        );
      }
      final trecho = input.requireString('trecho');
      final at = pars[i].texto.indexOf(trecho);
      if (at < 0) {
        throw const CommandException(
          'trecho_nao_encontrado',
          'O trecho não aparece literalmente nesse parágrafo.',
        );
      }
      final cor = input.optionalString('cor') ?? 'amarelo';
      final m = AnexosProcessoService.novaMarcacao(
        paragrafo: i,
        textoParagrafo: pars[i].texto,
        inicio: at,
        fim: at + trecho.length,
        cor: coresMarcacao.containsKey(cor) ? cor : 'amarelo',
        comentario: input.optionalString('comentario') ?? '',
      );
      await parecer.anexos.salvarMarcacao(a.id, m);
      return CommandResult.ok(message: 'Trecho marcado em "${a.nome}".');
    },
  ),
  ModuleCommand(
    id: 'parecer.verificar',
    title: 'Verificar o parecer antes do SEI',
    description:
        'Lista pendências: comentários "para revisão", artigos citados no '
        'texto que não estão na base de documentos e campos vazios. Rode '
        'antes de parecer.inserirSei e mostre o resultado ao usuário.',
    inputSchema: {'type': 'object', 'properties': {}},
    run: (input, origin) async {
      final c = await parecer.checklistSei();
      return CommandResult.ok(
        message: c.itens.isEmpty
            ? 'Nenhuma pendência encontrada.'
            : c.itens.map((i) => i.titulo).join('; '),
        data: {'itens': _itens(c)},
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.inserirSei',
    title: 'Inserir o parecer no SEI',
    description:
        'Gera um documento "Parecer" no processo aberto no Edge do app (ou '
        'preenche o editor de Parecer já aberto) com o rascunho e salva sem '
        'assinar. Antes, rode parecer.verificar e confirme com o usuário.',
    inputSchema: {'type': 'object', 'properties': {}},
    run: (input, origin) async {
      await parecer.carregar();
      final c = await parecer.checklistSei();
      final avisos = await parecer.inserirNoSei();
      return CommandResult.ok(
        message: 'Parecer inserido e salvo no SEI (não assinado).',
        data: {'avisos': avisos, 'pendencias': _itens(c)},
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.base.preparar',
    title: 'Preparar a base de documentos',
    description:
        'Prepara/atualiza a base de consulta (JSON na pasta de documentos '
        'do relator): extrai PDF com texto, DOCX, TXT/MD e HTML em trechos '
        'com página/artigo/seção/parágrafo. Só reprocessa arquivos novos ou '
        'alterados. pasta opcional (troca a pasta); forcar reprocessa tudo.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'pasta': {'type': 'string'},
        'forcar': {'type': 'boolean'},
      },
    },
    run: (input, origin) async {
      final base = parecer.base;
      final pasta = input.optionalString('pasta');
      if (pasta != null) {
        await base.definirPasta(pasta);
        if (input['forcar'] == true) await base.preparar(forcar: true);
      } else {
        await base.preparar(forcar: input['forcar'] == true);
      }
      final r = base.ultimoResumo;
      final b = base.base;
      return CommandResult.ok(
        message:
            'Base em ${base.pasta}: ${b?.documentos.length ?? 0} '
            'documento(s), ${b?.totalTrechos ?? 0} trecho(s). '
            '${r?.descricao ?? ''}',
        data: {
          'json': r?.arquivoJson ?? '',
          'sem_texto': r?.semTexto ?? const [],
          'erros': r?.erros ?? const [],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'parecer.base.buscar',
    title: 'Buscar na base de documentos',
    description:
        'Busca termos, normas ou artigos ("art. 41 estágio") na base de '
        'consulta e nos documentos lidos da árvore do SEI. Devolve trechos '
        'com arquivo original e localização. Cite sempre o arquivo e a '
        'localização; não invente referências.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'consulta': {'type': 'string'},
        'limite': {'type': 'integer'},
      },
      'required': ['consulta'],
    },
    run: (input, origin) async {
      final consulta = input.optionalString('consulta') ?? '';
      if (consulta.trim().isEmpty) {
        throw const CommandException('consulta_vazia', 'Informe a consulta.');
      }
      final limite = ((input['limite'] as num?)?.toInt() ?? 8).clamp(1, 30);
      final fontes = await parecer.base.fontesPara(
        consulta,
        processo: service.documentos,
        limiteBase: limite,
        limiteProcesso: (limite / 2).ceil(),
      );
      return CommandResult.ok(
        message: fontes.isEmpty
            ? 'Nada encontrado na base para "$consulta".'
            : '${fontes.length} trecho(s) encontrados.',
        data: {
          'pasta': parecer.base.pasta,
          'trechos': [
            for (final f in fontes)
              {
                'arquivo': f.arquivo,
                'localizacao': f.localizacao,
                'texto': f.texto,
              },
          ],
        },
      );
    },
  ),
];

List<Map<String, Object>> _itens(ChecklistSei c) => [
  for (final i in c.itens)
    {'titulo': i.titulo, 'gravidade': i.gravidade.name, 'detalhes': i.detalhes},
];
