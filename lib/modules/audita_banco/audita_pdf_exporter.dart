import 'dart:convert';
import 'dart:io';
import 'package:html/parser.dart' as html_parser;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/services.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';

/// Produces a separate, locally rendered annotated PDF. The original PDF is
/// never overwritten. Highlights are placed over matching source word boxes;
/// a review appendix retains editable text in the app's annotation store.
class AuditaPdfExporter {
  static Future<void> export({
    required String source,
    required List<MarcacaoAnexo> comments,
    required String target,
    void Function(String)? onProgress,
  }) async {
    if (comments.isEmpty)
      throw StateError('Não há comentários aceitos para exportar.');
    if (comments.any((m) => m.pdfPagina < 1))
      throw StateError(
        'Algum comentário aceito não tem âncora de página. Revise os trechos no visualizador antes de exportar.',
      );
    final temp = await Directory.systemTemp.createTemp('gestor_audita_');
    try {
      onProgress?.call('Lendo texto e posições do PDF…');
      final bbox = await Process.run(
        'pdftotext',
        ['-bbox', source, '-'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (bbox.exitCode != 0)
        throw StateError('pdftotext não conseguiu ler o PDF. ${bbox.stderr}');
      final parsed = html_parser.parse('${bbox.stdout}');
      final sourcePages = parsed.querySelectorAll('page');
      if (sourcePages.isEmpty)
        throw StateError('Nenhuma página foi identificada no PDF.');
      onProgress?.call('Renderizando páginas localmente…');
      final prefix = '${temp.path}${Platform.pathSeparator}page';
      final raster = await Process.run('pdftoppm', [
        '-jpeg',
        '-r',
        '120',
        '-jpegopt',
        'quality=82',
        '-forcenum',
        source,
        prefix,
      ], stderrEncoding: utf8);
      if (raster.exitCode != 0)
        throw StateError(
          'pdftoppm não conseguiu renderizar as páginas. ${raster.stderr}',
        );
      final output = pw.Document();
      final regular = pw.Font.ttf(
        await rootBundle.load(
          'assets/pdf_viewer/standard_fonts/LiberationSans-Regular.ttf',
        ),
      );
      final bold = pw.Font.ttf(
        await rootBundle.load(
          'assets/pdf_viewer/standard_fonts/LiberationSans-Bold.ttf',
        ),
      );
      final byPage = <int, List<MarcacaoAnexo>>{};
      for (final m in comments) {
        if (m.pdfPagina > 0) byPage.putIfAbsent(m.pdfPagina, () => []).add(m);
      }
      final notes = <({int page, MarcacaoAnexo marker, int number})>[];
      var markerNumber = 0;
      for (var i = 0; i < sourcePages.length; i++) {
        onProgress?.call(
          'Montando PDF anotado: página ${i + 1}/${sourcePages.length}…',
        );
        final page = sourcePages[i];
        final width = double.tryParse(page.attributes['width'] ?? '') ?? 595;
        final height = double.tryParse(page.attributes['height'] ?? '') ?? 842;
        final imageFile = File('$prefix-${i + 1}.jpg');
        if (!await imageFile.exists())
          throw StateError('Imagem da página ${i + 1} não foi gerada.');
        final image = pw.MemoryImage(await imageFile.readAsBytes());
        final words = page.querySelectorAll('word');
        final textBuffer = StringBuffer();
        final wordOffsets = <({int start, int end, Map<String, String> box})>[];
        for (final word in words) {
          if (textBuffer.isNotEmpty) textBuffer.write(' ');
          final start = textBuffer.length;
          textBuffer.write(word.text);
          wordOffsets.add((
            start: start,
            end: textBuffer.length,
            box: Map<String, String>.from(word.attributes),
          ));
        }
        final highlights = <pw.Widget>[];
        for (final m in byPage[i + 1] ?? const <MarcacaoAnexo>[]) {
          final range = localizarTrecho(m.texto, textBuffer.toString());
          if (range == null) continue;
          final matched = wordOffsets
              .where((w) => w.end > range.inicio && w.start < range.fim)
              .toList();
          if (matched.isEmpty) continue;
          markerNumber++;
          notes.add((page: i + 1, marker: m, number: markerNumber));
          for (final w in matched) {
            final x = double.tryParse(w.box['xmin'] ?? '') ?? 0,
                y = double.tryParse(w.box['ymin'] ?? '') ?? 0;
            final right = double.tryParse(w.box['xmax'] ?? '') ?? x + 12,
                bottom = double.tryParse(w.box['ymax'] ?? '') ?? y + 12;
            highlights.add(
              pw.Positioned(
                left: x,
                top: y,
                child: pw.Container(
                  width: (right - x).clamp(1, width).toDouble(),
                  height: (bottom - y).clamp(1, height).toDouble(),
                  color: PdfColor(1, 0.83, 0.12, 0.32),
                ),
              ),
            );
          }
          final first = matched.first.box;
          final x = double.tryParse(first['xmin'] ?? '') ?? 4,
              y = double.tryParse(first['ymin'] ?? '') ?? 4;
          highlights.add(
            pw.Positioned(
              left: x - 10,
              top: y - 10,
              child: pw.Container(
                width: 18,
                height: 18,
                alignment: pw.Alignment.center,
                decoration: const pw.BoxDecoration(
                  color: PdfColors.red,
                  shape: pw.BoxShape.circle,
                ),
                child: pw.Text(
                  '$markerNumber',
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 10,
                    color: PdfColors.white,
                  ),
                ),
              ),
            ),
          );
        }
        output.addPage(
          pw.Page(
            pageFormat: PdfPageFormat(width, height, marginAll: 0),
            build: (_) => pw.Stack(
              children: [
                pw.Positioned.fill(child: pw.Image(image, fit: pw.BoxFit.fill)),
                ...highlights,
              ],
            ),
          ),
        );
      }
      if (notes.length != comments.length)
        throw StateError(
          'Somente ${notes.length} de ${comments.length} trechos foram localizados. Nenhum PDF foi exportado para evitar omitir comentários.',
        );
      for (var offset = 0; offset < notes.length; offset += 7) {
        final slice = notes.skip(offset).take(7).toList();
        output.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(38),
            build: (_) => pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'Audita Banco • comentários revisados',
                  style: pw.TextStyle(font: bold, fontSize: 18),
                ),
                pw.SizedBox(height: 12),
                for (final note in slice)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 12),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          '${note.number}. Página ${note.page} • ${note.marker.revisao}',
                          style: pw.TextStyle(font: bold, fontSize: 11),
                        ),
                        pw.Text(
                          'Trecho: “${note.marker.texto}”',
                          style: pw.TextStyle(font: regular, fontSize: 10),
                        ),
                        pw.Text(
                          note.marker.comentario,
                          style: pw.TextStyle(font: regular, fontSize: 10),
                        ),
                        pw.Divider(),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      onProgress?.call('Salvando PDF anotado…');
      await File(target).writeAsBytes(await output.save());
    } on ProcessException catch (e) {
      throw StateError(
        'A exportação do PDF requer as ferramentas Poppler (pdftotext e pdftoppm) no PATH: ${e.message}',
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }
}
