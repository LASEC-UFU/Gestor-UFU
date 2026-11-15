import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/app/installed_modules.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_templates.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/modules/equivalencia/application/certidao_pdf.dart';
import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_commands.dart';
import 'package:gestor_ufu/modules/equivalencia/application/equivalencia_service.dart';
import 'package:gestor_ufu/modules/equivalencia/data/equivalencia_repository.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

void main() {
  // create_template usa os modelos declarados pelos módulos instalados.
  setUpAll(() {
    ModuleRegistry.instance.clear();
    installModules();
  });

  late Directory dir;
  late EquivalenciaService service;
  late Map<String, ModuleCommand> commands;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('equivalencia_test');
    service = EquivalenciaService(
      EquivalenciaRepository(KeyValueStore()),
      certidao: const CertidaoPdf(
        regularFontPath: 'inexistente.ttf',
        boldFontPath: 'inexistente-bold.ttf',
      ),
    );
    commands = {for (final c in equivalenciaCommands(service)) c.id: c};
  });

  tearDown(() => dir.delete(recursive: true));

  Future<String> template(String id) async =>
      (await AgentTemplates.create(id, folder: dir.path))['path'] as String;

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  test('estado inicial tem o currículo padrão', () async {
    final state = await service.load();
    expect(state.curricula.single.id, 'eca-2020');
    expect(state.currentId, 'eca-2020');
    expect(state.cases, isEmpty);
  });

  test('importa o modelo de currículo do agente (create_template)', () async {
    final path = await template('equivalencia_curriculo');
    final result = await run('equivalencia.importarCurriculo', {
      'path': path,
      'course': 'Engenharia Elétrica',
      'name': 'Currículo 2026',
    });
    expect(result.ok, isTrue);
    final state = await service.load();
    final created = state.curriculum(result.data['curriculumId'] as String)!;
    expect(created.subjects.map((s) => s.code), [
      'FEELT31101',
      'FEELT31102',
    ]);
    expect(created.subjects.last.practical, 30);
  });

  test('importa o modelo de análise com bloco mesclado', () async {
    final path = await template('equivalencia_analise');
    final result = await run('equivalencia.importarAnalise', {'path': path});
    expect(result.ok, isTrue);
    final item = (await service.load()).cases.single;
    expect(item.student, 'NOME DO ALUNO');
    expect(item.blocks, hasLength(2));
    // Linhas 2 e 3 (coluna G mesclada) formam um bloco com 2 disciplinas
    // cursadas na origem.
    expect(item.blocks.last.prior, hasLength(2));
    expect(item.blocks.last.priorHours, 90);
  });

  test('gera a certidão em PDF mesmo sem as fontes do Windows', () async {
    final path = await template('equivalencia_analise');
    await run('equivalencia.importarAnalise', {'path': path});
    final caseId = (await service.load()).cases.single.id;
    final result = await run('equivalencia.gerarCertidao', {
      'caseId': caseId,
      'path': '${dir.path}/certidao',
    });
    final pdf = File(result.data['path'] as String);
    expect(pdf.path, endsWith('.pdf'));
    expect(utf8.decode((await pdf.readAsBytes()).sublist(0, 4)), '%PDF');
  });

  test('remover análise exige aprovação e apaga do banco', () async {
    final path = await template('equivalencia_analise');
    await run('equivalencia.importarAnalise', {'path': path});
    final command = commands['equivalencia.removerAnalise']!;
    expect(command.approval, CommandApproval.required);
    final caseId = (await service.load()).cases.single.id;
    await run('equivalencia.removerAnalise', {'caseId': caseId});
    expect((await service.load()).cases, isEmpty);
  });

  test('erros têm código estável', () async {
    expect(
      () => run('equivalencia.importarAnalise', {'path': 'nao-existe.xlsx'}),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'arquivo_nao_encontrado',
        ),
      ),
    );
    expect(
      () => run('equivalencia.removerAnalise', {'caseId': 'x'}),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'analise_nao_encontrada',
        ),
      ),
    );
  });

  test('migra a chave antiga sem apagá-la', () async {
    SharedPreferences.setMockInitialValues({
      EquivalenciaRepository.legacyKey: jsonEncode([
        {
          'id': 'a1',
          'student': 'Ana',
          'destinationCourse': 'Engenharia Elétrica',
          'destinationSubject': 'Cálculo I',
          'sourceSubject': 'Cálculo A',
          'hours': '60',
        },
      ]),
    });
    final state = await service.load();
    expect(state.cases.single.student, 'Ana');
    expect(state.cases.single.blocks.single.currentHours, 60);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(EquivalenciaRepository.legacyKey), isNotNull);
    expect(prefs.getString(EquivalenciaRepository.key), isNotNull);
  });
}
