import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/ai_agent/agent_backends.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_history.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_mcp_server.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/orchestrator/application/git_worktrees.dart';
import 'package:gestor_ufu/orchestrator/application/orq_journal.dart';
import 'package:gestor_ufu/orchestrator/application/orq_memory.dart';
import 'package:gestor_ufu/orchestrator/application/orq_prompts.dart';
import 'package:gestor_ufu/orchestrator/application/orq_settings.dart';
import 'package:gestor_ufu/orchestrator/application/project_guidance.dart';
import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';
import 'package:gestor_ufu/orchestrator/domain/plan_parser.dart';
import 'package:gestor_ufu/orchestrator/domain/secret_redaction.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// O que o Orquestrador precisa para criar um agente (coordenador ou
/// trabalhador). A janela do agente monta o backend com o mesmo código das
/// abas (chave de API ou CLI, servidor MCP próprio, ferramentas do Gestor).
class OrqBackendRequest {
  const OrqBackendRequest({
    required this.provider,
    required this.access,
    required this.systemPrompt,
    required this.label,
    required this.onPermission,
    this.model = '',
    this.effort = '',
    this.workDir = '',
    this.extraMcpServers = const {},
  });

  final AgentProvider provider;
  final AgentAccess access;
  final String systemPrompt;

  /// Identifica o agente nas aprovações ("Tarefa a · Claude").
  final String label;
  final AgentPermissionHandler onPermission;
  final String model;
  final String effort;
  final String workDir;

  /// Servidores MCP adicionais (ex.: AI Memory) para os CLIs.
  final Map<String, String> extraMcpServers;
}

typedef OrqBackendFactory =
    Future<AgentBackend> Function(OrqBackendRequest request);

/// Pedido de aprovação de um agente do Orquestrador.
class OrqApproval {
  OrqApproval(this.label, this.tool, this.input);

  final String label;
  final String tool;
  final Map<String, dynamic> input;
  final completer = Completer<bool>();
}

/// Orquestrador (port do Orchestrator-AI): coordenador que planeja, quadro
/// de tarefas e agentes trabalhadores em paralelo, com revisão humana.
class OrqController extends ChangeNotifier {
  OrqController({
    required this.factory,
    OrqJournal? journal,
    KeyValueStore? store,
    OrqMemoryBridge? memory,
    String? storageRoot,
    this.machine = '',
  }) : _store = store ?? KeyValueStore(),
       journal = journal ?? OrqJournal(store),
       memory = memory ?? const NoMemoryBridge(),
       storageRoot = storageRoot ?? _defaultStorage();

  static const chatKey = 'orquestrador.chat.v1';

  final OrqBackendFactory factory;
  final OrqJournal journal;
  final KeyValueStore _store;
  OrqMemoryBridge memory;

  /// Pasta local das worktrees.
  final String storageRoot;

  /// Computador atual (as tarefas executam em um computador só).
  final String machine;
  String get _machine => machine.isNotEmpty ? machine : OrqSettings.machine;

  OrqSettings settings = OrqSettings();
  bool loaded = false;

  /// Conversa com o coordenador.
  final chat = <AgentEntry>[];
  bool coordinatorBusy = false;
  AgentBackend? _coordinator;
  AgentProvider? _coordinatorProvider;
  Map<String, dynamic> _coordinatorState = const {};

  /// Rodadas, mais recentes primeiro.
  final runs = <OrqRun>[];

  /// Agentes trabalhando agora (`run/task`).
  final _workers = <String, AgentBackend>{};
  final _cancelRequested = <String>{};
  final _handoffContext = <String, String>{};

  /// Última atividade de cada tarefa em execução (linha curta para a tela).
  final activity = <String, String>{};

  /// Diff atual de cada tarefa com worktree.
  final diffs = <String, OrqChanges>{};

  /// Aprovações pedidas pelos agentes do Orquestrador.
  final approvals = <OrqApproval>[];
  bool allowAll = false;

  Timer? _changesTimer;
  bool _disposed = false;

