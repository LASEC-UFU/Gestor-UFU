import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/orchestrator/application/orq_journal.dart';
import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';
import 'package:gestor_ufu/orchestrator/domain/plan_parser.dart';
import 'package:gestor_ufu/orchestrator/domain/secret_redaction.dart';

Map<String, dynamic> _task(
  String id, {
  List<String> deps = const [],
  String worktree = '',
}) => {
  'id': id,
  'title': 'Tarefa $id',
  'description': 'Fazer $id',
  'acceptanceCriteria': ['$id pronto'],
  'dependsOn': deps,
  'provider': 'claude',
  'worktree': worktree,
};

Matcher _planError(String text) => throwsA(
  isA<OrqPlanException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  group('plano do coordenador', () {
    test('lê o plano em bloco ```json e valida as tarefas', () {
      final reply = parseCoordinatorReply('''
Segue o plano:
```json
{"mode": "plan", "plan": {"title": "Refatorar", "tasks": [
  {"id": "a", "title": "A", "description": "Faz A",
   "acceptanceCriteria": ["ok"], "provider": "codex?", "effort": "high"},
  {"id": "b", "title": "B", "description": "Faz B",
   "acceptanceCriteria": ["ok"], "dependsOn": ["a"], "target": "gestor"}
]}}
```''');
      expect(reply, isA<OrqPlanReply>());
      final plan = reply as OrqPlanReply;
      expect(plan.title, 'Refatorar');
      expect(plan.tasks.map((t) => t.id), ['a', 'b']);
      expect(plan.tasks.first.provider, 'auto'); // provedor desconhecido
      expect(plan.tasks.last.target, OrqTarget.gestor);
      expect(plan.tasks.last.dependsOn, ['a']);
    });

    test('texto sem JSON vira resposta; modo answer também', () {
      expect(
        (parseCoordinatorReply('Olá! Posso ajudar.') as OrqAnswer).answer,
        'Olá! Posso ajudar.',
      );
      expect(
        (parseCoordinatorReply('{"mode":"answer","answer":"Sim"}') as OrqAnswer)
            .answer,
        'Sim',
      );
    });

    test('rejeita JSON inválido, modo desconhecido e plano vazio', () {
      expect(
        () => parseCoordinatorReply('{"mode": "plan", "plan": {'),
        _planError('JSON'),
      );
      expect(() => parseCoordinatorReply('{"mode": "x"}'), _planError('modo'));
      expect(() => validatePlan({'tasks': []}), _planError('entre 1 e 12'));
      expect(
        () => validatePlan({
          'tasks': [for (var i = 0; i < 13; i++) _task('t$i')],
        }),
        _planError('entre 1 e 12'),
      );
    });

    test('exige critérios, IDs únicos e dependências existentes', () {
      expect(
        () => validatePlan({
          'tasks': [
            {..._task('a'), 'acceptanceCriteria': []},
          ],
        }),
        _planError('critérios'),
      );
      expect(
        () => validatePlan({
          'tasks': [_task('a'), _task('a')],
        }),
        _planError('repetido'),
      );
      expect(
        () => validatePlan({
          'tasks': [
            _task('a', deps: ['zz']),
          ],
        }),
        _planError('inexistente'),
      );
    });

    test('detecta dependências circulares', () {
      expect(
        () => validatePlan({
          'tasks': [
            _task('a', deps: ['c']),
            _task('b', deps: ['a']),
            _task('c', deps: ['b']),
          ],
        }),
        _planError('circulares'),
      );
    });

    test('mesma worktree só é aceita se uma tarefa depende da outra', () {
      expect(
        () => validatePlan({
          'tasks': [
            _task('a', worktree: 'feat/x'),
            _task('b', worktree: 'Feat/X'),
          ],
        }),
        _planError('paralelo'),
      );
      final ok = validatePlan({
        'tasks': [
          _task('a', worktree: 'feat/x'),
          _task('b', worktree: 'feat/x', deps: ['a']),
        ],
      });
      expect(ok.tasks, hasLength(2));
    });

    test('branch base inválida e base com checkout atual são recusadas', () {
      expect(
        () => validatePlan({
          'tasks': [
            {..._task('a'), 'base': 'main/../x'},
          ],
        }),
        _planError('branch base'),
      );
      expect(
        () => validatePlan({
          'tasks': [
            {..._task('a', worktree: 'current'), 'base': 'main'},
          ],
        }),
        _planError('checkout atual'),
      );
    });

    test('transferência estruturada e pedido explícito', () {
      final reply = parseCoordinatorReply(
        '{"mode":"handoff","handoff":{"runId":"r1","taskId":"a",'
        '"provider":"chatgpt","context":"continue"}}',
      );
      expect((reply as OrqHandoffReply).handoff.provider, 'chatgpt');
      expect(
        () => parseCoordinatorReply(
          '{"mode":"handoff","handoff":{"runId":"r1","taskId":"a",'
          '"provider":"auto","context":"x"}}',
        ),
        _planError('transferência'),
      );
      expect(explicitHandoffRequest('transfira a tarefa para o Codex'), isTrue);
      expect(explicitHandoffRequest('não transfira a tarefa'), isFalse);
      final task = OrqTask(
        id: 'a',
        title: 'A',
        description: 'A',
        acceptanceCriteria: const ['ok'],
      );
      expect(handoffPermitted(task, 'continue'), isFalse);
      task.status = OrqTaskStatus.failed;
      expect(handoffPermitted(task, 'continue'), isTrue);
    });
  });

  group('redação de segredos', () {
    test('remove chaves, tokens, senhas e blocos de chave privada', () {
      final text = redactSensitiveText(
        'api_key=abc123 senha: "minha senha"'
        '\ntoken: xyz\n'
        'Authorization: Bearer eyJhbGc\n'
        'chave sk-ant-0123456789abcdefABCD e ghp_abcdefghijklmnopqrstuvwx\n'
        '-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----',
      );
      expect(text, isNot(contains('abc123')));
      expect(text, isNot(contains('minha senha')));
      expect(text, isNot(contains('xyz')));
      expect(text, isNot(contains('eyJhbGc')));
      expect(text, isNot(contains('sk-ant-0123')));
      expect(text, isNot(contains('ghp_abc')));
      expect(text, contains('[REDACTED PRIVATE KEY]'));
      expect(redactSensitiveText('x' * 50, max: 10), hasLength(10));
    });
  });

  group('diário', () {
    late OrqJournal journal;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      journal = OrqJournal();
    });

    OrqRun run(String id) => OrqRun(
      id: id,
      title: 'Rodada $id',
      prompt: 'pedido',
      tasks: validatePlan({
        'tasks': [
          _task('a'),
          _task('b', deps: ['a']),
        ],
      }).tasks,
    );

    test('grava e lê rodadas (mais recentes primeiro) sem segredos', () async {
      final r1 = run('r1');
      r1.tasks.first.result = 'feito com password=segredo';
      await journal.saveRun(r1);
      await journal.saveRun(run('r2'));
      expect((await journal.runs()).map((r) => r.id), ['r2', 'r1']);
      final loaded = await journal.loadRun('r1');
      expect(loaded!.tasks.first.result, isNot(contains('segredo')));
      await journal.deleteRun('r2');
      expect(await journal.runIds(), ['r1']);
    });

    test('eventos por tarefa ficam limitados', () async {
      for (var i = 0; i < OrqJournal.maxEventsPerTask + 5; i++) {
        await journal.addEvent('r1', 'a', 'texto', 'evento $i');
      }
      await journal.addEvent('r1', 'b', 'texto', 'outro');
      final a = await journal.events('r1', taskId: 'a');
      expect(a, hasLength(OrqJournal.maxEventsPerTask));
      expect(a.last.detail, 'evento ${OrqJournal.maxEventsPerTask + 4}');
      expect(await journal.events('r1', taskId: 'b'), hasLength(1));
    });

    test('transferência: só um destino consegue reivindicar', () async {
      final h = await journal.createHandoff(
        runId: 'r1',
        taskId: 'a',
        fromProvider: 'claude',
        toProvider: 'chatgpt',
        context: 'continue',
      );
      expect(
        () => journal.createHandoff(
          runId: 'r1',
          taskId: 'a',
          fromProvider: 'claude',
          toProvider: 'gemini',
          context: 'x',
        ),
        throwsStateError,
      );
      final claims = await Future.wait([
        journal.claimHandoff(h.id, 'chatgpt#1'),
        journal.claimHandoff(h.id, 'chatgpt#2'),
      ]);
      expect(claims.where((c) => c.claimed), hasLength(1));
      expect(claims.firstWhere((c) => !c.claimed).reason, 'claimed');
      // Rollback (o agente antigo não parou) e nova reivindicação.
      expect(await journal.releaseClaim(h.id, 'chatgpt#1'), isTrue);
      expect((await journal.claimHandoff(h.id, 'chatgpt#3')).claimed, isTrue);
      expect(await journal.recordSessionStart(h.id, 'chatgpt#3', 's1'), isTrue);
      expect(await journal.recordSessionStart(h.id, 'outro', 's2'), isFalse);
      expect(
        (await journal.handoffs(taskId: 'a')).single.status,
        OrqHandoffStatus.sessionStarted,
      );
    });

    test(
      'transferência expirada ou cancelada não pode ser reivindicada',
      () async {
        final expired = await journal.createHandoff(
          runId: 'r1',
          taskId: 'a',
          fromProvider: 'claude',
          toProvider: 'chatgpt',
          context: 'x',
          ttl: Duration.zero,
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect((await journal.claimHandoff(expired.id, 'c')).reason, 'expired');
        final cancelled = await journal.createHandoff(
          runId: 'r1',
          taskId: 'b',
          fromProvider: 'claude',
          toProvider: 'chatgpt',
          context: 'x',
        );
        expect(await journal.cancelHandoff(cancelled.id), isTrue);
        expect(
          (await journal.claimHandoff(cancelled.id, 'c')).reason,
          'cancelled',
        );
      },
    );

    test('pacote de continuidade traz objetivo, critérios e eventos', () async {
      final r = run('r1');
      final task = r.tasks.first..error = 'falhou; password=abc';
      await journal.addEvent('r1', 'a', 'ferramenta', 'editou main.dart');
      final packet = await journal.continuityPacket(r, task);
      expect(packet, contains('Fazer a'));
      expect(packet, contains('a pronto'));
      expect(packet, contains('editou main.dart'));
      expect(packet, isNot(contains('abc')));
    });
  });
}
