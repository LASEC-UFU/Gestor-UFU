import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gestor_ufu/data/services/ai_agent/agent_history.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/orchestrator/application/ai_memory.dart';
import 'package:gestor_ufu/orchestrator/application/orq_controller.dart';
import 'package:gestor_ufu/orchestrator/application/orq_settings.dart';
import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';
import 'package:gestor_ufu/orchestrator/domain/plan_parser.dart';
import 'package:gestor_ufu/presentation/pages/ai_agent_widgets.dart';

/// Aba "Orquestrador" da janela do Agente de IA: conversa com o coordenador
/// e quadro de tarefas (port da interface do Orchestrator-AI).
class OrchestratorView extends StatefulWidget {
  const OrchestratorView({
    required this.controller,
    this.onPrepareProject,
    this.memoryPanel,
    this.onProfileLogin,
    super.key,
  });

  final OrqController controller;

  /// Abre o login oficial do CLI para um perfil de conta.
  final Future<void> Function(OrqProfile profile)? onProfileLogin;

  /// "Preparar projeto (.ai)" (cria a pasta .ai com specs e skills).
  final Future<String> Function(String projectPath)? onPrepareProject;

  /// Painel do AI Memory nas configurações (instalar, estado, versão).
  final Widget Function(BuildContext context)? memoryPanel;

  @override
  State<OrchestratorView> createState() => _OrchestratorViewState();
}

