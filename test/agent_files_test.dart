import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/ai_agent/agent_files.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('files'));
  tearDown(() => dir.delete(recursive: true));

  Future<String> xlsx() async {
    final excel = Excel.createExcel();
    final sheet = excel['Notas'];
    sheet.appendRow([TextCellValue('Aluno'), TextCellValue('Nota')]);
    for (var i = 1; i <= 120; i++) {
      sheet.appendRow([TextCellValue('A$i'), IntCellValue(i % 10)]);
    }
    excel.delete('Sheet1');
    final path = p.join(dir.path, 'notas.xlsx');
    File(path).writeAsBytesSync(excel.encode()!);
    return path;
  }

  test('planilha: resumo primeiro, depois só o intervalo', () async {
    final path = await xlsx();
    final outline = await AgentFiles.readSpreadsheet({'path': path});
    final aba = (outline['abas'] as List).single as Map;
    expect(aba['aba'], 'Notas');
    expect(aba['linhas'], 121);
    expect(aba['cabecalho'], 'Aluno\tNota');
    expect(aba['primeiras_linhas'], hasLength(3));
    // O resumo é pequeno, mesmo com 121 linhas.
    expect(jsonEncode(outline).length, lessThan(600));

    final range = await AgentFiles.readSpreadsheet({
      'path': path,
      'sheet': 'Notas',
      'range': 'A10:B12',
    });
    expect(range['dados'], '10\tA9\t9\n11\tA10\t0\n12\tA11\t1\n');
    final page = await AgentFiles.readSpreadsheet({
      'path': path,
      'sheet': 'Notas',
      'start_row': 2,
      'max_rows': 5,
    });
    expect('${page['dados']}'.trim().split('\n'), hasLength(5));
    expect(
      () => AgentFiles.readSpreadsheet({'path': path, 'sheet': 'X'}),
      throwsStateError,
    );
  });

  test('CSV com ponto e vírgula e aspas', () async {
    final path = p.join(dir.path, 'a.csv');
    File(path).writeAsStringSync('nome;obs\n"Silva; J";"disse ""oi"""\n');
    final out = await AgentFiles.readSpreadsheet({'path': path, 'sheet': 'a'});
    expect(out['dados'], contains('Silva; J\tdisse "oi"'));
  });

  test('docx: parágrafos e tabela, em fatias', () async {
    const xml =
        '<?xml version="1.0"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
        '<w:p><w:r><w:t>Plano de Ensino</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Data</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>Conteúdo</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:t>Fim</w:t></w:r></w:p>'
        '</w:body></w:document>';
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'word/document.xml',
          utf8.encode(xml).length,
          utf8.encode(xml),
        ),
      );
    final path = p.join(dir.path, 'plano.docx');
    File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
    final doc = await AgentFiles.readDocument({'path': path});
    expect(doc['trecho'], 'Plano de Ensino\nData\tConteúdo\nFim');
    final slice = await AgentFiles.readDocument({
      'path': path,
      'offset': 0,
      'max_chars': 200,
    });
    expect(slice['caracteres_total'], 33);
  });
}
