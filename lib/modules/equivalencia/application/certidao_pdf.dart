import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';

/// Certidão de estudos (PDF) de uma análise deferida.
///
/// Usa as fontes Arial do Windows quando existem (acentos e visual iguais ao
/// documento oficial); sem elas, cai para a fonte padrão do PDF.
class CertidaoPdf {
  const CertidaoPdf({
    this.regularFontPath = 'C:/Windows/Fonts/arial.ttf',
    this.boldFontPath = 'C:/Windows/Fonts/arialbd.ttf',
  });

  final String regularFontPath;
  final String boldFontPath;

  static Future<pw.Font?> _font(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return pw.Font.ttf(ByteData.sublistView(await file.readAsBytes()));
    } on Object {
      return null;
    }
  }

  /// Nome de arquivo sugerido para a certidão de [item].
  static String fileName(EquivalenceCase item) =>
      'certidao-estudos-${item.student.replaceAll(RegExp(r'[<>:"/\\|?*]'), '').trim().replaceAll(RegExp(r'\s+'), '-')}.pdf';

  Future<Uint8List> build(EquivalenceCase item, Curriculum? curriculum) async {
    final regular = await _font(regularFontPath) ?? pw.Font.helvetica();
    final bold = await _font(boldFontPath) ?? pw.Font.helveticaBold();
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    final blocks = item.blocks;
    final totalCurrent = blocks.fold<int>(
      0,
      (sum, block) => sum + block.currentHours,
    );
    final totalPrior = blocks.fold<int>(
      0,
      (sum, block) => sum + block.priorHours,
    );
    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.fromLTRB(34, 28, 34, 30),
        ),
        header: (_) => pw.Column(
          children: [
            pw.Text(
              'UNIVERSIDADE FEDERAL DE UBERLÂNDIA',
              style: pw.TextStyle(font: bold, fontSize: 12),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'CERTIDÃO DE ESTUDOS',
              style: pw.TextStyle(font: bold, fontSize: 17),
            ),
            pw.SizedBox(height: 10),
          ],
        ),
        build: (_) => [
          pw.Text(
            'Curso: ${curriculum?.course ?? '—'}',
            style: const pw.TextStyle(fontSize: 10),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            'Discente: ${item.student.isEmpty ? '—' : item.student}    Matrícula: ${item.studentId.isEmpty ? '—' : item.studentId}',
            style: const pw.TextStyle(fontSize: 10),
          ),
          pw.SizedBox(height: 12),
          for (var index = 0; index < blocks.length; index++) ...[
            _certificateBlock(blocks[index], index),
            pw.SizedBox(height: 9),
          ],
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey600, width: .5),
            columnWidths: const {
              0: pw.FlexColumnWidth(4),
              1: pw.FlexColumnWidth(.7),
              2: pw.FlexColumnWidth(4),
              3: pw.FlexColumnWidth(.7),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  _pdfCell('Total geral dispensado', bold: true),
                  _pdfCell('$totalCurrent h', bold: true, centered: true),
                  _pdfCell('Total geral cursado na origem', bold: true),
                  _pdfCell('$totalPrior h', bold: true, centered: true),
                ],
              ),
            ],
          ),
          if (item.notes.trim().isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              'Observações: ${item.notes.trim()}',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ],
          pw.SizedBox(height: 22),
          pw.Center(
            child: pw.Text(
              'Documento gerado para conferência',
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  pw.Widget _certificateBlock(EquivalenceBlock block, int index) {
    final blockName = block.period.trim().isEmpty
        ? 'Bloco ${index + 1}'
        : block.period;
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey600, width: .6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Container(
            color: PdfColors.grey300,
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: pw.Text(
              blockName,
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: _certificateSide(
                  title: 'Disciplinas dispensadas',
                  subjects: block.current,
                  total: block.currentHours,
                ),
              ),
              pw.Container(width: .6, color: PdfColors.grey500),
              pw.Expanded(
                child: _certificateSide(
                  title: 'Disciplinas realizadas na IES de origem',
                  subjects: block.prior,
                  total: block.priorHours,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _certificateSide({
    required String title,
    required List<Subject> subjects,
    required int total,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.all(5),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(
                title,
                style: pw.TextStyle(
                  fontSize: 8,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Text(
              'Subtotal: $total h',
              style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
        pw.SizedBox(height: 3),
        if (subjects.isEmpty)
          _pdfCell('Nenhuma disciplina neste lado', centered: true)
        else
          for (final subject in subjects)
            pw.Container(
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  top: pw.BorderSide(color: PdfColors.grey300, width: .35),
                ),
              ),
              padding: const pw.EdgeInsets.symmetric(vertical: 3),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      '${subject.code.isEmpty ? '' : '${subject.code} - '}${subject.name}',
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ),
                  pw.SizedBox(width: 5),
                  pw.Text(
                    '${subject.hours} h',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ),
            ),
      ],
    ),
  );

  pw.Widget _pdfCell(String text, {bool bold = false, bool centered = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Text(
          text,
          textAlign: centered ? pw.TextAlign.center : pw.TextAlign.left,
          style: pw.TextStyle(
            fontSize: 8.5,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );
}
