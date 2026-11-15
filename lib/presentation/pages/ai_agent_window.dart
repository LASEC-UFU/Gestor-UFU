import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:excel/excel.dart' show Excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_backends.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_computer.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_history.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_mcp_server.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_skills.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/presentation/pages/ai_agent_widgets.dart';

/// Abre (ou traz para frente) a janela separada do Agente de IA. A janela é
/// independente e pode ser arrastada para outro monitor.
class AiAgentLauncher {
  static WindowController? _controller;
  static bool _opening = false;

  static bool _channelReady = false;

  static Future<void> open({String? route}) async {
    final skill = AgentSkills.idForRoute(route);
    // A janela principal também se registra no canal da janela do agente
    // (exigência dos canais bidirecionais) para enviar o foco do módulo.
    if (!_channelReady) {
      try {
        await const WindowMethodChannel(
          _windowChannel,
          mode: ChannelMode.bidirectional,
        ).setMethodCallHandler((call) async => null);
        _channelReady = true;
      } catch (_) {}
    }
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

  ThemeData _theme(Brightness brightness) {
    final vs = VsColors(brightness == Brightness.dark);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Segoe UI',
      colorSchemeSeed: vs.accent,
      scaffoldBackgroundColor: vs.bg,
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: isLight ? ThemeMode.light : ThemeMode.dark,
    home: AiAgentPage(initialSkill: initialSkill),
  );
}

class _Approval {
  _Approval(this.tool, this.input);
  final String tool;
  final Map<String, dynamic> input;
  final completer = Completer<bool>();
}

/// Estado de um agente (aba). Cada aba roda de forma independente, então
/// vários agentes podem trabalhar ao mesmo tempo, como no VS Code.
class _Session {
  _Session(this.provider, this.conv);

  final AgentProvider provider;
  AgentConversation conv;
  AgentBackend? backend;
  AgentMcpServer? mcp;
  bool busy = false;
  bool thinking = false;
  bool allowAll = false;
  DateTime? thinkStart;
  String workWord = 'Pensando…';
  String? pendingSkillNote;

  /// Transcrição a enviar na próxima mensagem quando a sessão original não
  /// pode ser retomada (conversa feita em outro computador, por exemplo).
  String? pendingContext;

  /// Bloco de texto que está recebendo o streaming.
  AgentEntry? open;
  final toolEntries = <String, AgentEntry>{};
  final approvals = <_Approval>[];

  /// Mensagens escritas enquanto o agente trabalhava: entregues assim que
  /// o passo atual termina (como na extensão do VS Code).
  final queue = <_Queued>[];

  List<AgentEntry> get entries => conv.entries;
}

/// Mensagem na fila de uma aba.
class _Queued {
  _Queued(this.text, this.attachments);

  final String text;
  final List<AgentAttachment> attachments;
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
  final _composerKey = GlobalKey();
  final _attachments = <AgentAttachment>[];
  final _host = const WindowMethodChannel(
    agentToolChannelName,
    mode: ChannelMode.bidirectional,
  );

  AgentSettings _settings = AgentSettings();
  late String _skill = widget.initialSkill;
  bool _manualSkill = false;
  bool _connecting = false;
  int _undoCount = 0;

  static const _workWords = [
    'Pensando…',
    'Analisando…',
    'Ponderando…',
    'Cozinhando…',
    'Fervilhando…',
    'Matutando…',
    'Elaborando…',
    'Tramando…',
  ];

  /// Uma sessão por agente (aba); a janela mostra a da aba selecionada.
  final _sessions = <AgentProvider, _Session>{};
  _Session get _s => _sessions.putIfAbsent(
    _settings.provider,
    () => _Session(_settings.provider, _newConv()),
  );

  AgentBackend? get _backend => _s.backend;
  set _backend(AgentBackend? value) => _s.backend = value;
  AgentConversation get _conv => _s.conv;
  set _conv(AgentConversation value) => _s.conv = value;
  bool get _busy => _s.busy;
  bool get _thinking => _s.thinking;
  String get _workWord => _s.workWord;
  AgentEntry? get _open => _s.open;
  Map<String, AgentEntry> get _toolEntries => _s.toolEntries;
  List<_Approval> get _approvals => _s.approvals;
  set _allowAll(bool value) => _s.allowAll = value;
  set _pendingSkillNote(String? value) => _s.pendingSkillNote = value;

  /// Histórico (lista "Chats").
  List<AgentConversation> _recent = [];
  bool _showHistory = false;
  bool _showAllRecent = false;
  final _historySearch = TextEditingController();

  /// Modelos da conta conectada, por provedor/modo (carregados após login).
  final _modelCache = <String, List<AgentModel>>{};
  bool _loadingModels = false;

  // Tela de conexão.
  String? _loginStatus;
  final _loginLines = <String>[];
  bool _showApiKey = false;
  final _apiKeyInput = TextEditingController();
  bool _hasSavedKey = false;
  bool _autoConnecting = false;

  String get _modelKey => '${_settings.provider.name}.${_settings.mode.name}';
  List<AgentEntry> get _entries => _conv.entries;

  AgentConversation _newConv() => AgentConversation(
    id: const Uuid().v4(),
    provider: _settings.provider.name,
    mode: _settings.mode.name,
    skill: _skill,
  );

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    unawaited(_init());
  }