class _OrchestratorViewState extends State<OrchestratorView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _board = false;

  OrqController get _orq => widget.controller;

  @override
  void initState() {
    super.initState();
    _orq.addListener(_refresh);
  }

  @override
  void dispose() {
    _orq.removeListener(_refresh);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && !_board) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _orq.coordinatorBusy) return;
    _input.clear();
    await _orq.send(text);
    // Plano novo: mostra o quadro.
    if (mounted &&
        _orq.runs.isNotEmpty &&
        _orq.runs.first.status == OrqRunStatus.proposed) {
      setState(() => _board = true);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error is StateError ? error.message : '$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    if (!_orq.loaded) return const Center(child: CircularProgressIndicator());
    final active = _orq.runs
        .expand((r) => r.tasks)
        .where((t) => !t.status.settled && t.status != OrqTaskStatus.planned)
        .length;
    return Column(
      children: [
        _header(vs, active),
        if (_orq.approvals.isNotEmpty) _approvals(vs),
        Expanded(child: _board ? _boardView(vs) : _chatView(vs)),
        if (!_board && _orq.chatReadOnlyBy != null)
          _readOnlyBar(vs)
        else if (!_board)
          _composer(vs),
      ],
    );
  }

  // ------------------------------------------------------------ Cabeçalho

  Widget _header(VsColors vs, int active) {
    Widget tab(String label, bool selected, VoidCallback onTap) => InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? vs.tab : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(label, style: TextStyle(fontSize: 12.5, color: vs.text)),
      ),
    );
    final project = _orq.settings.projectPath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 10, 6),
      child: Row(
        children: [
          tab('Conversa', !_board, () => setState(() => _board = false)),
          const SizedBox(width: 4),
          tab(
            active > 0 ? 'Quadro · $active' : 'Quadro',
            _board,
            () => setState(() => _board = true),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Coordenador: ${_orq.settings.coordinator.tabLabel} · '
              '${project.isEmpty ? 'sem pasta de projeto' : project} · '
              '${_orq.memory.statusLabel}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: vs.muted),
            ),
          ),
          if (!_board)
            VsIconButton(
              icon: Icons.history_rounded,
              tooltip: 'Conversas do coordenador (todos os computadores)',
              onPressed: _orq.coordinatorBusy ? null : _openConversations,
            ),
          if (!_board)
            VsIconButton(
              icon: Icons.add_comment_outlined,
              tooltip: 'Nova conversa com o coordenador',
              onPressed: _orq.coordinatorBusy ? null : _orq.newConversation,
            ),
          VsIconButton(
            icon: Icons.build_circle_outlined,
            tooltip: 'Sincronizar upstreams e compilar o projeto',
            onPressed: () => _run(_syncAndBuild),
          ),
          VsIconButton(
            icon: Icons.tune_rounded,
            tooltip: 'Configurações do Orquestrador',
            onPressed: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _approvals(VsColors vs) => Container(
    constraints: const BoxConstraints(maxHeight: 260),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: ListView(
      shrinkWrap: true,
      children: [
        for (final approval in List.of(_orq.approvals))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  approval.label,
                  style: TextStyle(fontSize: 11.5, color: vs.muted),
                ),
                ApprovalCard(
                  tool: approval.tool,
                  input: approval.input,
                  onAnswer: (allow) => _orq.answer(approval, allow),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  // ------------------------------------------------------------ Conversa

  Widget _chatView(VsColors vs) {
    final entries = _orq.chat;
    if (entries.isEmpty && !_orq.coordinatorBusy) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined, size: 40, color: vs.muted),
              const SizedBox(height: 12),
              Text(
                'Orquestrador',
                style: TextStyle(fontSize: 18, color: vs.text),
              ),
              const SizedBox(height: 6),
              Text(
                'Descreva o trabalho. O coordenador monta um plano de tarefas, '
                'você aprova e os agentes (Claude, Codex, Gemini, Copilot) '
                'executam em paralelo, cada um na sua worktree. Você revisa '
                'antes de concluir.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: vs.muted, height: 1.4),
              ),
            ],
          ),
        ),
      );
    }
    final count = entries.length + (_orq.coordinatorBusy ? 1 : 0);
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: count,
        itemBuilder: (context, index) {
          if (index >= entries.length) {
            return const Padding(
              padding: EdgeInsets.only(top: 12),
              child: ThinkingIndicator(label: 'Planejando…'),
            );
          }
          final entry = entries[index];
          return switch (entry.kind) {
            AgentEntryKind.user => UserBubble(entry),
            AgentEntryKind.error => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                entry.text,
                style: TextStyle(fontSize: 12.5, color: vs.error),
              ),
            ),
            AgentEntryKind.info => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                entry.text,
                style: TextStyle(fontSize: 12.5, color: vs.muted),
              ),
            ),
            _ => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: AgentMessage(entry),
            ),
          };
        },
      ),
    );
  }

  Widget _composer(VsColors vs) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        decoration: BoxDecoration(
          color: vs.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: vs.border),
        ),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter): _send,
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_orq.coordinatorBusy) unawaited(_orq.stopCoordinator());
            },
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(fontSize: 13, color: vs.text, height: 1.4),
                  decoration: InputDecoration(
                    hintText: 'Peça um trabalho ao Orquestrador',
                    hintStyle: TextStyle(color: vs.muted),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Tooltip(
                  message: _orq.coordinatorBusy
                      ? 'Parar (Esc)'
                      : 'Enviar (Enter)',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: _orq.coordinatorBusy ? _orq.stopCoordinator : _send,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0A6ED1),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Icon(
                        _orq.coordinatorBusy
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                        size: 17,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  // ------------------------------------------------------------ Quadro

  Widget _boardView(VsColors vs) {
    final runs = _orq.runs
        .where((r) => r.status != OrqRunStatus.rejected)
        .toList();
    if (runs.isEmpty) {
      return Center(
        child: Text(
          'Nenhuma rodada. Peça um trabalho na Conversa.',
          style: TextStyle(color: vs.muted),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: [for (final run in runs) _runCard(vs, run)],
    );
  }

  Color _statusColor(VsColors vs, OrqTaskStatus status) => switch (status) {
    OrqTaskStatus.complete => vs.success,
    OrqTaskStatus.failed || OrqTaskStatus.blocked => vs.error,
    OrqTaskStatus.awaitingReview => const Color(0xFFE5A50A),
    OrqTaskStatus.running || OrqTaskStatus.starting => vs.accent,
    _ => vs.muted,
  };

  Widget _chip(VsColors vs, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(text, style: TextStyle(fontSize: 11, color: color)),
  );

  Widget _runCard(VsColors vs, OrqRun run) {
    final proposed = run.status == OrqRunStatus.proposed;
    return Card(
      color: vs.card,
      margin: const EdgeInsets.only(top: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: vs.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    run.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: vs.text,
                    ),
                  ),
                ),
                _chip(vs, run.status.label, vs.accent),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              run.prompt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: vs.muted),
            ),
            const SizedBox(height: 8),
            if (_runElsewhere(run) case final by?)
              _holderBanner(
                vs,
                'Em execução em $by. Só visualização aqui (atualiza sozinha).',
                'Assumir rodada aqui',
                run,
              )
            else if (_runOrphan(run))
              _holderBanner(
                vs,
                'Nenhum computador está executando esta rodada'
                    '${run.machine.isEmpty ? '' : ' (última vez em ${run.machine})'}.',
                'Retomar aqui',
                run,
              ),
            if (_runElsewhere(run) == null && !_runOrphan(run))
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (proposed) ...[
                    FilledButton.icon(
                      onPressed: () => _run(() => _orq.approvePlan(run.id)),
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      label: const Text('Aprovar e iniciar'),
                    ),
                    OutlinedButton(
                      onPressed: () => _editPlan(run),
                      child: const Text('Editar plano'),
                    ),
                    TextButton(
                      onPressed: () => _run(() => _orq.rejectPlan(run.id)),
                      child: const Text('Rejeitar'),
                    ),
                  ],
                  if (run.status == OrqRunStatus.running)
                    OutlinedButton(
                      onPressed: () => _run(() => _orq.pauseRun(run.id)),
                      child: const Text('Pausar'),
                    ),
                  if (run.status == OrqRunStatus.paused)
                    OutlinedButton(
                      onPressed: () => _run(() => _orq.resumeRun(run.id)),
                      child: const Text('Retomar'),
                    ),
                  if (run.status == OrqRunStatus.running ||
                      run.status == OrqRunStatus.paused)
                    TextButton(
                      onPressed: () => _run(() => _orq.cancelRun(run.id)),
                      child: const Text('Cancelar rodada'),
                    ),
                  if (!proposed &&
                      run.status != OrqRunStatus.running &&
                      run.status != OrqRunStatus.paused)
                    TextButton(
                      onPressed: () => _run(() => _orq.deleteRun(run.id)),
                      child: const Text('Apagar do quadro'),
                    ),
                ],
              ),
            for (final task in run.tasks) _taskCard(vs, run, task),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(VsColors vs, OrqRun run, OrqTask task) {
    final key = OrqController.key(run, task);
    final working = _orq.isWorking(run, task);
    final otherMachine =
        task.machine.isNotEmpty &&
        task.machine != OrqSettings.machine &&
        task.status.active;
    final canRetry = task.attempts < _orq.settings.maxAttempts;
    final meta = [
      task.provider,
      if (task.model.isNotEmpty) task.model,
      if (task.effort.isNotEmpty) task.effort,
      task.target == OrqTarget.gestor ? 'Gestor UFU' : 'projeto',
      if (task.branch.isNotEmpty) 'branch ${task.branch}',
      if (task.attempts > 0) 'tentativa ${task.attempts}',
      if (task.machine.isNotEmpty) 'em ${task.machine}',
      'memória: ${task.memoryStatus == 'verified' ? 'verificada' : 'não verificada'}',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: vs.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (working) ...[
                PulsingDot(color: vs.accent),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  '${task.id} · ${task.title}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: vs.text,
                  ),
                ),
              ),
              _chip(vs, task.status.label, _statusColor(vs, task.status)),
            ],
          ),
          const SizedBox(height: 3),
          Text(meta, style: TextStyle(fontSize: 11, color: vs.muted)),
          if (task.dependsOn.isNotEmpty)
            Text(
              'Depende de: ${task.dependsOn.join(', ')}',
              style: TextStyle(fontSize: 11, color: vs.muted),
            ),
          const SizedBox(height: 4),
          Text(
            task.description,
            style: TextStyle(fontSize: 12, color: vs.text, height: 1.35),
          ),
          for (final c in task.acceptanceCriteria)
            Text(
              '• $c',
              style: TextStyle(fontSize: 11.5, color: vs.muted, height: 1.35),
            ),
          if (_orq.activity[key] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _orq.activity[key]!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: vs.accent,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          if (otherMachine)
            Text(
              'Executando em outro computador (${task.machine}).',
              style: TextStyle(fontSize: 11.5, color: vs.muted),
            ),
          if (task.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                task.error,
                style: TextStyle(fontSize: 11.5, color: vs.error),
              ),
            ),
          if (task.result.isNotEmpty)
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'Relatório do agente',
                  style: TextStyle(fontSize: 12, color: vs.text),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () =>
                          _run(() => _copyAgentReport(task.result)),
                      icon: const Icon(Icons.copy_rounded, size: 15),
                      label: const Text('Copiar relat\u00f3rio completo'),
                    ),
                  ),
                  AgentMessage(AgentEntry(AgentEntryKind.agent, task.result)),
                ],
              ),
            ),
          if (task.changedFiles.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => _showDiff(run, task),
              icon: const Icon(Icons.difference_outlined, size: 16),
              label: Text('${task.changedFiles.length} arquivo(s) alterado(s)'),
            ),
          if (task.history.isNotEmpty)
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  'Atividade · ${task.history.length} evento(s)',
                  style: TextStyle(fontSize: 12, color: vs.muted),
                ),
                children: [
                  for (final h in task.history.reversed.take(20))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${TimeOfDay.fromDateTime(h.at).format(context)} · '
                        '${h.event}${h.detail.isEmpty ? '' : ' · ${h.detail}'}',
                        style: TextStyle(fontSize: 11, color: vs.muted),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          if (_runElsewhere(run) == null && !_runOrphan(run))
            Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                if (task.status == OrqTaskStatus.awaitingReview) ...[
                  FilledButton(
                    onPressed: () => _run(
                      () => _orq.review(run.id, task.id, complete: true),
                    ),
                    child: const Text('Confirmar critérios e concluir'),
                  ),
                  if (canRetry)
                    OutlinedButton(
                      onPressed: () => _requestChanges(run, task),
                      child: const Text('Pedir ajustes'),
                    ),
                  TextButton(
                    onPressed: () => _run(
                      () => _orq.review(run.id, task.id, complete: false),
                    ),
                    child: const Text('Marcar bloqueada'),
                  ),
                ],
                if (working ||
                    task.status == OrqTaskStatus.queued ||
                    task.status == OrqTaskStatus.planned)
                  TextButton(
                    onPressed: () =>
                        _run(() => _orq.cancelTask(run.id, task.id)),
                    child: const Text('Cancelar tarefa'),
                  ),
                if (!working &&
                    canRetry &&
                    {
                      OrqTaskStatus.failed,
                      OrqTaskStatus.blocked,
                      OrqTaskStatus.parked,
                      OrqTaskStatus.cancelled,
                    }.contains(task.status))
                  OutlinedButton(
                    onPressed: () =>
                        _run(() => _orq.retryTask(run.id, task.id)),
                    child: const Text('Tentar novamente'),
                  ),
                if (!canRetry &&
                    !task.status.active &&
                    task.status != OrqTaskStatus.complete)
                  Text(
                    'Limite de ${_orq.settings.maxAttempts} tentativa(s) atingido',
                    style: TextStyle(fontSize: 11, color: vs.muted),
                  ),
                if (task.status != OrqTaskStatus.complete &&
                    task.status != OrqTaskStatus.planned &&
                    run.status != OrqRunStatus.proposed)
                  TextButton(
                    onPressed: () => _handoff(run, task),
                    child: const Text('Transferir para outro agente'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Computador que está com a rodada (null = este ou ninguém).
  String? _runElsewhere(OrqRun run) =>
      _orq.holdsRun(run) ? null : _orq.runHolders[run.id];

  /// Rodada em andamento sem nenhum computador executando (o dono fechou
  /// ou ficou sem posse): pode ser retomada aqui.
  bool _runOrphan(OrqRun run) =>
      !_orq.holdsRun(run) &&
      _orq.runHolders[run.id] == null &&
      run.machine.isNotEmpty &&
      run.machine != _orq.machineName &&
      (run.status == OrqRunStatus.running || run.status == OrqRunStatus.paused);

  Widget _holderBanner(VsColors vs, String text, String action, OrqRun run) =>
      Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: vs.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: vs.accent.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.devices_rounded, size: 16, color: vs.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: TextStyle(fontSize: 12, color: vs.text)),
            ),
            FilledButton(
              onPressed: () => _run(() => _orq.takeOverRun(run.id)),
              child: Text(action),
            ),
          ],
        ),
      );

  Widget _readOnlyBar(VsColors vs) => Container(
    margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
    decoration: BoxDecoration(
      color: vs.card,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: vs.border),
    ),
    child: Row(
      children: [
        Icon(Icons.visibility_outlined, size: 16, color: vs.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Só leitura: esta conversa está aberta em ${_orq.chatReadOnlyBy} '
            'e se atualiza sozinha.',
            style: TextStyle(fontSize: 12.5, color: vs.text),
          ),
        ),
        FilledButton(
          onPressed: () => _run(_orq.takeOverConversation),
          child: const Text('Assumir aqui'),
        ),
      ],
    ),
  );

  Future<void> _openConversations() async {
    final list = await _orq.conversations();
    if (!mounted) return;
    final picked = await showDialog<OrqChatSummary>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conversas do coordenador'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: list.isEmpty
              ? const Center(child: Text('Nenhuma conversa guardada.'))
              : ListView(
                  children: [
                    for (final c in list)
                      ListTile(
                        dense: true,
                        selected: c.id == _orq.chatId,
                        title: Text(c.title.isEmpty ? '(sem título)' : c.title),
                        subtitle: Text(
                          '${c.machine.isEmpty ? '' : '${c.machine} · '}'
                          '${c.updatedAt.day.toString().padLeft(2, '0')}/'
                          '${c.updatedAt.month.toString().padLeft(2, '0')} '
                          '${c.updatedAt.hour.toString().padLeft(2, '0')}:'
                          '${c.updatedAt.minute.toString().padLeft(2, '0')}'
                          '${c.openIn == null ? '' : ' · aberta em ${c.openIn}'}',
                        ),
                        trailing: c.openIn == null
                            ? null
                            : const Icon(Icons.devices_rounded, size: 16),
                        onTap: () => Navigator.pop(context, c),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    var takeOver = false;
    if (picked.openIn != null) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Conversa aberta em outro computador'),
          content: Text(
            'Esta conversa está aberta em ${picked.openIn}. Ela não roda em '
            'dois computadores ao mesmo tempo: você pode só visualizar ou '
            'assumir aqui (lá ela para).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Só visualizar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Assumir aqui'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      takeOver = choice;
    }
    await _run(() => _orq.openConversation(picked.id, takeOver: takeOver));
  }

  // ------------------------------------------------------------ Diálogos

  Future<String?> _ask(String title, String hint, {int lines = 4}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: lines,
            maxLines: lines + 6,
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Enviar'),
          ),
        ],
      ),
    );
    controller.dispose();
    final text = result?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  Future<void> _requestChanges(OrqRun run, OrqTask task) async {
    final note = await _ask(
      'Pedir ajustes a ${task.provider}',
      'O que precisa mudar (o agente continua a mesma sessão)',
    );
    if (note != null) {
      await _run(() => _orq.requestChanges(run.id, task.id, note));
    }
  }

  Future<void> _handoff(OrqRun run, OrqTask task) async {
    final providers = AgentProvider.values
        .where((p) => p.name != task.provider)
        .toList();
    var target = providers.first;
    final context = TextEditingController();
    final ok = await showDialog<bool>(
      context: this.context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: Text('Transferir "${task.title}"'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<AgentProvider>(
                  initialValue: target,
                  decoration: const InputDecoration(labelText: 'Novo agente'),
                  items: [
                    for (final p in providers)
                      DropdownMenuItem(value: p, child: Text(p.tabLabel)),
                  ],
                  onChanged: (value) =>
                      setLocal(() => target = value ?? target),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: context,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Contexto para o novo agente (opcional)',
                    hintText:
                        'O pacote de continuidade (objetivo, critérios, '
                        'eventos) é enviado automaticamente',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Transferir'),
            ),
          ],
        ),
      ),
    );
    final text = context.text;
    context.dispose();
    if (ok == true) {
      await _run(
        () => _orq.handoff(run.id, task.id, target.name, context: text),
      );
    }
  }

  Future<void> _editPlan(OrqRun run) async {
    final controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert({
        'title': run.title,
        'tasks': [
          for (final t in run.tasks)
            {
              'id': t.id,
              'title': t.title,
              'description': t.description,
              'acceptanceCriteria': t.acceptanceCriteria,
              'dependsOn': t.dependsOn,
              'provider': t.provider,
              'model': t.model,
              'effort': t.effort,
              'target': t.target.name,
              'worktree': t.worktree,
              'base': t.base,
            },
        ],
      }),
    );
    String? error;
    final edited = await showDialog<OrqPlanReply>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('Editar plano'),
          content: SizedBox(
            width: 640,
            height: 460,
            child: Column(
              children: [
                Text(
                  'provider: claude, chatgpt, gemini, copilot ou auto · '
                  'target: project ou gestor · worktree vazio = isolada, '
                  '"current" = checkout atual',
                  style: const TextStyle(fontSize: 11.5),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: TextField(
                    controller: controller,
                    expands: true,
                    maxLines: null,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      errorText: error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(
                    dialogContext,
                    validatePlan(jsonDecode(controller.text)),
                  );
                } on OrqPlanException catch (e) {
                  setLocal(() => error = e.message);
                } on FormatException catch (e) {
                  setLocal(() => error = 'JSON inválido: ${e.message}');
                }
              },
              child: const Text('Aprovar e iniciar'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (edited != null) {
      run.title = edited.title;
      await _run(() => _orq.approvePlan(run.id, edited: edited.tasks));
    }
  }

  Future<void> _showDiff(OrqRun run, OrqTask task) async {
    final changes = await _orq.changesFor(run.id, task.id);
    if (!mounted) return;
    final file = TextEditingController();
    final line = TextEditingController();
    final comment = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Alterações · ${task.id}'),
        content: SizedBox(
          width: 760,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                [
                  for (final f in task.changedFiles) '${f.code} ${f.path}',
                ].join('\n'),
                style: const TextStyle(fontSize: 12),
              ),
              if (changes?.untracked ?? false)
                const Text(
                  'Arquivos novos aparecem na lista; o diff mostra só os '
                  'arquivos rastreados.',
                  style: TextStyle(fontSize: 11),
                ),
              if (changes?.truncated ?? false)
                const Text(
                  'Diff grande: prévia limitada.',
                  style: TextStyle(fontSize: 11),
                ),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    changes?.diff.isNotEmpty == true
                        ? changes!.diff
                        : '(sem diff de arquivos rastreados)',
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ),
              if (task.status == OrqTaskStatus.awaitingReview &&
                  !(changes?.truncated ?? true)) ...[
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: file,
                        decoration: const InputDecoration(
                          labelText: 'Arquivo',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: line,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Linha',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: comment,
                  decoration: const InputDecoration(
                    labelText: 'Comentário para o agente (linha adicionada)',
                    isDense: true,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Fechar'),
          ),
          if (task.status == OrqTaskStatus.awaitingReview &&
              !(changes?.truncated ?? true))
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Enviar comentário'),
            ),
        ],
      ),
    );
    if (send == true) {
      await _run(
        () => _orq.commentLine(
          run.id,
          task.id,
          file.text.trim(),
          int.tryParse(line.text.trim()) ?? 0,
          comment.text,
        ),
      );
    }
    file.dispose();
    line.dispose();
    comment.dispose();
  }

  Future<void> _syncAndBuild() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Sincronizando e compilando…')),
    );
    final log = await _orq.syncAndBuild();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sincronizar e compilar'),
        content: SizedBox(
          width: 640,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              log,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 11.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _OrqSettingsDialog(
        settings: _orq.settings,
        onPrepareProject: widget.onPrepareProject,
        memoryPanel: widget.memoryPanel,
        onProfileLogin: widget.onProfileLogin,
      ),
    );
    if (saved == true) await _orq.saveSettings();
  }

  Future<void> _copyAgentReport(String report) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Relat\u00f3rio completo copiado.')),
    );
  }
}