  static String _defaultStorage() {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return p.join(base, 'GestorUFU', 'orquestrador');
  }

  static String key(OrqRun run, OrqTask task) => '${run.id}/${task.id}';

  bool isWorking(OrqRun run, OrqTask task) =>
      _workers.containsKey(key(run, task));

  int get activeCount => _workers.length;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------ Carregar

  Future<void> load() async {
    settings = await OrqSettings.load(_store);
    runs
      ..clear()
      ..addAll(await journal.runs());
    final saved = await _store.readJson(chatKey);
    if (saved is Map) {
      chat
        ..clear()
        ..addAll([
          for (final e in saved['entries'] as List? ?? const [])
            if (e is Map) AgentEntry.fromJson(Map<String, dynamic>.from(e)),
        ]);
      _coordinatorState = Map<String, dynamic>.from(
        saved['state'] as Map? ?? const {},
      );
    }
    // Tarefas deste computador que estavam executando quando o app fechou.
    for (final run in runs) {
      var dirty = false;
      for (final task in run.tasks) {
        if (task.status.active &&
            task.machine == _machine &&
            !isWorking(run, task)) {
          task
            ..status = OrqTaskStatus.parked
            ..error = 'Interrompida: o Gestor foi fechado durante a execução.'
            ..log('parada', 'O app fechou durante a execução.');
          dirty = true;
        }
      }
      if (dirty) await journal.saveRun(run);
    }
    loaded = true;
    _changed();
    _pump();
  }

  Future<void> saveSettings() async {
    await settings.save(_store);
    if (_coordinatorProvider != settings.coordinator) {
      await _dropCoordinator();
    }
    _changed();
    _pump();
  }

  Future<void> _saveChat() async {
    final entries = chat.length > 200 ? chat.sublist(chat.length - 200) : chat;
    await _store.writeJson(chatKey, {
      'entries': [for (final e in entries) e.toJson()],
      'state': _coordinator?.saveState() ?? _coordinatorState,
    });
  }

  Future<void> _dropCoordinator() async {
    final backend = _coordinator;
    _coordinator = null;
    _coordinatorProvider = null;
    _coordinatorState = const {};
    await backend?.dispose();
  }

  /// Nova conversa com o coordenador (o quadro continua).
  Future<void> newConversation() async {
    await _dropCoordinator();
    chat.clear();
    await _saveChat();
    _changed();
  }

  // ------------------------------------------------------------ Aprovações

  AgentPermissionHandler permissionFor(String label) => (tool, input) async {
    if (allowAll) return true;
    final approval = OrqApproval(label, tool, input);
    approvals.add(approval);
    _changed();
    return approval.completer.future;
  };

  void answer(OrqApproval approval, bool? allow) {
    if (allow == null) allowAll = true;
    approvals.remove(approval);
    if (!approval.completer.isCompleted) {
      approval.completer.complete(allow ?? true);
    }
    _changed();
  }

  // ------------------------------------------------------------ Coordenador

  Future<String> _guidance(String path) async {
    try {
      return await ProjectGuidance.load(path);
    } on Object {
      return '';
    }
  }

