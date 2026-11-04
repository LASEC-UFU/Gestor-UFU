import 'package:gestor_ufu/data/word_table_generator.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generateTsv filters practice rows and selected columns', () {
    final config = _sampleConfig();

    final text = WordTableGenerator.generateTsv(
      config,
      const WordTableOptions(
        preset: WordTablePreset.practice,
        columns: {
          WordTableColumn.date,
          WordTableColumn.modality,
          WordTableColumn.classGroup,
          WordTableColumn.taughtSubject,
        },
      ),
    );

    expect(text, contains('Data\tModalidade\tTurma\tMatéria Lecionada'));
    expect(text, contains('16/02/2026\tPrática\tT\tPrática 01 - Bancada'));
    expect(text, isNot(contains('Teoria 01')));
  });

  test('generateHtml marks theory and special rows', () {
    final config = _sampleConfig();

    final html = WordTableGenerator.generateHtml(
      config,
      const WordTableOptions(
        preset: WordTablePreset.theory,
        columns: {WordTableColumn.date, WordTableColumn.taughtSubject},
        onlyMatchingModality: false,
      ),
    );

    expect(html, contains('class="theory special"'));
    expect(html, contains('2ª Prova'));
  });

  test('resolves date macros and strips html markup', () {
    final now = DateTime(2026);
    final config = CourseConfig(
      id: 'cfg-html',
      name: 'Teste HTML',
      semesterStartDate: now,
      createdAt: now,
      updatedAt: now,
      sections: [
        SectionEntry(
          id: 's1',
          orderIndex: 1,
          name: 'BLOCO 01 (Inicia: <DD/MM/YYYY>)',
          referenceDaysOffset: 0,
          date: DateTime(2026, 2, 16),
          offsetDays: 0,
          moodleDescription:
              '<p>Avaliação com <strong>presença</strong> em <DD/MM/YYYY + 7>.</p>',
        ),
      ],
    );

    final text = WordTableGenerator.generateTsv(
      config,
      const WordTableOptions(
        preset: WordTablePreset.all,
        columns: {
          WordTableColumn.date,
          WordTableColumn.taughtSubject,
          WordTableColumn.moodleDescription,
        },
      ),
    );

    expect(text, contains('BLOCO 01 (Inicia: 16/02/2026)'));
    expect(text, contains('Avaliação com presença em 23/02/2026.'));
    expect(text, isNot(contains('<strong>')));
    expect(text, isNot(contains('<DD/MM/YYYY')));
  });

  test('uses explicit activity modality before text inference', () {
    final now = DateTime(2026);
    final config = CourseConfig(
      id: 'cfg-modality',
      name: 'Teste Modalidade',
      semesterStartDate: now,
      createdAt: now,
      updatedAt: now,
      sections: [
        SectionEntry(
          id: 's1',
          orderIndex: 1,
          name: 'BLOCO 01',
          referenceDaysOffset: 0,
          date: DateTime(2026, 2, 16),
          offsetDays: 0,
          activities: [
            ActivityEntry(
              id: 'a1',
              name: 'Aula de laboratório',
              activityType: 'URL',
              modality: 'Prática',
            ),
            ActivityEntry(
              id: 'a2',
              name: 'Aula de quadro',
              activityType: 'URL',
              modality: 'Teórica',
            ),
          ],
        ),
      ],
    );

    final text = WordTableGenerator.generateTsv(
      config,
      const WordTableOptions(
        preset: WordTablePreset.practice,
        columns: {
          WordTableColumn.modality,
          WordTableColumn.taughtSubject,
          WordTableColumn.activities,
        },
      ),
    );

    expect(text, contains('Prática\tBLOCO 01\tAula de laboratório'));
    expect(text, isNot(contains('Aula de quadro')));
  });

  test('splits activities by their real opening date', () {
    final now = DateTime(2026);
    final config = CourseConfig(
      id: 'cfg-dates',
      name: 'Teste Datas',
      semesterStartDate: now,
      createdAt: now,
      updatedAt: now,
      sections: [
        SectionEntry(
          id: 's1',
          orderIndex: 1,
          name: 'Teorica Quarta 02',
          referenceDaysOffset: 0,
          date: DateTime(2026, 4, 29),
          offsetDays: 0,
          activities: [
            ActivityEntry(
              id: 'a1',
              name: 'Questionario 02 (Inicia: <DD/MM/YYYY>)',
              activityType: 'Quiz',
              modality: 'Teorica',
              openOffsetDays: 0,
            ),
            ActivityEntry(
              id: 'a2',
              name: 'Teorica Quinta 02 (Realizar-se-a: <DD/MM/YYYY>)',
              activityType: 'URL',
              modality: 'Teorica',
              openOffsetDays: 1,
            ),
          ],
        ),
      ],
    );

    final text = WordTableGenerator.generateTsv(
      config,
      const WordTableOptions(
        preset: WordTablePreset.theory,
        columns: {WordTableColumn.date, WordTableColumn.activities},
      ),
    );

    expect(text, contains('29/04/2026\tQuestionario 02 (Inicia: 29/04/2026)'));
    expect(
      text,
      contains('30/04/2026\tTeorica Quinta 02 (Realizar-se-a: 30/04/2026)'),
    );
    expect(
      text,
      isNot(
        contains(
          '29/04/2026\tQuestionario 02 (Inicia: 29/04/2026) | Teorica Quinta',
        ),
      ),
    );
  });

  test('splits activities by dates written in the activity text', () {
    final now = DateTime(2026);
    final config = CourseConfig(
      id: 'cfg-text-dates',
      name: 'Teste Datas no Texto',
      semesterStartDate: now,
      createdAt: now,
      updatedAt: now,
      sections: [
        SectionEntry(
          id: 's1',
          orderIndex: 1,
          name: 'Teorica Quarta 02',
          referenceDaysOffset: 0,
          date: DateTime(2026, 4, 29),
          offsetDays: 0,
          activities: [
            ActivityEntry(
              id: 'a1',
              name:
                  'Questionario 02: Grafia Correta (Inicia: 29/04/2026 e termina: 06/05/2026)',
              activityType: 'Quiz',
              modality: 'Teorica',
            ),
            ActivityEntry(
              id: 'a2',
              name:
                  'Teorica Quinta 02: GPIO e Debug na ESP32 (Realizar-se-a: 30/04/2026)',
              activityType: 'URL',
              modality: 'Teorica',
            ),
          ],
        ),
      ],
    );

    final text = WordTableGenerator.generateTsv(
      config,
      const WordTableOptions(
        preset: WordTablePreset.theory,
        columns: {WordTableColumn.date, WordTableColumn.activities},
      ),
    );

    expect(text, contains('29/04/2026\tQuestionario 02'));
    expect(text, contains('30/04/2026\tTeorica Quinta 02'));
    expect(text, isNot(contains('| Teorica Quinta 02')));
  });
}

CourseConfig _sampleConfig() {
  final now = DateTime(2026);
  return CourseConfig(
    id: 'cfg',
    name: 'Teste',
    semesterStartDate: now,
    createdAt: now,
    updatedAt: now,
    sections: [
      SectionEntry(
        id: 's1',
        orderIndex: 1,
        name: 'Prática 01 - Bancada',
        referenceDaysOffset: 0,
        date: DateTime(2026, 2, 16),
        offsetDays: 0,
      ),
      SectionEntry(
        id: 's2',
        orderIndex: 2,
        name: 'Teoria 01 - Segurança',
        referenceDaysOffset: 1,
        date: DateTime(2026, 2, 17),
        offsetDays: 1,
      ),
      SectionEntry(
        id: 's3',
        orderIndex: 3,
        name: 'Teórica - 2ª Prova',
        referenceDaysOffset: 2,
        date: DateTime(2026, 2, 18),
        offsetDays: 2,
      ),
    ],
  );
}
