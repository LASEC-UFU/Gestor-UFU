import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:config_moodle/domain/entities/ajusta_horarios.dart';

class AjustaHorariosPdfSheet {
  const AjustaHorariosPdfSheet({
    required this.title,
    required this.schedule,
    required this.disciplineColors,
    required this.cellColorStops,
  });

  final String title;
  final Map<String, List<HorarioDisciplina>> schedule;
  final Map<String, PdfColor> disciplineColors;
  final Map<String, List<double>> cellColorStops;
}

class AjustaHorariosPdfService {
  Future<Uint8List> generate({
    required String term,
    required List<AjustaHorariosPdfSheet> sheets,
    required bool isLightTheme,
  }) async {
    final regularFont = await _loadWindowsFont('arial.ttf');
    final boldFont = await _loadWindowsFont('arialbd.ttf');
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );
    final pageBackground = _hex(isLightTheme ? 0xfff4f6fc : 0xff0f1123);
    final panelBackground = _hex(isLightTheme ? 0xffffffff : 0xff1e2045);
    final alternateRow = _hex(isLightTheme ? 0xfff0f1f7 : 0xff171932);
    final headerBackground = _hex(isLightTheme ? 0xffe8e7fc : 0xff292b55);
    final gridColor = _hex(isLightTheme ? 0xffd9deeb : 0xff2a2d52);
    final textColor = _hex(isLightTheme ? 0xff1d2033 : 0xffffffff);
    final secondaryColor = _hex(isLightTheme ? 0xff5e6478 : 0xff9ea2c4);
    final paletteOpacity = (isLightTheme ? 70 : 100) / 255;
    for (final sheet in sheets) {
      final title = sheet.title;
      final schedule = sheet.schedule;
      final disciplineColors = sheet.disciplineColors;
      final cellColorStops = sheet.cellColorStops;
      final weeklyLessonCount = schedule.values.fold<int>(
        0,
        (sum, entries) => sum + entries.map((entry) => entry.id).toSet().length,
      );
      document.addPage(
        pw.Page(
          pageTheme: pw.PageTheme(
            pageFormat: PdfPageFormat.a4.landscape,
            orientation: pw.PageOrientation.landscape,
            margin: const pw.EdgeInsets.fromLTRB(20, 16, 20, 14),
            buildBackground: (context) => pw.FullPage(
              ignoreMargins: true,
              child: pw.Container(color: pageBackground),
            ),
          ),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      title,
                      style: pw.TextStyle(
                        color: textColor,
                        fontSize: 15,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.Text(
                    term,
                    style: pw.TextStyle(color: secondaryColor, fontSize: 8.5),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Expanded(
                child: pw.Table(
                  border: pw.TableBorder.all(color: gridColor, width: 0.55),
                  columnWidths: {
                    0: const pw.FixedColumnWidth(102),
                    for (var day = 1; day <= 5; day++)
                      day: const pw.FlexColumnWidth(1),
                  },
                  children: [
                    pw.TableRow(
                      repeat: true,
                      decoration: pw.BoxDecoration(color: headerBackground),
                      children: [
                        _headerCell('Faixa horária', textColor),
                        for (final day in horarioDias)
                          _headerCell(day, textColor),
                      ],
                    ),
                    for (var slot = 1; slot <= horarioFaixas.length; slot++)
                      _scheduleRow(
                        slot: slot,
                        schedule: schedule,
                        disciplineColors: disciplineColors,
                        cellColorStops: cellColorStops,
                        panelBackground: panelBackground,
                        alternateRow: alternateRow,
                        paletteOpacity: paletteOpacity,
                        textColor: textColor,
                      ),
                  ],
                ),
              ),
              pw.SizedBox(height: 8),
              _disciplineLegend(
                schedule,
                panelBackground,
                gridColor,
                textColor,
                secondaryColor,
              ),
              pw.SizedBox(height: 6),
              pw.Row(
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      'Cada cor identifica uma disciplina e sua turma. Turmas simultâneas aparecem separadas por vírgula.',
                      style: pw.TextStyle(color: secondaryColor, fontSize: 7.2),
                    ),
                  ),
                  pw.Text(
                    '$weeklyLessonCount aulas por semana',
                    style: pw.TextStyle(
                      color: textColor,
                      fontSize: 7.5,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return document.save();
  }

  pw.Widget _headerCell(String value, PdfColor textColor) => pw.Container(
    height: 25,
    alignment: pw.Alignment.center,
    padding: const pw.EdgeInsets.symmetric(horizontal: 4),
    child: pw.Text(
      value,
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
        color: textColor,
        fontSize: 9.1,
        fontWeight: pw.FontWeight.bold,
      ),
    ),
  );

  pw.Widget _scheduleCell(
    List<HorarioDisciplina> entries,
    Map<String, PdfColor> disciplineColors,
    List<double> stops,
    PdfColor rowColor,
    double paletteOpacity,
    PdfColor textColor,
    double rowHeight,
  ) {
    final unique = <String, HorarioDisciplina>{
      for (final entry in entries) _scheduleColorKey(entry): entry,
    }.values.toList();
    if (unique.isEmpty) {
      return pw.Container(color: rowColor, height: rowHeight);
    }

    final colors = unique
        .map(
          (entry) => _blend(
            disciplineColors[_scheduleColorKey(entry)] ?? _hex(0xff6c63ff),
            rowColor,
            paletteOpacity,
          ),
        )
        .toList();
    final gradientColors = <PdfColor>[colors.first];
    if (colors.length == 1) {
      gradientColors.add(colors.single);
    } else {
      for (var index = 0; index < colors.length - 1; index++) {
        gradientColors
          ..add(colors[index])
          ..add(colors[index + 1]);
      }
      gradientColors.add(colors.last);
    }
    final labels = unique
        .map(
          (entry) =>
              '${entry.acronym}${entry.className.isEmpty ? '' : ' · ${entry.className}'}',
        )
        .toList();

    return pw.Container(
      height: rowHeight,
      alignment: pw.Alignment.center,
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: pw.BoxDecoration(
        gradient: pw.LinearGradient(
          colors: gradientColors,
          stops: stops,
          begin: pw.Alignment.centerLeft,
          end: pw.Alignment.centerRight,
        ),
      ),
      child: pw.Text(
        labels.join(', '),
        maxLines: 3,
        overflow: pw.TextOverflow.clip,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          color: textColor,
          fontSize: 9.75,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }

  pw.TableRow _scheduleRow({
    required int slot,
    required Map<String, List<HorarioDisciplina>> schedule,
    required Map<String, PdfColor> disciplineColors,
    required Map<String, List<double>> cellColorStops,
    required PdfColor panelBackground,
    required PdfColor alternateRow,
    required double paletteOpacity,
    required PdfColor textColor,
  }) {
    final rowHeight = _scheduleRowHeight(slot, schedule);
    final rowColor = slot.isEven ? panelBackground : alternateRow;
    return pw.TableRow(
      decoration: pw.BoxDecoration(color: rowColor),
      children: [
        pw.Container(
          height: rowHeight,
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(horizontal: 5),
          child: pw.Text(
            horarioFaixas[slot - 1]
                .replaceAll('–', '-')
                .replaceAll('\u2013', '-')
                .replaceAll('\u2014', '-'),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              color: textColor,
              fontSize: 10.2,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
        for (var weekday = 1; weekday <= 5; weekday++)
          _scheduleCell(
            schedule['$weekday:$slot'] ?? const [],
            disciplineColors,
            cellColorStops['$weekday:$slot'] ?? const [0, 1],
            rowColor,
            paletteOpacity,
            textColor,
            rowHeight,
          ),
      ],
    );
  }

  double _scheduleRowHeight(
    int slot,
    Map<String, List<HorarioDisciplina>> schedule,
  ) {
    final cellWidth = (PdfPageFormat.a4.landscape.width - 40 - 102) / 5;
    final charsPerLine = (cellWidth / (9.75 * 0.52)).floor().clamp(15, 80);
    var height = 24.0;
    for (var weekday = 1; weekday <= 5; weekday++) {
      final entries = <String, HorarioDisciplina>{
        for (final entry in schedule['$weekday:$slot'] ?? const [])
          _scheduleColorKey(entry): entry,
      }.values.toList();
      final label = entries
          .map(
            (entry) =>
                '${entry.acronym}${entry.className.isEmpty ? '' : ' · ${entry.className}'}',
          )
          .join(', ');
      final lines = (label.length / charsPerLine).ceil().clamp(1, 3);
      final neededHeight = (lines * 11.5 + 5).clamp(24.0, 40.0);
      if (neededHeight > height) height = neededHeight;
    }
    return height;
  }

  pw.Widget _disciplineLegend(
    Map<String, List<HorarioDisciplina>> schedule,
    PdfColor background,
    PdfColor border,
    PdfColor textColor,
    PdfColor secondaryColor,
  ) {
    final unique = <String, HorarioDisciplina>{};
    for (final entries in schedule.values) {
      for (final entry in entries) {
        final legendKey = [
          entry.acronym.trim().toLowerCase(),
          entry.name.trim().toLowerCase(),
          entry.teacherNames.map((name) => name.toLowerCase()).join('|'),
        ].join('|');
        unique[legendKey] = entry;
      }
    }
    final items = unique.values.toList()
      ..sort(
        (a, b) => a.acronym.toLowerCase().compareTo(b.acronym.toLowerCase()),
      );
    final rows = [
      for (var index = 0; index < items.length; index += 3)
        items.skip(index).take(3).toList(),
    ];
    return pw.Container(
      padding: const pw.EdgeInsets.fromLTRB(8, 5, 8, 6),
      decoration: pw.BoxDecoration(
        color: background,
        border: pw.Border.all(color: border, width: 0.6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'LEGENDA DE DISCIPLINAS',
            style: pw.TextStyle(
              color: secondaryColor,
              fontSize: 7,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 3),
          for (final row in rows)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Row(
                children: [
                  for (var index = 0; index < 3; index++)
                    pw.Expanded(
                      child: index < row.length
                          ? pw.Text(
                              '${row[index].acronym} | ${row[index].name}\n${row[index].teacherNames.join(', ')}',
                              maxLines: 3,
                              overflow: pw.TextOverflow.clip,
                              style: pw.TextStyle(
                                color: textColor,
                                fontSize: 6.5,
                              ),
                            )
                          : pw.SizedBox(),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _scheduleColorKey(HorarioDisciplina entry) =>
      '${entry.id}:${entry.className.trim().toLowerCase()}';

  Future<pw.Font> _loadWindowsFont(String fileName) async {
    final bytes = await File('C:/Windows/Fonts/$fileName').readAsBytes();
    return pw.Font.ttf(ByteData.sublistView(bytes));
  }

  PdfColor _blend(PdfColor foreground, PdfColor background, double opacity) =>
      PdfColor(
        foreground.red * opacity + background.red * (1 - opacity),
        foreground.green * opacity + background.green * (1 - opacity),
        foreground.blue * opacity + background.blue * (1 - opacity),
      );

  PdfColor _hex(int value) => PdfColor.fromInt(value);
}