class _OrqSettingsDialog extends StatefulWidget {
  const _OrqSettingsDialog({
    required this.settings,
    this.onPrepareProject,
    this.memoryPanel,
    this.onProfileLogin,
  });

  final OrqSettings settings;
  final Future<void> Function(OrqProfile profile)? onProfileLogin;
  final Future<String> Function(String projectPath)? onPrepareProject;
  final Widget Function(BuildContext context)? memoryPanel;

  @override
  State<_OrqSettingsDialog> createState() => _OrqSettingsDialogState();
}

class _OrqSettingsDialogState extends State<_OrqSettingsDialog> {
  late final s = widget.settings;
  late final _project = TextEditingController(text: s.projectPath);
  late final _command = TextEditingController(text: s.buildCommand);
  late final _args = TextEditingController(text: s.buildArgs);
  late final _dir = TextEditingController(text: s.buildDir);
  late final _upstreams = TextEditingController(
    text: [
      for (final u in s.upstreams) '${u.path} ${u.remote} ${u.branch}'.trim(),
    ].join('\n'),
  );
  String _prepareResult = '';
  final _profileName = TextEditingController();
  String _profileProvider = 'claude';
  int _profileParallel = 1;

  void _addProfile() {
    final name = _profileName.text.trim();
    if (name.isEmpty) return;
    final base = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    var id = '$_profileProvider-${base.isEmpty ? 'conta' : base}';
    var n = 2;
    while (s.profile(id) != null) {
      id = '$_profileProvider-${base.isEmpty ? 'conta' : base}-${n++}';
    }
    setState(() {
      s.profiles = [
        ...s.profiles,
        OrqProfile(
          id: id,
          provider: _profileProvider,
          name: name,
          maxParallel: _profileParallel,
        ),
      ];
      _profileName.clear();
    });
  }

