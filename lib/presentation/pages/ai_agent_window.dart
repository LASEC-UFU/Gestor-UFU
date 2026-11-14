import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_backends.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_mcp_server.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_skills.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';

/// Abre (ou traz para frente) a janela separada do Agente de IA. A janela é
/// independente e pode ser arrastada para outro monitor.
class AiAgentLauncher {
  static WindowController? _controller;
  static bool _opening = false;

  static Future<void> open({String? route}) async {
    final skill = AgentSkills.idForRoute(route);
    final existing = _controller;
    if (existing != null) {
      final windows = await WindowController.getAll();
      if (windows.any((w) => w.windowId == existing.windowId)) {
        try {
          await const WindowMethodChannel(
            _windowChannel,
            mode: ChannelMode.bidirectional,
          ).invokeMethod<bool>('focusSkill', skill);
        } catch (_) {}
        await existing.show();
        return;
      }
      _controller = null;
    }
    if (_opening) return;
    _opening = true;
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({
            'type': 'aiAgent',
            'skill': skill,
            'isLight': AppTheme.isLight,
          }),
        ),
      );
      _controller = controller;
      await controller.show();
    } finally {
      _opening = false;
    }
  }
}

const _windowChannel = 'gestor_ufu_ai_agent_window';

class AiAgentWindowApp extends StatelessWidget {
  const AiAgentWindowApp({
    required this.initialSkill,
    required this.isLight,
    super.key,
  });

  final String initialSkill;
  final bool isLight;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: isLight ? ThemeMode.light : ThemeMode.dark,
    home: AiAgentPage(initialSkill: initialSkill),
  );
}

enum _Role { user, agent, tool, info, error }

class _ChatItem {
  _ChatItem(this.role, this.text, {this.attachments = const []});
  final _Role role;
  final String text;
  final List<String> attachments;
}

class AiAgentPage extends StatefulWidget {
  const AiAgentPage({required this.initialSkill, super.key});

  final String initialSkill;

  @override
  State<AiAgentPage> createState() => _AiAgentPageState();
}

