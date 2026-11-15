import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/ajusta_horarios/application/ajusta_horarios_planilhas.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/data/ajusta_horarios_store.dart';
import 'package:gestor_ufu/modules/ajusta_horarios/domain/ajusta_horarios.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';

const _termo = {
  'term': {'type': 'string', 'description': 'Período letivo (padrão: o ativo)'},
};

/// Comandos do Ajusta Horários (tela, menu "/" e Agente de IA). [changes] é
/// avisado quando um comando altera os dados, para a tela recarregar.
List<ModuleCommand> ajustaHorariosCommands(
  AjustaHorariosStore store,
  AcademicTermService terms, {
  ValueNotifier<int>? changes,
}) {
  Future<String> term(CommandInput input) async {
    await terms.load();
    final requested = input.optionalString('term');
    if (requested == null) return terms.active;
    final normalized = AcademicTermService.normalize(requested);
    if (!terms.terms.contains(normalized)) {
      throw CommandException(
        'periodo_nao_encontrado',
        'Período "$requested" não existe. Períodos: ${terms.terms.join(', ')}.',
      );
    }
    return normalized;
  }

  Map<String, dynamic> resumo(HorarioDisciplina e) => {
    'id': e.id,
    'codigo': e.code,
    'sigla': e.acronym,
    'nome': e.name,
    'turma': e.className,
    'modalidade': e.modality,
    'docentes': e.teacherNames,
    'sala': e.room,
    'chTeorica': e.theoryHours,
    'chPratica': e.practiceHours,
    'cursoPeriodos': [
      for (final cp in e.coursePeriods)
        {'curso': cp.program, 'periodo': cp.period},
    ],
    'horarios': [
      for (final s in e.slots)
        '${horarioDias[s.weekday - 1]} ${horarioFaixas[s.slot - 1]}',
    ],
  };

  Map<String, List<HorarioDisciplina>> grade(
    List<HorarioDisciplina> entries,
    CommandInput input,
    int? period,
  ) => AjustaHorariosPlanilhas.grade(
    entries,
    program: input['program'] is num ? (input['program'] as num).toInt() : null,
    period: period,
    teacher: input.optionalString('teacher'),
    room: input.optionalString('room'),
  );

  void validarFiltro(CommandInput input) {
    final hasProgram = input['program'] is num;
    final hasTeacher = input.optionalString('teacher') != null;
    final hasRoom = input.optionalString('room') != null;
    if ([hasProgram, hasTeacher, hasRoom].where((v) => v).length != 1) {
      throw const CommandException(
        'filtro_invalido',
        'Informe exatamente um: program (com periods), teacher ou room.',
      );
    }
  }

  List<int> periodos(CommandInput input) {
    final raw = input['periods'];
    final list = raw is List
        ? raw.whereType<num>().map((n) => n.toInt()).toList()
        : raw is num
        ? [raw.toInt()]
        : <int>[];
    if (input['program'] is num && list.isEmpty) {
      throw const CommandException(
        'filtro_invalido',
        'Com program, informe periods (ex.: [1, 2]; 11 = optativas).',
      );
    }
    return list;
  }

  const filtro = {
    'program': {'type': 'integer', 'description': 'Número do curso'},
    'periods': {
      'type': 'array',
      'items': {'type': 'integer'},
      'description': 'Períodos do curso (1–10; 11 = optativas)',
    },
    'teacher': {'type': 'string'},
    'room': {'type': 'string'},
  };

  return [
    ModuleCommand(
      id: 'ajustaHorarios.listar',
      title: 'Listar horários',
      description:
          'Sem filtro: períodos letivos, cursos, totais de disciplinas, '
          'docentes e salas do período. Com program+periods, teacher ou '
          'room: as disciplinas (turma, docentes, sala, horários).',
      inputSchema: {
        'type': 'object',
        'properties': {..._termo, ...filtro},
      },
      run: (input, origin) async {
        final t = await term(input);
        final entries = await store.load(term: t);
        final hasFilter =
            input['program'] is num ||
            input.optionalString('teacher') != null ||
            input.optionalString('room') != null;
        if (!hasFilter) {
          return CommandResult.ok(
            data: {
              'periodoLetivo': t,
              'periodosLetivos': terms.terms,
              'cursos': {
                for (final p in (await store.programs()).entries)
                  '${p.key}': p.value,
              },
              'disciplinas': entries.length,
              'docentes': await store.teacherRoster(term: t),
              'salas': await store.roomRoster(term: t),
              'distribuicao': (await store.distribution(term: t)).length,
            },
          );
        }
        validarFiltro(input);
        final ps = periodos(input);
        final program = input['program'] is num
            ? (input['program'] as num).toInt()
            : null;
        final teacher = input.optionalString('teacher');
        final room = input.optionalString('room')?.trim().toLowerCase();
        final selected = entries.where((e) {
          if (teacher != null) return e.teacherNames.contains(teacher);
          if (room != null) return e.room.trim().toLowerCase() == room;
          return e.coursePeriods.any(
            (cp) => cp.program == program && ps.contains(cp.period),
          );
        });
        return CommandResult.ok(
          data: {
            'periodoLetivo': t,
            'disciplinas': [for (final e in selected) resumo(e)],
          },
        );
      },
    ),
    ModuleCommand(
      id: 'ajustaHorarios.distribuicao',
      title: 'Distribuição docente',
      description:
          'Linhas da distribuição docente do período (aba Banco): docente, '
          'disciplina/turma, período e cargas horárias; teacher filtra.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._termo,
          'teacher': {'type': 'string'},
        },
      },
      run: (input, origin) async {
        final t = await term(input);
        final teacher = input.optionalString('teacher');
        final rows = [
          for (final r in await store.distribution(term: t))
            if (teacher == null || r.teacher == teacher) r.toJson(),
        ];
        return CommandResult.ok(data: {'periodoLetivo': t, 'linhas': rows});
      },
    ),
    ModuleCommand(
      id: 'ajustaHorarios.importarPlanilha',
      title: 'Importar planilha do Ajusta Horários',
      description:
          'Lê .xlsx/.xlsm (modelos ajusta_horarios_bdados ou '
          'ajusta_horarios_banco). Aba Banco: grava a distribuição docente '
          '(mantém as grades). Aba BDados: SUBSTITUI a base de disciplinas '
          'do período e zera a distribuição. Pede confirmação.',
      approval: CommandApproval.required,
      mutates: true,
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._termo,
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
      run: (input, origin) async {
        final t = await term(input);
        final bytes = await GestorPaths.readInput(input.requireString('path'));
        final AjustaHorariosImportacao lida;
        try {
          lida = AjustaHorariosPlanilhas.ler(bytes);
        } on FormatException catch (error) {
          throw CommandException('planilha_invalida', error.message);
        }
        final String message;
        switch (lida) {
          case ImportacaoBanco(:final distribuicao, :final docentes):
            await store.importDistribution(distribuicao, term: t);
            message =
                'Distribuição docente importada: ${distribuicao.length} '
                'turma(s), ${docentes.length} docente(s).';
          case ImportacaoBDados(:final disciplinas):
            await store.replaceBase(disciplinas, term: t);
            message = '${disciplinas.length} disciplina(s) importada(s).';
        }
        if (changes != null) changes.value++;
        return CommandResult.ok(message: '$message Período: $t.');
      },
    ),
    ModuleCommand(
      id: 'ajustaHorarios.exportarGradeCsv',
      title: 'Exportar grade em CSV',
      description:
          'Grade semanal (faixas × dias) em CSV ";" com BOM: de um curso '
          '(program + periods, um bloco por período), de um docente '
          '(teacher) ou de uma sala (room). EaD fica fora da grade.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._termo,
          ...filtro,
          'path': {'type': 'string'},
        },
      },
      run: (input, origin) async {
        validarFiltro(input);
        final t = await term(input);
        final entries = await store.load(term: t);
        final ps = periodos(input);
        final rows = <List<String>>[];
        final String name;
        if (ps.isNotEmpty) {
          final program = (input['program'] as num).toInt();
          for (var i = 0; i < ps.length; i++) {
            if (ps.length > 1) {
              rows.add([ps[i] == 11 ? 'Optativas' : 'Período ${ps[i]}º']);
            }
            rows.addAll(
              AjustaHorariosPlanilhas.linhasGrade(grade(entries, input, ps[i])),
            );
            if (i < ps.length - 1) rows.add([]);
          }
          name = 'grade-curso-$program-periodos-${ps.join('-')}.csv';
        } else {
          final teacher = input.optionalString('teacher');
          final room = input.optionalString('room');
          if (room != null) rows.add(['Sala', room]);
          rows.addAll(
            AjustaHorariosPlanilhas.linhasGrade(grade(entries, input, null)),
          );
          name = room != null ? 'grade-sala-$room.csv' : 'grade-$teacher.csv';
        }
        final path = await GestorPaths.outputPath(
          input.optionalString('path'),
          name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '-'),
          sub: 'ajusta_horarios',
        );
        await File(path).writeAsBytes(AjustaHorariosPlanilhas.csv(rows));
        return CommandResult.ok(
          message: 'Grade exportada.',
          data: {'path': path},
        );
      },
    ),
  ];
}
