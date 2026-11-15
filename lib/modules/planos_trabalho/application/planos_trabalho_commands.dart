import 'dart:io';

import 'package:gestor_ufu/modules/planos_trabalho/application/planilha_trabalho_service.dart';
import 'package:gestor_ufu/modules/planos_trabalho/data/planos_trabalho_store.dart';
import 'package:gestor_ufu/modules/planos_trabalho/domain/plano_trabalho.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

const _planoId = {
  'id': {'type': 'string', 'description': 'id de planosTrabalho.listar'},
};

/// Comandos dos Planos de Trabalho (tela, menu "/" e Agente de IA).
List<ModuleCommand> planosTrabalhoCommands(
  PlanosTrabalhoStore store,
  SeiAutomationService sei, {
  PlanilhaTrabalhoService? planilhaService,
}) {
  final planilha = planilhaService ?? PlanilhaTrabalhoService();
  Future<PlanoTrabalho> plano(String id) async {
    for (final p in await store.list()) {
      if (p.id == id) return p;
    }
    throw CommandException(
      'plano_nao_encontrado',
      'Plano "$id" não encontrado.',
    );
  }

  CommandException invalid(Object error) => CommandException(
    'entrada_invalida',
    error is StateError ? error.message : '$error',
  );

  return [
    ModuleCommand(
      id: 'planosTrabalho.listar',
      title: 'Listar planos de trabalho',
      description:
          'Cadastros (id, nome, número, nome na árvore, interessado, PDF, nº '
          'de campos da planilha). Com id, devolve os campos da planilha.',
      inputSchema: {'type': 'object', 'properties': _planoId},
      run: (input, origin) async {
        final id = input.optionalString('id');
        if (id != null) {
          final p = await plano(id);
          return CommandResult.ok(data: {...p.toJson()});
        }
        return CommandResult.ok(
          data: {
            'planos': [
              for (final p in await store.list())
                {
                  'id': p.id,
                  'nome': p.nome,
                  'numero': p.numero,
                  'nomeArvore': p.nomeArvore,
                  'interessado': p.interessado,
                  'pdfPath': p.pdfPath,
                  'campos':
                      (p.spreadsheetData?['fields'] as List?)?.length ?? 0,
                },
            ],
          },
        );
      },
    ),
    ModuleCommand(
      id: 'planosTrabalho.salvarCadastro',
      title: 'Salvar cadastro do plano',
      description:
          'Cria (sem id) ou atualiza o cadastro: nome, numero e/ou '
          'nomeArvore (até 50 caracteres), interessado e pdfPath.',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'nome': {'type': 'string'},
          'numero': {'type': 'string'},
          'nomeArvore': {'type': 'string'},
          'interessado': {'type': 'string'},
          'pdfPath': {'type': 'string'},
        },
        'required': ['nome'],
      },
      run: (input, origin) async {
        final id = input.optionalString('id');
        final previous = id == null ? null : await plano(id);
        try {
          final saved = await store.save(
            id: id,
            nome: input.requireString('nome'),
            numero: input.optionalString('numero') ?? previous?.numero ?? '',
            nomeArvore:
                input.optionalString('nomeArvore') ??
                previous?.nomeArvore ??
                '',
            interessado:
                input.optionalString('interessado') ??
                previous?.interessado ??
                '',
            pdfPath: input.optionalString('pdfPath') ?? previous?.pdfPath ?? '',
          );
          return CommandResult.ok(
            message: 'Cadastro salvo.',
            data: {'id': saved.id},
          );
        } on StateError catch (error) {
          throw invalid(error);
        }
      },
    ),
    ModuleCommand(
      id: 'planosTrabalho.remover',
      title: 'Remover plano de trabalho',
      description: 'Remove o cadastro (o PDF não é apagado). Pede confirmação.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': _planoId,
        'required': ['id'],
      },
      run: (input, origin) async {
        final p = await plano(input.requireString('id'));
        await store.delete(p.id);
        return CommandResult.ok(message: 'Plano "${p.nome}" removido.');
      },
    ),
    ModuleCommand(
      id: 'planosTrabalho.importarPlanilha',
      title: 'Importar dados da planilha oficial',
      description:
          'Lê a planilha oficial preenchida (.xlsx/.xlsm, todas as abas do '
          'modelo) e guarda os valores no plano (campos com fórmula são '
          'ignorados).',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'path': {'type': 'string'},
        },
        'required': ['id', 'path'],
      },
      run: (input, origin) async {
        final p = await plano(input.requireString('id'));
        final path = input.requireString('path');
        await GestorPaths.readInput(path);
        final Map<String, dynamic> data;
        try {
          data = planilha.capture(path);
        } on FormatException catch (error) {
          throw CommandException('planilha_invalida', error.message);
        }
        await store.saveSpreadsheetData(p.id, data);
        return CommandResult.ok(
          message:
              '${(data['fields'] as List).length} campo(s) importado(s); '
              '${(data['ignoredFormulas'] as List).length} com fórmula '
              'ignorado(s).',
        );
      },
    ),
    ModuleCommand(
      id: 'planosTrabalho.definirCampo',
      title: 'Alterar um campo da planilha',
      description:
          'Muda o valor de um campo guardado (section + cell, ex.: "aulas" e '
          '"C15"; veja planosTrabalho.listar com id).',
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'section': {'type': 'string'},
          'cell': {'type': 'string'},
          'value': {},
        },
        'required': ['id', 'section', 'cell'],
      },
      run: (input, origin) async {
        final p = await plano(input.requireString('id'));
        final data = Map<String, dynamic>.from(p.spreadsheetData ?? {});
        final fields = [
          for (final f
              in (data['fields'] as List? ?? const []).whereType<Map>())
            Map<String, dynamic>.from(f),
        ];
        final section = input.requireString('section');
        final cell = input.requireString('cell').toUpperCase();
        final index = fields.indexWhere(
          (f) =>
              f['section'] == section && '${f['cell']}'.toUpperCase() == cell,
        );
        if (index < 0) {
          throw CommandException(
            'campo_nao_encontrado',
            'Campo $section!$cell não existe nos dados importados.',
          );
        }
        fields[index]['value'] = input['value'];
        data['fields'] = fields;
        await store.saveSpreadsheetData(p.id, data);
        return CommandResult.ok(message: 'Campo $section!$cell atualizado.');
      },
    ),
    ModuleCommand(
      id: 'planosTrabalho.preencherPlanilha',
      title: 'Gerar cópia preenchida da planilha',
      description:
          'Copia o modelo (modeloPath, .xlsx/.xlsm oficial) para destino com '
          'os valores guardados; fórmulas e formatação são preservadas; '
          'campos vazios não substituem dados do modelo.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'modeloPath': {'type': 'string'},
          'destino': {'type': 'string'},
        },
        'required': ['id', 'modeloPath'],
      },
      run: (input, origin) async {
        final p = await plano(input.requireString('id'));
        final data = p.spreadsheetData;
        if (data == null) {
          throw const CommandException(
            'sem_dados',
            'Importe os dados de uma planilha preenchida antes.',
          );
        }
        final model = input.requireString('modeloPath');
        await GestorPaths.readInput(model);
        final ext = model.toLowerCase().endsWith('.xlsm') ? 'xlsm' : 'xlsx';
        final target = await GestorPaths.outputPath(
          input.optionalString('destino'),
          'Plano_de_Trabalho_${p.nome.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.$ext',
          sub: 'planos_trabalho',
        );
        try {
          final changes = await planilha.fillCopy(
            sourcePath: model,
            destinationPath: target,
            data: data,
          );
          return CommandResult.ok(
            message: '${changes.length} campo(s) preenchido(s).',
            data: {'path': target},
          );
        } on FormatException catch (error) {
          throw CommandException('planilha_invalida', error.message);
        }
      },
    ),
    ModuleCommand(
      id: 'planosTrabalho.abrirSei',
      title: 'Abrir o SEI no Edge (planos de trabalho)',
      description:
          'Abre o Edge do SEI (url opcional). O usuário faz login e abre o '
          'processo.',
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
      id: 'planosTrabalho.inserirNoSei',
      title: 'Inserir o PDF do plano no SEI',
      description:
          'Inclui o PDF do plano como documento externo (tipo Plano, data de '
          'hoje, nato-digital, público) no processo aberto no Edge. Pede '
          'confirmação.',
      approval: CommandApproval.required,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._planoId,
          'pdfPath': {'type': 'string'},
        },
        'required': ['id'],
      },
      run: (input, origin) async {
        final p = await plano(input.requireString('id'));
        final pdf = input.optionalString('pdfPath') ?? p.pdfPath;
        if (pdf.isEmpty || !await File(pdf).exists()) {
          throw const CommandException(
            'pdf_nao_encontrado',
            'Informe o PDF do plano (pdfPath).',
          );
        }
        if (!sei.isConnected) {
          throw const CommandException(
            'sei_fechado',
            'Abra o SEI (planosTrabalho.abrirSei) e o processo antes de inserir.',
          );
        }
        final logs = <String>[];
        await sei.insertPlan(
          pdfPath: pdf,
          numero: p.numero,
          nomeArvore: p.nomeArvore,
          interessado: p.interessado,
          log: logs.add,
        );
        return CommandResult.ok(
          message: 'Documento inserido no SEI. Revise antes de assinar.',
          data: {'log': logs.take(40).toList()},
        );
      },
    ),
  ];
}
