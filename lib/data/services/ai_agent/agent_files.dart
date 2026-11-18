import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:gestor_ufu/platform/services/poppler.dart';

/// Leitura econômica de arquivos para os agentes: em vez de despejar a
/// planilha ou o documento inteiro no contexto (muitos tokens), o agente
/// pede primeiro um resumo e depois só o trecho de que precisa.
class AgentFiles {
  static const maxCells = 2000;
  static const maxChars = 20000;

  /// `read_spreadsheet`: sem `sheet`, devolve o resumo (abas, tamanho,
  /// cabeçalho e as primeiras linhas). Com `sheet` (+ `range` "A1:F50" ou
  /// `start_row`/`max_rows`), devolve só aquele trecho em TSV.
  static Future<Map<String, Object?>> readSpreadsheet(
    Map<String, dynamic> input,
  ) async {
    final path = '${input['path'] ?? ''}'.trim();
    final file = File(path);
    if (path.isEmpty || !await file.exists()) {
      throw StateError('Arquivo não encontrado: $path');
    }
    final ext = p.extension(path).toLowerCase();
    final sheets = <String, List<List<String>>>{};
    if (ext == '.csv' || ext == '.tsv') {
      final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      final separator = ext == '.tsv'
          ? '\t'
          : (text.split('\n').first.contains(';') ? ';' : ',');
      sheets[p.basenameWithoutExtension(path)] = [
        for (final line in const LineSplitter().convert(text))
          _splitCsv(line, separator),
      ];
    } else if (ext == '.xlsx' || ext == '.xlsm') {
      final excel = Excel.decodeBytes(await file.readAsBytes());
      for (final entry in excel.tables.entries) {
        sheets[entry.key] = [
          for (final row in entry.value.rows)
            [for (final cell in row) _cellText(cell?.value)],
        ];
      }
    } else {
      throw StateError(
        'Formato não suportado ($ext). Use .xlsx, .xlsm, .csv ou .tsv '
        '(.xls antigo: salve como .xlsx).',
      );
    }

    final sheetName = '${input['sheet'] ?? ''}'.trim();
    if (sheetName.isEmpty) {
      final preview = ((input['preview_rows'] as num?)?.toInt() ?? 3).clamp(
        0,
        20,
      );
      return {
        'arquivo': p.basename(path),
        'abas': [
          for (final entry in sheets.entries)
            () {
              final rows = _trimRows(entry.value);
              final cols = rows.fold<int>(
                0,
                (m, r) => r.length > m ? r.length : m,
              );
              return {
                'aba': entry.key,
                'linhas': rows.length,
                'colunas': cols,
                if (rows.isNotEmpty)
                  'intervalo': 'A1:${_col(cols)}${rows.length}',
                if (rows.isNotEmpty) 'cabecalho': rows.first.join('\t'),
                if (rows.length > 1 && preview > 0)
                  'primeiras_linhas': rows
                      .skip(1)
                      .take(preview)
                      .map((r) => r.join('\t'))
                      .toList(),
              };
            }(),
        ],
        'dica':
            'Leia só o necessário: read_spreadsheet com sheet e range '
            '(ex.: "A1:F50") ou start_row/max_rows.',
      };
    }
    final rows = sheets[sheetName];
    if (rows == null) {
      throw StateError(
        'Aba "$sheetName" não existe. Abas: ${sheets.keys.join(', ')}.',
      );
    }
    var (r0, c0, r1, c1) = (0, 0, rows.length - 1, 1 << 20);
    final range = '${input['range'] ?? ''}'.trim().toUpperCase();
    if (range.isNotEmpty) {
      final m = RegExp(r'^([A-Z]+)(\d+)(?::([A-Z]+)(\d+))?$').firstMatch(range);
      if (m == null) {
        throw StateError('Intervalo inválido: $range (ex.: A1:F50).');
      }
      c0 = _colIndex(m.group(1)!);
      r0 = int.parse(m.group(2)!) - 1;
      c1 = m.group(3) == null ? c0 : _colIndex(m.group(3)!);
      r1 = m.group(4) == null ? r0 : int.parse(m.group(4)!) - 1;
    } else {
      r0 = ((input['start_row'] as num?)?.toInt() ?? 1) - 1;
      r1 = r0 + ((input['max_rows'] as num?)?.toInt() ?? 50) - 1;
    }
    final out = StringBuffer();
    var cells = 0;
    var truncated = false;
    var lastRow = r0;
    for (var r = r0.clamp(0, rows.length); r <= r1 && r < rows.length; r++) {
      final row = rows[r];
      final end = c1 >= row.length ? row.length - 1 : c1;
      final values = [for (var c = c0; c <= end; c++) row[c]];
      cells += values.length;
      if (cells > maxCells || out.length > maxChars) {
        truncated = true;
        break;
      }
      out.writeln('${r + 1}\t${values.join('\t')}');
      lastRow = r + 1;
    }
    return {
      'aba': sheetName,
      'formato': 'TSV; a 1ª coluna é o número da linha',
      'linhas_total': rows.length,
      'dados': out.toString(),
      if (truncated)
        'cortado':
            'Limite de $maxCells células; continue com start_row='
            '${lastRow + 1}.',
    };
  }

