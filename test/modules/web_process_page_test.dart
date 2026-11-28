import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/app/installed_modules.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/pages/web_process_page.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'web_process_test.dart' show FakeWebBrowser;

void main() {
  testWidgets('interface cria processo, ação com ID/valor e registro do lote', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    ModuleRegistry.instance.clear();
    installModules();
    addTearDown(ModuleRegistry.instance.clear);
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final browser = FakeWebBrowser();
    final service = WebProcessService(KeyValueStore(), driver: browser);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeController(isLight: true),
        child: MaterialApp(home: WebProcessPage(service: service)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Criar Ações na Web'), findsOneWidget);
    await tester.tap(find.text('Novo processo').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'Processo pela interface',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'https://example.com/form',
    );
    await tester.tap(find.text('Salvar processo'));
    await tester.pumpAndSettle();
    expect(service.projects.single.name, 'Processo pela interface');
    await tester.tap(find.text('Etapas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar ação'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Preencher nome');
    await tester.enterText(find.byType(TextFormField).at(1), '#nome');
    await tester.enterText(find.byType(TextFormField).at(2), '{{nome}}');
    await tester.tap(find.text('Salvar ação'));
    await tester.pumpAndSettle();
    expect(service.projects.single.steps.single.selector, '#nome');
    expect(service.projects.single.steps.single.value, '{{nome}}');
    await tester.tap(find.text('Dados do lote'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novo registro'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Pessoa de teste');
    await tester.tap(find.text('Salvar registro'));
    await tester.pumpAndSettle();
    expect(service.projects.single.records.single.values, {
      'nome': 'Pessoa de teste',
    });
    expect(browser.opens, 0);
    expect(browser.actions, isEmpty);
    await tester.tap(find.text('Configuração'));
    await tester.pumpAndSettle();
    expect(find.text('Usar modelo Palmelo'), findsNothing);
    await tester.tap(find.text('Usar processo como modelo'));
    await tester.pumpAndSettle();
    expect(find.text('Processo existente'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Outro processo');
    await tester.tap(find.text('Criar processo'));
    await tester.pumpAndSettle();
    expect(service.projects, hasLength(2));
    expect(service.projects.last.name, 'Outro processo');
    expect(service.projects.last.records, isEmpty);
    expect(service.projects.last.steps.single.selector, '#nome');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
}
