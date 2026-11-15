import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';
import 'package:gestor_ufu/platform/ui/academic_term_selector.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';

void main() {
  late AcademicTermService terms;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      AcademicTermService.termsKey: ['2026/2', '2027/1'],
      AcademicTermService.activeKey: '2027/1',
    });
    terms = AcademicTermService(KeyValueStore());
    await terms.load();
    AcademicTermService.shared = terms;
  });

  tearDown(() => AcademicTermService.shared = null);

  Widget app() => ChangeNotifierProvider(
    create: (_) => ThemeController(isLight: true),
    child: MaterialApp(
      home: Scaffold(
        body: ModuleHeader(
          title: 'Módulo',
          icon: Icons.extension_rounded,
          accent: Colors.blue,
          onBack: () {},
          actions: const [Text('ação')],
        ),
      ),
    ),
  );

  testWidgets('período, agente e tema ficam encostados à direita', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());

    final width = tester.getSize(find.byType(ModuleHeader)).width;
    final theme = tester.getRect(find.byType(ThemeSelector));
    final term = tester.getRect(find.byType(AcademicTermSelector));
    final action = tester.getRect(find.text('ação'));
    // Só o padding do cabeçalho (20) depois do tema.
    expect(width - theme.right, closeTo(20, 1));
    expect(term.right, lessThan(theme.left));
    expect(action.right, lessThan(term.left));
    // As ações ficam junto do período, não perto do título.
    expect(term.left - action.right, lessThan(30));
  });

  testWidgets('o diálogo troca o período compartilhado', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('2027_1'), findsOneWidget);

    await tester.tap(find.byType(AcademicTermSelector));
    await tester.pumpAndSettle();
    expect(find.text('Períodos letivos'), findsOneWidget);
    expect(find.text('Novo período letivo'), findsOneWidget);
    expect(find.text('Fechar'), findsOneWidget);

    await tester.tap(find.text('2026_2'));
    await tester.pumpAndSettle();
    expect(terms.active, '2026/2');
    expect(find.text('2026_2'), findsOneWidget);
  });
}