  @override
  void dispose() {
    for (final c in [
      _project,
      _command,
      _args,
      _dir,
      _upstreams,
      _profileName,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    s
      ..projectPath = _project.text
      ..buildCommand = _command.text.trim()
      ..buildArgs = _args.text.trim()
      ..buildDir = _dir.text.trim()
      ..upstreams = [
        for (final line in _upstreams.text.split('\n'))
          if (line.trim().isNotEmpty)
            () {
              final parts = line.trim().split(RegExp(r'\s+'));
              return OrqUpstream(
                path: parts[0],
                remote: parts.length > 1 ? parts[1] : 'origin',
                branch: parts.length > 2 ? parts[2] : '',
              );
            }(),
      ];
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
    return AlertDialog(
      title: const Text('Configurações do Orquestrador'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              section('Agentes'),
              DropdownButtonFormField<AgentProvider>(
                initialValue: s.coordinator,
                decoration: const InputDecoration(
                  labelText: 'Coordenador (planeja, só leitura)',
                ),
                items: [
                  for (final p in AgentProvider.values)
                    DropdownMenuItem(value: p, child: Text(p.tabLabel)),
                ],
                onChanged: (v) =>
                    setState(() => s.coordinator = v ?? s.coordinator),
              ),
              DropdownButtonFormField<String>(
                initialValue: s.coordinatorEffort,
                decoration: const InputDecoration(
                  labelText: 'Esforço do coordenador (menos = menos tokens)',
                ),
                items: const [
                  DropdownMenuItem(value: '', child: Text('Padrão da conta')),
                  DropdownMenuItem(value: 'low', child: Text('Baixo')),
                  DropdownMenuItem(
                    value: 'medium',
                    child: Text('Médio (recomendado)'),
                  ),
                  DropdownMenuItem(value: 'high', child: Text('Alto')),
                ],
                onChanged: (v) => setState(() => s.coordinatorEffort = v ?? ''),
              ),
              const SizedBox(height: 6),
              const Text(
                'Trabalhadores permitidos',
                style: TextStyle(fontSize: 12),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final p in AgentProvider.values)
                    FilterChip(
                      label: Text(p.tabLabel),
                      selected: s.workers.contains(p),
                      onSelected: (on) => setState(() {
                        if (on) {
                          s.workers.add(p);
                        } else if (s.workers.length > 1) {
                          s.workers.remove(p);
                        }
                      }),
                    ),
                ],
              ),
              DropdownButtonFormField<AgentProvider>(
                initialValue: s.defaultWorker,
                decoration: const InputDecoration(
                  labelText: 'Trabalhador padrão (quando o plano diz "auto")',
                ),
                items: [
                  for (final p in AgentProvider.values)
                    DropdownMenuItem(value: p, child: Text(p.tabLabel)),
                ],
                onChanged: (v) =>
                    setState(() => s.defaultWorker = v ?? s.defaultWorker),
              ),
              DropdownButtonFormField<AgentAccess>(
                initialValue: s.workerAccess,
                decoration: const InputDecoration(
                  labelText: 'Permissão dos trabalhadores (tarefas de projeto)',
                ),
                items: [
                  for (final a in AgentAccess.values.where(
                    (a) => a != AgentAccess.gestor,
                  ))
                    DropdownMenuItem(value: a, child: Text(a.label)),
                ],
                onChanged: (v) =>
                    setState(() => s.workerAccess = v ?? s.workerAccess),
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: s.maxParallel,
                      decoration: const InputDecoration(
                        labelText: 'Tarefas em paralelo',
                      ),
                      items: [
                        for (var i = 1; i <= 6; i++)
                          DropdownMenuItem(value: i, child: Text('$i')),
                      ],
                      onChanged: (v) =>
                          setState(() => s.maxParallel = v ?? s.maxParallel),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: s.maxAttempts,
                      decoration: const InputDecoration(
                        labelText: 'Tentativas por tarefa',
                      ),
                      items: [
                        for (var i = 1; i <= 6; i++)
                          DropdownMenuItem(value: i, child: Text('$i')),
                      ],
                      onChanged: (v) =>
                          setState(() => s.maxAttempts = v ?? s.maxAttempts),
                    ),
                  ),
                ],
              ),
              section('Perfis (outras contas do Claude Code e do Codex)'),
              for (final profile in s.profiles)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${profile.name} · '
                        '${profile.provider == 'claude' ? 'Claude Code' : 'Codex'}'
                        ' · ${profile.id} · até ${profile.maxParallel}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (widget.onProfileLogin != null)
                      TextButton(
                        onPressed: () => widget.onProfileLogin!(profile),
                        child: const Text('Entrar'),
                      ),
                    IconButton(
                      tooltip: 'Remover perfil',
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () => setState(
                        () => s.profiles = [
                          for (final other in s.profiles)
                            if (other.id != profile.id) other,
                        ],
                      ),
                    ),
                  ],
                ),
              Row(
                children: [
                  DropdownButton<String>(
                    value: _profileProvider,
                    items: const [
                      DropdownMenuItem(
                        value: 'claude',
                        child: Text('Claude Code'),
                      ),
                      DropdownMenuItem(value: 'chatgpt', child: Text('Codex')),
                    ],
                    onChanged: (v) =>
                        setState(() => _profileProvider = v ?? 'claude'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _profileName,
                      decoration: const InputDecoration(
                        hintText: 'Nome da conta (ex.: Trabalho)',
                        isDense: true,
                      ),
                    ),
                  ),
                  DropdownButton<int>(
                    value: _profileParallel,
                    items: [
                      for (var i = 1; i <= 4; i++)
                        DropdownMenuItem(value: i, child: Text('$i×')),
                    ],
                    onChanged: (v) => setState(() => _profileParallel = v ?? 1),
                  ),
                  TextButton(
                    onPressed: _addProfile,
                    child: const Text('Adicionar'),
                  ),
                ],
              ),
              const Text(
                'Cada perfil usa uma pasta própria (CLAUDE_CONFIG_DIR ou '
                'CODEX_HOME). Depois de adicionar, salve e clique em "Entrar" '
                'para fazer o login oficial do CLI nessa conta.',
                style: TextStyle(fontSize: 11),
              ),
              section('Projeto (neste computador)'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _project,
                      decoration: const InputDecoration(
                        labelText: 'Pasta do projeto (repositório Git)',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Escolher pasta',
                    icon: const Icon(Icons.folder_open_rounded),
                    onPressed: () async {
                      final dir = await FilePicker.platform.getDirectoryPath(
                        dialogTitle: 'Pasta do projeto',
                      );
                      if (dir != null) setState(() => _project.text = dir);
                    },
                  ),
                ],
              ),
              if (widget.onPrepareProject != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 16,
                    ),
                    label: const Text('Preparar projeto (.ai)'),
                    onPressed: () async {
                      try {
                        final message = await widget.onPrepareProject!(
                          _project.text.trim(),
                        );
                        setState(() => _prepareResult = message);
                      } on Object catch (error) {
                        setState(() => _prepareResult = '$error');
                      }
                    },
                  ),
                ),
              if (_prepareResult.isNotEmpty)
                Text(_prepareResult, style: const TextStyle(fontSize: 11.5)),
              section('Build'),
              TextField(
                controller: _command,
                decoration: const InputDecoration(
                  labelText: 'Comando (ex.: flutter, npm)',
                ),
              ),
              TextField(
                controller: _args,
                decoration: const InputDecoration(
                  labelText: 'Argumentos (ex.: build windows)',
                ),
              ),
              TextField(
                controller: _dir,
                decoration: const InputDecoration(
                  labelText: 'Pasta do build (relativa ao projeto)',
                ),
              ),
              TextField(
                controller: _upstreams,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText:
                      'Upstreams (um por linha: pasta remoto branch) — '
                      'sincronizados só por fast-forward antes do build',
                ),
              ),
              section('Memória'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Usar o AI Memory'),
                subtitle: const Text(
                  'Página por tarefa e relatório por tentativa no runtime '
                  'oficial do AI Memory (MIT, akitaonrails/ai-memory).',
                ),
                value: s.aiMemory,
                onChanged: (v) => setState(() => s.aiMemory = v),
              ),
              if (widget.memoryPanel != null) widget.memoryPanel!(context),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _save, child: const Text('Salvar')),
      ],
    );
  }
}

