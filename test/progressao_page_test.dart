import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/data/services/progressao_store.dart';
import 'package:gestor_ufu/presentation/pages/progressao_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'progressao_test.dart' show exemploModelo;

void main() {
  testWidgets('abre processo e percorre todas as abas sem erros', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      ProgressaoStore.key: jsonEncode([exemploModelo().toJson()]),
    });
    await tester.pumpWidget(const MaterialApp(home: ProgressaoPage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('Josué Silva de Morais'), findsWidgets);

    await tester.tap(find.textContaining('Associado II → Associado III'));
    await tester.pumpAndSettle();
    expect(find.text('1281 / 920 pontos'), findsOneWidget);

    for (final aba in [
      'Textos',
      'A1.1 Ensino',
      'A1.2 Orientação',
      'A1.3 Produção',
      'A1.6 Gestão',
      'Resumo',
      'Dados',
    ]) {
      final tab = find.textContaining(aba).first;
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('novo processo cancelado sem pasta não é criado', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FilePicker.platform = _FakeFilePicker(null);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: ProgressaoPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novo processo'));
    await tester.pumpAndSettle();
    expect(find.text('Nenhum processo cadastrado'), findsOneWidget);
    expect(find.textContaining('Processo não criado'), findsOneWidget);
  });

  testWidgets('cria novo processo e lança item', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picker = _FakeFilePicker(r'C:\Comprovantes\Progressao');
    FilePicker.platform = picker;
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: ProgressaoPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novo processo'));
    await tester.pumpAndSettle();
    expect(picker.pedidosDePasta, 1);
    final abaSei = find.textContaining('Comprovantes / SEI');
    await tester.ensureVisible(abaSei);
    await tester.pumpAndSettle();
    await tester.tap(abaSei);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(r'C:\Comprovantes\Progressao', findRichText: true),
      findsWidgets,
    );
    expect(find.text('Selecionar arquivo…'), findsNothing);
    final abaEnsino = find.textContaining('A1.1 Ensino');
    await tester.ensureVisible(abaEnsino);
    await tester.pumpAndSettle();
    await tester.tap(abaEnsino);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar item'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Aula teórica ou prática').first);
    await tester.pumpAndSettle();
    expect(find.text('Selecionar arquivo…'), findsOneWidget);
    final qtd = find.byType(TextField).at(2);
    await tester.enterText(qtd, '72');
    await tester.pumpAndSettle();
    expect(find.text('72 / 880 pontos'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.pasta);

  final String? pasta;
  int pedidosDePasta = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    pedidosDePasta++;
    return pasta;
  }
}
