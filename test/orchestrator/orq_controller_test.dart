import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/data/services/ai_agent/agent_backends.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/orchestrator/application/git_worktrees.dart';
import 'package:gestor_ufu/orchestrator/application/orq_controller.dart';
import 'package:gestor_ufu/orchestrator/application/orq_prompts.dart';
import 'package:gestor_ufu/orchestrator/application/orq_settings.dart';
import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';
import 'package:gestor_ufu/platform/services/session_lease.dart';

/// Agente falso: responde com [reply] (ou espera [gate] para terminar).
class FakeBackend extends AgentBackend {
  FakeBackend(this.request, this._reply, {this.gate, this.onSend});

  final OrqBackendRequest request;
  final String Function() _reply;
  String get reply => _reply();
  final Completer<void>? gate;
  final void Function(FakeBackend backend, String prompt)? onSend;
  final prompts = <String>[];
  Map<String, dynamic> restored = const {};
  bool cancelled = false;

  @override
  String get label => 'fake-${request.provider.name}';

  @override
  Future<String> verify() async => 'ok';

  @override
  Future<List<AgentModel>> listModels() async => const [];

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {
    prompts.add(prompt);
    onSend?.call(this, prompt);
    emit(const AgentToolEvent('1', 'Read', {'file_path': 'main.dart'}));
    if (gate != null) {
      await gate!.future;
      if (cancelled) throw AgentException('Cancelado.');
    }
    emit(AgentTextDeltaEvent(reply));
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }

  @override
  Map<String, dynamic> saveState() => {'session': label};

  @override
  void restoreState(Map<String, dynamic> state) => restored = state;

  @override
  void reset() {}
}

String _plan(List<Map<String, dynamic>> tasks) => jsonEncode({
  'mode': 'plan',
  'plan': {'title': 'Plano', 'tasks': tasks},
});

Map<String, dynamic> _task(
  String id, {
  List<String> deps = const [],
  String provider = 'claude',
}) => {
  'id': id,
  'title': 'Tarefa $id',
  'description': 'Fazer $id',
  'acceptanceCriteria': ['$id ok'],
  'dependsOn': deps,
  'provider': provider,
  'target': 'gestor',
};

Future<void> _settle(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'estado esperado não alcançado');
}

