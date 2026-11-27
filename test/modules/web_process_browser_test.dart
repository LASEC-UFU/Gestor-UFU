import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:puppeteer/puppeteer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_browser_driver.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/browser_service.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late Browser browser;
  late Page page;
  late Directory directory;
  late String url;
  final posted = <Map<String, String>>[];
  var available = false;

  setUpAll(() async {
    final executable = await BrowserService.findExecutable();
    if (executable == null) return;
    directory = await Directory.systemTemp.createTemp(
      'gestor_web_browser_test_',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/form';
    server.listen((request) async {
      request.response.headers.contentType = ContentType(
        'text',
        'html',
        charset: 'utf-8',
      );
      if (request.method == 'POST' && request.uri.path == '/enviado') {
        final body = await utf8.decoder.bind(request).join();
        final values = Uri.splitQueryString(body);
        posted.add(values);
        request.response.write(
          '<html><body><p id="confirmacao">Resposta registrada</p><p id="resultado">${values['nome']}</p></body></html>',
        );
      } else {
        request.response.write('''<!doctype html><html><body>
          <form action="/enviado" method="post">
          <label for="nome">Nome completo</label><input id="nome" name="nome">
          <input id="telefone" name="telefone">
          <select id="pais" name="pais"><option value="">Escolher</option><option value="BR">Brasil</option></select>
          <input id="aceito" name="aceito" type="checkbox" value="sim">
          <input id="anexo" type="file" style="display:none">
          <button id="enviar" type="submit">Enviar</button>
          <div id="acao-div" role="button" onclick="window.disparou=true">Ação</div>
          </form><iframe srcdoc='<input id="interno"><button id="botao" onclick="window.executou=true">Botão</button>'></iframe>
          </body></html>''');
      }
      await request.response.close();
    });
    browser = await puppeteer.launch(
      executablePath: executable,
      headless: true,
      userDataDir: '${directory.path}/profile',
      defaultViewport: DeviceViewport(width: 1000, height: 750),
    );
    page = await browser.newPage();
    available = true;
  });
  tearDownAll(() async {
    if (!available) return;
    await browser.close();
    await server.close(force: true);
    for (var i = 0; i < 20; i++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });
  test(
    'modelo Palmelo localiza campos anônimos pelos identificadores originais',
    () async {
      if (!available) {
        markTestSkipped('Edge/Chrome não instalado.');
        return;
      }
      final raw =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/web_automation/palmelo.json',
                ),
              )
              as Map<String, dynamic>;
      final steps = (raw['steps'] as List)
          .take(7)
          .map((s) => WebStep.fromJson(Map<String, dynamic>.from(s as Map)))
          .toList();
      final html = steps.map((s) {
        final id = RegExp(r'entry\.(\d+)').firstMatch(s.selector)![1];
        return '<section data-params="%.@.[[$id,null,true]]"><input type="text"></section>';
      }).join();
      await page.evaluate(
        '(html) => { document.body.innerHTML = html; }',
        args: [html],
      );
      final driver = PuppeteerWebBrowserDriver(
        pageFactory: (_) => Future.value(page),
      );
      await driver.open(
        WebProcess(id: 'palmelo-local', name: 'Campos locais', url: url),
      );
      for (var i = 0; i < steps.length; i++) {
        await driver.perform(steps[i], 'valor $i');
      }
      expect(
        await page.evaluate<List>(
          '() => [...document.querySelectorAll("input")].map(e=>e.value)',
        ),
        List.generate(7, (i) => 'valor $i'),
      );
      expect(posted, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    posted.clear();
    if (available) await page.goto(url);
  });

  test(
    'executa campos, seleção, checkbox e envio somente em servidor local',
    () async {
      if (!available) {
        markTestSkipped('Edge/Chrome não instalado.');
        return;
      }
      final driver = PuppeteerWebBrowserDriver(
        pageFactory: (_) => Future.value(page),
      );
      final service = WebProcessService(KeyValueStore(), driver: driver);
      final process = await service.saveProcess({
        'name': 'Cadastro local',
        'url': url,
        'outputDirectory': directory.path,
        'successText': 'Resposta registrada',
        'delayMinMs': 0,
        'delayMaxMs': 0,
        'steps': [
          {
            'id': 'nome',
            'action': 'fill',
            'selector': 'nome',
            'value': '{{nome}}',
          },
          {
            'id': 'telefone',
            'action': 'fill',
            'selector': '#telefone',
            'value': '{{telefone}}',
            'transform': 'digits',
          },
          {
            'id': 'pais',
            'action': 'select',
            'selector': '#pais',
            'value': 'Brasil',
          },
          {'id': 'aceito', 'action': 'check', 'selector': '#aceito'},
          {'id': 'aceito2', 'action': 'check', 'selector': '#aceito'},
          {'id': 'enviar', 'action': 'click', 'selector': '#enviar'},
          {
            'id': 'ler',
            'name': 'protocolo',
            'action': 'read',
            'selector': '#resultado',
          },
        ],
      });
      await service.saveRecord(process.id, {
        'nome': 'Pessoa de teste',
        'telefone': '(34) 99999-0000',
      });
      final result = await service.run(process.id);
      expect(
        result['success'],
        1,
        reason: service.project(process.id).records.single.message,
      );
      expect(posted, [
        {
          'nome': 'Pessoa de teste',
          'telefone': '34999990000',
          'pais': 'BR',
          'aceito': 'sim',
        },
      ]);
      expect(service.project(process.id).records.single.extracted, {
        'protocolo': 'Pessoa de teste',
      });
      expect(
        await File('${result['outputPath']}/registro_001/antes.png').exists(),
        isTrue,
      );
      expect(
        await File('${result['outputPath']}/registro_001/depois.html').exists(),
        isTrue,
      );
      expect(await File('${result['outputPath']}/rede.json').exists(), isTrue);
      service.dispose();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'seleção visual captura ID sem acionar o botão nem enviar o formulário',
    () async {
      if (!available) {
        markTestSkipped('Edge/Chrome não instalado.');
        return;
      }
      final driver = PuppeteerWebBrowserDriver(
        pageFactory: (_) => Future.value(page),
      );
      await driver.open(
        WebProcess(id: 'picker', name: 'Seleção local', url: url),
      );
      final picking = driver.pick(() => false);
      await page.waitForSelector('[data-gestor-web-picker="instructions"]');
      await page.click('#enviar');
      final element = await picking;
      expect(element.selector, '#enviar');
      expect(element.tag, 'button');
      expect(element.framePath, isEmpty);
      expect(posted, isEmpty);
      expect(page.url, contains('/form'));
      final pickingDiv = driver.pick(() => false);
      await page.waitForSelector('[data-gestor-web-picker="instructions"]');
      await page.click('#acao-div');
      expect((await pickingDiv).role, 'button');
      expect(
        await page.evaluate<bool>('() => window.disparou === true'),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'seleção em iframe e anexo oculto funcionam sem enviar dados',
    () async {
      if (!available) {
        markTestSkipped('Edge/Chrome não instalado.');
        return;
      }
      final driver = PuppeteerWebBrowserDriver(
        pageFactory: (_) => Future.value(page),
      );
      await driver.open(
        WebProcess(id: 'iframe', name: 'Quadro local', url: url),
      );
      final frame = page.frames.firstWhere((f) => f.parentFrame != null);
      final picking = driver.pick(() => false);
      await frame.waitForSelector('[data-gestor-web-picker="instructions"]');
      await frame.click('#interno');
      final element = await picking;
      expect(element.selector, '#interno');
      expect(element.framePath, [0]);
      await driver.perform(
        WebStep(
          id: 'fill',
          action: WebAction.fill,
          selector: element.selector,
          framePath: element.framePath,
        ),
        'Texto no quadro',
      );
      expect(
        await frame.evaluate<String>(
          '() => document.querySelector("#interno").value',
        ),
        'Texto no quadro',
      );
      final file = File('${directory.path}/anexo.txt');
      await file.writeAsString('Arquivo de teste');
      await driver.perform(
        const WebStep(
          id: 'upload',
          action: WebAction.upload,
          selector: '#anexo',
        ),
        file.path,
      );
      expect(
        await page.evaluate<String>(
          '() => document.querySelector("#anexo").files[0].name',
        ),
        'anexo.txt',
      );
      expect(posted, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Esc cancela a escolha de elemento e remove o seletor visual',
    () async {
      if (!available) {
        markTestSkipped('Edge/Chrome não instalado.');
        return;
      }
      final driver = PuppeteerWebBrowserDriver(
        pageFactory: (_) => Future.value(page),
      );
      await driver.open(
        WebProcess(id: 'cancel', name: 'Seleção local', url: url),
      );
      final picking = driver.pick(() => false);
      final expectation = expectLater(
        picking,
        throwsA(
          isA<CommandException>().having((e) => e.code, 'code', 'cancelado'),
        ),
      );
      await page.waitForSelector('[data-gestor-web-picker="instructions"]');
      await page.evaluate(
        '() => document.dispatchEvent(new KeyboardEvent("keydown", {key:"Escape",bubbles:true}))',
      );
      await expectation;
      expect(
        await page.$OrNull('[data-gestor-web-picker="instructions"]'),
        isNull,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
