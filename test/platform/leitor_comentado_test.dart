import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado_controller.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/marca_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/superficie_texto.dart';

List<ComentarioDocumento> _lista({bool segundoAncorado = true}) => [
  const ComentarioDocumento(
    id: 'a',
    titulo: 'A data do ofício não confere com a da ata.',
    cor: Colors.amber,
    local: 'p. 1',
    trechoMarcado: 'ofício de 3 de março',
    secoes: [
      SecaoComentario('Por que merece atenção', 'A ata é de 5 de março.'),
      SecaoComentario('Como melhorar', 'Conferir e corrigir a data.'),
    ],
  ),
  ComentarioDocumento(
    id: 'b',
    titulo: 'Falta citar a Resolução de extensão.',
    cor: Colors.green,
    local: 'p. 2',
    ancorado: segundoAncorado,
    trechoMarcado: 'carga horária de extensão',
  ),
];

void main() {
  group('controlador', () {
    test('selecionar navega, e o anterior/próximo também', () async {
      final idas = <String>[];
      final c = LeitorComentadoController()
        ..navegar = (com, rolar) async {
          idas.add('${com.id}:$rolar');
          return true;
        }
        ..definirComentarios(_lista());
      await c.selecionar('a');
      expect(c.selecionado, 'a');
      expect(c.expandido('a'), isTrue);
      await c.proximo();
      expect(c.selecionado, 'b');
      await c.anterior();
      expect(idas, ['a:true', 'b:true', 'a:true']);
      expect(c.temAnterior, isFalse);
      expect(c.temProximo, isTrue);
      // Clique vindo do documento: só destaca.
      await c.selecionar('b', rolar: false);
      expect(idas.last, 'b:false');
    });

    test(
      'anterior só fica disponível depois de selecionar um comentário',
      () async {
        final c = LeitorComentadoController()..definirComentarios(_lista());
        expect(c.selecionado, isNull);
        expect(c.temAnterior, isFalse);
        expect(c.temProximo, isTrue);

        await c.anterior();
        expect(c.selecionado, isNull);

        await c.selecionar('b');
        expect(c.temAnterior, isTrue);
        await c.anterior();
        expect(c.selecionado, 'a');
        expect(c.temAnterior, isFalse);
      },
    );

    test(
      'expansão única e seleção pelo documento herda expandido/recolhido',
      () async {
        final c = LeitorComentadoController()
          ..navegar = ((_, _) async => true)
          ..definirComentarios(_lista());

        await c.selecionar('a');
        expect(
          (c.selecionado, c.expandido('a'), c.expandido('b')),
          ('a', true, false),
        );

        await c.selecionar('b', rolar: false);
        expect(
          (c.selecionado, c.expandido('a'), c.expandido('b')),
          ('b', false, true),
        );

        await c.alternarExpansao('b');
        expect(
          (c.selecionado, c.expandido('a'), c.expandido('b')),
          ('b', false, false),
        );

        await c.selecionar('a', rolar: false);
        expect(
          (c.selecionado, c.expandido('a'), c.expandido('b')),
          ('a', false, false),
        );

        await c.alternarExpansao('b');
        expect(
          (c.selecionado, c.expandido('a'), c.expandido('b')),
          ('b', false, true),
        );
      },
    );

    test('clicar de novo recolhe e desfaz a seleção', () async {
      var limpou = 0;
      final c = LeitorComentadoController()
        ..navegar = ((_, _) async => true)
        ..aoLimpar = () {
          limpou++;
        }
        ..definirComentarios(_lista());
      await c.alternar('a');
      expect((c.selecionado, c.expandido('a')), ('a', true));
      await c.alternar('a');
      expect((c.selecionado, c.expandido('a')), (null, false));
      expect(limpou, 1);
      c.alternarExpansao('b');
      expect((c.selecionado, c.expandido('b')), ('b', true));
    });

    test('sem âncora ou trecho não achado: avisa em vez de fingir', () async {
      var navegou = 0;
      final c = LeitorComentadoController()
        ..navegar = (com, _) async {
          navegou++;
          return false;
        }
        ..definirComentarios(_lista(segundoAncorado: false));
      await c.selecionar('b');
      expect(navegou, 0);
      expect(c.aviso('b'), contains('não tem um trecho'));
      await c.selecionar('a');
      expect(navegou, 1);
      expect(c.aviso('a'), contains('Não foi possível localizar'));
    });

    test('busca no comentário e no trecho marcado, sem acentos', () {
      final c = LeitorComentadoController()..definirComentarios(_lista());
      c.definirBusca('OFICIO');
      expect(c.visiveis.map((x) => x.id), ['a']);
      c.definirBusca('carga horaria');
      expect(c.visiveis.map((x) => x.id), ['b']);
      c.definirBusca('corrigir a data');
      expect(c.visiveis.map((x) => x.id), ['a']);
      c.definirBusca('');
      expect(c.visiveis, hasLength(2));
    });

    test('comentário removido deixa de estar selecionado', () async {
      var limpou = 0;
      final c = LeitorComentadoController()
        ..navegar = ((_, _) async => true)
        ..aoLimpar = () {
          limpou++;
        }
        ..definirComentarios(_lista());
      await c.selecionar('b');
      c.definirComentarios(_lista().take(1).toList());
      expect(c.selecionado, isNull);
      expect(limpou, 1);
    });
  });

  group('tela', () {
    Future<LeitorComentadoController> montar(
      WidgetTester tester, {
      required Size tamanho,
      List<String>? idas,
    }) async {
      tester.view.physicalSize = tamanho;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = LeitorComentadoController()
        ..navegar = (com, rolar) async {
          idas?.add(com.id);
          return true;
        };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LeitorComentado(
              controller: c,
              comentarios: _lista(),
              documento: const ColoredBox(
                color: Colors.white,
                child: Center(child: Text('DOCUMENTO')),
              ),
            ),
          ),
        ),
      );
      return c;
    }

    testWidgets('desktop: expande no cartão, fecha/reabre e redimensiona', (
      tester,
    ) async {
      final idas = <String>[];
      final c = await montar(
        tester,
        tamanho: const Size(1400, 900),
        idas: idas,
      );
      expect(find.text('Comentários (2)'), findsOneWidget);
      expect(find.text('Como melhorar'), findsNothing);

      await tester.tap(find.text('A data do ofício não confere com a da ata.'));
      await tester.pumpAndSettle();
      expect(find.text('Como melhorar'), findsOneWidget);
      expect(find.text('Conferir e corrigir a data.'), findsOneWidget);
      expect(idas, ['a']);
      expect(find.text('Comentário 1 de 2'), findsOneWidget);
      // Nenhuma tela nova foi aberta.
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('A data do ofício não confere com a da ata.'));
      await tester.pumpAndSettle();
      expect(find.text('Como melhorar'), findsNothing);
      expect(c.selecionado, isNull);

      // Próximo pelo botão e pela seta para baixo no painel.
      await tester.tap(find.byTooltip('Próximo comentário (↓)'));
      await tester.pumpAndSettle();
      expect(c.selecionado, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'b');
      expect(idas, ['a', 'a', 'b']);
      expect(
        find.text('Sem trecho correspondente no documento.'),
        findsNothing,
      );

      // Redimensionar arrastando a alça (limites respeitados).
      final painel = find.byType(LeitorComentado);
      final larguraAntes = tester.getSize(find.text('Comentários (2)')).width;
      expect(larguraAntes, greaterThan(0));
      await tester.drag(
        find.bySemanticsLabel('Redimensionar o painel de comentários'),
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      // O arrasto desconta a folga do gesto (~20 px).
      expect(c.largura, inInclusiveRange(530, 560));
      await tester.drag(
        find.bySemanticsLabel('Redimensionar o painel de comentários'),
        const Offset(2000, 0),
      );
      await tester.pumpAndSettle();
      expect(c.largura, LeitorComentado.larguraMinima);
      expect(painel, findsOneWidget);

      // Fechar e reabrir.
      await tester.tap(find.byTooltip('Fechar o painel de comentários'));
      await tester.pumpAndSettle();
      expect(find.text('Comentários (2)'), findsOneWidget); // botão de abrir
      expect(find.byTooltip('Próximo comentário (↓)'), findsNothing);
      await tester.tap(find.text('Comentários (2)'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Próximo comentário (↓)'), findsOneWidget);
    });

    testWidgets('busca mostra a contagem e pode ser limpa', (tester) async {
      await montar(tester, tamanho: const Size(1400, 900));
      await tester.enterText(find.byType(TextField), 'resolução');
      await tester.pumpAndSettle();
      expect(find.text('1 de 2 comentário(s) encontrado(s)'), findsOneWidget);
      expect(
        find.text('A data do ofício não confere com a da ata.'),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), 'xilofone');
      await tester.pumpAndSettle();
      expect(find.text('Nenhum comentário encontrado'), findsOneWidget);
      await tester.tap(find.byTooltip('Limpar a busca'));
      await tester.pumpAndSettle();
      expect(find.text('2 comentário(s)'), findsOneWidget);
    });

    testWidgets('tela estreita: folha inferior e comentário ativo compacto', (
      tester,
    ) async {
      final idas = <String>[];
      final c = await montar(tester, tamanho: const Size(420, 800), idas: idas);
      // O documento ocupa a tela; a folha começa aberta e pode fechar.
      await tester.tap(find.byTooltip('Fechar comentários'));
      await tester.pumpAndSettle();
      expect(find.text('DOCUMENTO'), findsOneWidget);
      await tester.tap(find.text('Comentários (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Falta citar a Resolução de extensão.'));
      await tester.pumpAndSettle();
      expect(idas, ['b']);
      // Folha compacta: mostra qual comentário está ativo.
      expect(find.textContaining('Comentário 2 de 2'), findsOneWidget);
      expect(find.text('Ler comentário'), findsOneWidget);
      await tester.tap(find.text('Anterior'));
      await tester.pumpAndSettle();
      expect(c.selecionado, 'a');
      expect(idas, ['b', 'a']);
      // Botões com área de toque adequada.
      final botao = find.ancestor(
        of: find.text('Ler comentário'),
        matching: find.byType(FilledButton),
      );
      expect(tester.getSize(botao).height, greaterThanOrEqualTo(44));
    });
  });

  testWidgets('superfície de texto destaca o selecionado e navega', (
    tester,
  ) async {
    final ctrl = SuperficieTextoController();
    final tocadas = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SuperficieTexto(
            paragrafos: [
              for (var i = 0; i < 80; i++)
                (
                  texto: 'Parágrafo número $i do documento.',
                  pagina: 1 + i ~/ 20,
                  titulo: false,
                ),
            ],
            marcas: const [
              MarcaDocumento(
                id: 'm',
                cor: Colors.amber,
                paragrafo: 70,
                inicio: 0,
                fim: 9,
              ),
            ],
            selecionada: 'm',
            controller: ctrl,
            aoSelecionar: (_) {},
            aoPedirAcao: (_, _) {},
            aoTocarMarca: tocadas.add,
          ),
        ),
      ),
    );
    expect(find.textContaining('Parágrafo número 70'), findsNothing);
    // A rolagem é animada: avança os quadros até a navegação terminar.
    var ok = false;
    var fim = false;
    ctrl
        .irPara(
          const MarcaDocumento(
            id: 'm',
            cor: Colors.amber,
            paragrafo: 70,
            fim: 9,
          ),
        )
        .then((v) {
          ok = v;
          fim = true;
        });
    for (var i = 0; i < 40 && !fim; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(ok, isTrue);
    expect(find.textContaining('Parágrafo número 70'), findsOneWidget);
    expect(
      await ctrl.irPara(const MarcaDocumento(id: 'x', cor: Colors.amber)),
      isFalse,
    );
  });

  testWidgets('clicar num trecho marcado informa qual comentário foi tocado', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = LeitorComentadoController()..navegar = ((_, _) async => true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LeitorComentado(
            controller: c,
            comentarios: const [
              ComentarioDocumento(
                id: 'comentario-a',
                titulo: 'Comentário de teste',
                trechoMarcado: 'Trecho com comentário',
                local: 'p. 1',
                cor: Colors.amber,
              ),
            ],
            documento: SuperficieTexto(
              paragrafos: const [
                (texto: 'Trecho com comentário', pagina: 1, titulo: false),
              ],
              marcas: const [
                MarcaDocumento(
                  id: 'comentario-a',
                  cor: Colors.amber,
                  paragrafo: 0,
                  inicio: 0,
                  fim: 21,
                ),
              ],
              controller: SuperficieTextoController(),
              selecionada: c.selecionado,
              aoSelecionar: (_) {},
              aoPedirAcao: (_, _) {},
              aoTocarMarca: (id) => c.selecionar(id, rolar: false),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(55, 64));
    await tester.pumpAndSettle();
    expect(c.selecionado, 'comentario-a');
    expect(find.byIcon(Icons.my_location), findsOneWidget);
  });

  group('navegação numa lista longa', () {
    late LeitorComentadoController c;
    late List<String> idas;
    late List<ComentarioDocumento> lista;

    Future<void> montar(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      idas = [];
      c = LeitorComentadoController()
        ..navegar = (com, rolar) async {
          idas.add(com.id);
          return true;
        };
      lista = [
        for (var i = 0; i < 30; i++)
          ComentarioDocumento(
            id: 'c$i',
            titulo:
                'Comentário número $i, com texto suficiente para '
                'ocupar duas linhas no cartão do painel lateral.',
            cor: Colors.amber,
            secoes: [SecaoComentario('Por que', 'Explicação. ' * 12)],
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LeitorComentado(
              controller: c,
              comentarios: lista,
              documento: const SizedBox.expand(),
            ),
          ),
        ),
      );
    }

    bool visivel(WidgetTester tester, String id) {
      final f = find.text(lista.firstWhere((x) => x.id == id).titulo);
      if (f.evaluate().isEmpty) return false;
      final r = tester.getRect(f);
      return r.top >= 0 && r.bottom <= 700;
    }

    testWidgets('anterior a partir do último mostra o cartão e o trecho', (
      tester,
    ) async {
      await montar(tester);
      await c.selecionar('c29');
      await tester.pumpAndSettle();
      expect(visivel(tester, 'c29'), isTrue);
      for (final esperado in ['c28', 'c27', 'c26']) {
        await tester.tap(find.byTooltip('Comentário anterior (↑)'));
        await tester.pumpAndSettle();
        expect(c.selecionado, esperado);
        expect(visivel(tester, esperado), isTrue, reason: esperado);
      }
      expect(idas, ['c29', 'c28', 'c27', 'c26']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('em paisagem, ←/→ navegam com foco no painel de comentários', (
      tester,
    ) async {
      await montar(tester);
      // Sem seleção, as setas não navegam.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.selecionado, isNull);

      await tester.tap(find.text(lista[2].titulo));
      await tester.pumpAndSettle();
      expect(c.selecionado, 'c2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'c3');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'c4');
      expect(idas, ['c2', 'c3', 'c4']);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'c4');

      // Na busca, as setas são do campo de texto.
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'número');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'c4');

    });

    testWidgets(
      'seleção vinda do documento tira o foco das abas antes de navegar',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final focoAbas = FocusNode(debugLabel: 'Abas do parecer');
        addTearDown(focoAbas.dispose);
        var trocasDeAba = 0;
        final c = LeitorComentadoController()..navegar = ((_, _) async => true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Focus(
                    focusNode: focoAbas,
                    onKeyEvent: (_, e) {
                      if (e is! KeyUpEvent &&
                          e.logicalKey == LogicalKeyboardKey.arrowRight) {
                        trocasDeAba++;
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: const SizedBox(height: 44),
                  ),
                  Expanded(
                    child: LeitorComentado(
                      controller: c,
                      comentarios: _lista(),
                      documento: const ColoredBox(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        focoAbas.requestFocus();
        await tester.pump();
        expect(focoAbas.hasFocus, isTrue);

        // Equivale ao clique numa marca do texto/PDF.
        await c.selecionar('a', rolar: false);
        await tester.pumpAndSettle();
        expect(focoAbas.hasFocus, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(c.selecionado, 'b');
        expect(trocasDeAba, 0);
      },
    );

    testWidgets('em retrato, ↑/↓ navegam com foco no painel de comentários', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = LeitorComentadoController()..navegar = ((_, _) async => true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LeitorComentado(
              controller: c,
              comentarios: _lista(),
              documento: const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      );

      await tester.tap(find.text('A data do ofício não confere com a da ata.'));
      await tester.pumpAndSettle();
      expect(c.selecionado, 'a');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'b');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'a');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(c.selecionado, 'a');
    });
  });
}
