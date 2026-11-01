import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:config_moodle/domain/entities/ajusta_horarios.dart';

class AjustaHorariosStore {
  static const _storageKey = 'ajusta_horarios_disciplinas_2026_2_ca_v2';
  static const _initialResetKey = 'ajusta_horarios_importacao_2026_2_ca_v2';
  static const _termStorageMigrationKey =
      'ajusta_horarios_migracao_periodos_v1';
  static const _termsKey = 'ajusta_horarios_periodos_letivos';
  static const defaultTerm = '2\u00ba semestre de 2026';

  String _keyForTerm(String term) {
    final token = base64Url
        .encode(utf8.encode(term.trim()))
        .replaceAll('=', '');
    return '${_storageKey}_$token';
  }

  Future<List<HorarioDisciplina>> load({String term = defaultTerm}) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_initialResetKey) != true) {
      final seed = await _loadSeed();
      await save(seed, term: defaultTerm);
      await prefs.remove('ajusta_horarios_disciplinas_v1');
      await prefs.remove('ajusta_horarios_disciplinas_2026_2_ca_v1');
      await prefs.remove(_storageKey);
      await prefs.remove('ajusta_horarios_distribuicao_docente');
      await prefs.remove('ajusta_horarios_docentes_ocultos_distribuicao');
      await prefs.setString(
        'ajusta_horarios_cursos',
        '{"2":"Engenharia de Controle e Automa\u00e7\u00e3o"}',
      );
      await prefs.setInt('ajusta_horarios_curso_selecionado', 2);
      await prefs.setInt('ajusta_horarios_periodo_selecionado', 1);
      await prefs.setInt('ajusta_horarios_visao_selecionada', 0);
      await prefs.setString('ajusta_horarios_periodo_letivo', defaultTerm);
      await prefs.setStringList(_termsKey, [defaultTerm]);
      await prefs.remove('ajusta_horarios_docente_selecionado');
      for (final key in const [
        'curso_y',
        'curso_x',
        'docente_y',
        'docente_x',
      ]) {
        await prefs.remove('ajusta_horarios_grade_scroll_$key');
      }
      await prefs.setBool(_initialResetKey, true);
      return seed;
    }

    if (prefs.getBool(_termStorageMigrationKey) != true) {
      final previous = prefs.getString(_storageKey);
      final savedActive = prefs.getString('ajusta_horarios_periodo_letivo');
      final active = savedActive?.trim().isNotEmpty == true
          ? savedActive!.trim()
          : defaultTerm;
      if (previous != null) {
        await prefs.setString(_keyForTerm(active), previous);
      }
      await prefs.remove(_storageKey);
      final terms = prefs.getStringList(_termsKey) ?? const <String>[];
      if (terms.isEmpty) {
        await prefs.setStringList(_termsKey, [active]);
        await prefs.setString('ajusta_horarios_periodo_letivo', active);
      }
      await prefs.setBool(_termStorageMigrationKey, true);
    }

    final stored = prefs.getString(_keyForTerm(term));
    if (stored != null) {
      final data = jsonDecode(stored) as List;
      return data
          .map(
            (row) => HorarioDisciplina.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
    }

    return const <HorarioDisciplina>[];
  }

  Future<List<HorarioDisciplina>> _loadSeed() async {
    final seed =
        jsonDecode(
              await rootBundle.loadString('assets/adjust_schedule/seed.json'),
            )
            as List;
    return seed
        .map(
          (row) =>
              HorarioDisciplina.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  Future<void> save(
    List<HorarioDisciplina> entries, {
    String term = defaultTerm,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyForTerm(term),
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }
}