class _AiAgentPageState extends State<AiAgentPage> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  final _items = <_ChatItem>[];
  final _attachments = <AgentAttachment>[];
  final _host = const WindowMethodChannel(
    agentToolChannelName,
    mode: ChannelMode.bidirectional,
  );

  AgentSettings _settings = AgentSettings();
  AgentBackend? _backend;
  AgentMcpServer? _mcp;
  late String _skill = widget.initialSkill;
  String? _pendingSkillNote;
  bool _manualSkill = false;
  bool _connecting = false;
  bool _busy = false;
  int _undoCount = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    await const WindowMethodChannel(
      _windowChannel,
      mode: ChannelMode.bidirectional,
    ).setMethodCallHandler((call) async {
      if (call.method == 'focusSkill' && call.arguments is String) {
        _changeSkill(call.arguments as String, announce: false);
        return true;
      }
      return null;
    });
    final settings = await AgentSettings.load();
    if (!mounted) return;
    setState(() => _settings = settings);
    _info(
      'Escolha Claude ou ChatGPT e conecte. A skill de '
      '"${AgentSkills.byId(_skill)?.title}" é entregue ao agente ao conectar.',
    );
    if (settings.autoConnect) await _connect(silent: true);
    await _refreshUndo();
  }

  @override
  void dispose() {
    unawaited(_backend?.dispose());
    unawaited(_mcp?.stop());
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- conexão

  Future<String> _callTool(String name, Map<String, dynamic> input) async {
    final result = await _host.invokeMethod<String>('tool', {
      'name': name,
      'input': jsonEncode(input),
    });
    if (agentTools.any((t) => t.name == name && t.mutates)) {
      unawaited(_refreshUndo());
    }
    return result ?? '{"error":"Sem resposta da janela principal."}';
  }

  Future<void> _refreshUndo() async {
    try {
      final count = await _host.invokeMethod<int>('undoCount');
      if (mounted) setState(() => _undoCount = count ?? 0);
    } catch (_) {}
  }

  Future<AgentBackend> _buildBackend() async {
    final provider = _settings.provider;
    final mode = _settings.mode;
    final model = _settings.modelFor(provider, mode);
    if (mode == AgentAuthMode.apiKey) {
      final key = await AgentSettings.readApiKey(provider);
      if (key == null) {
        throw AgentException(
          'Informe a chave de API do ${provider.label} nas configurações.',
        );
      }
      return provider == AgentProvider.claude
          ? ClaudeApiBackend(apiKey: key, model: model, callTool: _callTool)
          : OpenAiApiBackend(apiKey: key, model: model, callTool: _callTool);
    }
    final mcp = _mcp ??= AgentMcpServer(
      _callTool,
      onToolCall: (name, input) {
        if (mounted) _addTool(name, input);
      },
    );
    await mcp.start();
    final path = _settings.cliPathFor(provider);
    return provider == AgentProvider.claude
        ? ClaudeCliBackend(mcp: mcp, configuredPath: path, model: model)
        : CodexCliBackend(mcp: mcp, configuredPath: path, model: model);
  }

  Future<void> _connect({bool silent = false}) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      await _backend?.cancel();
      final backend = await _buildBackend();
      final status = await backend.verify();
      backend.systemPrompt = AgentSkills.systemPrompt(_skill);
      _pendingSkillNote = null;
      _settings.autoConnect = true;
      await _settings.save();
      if (!mounted) return;
      setState(() => _backend = backend);
      _info('Conectado: ${backend.label}. $status');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _backend = null);
      if (!silent || error is! AgentException) {
        _error('$error');
      } else {
        _info('Não foi possível reconectar automaticamente: $error');
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    await _backend?.cancel();
    _settings.autoConnect = false;
    await _settings.save();
    setState(() => _backend = null);
    _info('Desconectado.');
  }

  void _changeSkill(String id, {bool announce = true}) {
    if (id == _skill || AgentSkills.byId(id) == null) return;
    setState(() => _skill = id);
    final skill = AgentSkills.byId(id)!;
    if (_backend != null) {
      _pendingSkillNote =
          '<skill_ativa modulo="${skill.id}">\nO usuário mudou o foco para '
          '"${skill.title}".\n${skill.body}\n</skill_ativa>\n\n';
    }
    if (announce || _backend != null) _info('Foco: ${skill.title}.');
  }

  // ------------------------------------------------------------- conversa

  Future<void> _send() async {
    final backend = _backend;
    final text = _input.text.trim();
    if (backend == null || _busy || (text.isEmpty && _attachments.isEmpty)) {
      return;
    }
    final attachments = List<AgentAttachment>.of(_attachments);
    final prompt = text.isEmpty
        ? 'Analise os anexos e proponha como usá-los no Gestor UFU.'
        : text;
    setState(() {
      _items.add(
        _ChatItem(
          _Role.user,
          prompt,
          attachments: attachments.map((a) => a.name).toList(),
        ),
      );
      _attachments.clear();
      _input.clear();
      _busy = true;
    });
    _scrollToEnd();
    await _followMainWindowModule();
    final note = _pendingSkillNote;
    _pendingSkillNote = null;
    try {
      await backend.send('${note ?? ''}$prompt', attachments, (event) {
        if (!mounted) return;
        switch (event) {
          case AgentTextEvent(:final text):
            setState(() => _items.add(_ChatItem(_Role.agent, text)));
          case AgentToolEvent(:final name, :final input):
            _addTool(name, input);
          case AgentInfoEvent(:final text):
            _info(text);
        }
        _scrollToEnd();
      });
    } on Object catch (error) {
      _pendingSkillNote ??= note;
      _error('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshUndo();
      _inputFocus.requestFocus();
    }
  }

  /// Acompanha o módulo aberto na janela principal, a menos que o usuário
  /// tenha escolhido o foco manualmente.
  Future<void> _followMainWindowModule() async {
    if (_manualSkill) return;
    try {
      final id = await _host.invokeMethod<String>('currentSkill');
      if (id != null && id != AgentSkills.general) _changeSkill(id);
    } catch (_) {}
  }

  Future<void> _stop() async {
    await _backend?.cancel();
    _info('Solicitação interrompida.');
  }

  void _newConversation() {
    _backend?.reset();
    if (_backend != null) {
      _backend!.systemPrompt = AgentSkills.systemPrompt(_skill);
    }
    _pendingSkillNote = null;
    setState(() => _items.clear());
    _info('Nova conversa iniciada.');
  }

  Future<void> _undo() async {
    final result = await _host.invokeMethod<Object?>('undo');
    final map = result is Map ? result : const {};
    _info(
      map['ok'] == true
          ? 'Alteração desfeita na chave "${map['key']}".'
          : '${map['message'] ?? 'Nada para desfazer.'}',
    );
    await _refreshUndo();
  }

  void _addTool(String name, Map<String, dynamic> input) {
    final key = input['key'] ?? input['module'] ?? input['prefix'] ?? '';
    final ops = input['operations'] is List
        ? ' · ${(input['operations'] as List).length} operação(ões)'
        : '';
    setState(() => _items.add(_ChatItem(_Role.tool, '$name  $key$ops')));
    _scrollToEnd();
  }

  void _info(String text) {
    if (!mounted) return;
    setState(() => _items.add(_ChatItem(_Role.info, text)));
    _scrollToEnd();
  }

  void _error(String text) {
    if (!mounted) return;
    setState(() => _items.add(_ChatItem(_Role.error, text)));
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ------------------------------------------------------------- anexos

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    for (final file in result.files) {
      try {
        final attachment = await _readAttachment(file);
        setState(() => _attachments.add(attachment));
      } on Object catch (error) {
        _error('Não foi possível ler "${file.name}": $error');
      }
    }
  }

  Future<AgentAttachment> _readAttachment(PlatformFile file) async {
    final bytes =
        file.bytes ??
        (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) throw AgentException('arquivo vazio');
    final ext = p.extension(file.name).toLowerCase();
    const images = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
    };
    if (images.containsKey(ext)) {
      return AgentAttachment(
        name: file.name,
        mimeType: images[ext]!,
        bytes: bytes,
        localPath: file.path,
      );
    }
    if (ext == '.pdf') {
      return AgentAttachment(
        name: file.name,
        mimeType: 'application/pdf',
        bytes: bytes,
        localPath: file.path,
      );
    }
    if (ext == '.xlsx') {
      final excel = Excel.decodeBytes(bytes);
      final buffer = StringBuffer();
      for (final entry in excel.tables.entries) {
        buffer.writeln('### Planilha "${entry.key}" (colunas separadas por TAB)');
        for (final row in entry.value.rows) {
          final cells = row.map((c) => '${c?.value ?? ''}'.replaceAll('\n', ' '));
          if (cells.every((c) => c.trim().isEmpty)) continue;
          buffer.writeln(cells.join('\t'));
        }
      }
      return AgentAttachment(
        name: file.name,
        mimeType: 'text/plain',
        text: buffer.toString(),
      );
    }
    const textExtensions = {
      '.txt', '.csv', '.tsv', '.json', '.md', '.html', '.htm', '.xml', '.ics',
    };
    if (textExtensions.contains(ext) || ext.isEmpty) {
      return AgentAttachment(
        name: file.name,
        mimeType: 'text/plain',
        text: utf8.decode(bytes, allowMalformed: true),
      );
    }
    throw AgentException(
      'formato não suportado (use xlsx, csv, txt, json, html, pdf ou imagens)',
    );
  }

  Future<void> _pasteImageOrText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    // Textos longos colados viram anexo para não poluir a caixa de mensagem.
    if (text.length > 4000) {
      setState(
        () => _attachments.add(
          AgentAttachment(
            name: 'colado_${_attachments.length + 1}.txt',
            mimeType: 'text/plain',
            text: text,
          ),
        ),
      );
    } else {
      final selection = _input.selection;
      final start = selection.isValid ? selection.start : _input.text.length;
      final end = selection.isValid ? selection.end : _input.text.length;
      _input.value = TextEditingValue(
        text: _input.text.replaceRange(start, end, text),
        selection: TextSelection.collapsed(offset: start + text.length),
      );
    }
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _toolbar(context),
            const Divider(height: 1),
            Expanded(child: _chat(context)),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            _composer(context),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final connected = _backend != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.smart_toy_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Agente de IA',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SegmentedButton<AgentProvider>(
            segments: const [
              ButtonSegment(
                value: AgentProvider.claude,
                label: Text('Claude'),
              ),
              ButtonSegment(
                value: AgentProvider.chatgpt,
                label: Text('ChatGPT'),
              ),
            ],
            selected: {_settings.provider},
            onSelectionChanged: _busy || _connecting
                ? null
                : (value) async {
                    setState(() {
                      _settings.provider = value.first;
                      _backend = null;
                    });
                    await _settings.save();
                  },
          ),
          DropdownButton<AgentAuthMode>(
            value: _settings.mode,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(
                value: AgentAuthMode.cli,
                child: Text('Assinatura (CLI)'),
              ),
              DropdownMenuItem(
                value: AgentAuthMode.apiKey,
                child: Text('Chave de API'),
              ),
            ],
            onChanged: _busy || _connecting
                ? null
                : (value) async {
                    if (value == null) return;
                    setState(() {
                      _settings.mode = value;
                      _backend = null;
                    });
                    await _settings.save();
                  },
          ),
          if (connected)
            OutlinedButton.icon(
              onPressed: _busy ? null : _disconnect,
              icon: const Icon(Icons.check_circle, color: Colors.green, size: 18),
              label: const Text('Conectado'),
            )
          else
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded, size: 18),
              label: const Text('Conectar'),
            ),
          IconButton(
            tooltip: 'Configurações do agente (chaves, modelos, login)',
            onPressed: _busy ? null : _openSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 6),
          DropdownButton<String>(
            value: _skill,
            underline: const SizedBox.shrink(),
            items: [
              for (final skill in AgentSkills.all)
                DropdownMenuItem(
                  value: skill.id,
                  child: Text('Foco: ${skill.title}'),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    _manualSkill = true;
                    _changeSkill(value);
                  },
          ),
          IconButton(
            tooltip: 'Nova conversa',
            onPressed: _busy ? null : _newConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          Badge(
            isLabelVisible: _undoCount > 0,
            label: Text('$_undoCount'),
            child: IconButton(
              tooltip: 'Desfazer a última alteração do agente',
              onPressed: _busy || _undoCount == 0 ? null : _undo,
              icon: const Icon(Icons.undo_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chat(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        switch (item.role) {
          case _Role.tool:
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.build_circle_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.text,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            );
          case _Role.info:
          case _Role.error:
            final isError = item.role == _Role.error;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    isError ? Icons.error_outline : Icons.info_outline,
                    size: 16,
                    color: isError ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      item.text,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isError ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            );
          case _Role.user:
          case _Role.agent:
            final isUser = item.role == _Role.user;
            return Align(
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 760),
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isUser
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(
                          spacing: 6,
                          children: [
                            for (final name in item.attachments)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: const Icon(Icons.attach_file, size: 14),
                                label: Text(name),
                              ),
                          ],
                        ),
                      ),
                    SelectableText(item.text),
                  ],
                ),
              ),
            );
        }
      },
    );
  }

  Widget _composer(BuildContext context) {
    final enabled = _backend != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final attachment in List.of(_attachments))
                    InputChip(
                      avatar: Icon(
                        attachment.isImage
                            ? Icons.image_outlined
                            : attachment.isPdf
                            ? Icons.picture_as_pdf_outlined
                            : Icons.description_outlined,
                        size: 16,
                      ),
                      label: Text(attachment.name),
                      onDeleted: () =>
                          setState(() => _attachments.remove(attachment)),
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Anexar arquivos (xlsx, csv, txt, json, html, pdf, imagens)',
                onPressed: enabled && !_busy ? _pickFiles : null,
                icon: const Icon(Icons.attach_file_rounded),
              ),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): _send,
                    const SingleActivator(
                      LogicalKeyboardKey.keyV,
                      control: true,
                    ): _pasteImageOrText,
                  },
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText: enabled
                          ? 'Peça ao agente para preencher, corrigir ou copiar '
                                'dados… (Enter envia, Shift+Enter quebra linha)'
                          : 'Conecte-se ao Claude ou ao ChatGPT para começar.',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_busy)
                IconButton.filledTonal(
                  tooltip: 'Interromper',
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_rounded),
                )
              else
                IconButton.filled(
                  tooltip: 'Enviar',
                  onPressed: enabled ? _send : null,
                  icon: const Icon(Icons.send_rounded),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AgentSettingsDialog(settings: _settings),
    );
    if (saved == true) {
      await _settings.save();
      setState(() => _backend = null);
      _info('Configurações salvas. Clique em Conectar.');
    }
  }
}

