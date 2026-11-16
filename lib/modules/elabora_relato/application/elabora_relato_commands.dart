import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

/// Comandos do módulo Parecer / Relato (tela, menu "/" e agente).
List<ModuleCommand> elaboraRelatoCommands(
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
      for (final item in (input['itens'] as List? ?? const []).whereType<Map>()) {
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
        'conclusao. Campos omitidos não mudam.',
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
      parecer.atualizar(novo.copyWith(
        relatorio: parecer.parecer.relatorio,
        fundamentacao: parecer.parecer.fundamentacao,
        conclusao: parecer.parecer.conclusao,
      ));
      for (final s in ParecerSecao.values) {
        final html = input[s.id];
        if (html is String) await parecer.substituirSecao(s, html);
      }
      await parecer.salvarAgora();
      return CommandResult.ok(message: 'Rascunho do parecer atualizado.');
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
    id: 'parecer.inserirSei',
    title: 'Inserir o parecer no SEI',
    description:
        'Gera um documento "Parecer" no processo aberto no Edge do app (ou '
        'preenche o editor de Parecer já aberto) com o rascunho e salva sem '
        'assinar. Confirme com o usuário antes.',
    inputSchema: {'type': 'object', 'properties': {}},
    run: (input, origin) async {
      await parecer.carregar();
      final avisos = await parecer.inserirNoSei();
      return CommandResult.ok(
        message: 'Parecer inserido e salvo no SEI (não assinado).',
        data: {'avisos': avisos},
      );
    },
  ),
];