  Future<void> _init() async {
    // Canal bidirecional: as duas janelas precisam se registrar para que uma
    // possa chamar a outra (ferramentas, histórico, navegador…).
    try {
      await _host.setMethodCallHandler((call) async => null);
    } catch (error) {
      debugPrint('Agente: não registrou o canal do Gestor: $error');
    }
    await const WindowMethodChannel(
      _windowChannel,
      mode: ChannelMode.bidirectional,
    ).setMethodCallHandler((call) async {
      if (call.method == 'focusSkill' && call.arguments is String) {
        _changeSkill(call.arguments as String);
        return true;
      }
      return null;
    });
    final settings = await AgentSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _conv = _newConv();
    });
    unawaited(_reloadRecent());
    await _refreshSavedKey();
    await _autoConnect();
    await _refreshUndo();
  }

  @override
  void dispose() {
    for (final session in _sessions.values) {
      for (final approval in session.approvals) {
        if (!approval.completer.isCompleted) {
          approval.completer.complete(false);
        }
      }
      unawaited(session.backend?.dispose());
      unawaited(session.mcp?.stop());
    }
    _input.dispose();
    _apiKeyInput.dispose();
    _historySearch.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- ferramentas

  /// Executa uma ferramenta do Gestor para a sessão [s]. Back-ends que não
  /// relatam as ferramentas têm a chamada mostrada pela janela.
  AgentToolCaller _toolCaller(_Session s) => (name, input) async {
    // Controle do computador: desligado em "Só o Gestor"; cada ação (clique,
    // digitação, atalho...) pede aprovação nos modos que não são automáticos.
    if (name.startsWith('computer_')) {
      final access = _settings.access;
      if (access == AgentAccess.gestor) {
        return jsonEncode({
          'error':
              'O controle do computador está desligado no modo "Só o '
              'Gestor". Peça ao usuário para escolher outro modo de acesso.',
        });
      }
      final asks = {
        AgentAccess.manual,
        AgentAccess.plan,
        AgentAccess.acceptEdits,
      }.contains(access);
      if (asks && AgentComputer.actions.contains(name)) {
        final allowed = await _permissionFor(s)(name, input);
        if (!allowed) {
          return jsonEncode({
            'error': 'O usuário negou a ação no computador ($name).',
          });
        }
      }
    }
    // Comandos que exigem aprovação: confirma no chat antes de executar.
    if (name == 'run_command' && _settings.access != AgentAccess.bypass) {
      final command = ModuleRegistry.instance.commandById(
        '${input['command'] ?? ''}',
      );
      if (command != null && command.approval == CommandApproval.required) {
        final allowed = await _permissionFor(s)(
          'Comando: ${command.title}',
          Map<String, dynamic>.from(input['input'] as Map? ?? const {}),
        );
        if (!allowed) {
          return jsonEncode({'error': 'O usuário negou "${command.title}".'});
        }
      }
    }
    final show = !(s.backend?.reportsTools ?? false);
    AgentEntry? entry;
    if (show && mounted) {
      _closeOpen(s);
      entry = AgentEntry(
        AgentEntryKind.tool,
        '',
        toolName: name,
        toolInput: input,
        running: true,
      );
      setState(() => s.entries.add(entry!));
      if (identical(s, _s)) _scrollToEnd();
    }
    String result;
    try {
      result =
          await _host.invokeMethod<String>('tool', {
            'name': name,
            'input': jsonEncode(input),
          }) ??
          '{"error":"Sem resposta da janela principal."}';
    } on Object catch (error) {
      result = jsonEncode({'error': '$error'});
    }
    if (agentTools.any((t) => t.name == name && t.mutates)) {
      unawaited(_refreshUndo());
    }
    // A imagem (captura de tela) vai só para os CLIs, pelo MCP; no chat e
    // nas APIs fica um resumo em texto.
    final display = _withoutImage(result);
    if (entry != null && mounted) {
      setState(() {
        entry!
          ..running = false
          ..toolResult = display
          ..toolError = result.startsWith('{"error"');
      });
    }
    return s.backend is CliAgentBackend ? result : display;
  };

  static String _withoutImage(String result) {
    if (!result.contains('"image_base64"')) return result;
    try {
      final data = Map<String, dynamic>.from(jsonDecode(result) as Map)
        ..remove('image_base64')
        ..['image'] = '(captura de tela enviada ao agente)';
      return jsonEncode(data);
    } catch (_) {
      return result;
    }
  }

  /// Aprovação no chat (modos Manual, Editar automaticamente, Planejar…).
  AgentPermissionHandler _permissionFor(_Session s) => (tool, input) async {
    if (s.allowAll && tool != 'ExitPlanMode') return true;
    if (!mounted) return false;
    final approval = _Approval(tool, input);
    setState(() {
      _closeOpen(s);
      s.approvals.add(approval);
    });
    if (identical(s, _s)) _scrollToEnd(force: true);
    return approval.completer.future;
  };

  void _answer(_Approval approval, bool? allow) {
    if (allow == null) _allowAll = true;
    final allowed = allow ?? true;
    setState(() {
      _approvals.remove(approval);
      _entries.add(
        AgentEntry(
          AgentEntryKind.info,
          allowed
              ? '${agentToolLabel(approval.tool)}: permitido.'
              : '${agentToolLabel(approval.tool)}: negado.',
        ),
      );
    });
    if (!approval.completer.isCompleted) approval.completer.complete(allowed);
    if (approval.tool == 'ExitPlanMode' && allowed) {
      // Plano aprovado: sai do modo Planejar, como na extensão.
      unawaited(_setAccess(AgentAccess.acceptEdits, announce: false));
    }
  }

  Future<void> _refreshUndo() async {
    try {
      final count = await _host.invokeMethod<int>('undoCount');
      if (mounted) setState(() => _undoCount = count ?? 0);
    } catch (_) {}
  }

  // ------------------------------------------------------------- conexão

  Future<AgentBackend> _buildBackend(_Session s) async {
    final provider = s.provider;
    final mode = _settings.modeFor(provider);
    final model = _settings.modelFor(provider, mode);
    final callTool = _toolCaller(s);
    AgentBackend backend;
    if (mode == AgentAuthMode.apiKey) {
      final key = await AgentSettings.readApiKey(provider);
      if (key == null) {
        throw AgentException(
          'Informe a chave de API do ${provider.label} nas configurações.',
        );
      }
      backend = switch (provider) {
        AgentProvider.claude => ClaudeApiBackend(
          apiKey: key,
          model: model,
          callTool: callTool,
        ),
        AgentProvider.chatgpt => OpenAiApiBackend(
          apiKey: key,
          model: model,
          callTool: callTool,
        ),
        AgentProvider.gemini => GeminiApiBackend(
          apiKey: key,
          model: model,
          callTool: callTool,
        ),
        AgentProvider.copilot => throw AgentException(
          'O GitHub Copilot funciona só com a assinatura (login GitHub).',
        ),
      };
    } else {
      // Servidor MCP próprio de cada aba: as ferramentas e aprovações vão
      // para a conversa certa mesmo com agentes rodando em paralelo.
      final mcp = s.mcp ??= AgentMcpServer(callTool);
      mcp.onPermission = _permissionFor(s);
      await mcp.start();
      backend = cliBackendFor(
        provider,
        mcp: mcp,
        path: _settings.cliPathFor(provider),
        model: model,
      );
    }
    return backend
      ..access = _settings.access
      ..effort = _settings.effort
      ..workDir = _settings.workDir
      ..onPermission = _permissionFor(s)
      ..systemPrompt = AgentSkills.systemPrompt(_skill);
  }

  Future<void> _connect({bool silent = false}) async {
    if (_connecting) return;
    final s = _s;
    setState(() => _connecting = true);
    try {
      final previous = s.backend;
      final state = previous?.saveState();
      await previous?.cancel();
      final backend = await _buildBackend(s);
      await backend.verify();
      s.pendingSkillNote = null;
      // Mantém a conversa aberta (troca de modelo) ou retoma do histórico.
      if (state != null && state.isNotEmpty) {
        backend.restoreState(state);
      } else if (s.conv.hasMessages) {
        await _restoreInto(s, backend, s.conv);
      }
      _settings.autoConnect = true;
      await _settings.save();
      if (!mounted) return;
      setState(() {
        s.backend = backend;
        if (!s.conv.hasMessages) {
          s.conv
            ..provider = s.provider.name
            ..mode = _settings.modeFor(s.provider).name;
        }
      });
      unawaited(previous?.dispose());
      if (identical(s, _s)) unawaited(_loadModels(backend));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => s.backend = null);
      _loginLog('$error');
      if (!silent || error is! AgentException) _error('$error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _loadModels(AgentBackend backend, {bool force = false}) async {
    final key = _modelKey;
    if (!force && _modelCache.containsKey(key)) return;
    setState(() => _loadingModels = true);
    try {
      final models = await backend.listModels();
      if (!mounted) return;
      setState(() => _modelCache[key] = models);
    } on Object catch (error) {
      _error('Não foi possível listar os modelos: $error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  /// Conecta sozinho quando o provedor já está logado (CLI) ou tem chave
  /// salva; se o CLI estiver instalado mas sem login, abre o navegador.
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
        final cli = _probe(provider);
        final installed = await cli.isInstalled();
        ready = installed && await cli.isLoggedIn();
        needsBrowser = installed && !ready;
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

  CliAgentBackend _probe(AgentProvider provider) =>
      cliBackendFor(
            provider,
            mcp: AgentMcpServer((_, _) async => '{}'),
            path: _settings.cliPathFor(provider),
            model: '',
          )
          as CliAgentBackend;

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
    final cli = _probe(provider);
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
        setState(() => _connecting = false);
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
    await _disposeBackend();
    await _connect();
  }

  Future<void> _disposeBackend() async {
    final backend = _backend;
    _backend = null;
    await backend?.cancel();
    await backend?.dispose();
  }

  /// Troca de aba. Cada agente mantém a sua sessão (conectado, com a sua
  /// conversa e até trabalhando), então voltar a ele é imediato.
  Future<void> _selectProvider(AgentProvider provider) async {
    if (provider == _settings.provider) {
      if (_backend == null) await _autoConnect();
      return;
    }
    await _saveConversation();
    setState(() {
      _settings.provider = provider;
      _loginLines.clear();
      _showApiKey = false;
      _showHistory = false;
    });
    await _settings.save();
    await _refreshSavedKey();
    if (_backend == null) {
      await _autoConnect();
    } else {
      unawaited(_loadModels(_backend!));
    }
    _scrollToEnd(force: true);
  }

  Future<void> _disconnect() async {
    await _saveConversation();
    await _disposeBackend();
    _settings.autoConnect = false;
    await _settings.save();
    if (mounted) setState(() {});
  }

  void _changeSkill(String id) {
    if (id == _skill || AgentSkills.byId(id) == null) return;
    setState(() {
      _skill = id;
      _conv.skill = id;
    });
    final skill = AgentSkills.byId(id)!;
    if (_backend != null) {
      _pendingSkillNote =
          '<skill_ativa modulo="${skill.id}">\nO usuário mudou o foco para '
          '"${skill.title}".\n${skill.body}\n</skill_ativa>\n\n';
    }
  }

  Future<void> _setAccess(AgentAccess access, {bool announce = true}) async {
    if (access == _settings.access) return;
    setState(() => _settings.access = access);
    await _settings.save();
    for (final session in _sessions.values) {
      session.backend
        ?..access = access
        ..refreshSession();
    }
    if (announce) _info('Modo: ${access.label}.');
  }

  void _cycleAccess() {
    const order = [
      AgentAccess.manual,
      AgentAccess.acceptEdits,
      AgentAccess.plan,
      AgentAccess.auto,
      AgentAccess.bypass,
      AgentAccess.gestor,
    ];
    final next = order[(order.indexOf(_settings.access) + 1) % order.length];
    unawaited(_setAccess(next));
  }

  Future<void> _setEffort(String effort) async {
    setState(() => _settings.effort = effort);
    await _settings.save();
    for (final session in _sessions.values) {
      session.backend
        ?..effort = effort
        ..refreshSession();
    }
  }

  // ------------------------------------------------------------- conversa

  Future<void> _send() async {
    final s = _s;
    final text = _input.text.trim();
    if (s.backend == null || (text.isEmpty && _attachments.isEmpty)) return;
    final attachments = List<AgentAttachment>.of(_attachments);
    if (s.busy) {
      // O agente está trabalhando: a mensagem entra na fila e é entregue
      // quando o passo atual terminar.
      setState(() {
        s.queue.add(_Queued(text, attachments));
        _attachments.clear();
        _input.clear();
      });
      return;
    }
    setState(() {
      _attachments.clear();
      _input.clear();
    });
    await _deliver(s, text, attachments);
  }

  /// Entrega a mensagem ao agente da aba [s] e acompanha a resposta.
  Future<void> _deliver(
    _Session s,
    String text,
    List<AgentAttachment> attachments,
  ) async {
    final backend = s.backend;
    if (backend == null) return;
    final prompt = text.isEmpty
        ? 'Analise os anexos e proponha como usá-los no Gestor UFU.'
        : text;
    setState(() {
      _showHistory = false;
      if (s.conv.title.isEmpty) {
        final line = prompt.split('\n').first.trim();
        s.conv.title = line.length > 70 ? '${line.substring(0, 70)}…' : line;
      }
      s.entries.add(
        AgentEntry(
          AgentEntryKind.user,
          prompt,
          attachments: [
            for (final a in attachments)
              a.dims == null ? a.name : '${a.name} ${a.dims}',
          ],
        ),
      );
      s
        ..busy = true
        ..thinking = true
        ..thinkStart = null
        ..workWord =
            _workWords[DateTime.now().millisecondsSinceEpoch %
                _workWords.length];
    });
    _scrollToEnd(force: true);
    await _followMainWindowModule();
    final note = s.pendingSkillNote;
    final context = s.pendingContext;
    s.pendingSkillNote = null;
    s.pendingContext = null;
    try {
      await backend.send(
        '${context ?? ''}${note ?? ''}$prompt',
        attachments,
        (event) => _onEvent(s, event),
      );
    } on Object catch (error) {
      s.pendingSkillNote ??= note;
      s.pendingContext ??= context;
      final message = '$error';
      if (mounted) {
        setState(
          () => s.entries.add(
            message == 'Cancelado.'
                ? AgentEntry(AgentEntryKind.info, 'Interrompido.')
                : AgentEntry(AgentEntryKind.error, message),
          ),
        );
      }
    } finally {
      _closeOpen(s);
      s.thinkStart = null;
      for (final entry in s.toolEntries.values) {
        entry.running = false;
      }
      s.toolEntries.clear();
      if (mounted) {
        setState(() {
          s
            ..busy = false
            ..thinking = false;
        });
      }
      await _rememberActiveModel(s);
      await _saveConversation(s);
      await _refreshUndo();
      if (identical(s, _s)) _inputFocus.requestFocus();
    }
    _deliverQueue(s);
  }

  /// Entrega de uma vez as mensagens que ficaram na fila da aba.
  void _deliverQueue(_Session s) {
    if (!mounted || s.busy || s.queue.isEmpty || s.backend == null) return;
    final items = List.of(s.queue);
    setState(s.queue.clear);
    unawaited(
      _deliver(
        s,
        items.map((q) => q.text).where((t) => t.isNotEmpty).join('\n\n'),
        [for (final q in items) ...q.attachments],
      ),
    );
  }

  /// "Enviar agora": interrompe o passo atual; a fila é entregue em seguida.
  Future<void> _sendQueuedNow() async {
    final s = _s;
    for (final approval in List.of(s.approvals)) {
      if (!approval.completer.isCompleted) approval.completer.complete(false);
    }
    setState(s.approvals.clear);
    await s.backend?.cancel();
  }

  /// Tira da fila e devolve o texto à caixa de mensagem para editar.
  void _editQueued(_Queued item) {
    final s = _s;
    setState(() {
      s.queue.remove(item);
      final current = _input.text.trim();
      _input.text = current.isEmpty ? item.text : '${item.text}\n$current';
      _attachments.addAll(item.attachments);
    });
    _inputFocus.requestFocus();
  }

  void _onEvent(_Session s, AgentEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case AgentTextBreakEvent():
          _closeOpen(s);
        case AgentTextDeltaEvent(:final text):
          _flushThought(s);
          s.thinking = false;
          var open = s.open;
          if (open == null) {
            open = s.open = AgentEntry(AgentEntryKind.agent, '', running: true);
            s.entries.add(open);
          }
          open.buffer.write(text);
        case AgentTextEvent(:final text):
          _closeOpen(s);
          _flushThought(s);
          s.thinking = false;
          s.entries.add(AgentEntry(AgentEntryKind.agent, text));
        case AgentThinkingEvent():
          s.thinkStart ??= DateTime.now();
          if (s.open == null) s.thinking = true;
        case AgentToolEvent(:final id, :final name, :final input):
          _closeOpen(s);
          _flushThought(s);
          s.thinking = false;
          final entry = AgentEntry(
            AgentEntryKind.tool,
            '',
            toolName: name,
            toolInput: input,
            running: true,
          );
          s.toolEntries[id] = entry;
          s.entries.add(entry);
        case AgentToolResultEvent(:final id, :final result, :final isError):
          final entry = s.toolEntries.remove(id);
          if (entry != null) {
            entry
              ..running = false
              ..toolResult = result
              ..toolError = isError;
          }
          s.thinking = true;
        case AgentInfoEvent(:final text):
          s.entries.add(AgentEntry(AgentEntryKind.info, text));
      }
    });
    if (identical(s, _s)) _scrollToEnd();
  }

  /// Registra "Pensou por Xs" quando o raciocínio termina.
  void _flushThought(_Session s) {
    final start = s.thinkStart;
    if (start == null) return;
    s.thinkStart = null;
    final seconds = DateTime.now().difference(start).inSeconds;
    if (seconds >= 1) {
      s.entries.add(AgentEntry(AgentEntryKind.thought, '$seconds'));
    }
  }

  void _closeOpen(_Session s) {
    final open = s.open;
    if (open == null) return;
    open.running = false;
    s.open = null;
  }

  Future<void> _followMainWindowModule() async {
    if (_manualSkill) return;
    try {
      final id = await _host.invokeMethod<String>('currentSkill');
      if (id != null && id != AgentSkills.general) _changeSkill(id);
    } catch (_) {}
  }

  Future<void> _stop() async {
    // Parar não entrega a fila: as mensagens voltam para a caixa de texto.
    for (final item in List.of(_s.queue).reversed) {
      _editQueued(item);
    }
    for (final approval in List.of(_approvals)) {
      if (!approval.completer.isCompleted) approval.completer.complete(false);
    }
    setState(_approvals.clear);
    await _backend?.cancel();
  }

  Future<void> _saveConversation([_Session? session]) async {
    final s = session ?? _s;
    if (!s.conv.hasMessages) return;
    final backend = s.backend;
    s.conv
      ..updatedAt = DateTime.now()
      ..state = backend == null
          ? s.conv.state
          : {...backend.saveState(), 'machine': Platform.localHostname};
    try {
      await AgentHistory.save(s.conv);
    } catch (_) {}
    await _reloadRecent();
  }

  Future<void> _reloadRecent() async {
    final list = await AgentHistory.list();
    if (mounted) setState(() => _recent = list);
  }

  Future<void> _newConversation() async {
    if (_busy) return;
    await _saveConversation();
    _backend?.reset();
    _backend?.systemPrompt = AgentSkills.systemPrompt(_skill);
    _s.pendingContext = null;
    setState(() {
      _pendingSkillNote = null;
      _allowAll = false;
      _approvals.clear();
      _showHistory = false;
      _conv = _newConv();
    });
    _inputFocus.requestFocus();
  }

  Future<void> _openConversation(AgentConversation summary) async {
    if (_busy) return;
    final loaded = await AgentHistory.load(summary.id);
    if (loaded == null || !mounted) return;
    await _saveConversation();
    final provider = AgentProvider.values.firstWhere(
      (p) => p.name == loaded.provider,
      orElse: () => _settings.provider,
    );
    if (_sessions[provider]?.busy ?? false) {
      _info('O ${provider.tabLabel} está trabalhando; aguarde ou pare antes.');
      return;
    }
    if (provider != _settings.provider) await _selectProvider(provider);
    if (!mounted) return;
    setState(() {
      _showHistory = false;
      _allowAll = false;
      _approvals.clear();
      _conv = loaded;
      _skill = AgentSkills.byId(loaded.skill) != null ? loaded.skill : _skill;
    });
    final backend = _backend;
    if (backend != null) {
      backend.systemPrompt = AgentSkills.systemPrompt(_skill);
      await _restoreInto(_s, backend, loaded);
    }
    _scrollToEnd(force: true);
  }

  /// Retoma [conv] no [backend]: pela própria sessão do agente quando ela
  /// existe neste computador; senão (outro computador, sessão expirada ou
  /// outro modo de conexão) pela transcrição enviada na próxima mensagem.
  Future<void> _restoreInto(
    _Session s,
    AgentBackend backend,
    AgentConversation conv,
  ) async {
    backend.reset();
    s.pendingContext = null;
    final state = conv.state;
    final machine = state['machine'];
    final sameMode = conv.mode == _settings.modeFor(s.provider).name;
    final sameMachine = machine == null || machine == Platform.localHostname;
    var native = sameMode && state.keys.any((k) => k != 'machine');
    if (native && backend is CliAgentBackend) {
      final id = state['sessionId'];
      native = sameMachine && id is String && await backend.canResume(id);
    }
    if (native) {
      backend.restoreState(state);
    } else if (conv.hasMessages) {
      s.pendingContext =
          '<historico_da_conversa>\n'
          'Esta conversa começou antes (possivelmente em outro computador). '
          'Continue a partir dela; o histórico é:\n'
          '${conv.transcript()}\n'
          '</historico_da_conversa>\n\n';
    }
  }

  Future<void> _deleteConversation(AgentConversation conversation) async {
    await AgentHistory.delete(conversation.id);
    if (conversation.id == _conv.id) {
      _backend?.reset();
      setState(() => _conv = _newConv());
    }
    await _reloadRecent();
  }

  Future<void> _exportConversation() async {
    if (!_conv.hasMessages) {
      _info('A conversa está vazia.');
      return;
    }
    final buffer = StringBuffer('# ${_conv.title}\n\n');
    for (final entry in _entries) {
      switch (entry.kind) {
        case AgentEntryKind.user:
          buffer.writeln('**Você:** ${entry.text}\n');
        case AgentEntryKind.agent:
          buffer.writeln('${entry.text}\n');
        case AgentEntryKind.tool:
          buffer.writeln(
            '> ${agentToolLabel(entry.toolName ?? '')} '
            '${agentToolSummary(entry.toolInput)}\n',
          );
        case AgentEntryKind.thought:
          break;
        case AgentEntryKind.info:
        case AgentEntryKind.error:
          buffer.writeln('_${entry.text}_\n');
      }
    }
    final safe = _conv.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar conversa',
      fileName: '${safe.isEmpty ? 'conversa' : safe}.md',
    );
    if (path == null) return;
    await File(path).writeAsString(buffer.toString());
    _info('Conversa exportada para $path.');
  }

  // ------------------------------------------------------------- navegador

  bool _browserRecording = false;

  /// Chama uma ferramenta do navegador do agente (na janela principal).
  Future<Map<String, dynamic>> _browserTool(
    String name, [
    Map<String, dynamic> input = const {},
  ]) async {
    try {
      final raw = await _host.invokeMethod<String>('tool', {
        'name': name,
        'input': jsonEncode(input),
      });
      final result = Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map);
      if (result['error'] != null) _error('Navegador: ${result['error']}');
      return result;
    } on Object catch (error) {
      _error('Navegador: $error');
      return const {};
    }
  }

  /// O usuário grava o que faz no navegador do agente; ao parar, a gravação
  /// vira anexo da próxima mensagem (o agente pode reproduzir ou documentar).
  Future<void> _toggleBrowserRecording() async {
    if (!_browserRecording) {
      await _browserTool('browser_open');
      final result = await _browserTool('browser_record', {'action': 'start'});
      if (result['recording'] == true) {
        setState(() => _browserRecording = true);
      }
      return;
    }
    final result = await _browserTool('browser_record', {'action': 'stop'});
    setState(() => _browserRecording = false);
    final events = result['events'];
    if (events is List && events.isNotEmpty) {
      setState(
        () => _attachments.add(
          AgentAttachment(
            name: 'gravacao_navegador.json',
            mimeType: 'text/plain',
            text: const JsonEncoder.withIndent('  ').convert(events),
          ),
        ),
      );
      if (_input.text.trim().isEmpty) {
        _input.text = 'Esta é a gravação do que fiz no navegador. ';
      }
      _inputFocus.requestFocus();
    } else {
      _info('Nenhuma ação foi gravada no navegador.');
    }
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

  void _info(String text) {
    if (!mounted) return;
    setState(() => _entries.add(AgentEntry(AgentEntryKind.info, text)));
    _scrollToEnd();
  }

  void _error(String text) {
    if (!mounted) return;
    setState(() => _entries.add(AgentEntry(AgentEntryKind.error, text)));
    _scrollToEnd();
  }

  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      // Só acompanha se o usuário já estava perto do fim.
      if (!force && position.maxScrollExtent - position.pixels > 220) return;
      _scroll.jumpTo(position.maxScrollExtent);
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
      await _addFile(file.name, file.path, file.bytes);
    }
  }

  Future<void> _addFile(String name, String? path, List<int>? bytes) async {
    try {
      final attachment = await _readAttachment(name, path, bytes);
      setState(() => _attachments.add(attachment));
      unawaited(_measure(attachment));
    } on Object catch (error) {
      _error('Não foi possível ler "$name": $error');
    }
  }

  Future<AgentAttachment> _readAttachment(
    String name,
    String? path,
    List<int>? data,
  ) async {
    final bytes =
        data ?? (path != null ? await File(path).readAsBytes() : null);
    if (bytes == null) throw AgentException('arquivo vazio');
    final ext = p.extension(name).toLowerCase();
    const images = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
    };
    if (images.containsKey(ext)) {
      return AgentAttachment(
        name: name,
        mimeType: images[ext]!,
        bytes: bytes,
        localPath: path,
      );
    }
    if (ext == '.pdf') {
      return AgentAttachment(
        name: name,
        mimeType: 'application/pdf',
        bytes: bytes,
        localPath: path,
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
        name: name,
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
      '.dart',
      '.py',
      '.js',
      '.log',
    };
    if (textExtensions.contains(ext) || ext.isEmpty) {
      return AgentAttachment(
        name: name,
        mimeType: 'text/plain',
        text: utf8.decode(bytes, allowMalformed: true),
      );
    }
    // Outros formatos: o agente lê pelo caminho (fora do modo "Só o Gestor").
    return AgentAttachment(
      name: name,
      mimeType: 'application/octet-stream',
      bytes: bytes,
      localPath: path,
    );
  }

  /// Ctrl+V: imagem ou arquivos copiados viram anexos; texto vai para a
  /// caixa (textos muito longos viram anexo).
  Future<void> _paste() async {
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        for (final path in files) {
          if (await File(path).exists()) {
            await _addFile(p.basename(path), path, null);
          }
        }
        return;
      }
      final image = await Pasteboard.image;
      if (image != null && image.isNotEmpty) {
        final count = _attachments.where((a) => a.isImage).length + 1;
        final attachment = AgentAttachment(
          name: 'image${count == 1 ? '' : '_$count'}.png',
          mimeType: 'image/png',
          bytes: image,
        );
        setState(() => _attachments.add(attachment));
        unawaited(_measure(attachment));
        return;
      }
    } catch (_) {}
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
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
      return;
    }
    final selection = _input.selection;
    final start = selection.isValid ? selection.start : _input.text.length;
    final end = selection.isValid ? selection.end : _input.text.length;
    _input.value = TextEditingValue(
      text: _input.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// Microfone: abre o ditado por voz do Windows (Win+H), que escreve o
  /// que for falado direto na caixa de mensagem.
  Future<void> _dictate() async {
    _inputFocus.requestFocus();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    try {
      const vkLeftWin = 0x5B;
      const vkH = 0x48;
      const keyUp = 0x0002;
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final keybdEvent = user32
          .lookupFunction<
            ffi.Void Function(ffi.Uint8, ffi.Uint8, ffi.Uint32, ffi.UintPtr),
            void Function(int, int, int, int)
          >('keybd_event');
      keybdEvent(vkLeftWin, 0, 0, 0);
      keybdEvent(vkH, 0, 0, 0);
      keybdEvent(vkH, 0, keyUp, 0);
      keybdEvent(vkLeftWin, 0, keyUp, 0);
    } catch (error) {
      _error('Não foi possível abrir o ditado do Windows: $error');
    }
  }

  /// "/" no início da caixa abre o menu de ações, como na extensão.
  void _onInputChanged() {
    if (_input.text == '/') {
      _input.clear();
      unawaited(_openActions());
    }
  }

  // ------------------------------------------------------------- menus

  double get _paletteBottom {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    return (box?.size.height ?? 110) + 4;
  }

  String get _modelLabel {
    final active = _backend?.activeModel ?? _settings.models['seen.$_modelKey'];
    if (active != null && active.isNotEmpty) return _prettyModel(active);
    final provider = _settings.provider;
    final current = _settings.modelFor(provider, _settings.mode);
    for (final model in _modelCache[_modelKey] ?? const <AgentModel>[]) {
      if (model.id == current) {
        return model.label.split('  ·  ').first;
      }
    }
    return current.isEmpty ? 'Padrão' : current;
  }

  /// "claude-opus-5-5" → "Opus 5.5"; outros pelo nome da lista de modelos.
  String _prettyModel(String id) {
    for (final model in _modelCache[_modelKey] ?? const <AgentModel>[]) {
      if (model.id == id && id.isNotEmpty) {
        return model.label.split('  ·  ').first;
      }
    }
    final match = RegExp(
      r'^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-|$)',
    ).firstMatch(id);
    if (match != null) {
      final name = match[1]!;
      return '${name[0].toUpperCase()}${name.substring(1)} ${match[2]}'
          '${match[3] != null ? '.${match[3]}' : ''}';
    }
    return id;
  }

  /// Lembra o último modelo usado para mostrar o nome desde a abertura.
  Future<void> _rememberActiveModel(_Session s) async {
    final active = s.backend?.activeModel;
    final key = 'seen.${s.provider.name}.${_settings.modeFor(s.provider).name}';
    if (active == null || active.isEmpty || _settings.models[key] == active) {
      return;
    }
    _settings.models[key] = active;
    await _settings.save();
  }

  /// Lê as dimensões das imagens anexadas ("382×447").
  Future<void> _measure(AgentAttachment attachment) async {
    final bytes = attachment.bytes;
    if (!attachment.isImage || bytes == null) return;
    try {
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      attachment.dims = '${frame.image.width}×${frame.image.height}';
      frame.image.dispose();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Widget _effortItem(BuildContext context, VoidCallback refresh) => EffortRow(
    value: _settings.effort,
    icon: true,
    onChanged: (value) async {
      await _setEffort(value);
      refresh();
    },
  );

  Future<void> _openActions() => showPalette(
    context,
    bottom: _paletteBottom,
    items: () {
      final skill = AgentSkills.byId(_skill);
      return [
        PaletteItem(
          section: 'Contexto',
          label: 'Anexar arquivo…',
          onSelect: _pickFiles,
        ),
        PaletteItem(
          section: 'Contexto',
          label: 'Colar imagem ou arquivo copiado',
          onSelect: _paste,
        ),
        PaletteItem(
          section: 'Contexto',
          label: 'Limpar conversa',
          onSelect: _newConversation,
        ),
        PaletteItem(
          section: 'Contexto',
          label: 'Histórico de conversas',
          trailing: '${_recent.length}',
          onSelect: () => setState(() => _showHistory = true),
        ),
        PaletteItem(
          section: 'Contexto',
          label: 'Exportar conversa',
          onSelect: _exportConversation,
        ),
        PaletteItem(
          section: 'Modelo',
          label: 'Trocar modelo…',
          trailing: _modelLabel,
          onSelect: _openModels,
        ),
        PaletteItem(section: 'Modelo', label: 'Esforço', builder: _effortItem),
        PaletteItem(
          section: 'Modo',
          label: 'Modo de permissão…',
          trailing: _settings.access.label,
          onSelect: _openModes,
        ),
        PaletteItem(
          section: 'Gestor UFU',
          label: 'Foco do agente…',
          trailing: skill?.title ?? '',
          onSelect: _openSkills,
        ),
        PaletteItem(
          section: 'Gestor UFU',
          label: 'Desfazer a última alteração do agente',
          trailing: _undoCount > 0 ? '$_undoCount' : 'nada',
          onSelect: _undoCount > 0 ? _undo : null,
        ),
        PaletteItem(
          section: 'Navegador',
          label: 'Abrir navegador do agente',
          onSelect: () => _browserTool('browser_open'),
        ),
        PaletteItem(
          section: 'Navegador',
          label: _browserRecording
              ? 'Parar gravação e anexar as ações'
              : 'Gravar minhas ações no navegador',
          onSelect: _toggleBrowserRecording,
        ),
        PaletteItem(
          section: 'Navegador',
          label: 'Fechar navegador do agente',
          onSelect: () => _browserTool('browser_close'),
        ),
        for (final provider in AgentProvider.values)
          PaletteItem(
            section: 'Agente',
            label: provider.tabLabel,
            checked: provider == _settings.provider,
            onSelect: () => _selectProvider(provider),
          ),
        PaletteItem(
          section: 'Conta',
          label: 'Configurações do agente…',
          onSelect: _openSettings,
        ),
        if (_settings.provider != AgentProvider.copilot)
          PaletteItem(
            section: 'Conta',
            label: _settings.mode == AgentAuthMode.cli
                ? 'Usar chave de API'
                : 'Usar assinatura (${_settings.provider.cliProductName})',
            onSelect: () async {
              if (_settings.mode == AgentAuthMode.cli) {
                await _disconnect();
                setState(() => _showApiKey = true);
              } else {
                await _disposeBackend();
                await _browserLogin();
              }
            },
          ),
        PaletteItem(
          section: 'Conta',
          label: 'Desconectar',
          onSelect: _disconnect,
        ),
      ];
    },
  );

  Future<void> _openModes() => showPalette(
    context,
    bottom: _paletteBottom,
    filter: false,
    width: 360,
    title: 'Modos',
    hint: 'Shift + Tab para alternar',
    items: () => [
      for (final access in AgentAccess.values)
        PaletteItem(
          section: '',
          label: access.label,
          subtitle: access.description,
          icon: access.icon,
          checked: access == _settings.access,
          onSelect: () => _setAccess(access),
        ),
      PaletteItem(section: ' ', label: 'Esforço', builder: _effortItem),
    ],
  );

  Future<void> _openModels() async {
    final backend = _backend;
    if (backend == null) return;
    if (!_modelCache.containsKey(_modelKey)) await _loadModels(backend);
    if (!mounted) return;
    final provider = _settings.provider;
    final current = _settings.modelFor(provider, _settings.mode);
    await showPalette(
      context,
      bottom: _paletteBottom,
      width: 420,
      items: () => [
        for (final model in _modelCache[_modelKey] ?? const <AgentModel>[])
          PaletteItem(
            section: 'Modelos da sua conta',
            label: model.label.split('  ·  ').first,
            trailing: model.isDefault && model.id.isNotEmpty
                ? 'padrão'
                : (model.label.contains('  ·  ') ? model.id : null),
            checked: model.id == current,
            onSelect: () => _setModel(model.id),
          ),
        PaletteItem(section: 'Modelo', label: 'Esforço', builder: _effortItem),
        PaletteItem(
          section: 'Modelo',
          label: 'Outro modelo…',
          onSelect: () async {
            final typed = await _askModelName(provider, current);
            if (typed != null) await _setModel(typed);
          },
        ),
        PaletteItem(
          section: 'Modelo',
          label: 'Atualizar lista',
          onSelect: () => _loadModels(backend, force: true),
        ),
      ],
    );
  }

  Future<void> _openSkills() => showPalette(
    context,
    bottom: _paletteBottom,
    width: 420,
    items: () => [
      for (final skill in AgentSkills.all)
        PaletteItem(
          section: 'Foco do agente no Gestor',
          label: skill.title,
          checked: skill.id == _skill,
          onSelect: () {
            _manualSkill = true;
            _changeSkill(skill.id);
          },
        ),
    ],
  );

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
    setState(() {
      _settings.setModel(provider, mode, model);
      _settings.models.remove('seen.$_modelKey');
    });
    await _settings.save();
    // Recria o back-end com o novo modelo mantendo a conversa.
    if (_backend != null) await _connect();
  }

  Future<void> _openSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _AgentSettingsDialog(settings: _settings),
    );
    if (saved == true) {
      await _settings.save();
      if (_backend != null) await _connect();
    }
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final connected = _backend != null;
    return Scaffold(
      backgroundColor: vs.bg,
      body: SafeArea(
        child: Column(
          children: [
            _tabs(vs),
            _header(vs),
            Expanded(
              child: _showHistory
                  ? _historyView(vs)
                  : !connected
                  ? _connectPanel(context)
                  : _entries.isEmpty && _approvals.isEmpty
                  ? _emptyState(vs)
                  : _chat(vs),
            ),
            if (connected) _composer(vs),
          ],
        ),
      ),
    );
  }

  /// Abas no topo, como "Chat · Codex · Claude Code" do VS Code.
  Widget _tabs(VsColors vs) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
    child: Row(
      children: [
        for (final provider in AgentProvider.values)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: _connecting ? null : () => _selectProvider(provider),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: provider == _settings.provider ? vs.tab : null,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      provider.tabLabel,
                      style: TextStyle(fontSize: 13, color: vs.text),
                    ),
                    // Agente trabalhando em segundo plano nesta aba.
                    if (_sessions[provider]?.busy ?? false) ...[
                      const SizedBox(width: 6),
                      const PulsingDot(color: Color(0xFFD97757)),
                    ] else if ((_sessions[provider]?.approvals.isNotEmpty ??
                        false)) ...[
                      const SizedBox(width: 6),
                      TimelineDot(vs.accent),
                    ],
                  ],
                ),
              ),
            ),
          ),
        const Spacer(),
        if (_undoCount > 0)
          Badge(
            label: Text('$_undoCount'),
            child: VsIconButton(
              icon: Icons.undo_rounded,
              tooltip: 'Desfazer a última alteração do agente no Gestor',
              onPressed: _busy ? null : _undo,
            ),
          ),
        VsIconButton(
          icon: Icons.settings_outlined,
          tooltip: 'Configurações do agente',
          onPressed: _busy ? null : _openSettings,
        ),
      ],
    ),
  );

  Widget _header(VsColors vs) {
    final title = _showHistory
        ? 'Histórico'
        : _conv.title.isNotEmpty
        ? _conv.title
        : 'Agente de IA no GestorUFU';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 10, 6),
      child: Row(
        children: [
          if (_showHistory)
            VsIconButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Voltar',
              onPressed: () => setState(() => _showHistory = false),
            ),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: vs.text,
              ),
            ),
          ),
          VsIconButton(
            icon: Icons.access_time_rounded,
            tooltip: 'Histórico de conversas',
            onPressed: () => setState(() => _showHistory = !_showHistory),
          ),
          VsIconButton(
            icon: Icons.add_circle_outline_rounded,
            tooltip: 'Nova conversa',
            onPressed: _busy ? null : _newConversation,
          ),
        ],
      ),
    );
  }

  /// Tela inicial (sem mensagens): lista "Chats" e o logo esmaecido.
  Widget _emptyState(VsColors vs) {
    final shown = _showAllRecent ? _recent : _recent.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_recent.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: Text(
              'Chats',
              style: TextStyle(fontSize: 12, color: vs.muted),
            ),
          ),
          Flexible(
            flex: _showAllRecent ? 3 : 0,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final c in shown)
                  ConversationTile(
                    conversation: c,
                    onOpen: () => _openConversation(c),
                    onDelete: () => _deleteConversation(c),
                  ),
                if (_recent.length > 3)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: InkWell(
                      onTap: () =>
                          setState(() => _showAllRecent = !_showAllRecent),
                      child: Text(
                        _showAllRecent
                            ? 'Mostrar menos'
                            : 'Exibir tudo (${_recent.length})',
                        style: TextStyle(fontSize: 11.5, color: vs.muted),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        Expanded(
          flex: 4,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: 0.35,
                  child: ProviderIcon(_settings.provider, size: 46),
                ),
                const SizedBox(height: 14),
                Text(
                  'Peça para preencher, corrigir ou copiar dados do Gestor,\n'
                  'pesquisar na web ou analisar arquivos anexados.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: vs.muted),
                ),
                const SizedBox(height: 6),
                Text(
                  'Digite / para ver as ações.',
                  style: TextStyle(fontSize: 12, color: vs.muted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _historyView(VsColors vs) {
    final query = _historySearch.text.trim().toLowerCase();
    final list = [
      for (final c in _recent)
        if (query.isEmpty || c.title.toLowerCase().contains(query)) c,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: _historySearch,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 13, color: vs.text),
            decoration: InputDecoration(
              hintText: 'Pesquisar conversas…',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18, color: vs.muted),
              filled: true,
              fillColor: vs.card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: vs.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: vs.border),
              ),
            ),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                    'Nenhuma conversa.',
                    style: TextStyle(color: vs.muted),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    for (final c in list)
                      ConversationTile(
                        conversation: c,
                        active: c.id == _conv.id,
                        onOpen: () => _openConversation(c),
                        onDelete: () => _deleteConversation(c),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _chat(VsColors vs) {
    final showThinking =
        _busy &&
        _approvals.isEmpty &&
        (_thinking ||
            (_open == null && !_toolEntries.values.any((e) => e.running)));
    final count = _entries.length + _approvals.length + (showThinking ? 1 : 0);
    bool isUser(int index) =>
        index < _entries.length && _entries[index].kind == AgentEntryKind.user;
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: count,
        itemBuilder: (context, index) {
          if (isUser(index)) return UserBubble(_entries[index]);
          final above = index > 0 && !isUser(index - 1);
          final below = index < count - 1 && !isUser(index + 1);
          Widget item(Widget dot, Widget child) => TimelineItem(
            dot: dot,
            lineAbove: above,
            lineBelow: below,
            dotTop: 10,
            child: child,
          );
          if (index < _entries.length) {
            final entry = _entries[index];
            return switch (entry.kind) {
              AgentEntryKind.user => UserBubble(entry),
              AgentEntryKind.agent => item(
                TimelineDot(vs.text.withValues(alpha: 0.55)),
                AgentMessage(entry),
              ),
              AgentEntryKind.tool => item(
                entry.running
                    ? PulsingDot(color: vs.muted)
                    : TimelineDot(entry.toolError ? vs.error : vs.success),
                ToolRow(entry),
              ),
              AgentEntryKind.thought => item(
                TimelineDot(vs.muted.withValues(alpha: 0.7)),
                Text(
                  'Pensou por ${entry.text}s',
                  style: TextStyle(fontSize: 13, color: vs.muted),
                ),
              ),
              AgentEntryKind.info => item(
                TimelineDot(vs.muted.withValues(alpha: 0.5)),
                Text(
                  entry.text,
                  style: TextStyle(fontSize: 12.5, color: vs.muted),
                ),
              ),
              AgentEntryKind.error => item(
                TimelineDot(vs.error),
                Text(
                  entry.text,
                  style: TextStyle(fontSize: 12.5, color: vs.error),
                ),
              ),
            };
          }
          final approvalIndex = index - _entries.length;
          if (approvalIndex < _approvals.length) {
            final approval = _approvals[approvalIndex];
            return item(
              PulsingDot(color: vs.accent),
              ApprovalCard(
                tool: approval.tool,
                input: approval.input,
                onAnswer: (allow) => _answer(approval, allow),
              ),
            );
          }
          return item(
            const PulsingDot(color: Color(0xFFD97757)),
            ThinkingIndicator(label: _workWord),
          );
        },
      ),
    );
  }

  /// Caixa de mensagem no estilo da extensão: texto, anexos e a barra com
  /// +, /, modelo, modo e enviar.
  /// Mensagens na fila, acima da caixa de texto.
  Widget _queuePanel(VsColors vs) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: vs.border)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.schedule_rounded, size: 13, color: vs.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _s.queue.length == 1
                    ? 'Na fila: será enviada quando o agente terminar o passo '
                          'atual'
                    : '${_s.queue.length} mensagens na fila: serão enviadas '
                          'juntas quando o agente terminar o passo atual',
                style: TextStyle(fontSize: 11, color: vs.muted),
              ),
            ),
            TextButton.icon(
              onPressed: _sendQueuedNow,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 11),
              ),
              icon: const Icon(Icons.bolt_rounded, size: 14),
              label: const Text('Enviar agora'),
            ),
          ],
        ),
        for (final item in List.of(_s.queue))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    [
                      if (item.text.isNotEmpty) item.text,
                      if (item.attachments.isNotEmpty)
                        '(${item.attachments.length} anexo(s))',
                    ].join(' ').replaceAll(RegExp(r'\s+'), ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: vs.text),
                  ),
                ),
                VsIconButton(
                  icon: Icons.edit_outlined,
                  tooltip: 'Editar (volta para a caixa de texto)',
                  onPressed: () => _editQueued(item),
                ),
                VsIconButton(
                  icon: Icons.close_rounded,
                  tooltip: 'Remover da fila',
                  onPressed: () => setState(() => _s.queue.remove(item)),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _composer(VsColors vs) {
    final provider = _settings.provider;
    final skill = AgentSkills.byId(_skill);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          key: _composerKey,
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          decoration: BoxDecoration(
            color: vs.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: vs.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: vs.dark ? 0.35 : 0.08),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_s.queue.isNotEmpty) _queuePanel(vs),
              if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final attachment in List.of(_attachments))
                        AttachmentPill(
                          name: attachment.name,
                          detail: attachment.dims,
                          onRemove: () =>
                              setState(() => _attachments.remove(attachment)),
                        ),
                    ],
                  ),
                ),
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): _send,
                  const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                      _paste,
                  const SingleActivator(LogicalKeyboardKey.tab, shift: true):
                      _cycleAccess,
                  const SingleActivator(LogicalKeyboardKey.escape): () {
                    if (_busy) unawaited(_stop());
                  },
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        focusNode: _inputFocus,
                        autofocus: true,
                        minLines: 1,
                        maxLines: 10,
                        keyboardType: TextInputType.multiline,
                        style: TextStyle(
                          fontSize: 13,
                          color: vs.text,
                          height: 1.4,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Peça qualquer coisa',
                          hintStyle: TextStyle(color: vs.muted),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.fromLTRB(
                            12,
                            12,
                            12,
                            8,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 5, 6, 0),
                      child: VsIconButton(
                        icon: Icons.mic_none_rounded,
                        tooltip: 'Ditado por voz (Win+H)',
                        onPressed: _dictate,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: vs.border.withValues(alpha: 0.6)),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                child: Row(
                  children: [
                    VsIconButton(
                      icon: Icons.add_rounded,
                      tooltip: 'Anexar arquivo (ou cole com Ctrl+V)',
                      onPressed: _busy ? null : _pickFiles,
                    ),
                    Tooltip(
                      message: 'Ações (/)',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: _openActions,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Container(
                            width: 15,
                            height: 15,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: vs.text.withValues(alpha: 0.85),
                                width: 1.3,
                              ),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '/',
                              style: TextStyle(
                                fontSize: 10,
                                height: 1,
                                fontWeight: FontWeight.w700,
                                color: vs.text.withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Chips do meio ocupam o espaço livre e encolhem com
                    // reticências; modo e enviar ficam sempre colados à
                    // direita.
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: ComposerChip(
                              label: _loadingModels
                                  ? 'Carregando modelos…'
                                  : '$_modelLabel'
                                        '${_settings.effort.isEmpty ? '' : ' ${AgentSettings.effortLabel(_settings.effort)}'}',
                              filled: true,
                              tooltip: 'Modelo e esforço',
                              onTap: _busy ? null : _openModels,
                            ),
                          ),
                          const SizedBox(width: 4),
                          if (skill != null)
                            Flexible(
                              child: ComposerChip(
                                label: skill.title.split(' (').first,
                                icon: Icons.center_focus_strong_outlined,
                                tooltip: 'Foco do agente: ${skill.title}',
                                onTap: _openSkills,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (_browserRecording) ...[
                      ComposerChip(
                        label: 'Gravando',
                        icon: Icons.fiber_manual_record_rounded,
                        iconColor: const Color(0xFFE5484D),
                        tooltip: 'Parar a gravação do navegador e anexar',
                        onTap: _toggleBrowserRecording,
                      ),
                      const SizedBox(width: 4),
                    ],
                    ComposerChip(
                      label: _settings.access.label,
                      icon: _settings.access.icon,
                      tooltip: 'Modo de permissão (Shift+Tab alterna)',
                      onTap: _openModes,
                    ),
                    const SizedBox(width: 6),
                    // Ocupado e sem nada escrito: parar. Com texto: enviar
                    // (vai para a fila se o agente ainda estiver trabalhando).
                    ListenableBuilder(
                      listenable: _input,
                      builder: (context, _) {
                        final stop =
                            _busy &&
                            _input.text.trim().isEmpty &&
                            _attachments.isEmpty;
                        return Tooltip(
                          message: stop
                              ? 'Parar (Esc)'
                              : _busy
                              ? 'Adicionar à fila (Enter)'
                              : 'Enviar (Enter)',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(5),
                            onTap: stop ? _stop : _send,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: provider.sendColor,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Icon(
                                stop
                                    ? Icons.stop_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 17,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tela exibida enquanto não há conexão: botão central para entrar pelo
  /// navegador (como na extensão do VS Code) ou usar uma chave de API.
  Widget _connectPanel(BuildContext context) {
    final provider = _settings.provider;
    final vs = VsColors.of(context);
    if (_autoConnecting || (_connecting && _loginStatus == null)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProviderIcon(provider, size: 52),
            const SizedBox(height: 18),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Conectando ao ${provider.tabLabel}…',
              style: TextStyle(color: vs.muted),
            ),
          ],
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProviderIcon(provider, size: 52),
              const SizedBox(height: 16),
              Text(
                provider.tabLabel,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: vs.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Entre com sua conta ${provider.label} para usar o agente no '
                'Gestor UFU.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: vs.muted),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 40,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: provider.sendColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onPressed: _connecting ? null : _browserLogin,
                  icon: _connecting && _loginStatus != null
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.open_in_browser_rounded, size: 18),
                  label: Text('Entrar com ${provider.label} no navegador'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Usa sua assinatura pelo ${provider.cliProductName} '
                '(instalado automaticamente se necessário).',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: vs.muted),
              ),
              if (provider == AgentProvider.gemini) ...[
                const SizedBox(height: 8),
                Text(
                  'Usa o Antigravity CLI do Google, que aceita contas pessoais '
                  '(Google AI Pro e gratuitas).',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: vs.muted),
                ),
              ],
              if (_loginStatus != null) ...[
                const SizedBox(height: 16),
                Text(
                  _loginStatus!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: vs.text),
                ),
              ],
              if (_loginLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: vs.card,
                    border: Border.all(color: vs.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    _loginLines.join('\n'),
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                      color: vs.text,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (provider == AgentProvider.copilot)
                const SizedBox.shrink()
              else if (!_showApiKey)
                TextButton.icon(
                  onPressed: _connecting
                      ? null
                      : () => setState(() => _showApiKey = true),
                  icon: const Icon(Icons.key_rounded, size: 18),
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
                    icon: const Icon(Icons.login_rounded, size: 18),
                    label: Text(
                      _hasSavedKey
                          ? 'Conectar com a chave'
                          : 'Salvar chave e conectar',
                    ),
                  ),
                ),
              ],
              if (_entries.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final entry in _entries.where(
                  (e) => e.kind == AgentEntryKind.error,
                ))
                  Text(
                    entry.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: vs.error),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
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
  late final _workDir = TextEditingController(text: widget.settings.workDir);
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
    for (final c in [
      ..._keys.values,
      ..._models.values,
      ..._paths.values,
      _workDir,
    ]) {
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
    widget.settings.workDir = _workDir.text.trim();
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
              provider.tabLabel,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 8),
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
            labelText: 'Modelo na assinatura (opcional)',
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
              'computador e não vão para o banco compartilhado. O histórico de '
              'conversas fica só neste computador.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _workDir,
              decoration: const InputDecoration(
                labelText:
                    'Pasta de trabalho do agente (vazio = '
                    'Documentos\\GestorUFU Agente)',
                helperText:
                    'Onde o agente cria e lê arquivos fora do modo "Só o '
                    'Gestor".',
                isDense: true,
              ),
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
  AgentProvider.copilot => CopilotCliBackend(
    mcp: mcp,
    configuredPath: path,
    model: model,
  ),
};

/// Ícone de cada provedor (selo colorido).
class ProviderIcon extends StatelessWidget {
  const ProviderIcon(this.provider, {super.key, this.size = 22});

  final AgentProvider provider;
  final double size;

  @override
  Widget build(BuildContext context) {
    final List<Color> colors = switch (provider) {
      AgentProvider.claude => const [Color(0xFFE08B6D), Color(0xFFC96442)],
      AgentProvider.chatgpt => const [Color(0xFF3A3A3A), Color(0xFF111111)],
      AgentProvider.gemini => const [Color(0xFF4796E3), Color(0xFF9177C7)],
      AgentProvider.copilot => const [Color(0xFF8250DF), Color(0xFF24292F)],
    };
    final Widget glyph = switch (provider) {
      // Asterisco do Claude.
      AgentProvider.claude => Text(
        '✻',
        style: TextStyle(
          fontSize: size * 0.72,
          height: 1,
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
      AgentProvider.chatgpt => Icon(
        Icons.terminal_rounded,
        size: size * 0.6,
        color: Colors.white,
      ),
      AgentProvider.gemini => Icon(
        Icons.auto_awesome,
        size: size * 0.6,
        color: Colors.white,
      ),
      AgentProvider.copilot => Icon(
        Icons.flight_rounded,
        size: size * 0.6,
        color: Colors.white,
      ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: glyph,
    );
  }
}
