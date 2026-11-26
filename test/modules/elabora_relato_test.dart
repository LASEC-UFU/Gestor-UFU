import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/processos_parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/elabora_relato_module.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/elabora_relato_page.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/elabora_relato_commands.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

void main() {
  group('SeiArvoreTexto', () {
    test('divide nome da árvore em tipo/número e código', () {
      expect(SeiArvoreTexto.dividirNome('Ofício 12 (1234567)'), (
        'Ofício 12',
        '1234567',
      ));
      expect(SeiArvoreTexto.dividirNome('Anexo'), ('Anexo', ''));
    });

    test('data: assinatura, por extenso e numérica', () {
      expect(
        SeiArvoreTexto.data(
          'Texto 01/01/2020\nDocumento assinado eletronicamente por Fulano, '
          'Professor, em 03/03/2025, às 10:00',
        ),
        '03/03/2025',
      );
      expect(
        SeiArvoreTexto.data('Uberlândia, 5 de março de 2024.'),
        '05/03/2024',
      );
      expect(SeiArvoreTexto.data('Prazo 10/02/2023'), '10/02/2023');
      expect(SeiArvoreTexto.data(''), '');
    });

    test('resumo: assunto ou primeiro parágrafo de conteúdo', () {
      expect(
        SeiArvoreTexto.resumo(
          'UNIVERSIDADE FEDERAL\nAssunto: Pedido de progressão',
        ),
        'Pedido de progressão',
      );
      expect(
        SeiArvoreTexto.resumo(
          'UNIVERSIDADE FEDERAL DE UBERLÂNDIA\nSenhor Coordenador,\n'
          'Encaminho o relatório de atividades do período para apreciação.',
        ),
        'Encaminho o relatório de atividades do período para apreciação.',
      );
    });

    test('relatório no formato para parecer', () {
      final text = SeiArvoreTexto.relatorio([
        SeiDocumento.fromTree(
          1,
          'Ofício 12 (1234567)',
          texto:
              'Assunto: Pedido\nassinado eletronicamente por X, em 03/03/2025',
        ),
        SeiDocumento.fromTree(2, 'Anexo'),
      ]);
      expect(text, '1. Ofício 12 (1234567), de 03/03/2025 – Pedido\n2. Anexo');
    });
  });

  group('comandos', () {
    late Map<String, ModuleCommand> commands;
    late SeiArvoreService service;
    late ProcessosParecerService processos;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = SeiArvoreService();
      final parecer = ParecerService(arvore: service);
      processos = ProcessosParecerService(parecer: parecer);
      commands = {
        for (final c in elaboraRelatoCommands(service, parecer, processos))
          c.id: c,
      };
    });

    Future<CommandResult> run(String id, Map<String, dynamic> input) =>
        commands[id]!.run(input, CommandOrigin.test);

    Matcher code(String c) =>
        throwsA(isA<CommandException>().having((e) => e.code, 'code', c));

    test('extrair sem Edge e relatório sem extração têm código', () {
      expect(() => run('relato.extrairArvore', {}), code('sei_fechado'));
      expect(() => run('relato.relatorioArvore', {}), code('sem_extracao'));
      expect(
        () => run('relato.abrirSei', {'url': 'ftp://x'}),
        code('endereco_invalido'),
      );
    });

    test('relatório salva .txt', () async {
      // Sem processo aberto, o comando cria e abre um.
      await processos.garantirAtivo();
      service.definirDocumentos([
        SeiDocumento.fromTree(1, 'Despacho (7654321)'),
      ]);
      final dir = await Directory.systemTemp.createTemp('sei_cmd');
      addTearDown(() => dir.delete(recursive: true));
      final result = await run('relato.relatorioArvore', {
        'path': '${dir.path}/r.txt',
      });
      expect(
        File(result.data['path'] as String).readAsStringSync(),
        '1. Despacho (7654321)',
      );
    });
  });

  testWidgets('tela do módulo com a aba Extrair árvore de processo', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ModuleRegistry.instance
      ..clear()
      ..register(ElaboraRelatoModule());
    addTearDown(ModuleRegistry.instance.clear);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeController(isLight: true),
        child: MaterialApp(
          home: ElaboraRelatoPage(
            processos: ProcessosParecerService(
              parecer: ParecerService(arvore: SeiArvoreService()),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Primeiro a lista de processos.
    expect(find.text('Nenhum processo cadastrado'), findsOneWidget);
    await tester.tap(find.text('Novo processo').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'Estágio Mecânica');
    await tester.tap(find.text('Salvar'));
    // O editor (WebView2) não existe em testes: só alguns quadros.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Estágio Mecânica'), findsOneWidget);
    expect(find.text('Inserir no SEI'), findsOneWidget);
    expect(find.byType(Tab), findsNWidgets(4));
    expect(find.text('II. FUNDAMENTAÇÃO E ANÁLISE'), findsOneWidget);
    expect(find.text('III. CONCLUSÃO'), findsOneWidget);
    expect(find.text('1 · Extrair árvore'), findsOneWidget);
    expect(find.text('Extrair árvore'), findsOneWidget);

    // Aba dos documentos do processo (leitura e marcação).
    await tester.tap(find.text('Documentos do processo'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Anexar documento'), findsWidgets);
    expect(find.text('Documentos do processo'), findsWidgets);
  });
}
