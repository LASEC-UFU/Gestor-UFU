import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/audita_bancas/application/audita_bancas_commands.dart';
import 'package:gestor_ufu/modules/audita_bancas/application/audita_service.dart';
import 'package:gestor_ufu/modules/audita_bancas/application/audita_pdf_exporter.dart';
import 'package:gestor_ufu/modules/audita_bancas/domain/auditoria.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/services/poppler.dart';

class _IaFalsa implements AiTextService {
  _IaFalsa(this.respostas);

  final List<String> respostas;
  final prompts = <String>[];

  @override
  Future<String> descricao() async => 'teste';

  @override
  Future<String> gerar({
    required String sistema,
    required String prompt,
  }) async {
    prompts.add(prompt);
    return respostas.isEmpty ? '[]' : respostas.removeAt(0);
  }
}

const _paginas = [
  'Introdução\nEste trabalho analisa a evasão nos cursos de engenha-\nria da UFU.',
  'Metodologia\nForam entrevistados 12 alunos em 2025.',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('serviço', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('audita_bancas_');
    });
    tearDown(() => dir.delete(recursive: true));

    Future<String> pdf(String nome) async {
      final d = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('Texto do trabalho.')));
      final f = File(p.join(dir.path, nome));
      await f.writeAsBytes(await d.save());
      return f.path;
    }

    test('blocos por página e divisão de páginas longas', () {
      final b = AuditaService.blocos(_paginas);
      expect(b, hasLength(1));
      expect(b.single.map((x) => x.pagina), [1, 2]);
      final longa = AuditaService.blocos([
        'x' * (AuditaService.tamanhoBloco + 100),
      ]);
      expect(longa, hasLength(2));
      expect(longa.every((bl) => bl.single.pagina == 1), isTrue);
    });

    test('ancora o trecho na página, tolerando hífen e acentos', () {
      final o = AuditaService.observacaoDeItem({
        'trecho': 'evasão nos cursos de engenharia',
        'problema': 'Falta dizer o período estudado.',
        'importancia': 'Sem o período, o leitor não compara os dados.',
        'melhoria': 'Informe os anos analisados.',
        'categoria': 'Metodológica',
      }, _paginas);
      expect(o.ancorada, isTrue);
      expect(o.pagina, 1);
      expect(_paginas[0].substring(o.inicio, o.fim), contains('engenha-\nria'));
      final solta = AuditaService.observacaoDeItem({
        'trecho': 'frase que não existe',
        'problema': 'x',
      }, _paginas);
      expect(solta.ancorada, isFalse);
    });

    test('análise com IA cria observações, sem duplicar ao repetir', () async {
      final resposta = jsonEncode([
        {
          'trecho': 'Foram entrevistados 12 alunos',
          'categoria': 'Metodológica',
          'problema': 'A amostra é pequena para generalizar.',
          'importancia': 'Conclusões gerais exigem amostra maior.',
          'melhoria': 'Delimite as conclusões ao grupo estudado.',
        },
        {'trecho': 'inexistente', 'problema': 'Sem âncora.'},
      ]);
      final ia = _IaFalsa(['```json\n$resposta\n```', resposta]);
      final s = AuditaService(ia: ia, pasta: () async => dir.path);
      final doc = await s.abrirPdf(await pdf('tcc.pdf'));
      final r = await s.analisar(doc.id, _paginas, criterios: 'ABNT NBR 14724');
      expect((r.criadas, r.naoAncoradas), (2, 1));
      expect(ia.prompts.single, contains('ABNT NBR 14724'));
      expect(ia.prompts.single, contains('[p. 2] Metodologia'));
      final obs = s.documento(doc.id)!.observacoes;
      expect(obs.first.pagina, 2); // ancoradas primeiro
      expect(obs.last.ancorada, isFalse);

      final r2 = await s.analisar(doc.id, _paginas);
      expect(r2.criadas, 0); // nada duplica, nem a sem âncora
      expect(
        s.documento(doc.id)!.observacoes.where((o) => o.pagina == 2),
        hasLength(1),
      );
    });

    test('revisão e observação manual ficam salvas', () async {
      final s = AuditaService(pasta: () async => dir.path);
      final caminho = await pdf('tese.pdf');
      final doc = await s.abrirPdf(caminho);
      final o = AuditaService.novaObservacao(
        pagina: 1,
        textoPagina: _paginas[0],
        inicio: 0,
        fim: 10,
        problema: 'Título genérico.',
      );
      await s.salvarObservacao(doc.id, o);
      await s.definirRevisao(doc.id, o.id, Revisao.aceita);

      final outro = AuditaService(pasta: () async => dir.path);
      await outro.carregar();
      final salvo = outro.documento(doc.id)!.observacoes.single;
      expect(salvo.revisao, Revisao.aceita);
      expect(salvo.manual, isTrue);
      expect(salvo.trecho, 'Introdução');
      // O mesmo arquivo reabre o mesmo documento.
      expect((await outro.abrirPdf(caminho)).id, doc.id);
      expect(
        AuditaService.relatorio(outro.documento(doc.id)!),
        contains('ACEITA • página 1'),
      );
    });
  });

  test('imagens das páginas com zeros à esquerda (10+ páginas)', () async {
    final dir = await Directory.systemTemp.createTemp('audita_img_');
    try {
      for (final n in ['page-01.jpg', 'page-02.jpg', 'page-10.jpg']) {
        File(p.join(dir.path, n)).writeAsStringSync('x');
      }
      final m = await AuditaPdfExporter.imagensDasPaginas(dir.path);
      expect(m.keys.toSet(), {1, 2, 10});
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('exporta um PDF anotado separado e preserva o original', () async {
    if (await Poppler.pdftoppm() == null) {
      markTestSkipped('Poppler (pdftotext -bbox e pdftoppm) não instalado.');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('audita_export_test_');
    try {
      final source = File('${dir.path}/entrada.pdf'),
          target = '${dir.path}/revisado.pdf';
      final document = pw.Document();
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) =>
              pw.Center(child: pw.Text('Uma frase original para revisar.')),
        ),
      );
      final original = await document.save();
      await source.writeAsBytes(original);
      const comment = Observacao(
        id: 'mark-1',
        trecho: 'Uma frase original',
        problema: 'Reveja esta frase.',
        revisao: Revisao.aceita,
        pagina: 1,
        inicio: 0,
        fim: 18,
      );
      await AuditaPdfExporter.export(
        source: source.path,
        comments: [comment],
        target: target,
      );
      expect(await source.readAsBytes(), original);
      final annotated = await File(target).readAsBytes();
      expect(String.fromCharCodes(annotated.take(5)), '%PDF-');
      expect(annotated.length, greaterThan(original.length));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  group('comandos', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('audita_cmd_');
    });
    tearDown(() => dir.delete(recursive: true));

    test('abrir, analisar, revisar, editar, exportar e excluir', () async {
      if (await Poppler.pdftotext() == null) {
        markTestSkipped('pdftotext não instalado.');
        return;
      }
      final ia = _IaFalsa([
        jsonEncode([
          {
            'trecho': 'The sample has twelve students',
            'categoria': 'Metodológica',
            'problema': 'A amostra é pequena.',
            'importancia': 'Limita a generalização.',
            'melhoria': 'Delimite as conclusões.',
          },
        ]),
      ]);
      final service = AuditaService(ia: ia, pasta: () async => dir.path);
      final cmds = {for (final c in auditaBancasCommands(service)) c.id: c};
      Future<CommandResult> run(String id, Map<String, dynamic> input) =>
          cmds[id]!.run(input, CommandOrigin.test);
      expect(cmds['auditaBancas.analisar']!.approval, CommandApproval.required);
      expect(
        cmds['auditaBancas.excluirObservacao']!.approval,
        CommandApproval.required,
      );

      final pdf = pw.Document()
        ..addPage(
          pw.Page(build: (_) => pw.Text('The sample has twelve students.')),
        );
      final origem = File(p.join(dir.path, 'tcc.pdf'))
        ..writeAsBytesSync(await pdf.save());
      final aberto = await run('auditaBancas.abrirPdf', {
        'caminho': origem.path,
      });
      final docId = aberto.data['id'] as String;

      final analise = await run('auditaBancas.analisar', {
        'documento': docId,
        'criterios': 'Rigor metodológico',
      });
      expect(analise.data['criadas'], 1);
      final lista = await run('auditaBancas.observacoes', {'documento': docId});
      final obs = (lista.data['observacoes'] as List).single as Map;
      expect(obs['pagina'], 1);

      await run('auditaBancas.revisar', {
        'documento': docId,
        'observacao': obs['id'],
        'revisao': 'aceita',
      });
      await run('auditaBancas.editarObservacao', {
        'documento': docId,
        'observacao': obs['id'],
        'melhoria': 'Restrinja as conclusões aos 12 entrevistados.',
      });
      final o = service.documento(docId)!.observacoes.single;
      expect(o.revisao, Revisao.aceita);
      expect(o.melhoria, startsWith('Restrinja'));
      expect(o.problema, 'A amostra é pequena.');

      final rel = await run('auditaBancas.exportarRelatorio', {
        'documento': docId,
      });
      final txt = File(rel.data['caminho'] as String);
      expect(p.basename(txt.path), 'tcc_audita_bancas.txt');
      expect(txt.readAsStringSync(), contains('ACEITA • página 1'));

      // Âncoras relocalizadas no texto do visualizador (pdf.js).
      final semTrecho = await service.reancorar(docId, [
        'Header\nThe sample has twelve\nstudents.',
      ]);
      expect(semTrecho, 0);
      final r = service.documento(docId)!.observacoes.single;
      expect(r.inicio, 7);

      await run('auditaBancas.excluirObservacao', {
        'documento': docId,
        'observacao': obs['id'],
      });
      expect(service.documento(docId)!.observacoes, isEmpty);
      await expectLater(
        () => run('auditaBancas.exportarPdf', {'documento': docId}),
        throwsA(
          isA<CommandException>().having((e) => e.code, 'code', 'sem_aceitas'),
        ),
      );
      final listados = await run('auditaBancas.listar', {});
      expect((listados.data['documentos'] as List).single['id'], docId);
    });
  });
}