void main() {
  late List<FakeBackend> created;
  late String coordinatorReply;
  late Map<String, Completer<void>> gates;
  late Directory storage;

  OrqController controller() => OrqController(
    machine: 'pc-teste',
    storageRoot: storage.path,
    factory: (request) async {
      final isCoordinator = request.label == 'Coordenador';
      final taskId = RegExp(
        r'Tarefa (\S+)',
      ).firstMatch(request.label)?.group(1);
      final backend = FakeBackend(
        request,
        () => isCoordinator ? coordinatorReply : 'feito ${taskId ?? ''}',
        gate: taskId == null ? null : gates[taskId],
      );
      created.add(backend);
      return backend;
    },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    created = [];
    gates = {};
    storage = await Directory.systemTemp.createTemp('orq');
  });

  tearDown(() => storage.delete(recursive: true));

  test('coordenador propõe plano; dependências e revisão', () async {
    final orq = controller();
    await orq.load();
    coordinatorReply = _plan([
      _task('a'),
      _task('b', deps: ['a']),
    ]);
    await orq.send('organize os horários');
    expect(orq.runs.single.status, OrqRunStatus.proposed);
    expect(created.single.request.access, AgentAccess.plan);
    expect(created.single.prompts.single, contains('organize os horários'));

    final run = orq.runs.single;
    await orq.approvePlan(run.id);
    await _settle(() => run.task('a')!.status == OrqTaskStatus.awaitingReview);
    // b espera a revisão de a.
    expect(run.task('b')!.status, OrqTaskStatus.queued);
    expect(run.task('a')!.result, 'feito a');
    final worker = created.firstWhere(
      (b) => b.request.label.startsWith('Tarefa a '),
    );
    expect(worker.request.access, AgentAccess.gestor);
    expect(worker.prompts.single, contains('a ok'));

    await orq.review(run.id, 'a', complete: true);
    await _settle(() => run.task('b')!.status == OrqTaskStatus.awaitingReview);
    await orq.review(run.id, 'b', complete: true);
    await _settle(() => run.status == OrqRunStatus.complete);
    final events = await orq.journal.events(run.id, taskId: 'a');
    expect(events.map((e) => e.event), contains('ferramenta'));
    orq.dispose();
  });

  test('paralelismo 2 e cancelar só a tarefa A', () async {
    final orq = controller();
    await orq.load();
    orq.settings.maxParallel = 2;
    for (final id in ['a', 'b', 'c']) {
      gates[id] = Completer<void>();
    }
    coordinatorReply = _plan([_task('a'), _task('b'), _task('c')]);
    await orq.send('três tarefas');
    final run = orq.runs.single;
    await orq.approvePlan(run.id);
    await _settle(
      () =>
          run.task('a')!.status == OrqTaskStatus.running &&
          run.task('b')!.status == OrqTaskStatus.running,
    );
    expect(run.task('c')!.status, OrqTaskStatus.queued);
    expect(orq.activeCount, 2);

    await orq.cancelTask(run.id, 'a');
    await _settle(() => run.task('a')!.status == OrqTaskStatus.cancelled);
    expect(run.task('b')!.status, OrqTaskStatus.running);
    // A vaga liberada inicia c.
    await _settle(() => run.task('c')!.status == OrqTaskStatus.running);
    gates['b']!.complete();
    gates['c']!.complete();
    await _settle(
      () =>
          run.task('b')!.status == OrqTaskStatus.awaitingReview &&
          run.task('c')!.status == OrqTaskStatus.awaitingReview,
    );
    orq.dispose();
  });

  test('pedir ajustes continua a mesma sessão com a orientação', () async {
    final orq = controller();
    await orq.load();
    coordinatorReply = _plan([_task('a')]);
    await orq.send('uma tarefa');
    final run = orq.runs.single;
    await orq.approvePlan(run.id);
    await _settle(() => run.task('a')!.status == OrqTaskStatus.awaitingReview);
    await orq.requestChanges(run.id, 'a', 'use outro nome');
    await _settle(
      () =>
          run.task('a')!.status == OrqTaskStatus.awaitingReview &&
          run.task('a')!.attempts == 2,
    );
    final second = created.last;
    expect(second.restored, {'session': 'fake-claude'});
    expect(second.prompts.single, contains('use outro nome'));
    orq.dispose();
  });

  test('transferência para outro agente com pacote de continuidade', () async {
    final orq = controller();
    await orq.load();
    gates['a'] = Completer<void>();
    coordinatorReply = _plan([_task('a')]);
    await orq.send('uma tarefa');
    final run = orq.runs.single;
    await orq.approvePlan(run.id);
    await _settle(() => run.task('a')!.status == OrqTaskStatus.running);
    gates.remove('a');
    await orq.handoff(run.id, 'a', 'chatgpt', context: 'continue do passo 2');
    await _settle(() => run.task('a')!.status == OrqTaskStatus.awaitingReview);
    final recipient = created.last;
    expect(recipient.request.provider, AgentProvider.chatgpt);
    expect(recipient.prompts.single, contains('continue do passo 2'));
    expect(recipient.restored, isEmpty);
    final handoffs = await orq.journal.handoffs(taskId: 'a');
    expect(handoffs.single.status.name, 'sessionStarted');
    orq.dispose();
  });

  test('tarefas executando quando o app fechou ficam paradas', () async {
    final orq = controller();
    await orq.load();
    coordinatorReply = _plan([_task('a')]);
    await orq.send('uma tarefa');
    final run = orq.runs.single
      ..status = OrqRunStatus.running
      ..tasks.single.status = OrqTaskStatus.running
      ..tasks.single.machine = 'pc-teste';
    await orq.journal.saveRun(run);
    orq.dispose();
    final reopened = controller();
    await reopened.load();
    expect(reopened.runs.single.tasks.single.status, OrqTaskStatus.parked);
    reopened.dispose();
  });

  test('perfis: conta da tarefa, agente errado e limite por perfil', () async {
    final orq = controller();
    await orq.load();
    orq.settings
      ..maxParallel = 3
      ..profiles = [
        const OrqProfile(id: 'claude-trab', provider: 'claude', name: 'Trab'),
      ];
    gates['a'] = Completer<void>();
    gates['b'] = Completer<void>();
    coordinatorReply = _plan([
      {..._task('c', provider: 'chatgpt'), 'profileId': 'claude-trab'},
    ]);
    await orq.send('perfil errado');
    await expectLater(
      () => orq.approvePlan(orq.runs.first.id),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('não do chatgpt'),
        ),
      ),
    );
    coordinatorReply = _plan([
      {..._task('a'), 'profileId': 'claude-trab'},
      {..._task('b'), 'profileId': 'claude-trab'},
    ]);
    await orq.send('perfis');
    final run = orq.runs.first;
    await orq.approvePlan(run.id);
    await _settle(() => run.task('a')!.status == OrqTaskStatus.running);
    // Limite de 1 por perfil: b espera a terminar.
    expect(run.task('b')!.status, OrqTaskStatus.queued);
    final worker = created.firstWhere(
      (b) => b.request.label.startsWith('Tarefa a '),
    );
    expect(
      worker.request.environment['CLAUDE_CONFIG_DIR'],
      endsWith('claude-trab'),
    );
    gates['a']!.complete();
    await _settle(() => run.task('b')!.status == OrqTaskStatus.running);
    gates['b']!.complete();
    orq.dispose();
  });

  test('perfil do Codex usa CODEX_HOME com credenciais em arquivo', () async {
    const profile = OrqProfile(
      id: 'teste-codex',
      provider: 'chatgpt',
      name: 'T',
    );
    expect(profile.environment.keys, ['CODEX_HOME']);
    await profile.prepare();
    final config = File(p.join(profile.directory, 'config.toml'));
    expect(
      config.readAsStringSync(),
      contains('cli_auth_credentials_store = "file"'),
    );
    await Directory(profile.directory).delete(recursive: true);
  });

  test(
    'coordenador: contexto fixo uma vez, skill, ferramentas e esforço',
    () async {
      final orq = controller()
        ..modelCatalog = () async => {
          'claude': [
            'claude-haiku-5-5',
            'claude-sonnet-5-5',
            'claude-opus-5-5',
          ],
        };
      await orq.load();
      coordinatorReply = '{"mode":"answer","answer":"ok"}';
      await orq.send('primeira');
      await orq.send('segunda');
      final coordinator = created.single;
      expect(
        coordinator.request.systemPrompt,
        contains('Roteamento e economia'),
      );
      expect(coordinator.request.toolFilter, orqCoordinatorTools);
      expect(coordinator.request.effort, 'medium');
      expect(coordinator.request.gestorGuide, isFalse);
      final first = coordinator.prompts[0];
      final second = coordinator.prompts[1];
      expect(first, contains('Agentes trabalhadores permitidos'));
      expect(first, contains('claude-haiku-5-5 (econômico)'));
      expect(first, contains('claude-opus-5-5 (forte)'));
      expect(second, isNot(contains('Agentes trabalhadores permitidos')));
      expect(second, contains('Pedido do usuário:\nsegunda'));
      // Nova conversa: o contexto volta a ser enviado.
      await orq.newConversation();
      await orq.send('terceira');
      expect(
        created.last.prompts.single,
        contains('Agentes trabalhadores permitidos'),
      );
      orq.dispose();
    },
  );

  test('trabalhador de projeto recebe só ferramentas de arquivo', () async {
    final repo = await Directory.systemTemp.createTemp('orq_proj');
    final orq = controller();
    await orq.load();
    orq.settings.projectPath = repo.path;
    coordinatorReply = _plan([
      {..._task('p'), 'target': 'project', 'worktree': 'current'},
      _task('g'),
    ]);
    await orq.send('duas');
    final run = orq.runs.first;
    await orq.approvePlan(run.id);
    await _settle(
      () => run.tasks.every((t) => t.status == OrqTaskStatus.awaitingReview),
    );
    final project = created.firstWhere(
      (b) => b.request.label.startsWith('Tarefa p '),
    );
    final gestor = created.firstWhere(
      (b) => b.request.label.startsWith('Tarefa g '),
    );
    expect(project.request.toolFilter, orqProjectWorkerTools);
    expect(project.request.gestorGuide, isFalse);
    expect(gestor.request.toolFilter, isNull);
    expect(gestor.request.gestorGuide, isTrue);
    orq.dispose();
    await repo.delete(recursive: true);
  });

  test('faixa de custo pelo nome do modelo', () {
    expect(modelTier('claude-haiku-5-5'), 'econômico');
    expect(modelTier('gpt-5.6-luna'), 'econômico');
    expect(modelTier('gemini-3-flash'), 'econômico');
    expect(modelTier('gpt-5-codex-mini'), 'econômico');
    expect(modelTier('claude-sonnet-5-5'), 'padrão');
    expect(modelTier('claude-opus-5-5'), 'forte');
    expect(modelTier('gemini-3.1-pro'), 'forte');
    expect(modelTier('gpt-5.6-terra'), 'forte');
    expect(modelTier('gemini-3.5-flash'), 'econômico');
    expect(modelTier('gpt-5-codex-max'), 'forte');
    expect(modelTier('gpt-5-codex'), 'padrão');
  });

  group('dois computadores (D6)', () {
    late Directory folder;
    setUp(() async => folder = await Directory.systemTemp.createTemp('sess'));
    tearDown(() async {
      // As posses são liberadas em segundo plano ao descartar.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // Pasta temporária: o sistema limpa depois.
      }
    });

    SessionLease leaseFor(String name) =>
        SessionLease(() async => folder.path, machine: name);

    OrqController pc(String name, SessionLease lease) => OrqController(
      machine: name,
      storageRoot: storage.path,
      lease: lease,
      factory: (request) async {
        final taskId = RegExp(
          r'Tarefa (\S+)',
        ).firstMatch(request.label)?.group(1);
        final backend = FakeBackend(
          request,
          () => request.label == 'Coordenador'
              ? coordinatorReply
              : 'feito ${taskId ?? ''} em $name',
          gate: taskId == null ? null : gates['$name/$taskId'],
        );
        created.add(backend);
        return backend;
      },
    );

    test('posse: outro computador vê, assume e o primeiro perde', () async {
      final a = leaseFor('A');
      final b = leaseFor('B');
      final lost = <String>[];
      await a.take('agente', 'c1', onLost: lost.add);
      expect((await b.openElsewhere('agente', 'c1'))!.machine, 'A');
      expect(await a.openElsewhere('agente', 'c1'), isNull);
      await b.take('agente', 'c1', onLost: (_) {});
      await a.heartbeat();
      expect(lost, ['B']);
      expect(a.holds('agente', 'c1'), isFalse);
      // Posse abandonada (sem batida há mais de 3 min) fica livre.
      File(p.join(folder.path, 'sessoes', 'agente-c2.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'computador': 'A',
            'batida': DateTime.now()
                .toUtc()
                .subtract(const Duration(minutes: 5))
                .toIso8601String(),
          }),
        );
      expect(await b.openElsewhere('agente', 'c2'), isNull);
      a.dispose();
      b.dispose();
    });

    test(
      'conversa do coordenador: só visualizar, assumir, outro para',
      () async {
        final leaseA = leaseFor('A');
        final leaseB = leaseFor('B');
        final a = pc('A', leaseA);
        await a.load();
        coordinatorReply = '{"mode":"answer","answer":"oi"}';
        await a.send('olá do A');
        final conversation = a.chatId;

        final b = pc('B', leaseB);
        await b.load();
        expect(b.chatId, isNot(conversation), reason: 'não rouba a conversa');
        final list = await b.conversations();
        expect(list.single.openIn, 'A');

        await b.openConversation(conversation);
        expect(b.chatReadOnlyBy, 'A');
        expect(b.chat.first.text, 'olá do A');
        final sentBefore = created.length;
        await b.send('tentativa');
        expect(created.length, sentBefore, reason: 'não chama o coordenador');

        await b.takeOverConversation();
        expect(b.chatReadOnlyBy, isNull);
        await leaseA.heartbeat();
        expect(a.chatReadOnlyBy, 'B');
        await b.send('continuando no B');
        // A sessão do CLI era do A: o coordenador do B recebe o histórico.
        expect(created.last.prompts.last, contains('olá do A'));
        a.dispose();
        b.dispose();
      },
    );

    test(
      'rodada: dono executa, outro assume e continua com o histórico',
      () async {
        final leaseA = leaseFor('A');
        final leaseB = leaseFor('B');
        final a = pc('A', leaseA);
        await a.load();
        gates['A/t1'] = Completer<void>();
        coordinatorReply = _plan([_task('t1')]);
        await a.send('uma tarefa');
        final run = a.runs.first;
        await a.approvePlan(run.id);
        await _settle(() => run.task('t1')!.status == OrqTaskStatus.running);

        final b = pc('B', leaseB);
        await b.load();
        final runB = b.runs.first;
        expect(b.runHolders[run.id], 'A');
        await expectLater(
          () => b.retryTask(run.id, 't1'),
          throwsA(
            isA<StateError>().having((e) => e.message, 'm', contains('em A')),
          ),
        );

        await b.takeOverRun(run.id);
        expect(b.runs.first.task('t1')!.status, OrqTaskStatus.parked);
        await leaseA.heartbeat();
        await _settle(() => a.activeCount == 0);
        expect(a.runHolders[run.id], 'B');

        await b.retryTask(runB.id, 't1');
        await _settle(
          () => b.runs.first.task('t1')!.status == OrqTaskStatus.awaitingReview,
        );
        final worker = created.last;
        expect(worker.prompts.single, contains('começou em A'));
        expect(
          worker.restored,
          isEmpty,
          reason: 'sessão local do A não existe aqui',
        );
        expect(b.runs.first.task('t1')!.result, 'feito t1 em B');
        a.dispose();
        b.dispose();
      },
    );
  });

  group('git', () {
    late Directory repo;

    Future<void> git(List<String> args) => GitWorktrees.git(args, repo.path);

    setUp(() async {
      repo = await Directory.systemTemp.createTemp('orq_repo');
      await git(['init', '-q', '-b', 'main']);
      await git(['config', 'user.email', 't@t']);
      await git(['config', 'user.name', 'T']);
      File(p.join(repo.path, 'a.txt')).writeAsStringSync('linha 1\n');
      File(p.join(repo.path, '.gitignore')).writeAsStringSync('.env\nlogs/\n');
      File(p.join(repo.path, '.env')).writeAsStringSync('SEGREDO=1');
      Directory(p.join(repo.path, 'logs')).createSync();
      File(p.join(repo.path, 'logs', 'x.log')).writeAsStringSync('x');
      File(p.join(repo.path, '.worktreeinclude')).writeAsStringSync('.env\n');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'inicial']);
    });

    tearDown(() async {
      try {
        await repo.delete(recursive: true);
      } on Object {
        // Arquivos do Git podem demorar a liberar no Windows.
      }
    });

    test('worktree isolada, .worktreeinclude, alterações e diff', () async {
      final worktrees = GitWorktrees(storage.path);
      final wt = await worktrees.open(repo.path, runId: 'r1', taskId: 'a');
      expect(wt.branch, 'orquestrador/r1-a-1');
      expect(wt.includedFiles, ['.env']);
      expect(File(p.join(wt.path, 'logs', 'x.log')).existsSync(), isFalse);
      expect(
        () => worktrees.open(repo.path, runId: 'r1', taskId: 'a'),
        throwsA(isA<GitException>()),
      );

      File(p.join(wt.path, 'a.txt')).writeAsStringSync('linha 1\nnova\n');
      File(p.join(wt.path, 'b.txt')).writeAsStringSync('b');
      final changes = await GitWorktrees.changes(wt.path);
      expect(changes.files.map((f) => f.path), containsAll(['a.txt', 'b.txt']));
      expect(changes.untracked, isTrue);
      expect(changes.diff, contains('+nova'));
      expect(
        GitWorktrees.validateLineComment(changes.diff, 'a.txt', 2),
        isNull,
      );
      expect(
        GitWorktrees.validateLineComment(changes.diff, 'a.txt', 1),
        isNotNull,
      );
      // O checkout original não mudou.
      expect(File(p.join(repo.path, 'b.txt')).existsSync(), isFalse);
      await GitWorktrees.git([
        'worktree',
        'remove',
        '--force',
        wt.path,
      ], repo.path);
    });

    test('padrões do .worktreeinclude', () {
      bool m(String path, String pattern) =>
          GitWorktrees.matchesInclude(path, [pattern]);
      expect(m('.env', '.env'), isTrue);
      expect(m('config/.env', '.env'), isTrue);
      expect(m('config/.env', '/.env'), isFalse);
      expect(m('secrets/a/b.json', 'secrets/'), isTrue);
      expect(m('a/secrets.json', '*.json'), isTrue);
      expect(m('a/b/c.key', '**/*.key'), isTrue);
      expect(m('a.txt', '!a.txt'), isFalse);
    });
  });
}