  /// Envia uma mensagem ao coordenador: ele responde, propõe um plano ou
  /// pede a transferência de uma tarefa.
  Future<void> send(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || coordinatorBusy) return;
    chat.add(AgentEntry(AgentEntryKind.user, prompt));
    coordinatorBusy = true;
    _changed();
    try {
      final backend = await _ensureCoordinator();
      final project = settings.projectPath;
      final root = await GitWorktrees.repositoryRoot(project);
      final message = buildCoordinatorMessage(
        userText: prompt,
        projectPath: project,
        guidance: await _guidance(project),
        branches: root == null
            ? const []
            : await GitWorktrees.localBranches(root),
        allowedWorkers: [for (final w in settings.workers) w.name],
        maxParallel: settings.maxParallel,
        maxAttempts: settings.maxAttempts,
        runs: runs,
        memoryContext: settings.aiMemory
            ? await memory.coordinatorContext(prompt, project)
            : '',
      );
      final reply = StringBuffer();
      await backend.send(message, const [], (event) {
        switch (event) {
          case AgentTextDeltaEvent(:final text):
            reply.write(text);
          case AgentTextEvent(:final text):
            reply
              ..write(text)
              ..write('\n');
          case AgentTextBreakEvent():
            reply.write('\n');
          default:
            break;
        }
      });
      _coordinatorState = backend.saveState();
      await _handleReply(prompt, reply.toString());
    } on OrqPlanException catch (error) {
      chat.add(AgentEntry(AgentEntryKind.error, error.message));
    } on Object catch (error) {
      chat.add(
        AgentEntry(
          AgentEntryKind.error,
          '$error' == 'Cancelado.' ? 'Interrompido.' : '$error',
        ),
      );
    } finally {
      coordinatorBusy = false;
      await _saveChat();
      _changed();
    }
  }

  Future<void> stopCoordinator() async => _coordinator?.cancel();

  Future<AgentBackend> _ensureCoordinator() async {
    final current = _coordinator;
    if (current != null && _coordinatorProvider == settings.coordinator) {
      return current;
    }
    await _dropCoordinator();
    final backend = await factory(
      OrqBackendRequest(
        provider: settings.coordinator,
        // Só planeja: leitura do projeto, sem editar nem disparar agentes.
        access: AgentAccess.plan,
        systemPrompt: orqCoordinatorSystemPrompt,
        label: 'Coordenador',
        workDir: settings.projectPath,
        onPermission: permissionFor('Coordenador'),
      ),
    );
    if (_coordinatorState.isNotEmpty) {
      backend.restoreState(_coordinatorState);
    }
    _coordinator = backend;
    _coordinatorProvider = settings.coordinator;
    return backend;
  }

  Future<void> _handleReply(String userText, String text) async {
    final reply = parseCoordinatorReply(text);
    switch (reply) {
      case OrqAnswer(:final answer):
        chat.add(AgentEntry(AgentEntryKind.agent, answer));
      case OrqPlanReply(:final title, :final tasks):
        final run = OrqRun(
          id: 'r${DateTime.now().millisecondsSinceEpoch}',
          title: title,
          prompt: userText,
          tasks: tasks,
          projectPath: settings.projectPath,
        );
        runs.insert(0, run);
        await journal.saveRun(run);
        chat.add(
          AgentEntry(
            AgentEntryKind.agent,
            'Plano proposto: **$title** (${tasks.length} tarefa(s)). Revise '
            'no quadro e aprove para iniciar.',
          ),
        );
      case OrqHandoffReply(:final handoff):
        final run = _run(handoff.runId);
        final task = run?.task(handoff.taskId);
        if (run == null || task == null) {
          throw OrqPlanException(
            'A tarefa ${handoff.runId}/${handoff.taskId} não existe.',
          );
        }
        if (!handoffPermitted(task, userText)) {
          throw const OrqPlanException(
            'Transferência recusada: só quando você pedir ou quando a tarefa '
            'falhar/bloquear.',
          );
        }
        await this.handoff(
          run.id,
          task.id,
          handoff.provider,
          context: handoff.context,
          model: handoff.model,
          effort: handoff.effort,
        );
        chat.add(
          AgentEntry(
            AgentEntryKind.agent,
            'Tarefa ${task.title} transferida para ${handoff.provider}.',
          ),
        );
    }
  }

  // ------------------------------------------------------------ Plano/rodada

  OrqRun? _run(String id) {
    for (final run in runs) {
      if (run.id == id) return run;
    }
    return null;
  }

  OrqRun _requireRun(String id) =>
      _run(id) ?? (throw StateError('Rodada $id não encontrada.'));

  /// Aprova o plano (opcionalmente editado) e coloca as tarefas na fila.
  Future<void> approvePlan(String runId, {List<OrqTask>? edited}) async {
    final run = _requireRun(runId);
    if (run.status != OrqRunStatus.proposed) return;
    if (edited != null) {
      run.tasks
        ..clear()
        ..addAll(edited);
    }
    run.status = OrqRunStatus.running;
    for (final task in run.tasks) {
      task
        ..status = OrqTaskStatus.queued
        ..log('aprovada', 'Plano aprovado pelo usuário.');
    }
    await journal.saveRun(run);
    _changed();
    _pump();
  }

  Future<void> rejectPlan(String runId) async {
    final run = _requireRun(runId);
    run.status = OrqRunStatus.rejected;
    await journal.saveRun(run);
    _changed();
  }

  Future<void> pauseRun(String runId) async {
    final run = _requireRun(runId);
    if (run.status != OrqRunStatus.running) return;
    run.status = OrqRunStatus.paused;
    await journal.saveRun(run);
    _changed();
  }

  Future<void> resumeRun(String runId) async {
    final run = _requireRun(runId);
    if (run.status != OrqRunStatus.paused) return;
    run.status = OrqRunStatus.running;
    await journal.saveRun(run);
    _changed();
    _pump();
  }

  Future<void> cancelRun(String runId) async {
    final run = _requireRun(runId);
    run.status = OrqRunStatus.cancelled;
    for (final task in run.tasks) {
      if (task.status == OrqTaskStatus.queued ||
          task.status == OrqTaskStatus.planned) {
        task.status = OrqTaskStatus.cancelled;
      }
    }
    await journal.saveRun(run);
    for (final task in run.tasks) {
      if (isWorking(run, task)) await cancelTask(run.id, task.id);
    }
    _changed();
  }

  Future<void> deleteRun(String runId) async {
    final run = _requireRun(runId);
    if (run.tasks.any((t) => isWorking(run, t))) {
      throw StateError('Cancele as tarefas em execução antes de apagar.');
    }
    runs.remove(run);
    await journal.deleteRun(runId);
    _changed();
  }

  // ------------------------------------------------------------ Tarefas

  Future<void> cancelTask(String runId, String taskId) async {
    final run = _requireRun(runId);
    final task = run.task(taskId)!;
    final worker = _workers[key(run, task)];
    if (worker == null) {
      if (!task.status.settled) {
        task
          ..status = OrqTaskStatus.cancelled
          ..log('cancelada', 'Cancelada antes de iniciar.');
        await journal.saveRun(run);
        _changed();
      }
      return;
    }
    _cancelRequested.add(key(run, task));
    task.status = OrqTaskStatus.cancelling;
    _changed();
    await worker.cancel();
  }

  /// Tenta de novo uma tarefa que falhou, foi bloqueada, parada ou
  /// cancelada (respeitando o limite de tentativas).
  Future<void> retryTask(
    String runId,
    String taskId, {
    String note = '',
  }) async {
    final run = _requireRun(runId);
    final task = run.task(taskId)!;
    if (isWorking(run, task)) return;
    if (task.attempts >= settings.maxAttempts) {
      throw StateError(
        'Limite de ${settings.maxAttempts} tentativa(s) atingido.',
      );
    }
    task
      ..status = OrqTaskStatus.queued
      ..error = ''
      ..reviewNote = note.trim()
      ..log('repetir', note.trim().isEmpty ? 'Nova tentativa.' : note.trim());
    if (run.status == OrqRunStatus.cancelled ||
        run.status == OrqRunStatus.complete) {
      run.status = OrqRunStatus.running;
    }
    await journal.saveRun(run);
    _changed();
    _pump();
  }

  /// Revisão: pedir ajustes ao mesmo agente (continua a mesma sessão).
  Future<void> requestChanges(String runId, String taskId, String note) =>
      retryTask(runId, taskId, note: note);

  /// Revisão: comentário numa linha adicionada do diff, enviado ao agente.
  Future<void> commentLine(
    String runId,
    String taskId,
    String file,
    int line,
    String comment,
  ) async {
    final run = _requireRun(runId);
    final task = run.task(taskId)!;
    final changes = diffs[key(run, task)];
    if (changes == null || changes.truncated) {
      throw StateError('O diff da tarefa não está disponível por completo.');
    }
    final problem = GitWorktrees.validateLineComment(changes.diff, file, line);
    if (problem != null) throw StateError(problem);
    await retryTask(
      runId,
      taskId,
      note: 'Comentário na linha $file:$line: ${comment.trim()}',
    );
  }

  /// Revisão: os critérios foram atendidos (conclui) ou não (bloqueia).
  Future<void> review(
    String runId,
    String taskId, {
    required bool complete,
  }) async {
    final run = _requireRun(runId);
    final task = run.task(taskId)!;
    if (task.status != OrqTaskStatus.awaitingReview) return;
    task
      ..status = complete ? OrqTaskStatus.complete : OrqTaskStatus.blocked
      ..log(
        complete ? 'concluída' : 'bloqueada',
        complete
            ? 'Critérios confirmados pelo usuário.'
            : 'O revisor marcou como bloqueada.',
      );
    await journal.saveRun(run);
    _changed();
    _pump();
  }

  /// Transfere a tarefa para outro agente: reivindica o destino antes de
  /// parar o atual e desfaz a reivindicação se a parada falhar.
  Future<void> handoff(
    String runId,
    String taskId,
    String provider, {
    String context = '',
    String model = '',
    String effort = '',
  }) async {
    final run = _requireRun(runId);
    final task = run.task(taskId)!;
    if (task.status == OrqTaskStatus.complete) {
      throw StateError('A tarefa já foi concluída.');
    }
    if (!AgentProvider.values.any((p) => p.name == provider)) {
      throw StateError('Agente desconhecido: $provider.');
    }
    final packet = context.trim().isNotEmpty
        ? '${context.trim()}\n\n${await journal.continuityPacket(run, task, max: 3000)}'
        : await journal.continuityPacket(run, task);
    final record = await journal.createHandoff(
      runId: run.id,
      taskId: task.id,
      fromProvider: task.provider,
      toProvider: provider,
      context: packet,
      toModel: model,
      toEffort: effort,
    );
    final recipient = '$provider#${run.id}/${task.id}';
    final claim = await journal.claimHandoff(record.id, recipient);
    if (!claim.claimed) {
      throw StateError('Transferência não reivindicada (${claim.reason}).');
    }
    final worker = _workers[key(run, task)];
    if (worker != null) {
      try {
        _cancelRequested.add(key(run, task));
        await worker.cancel();
      } on Object {
        _cancelRequested.remove(key(run, task));
        await journal.releaseClaim(record.id, recipient);
        rethrow;
      }
      // Espera o agente atual sair.
      for (var i = 0; i < 100 && isWorking(run, task); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    task
      ..log('transferida', '${task.provider} → $provider')
      ..provider = provider
      ..model = model
      ..effort = effort
      ..sessionState = const {}
      ..handoffId = record.id
      ..status = OrqTaskStatus.queued
      ..error = '';
    _handoffContext[key(run, task)] = record.context;
    if (run.status != OrqRunStatus.running) run.status = OrqRunStatus.running;
    await journal.saveRun(run);
    _changed();
    _pump();
  }

  // ------------------------------------------------------------ Agendador

  bool _dependenciesDone(OrqRun run, OrqTask task) => task.dependsOn.every(
    (id) => run.task(id)?.status == OrqTaskStatus.complete,
  );

  /// Inicia as tarefas prontas (dependências concluídas) até o limite de
  /// paralelismo.
  void _pump() {
    if (!loaded || _disposed) return;
    for (final run in runs.reversed) {
      if (run.status != OrqRunStatus.running) continue;
      for (final task in run.tasks) {
        if (_workers.length >= settings.maxParallel) return;
        if (task.status != OrqTaskStatus.queued) continue;
        if (task.machine.isNotEmpty && task.machine != _machine) continue;
        final blocker = task.dependsOn
            .map(run.task)
            .whereType<OrqTask>()
            .where(
              (d) =>
                  d.status == OrqTaskStatus.cancelled ||
                  d.status == OrqTaskStatus.failed,
            );
        if (blocker.isNotEmpty) {
          task
            ..status = OrqTaskStatus.blocked
            ..error =
                'A dependência ${blocker.first.id} terminou como '
                '${blocker.first.status.label.toLowerCase()}.';
          unawaited(journal.saveRun(run));
          continue;
        }
        if (!_dependenciesDone(run, task)) continue;
        unawaited(_runTask(run, task));
      }
      if (run.tasks.every((t) => t.status == OrqTaskStatus.complete)) {
        run.status = OrqRunStatus.complete;
        unawaited(journal.saveRun(run));
      }
    }
    _changed();
  }

  AgentProvider _providerFor(OrqTask task) {
    final named = AgentProvider.values.where((p) => p.name == task.provider);
    final provider = named.isEmpty ? settings.defaultWorker : named.first;
    if (!settings.workers.contains(provider)) {
      throw StateError(
        'O agente ${provider.name} não está entre os trabalhadores permitidos '
        'nas configurações do Orquestrador.',
      );
    }
    return provider;
  }

  Future<String> _prepareWorkspace(OrqRun run, OrqTask task) async {
    if (task.target == OrqTarget.gestor) return '';
    final project = run.projectPath.isNotEmpty
        ? run.projectPath
        : settings.projectPath;
    if (project.isEmpty || !await Directory(project).exists()) {
      throw StateError(
        'Configure a pasta do projeto nas configurações do Orquestrador.',
      );
    }
    if (task.worktree == 'current') return project;
    final root = await GitWorktrees.repositoryRoot(project);
    if (root == null) {
      // Projeto sem Git: trabalha direto na pasta (sem isolamento).
      task.log('aviso', 'Projeto sem Git: a tarefa trabalha direto na pasta.');
      return project;
    }
    final worktree = await GitWorktrees(storageRoot).open(
      project,
      runId: run.id,
      taskId: task.id,
      attempt: task.attempts,
      requestedBranch: task.worktree,
      base: task.base,
      existingPath: task.worktreePath,
    );
    task
      ..worktreePath = worktree.path
      ..branch = worktree.branch;
    if (worktree.includedFiles.isNotEmpty) {
      task.log(
        'worktree',
        'Copiados de .worktreeinclude: ${worktree.includedFiles.join(', ')}',
      );
    }
    return worktree.path;
  }

  Future<void> _runTask(OrqRun run, OrqTask task) async {
    final k = key(run, task);
    if (_workers.containsKey(k)) return;
    final placeholder = _PendingBackend();
    _workers[k] = placeholder;
    task
      ..status = OrqTaskStatus.starting
      ..attempts += 1
      ..machine = _machine
      ..error = ''
      ..log('iniciando', 'Tentativa ${task.attempts}.');
    await journal.saveRun(run);
    _changed();
    AgentBackend? backend;
    final segment = StringBuffer();
    var lastText = '';
    try {
      final provider = _providerFor(task);
      final workDir = await _prepareWorkspace(run, task);
      final taskMemory = settings.aiMemory
          ? await memory.prepareTask(run, task)
          : const OrqTaskMemory();
      task
        ..memoryStatus = taskMemory.status
        ..memoryPage = taskMemory.pagePath;
      final guidance = await _guidance(
        workDir.isEmpty ? settings.projectPath : workDir,
      );
      final events = await journal.events(run.id, taskId: task.id);
      final journalContext = [
        for (final e in events.reversed.take(12).toList().reversed)
          '- ${e.event}: ${e.detail}',
      ].join('\n');
      final prompt = buildWorkerPrompt(
        run: run,
        task: task,
        guidance: guidance,
        workDir: workDir,
        journalContext: journalContext,
        handoff: _handoffContext.remove(k) ?? '',
        memoryContext: taskMemory.context,
        memoryInstructions: taskMemory.instructions,
      );
      backend = await factory(
        OrqBackendRequest(
          provider: provider,
          access: task.target == OrqTarget.gestor
              ? AgentAccess.gestor
              : settings.workerAccess,
          model: task.model,
          effort: task.effort,
          workDir: workDir,
          systemPrompt:
              'Você é um agente trabalhador do Orquestrador do Gestor UFU. '
              'Execute somente a tarefa recebida, dentro da pasta indicada.',
          label: 'Tarefa ${task.id} · ${provider.name}',
          onPermission: permissionFor('Tarefa ${task.id} · ${provider.name}'),
          extraMcpServers: {
            if (taskMemory.mcpServerUrl.isNotEmpty)
              'ai_memory': taskMemory.mcpServerUrl,
          },
        ),
      );
      if (_cancelRequested.contains(k)) throw const _Cancelled();
      if (task.sessionState.isNotEmpty) backend.restoreState(task.sessionState);
      _workers[k] = backend;
      if (task.handoffId.isNotEmpty) {
        await journal.recordSessionStart(
          task.handoffId,
          '${provider.name}#${run.id}/${task.id}',
          '${backend.label}@${DateTime.now().toIso8601String()}',
        );
      }
      task.status = OrqTaskStatus.running;
      await journal.addEvent(run.id, task.id, 'início', backend.label);
      await journal.saveRun(run);
      _changed();
      await backend.send(prompt, const [], (event) {
        switch (event) {
          case AgentTextDeltaEvent(:final text):
            segment.write(text);
            _setActivity(k, segment.toString());
          case AgentTextEvent(:final text):
            segment
              ..write(text)
              ..write('\n');
            _setActivity(k, text);
          case AgentTextBreakEvent():
            if (segment.toString().trim().isNotEmpty) {
              lastText = segment.toString().trim();
            }
            segment.clear();
          case AgentToolEvent(:final name, :final input):
            if (segment.toString().trim().isNotEmpty) {
              lastText = segment.toString().trim();
              unawaited(journal.addEvent(run.id, task.id, 'texto', lastText));
            }
            segment.clear();
            final summary = _toolSummary(name, input);
            _setActivity(k, '⚙ $summary');
            unawaited(journal.addEvent(run.id, task.id, 'ferramenta', summary));
          case AgentInfoEvent(:final text):
            unawaited(journal.addEvent(run.id, task.id, 'info', text));
          default:
            break;
        }
      });
      final finalText = segment.toString().trim().isNotEmpty
          ? segment.toString().trim()
          : lastText;
      task
        ..result = redactSensitiveText(finalText)
        ..sessionState = backend.saveState()
        ..reviewNote = ''
        ..status = OrqTaskStatus.awaitingReview
        ..log('aguardando revisão', 'O agente terminou a tentativa.');
      if (settings.aiMemory) {
        task.memoryStatus = await memory.recordAttempt(
          run,
          task,
          provider.name,
        );
      }
      await journal.addEvent(run.id, task.id, 'resultado', finalText);
    } on Object catch (error) {
      final cancelled = _cancelRequested.contains(k) || error is _Cancelled;
      try {
        task.sessionState = backend?.saveState() ?? task.sessionState;
      } on Object {
        // O estado do backend pode não estar disponível após a falha.
      }
      if (cancelled) {
        task
          ..status = task.status == OrqTaskStatus.queued
              ? OrqTaskStatus.queued
              : OrqTaskStatus.cancelled
          ..log('cancelada', 'Cancelada pelo usuário.');
      } else {
        final message = error is GitException
            ? error.message
            : error is StateError
            ? error.message
            : '$error';
        task
          ..status = OrqTaskStatus.failed
          ..error = redactSensitiveText(message, max: 3000)
          ..log('falhou', message);
        await journal.addEvent(run.id, task.id, 'erro', message);
      }
    } finally {
      if (identical(_workers[k], backend) ||
          identical(_workers[k], placeholder)) {
        _workers.remove(k);
      }
      _cancelRequested.remove(k);
      activity.remove(k);
      await backend?.dispose();
      await _refreshChanges(run, task);
      await journal.saveRun(run);
      _changed();
      _pump();
    }
  }

  void _setActivity(String k, String text) {
    final line = text.trim().split('\n').last.trim();
    if (line.isEmpty) return;
    activity[k] = line.length > 160 ? '${line.substring(0, 160)}…' : line;
    _changed();
  }

  static String _toolSummary(String name, Map<String, dynamic> input) {
    final short = name.replaceFirst(RegExp(r'^mcp__[a-z_]+__'), '');
    for (final field in [
      'command',
      'file_path',
      'path',
      'url',
      'query',
      'pattern',
    ]) {
      final value = input[field];
      if (value != null && '$value'.trim().isNotEmpty) {
        final text = '$value'.replaceAll(RegExp(r'\s+'), ' ');
        return '$short: ${text.length > 120 ? '${text.substring(0, 120)}…' : text}';
      }
    }
    return short;
  }

  // ------------------------------------------------------------ Alterações

  /// Atualiza arquivos alterados e diff das tarefas com worktree.
  Future<void> _refreshChanges(OrqRun run, OrqTask task) async {
    if (task.worktreePath.isEmpty ||
        !await Directory(task.worktreePath).exists()) {
      return;
    }
    try {
      final changes = await GitWorktrees.changes(
        task.worktreePath,
        base: task.base,
      );
      diffs[key(run, task)] = changes;
      task.changedFiles = changes.files;
    } on Object {
      // Worktree removida ou Git indisponível: mantém o último estado.
    }
  }

  /// Acompanha as alterações das tarefas em execução (a cada 5 s).
  void startWatchingChanges() {
    _changesTimer ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      for (final run in runs) {
        for (final task in run.tasks) {
          if (isWorking(run, task) && task.worktreePath.isNotEmpty) {
            await _refreshChanges(run, task);
            _changed();
          }
        }
      }
    });
  }

  Future<OrqChanges?> changesFor(String runId, String taskId) async {
    final run = _requireRun(runId);
    final task = run.task(taskId)!;
    await _refreshChanges(run, task);
    _changed();
    return diffs[key(run, task)];
  }

  // ------------------------------------------------------------ Build

  /// Sincroniza os upstreams (fast-forward) e roda o build configurado.
  Future<String> syncAndBuild() async {
    final project = settings.projectPath;
    if (project.isEmpty) throw StateError('Configure a pasta do projeto.');
    final log = StringBuffer();
    for (final upstream in settings.upstreams) {
      log.writeln(
        await GitWorktrees.syncUpstream(
          project,
          upstream.path,
          remote: upstream.remote,
          branch: upstream.branch,
        ),
      );
    }
    if (settings.buildCommand.trim().isEmpty) {
      log.writeln('Nenhum comando de build configurado.');
      return log.toString();
    }
    final args = _splitArgs(settings.buildArgs);
    final dir = settings.buildDir.trim().isEmpty
        ? project
        : p.join(project, settings.buildDir.trim());
    final result = await Process.run(
      settings.buildCommand.trim(),
      args,
      workingDirectory: dir,
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(Duration(minutes: settings.buildTimeoutMinutes));
    final output = '${result.stdout}\n${result.stderr}'.trim();
    log
      ..writeln('Build terminou com código ${result.exitCode}.')
      ..writeln(
        output.length > 6000 ? output.substring(output.length - 6000) : output,
      );
    return redactSensitiveText(log.toString());
  }

  static List<String> _splitArgs(String text) => [
    for (final m in RegExp(r'"([^"]*)"|(\S+)').allMatches(text))
      m.group(1) ?? m.group(2)!,
  ];

  @override
  void dispose() {
    _disposed = true;
    _changesTimer?.cancel();
    for (final approval in approvals) {
      if (!approval.completer.isCompleted) approval.completer.complete(false);
    }
    for (final worker in _workers.values) {
      unawaited(worker.cancel());
    }
    unawaited(_coordinator?.dispose());
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Marca a vaga ocupada enquanto o backend da tarefa é criado.
class _PendingBackend extends AgentBackend {
  @override
  String get label => 'iniciando';

  @override
  Future<String> verify() async => '';

  @override
  Future<List<AgentModel>> listModels() async => const [];

  @override
  Future<void> send(
    String prompt,
    List<AgentAttachment> attachments,
    AgentEventSink emit,
  ) async {}

  @override
  void reset() {}
}
