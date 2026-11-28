import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/presentation/pages/dashboard_page.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';

void main() {
  for (final width in [1400.0, 960.0, 640.0, 480.0, 420.0, 360.0]) {
    testWidgets('cabeçalho mantém ações acessíveis sem overflow em $width px', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var settingsPressed = false;
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => ThemeController(isLight: true),
          child: MaterialApp(
            home: Scaffold(
              body: DashboardHeader(
                compact: width < 700,
                onSettingsPressed: () => settingsPressed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final selector = tester.widget<ThemeSelector>(find.byType(ThemeSelector));
      expect(selector.compact, width < 1050);
      if (width < 1050) {
        expect(find.text('Acesso móvel'), findsNothing);
        expect(find.text('Configurações'), findsNothing);
        expect(find.byTooltip('Acesso móvel'), findsOneWidget);
        await tester.tap(find.byTooltip('Configurações'));
      } else {
        expect(find.text('Acesso móvel'), findsOneWidget);
        await tester.tap(find.text('Configurações'));
      }
      expect(settingsPressed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Selecionar tema'));
      await tester.pumpAndSettle();
      expect(find.text('Escuro'), findsOneWidget);
      expect(find.text('Claro'), findsOneWidget);
    });
  }
}
