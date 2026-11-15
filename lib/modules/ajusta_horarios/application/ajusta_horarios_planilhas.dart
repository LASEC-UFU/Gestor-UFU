import 'dart:convert';

import 'package:excel/excel.dart' as xls;
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/ajusta_horarios/domain/ajusta_horarios.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/domain/distribuicao_docente.dart';

/// Conteúdo de uma planilha importada: a base de disciplinas (aba BDados)
/// ou a distribuição docente (aba Banco). A aba Banco tem prioridade.
sealed class AjustaHorariosImportacao {
  const AjustaHorariosImportacao();
}

class ImportacaoBDados extends AjustaHorariosImportacao {
  const ImportacaoBDados(this.disciplinas);
  final List<HorarioDisciplina> disciplinas;
}

class ImportacaoBanco extends AjustaHorariosImportacao {
  const ImportacaoBanco(this.distribuicao);
  final List<DistribuicaoDocente> distribuicao;
  Set<String> get docentes => {
    for (final item in distribuicao)
      if (item.teacher.trim().isNotEmpty) item.teacher.trim(),
  };
}

/// Leitura e montagem das planilhas e grades do Ajusta Horários, sem tela.
class AjustaHorariosPlanilhas {
  /// Lê uma planilha .xlsx/.xlsm (abas Banco ou BDados). Lança
  /// [FormatException] com mensagem para o usuário.
  static AjustaHorariosImportacao ler(List<int> bytes) {
    final book = xls.Excel.decodeBytes(bytes);
    final banco = book.tables['Banco'];
    if (banco != null) return ImportacaoBanco(lerBanco(banco));
    final sheet = book.tables['BDados'];
    if (sheet == null) {
      throw const FormatException(
        'A planilha não contém a aba BDados nem a aba Banco.',
      );
    }
    return ImportacaoBDados(lerBDados(sheet));
  }

  static String _cell(xls.Sheet sheet, int row, int column) {
    if (column < 0 || row >= sheet.maxRows) return '';
    return sheet
            .cell(
              xls.CellIndex.indexByColumnRow(
                columnIndex: column,
                rowIndex: row,
              ),
            )
            .value
            ?.toString()
            .trim() ??
        '';
  }

