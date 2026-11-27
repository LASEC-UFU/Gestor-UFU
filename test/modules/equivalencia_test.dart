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
import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('currículos no banco e migração de períodos', () {
    const expectedPeriods = {
      'INFIS39032': '1º Período',
      'INFIS31402': '2º Período',
      'INFIS39056': '2º Período',
      'FEELT32301': '3º Período',
      'INFIS39034': '4º Período',
      'FEELT32401': '4º Período',
      'FEELT32602': '6º Período',
    };

    Map<String, dynamic> subject(String code, {String period = 'Optativas'}) =>
        {
          'code': code,
          'name': 'Disciplina $code',
          'theoretical': 45,
          'practical': 15,
          'period': period,
          'observacao': 'preservar',
        };

    Map<String, dynamic> database(List<Map<String, dynamic>> subjects) => {
      'curricula': [
        {
          'id': 'eca-2020',
          'course': 'Curso editado',
          'name': 'Nome editado',
          'subjects': subjects,
          'extra': true,
        },
      ],
      'cases': [
        {
          'id': 'a1',
          'student': 'Ana',
          'priorCurriculumId': 'origem',
          'history': [],
          'blocks': [],
          'notasExtras': 'preservar',
        },
      ],
      'currentId': 'eca-2020',
      'campoExtra': {'valor': 42},
    };

    Future<void> write(Map<String, dynamic> data) =>
        KeyValueStore().writeJson(EquivalenciaRepository.key, data);

    Future<Map> read() async =>
        (await KeyValueStore().readJson(EquivalenciaRepository.key)) as Map;

    test(
      'load preserva currículo editado sem repor disciplinas da semente',
      () async {
        final data = database([subject('INFIS39032', period: '8º Período')]);
        data['schemaVersion'] = 2;
        await write(data);
        final state = await service.load();
        expect(state.curricula.single.course, 'Curso editado');
        expect(state.curricula.single.subjects.single.period, '8º Período');
        expect(await read(), data);
        await service.load();
        expect(await read(), data);
      },
    );

    test(
      'banco vazio recebe semente corrigida uma vez e conserva exclusões',
      () async {
        final repository = EquivalenciaRepository(KeyValueStore());
        final initial = await repository.load();
        for (final entry in expectedPeriods.entries) {
          expect(
            initial.curricula.single.subjects
                .singleWhere((s) => s.code == entry.key)
                .period,
            entry.value,
          );
        }
        expect((await read())['schemaVersion'], 2);
        await repository.save(
          initial.copyWith(
            curricula: [
              initial.curricula.single.copyWith(
                subjects: [
                  const Subject(
                    code: 'NOVO',
                    name: 'Manual',
                    theoretical: 10,
                    practical: 20,
                    period: 'Livre',
                  ),
                ],
              ),
            ],
          ),
        );
        final loaded = await EquivalenciaRepository(KeyValueStore()).load();
        expect(loaded.curricula.single.subjects.single.code, 'NOVO');
        expect(loaded.curricula.single.subjects.single.period, 'Livre');
        expect((await read())['schemaVersion'], 2);
      },
    );

    test('não adiciona ECA quando outro currículo já existe', () async {
      final data = database([subject('EX1')]);
      data['curricula'][0]['id'] = 'personalizado';
      data['currentId'] = 'personalizado';
      await write(data);
      final state = await service.load();
      expect(state.curricula.single.id, 'personalizado');
      expect(state.curricula.single.subjects.single.period, 'Optativas');
    });

    test(
      'migra sete períodos e remove duplicata de código com nome diferente',
      () async {
        final subjects = [
          for (final code in expectedPeriods.keys) subject(code),
          {
            ...subject('INFIS39056'),
            'name': 'Experimental de Física Básica:Oscilações, Ondas e Óptica',
          },
          subject('SEM_PERIODO', period: ''),
        ];
        subjects[0]['period'] = '';
        final data = database(subjects);
        await write(data);
        final state = await service.load();
        expect(state.curricula.single.subjects, hasLength(8));
        for (final entry in expectedPeriods.entries) {
          expect(
            state.curricula.single.subjects
                .singleWhere((s) => s.code == entry.key)
                .period,
            entry.value,
          );
        }
        final saved = await read();
        expect(saved['schemaVersion'], 2);
        expect(saved['cases'], data['cases']);
        expect(saved['currentId'], data['currentId']);
        expect(saved['campoExtra'], data['campoExtra']);
        expect(saved['curricula'][0]['extra'], true);
        expect(saved['curricula'][0]['subjects'][0]['observacao'], 'preservar');
        expect(state.curricula.single.subjects.last.period, '');
      },
    );

    test(
      'migração preserva período personalizado inclusive em duplicatas',
      () async {
        await write(
          database([
            subject('INFIS39056'),
            subject('INFIS39056', period: '9º Período'),
            subject('INFIS39032', period: 'Integral'),
          ]),
        );
        final state = await service.load();
        expect(state.curricula.single.subjects.map((s) => s.period), [
          '9º Período',
          'Integral',
        ]);
      },
    );

    test('migração não roda novamente após edições e salvamento', () async {
      final repository = EquivalenciaRepository(KeyValueStore());
      await write(database([subject('INFIS39032')]));
      final migrated = await repository.load();
      await repository.save(
        migrated.copyWith(
          curricula: [
            migrated.curricula.single.copyWith(
              subjects: [
                Subject.fromJson(subject('INFIS39032')),
                Subject.fromJson(subject('INFIS39056', period: '')),
              ],
            ),
          ],
        ),
      );
      final loaded = await EquivalenciaRepository(KeyValueStore()).load();
      expect(loaded.curricula.single.subjects.map((s) => s.period), [
        'Optativas',
        '',
      ]);
      expect((await read())['schemaVersion'], 2);
    });

    test('semente JSON pode ser importada preservando os períodos', () async {
      final bytes = await File(EquivalenciaRepository.seedAsset).readAsBytes();
      final imported = service.parseCurriculum(bytes);
      for (final entry in expectedPeriods.entries) {
        expect(
          imported.singleWhere((s) => s.code == entry.key).period,
          entry.value,
        );
      }
      expect(imported.map((s) => s.code).toSet(), hasLength(imported.length));
    });
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
    expect(created.subjects.map((s) => s.code), ['FEELT31101', 'FEELT31102']);
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
