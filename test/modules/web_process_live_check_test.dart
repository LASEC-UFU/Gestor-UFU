import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:puppeteer/puppeteer.dart';
import 'package:gestor_ufu/platform/services/browser_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_browser_driver.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'confere sete campos no formulário real sem enviar',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gestor_live_check_',
      );
      final browser = await puppeteer.launch(
        executablePath: await BrowserService.findExecutable(),
        headless: true,
        userDataDir: '${directory.path}/profile',
      );
      try {
        final page = await browser.newPage();
        var submissionAttempts = 0;
        page.onRequest.listen((r) async {
          if (r.url.contains('/formResponse')) submissionAttempts++;
          if (r.method != 'GET' || r.url.contains('/formResponse')) {
            await r.abort();
          } else {
            await r.continueRequest();
          }
        });
        await page.setRequestInterception(true);
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
        final driver = PuppeteerWebBrowserDriver(
          pageFactory: (_) async => page,
        );
        await driver.open(
          WebProcess(id: 'check', name: 'Check', url: raw['url'] as String),
        );
        final values = [
          'Teste local sem envio',
          '34999990000',
          'teste@example.com',
          'Brasil',
          'Uberlândia',
          'MG',
          'Endereço de teste',
        ];
        for (var i = 0; i < steps.length; i++) {
          await driver.perform(steps[i], values[i]);
          final actual = await page.evaluate<String>(
            '(selector) => [...document.querySelectorAll(selector)].find(e=>e.getClientRects().length && e.type !== "hidden").value',
            args: [steps[i].selector],
          );
          expect(actual, values[i], reason: steps[i].name);
        }
        expect(
          await page.evaluate<bool>(
            '() => [...document.querySelectorAll("[role=button],button")].some(e=>e.innerText.trim()==="Enviar")',
          ),
          isTrue,
        );
        // Nenhum clique em Enviar. Interceptação impede qualquer POST adicional.
        expect(page.url, contains('/viewform'));
        expect(submissionAttempts, 0);
      } finally {
        await browser.close();
        for (var i = 0; i < 20; i++) {
          try {
            await directory.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !const bool.fromEnvironment('GESTOR_LIVE_FORM_CHECK'),
  );
}
