import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';
import 'package:gestor_ufu/modules/equivalencia/pages/equivalencia_history_window.dart';

const calculus = Subject(
  code: 'CAL1',
  name: 'Cálculo I',
  theoretical: 60,
  practical: 0,
  period: '1',
);
const physics = Subject(
  code: 'FIS1',
  name: 'Física I',
  theoretical: 60,
  practical: 0,
  period: '1',
);
const block = EquivalenceBlock(
  id: 'b1',
  period: '1',
  current: [calculus],
  prior: [physics],
);

EquivalenceCase analysis({
  List<EquivalenceBlock> blocks = const [block],
  List<HistoricalSubject> history = const [],
}) => EquivalenceCase(
  id: 'a1',
  student: 'Ana',
  studentId: '',
  currentCurriculumId: 'c1',
  priorCurriculumId: '',
  status: 'Em análise',
  notes: '',
  blocks: blocks,
  history: history,
);

void main() {
  test('dispensa mantém a coluna do currículo mesmo com semestre no bloco', () {
    const imported = Subject(
      code: 'CAL1',
      name: 'Cálculo I importado',
      theoretical: 60,
      practical: 0,
      period: '2018/1º Sem',
    );
    final item = analysis(
      blocks: const [
        EquivalenceBlock(
          id: 'importado',
          period: '2018/1º Sem',
          current: [imported],
          prior: [physics],
        ),
      ],
      history: const [HistoricalSubject(subject: imported)],
    );
    final entries = item.historyFor(subjects: [calculus, physics]);
    expect(entries, hasLength(2));
    expect(entries.first.subject, same(calculus));
    expect(entries.first.subject.period, '1');
    expect(entries.first.status, 'Dispensado');
    expect(entries.map((e) => e.subject.period), everyElement('1'));
  });

  test(
    'blocos antigos viram dispensas sem alterar aprovações independentes',
    () {
      final item = EquivalenceCase.fromJson(
        analysis(
          history: const [
            HistoricalSubject(subject: calculus, status: 'Aprovado'),
            HistoricalSubject(subject: physics, status: 'Aprovado'),
          ],
        ).toJson(),
      );
      expect(item.history.map((e) => e.status), ['Dispensado', 'Aprovado']);
      expect(
        EquivalenceCase.fromJson(item.toJson()).history.first.status,
        'Dispensado',
      );
      final removed = item.copyWith(blocks: []).historyFor();
      expect(removed.map((e) => e.status), ['Não cursada', 'Aprovado']);
    },
  );

  test('azul depende dos blocos e matrícula antiga deixa de bloquear', () {
    final old = HistoricalSubject.fromJson({
      'subject': physics.toJson(),
      'status': 'Matriculado',
    });
    expect(old.status, 'Não cursada');
    final entries = analysis(history: [old]).historyFor();
    expect(
      entries.singleWhere((e) => e.subject.code == 'CAL1').status,
      'Dispensado',
    );
    expect(
      analysis(
        blocks: [],
        history: const [
          HistoricalSubject(subject: calculus, status: 'Dispensado'),
        ],
      ).historyFor().single.status,
      'Não cursada',
    );
  });

  testWidgets('histórico bloqueia azul e alterna somente cinza e verde', (
    tester,
  ) async {
    var entries = analysis().historyFor(subjects: [calculus, physics]);
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => EquivalenciaHistoryGrid(
              student: 'Ana',
              entries: entries,
              onChanged: (updated) async {
                saves++;
                setState(() => entries = updated);
              },
            ),
          ),
        ),
      ),
    );
    expect(find.text('Matriculado'), findsNothing);
    final blueCard = tester.widget<Card>(
      find.ancestor(of: find.text('CAL1'), matching: find.byType(Card)),
    );
    expect(blueCard.color, Colors.blue.shade300);
    await tester.tap(find.text('CAL1'));
    await tester.pump();
    expect(saves, 0);
    await tester.tap(find.text('FIS1'));
    await tester.pump();
    expect(entries.last.status, 'Aprovado');
    await tester.tap(find.text('FIS1'));
    await tester.pump();
    expect(entries.last.status, 'Não cursada');
    expect(saves, 2);
  });
}
