import 'package:gestor_ufu/modules/equivalencia/application/certidao_pdf.dart';
import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

/// Comandos da Equivalência de Alunos (tela, menu "/" e Agente de IA).
List<ModuleCommand> equivalenciaCommands(EquivalenciaService service) => [
  ModuleCommand(
    id: 'equivalencia.listar',
    title: 'Listar currículos e análises',
    description:
        'Currículos (id, curso, nome, nº de disciplinas), análises (id, aluno, '
        'matrícula, situação, nº de blocos) e o currículo selecionado.',
    run: (input, origin) async {
      final state = await service.load();
      return CommandResult.ok(
        data: {
          'currentId': state.currentId,
          'curricula': [
            for (final c in state.curricula)
              {
                'id': c.id,
                'course': c.course,
                'name': c.name,
                'subjects': c.subjects.length,
              },
          ],
          'cases': [
            for (final c in state.cases)
              {
                'id': c.id,
                'student': c.student,
                'studentId': c.studentId,
                'status': c.status,
                'blocks': c.blocks.length,
                'curriculumId': c.currentCurriculumId,
              },
          ],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'equivalencia.importarCurriculo',
    title: 'Importar disciplinas de currículo (.xlsx)',
    description:
        'Lê a planilha de disciplinas (modelo equivalencia_curriculo) e grava '
        'no currículo curriculumId, ou cria um currículo novo com course e '
        'name. replace=true troca a lista; senão mescla sem repetir.',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Caminho do .xlsx/.xlsm'},
        'curriculumId': {'type': 'string'},
        'course': {'type': 'string'},
        'name': {'type': 'string'},
        'replace': {'type': 'boolean'},
      },
      'required': ['path'],
    },
    run: (input, origin) async {
      final bytes = await GestorPaths.readInput(input.requireString('path'));
      final result = await service.importCurriculum(
        bytes,
        curriculumId: input.optionalString('curriculumId'),
        course: input.optionalString('course'),
        name: input.optionalString('name'),
        replace: input.flag('replace'),
      );
      return CommandResult.ok(
        message:
            '${result.imported} disciplinas lidas; o currículo '
            '"${result.curriculum.label}" tem agora '
            '${result.curriculum.subjects.length}.',
        data: {'curriculumId': result.curriculum.id},
      );
    },
  ),
  ModuleCommand(
    id: 'equivalencia.importarAnalise',
    title: 'Importar análise de aluno (.xlsx)',
    description:
        'Lê a planilha de análise (aba Equivalencia, modelo '
        'equivalencia_analise) e grava como nova análise no currículo '
        'curriculumId (padrão: o selecionado na tela).',
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'curriculumId': {'type': 'string'},
      },
      'required': ['path'],
    },
    run: (input, origin) async {
      final bytes = await GestorPaths.readInput(input.requireString('path'));
      final item = await service.importAnalysis(
        bytes,
        curriculumId: input.optionalString('curriculumId'),
      );
      return CommandResult.ok(
        message:
            'Análise de "${item.student}" importada com '
            '${item.blocks.length} bloco(s).',
        data: {'caseId': item.id},
      );
    },
  ),
  ModuleCommand(
    id: 'equivalencia.gerarCertidao',
    title: 'Gerar certidão de estudos (PDF)',
    description:
        'Gera o PDF da certidão de uma análise (caseId). path opcional; o '
        'padrão é Documentos/GestorUFU Agente/equivalencia.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'caseId': {'type': 'string'},
        'path': {'type': 'string'},
      },
      'required': ['caseId'],
    },
    run: (input, origin) async {
      final caseId = input.requireString('caseId');
      final item = (await service.load()).caseById(caseId);
      if (item == null) {
        throw CommandException(
          'analise_nao_encontrada',
          'Análise "$caseId" não encontrada.',
        );
      }
      final path = await GestorPaths.outputPath(
        input.optionalString('path'),
        CertidaoPdf.fileName(item),
        sub: 'equivalencia',
      );
      final saved = await service.exportCertidao(caseId, path);
      return CommandResult.ok(
        message: 'Certidão gerada.',
        data: {'path': saved},
      );
    },
  ),
  ModuleCommand(
    id: 'equivalencia.removerAnalise',
    title: 'Remover análise',
    description: 'Apaga uma análise (caseId). Pede confirmação ao usuário.',
    approval: CommandApproval.required,
    mutates: true,
    inputSchema: {
      'type': 'object',
      'properties': {
        'caseId': {'type': 'string'},
      },
      'required': ['caseId'],
    },
    run: (input, origin) async {
      final item = await service.removeCase(input.requireString('caseId'));
      return CommandResult.ok(
        message:
            'Análise de "${item.student.isEmpty ? 'aluno sem nome' : item.student}" '
            'removida.',
      );
    },
  ),
];
