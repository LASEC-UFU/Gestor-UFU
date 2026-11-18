import 'package:gestor_ufu/modules/audita_bancas/application/audita_service.dart';
import 'package:gestor_ufu/modules/audita_bancas/domain/auditoria.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

const _documento = {
  'type': 'string',
  'description': 'id do documento (auditaBancas.listar)',
};
const _observacao = {
  'type': 'string',
  'description': 'id da observação (auditaBancas.observacoes)',
};

Map<String, Object?> _resumo(DocumentoAuditado d) => {
  'id': d.id,
  'nome': d.nome,
  'origem': d.origem,
  'observacoes': d.observacoes.length,
  'aceitas': d.observacoes.where((o) => o.revisao == Revisao.aceita).length,
  'pendentes': d.observacoes.where((o) => o.revisao == Revisao.pendente).length,
};

/// Comandos do Audita Bancas: o que a tela faz, para o menu "/" e o agente.
List<ModuleCommand> auditaBancasCommands(AuditaService service) => [
  ModuleCommand(
    id: 'auditaBancas.listar',
    title: 'Listar documentos auditados',
    description: 'Documentos auditados (id, nome, origem e contagens).',
    run: (input, origin) async {
      await service.carregar(forcar: true);
      return CommandResult.ok(
        message: '${service.documentos.length} documento(s).',
        data: {
          'documentos': [for (final d in service.documentos) _resumo(d)],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.abrirPdf',
    title: 'Abrir um PDF para auditar',
    description:
        'Guarda uma cópia do PDF {caminho} (o original não muda) e devolve o '
        'documento; o mesmo arquivo reabre o documento já auditado.',
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'caminho': {'type': 'string', 'description': 'caminho do PDF'},
      },
      'required': ['caminho'],
    },
    run: (input, origin) async {
      final d = await service.abrirPdf(input.requireString('caminho'));
      return CommandResult.ok(
        message: 'Documento "${d.nome}" aberto.',
        data: _resumo(d),
      );
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.analisar',
    title: 'Analisar o documento com IA',
    description:
        'Envia o texto do PDF ao modelo configurado e cria observações '
        '(problema, por que importa, como melhorar) ancoradas nos trechos. '
        '{documento, criterios? (critérios/rubrica/normas da banca)}. '
        'Repetir atualiza as observações iguais.',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'documento': _documento,
        'criterios': {'type': 'string'},
      },
      'required': ['documento'],
    },
    run: (input, origin) async {
      await service.carregar();
      final id = input.requireString('documento');
      final List<String> paginas;
      try {
        paginas = await service.paginasDoPdf(id);
      } on StateError catch (e) {
        throw CommandException('leitura_falhou', e.message);
      }
      final r = await service.analisar(
        id,
        paginas,
        criterios: input.optionalString('criterios') ?? '',
      );
      return CommandResult.ok(
        message:
            '${r.criadas} observação(ões) nova(s); ${r.naoAncoradas} sem '
            'trecho localizado.',
        data: {'criadas': r.criadas, 'nao_ancoradas': r.naoAncoradas},
      );
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.observacoes',
    title: 'Listar as observações de um documento',
    description:
        'Observações do {documento}, na ordem do PDF: id, página, trecho, '
        'categoria, problema, importância, melhoria e revisão.',
    inputSchema: const {
      'type': 'object',
      'properties': {'documento': _documento},
      'required': ['documento'],
    },
    run: (input, origin) async {
      await service.carregar();
      final d = service.documento(input.requireString('documento'));
      if (d == null) {
        throw const CommandException(
          'documento_inexistente',
          'Documento não encontrado (auditaBancas.listar).',
        );
      }
      return CommandResult.ok(
        message: '${d.observacoes.length} observação(ões).',
        data: {
          'observacoes': [for (final o in d.observacoes) o.toJson()],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.revisar',
    title: 'Aceitar ou rejeitar uma observação',
    description:
        'Define a revisão {documento, observacao, revisao: pendente, aceita '
        'ou rejeitada}. Só as aceitas vão para o PDF anotado.',
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'documento': _documento,
        'observacao': _observacao,
        'revisao': {
          'type': 'string',
          'enum': ['pendente', 'aceita', 'rejeitada'],
        },
      },
      'required': ['documento', 'observacao', 'revisao'],
    },
    run: (input, origin) async {
      await service.carregar();
      await service.definirRevisao(
        input.requireString('documento'),
        input.requireString('observacao'),
        Revisao.de(input.requireString('revisao')),
      );
      return CommandResult.ok(message: 'Revisão atualizada.');
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.editarObservacao',
    title: 'Editar uma observação',
    description:
        'Muda {documento, observacao} e os campos informados: problema, '
        'importancia, melhoria, categoria (frases completas, sem rótulos '
        'soltos).',
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {
        'documento': _documento,
        'observacao': _observacao,
        'problema': {'type': 'string'},
        'importancia': {'type': 'string'},
        'melhoria': {'type': 'string'},
        'categoria': {'type': 'string'},
      },
      'required': ['documento', 'observacao'],
    },
    run: (input, origin) async {
      await service.carregar();
      final docId = input.requireString('documento');
      final obsId = input.requireString('observacao');
      final o = service
          .documento(docId)
          ?.observacoes
          .where((x) => x.id == obsId)
          .firstOrNull;
      if (o == null) {
        throw const CommandException(
          'observacao_inexistente',
          'Observação não encontrada (auditaBancas.observacoes).',
        );
      }
      await service.salvarObservacao(
        docId,
        o.copyWith(
          problema: input.optionalString('problema'),
          importancia: input.optionalString('importancia'),
          melhoria: input.optionalString('melhoria'),
          categoria: input.optionalString('categoria'),
        ),
      );
      return CommandResult.ok(message: 'Observação atualizada.');
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.excluirObservacao',
    title: 'Excluir uma observação',
    description: 'Exclui a observação {documento, observacao}.',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: const {
      'type': 'object',
      'properties': {'documento': _documento, 'observacao': _observacao},
      'required': ['documento', 'observacao'],
    },
    run: (input, origin) async {
      await service.carregar();
      await service.excluirObservacao(
        input.requireString('documento'),
        input.requireString('observacao'),
      );
      return CommandResult.ok(message: 'Observação excluída.');
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.exportarRelatorio',
    title: 'Exportar o relatório em texto',
    description:
        'Grava o relatório (.txt) com todas as observações do {documento} '
        'ao lado do PDF de origem, ou em {caminho}.',
    inputSchema: const {
      'type': 'object',
      'properties': {
        'documento': _documento,
        'caminho': {'type': 'string'},
      },
      'required': ['documento'],
    },
    run: (input, origin) async {
      await service.carregar();
      final caminho = await service.exportarRelatorio(
        input.requireString('documento'),
        caminho: input.optionalString('caminho'),
      );
      return CommandResult.ok(
        message: 'Relatório salvo em $caminho.',
        data: {'caminho': caminho},
      );
    },
  ),
  ModuleCommand(
    id: 'auditaBancas.exportarPdf',
    title: 'Exportar o PDF anotado',
    description:
        'Gera um PDF separado com as observações ACEITAS destacadas e '
        'páginas de notas (o original não muda). {documento, caminho?}. '
        'Precisa do Poppler; erros: sem_aceitas, exportacao_falhou.',
    inputSchema: const {
      'type': 'object',
      'properties': {
        'documento': _documento,
        'caminho': {'type': 'string'},
      },
      'required': ['documento'],
    },
    run: (input, origin) async {
      await service.carregar();
      final caminho = await service.exportarPdf(
        input.requireString('documento'),
        caminho: input.optionalString('caminho'),
      );
      return CommandResult.ok(
        message: 'PDF anotado salvo em $caminho.',
        data: {'caminho': caminho},
      );
    },
  ),
];
