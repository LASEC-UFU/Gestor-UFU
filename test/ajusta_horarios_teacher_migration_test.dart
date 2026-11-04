import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/data/services/ajusta_horarios_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'keeps legacy teachers and correlates them to modality classes',
    () async {
      final term = AjustaHorariosStore.defaultTerm;
      final token = base64Url.encode(utf8.encode(term)).replaceAll('=', '');
      final scheduleKey = 'ajusta_horarios_disciplinas_2026_2_ca_v2_$token';
      SharedPreferences.setMockInitialValues({
        'ajusta_horarios_importacao_2026_2_ca_v2': true,
        'ajusta_horarios_migracao_periodos_v1': true,
        'ajusta_horarios_migracao_grupos_modalidade_v1': true,
        'ajusta_horarios_limpeza_dados_v1': true,
        scheduleKey: jsonEncode([
          {
            'id': 'subject-theory',
            'subjectId': 'subject',
            'modality': 'theory',
            'code': 'TEST101',
            'acronym': 'TST',
            'name': 'Disciplina de teste',
            'className': 'T1',
            'teacher': 'Ana Docente',
            'coTeachers': ['Bruno Docente'],
            'room': '',
            'coursePeriods': [
              {'program': 2, 'period': 1},
            ],
            'slots': [],
            'theoryHours': 2,
            'practiceHours': 0,
          },
          {
            'id': 'subject-practice',
            'subjectId': 'subject',
            'modality': 'practice',
            'code': 'TEST101',
            'acronym': 'TST',
            'name': 'Disciplina de teste',
            'className': 'P1',
            'teacher': '',
            'coTeachers': [],
            'teachers': [],
            'room': '',
            'coursePeriods': [
              {'program': 2, 'period': 1},
            ],
            'slots': [],
            'theoryHours': 0,
            'practiceHours': 2,
          },
        ]),
      });

      final entries = await AjustaHorariosStore().load(term: term);

      expect(entries, hasLength(2));
      expect(entries[0].teacherNames, ['Ana Docente', 'Bruno Docente']);
      expect(entries[1].teacherNames, ['Ana Docente', 'Bruno Docente']);

      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(scheduleKey)!) as List;
      expect(saved[0], contains('teachers'));
      expect(saved[0], isNot(contains('teacher')));
      expect(saved[1]['teachers'], ['Ana Docente', 'Bruno Docente']);
    },
  );
}