  /// `read_document`: extrai texto de DOCX, PDF e arquivos de texto em fatias.
  static Future<Map<String, Object?>> readDocument(
    Map<String, dynamic> input,
  ) async {
    final path = '${input['path'] ?? ''}'.trim();
    final text = await documentText(path);
    final offset = ((input['offset'] as num?)?.toInt() ?? 0).clamp(
      0,
      text.length,
    );
    final max = ((input['max_chars'] as num?)?.toInt() ?? 8000).clamp(
      200,
      maxChars,
    );
    final end = (offset + max).clamp(0, text.length);
    return {
      'arquivo': p.basename(path),
      'caracteres_total': text.length,
      'trecho': text.substring(offset, end),
      if (end < text.length)
        'continua': 'Use offset=$end para o próximo trecho.',
    };
  }

  /// Extrai o conteúdo integral de um DOCX, PDF ou arquivo de texto.
  static Future<String> documentText(String path) async {
    final file = File(path);
    if (path.trim().isEmpty || !await file.exists()) {
      throw StateError('Arquivo não encontrado: $path');
    }
    final ext = p.extension(path).toLowerCase();
    if (ext == '.docx') return docxText(await file.readAsBytes());
    if (ext == '.pdf') {
      final text = (await pdfPages(
        path,
      )).join('\n\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
      if (text.isEmpty) {
        throw StateError(
          'O PDF não tem camada de texto (digitalizado como imagem); é '
          'necessário OCR.',
        );
      }
      return text;
    }
    if (textExtensions.contains(ext)) {
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }
    throw StateError('Formato não suportado: $ext.');
  }

  /// Extensões lidas como texto puro.
  static const textExtensions = {
    '.txt',
    '.md',
    '.csv',
    '.tsv',
    '.json',
    '.xml',
    '.html',
    '.htm',
    '.log',
  };

  /// Texto de cada página de um PDF (camada de texto, via Poppler
  /// `pdftotext`, em ordem de leitura). Páginas digitalizadas como imagem
  /// voltam vazias: o PDF precisa de OCR, que o Gestor não faz.
  static Future<List<String>> pdfPages(String path) =>
      Poppler.paginasDeTexto(path);

  /// Parágrafos de um .docx na ordem do documento, com o estilo de
  /// parágrafo (`w:pStyle`, ex.: "Heading1", "Ttulo2"); cada linha de
  /// tabela vira um parágrafo com as células separadas por TAB.
  static List<({String texto, String estilo})> docxParagraphs(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('word/document.xml');
    if (entry == null) throw StateError('O arquivo não parece um .docx.');
    final xml = XmlDocument.parse(
      utf8.decode(entry.content as List<int>, allowMalformed: true),
    );
    final out = <({String texto, String estilo})>[];
    final body = xml.findAllElements('w:body').firstOrNull;
    if (body == null) return out;
    for (final child in body.childElements) {
      if (child.name.local == 'p') {
        final style =
            child
                .findAllElements('w:pStyle')
                .firstOrNull
                ?.getAttribute('w:val') ??
            '';
        out.add((texto: _docxParagraph(child), estilo: style));
      } else if (child.name.local == 'tbl') {
        for (final row in child.findAllElements('w:tr')) {
          out.add((
            texto: [
              for (final cell in row.findElements('w:tc'))
                cell
                    .findAllElements('w:p')
                    .map(_docxParagraph)
                    .join(' ')
                    .trim(),
            ].join('\t'),
            estilo: 'tabela',
          ));
        }
      }
    }
    return out;
  }

  static String _docxParagraph(XmlElement p) {
    final buffer = StringBuffer();
    for (final node in p.descendants.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 't':
          buffer.write(node.innerText);
        case 'tab':
          buffer.write('\t');
        case 'br':
          buffer.write(' ');
      }
    }
    return buffer.toString();
  }

  /// Texto de um .docx: parágrafos em linhas, tabelas com células por TAB.
  static String docxText(List<int> bytes) => docxParagraphs(
    bytes,
  ).map((p) => p.texto).join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

  static String _cellText(CellValue? value) {
    if (value == null) return '';
    final text = switch (value) {
      FormulaCellValue(:final formula) => '=$formula',
      _ => value.toString(),
    };
    return text.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  }

  static List<List<String>> _trimRows(List<List<String>> rows) {
    var end = rows.length;
    while (end > 0 && rows[end - 1].every((c) => c.isEmpty)) {
      end--;
    }
    return rows.sublist(0, end);
  }

  static List<String> _splitCsv(String line, String separator) {
    final out = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (ch == separator && !quoted) {
        out.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    out.add(buffer.toString());
    return out;
  }

  static int _colIndex(String letters) {
    var n = 0;
    for (final code in letters.codeUnits) {
      n = n * 26 + (code - 64);
    }
    return n - 1;
  }

  static String _col(int count) {
    var n = count;
    var s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s.isEmpty ? 'A' : s;
  }
}
