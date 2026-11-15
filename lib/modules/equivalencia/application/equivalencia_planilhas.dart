import 'dart:typed_data';

import 'package:excel/excel.dart' as xls;

import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

/// Leitura das planilhas aceitas pela Equivalência (formatos documentados na
/// skill do módulo e gerados por `create_template`).
class EquivalenciaPlanilhas {
  const EquivalenciaPlanilhas._();

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('à', 'a')
      .replaceAll('ã', 'a')
      .replaceAll('â', 'a')
      .replaceAll('é', 'e')
      .replaceAll('ê', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ô', 'o')
      .replaceAll('õ', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  static xls.Excel _decode(Uint8List bytes) {
    try {
      return xls.Excel.decodeBytes(bytes);
    } on Object catch (error) {
      throw CommandException(
        'arquivo_invalido',
        'Não foi possível ler a planilha (.xlsx/.xlsm): $error',
      );
    }
  }

  /// Disciplinas de um currículo. O cabeçalho é procurado nas 30 primeiras
  /// linhas de cada aba (ordem das colunas livre). Optativas, estágio,
  /// atividades complementares, equivalências automáticas e linhas de total
  /// são ignoradas.
  static List<Subject> curriculumSubjects(Uint8List bytes) {
    final book = _decode(bytes);
    for (final sheet in book.tables.values) {
      String value(int r, int c) {
        if (r >= sheet.maxRows || c >= sheet.maxColumns) return '';
        return sheet
                .cell(
                  xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
                )
                .value
                ?.toString()
                .trim() ??
            '';
      }

      for (
        var headerRow = 0;
        headerRow < sheet.maxRows && headerRow < 30;
        headerRow++
      ) {
        final columnsByKey = <String, int>{};
        for (var c = 0; c < sheet.maxColumns; c++) {
          final key = _norm(value(headerRow, c));
          if (key.isNotEmpty) columnsByKey.putIfAbsent(key, () => c);
        }
        int column(List<String> keys) {
          for (final key in keys) {
            final index = columnsByKey[key];
            if (index != null) return index;
          }
          return -1;
        }

        final codeKey = column([
          'codigodisciplina',
          'coddisc',
          'coddisciplina',
          'codigocomponente',
          'codigo',
          'codcomponente',
          'codcomponenteorganizacional',
          'sigla',
        ]);
        final nameKey = column([
          'nomedisciplina',
          'disciplina',
          'nomecomponente',
          'componente',
          'nomedocomponente',
        ]);
        if (nameKey < 0) continue;
        final theorKey = column([
          'chteorica',
          'cargahorariateorica',
          'horasteoricas',
          'ch',
        ]);
        final pracKey = column([
          'chpratica',
          'cargahorariapratica',
          'horaspraticas',
        ]);
        final typeKey = column([
          'tipo',
          'natureza',
          'categoria',
          'classificacao',
          'tipodisciplina',
        ]);
        final structureKey = column([
          'estruturacurricular',
          'estrutura',
          'grupocurricular',
        ]);
        final totalHoursKey = column([
          'chtotal',
          'cargahorariatotal',
          'horastotais',
        ]);
        String number(String raw) => raw
            .replaceAll(',', '.')
            .replaceAll(RegExp(r'[^0-9.]'), '')
            .split('.')
            .first;
        final result = <Subject>[];
        for (var r = headerRow + 1; r < sheet.maxRows; r++) {
          String field(int col) => col < 0 ? '' : value(r, col);
          final subjectName = field(nameKey);
          if (subjectName.isEmpty) continue;
          final type = _norm(field(typeKey));
          final structure = _norm(field(structureKey));
          final details = _norm(
            '$subjectName ${field(typeKey)} ${field(structureKey)}',
          );
          final isInternship =
              type.contains('estagio') ||
              structure.contains('estagio') ||
              _norm(subjectName).contains('estagio');
          final isComplementaryActivity =
              (details.contains('atividad') &&
                  details.contains('complement')) ||
              (structure.contains('deoutros') &&
                  structure.contains('curriculo'));
          if (type.contains('optativa') ||
              isInternship ||
              isComplementaryActivity ||
              details.contains('equivalencia')) {
            continue;
          }
          final code = field(codeKey);
          if (code.isEmpty && subjectName.toLowerCase().contains('total')) {
            continue;
          }
          final theoretical = int.tryParse(number(field(theorKey))) ?? 0;
          final practical = int.tryParse(number(field(pracKey))) ?? 0;
          final total = int.tryParse(number(field(totalHoursKey))) ?? 0;
          result.add(
            Subject(
              code: code,
              name: subjectName,
              theoretical: theoretical + practical == 0 ? total : theoretical,
              practical: theoretical + practical == 0 ? 0 : practical,
            ),
          );
        }
        if (result.isNotEmpty) return result;
      }
    }
    throw const CommandException(
      'cabecalho_nao_encontrado',
      'Não encontrei colunas de disciplina e nome. Confira se a planilha '
          'contém o código/nome das disciplinas.',
    );
  }

  static int _number(String value) =>
      int.tryParse(value.replaceAll(',', '.').split('.').first) ?? 0;

  /// Análise de um aluno (aba "Equivalencia" ou a primeira): A1 aluno, A2
  /// matrícula, dados a partir da linha 7; linhas com a coluna G (Saldo)
  /// mesclada formam um bloco.
  static EquivalenceCase analysis(
    Uint8List bytes, {
    required String currentCurriculumId,
  }) {
    final book = _decode(bytes);
    final sheet =
        book.tables['Equivalencia'] ??
        (book.tables.isNotEmpty ? book.tables.values.first : null);
    if (sheet == null) {
      throw const CommandException(
        'aba_nao_encontrada',
        'A planilha não contém uma aba legível.',
      );
    }
    String cell(int r, int c) {
      if (r >= sheet.maxRows || c >= sheet.maxColumns) return '';
      final v = sheet
          .cell(xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
          .value;
      return v?.toString().trim() ?? '';
    }

    // Células "Saldo" (coluna G) mescladas identificam blocos de várias
    // linhas; linhas soltas viram blocos individuais.
    final blockRows = <int, int>{};
    for (final span in sheet.spannedItems) {
      final match = RegExp(r'^G(\d+):G(\d+)$').firstMatch(span);
      if (match != null) {
        final start = int.parse(match.group(1)!) - 1;
        final end = int.parse(match.group(2)!) - 1;
        if (end >= 6) blockRows[start] = end;
      }
    }
    final starts = <int, int>{};
    for (var r = 6; r < sheet.maxRows; r++) {
      final hasCourse = [
        cell(r, 1),
        cell(r, 2),
        cell(r, 7),
        cell(r, 8),
      ].any((e) => e.isNotEmpty);
      if (!hasCourse) continue;
      final parent = blockRows.entries
          .where((e) => r >= e.key && r <= e.value)
          .map((e) => e.key)
          .firstOrNull;
      starts[parent ?? r] = blockRows[parent ?? r] ?? r;
    }
    final blocks = <EquivalenceBlock>[];
    for (final entry in starts.entries) {
      final left = <Subject>[];
      final right = <Subject>[];
      for (var r = entry.key; r <= entry.value; r++) {
        final curCode = cell(r, 1), curName = cell(r, 2);
        if (curCode.isNotEmpty || curName.isNotEmpty) {
          left.add(
            Subject(
              code: curCode,
              name: curName,
              theoretical: _number(cell(r, 3)),
              practical: _number(cell(r, 4)),
            ),
          );
        }
        final oldCode = cell(r, 7), oldName = cell(r, 8);
        if (oldCode.isNotEmpty || oldName.isNotEmpty) {
          right.add(
            Subject(
              code: oldCode,
              name: oldName,
              theoretical: _number(cell(r, 9)),
              practical: _number(cell(r, 10)),
            ),
          );
        }
      }
      if (left.isNotEmpty && right.isNotEmpty) {
        blocks.add(
          EquivalenceBlock(
            id: '${DateTime.now().microsecondsSinceEpoch}${blocks.length}',
            period: cell(entry.key, 0),
            current: left,
            prior: right,
          ),
        );
      }
    }
    if (blocks.isEmpty) {
      throw const CommandException(
        'sem_blocos',
        'Não encontrei blocos com disciplinas nos dois currículos. Confira se '
            'selecionou a planilha modelo.',
      );
    }
    return EquivalenceCase(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      student: cell(0, 0),
      studentId: cell(1, 0),
      currentCurriculumId: currentCurriculumId,
      priorCurriculumId: '',
      status: 'Em análise',
      notes: '',
      blocks: blocks,
    );
  }
}
