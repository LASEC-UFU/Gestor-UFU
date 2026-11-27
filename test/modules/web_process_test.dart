import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_browser_driver.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_commands.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

class FakeWebBrowser extends WebBrowserDriver {
  final actions = <(String, String)>[];
  int opens = 0;
  void Function(WebStep)? onStep;
  String? failStep;
  @override
  Future<void> open(WebProcess process) async {
    opens++;
  }

  @override
  Future<void> navigate(String url) async {
    actions.add(('navigate', url));
  }

  @override
  Future<PickedWebElement> pick(bool Function() cancelled) async =>
      const PickedWebElement(selector: '#nome', label: 'Nome', tag: 'input');
  @override
  Future<String?> perform(WebStep step, String value) async {
    actions.add((step.action.name, value));
    onStep?.call(step);
    if (step.id == failStep) {
      throw const CommandException(
        'elemento_ausente',
        'Componente não encontrado.',
      );
    }
    return step.action == WebAction.read ? 'Texto lido' : null;
  }

  @override
  Future<void> capture(String directory, String name) async {
    await File('$directory/$name.html').writeAsString('<html>Teste</html>');
  }

  @override
  Future<void> startRecording() async {}
  @override
  Future<void> stopRecording(String directory) async {
    await File('$directory/rede.json').writeAsString('[]');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FakeWebBrowser browser;
  late WebProcessService service;
  late Map<String, ModuleCommand> commands;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('gestor_web_test_');
    browser = FakeWebBrowser();
    service = WebProcessService(
      KeyValueStore(),
      driver: browser,
      delay: (_) => Future.value(),
    );
    await service.load();
    commands = {
      for (final command in webProcessCommands(service)) command.id: command,
    };
  });
  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  Future<WebProcess> create({List<Map<String, Object?>>? steps}) =>
      service.saveProcess({
        'name': 'Cadastro de teste',
        'url': 'https://example.com/form',
        'outputDirectory': directory.path,
        'delayMinMs': 0,
        'delayMaxMs': 0,
        'successText': 'Resposta registrada',
        'steps':
            steps ??
            [
              {
                'id': 'nome',
                'action': 'fill',
                'selector': '#nome',
                'value': '{{nome_completo}}',
              },
              {
                'id': 'telefone',
                'action': 'fill',
                'selector': '#telefone',
                'value': '{{whatsapp}}',
                'transform': 'digits',
              },
              {'id': 'enviar', 'action': 'click', 'selector': '#enviar'},
              {
                'id': 'ler',
                'action': 'read',
                'selector': '#resultado',
                'name': 'protocolo',
              },
            ],
      });

  Future<CommandResult> runCommand(String id, Map<String, dynamic> input) =>
      commands['acoesWeb.$id']!.run(input, CommandOrigin.test);

  test(
    'IA cria processo, cadastra ações e reordena a mesma sequência da interface',
    () async {
      final result = await runCommand('salvarProcesso', {
        'process': {'name': 'Novo processo', 'url': 'https://example.com'},
      });
      final id = result.data['processId'] as String;
      final a = await runCommand('adicionarEtapa', {
        'processId': id,
        'step': {'action': 'fill', 'selector': 'nome', 'value': '{{nome}}'},
      });
      final b = await runCommand('adicionarEtapa', {
        'processId': id,
        'step': {'action': 'click', 'selector': '#enviar'},
      });
      await runCommand('reordenarEtapas', {
        'processId': id,
        'stepIds': [b.data['stepId'], a.data['stepId']],
      });
      expect(service.project(id).steps.map((s) => s.action), [
        WebAction.click,
        WebAction.fill,
      ]);
      await runCommand('atualizarEtapa', {
        'processId': id,
        'stepId': a.data['stepId'],
        'step': {'selector': '#nome-atualizado'},
      });
      expect(service.project(id).steps.last.selector, '#nome-atualizado');
      expect(
        commands['acoesWeb.executarProcesso']!.approval,
        CommandApproval.required,
      );
      expect(
        commands['acoesWeb.removerProcesso']!.approval,
        CommandApproval.required,
      );
      final reloaded = WebProcessService(
        KeyValueStore(),
        driver: FakeWebBrowser(),
      );
      await reloaded.load();
      expect(reloaded.projects.single.steps.last.selector, '#nome-atualizado');
      reloaded.dispose();
    },
  );

  test('reordenação inválida não remove nem duplica etapas', () async {
    final item = await create();
    await expectLater(
      runCommand('reordenarEtapas', {
        'processId': item.id,
        'stepIds': ['nome', 'nome'],
      }),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'code', 'ordem_invalida'),
      ),
    );
    expect(service.project(item.id).steps, hasLength(4));
  });

  test(
    'lote JSON usa campos configuráveis, normaliza telefone e registra conclusão',
    () async {
      final item = await create();
      final path = '${directory.path}/dados.json';
      await File(path).writeAsString(
        jsonEncode([
          {'nome_completo': 'Pessoa A', 'whatsapp': '(34) 99999-0000'},
          {'nome_completo': 'Pessoa B', 'whatsapp': '34 98888-0000'},
        ]),
      );
      expect(await service.importData(item.id, path), 2);
      final result = await service.run(item.id);
      expect(result['success'], 2);
      expect(result['failed'], 0);
      expect(browser.actions, [
        ('navigate', 'https://example.com/form'),
        ('fill', 'Pessoa A'),
        ('fill', '34999990000'),
        ('click', ''),
        ('read', ''),
        ('waitText', 'Resposta registrada'),
        ('navigate', 'https://example.com/form'),
        ('fill', 'Pessoa B'),
        ('fill', '34988880000'),
        ('click', ''),
        ('read', ''),
        ('waitText', 'Resposta registrada'),
      ]);
      expect(
        service.project(item.id).records.every((r) => r.status == 'success'),
        isTrue,
      );
      expect(service.project(item.id).records.first.extracted, {
        'protocolo': 'Texto lido',
      });
      final summary = File('${result['outputPath']}/resumo.json');
      expect(await summary.exists(), isTrue);
      expect(
        await File('${result['outputPath']}/registro_001/antes.html').exists(),
        isTrue,
      );
      expect(service.busy, isFalse);
      await expectLater(
        service.run(item.id),
        throwsA(
          isA<CommandException>().having(
            (e) => e.code,
            'code',
            'sem_pendentes',
          ),
        ),
      );
      expect(browser.opens, 1);
    },
  );

  test(
    'campo ausente impede qualquer ação no navegador antes da execução',
    () async {
      final item = await create();
      await service.saveRecord(item.id, {'nome_completo': 'Pessoa'});
      await expectLater(
        service.run(item.id),
        throwsA(
          isA<CommandException>().having(
            (e) => e.code,
            'code',
            'campo_ausente',
          ),
        ),
      );
      expect(browser.opens, 0);
      expect(browser.actions, isEmpty);
      expect(service.busy, isFalse);
    },
  );

  test('falha não vira sucesso e não repete o envio automaticamente', () async {
    final item = await create();
    browser.failStep = 'enviar';
    await service.saveRecord(item.id, {
      'nome_completo': 'Pessoa',
      'whatsapp': '34',
    });
    final result = await service.run(item.id);
    expect(result['success'], 0);
    expect(result['failed'], 1);
    expect(service.project(item.id).records.single.status, 'failed');
    expect(browser.actions.where((a) => a.$1 == 'click'), hasLength(1));
    await expectLater(service.run(item.id), throwsA(isA<CommandException>()));
  });

  test(
    'parada preserva registros pendentes e pede conferência do atual',
    () async {
      final item = await create();
      await service.saveRecord(item.id, {
        'nome_completo': 'A',
        'whatsapp': '1',
      });
      await service.saveRecord(item.id, {
        'nome_completo': 'B',
        'whatsapp': '2',
      });
      browser.onStep = (step) {
        if (step.id == 'enviar') service.stop();
      };
      final result = await service.run(item.id);
      expect(result['cancelled'], isTrue);
      expect(service.project(item.id).records.map((r) => r.status), [
        'review',
        'pending',
      ]);
      expect(browser.actions.where((a) => a.$1 == 'read'), isEmpty);
    },
  );

  test(
    'retomada após fechamento não reenvia registro que estava em execução',
    () async {
      final item = await create();
      await KeyValueStore().writeJson(WebProcessService.key, [
        {
          ...item.toJson(),
          'records': [
            {
              'id': 'r1',
              'values': {'nome_completo': 'A', 'whatsapp': '1'},
              'status': 'running',
            },
          ],
        },
      ]);
      await service.load();
      expect(service.project(item.id).records.single.status, 'review');
      await expectLater(service.run(item.id), throwsA(isA<CommandException>()));
      expect(browser.opens, 0);
    },
  );

  test('processo com valores fixos executa uma vez sem lote', () async {
    final item = await create(
      steps: [
        {
          'id': 's1',
          'action': 'fill',
          'selector': '#nome',
          'value': 'Valor fixo',
        },
      ],
    );
    expect((await service.run(item.id))['success'], 1);
    expect(service.project(item.id).records, hasLength(1));
    await expectLater(service.run(item.id), throwsA(isA<CommandException>()));
  });

  test(
    'modelo Palmelo tem os sete campos originais e nenhum dado pessoal',
    () async {
      final item = await service.addPalmeloTemplate();
      expect(item.steps, hasLength(8));
      expect(item.records, isEmpty);
      expect(
        item.fields,
        containsAll([
          'nome_completo',
          'whatsapp',
          'email',
          'pais',
          'cidade',
          'estado',
          'endereco_completo',
        ]),
      );
      expect(item.steps[1].transform, 'digits');
      expect(item.steps.last.action, WebAction.click);
      expect(item.successText, 'Sua resposta foi registrada');
    },
  );

  test(
    'export/import de processo preserva etapas sem copiar registros ou resultados',
    () async {
      final item = await create();
      await service.saveRecord(item.id, {
        'nome_completo': 'Nome de teste',
        'whatsapp': '1',
      });
      final path = await service.exportProcess(
        item.id,
        '${directory.path}/processo.json',
      );
      expect(await File(path).readAsString(), isNot(contains('Nome de teste')));
      final imported = await service.importProcess(path);
      expect(imported.id, isNot(item.id));
      expect(imported.records, isEmpty);
      expect(
        imported.steps.map((s) => s.toJson()),
        item.steps.map((s) => s.toJson()),
      );
    },
  );

  test('processos não aceitam URLs de arquivos ou JavaScript', () async {
    for (final url in [
      'javascript:alert(1)',
      'file:///C:/documento',
      'https://usuario:senha@example.com',
    ]) {
      await expectLater(
        service.saveProcess({'name': 'Teste', 'url': url}),
        throwsA(
          isA<CommandException>().having((e) => e.code, 'code', 'url_invalida'),
        ),
      );
    }
  });

  test('ações sem valor não exigem parâmetros antigos após editar o tipo', () {
    const step = WebStep(
      id: 's',
      action: WebAction.read,
      selector: '#resultado',
      value: '{{campo_antigo}}',
    );
    expect(step.resolve({}), '');
    expect(
      WebProcess(
        id: 'p',
        name: 'Teste',
        url: 'https://example.com',
        steps: [step],
      ).fields,
      isEmpty,
    );
  });

  test('pausa inválida é detectada antes de qualquer ação no site', () async {
    final item = await create(
      steps: [
        {'id': 'enviar', 'action': 'click', 'selector': '#enviar'},
        {'id': 'pausa', 'action': 'pause', 'value': '-5'},
      ],
    );
    await expectLater(
      service.run(item.id),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'code', 'pausa_invalida'),
      ),
    );
    expect(browser.actions, isEmpty);
    expect(browser.opens, 0);
  });
}
