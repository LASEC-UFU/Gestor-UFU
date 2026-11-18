import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:gestor_ufu/modules/audita_banco/audita_pdf_exporter.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('exports a separate annotated PDF and preserves the original', () async {
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
      final comment = MarcacaoAnexo(
        id: 'mark-1',
        paragrafo: 0,
        inicio: 0,
        fim: 21,
        texto: 'Uma frase original',
        comentario: 'Reveja esta frase.',
        pergunta: 'audita_banco',
        revisao: 'aceito',
        pdfPagina: 1,
        pdfInicio: 0,
        pdfFim: 21,
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
}