class _AgentSettingsDialog extends StatefulWidget {
  const _AgentSettingsDialog({required this.settings});

  final AgentSettings settings;

  @override
  State<_AgentSettingsDialog> createState() => _AgentSettingsDialogState();
}

class _AgentSettingsDialogState extends State<_AgentSettingsDialog> {
  final _keys = {
    for (final p in AgentProvider.values) p: TextEditingController(),
  };
  final _hasKey = <AgentProvider, bool>{};
  late final _models = {
    for (final p in AgentProvider.values)
      for (final m in AgentAuthMode.values)
        (p, m): TextEditingController(text: widget.settings.models['${p.name}.${m.name}'] ?? ''),
  };
  late final _paths = {
    for (final p in AgentProvider.values)
      p: TextEditingController(text: widget.settings.cliPathFor(p)),
  };
  String? _message;

  @override
  void initState() {
    super.initState();
    for (final provider in AgentProvider.values) {
      AgentSettings.readApiKey(provider).then((value) {
        if (mounted) setState(() => _hasKey[provider] = value != null);
      });
    }
  }

  @override
  void dispose() {
    for (final c in [..._keys.values, ..._models.values, ..._paths.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    for (final provider in AgentProvider.values) {
      final key = _keys[provider]!.text.trim();
      if (key.isNotEmpty) await AgentSettings.writeApiKey(provider, key);
      widget.settings.cliPaths[provider.name] = _paths[provider]!.text.trim();
      for (final mode in AgentAuthMode.values) {
        widget.settings.setModel(provider, mode, _models[(provider, mode)]!.text);
      }
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _login(AgentProvider provider) async {
    final backend = provider == AgentProvider.claude
        ? ClaudeCliBackend(
            mcp: AgentMcpServer((_, _) async => '{}'),
            configuredPath: _paths[provider]!.text.trim(),
            model: '',
          )
        : CodexCliBackend(
            mcp: AgentMcpServer((_, _) async => '{}'),
            configuredPath: _paths[provider]!.text.trim(),
            model: '',
          );
    try {
      await openCliLogin(backend);
      setState(
        () => _message = provider == AgentProvider.claude
            ? 'Um terminal foi aberto com o Claude Code. Digite /login, conclua '
                  'o login com sua conta Claude (Pro/Max) e feche o terminal.'
            : 'Um terminal foi aberto com "codex login". Entre com sua conta '
                  'ChatGPT e feche o terminal ao terminar.',
      );
    } on Object catch (error) {
      setState(() => _message = '$error');
    }
  }

  Widget _providerSection(AgentProvider provider) {
    final hasKey = _hasKey[provider] ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          provider.label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Assinatura: usa o ${provider == AgentProvider.claude ? 'Claude Code' : 'Codex'} '
          'instalado neste computador, com o login da sua conta.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _paths[provider],
                decoration: InputDecoration(
                  labelText:
                      'Executável do ${provider.cliName} (vazio = detectar)',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _login(provider),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('Entrar'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _models[(provider, AgentAuthMode.cli)],
          decoration: const InputDecoration(
            labelText: 'Modelo no CLI (opcional)',
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keys[provider],
          obscureText: true,
          decoration: InputDecoration(
            labelText: hasKey
                ? 'Chave de API (salva — preencha para trocar)'
                : 'Chave de API',
            isDense: true,
            suffixIcon: hasKey
                ? IconButton(
                    tooltip: 'Apagar chave salva',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await AgentSettings.writeApiKey(provider, null);
                      setState(() => _hasKey[provider] = false);
                    },
                  )
                : null,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _models[(provider, AgentAuthMode.apiKey)],
          decoration: InputDecoration(
            labelText: 'Modelo na API (padrão ${provider.defaultApiModel})',
            isDense: true,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Configurações do Agente de IA'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'As chaves e preferências ficam no cofre seguro do Windows deste '
              'computador e não vão para o banco compartilhado.',
            ),
            const SizedBox(height: 16),
            _providerSection(AgentProvider.claude),
            const Divider(height: 32),
            _providerSection(AgentProvider.chatgpt),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],
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
