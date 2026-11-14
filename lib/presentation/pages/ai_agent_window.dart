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

  /// Modelos da conta conectada, por provedor/modo (carregados após login).
  final _modelCache = <String, List<AgentModel>>{};
  bool _loadingModels = false;

  // Tela de conexão (estilo VS Code).
  String? _loginStatus;
  final _loginLines = <String>[];
  bool _showApiKey = false;
  final _apiKeyInput = TextEditingController();
  bool _hasSavedKey = false;

  String get _modelKey => '${_settings.provider.name}.${_settings.mode.name}';

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
    await _refreshSavedKey();
    await _autoConnect();
    await _refreshUndo();
  }

  @override
  void dispose() {
    unawaited(_backend?.dispose());
    unawaited(_mcp?.stop());
    _input.dispose();
    _apiKeyInput.dispose();
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
      return switch (provider) {
        AgentProvider.claude => ClaudeApiBackend(
          apiKey: key,
          model: model,
          callTool: _callTool,
        ),
        AgentProvider.chatgpt => OpenAiApiBackend(
          apiKey: key,
          model: model,
          callTool: _callTool,
        ),
        AgentProvider.gemini => GeminiApiBackend(
          apiKey: key,
          model: model,
          callTool: _callTool,
        ),
      };
    }
    final mcp = _mcp ??= AgentMcpServer(
      _callTool,
      onToolCall: (name, input) {
        if (mounted) _addTool(name, input);
      },
    );
    await mcp.start();
    return cliBackendFor(
      provider,
      mcp: mcp,
      path: _settings.cliPathFor(provider),
      model: model,
    );
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
      unawaited(_loadModels(backend));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _backend = null);
      _loginLog('$error');
      if (!silent || error is! AgentException) {
        _error('$error');
      } else {
        _info('Não foi possível reconectar automaticamente: $error');
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Consulta os modelos disponíveis para a conta e habilita o seletor.
  Future<void> _loadModels(AgentBackend backend, {bool force = false}) async {
    final key = _modelKey;
    if (!force && _modelCache.containsKey(key)) return;
    setState(() => _loadingModels = true);
    try {
      final models = await backend.listModels();
      if (!mounted) return;
      setState(() => _modelCache[key] = models);
      _info(
        '${models.length} modelos disponíveis para ${_settings.provider.label}.',
      );
    } on Object catch (error) {
      _error('Não foi possível listar os modelos: $error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  /// Conecta sozinho quando o provedor já está logado (CLI) ou tem chave
  /// salva, como a extensão do VS Code faz ao abrir.
  bool _autoConnecting = false;

  Future<void> _autoConnect() async {
    if (!_settings.autoConnect || _backend != null || _connecting) return;
    final provider = _settings.provider;
    setState(() => _autoConnecting = true);
    var needsBrowser = false;
    try {
      var ready = false;
      if (_settings.mode == AgentAuthMode.apiKey) {
        ready = await AgentSettings.readApiKey(provider) != null;
      } else {
        final cli =
            cliBackendFor(
                  provider,
                  mcp: AgentMcpServer((_, _) async => '{}'),
                  path: _settings.cliPathFor(provider),
                  model: '',
                )
                as CliAgentBackend;
        final installed = await cli.isInstalled();
        ready = installed && await cli.isLoggedIn();
        // Instalado mas sem login: abre direto a tela de login no navegador.
        // (O Gemini CLI não aceita mais contas pessoais; fica no botão.)
        needsBrowser = installed && !ready && provider != AgentProvider.gemini;
      }
      if (ready && mounted && _settings.provider == provider) {
        await _connect(silent: true);
      }
    } finally {
      if (mounted) setState(() => _autoConnecting = false);
    }
    if (needsBrowser && mounted && _settings.provider == provider) {
      await _browserLogin();
    }
  }

  Future<void> _refreshSavedKey() async {
    final key = await AgentSettings.readApiKey(_settings.provider);
    if (mounted) setState(() => _hasSavedKey = key != null);
  }

  void _loginLog(String line) {
    if (!mounted) return;
    setState(() {
      _loginLines.add(line);
      if (_loginLines.length > 6) _loginLines.removeAt(0);
    });
  }

  /// Fluxo "Entrar com o navegador": instala o CLI se faltar, abre o login
  /// no navegador quando necessário e conecta ao terminar.
  Future<void> _browserLogin() async {
    if (_connecting) return;
    final provider = _settings.provider;
    setState(() {
      _settings.mode = AgentAuthMode.cli;
      _connecting = true;
      _loginLines.clear();
      _loginStatus = 'Verificando o ${provider.cliProductName}…';
    });
    await _settings.save();
    final cli =
        cliBackendFor(
              provider,
              mcp: AgentMcpServer((_, _) async => '{}'),
              path: _settings.cliPathFor(provider),
              model: '',
            )
            as CliAgentBackend;
    try {
      if (!await cli.isInstalled()) {
        setState(
          () => _loginStatus = 'Instalando o ${provider.cliProductName} (npm)…',
        );
        await cli.install(_loginLog);
      }
      if (!await cli.isLoggedIn()) {
        setState(
          () => _loginStatus = 'Conclua o login no navegador que foi aberto…',
        );
        await cli.loginWithBrowser(_loginLog);
      }
      setState(() {
        _connecting = false;
        _loginStatus = 'Conectando…';
      });
      await _connect();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _loginStatus = null;
        });
        _loginLog('Erro: $error');
      }
    } finally {
      if (mounted) setState(() => _loginStatus = null);
    }
  }

  Future<void> _connectWithApiKey() async {
    final provider = _settings.provider;
    final typed = _apiKeyInput.text.trim();
    if (typed.isNotEmpty) await AgentSettings.writeApiKey(provider, typed);
    _apiKeyInput.clear();
    setState(() {
      _settings.mode = AgentAuthMode.apiKey;
      _loginLines.clear();
    });
    await _settings.save();
    await _refreshSavedKey();
    await _connect();
  }

  Future<void> _selectProvider(AgentProvider provider) async {
    await _backend?.cancel();
    setState(() {
      _settings.provider = provider;
      _backend = null;
      _loginLines.clear();
      _showApiKey = false;
    });
    await _settings.save();
    await _refreshSavedKey();
    await _autoConnect();
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
        buffer.writeln(
          '### Planilha "${entry.key}" (colunas separadas por TAB)',
        );
        for (final row in entry.value.rows) {
          final cells = row.map(
            (c) => '${c?.value ?? ''}'.replaceAll('\n', ' '),
          );
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
      '.txt',
      '.csv',
      '.tsv',
      '.json',
      '.md',
      '.html',
      '.htm',
      '.xml',
      '.ics',
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
            if (_backend == null)
              Expanded(child: _connectPanel(context))
            else ...[
              Expanded(child: _chat(context)),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              _composer(context),
            ],
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SegmentedButton<AgentProvider>(
            // Só o ícone de cada provedor; o nome aparece ao passar o mouse.
            segments: [
              for (final provider in AgentProvider.values)
                ButtonSegment(
                  value: provider,
                  tooltip: provider.label,
                  label: ProviderIcon(provider),
                ),
            ],
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(52, 40),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            selected: {_settings.provider},
            onSelectionChanged: _busy || _connecting
                ? null
                : (value) => _selectProvider(value.first),
          ),
          if (connected) ...[
            _modelSelector(),
            Tooltip(
              message: '${_backend!.label}\nClique para desconectar.',
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _disconnect,
                icon: const Icon(
                  Icons.check_circle,
                  color: Colors.green,
                  size: 18,
                ),
                label: Text(
                  _settings.mode == AgentAuthMode.cli
                      ? 'Conectado · assinatura'
                      : 'Conectado · chave de API',
                ),
              ),
            ),
          ],
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

  /// Tela exibida enquanto não há conexão: botão central para entrar pelo
  /// navegador (como na extensão do VS Code) ou usar uma chave de API.
  Widget _connectPanel(BuildContext context) {
    final provider = _settings.provider;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_autoConnecting || (_connecting && _loginStatus == null)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProviderIcon(provider, size: 64),
            const SizedBox(height: 18),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 12),
            Text('Conectando ao ${provider.label}…'),
          ],
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProviderIcon(provider, size: 64),
              const SizedBox(height: 18),
              Text(
                'Agente de IA do Gestor UFU',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Entre com sua conta ${provider.label} para preencher, '
                'corrigir e copiar dados das funcionalidades do Gestor.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _connecting ? null : _browserLogin,
                  icon: _connecting && _loginStatus != null
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.open_in_browser_rounded),
                  label: Text('Entrar com ${provider.label} no navegador'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Usa sua assinatura pelo ${provider.cliProductName} '
                '(instalado automaticamente se necessário).',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (provider == AgentProvider.gemini) ...[
                const SizedBox(height: 8),
                Text(
                  'Atenção: o Gemini CLI não aceita mais contas Google pessoais '
                  '(só Gemini Code Assist pago). Para contas pessoais, use a '
                  'chave de API gratuita do Google AI Studio.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.warning,
                  ),
                ),
              ],
              if (_loginStatus != null) ...[
                const SizedBox(height: 16),
                Text(_loginStatus!, textAlign: TextAlign.center),
              ],
              if (_loginLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    _loginLines.join('\n'),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'ou',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 12),
              if (!_showApiKey)
                TextButton.icon(
                  onPressed: _connecting
                      ? null
                      : () => setState(() => _showApiKey = true),
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('Usar chave de API'),
                )
              else ...[
                TextField(
                  controller: _apiKeyInput,
                  obscureText: true,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: _hasSavedKey
                        ? 'Chave de API (salva — preencha para trocar)'
                        : 'Chave de API do ${provider.label}',
                    helperText: provider.apiKeyHint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _connectWithApiKey(),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _connecting ? null : _connectWithApiKey,
                    icon: const Icon(Icons.login_rounded),
                    label: Text(
                      _hasSavedKey
                          ? 'Conectar com a chave'
                          : 'Salvar chave e conectar',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
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
                  Icon(
                    Icons.build_circle_outlined,
                    size: 16,
                    color: scheme.primary,
                  ),
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
                tooltip:
                    'Anexar arquivos (xlsx, csv, txt, json, html, pdf, imagens)',
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

  String _modelLabel(String model) =>
      model.isEmpty ? 'Modelo padrão do CLI' : model;

  /// Seletor do modelo do provedor/modo atuais. Sugestões + "Outro modelo…"
  /// para digitar qualquer nome (ex.: um modelo novo ainda não listado).
  Widget _modelSelector() {
    final provider = _settings.provider;
    final mode = _settings.mode;
    final current = _settings.modelFor(provider, mode);
    final backend = _backend;
    final models = _modelCache[_modelKey];
    final ready = backend != null && models != null;
    const other = '\u0000outro';
    const refresh = '\u0000atualizar';
    String labelFor(String id) {
      for (final model in models ?? const <AgentModel>[]) {
        if (model.id == id) return model.label;
      }
      return _modelLabel(id);
    }

    return PopupMenuButton<String>(
      tooltip: ready
          ? 'Modelo do ${provider.label}'
          : 'Conecte para ver os modelos disponíveis na sua conta',
      enabled: ready && !_busy && !_connecting,
      onSelected: (value) async {
        if (value == refresh) {
          await _loadModels(backend!, force: true);
          return;
        }
        if (value == other) {
          final typed = await _askModelName(provider, current);
          if (typed == null) return;
          value = typed;
        }
        await _setModel(value);
      },
      itemBuilder: (context) => [
        for (final model in models ?? const <AgentModel>[])
          CheckedPopupMenuItem(
            value: model.id,
            checked: model.id == current,
            child: Text(
              model.isDefault && model.id.isNotEmpty
                  ? '${model.label}  (padrão)'
                  : model.label,
            ),
          ),
        if (!(models ?? const <AgentModel>[]).any((m) => m.id == current))
          CheckedPopupMenuItem(
            value: current,
            checked: true,
            child: Text(_modelLabel(current)),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: other,
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 10),
              Text('Outro modelo…'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: refresh,
          child: Row(
            children: [
              Icon(Icons.refresh_rounded, size: 18),
              SizedBox(width: 10),
              Text('Atualizar lista'),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loadingModels)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.memory_rounded,
                size: 18,
                color: ready ? null : Theme.of(context).disabledColor,
              ),
            const SizedBox(width: 6),
            Text(
              ready ? labelFor(current) : 'Modelo (conecte primeiro)',
              style: ready
                  ? null
                  : TextStyle(color: Theme.of(context).disabledColor),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Future<String?> _askModelName(AgentProvider provider, String current) async {
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Modelo do ${provider.label}'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Nome do modelo',
              helperText: _settings.mode == AgentAuthMode.cli
                  ? 'Vazio = modelo padrão do ${provider.cliProductName}.'
                  : 'Use o nome exato do modelo na API.',
            ),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Usar'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _setModel(String model) async {
    final provider = _settings.provider;
    final mode = _settings.mode;
    if (model == _settings.modelFor(provider, mode)) return;
    setState(() => _settings.setModel(provider, mode, model));
    await _settings.save();
    _info(
      'Modelo do ${provider.label}: ${_modelLabel(_settings.modelFor(provider, mode))}.',
    );
    // Reconecta para aplicar o modelo (inicia uma nova conversa).
    if (_backend != null) {
      setState(() => _backend = null);
      await _connect();
    }
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
        (p, m): TextEditingController(
          text: widget.settings.models['${p.name}.${m.name}'] ?? '',
        ),
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
        widget.settings.setModel(
          provider,
          mode,
          _models[(provider, mode)]!.text,
        );
      }
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _login(AgentProvider provider) async {
    final backend = cliBackendFor(
      provider,
      mcp: AgentMcpServer((_, _) async => '{}'),
      path: _paths[provider]!.text.trim(),
      model: '',
    );
    try {
      await openCliLogin(backend);
      setState(() => _message = provider.loginHint);
    } on Object catch (error) {
      setState(() => _message = '$error');
    }
  }

  Widget _providerSection(AgentProvider provider) {
    final hasKey = _hasKey[provider] ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ProviderIcon(provider),
            const SizedBox(width: 8),
            Text(
              provider.label,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Assinatura: usa o ${provider.cliProductName} '
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
            for (final provider in AgentProvider.values) ...[
              if (provider != AgentProvider.values.first)
                const Divider(height: 32),
              _providerSection(provider),
            ],
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

/// Cria o back-end do CLI oficial de cada provedor.
AgentBackend cliBackendFor(
  AgentProvider provider, {
  required AgentMcpServer mcp,
  required String path,
  required String model,
}) => switch (provider) {
  AgentProvider.claude => ClaudeCliBackend(
    mcp: mcp,
    configuredPath: path,
    model: model,
  ),
  AgentProvider.chatgpt => CodexCliBackend(
    mcp: mcp,
    configuredPath: path,
    model: model,
  ),
  AgentProvider.gemini => GeminiCliBackend(
    mcp: mcp,
    configuredPath: path,
    model: model,
  ),
};

/// Ícone de cada provedor (selo colorido). Para usar os logotipos oficiais,
/// basta trocar o conteúdo por imagens em assets.
class ProviderIcon extends StatelessWidget {
  const ProviderIcon(this.provider, {super.key, this.size = 22});

  final AgentProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, List<Color> colors) = switch (provider) {
      AgentProvider.claude => (
        Icons.brightness_7_rounded,
        const [Color(0xFFE08B6D), Color(0xFFC96442)],
      ),
      AgentProvider.chatgpt => (
        Icons.hub_rounded,
        const [Color(0xFF19C37D), Color(0xFF0E8A5F)],
      ),
      AgentProvider.gemini => (
        Icons.auto_awesome,
        const [Color(0xFF4796E3), Color(0xFF9177C7)],
      ),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(icon, size: size * 0.64, color: Colors.white),
    );
  }
}