/// Painel do AI Memory nas configurações do Orquestrador: estado, instalação
/// da release oficial fixada (com SHA-256) e aviso de licença.
class AiMemoryPanel extends StatefulWidget {
  const AiMemoryPanel({required this.bridge, this.onChanged, super.key});

  final AiMemoryBridge bridge;
  final VoidCallback? onChanged;

  @override
  State<AiMemoryPanel> createState() => _AiMemoryPanelState();
}

class _AiMemoryPanelState extends State<AiMemoryPanel> {
  double? _progress;
  String _error = '';
  bool _installed = false;

  @override
  void initState() {
    super.initState();
    widget.bridge.runtime.executable().then((exe) {
      if (mounted) setState(() => _installed = exe != null);
    });
  }

  Future<void> _install() async {
    setState(() {
      _progress = 0;
      _error = '';
    });
    try {
      await widget.bridge.runtime.install(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await widget.bridge.start();
      _installed = true;
    } on Object catch (error) {
      _error = '$error';
    }
    if (mounted) setState(() => _progress = null);
    widget.onChanged?.call();
  }

  Future<void> _start() async {
    setState(() => _progress = -1);
    await widget.bridge.start();
    if (mounted) setState(() => _progress = null);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Estado: ${widget.bridge.statusLabel}',
        style: const TextStyle(fontSize: 12),
      ),
      Text(
        'Entre computadores: ${widget.bridge.shareStatus}',
        style: const TextStyle(fontSize: 12),
      ),
      if (_progress != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: LinearProgressIndicator(
            value: _progress! < 0 ? null : _progress,
          ),
        ),
      if (_error.isNotEmpty)
        Text(_error, style: const TextStyle(fontSize: 12, color: Colors.red)),
      Wrap(
        spacing: 8,
        children: [
          if (!_installed)
            OutlinedButton.icon(
              onPressed: _progress == null ? _install : null,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: Text(
                'Instalar AI Memory ${AiMemoryRelease.version} '
                '(${(AiMemoryRelease.sizeBytes / 1048576).toStringAsFixed(0)} MB)',
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: _progress == null ? _start : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 16),
              label: const Text('Iniciar / verificar'),
            ),
        ],
      ),
      const SizedBox(height: 4),
      const Text(
        'Baixado de github.com/${AiMemoryRelease.repository} (release '
        '${AiMemoryRelease.version}, SHA-256 conferido) e executado só neste '
        'computador, numa pasta privada e em 127.0.0.1. Licença MIT, '
        'Copyright (c) 2026 Fabio Akita.',
        style: TextStyle(fontSize: 11),
      ),
    ],
  );
}