  /// Aba BDados: a partir da 3ª linha, colunas B (período,curso;...),
  /// C (faixa,dia+1;...), D código, E sigla, F nome, G turma, H docentes
  /// (separados por vírgula), I sala, J CH teórica, K CH prática.
  static List<HorarioDisciplina> lerBDados(xls.Sheet sheet) {
    String value(int row, int col) => _cell(sheet, row, col);
    List<T> parsePairs<T>(String raw, T Function(int a, int b) create) =>
        raw.split(';').where((item) => item.contains(',')).map((item) {
          final parts = item.split(',');
          return create(
            int.tryParse(parts[0].trim()) ?? 0,
            int.tryParse(parts[1].trim()) ?? 0,
          );
        }).toList();
    final imported = <HorarioDisciplina>[];
    for (var row = 2; row < sheet.maxRows; row++) {
      final code = value(row, 3), acronym = value(row, 4), name = value(row, 5);
      if (code.isEmpty && acronym.isEmpty && name.isEmpty) continue;
      imported.add(
        HorarioDisciplina(
          id: 'import_${const Uuid().v4()}',
          code: code,
          acronym: acronym,
          name: name,
          className: value(row, 6),
          teachers: value(row, 7)
              .split(',')
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty)
              .toList(),
          room: value(row, 8),
          theoryHours: int.tryParse(value(row, 9)) ?? 0,
          practiceHours: int.tryParse(value(row, 10)) ?? 0,
          coursePeriods:
              parsePairs(
                    value(row, 1),
                    (period, program) =>
                        CursoPeriodo(program: program, period: period),
                  )
                  .where(
                    (v) =>
                        v.program >= 1 &&
                        v.program <= 5 &&
                        v.period >= 1 &&
                        v.period <= 11,
                  )
                  .toList(),
          slots:
              parsePairs(
                    value(row, 2),
                    (slot, weekdayEncoded) =>
                        HorarioSlot(weekday: weekdayEncoded - 1, slot: slot),
                  )
                  .where(
                    (v) =>
                        v.weekday >= 1 &&
                        v.weekday <= 5 &&
                        v.slot >= 1 &&
                        v.slot <= horarioFaixas.length,
                  )
                  .toList(),
        ),
      );
    }
    if (imported.isEmpty) {
      throw const FormatException(
        'Nenhuma disciplina foi encontrada em BDados.',
      );
    }
    return imported;
  }

  static String _normalize(String value) => value
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

  /// Aba Banco: cabeçalho na 1ª linha (Período, Sigla, Disciplina, Turma,
  /// Docente, Opção (Sigla Turma), CH_T, CH_P, CH EAD, CH Extensão).
  static List<DistribuicaoDocente> lerBanco(xls.Sheet sheet) {
    String cell(int row, int column) => _cell(sheet, row, column);
    final headers = [
      for (var column = 0; column < sheet.maxColumns; column++)
        _normalize(cell(0, column)),
    ];
    int column(String name) => headers.indexOf(_normalize(name));

    final periodColumn = column('Período');
    final acronymColumn = column('Sigla');
    final subjectColumn = column('Disciplina');
    final classColumn = column('Turma');
    final teacherColumn = column('Docente');
    final optionColumn = column('Opção (Sigla Turma)');
    final theoryColumn = column('CH_T');
    final practiceColumn = column('CH_P');
    final eadColumn = column('CH EAD');
    final extensionColumn = column('CH Extensão');
    if (teacherColumn < 0 || (optionColumn < 0 && subjectColumn < 0)) {
      throw const FormatException(
        'A aba Banco precisa conter Docente e uma coluna de disciplina.',
      );
    }

    final imported = <DistribuicaoDocente>[];
    for (var row = 1; row < sheet.maxRows; row++) {
      final teacher = cell(row, teacherColumn);
      if (teacher.isEmpty) continue;
      final option = cell(row, optionColumn);
      final acronym = cell(row, acronymColumn);
      final className = cell(row, classColumn);
      final subject = cell(row, subjectColumn);
      final discipline = option.isNotEmpty
          ? option
          : '${acronym.isEmpty ? subject : acronym}${className.isEmpty ? '' : ' $className'}';
      if (discipline.trim().isEmpty) continue;
      imported.add(
        DistribuicaoDocente(
          teacher: teacher,
          discipline: discipline.trim(),
          period: cell(row, periodColumn),
          theoryHours: int.tryParse(cell(row, theoryColumn)) ?? 0,
          practiceHours: int.tryParse(cell(row, practiceColumn)) ?? 0,
          eadHours: int.tryParse(cell(row, eadColumn)) ?? 0,
          extensionHours: int.tryParse(cell(row, extensionColumn)) ?? 0,
        ),
      );
    }
    if (imported.isEmpty) {
      throw const FormatException(
        'Nenhuma distribuição docente encontrada na aba Banco.',
      );
    }
    return imported;
  }

  /// Grade semanal ("dia:faixa" → disciplinas) de um curso/período, docente
  /// ou sala. Disciplinas EaD ficam fora da grade.
  static Map<String, List<HorarioDisciplina>> grade(
    Iterable<HorarioDisciplina> entries, {
    int? program,
    int? period,
    String? teacher,
    String? room,
  }) {
    final result = <String, List<HorarioDisciplina>>{};
    for (final entry in entries) {
      if (entry.modality == 'ead') continue;
      final include = room != null
          ? entry.room.trim().toLowerCase() == room.trim().toLowerCase()
          : teacher != null
          ? entry.teacherNames.contains(teacher)
          : entry.coursePeriods.any(
              (item) => item.program == program && item.period == period,
            );
      if (!include) continue;
      for (final slot in entry.slots) {
        result.putIfAbsent(slot.key, () => []).add(entry);
      }
    }
    return result;
  }

  /// Linhas da grade (cabeçalho "Faixa horária" + dias, uma linha por faixa).
  static List<List<String>> linhasGrade(
    Map<String, List<HorarioDisciplina>> schedule,
  ) => [
    ['Faixa horária', ...horarioDias],
    for (var slot = 1; slot <= horarioFaixas.length; slot++)
      [
        horarioFaixas[slot - 1],
        for (var day = 1; day <= 5; day++)
          (schedule['$day:$slot'] ?? const [])
              .map((entry) => entry.timetableLabel)
              .join(' | '),
      ],
  ];

  /// CSV separado por ";" (com BOM, para abrir no Excel).
  static List<int> csv(List<List<String>> rows) {
    final text = rows
        .map(
          (row) =>
              row.map((cell) => '"${cell.replaceAll('"', '""')}"').join(';'),
        )
        .join('\r\n');
    return [0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
  }
}
