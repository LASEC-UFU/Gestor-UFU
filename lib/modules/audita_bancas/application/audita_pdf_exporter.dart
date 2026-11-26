import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:gestor_ufu/modules/audita_bancas/domain/auditoria.dart';
import 'package:gestor_ufu/platform/services/poppler.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/ancora_texto.dart';

/// Gera um PDF anotado separado (o original nunca é sobrescrito): as
/// páginas são renderizadas pelo Poppler, os trechos das observações
/// aceitas recebem realce e um número, e as observações vão em páginas de
/// notas no fim.
class AuditaPdfExporter {
  const AuditaPdfExporter._();

  static Future<void> export({
    required String source,
    required List<Observacao> comments,
    required String target,
    void Function(String)? onProgress,
  }) async {
    if (comments.isEmpty) {
      throw StateError('Não há observações aceitas para exportar.');
    }
    if (comments.any((m) => m.pagina < 1)) {
      throw StateError(
        'Alguma observação aceita não tem página no documento. Revise os '
        'trechos no visualizador antes de exportar.',
      );
    }
    final pdftotext = await Poppler.pdftotextComCaixas();
    final pdftoppm = await Poppler.pdftoppm();
    if (pdftotext == null || pdftoppm == null) {
      throw StateError(
        'A exportação do PDF anotado precisa do Poppler (pdftotext e '
        'pdftoppm), que vem com o instalador do Gestor. Reinstale o Gestor.',
      );
    }
    final temp = await Directory.systemTemp.createTemp('gestor_audita_');
    try {
      onProgress?.call('Lendo texto e posições do PDF…');
      final bbox = await Process.run(
        pdftotext,
        ['-bbox', source, '-'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (bbox.exitCode != 0) {
        throw StateError('pdftotext não conseguiu ler o PDF. ${bbox.stderr}');
      }
      final parsed = html_parser.parse('${bbox.stdout}');
      final sourcePages = parsed.querySelectorAll('page');
      if (sourcePages.isEmpty) {
        throw StateError('Nenhuma página foi identificada no PDF.');
      }
      onProgress?.call('Renderizando páginas localmente…');
      final prefix = p.join(temp.path, 'page');
      final raster = await Process.run(pdftoppm, [
        '-jpeg',
        '-r',
        '120',
        '-jpegopt',
        'quality=82',
        '-forcenum',
        source,
        prefix,
      ], stderrEncoding: utf8);
      if (raster.exitCode != 0) {
        throw StateError(
          'pdftoppm não conseguiu renderizar as páginas. ${raster.stderr}',
        );
      }
      final imagens = await imagensDasPaginas(temp.path);
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
      final byPage = <int, List<Observacao>>{};
      for (final m in comments) {
        byPage.putIfAbsent(m.pagina, () => []).add(m);
      }
      final notes = <({int page, Observacao marker, int number})>[];
      var markerNumber = 0;
      for (var i = 0; i < sourcePages.length; i++) {
        onProgress?.call(
          'Montando PDF anotado: página ${i + 1}/${sourcePages.length}…',
        );
        final page = sourcePages[i];
        final width = double.tryParse(page.attributes['width'] ?? '') ?? 595;
        final height = double.tryParse(page.attributes['height'] ?? '') ?? 842;
        final imageFile = imagens[i + 1];
        if (imageFile == null) {
          throw StateError('Imagem da página ${i + 1} não foi gerada.');
        }
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
        for (final m in byPage[i + 1] ?? const <Observacao>[]) {
          final range = localizarTrecho(m.trecho, textBuffer.toString());
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
      if (notes.length != comments.length) {
        throw StateError(
          'Somente ${notes.length} de ${comments.length} trechos foram '
          'localizados. Nenhum PDF foi exportado para evitar omitir '
          'observações.',
        );
      }
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
                  'Audita Bancas • observações revisadas',
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
                          '${note.number}. Página ${note.page}'
                          '${note.marker.categoria.isEmpty ? '' : ' • ${note.marker.categoria}'}',
                          style: pw.TextStyle(font: bold, fontSize: 11),
                        ),
                        pw.Text(
                          'Trecho: “${note.marker.trecho}”',
                          style: pw.TextStyle(font: regular, fontSize: 10),
                        ),
                        pw.Text(
                          note.marker.texto,
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
        'A exportação do PDF requer o Poppler (pdftotext e pdftoppm): '
        '${e.message}',
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }

  /// Imagens geradas pelo pdftoppm, por número de página. O pdftoppm usa
  /// zeros à esquerda conforme o total de páginas ("page-01.jpg" com 10 ou
  /// mais páginas), então o número é lido do nome.
  static Future<Map<int, File>> imagensDasPaginas(String pasta) async {
    final out = <int, File>{};
    await for (final e in Directory(pasta).list()) {
      if (e is! File) continue;
      final m = RegExp(r'-(\d+)\.jpg$').firstMatch(p.basename(e.path));
      if (m != null) out[int.parse(m.group(1)!)] = e;
    }
    return out;
  }
}
