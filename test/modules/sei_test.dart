import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/sei/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/sei/application/sei_commands.dart';
import 'package:gestor_ufu/modules/sei/domain/sei_documento.dart';
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

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service = SeiArvoreService();
      commands = {for (final c in seiCommands(service)) c.id: c};
    });

    Future<CommandResult> run(String id, Map<String, dynamic> input) =>
        commands[id]!.run(input, CommandOrigin.test);

    Matcher code(String c) =>
        throwsA(isA<CommandException>().having((e) => e.code, 'code', c));

    test('extrair sem Edge e relatório sem extração têm código', () {
      expect(() => run('sei.extrairArvore', {}), code('sei_fechado'));
      expect(() => run('sei.relatorio', {}), code('sem_extracao'));
      expect(
        () => run('sei.abrir', {'url': 'ftp://x'}),
        code('endereco_invalido'),
      );
    });

    test('relatório salva .txt', () async {
      service.definirDocumentos([
        SeiDocumento.fromTree(1, 'Despacho (7654321)'),
      ]);
      final dir = await Directory.systemTemp.createTemp('sei_cmd');
      addTearDown(() => dir.delete(recursive: true));
      final result = await run('sei.relatorio', {'path': '${dir.path}/r.txt'});
      expect(
        File(result.data['path'] as String).readAsStringSync(),
        '1. Despacho (7654321)',
      );
    });
  });
}
