import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm2/xterm.dart';

import 'remote_api.dart';

const _remoteUploadFields = <String, Set<String>>{
  'moodle.importarPlanilha': {'path'},
  'diario.importarPlanilha': {'path'},
  'diario.carregarJson': {'path'},
  'ajustaHorarios.importarPlanilha': {'path'},
  'planosEnsino.importarWord': {'path'},
  'planosEnsino.importarBackup': {'path'},
  'planosTrabalho.importarPlanilha': {'path'},
  'planosTrabalho.preencherPlanilha': {'modelopath'},
  'planosTrabalho.salvarCadastro': {'pdfpath'},
  'planosTrabalho.inserirNoSei': {'pdfpath'},
  'equivalencia.importarCurriculo': {'path'},
  'equivalencia.importarAnalise': {'path'},
  'progressao.anexarComprovante': {'path'},
  'progressao.lancar': {'comprovante'},
  'auditaBancas.abrirPdf': {'caminho'},
};
const _speechOutput = MethodChannel('br.ufu.gestor.mobile/tts');

void main() => runApp(const GestorRemoteApp());

class GestorRemoteApp extends StatefulWidget {
  const GestorRemoteApp({super.key});
  @override
  State<GestorRemoteApp> createState() => _GestorRemoteAppState();
}

class _GestorRemoteAppState extends State<GestorRemoteApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    const vault = FlutterSecureStorage();
    final saved = await vault.read(key: 'remote.themeMode');
    if (!mounted || saved == null) return;
    setState(
      () => _themeMode = saved == 'light' ? ThemeMode.light : ThemeMode.dark,
    );
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    const vault = FlutterSecureStorage();
    await vault.write(
      key: 'remote.themeMode',
      value: mode == ThemeMode.light ? 'light' : 'dark',
    );
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff6c63ff),
          brightness: brightness,
        ).copyWith(
          primary: isDark ? const Color(0xff8b83ff) : const Color(0xff5147c5),
          secondary: isDark ? const Color(0xff00d4ff) : const Color(0xff007e94),
          surface: isDark ? const Color(0xff1e2045) : Colors.white,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: isDark
          ? const Color(0xff0f1123)
          : const Color(0xfff3f4f9),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xff0f1123) : Colors.white,
        foregroundColor: colors.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: isDark ? 0 : 1,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xff171932) : Colors.white,
        indicatorColor: colors.primary.withAlpha(isDark ? 60 : 28),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? colors.onSurface
                : colors.onSurfaceVariant,
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xff151730) : const Color(0xfff8f8fc),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Gestor UFU Remoto',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: _themeMode,
    home: RemoteHomePage(
      themeMode: _themeMode,
      onThemeModeChanged: _setThemeMode,
    ),
  );
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage>
    with WidgetsBindingObserver {
  final _speech = stt.SpeechToText();
  final _input = TextEditingController();
  final _messages = <_ChatMessage>[];
  List<Map<String, dynamic>> _modules = [];
  List<Map<String, dynamic>> _agentProviders = [];
  String? _agentProvider;
  List<Map<String, dynamic>> _approvals = [];
  final _activeTasks = <String, Map<String, dynamic>>{};
  final _taskHistory = <Map<String, dynamic>>[];
  RemoteApi? _api;
  WebSocket? _socket;
  Timer? _reconnect;
  bool _connected = false;
  bool _connecting = false;
  bool _listening = false;
  bool _sending = false;
  bool _speechReady = false;
  bool _speechSubmitted = false;
  bool _speakResponses = true;
  int _selectedTab = 0;
  String? _selectedModuleId;
  String _moduleFilter = '';
  String? _error;
  String _assistantDraft = '';
  bool _moodleHomeLoading = false;
  String? _moodleHomeError;
  Map<String, dynamic>? _moodleHomeData;
  bool _agendaHomeLoading = false;
  String? _agendaHomeError;
  int _agendaTabIndex = 0;
  List<Map<String, dynamic>> _agendaCalendars = [];
  List<Map<String, dynamic>> _agendaEvents = [];
  List<Map<String, dynamic>> _emailMessages = [];
  bool _agendaEventsLoaded = false;
  final _emailSearch = TextEditingController();
  bool _emailUnreadOnly = false;
  bool _moduleWorkspaceLoading = false;
  String? _moduleWorkspaceError;
  Map<String, dynamic>? _moduleWorkspaceData;
  bool _moduleActionsTab = false;
  final _remoteTerminal = Terminal(maxLines: 20000);
  final _remoteTerminalController = TerminalController();
  WebSocket? _terminalSocket;
  bool _terminalConnecting = false;
  String? _terminalError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
    _remoteTerminal.onOutput = (data) {
      final socket = _terminalSocket;
      if (socket != null && socket.readyState == WebSocket.open) {
        socket.add(jsonEncode({'type': 'input', 'data': data}));
      }
    };
    _remoteTerminal.onResize = (columns, rows, _, __) {
      final socket = _terminalSocket;
      if (socket != null && socket.readyState == WebSocket.open) {
        socket.add(
          jsonEncode({'type': 'resize', 'columns': columns, 'rows': rows}),
        );
      }
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _api != null && !_connecting) {
      _reconnect?.cancel();
      unawaited(_connect());
    }
  }

  Future<void> _restore() async {
    const vault = FlutterSecureStorage();
    _speakResponses = await vault.read(key: 'remote.speakResponses') != 'false';
    _speechReady = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') &&
            _listening &&
            mounted) {
          _finishSpeech();
        }
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _error = 'Microfone: ${e.errorMsg}';
            _listening = false;
          });
        }
      },
    );
    final saved = await RemoteApi.load();
    if (saved['host']!.isNotEmpty && saved['token']!.isNotEmpty) {
      _api = RemoteApi(
        host: saved['host']!,
        port: int.tryParse(saved['port']!) ?? 48761,
        token: saved['token']!,
        fingerprint: saved['fingerprint']!,
      );
      await _connect();
    }
    if (mounted) setState(() {});
  }

  Future<void> _configure() async {
    final saved = await RemoteApi.load();
    final host = TextEditingController(text: saved['host']);
    final port = TextEditingController(text: saved['port']);
    final token = TextEditingController(text: saved['token']);
    final fingerprint = TextEditingController(text: saved['fingerprint']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conectar ao computador Windows'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: host,
                  decoration: const InputDecoration(
                    labelText: 'Endereço interno ou IP do computador',
                  ),
                ),
                TextField(
                  controller: port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Porta TCP'),
                ),
                TextField(
                  controller: token,
                  obscureText: true,
                  maxLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Token de acesso',
                  ),
                ),
                TextField(
                  controller: fingerprint,
                  decoration: const InputDecoration(
                    labelText: 'SHA-256 do certificado TLS',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use o endereço acessível com FortiClient conectado. O fingerprint fixa a identidade do computador e impede aceitar outro certificado.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Salvar e conectar'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    final parsedPort = int.tryParse(port.text.trim());
    if (host.text.trim().isEmpty ||
        parsedPort == null ||
        token.text.trim().isEmpty ||
        fingerprint.text.trim().isEmpty) {
      setState(
        () => _error =
            'Preencha endereço, porta, token e fingerprint do certificado.',
      );
      return;
    }
    await RemoteApi.save(
      host: host.text,
      port: port.text,
      token: token.text,
      fingerprint: fingerprint.text,
    );
    _api = RemoteApi(
      host: host.text.trim(),
      port: parsedPort,
      token: token.text.trim(),
      fingerprint: fingerprint.text.trim(),
    );
    await _connect();
  }

  Future<void> _chooseTheme() async {
    final selected = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Aparência',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            RadioListTile<ThemeMode>(
              value: ThemeMode.light,
              groupValue: widget.themeMode,
              secondary: const Icon(Icons.light_mode_rounded),
              title: const Text('Tema claro'),
              onChanged: (value) => Navigator.pop(sheetContext, value),
            ),
            RadioListTile<ThemeMode>(
              value: ThemeMode.dark,
              groupValue: widget.themeMode,
              secondary: const Icon(Icons.dark_mode_rounded),
              title: const Text('Tema escuro'),
              onChanged: (value) => Navigator.pop(sheetContext, value),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) widget.onThemeModeChanged(selected);
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final api = _api;
    if (api == null) {
      await _configure();
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await api.check();
      _modules = await api.modules();
      final agentConfig = await api.agentConfiguration();
      _agentProviders = (agentConfig['providers'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      _agentProvider = agentConfig['provider'] as String?;
      _loadTasks(await api.tasks());
      final history = await api.history();
      _messages
        ..clear()
        ..addAll(
          history.map(
            (item) => _ChatMessage('${item['role']}', '${item['text']}'),
          ),
        );
      final agentStatus = await api.agentStatus();
      _sending = agentStatus['busy'] == true;
      if (agentStatus['lastError'] != null)
        _error = '${agentStatus['lastError']}';
      await _listenEvents();
      _reconnect?.cancel();
      _reconnect = null;
      if (mounted)
        setState(() {
          _connected = true;
          _connecting = false;
        });
      if (_selectedTab == 4) unawaited(_openRemotePowerShell());
      if (_selectedModuleId == 'moodle') unawaited(_loadMoodleHome());
      if (_selectedModuleId == 'agenda-email') unawaited(_loadAgendaHome());
      final selectedModule = _selectedModuleId;
      if (selectedModule != null && _hasOperationalWorkspace(selectedModule)) {
        unawaited(_loadModuleWorkspace(selectedModule));
      }
    } catch (e) {
      final staleSocket = _socket;
      _socket = null;
      await staleSocket?.close();
      await _detachRemotePowerShell();
      if (mounted)
        setState(() {
          _connected = false;
          _connecting = false;
          _error = _friendlyError(e);
        });
      _reconnect?.cancel();
      _reconnect = Timer(const Duration(seconds: 8), () {
        if (mounted) unawaited(_connect());
      });
    }
  }

  Future<void> _listenEvents() async {
    final previous = _socket;
    _socket = null;
    await previous?.close();
    final socket = await _api!.events();
    _socket = socket;
    socket.listen(
      (raw) {
        try {
          _onEvent(Map<String, dynamic>.from(jsonDecode('$raw') as Map));
        } catch (_) {}
      },
      onDone: () {
        if (identical(_socket, socket)) _lostConnection();
      },
      onError: (_) {
        if (identical(_socket, socket)) _lostConnection();
      },
    );
    socket.add('snapshot');
    unawaited(_refreshApprovals());
  }

  void _lostConnection() {
    if (!mounted || _connecting) return;
    setState(() => _connected = false);
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 8), () {
      if (mounted) unawaited(_connect());
    });
  }

  bool _isTaskActive(Map<String, dynamic> task) =>
      {'queued', 'running', 'cancel_requested'}.contains(task['status']);

  void _loadTasks(Iterable<Map<String, dynamic>> tasks) {
    _activeTasks.clear();
    _taskHistory.clear();
    for (final task in tasks) {
      _recordTask(task);
    }
  }

  void _recordTask(Map<String, dynamic> task) {
    final id = '${task['id']}';
    if (_isTaskActive(task)) {
      _taskHistory.removeWhere((item) => '${item['id']}' == id);
      _activeTasks[id] = task;
      return;
    }
    _activeTasks.remove(id);
    _taskHistory.removeWhere((item) => '${item['id']}' == id);
    _taskHistory.add(task);
    _taskHistory.sort((a, b) {
      final aTime = DateTime.tryParse('${a['updatedAt']}') ?? DateTime(1970);
      final bTime = DateTime.tryParse('${b['updatedAt']}') ?? DateTime(1970);
      return bTime.compareTo(aTime);
    });
    if (_taskHistory.length > 100) {
      _taskHistory.removeRange(100, _taskHistory.length);
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'agent_status':
        if (event['status'] == 'processing') {
          _assistantDraft = '';
          _messages.add(_ChatMessage('assistant', 'Estou trabalhando nisso…'));
        }
        if (event['status'] == 'complete') {
          if (_assistantDraft.isNotEmpty)
            _messages.add(_ChatMessage('assistant', _assistantDraft));
          _assistantDraft = '';
          _sending = false;
        }
        if (event['status'] == 'failed') _sending = false;
        if (event['status'] == 'cancelled') {
          if (_assistantDraft.isNotEmpty) {
            _messages.add(
              _ChatMessage(
                'assistant',
                'Resposta parcial (interrompida):\n$_assistantDraft',
              ),
            );
          }
          _assistantDraft = '';
          _messages.add(
            const _ChatMessage(
              'system',
              'Geração do agente interrompida. Uma operação do módulo que já começou pode continuar; verifique as tarefas ativas.',
            ),
          );
          _sending = false;
        }
      case 'agent_text':
        if (event['final'] == true) {
          _assistantDraft = '${event['text'] ?? ''}';
          _messages.add(_ChatMessage('assistant', _assistantDraft));
          if (_speakResponses) unawaited(_speak(_assistantDraft));
          _assistantDraft = '';
        } else {
          _assistantDraft += '${event['text'] ?? ''}';
        }
      case 'agent_error':
        _messages.add(_ChatMessage('error', '${event['message']}'));
        _sending = false;
      case 'agent_tool':
        _messages.add(_ChatMessage('system', 'Executando ${event['name']}'));
      case 'approval_required':
        unawaited(_refreshApprovals());
        _messages.add(
          _ChatMessage(
            'system',
            'Aguardando sua confirmação: ${event['tool']}',
          ),
        );
      case 'task':
        final task = Map<String, dynamic>.from(event['task'] as Map);
        _recordTask(task);
      case 'snapshot':
        final tasks = event['tasks'] as List? ?? const [];
        _loadTasks(tasks.map((task) => Map<String, dynamic>.from(task as Map)));
    }
    setState(() {});
  }

  Future<void> _refreshApprovals() async {
    try {
      final list = await _api!.approvals();
      if (mounted) setState(() => _approvals = list);
    } catch (_) {}
  }

  Future<void> _answerApproval(Map<String, dynamic> item, bool approved) async {
    await _api!.answerApproval('${item['id']}', approved);
    await _refreshApprovals();
    if (mounted)
      setState(
        () => _messages.add(
          _ChatMessage(
            'system',
            approved ? 'Ação autorizada.' : 'Ação recusada.',
          ),
        ),
      );
  }

  Future<void> _toggleMic() async {
    if (!_speechReady) {
      setState(
        () => _error =
            'Este Android não disponibilizou serviço de reconhecimento de fala.',
      );
      return;
    }
    if (_listening) {
      await _speech.stop();
      _finishSpeech();
      return;
    }
    await _stopSpeaking();
    _input.clear();
    _speechSubmitted = false;
    setState(() {
      _listening = true;
      _error = null;
    });
    await _speech.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: 'pt_BR',
        onDevice: true,
        listenFor: const Duration(minutes: 1),
        pauseFor: const Duration(seconds: 4),
      ),
      onResult: (result) {
        if (!_listening || _speechSubmitted) return;
        _input.text = result.recognizedWords;
        if (mounted) setState(() {});
      },
    );
  }

  void _finishSpeech() {
    if (!_listening || !mounted) return;
    final transcript = _input.text.trim();
    setState(() => _listening = false);
    if (transcript.isNotEmpty && !_speechSubmitted) {
      _speechSubmitted = true;
      unawaited(_send(transcript));
    }
  }

  Future<void> _send([String? value]) async {
    final text = (value ?? _input.text).trim();
    if (text.isEmpty || _api == null || !_connected || _sending) return;
    setState(() {
      _sending = true;
      _input.clear();
      _messages.add(_ChatMessage('user', text));
      _error = null;
    });
    await _stopSpeaking();
    try {
      await _api!.sendAgentMessage(text);
    } catch (e) {
      if (mounted)
        setState(() {
          _sending = false;
          _error = _friendlyError(e);
        });
    }
  }

  Future<void> _selectRemoteProvider(String? provider) async {
    if (provider == null || provider == _agentProvider || _api == null) return;
    try {
      final config = await _api!.selectAgentProvider(provider);
      if (!mounted) return;
      setState(() => _agentProvider = config['provider'] as String?);
      final selected = _agentProviders.where((item) => item['id'] == provider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Agente ${selected.isEmpty ? provider : selected.first['label']} selecionado no computador.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    }
  }

  Future<void> _cancelAgentMessage() async {
    if (!_sending || _api == null) return;
    try {
      await _api!.cancelAgentMessage();
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyError(e));
    }
  }

  Future<void> _speak(String text) async {
    final clean = text.trim();
    if (!_speakResponses || clean.isEmpty) return;
    try {
      await _speechOutput.invokeMethod<bool>('speak', {'text': clean});
    } on MissingPluginException {
      // Text responses remain available if the Android speech service is absent.
    } on PlatformException catch (error) {
      if (mounted)
        setState(() => _error = 'Áudio da resposta: ${error.message}');
    }
  }

  Future<void> _stopSpeaking() async {
    try {
      await _speechOutput.invokeMethod<void>('stop');
    } on MissingPluginException {
      // This channel is provided by the Android host app.
    } on PlatformException {
      // Speech output is optional and must not block text interaction.
    }
  }

  Future<Map<String, dynamic>?> _parameters(
    Map<String, dynamic> command, {
    Map<String, dynamic> initial = const {},
  }) async {
    final schema = Map<String, dynamic>.from(
      command['schema'] as Map? ?? const {},
    );
    final props = Map<String, dynamic>.from(
      schema['properties'] as Map? ?? const {},
    );
    final commandId = '${command['id']}';
    final fields = <String, TextEditingController>{};
    for (final entry in props.entries) {
      final spec = Map<String, dynamic>.from(entry.value as Map? ?? const {});
      if (spec['type'] == 'boolean' ||
          (_isPathField(entry.key) && !_isFileInput(commandId, entry.key))) {
        continue;
      }
      fields[entry.key] = TextEditingController(
        text: '${initial[entry.key] ?? spec['default'] ?? ''}',
      );
    }
    final bools = <String, bool>{
      for (final e in props.entries)
        if ((e.value as Map)['type'] == 'boolean')
          e.key: (e.value as Map)['default'] == true,
    };
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text('${command['title']}'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in props.entries)
                    if (fields.containsKey(entry.key) &&
                        _isFileInput(commandId, entry.key))
                      ListTile(
                        title: Text(
                          fields[entry.key]!.text.isEmpty
                              ? 'Selecionar arquivo para ${entry.key}'
                              : fields[entry.key]!.text,
                        ),
                        subtitle: Text(
                          '${(entry.value as Map)['description'] ?? ''}',
                        ),
                        leading: const Icon(Icons.attach_file),
                        onTap: () async {
                          final file = await FilePicker.pickFile(
                            type: FileType.custom,
                            allowedExtensions: const [
                              'pdf',
                              'docx',
                              'doc',
                              'xlsx',
                              'xlsm',
                              'xls',
                              'csv',
                              'json',
                              'txt',
                              'png',
                              'jpg',
                              'jpeg',
                              'zip',
                            ],
                          );
                          if (file == null) return;
                          try {
                            final uploaded = await _api!.upload(
                              file.name,
                              await file.readAsBytes(),
                            );
                            fields[entry.key]!.text =
                                '${uploaded['reference']}';
                            setDialog(() {});
                          } catch (error) {
                            if (context.mounted)
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text('$error')));
                          }
                        },
                      ),
                  for (final entry in props.entries)
                    if (fields.containsKey(entry.key) &&
                        !_isFileInput(commandId, entry.key))
                      if (((entry.value as Map)['enum'] as List?)
                          case final options?)
                        DropdownButtonFormField<String>(
                          initialValue:
                              options
                                  .map((option) => '$option')
                                  .contains(fields[entry.key]!.text)
                              ? fields[entry.key]!.text
                              : null,
                          decoration: InputDecoration(
                            labelText: entry.key,
                            helperText:
                                '${(entry.value as Map)['description'] ?? ''}',
                          ),
                          items: [
                            for (final option in options)
                              DropdownMenuItem(
                                value: '$option',
                                child: Text('$option'),
                              ),
                          ],
                          onChanged: (value) {
                            fields[entry.key]!.text = value ?? '';
                            setDialog(() {});
                          },
                        )
                      else
                        TextField(
                          controller: fields[entry.key],
                          maxLines:
                              (entry.value as Map)['type'] == 'object' ||
                                  (entry.value as Map)['type'] == 'array'
                              ? 4
                              : 1,
                          decoration: InputDecoration(
                            labelText: entry.key,
                            helperText:
                                '${(entry.value as Map)['description'] ?? ''}',
                          ),
                        ),
                  for (final entry in bools.entries)
                    CheckboxListTile(
                      value: entry.value,
                      title: Text(entry.key),
                      onChanged: (value) =>
                          setDialog(() => bools[entry.key] = value ?? false),
                    ),
                  if (props.isEmpty)
                    const Text('Esta ação não exige parâmetros.'),
                  if (command['requiresConfirmation'] == true)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Esta ação altera dados ou envia informações. Confirme antes de executar.',
                        style: TextStyle(color: Colors.deepOrange),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final input = <String, dynamic>{...bools};
                  for (final entry in fields.entries) {
                    final value = entry.value.text.trim();
                    if (value.isEmpty) continue;
                    final type = (props[entry.key] as Map)['type'];
                    final parsed = switch (type) {
                      'integer' => int.tryParse(value),
                      'number' => num.tryParse(value),
                      'object' || 'array' => jsonDecode(value),
                      _ => value,
                    };
                    if ((type == 'integer' || type == 'number') &&
                        parsed == null) {
                      throw FormatException('$value não é um número válido.');
                    }
                    if (type == 'object' && parsed is! Map) {
                      throw const FormatException(
                        'Este campo precisa receber um objeto JSON.',
                      );
                    }
                    if (type == 'array' && parsed is! List) {
                      throw const FormatException(
                        'Este campo precisa receber uma lista JSON.',
                      );
                    }
                    input[entry.key] = parsed;
                  }
                  final required = (schema['required'] as List? ?? const [])
                      .cast<String>();
                  final missing = required.where((key) {
                    final value = input[key];
                    return value == null ||
                        (value is String && value.trim().isEmpty);
                  }).toList();
                  if (missing.isNotEmpty) {
                    throw FormatException(
                      'Preencha os campos obrigatórios: ${missing.join(', ')}.',
                    );
                  }
                  Navigator.pop(context, input);
                } catch (error) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('$error')));
                }
              },
              child: const Text('Executar'),
            ),
          ],
        ),
      ),
    );
    for (final controller in fields.values) {
      controller.dispose();
    }
    return result;
  }

  Future<void> _runCommand(
    Map<String, dynamic> command, {
    Map<String, dynamic> initial = const {},
  }) async {
    if (!_connected) return;
    final input = await _parameters(command, initial: initial);
    if (input == null) return;
    if (command['requiresConfirmation'] == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${command['title']}?'),
          content: Text(
            '${command['description']}\n\nConfirma esta operação no computador?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      var task = await _api!.runCommand(
        '${command['id']}',
        input,
        confirmed: true,
      );
      if (mounted) {
        setState(() {
          _recordTask(Map<String, dynamic>.from(task));
          _messages.add(
            _ChatMessage(
              'system',
              task['status'] == 'queued'
                  ? 'O Windows recebeu “${task['title']}” e colocou na fila.'
                  : 'O Windows iniciou “${task['title']}”.',
            ),
          );
        });
      }
      final started = DateTime.now();
      const terminal = {'succeeded', 'failed', 'cancelled', 'interrupted'};
      while (mounted && !terminal.contains(task['status'])) {
        if (DateTime.now().difference(started) > const Duration(minutes: 10)) {
          if (mounted) {
            setState(() {
              _recordTask(Map<String, dynamic>.from(task));
              _messages.add(
                _ChatMessage(
                  'error',
                  'A tarefa ainda está ${task['status']}. Ela continua disponível na tela Tarefas; confira o estado no Windows antes de repetir.',
                ),
              );
            });
          }
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        task = await _api!.task('${task['id']}');
        if (mounted)
          setState(() => _recordTask(Map<String, dynamic>.from(task)));
      }
      if (!mounted) return;
      final result = Map<String, dynamic>.from(
        task['result'] as Map? ?? const {},
      );
      final artifacts = (result['artifacts'] as List? ?? const [])
          .map((x) => Map<String, dynamic>.from(x as Map))
          .toList();
      setState(() {
        _recordTask(Map<String, dynamic>.from(task));
        _messages.add(
          _ChatMessage(
            result['ok'] == false ? 'error' : 'system',
            _taskSummary(task),
            artifacts: artifacts,
          ),
        );
      });
      await _showTaskResult(task);
      if (command['mutates'] == true && _selectedModuleId == 'moodle') {
        unawaited(_loadMoodleHome());
      }
      if (command['mutates'] == true && _selectedModuleId == 'agenda-email') {
        unawaited(_loadAgendaHome());
      }
      final selectedModule = _selectedModuleId;
      if (command['mutates'] == true &&
          selectedModule != null &&
          _hasOperationalWorkspace(selectedModule)) {
        unawaited(_loadModuleWorkspace(selectedModule));
      }
      if (command['id'] == 'parecer.processos.abrir' &&
          _selectedModuleId == 'elabora-relato') {
        unawaited(_loadModuleWorkspace('elabora-relato'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyError(e));
    }
  }

  bool _isFileInput(String commandId, String key) =>
      _remoteUploadFields[commandId]?.contains(key.toLowerCase()) ?? false;

  String _taskSummary(Map<String, dynamic> task) {
    final result = Map<String, dynamic>.from(
      task['result'] as Map? ?? const {},
    );
    final message = result.remove('message');
    result
      ..remove('ok')
      ..remove('artifacts');
    final details = result.isEmpty
        ? ''
        : '\n${const JsonEncoder.withIndent('  ').convert(result)}';
    return '${task['title']}: ${task['status']}${message == null ? '' : ' — $message'}$details';
  }

  Future<void> _showTaskResult(Map<String, dynamic> task) async {
    if (!mounted) return;
    final result = Map<String, dynamic>.from(
      task['result'] as Map? ?? const {},
    );
    final artifacts = (result['artifacts'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final message = result['message']?.toString();
    final details = Map<String, dynamic>.from(result)
      ..remove('ok')
      ..remove('message')
      ..remove('artifacts');
    final succeeded = task['status'] == 'succeeded' && result['ok'] != false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.58,
          maxChildSize: 0.92,
          builder: (context, controller) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 26),
            children: [
              Row(
                children: [
                  Icon(
                    succeeded
                        ? Icons.task_alt_rounded
                        : Icons.error_outline_rounded,
                    color: succeeded
                        ? const Color(0xff55d6a6)
                        : const Color(0xffff8a80),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${task['title']}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                succeeded ? 'Concluída no computador' : 'Não foi concluída',
                style: TextStyle(
                  color: succeeded
                      ? const Color(0xff55d6a6)
                      : const Color(0xffff8a80),
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (message != null && message.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(message, style: const TextStyle(height: 1.45)),
              ],
              if (details.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  'Resultado',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(details),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
              for (final artifact in artifacts)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.download_rounded),
                    title: Text('${artifact['name']}'),
                    subtitle: const Text('Salvar arquivo recebido do Windows'),
                    onTap: () => _downloadArtifact(artifact),
                  ),
                ),
              if (message == null && details.isEmpty && artifacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: Text('A tarefa terminou sem retornar detalhes.'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isPathField(String key) {
    final value = key.toLowerCase();
    return value.contains('path') ||
        value.contains('file') ||
        value.contains('arquivo') ||
        value.contains('folder') ||
        value.contains('pasta') ||
        value.contains('comprovante');
  }

  Future<void> _downloadArtifact(Map<String, dynamic> artifact) async {
    try {
      final bytes = await _api!.download('${artifact['id']}');
      await FilePicker.saveFile(
        fileName: '${artifact['name']}',
        bytes: Uint8List.fromList(bytes),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  String _friendlyError(Object error) {
    final text = '$error';
    if (text.contains('HandshakeException') ||
        text.contains('CERTIFICATE_VERIFY_FAILED'))
      return 'Certificado não confere. Compare o fingerprint SHA-256 com o mostrado no Windows.';
    if (text.contains('SocketException') ||
        text.contains('Connection refused') ||
        text.contains('timed out'))
      return 'Computador indisponível. Confira se está ligado, com Gestor UFU ativo e FortiClient conectado.';
    return text
        .replaceFirst('Exception: ', '')
        .replaceFirst('HttpException: ', '');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnect?.cancel();
    _socket?.close();
    _speech.stop();
    _input.dispose();
    _emailSearch.dispose();
    _remoteTerminalController.dispose();
    unawaited(_terminalSocket?.close());
    super.dispose();
  }

  String get _pageTitle {
    final modules = _modules.where((item) => item['id'] == _selectedModuleId);
    if (modules.isNotEmpty) return '${modules.first['title']}';
    return switch (_selectedTab) {
      0 => 'Início',
      1 => 'Módulos',
      2 => 'Tarefas',
      4 => 'PowerShell',
      _ => 'Agente',
    };
  }

  String? get _agentProviderLabel {
    for (final provider in _agentProviders) {
      if (provider['id'] == _agentProvider) return '${provider['label']}';
    }
    return null;
  }

  String get _agentProviderShortLabel => switch (_agentProvider) {
    'claude' => 'Claude',
    'chatgpt' => 'ChatGPT',
    'gemini' => 'Gemini',
    'copilot' => 'Copilot',
    _ => _agentProviderLabel ?? 'Selecionar',
  };

  Color _moduleAccent(Map<String, dynamic> module) {
    final value = module['accentColor'];
    return value is num ? Color(value.toInt()) : const Color(0xff6c63ff);
  }

  IconData _moduleIcon(Map<String, dynamic> module) {
    final value = module['iconCodePoint'];
    if (value is! num) return Icons.apps_rounded;
    return IconData(
      value.toInt(),
      fontFamily: module['iconFontFamily'] as String? ?? 'MaterialIcons',
      fontPackage: module['iconFontPackage'] as String?,
    );
  }

  void _openModule(Map<String, dynamic> module) {
    setState(() {
      _selectedModuleId = '${module['id']}';
      _selectedTab = 1;
      _moduleActionsTab = false;
      _moduleWorkspaceData = null;
      _moduleWorkspaceError = null;
    });
    if (module['id'] == 'moodle') unawaited(_loadMoodleHome());
    if (module['id'] == 'agenda-email') unawaited(_loadAgendaHome());
    if (_hasOperationalWorkspace('${module['id']}')) {
      unawaited(_loadModuleWorkspace('${module['id']}'));
    }
  }

  bool _hasOperationalWorkspace(String id) => const {
    'audita-bancas',
    'diario',
    'elabora-relato',
    'planos-ensino',
    'planos-trabalho',
    'ajusta-horarios',
    'equivalencia-alunos',
    'progressao',
  }.contains(id);

  Future<void> _loadModuleWorkspace(String moduleId) async {
    if (!_connected || _api == null) return;
    final query = switch (moduleId) {
      'audita-bancas' => ('auditaBancas.listar', <String, dynamic>{}),
      'diario' => ('diario.listar', <String, dynamic>{'lancamentos': true}),
      'elabora-relato' => ('parecer.processos.listar', <String, dynamic>{}),
      'planos-ensino' => ('planosEnsino.listar', <String, dynamic>{}),
      'planos-trabalho' => ('planosTrabalho.listar', <String, dynamic>{}),
      'ajusta-horarios' => ('ajustaHorarios.listar', <String, dynamic>{}),
      'equivalencia-alunos' => ('equivalencia.listar', <String, dynamic>{}),
      'progressao' => ('progressao.listar', <String, dynamic>{}),
      _ => null,
    };
    if (query == null) return;
    setState(() {
      _moduleWorkspaceLoading = true;
      _moduleWorkspaceError = null;
    });
    try {
      final result = await _executeRemoteCommand(moduleId, query.$1, query.$2);
      if (!mounted || _selectedModuleId != moduleId) return;
      setState(() {
        _moduleWorkspaceData = result;
        _moduleWorkspaceLoading = false;
      });
    } catch (error) {
      if (!mounted || _selectedModuleId != moduleId) return;
      setState(() {
        _moduleWorkspaceError = '$error'.replaceFirst('HttpException: ', '');
        _moduleWorkspaceLoading = false;
      });
    }
  }

  Map<String, dynamic>? _commandById(String moduleId, String commandId) {
    for (final module in _modules.where((item) => item['id'] == moduleId)) {
      for (final value in module['commands'] as List? ?? const []) {
        final command = Map<String, dynamic>.from(value as Map);
        if (command['id'] == commandId) return command;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _executeRemoteCommand(
    String moduleId,
    String commandId,
    Map<String, dynamic> input, {
    bool confirmed = false,
  }) async {
    final command = _commandById(moduleId, commandId);
    if (command == null) throw HttpException('Ação não disponível no Windows.');
    if (command['requiresConfirmation'] == true && !confirmed) {
      throw HttpException('Esta ação exige confirmação antes de executar.');
    }
    final task = await _api!.runCommand(commandId, input, confirmed: true);
    var current = Map<String, dynamic>.from(task);
    if (mounted) setState(() => _recordTask(current));
    final started = DateTime.now();
    const terminal = {'succeeded', 'failed', 'cancelled', 'interrupted'};
    while (!terminal.contains(current['status'])) {
      if (DateTime.now().difference(started) > const Duration(minutes: 10)) {
        throw HttpException(
          'A tarefa continua ${current['status']}. Ela permanece na tela Tarefas para acompanhamento.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      current = await _api!.task('${current['id']}');
      if (mounted) setState(() => _recordTask(current));
    }
    final result = Map<String, dynamic>.from(
      current['result'] as Map? ?? const {},
    );
    if (current['status'] != 'succeeded' || result['ok'] == false) {
      throw HttpException(
        '${result['message'] ?? 'A operação terminou com status ${current['status']}.'}',
      );
    }
    return result;
  }

  Future<void> _loadMoodleHome() async {
    if (!_connected || _api == null) return;
    setState(() {
      _moodleHomeLoading = true;
      _moodleHomeError = null;
    });
    try {
      final periods = await _executeRemoteCommand(
        'moodle',
        'moodle.listarPeriodos',
        const {},
      );
      final configurations = await _executeRemoteCommand(
        'moodle',
        'moodle.listar',
        const {},
      );
      if (!mounted) return;
      setState(() {
        _moodleHomeData = {
          'activeTerm': periods['periodoAtivo'],
          'terms': periods['periodos'] as List? ?? const [],
          'configurations':
              configurations['configuracoes'] as List? ?? const [],
        };
        _moodleHomeLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _moodleHomeError = '$error'.replaceFirst('HttpException: ', '');
        _moodleHomeLoading = false;
      });
    }
  }

  Future<void> _loadAgendaHome() async {
    if (!_connected || _api == null) return;
    setState(() {
      _agendaHomeLoading = true;
      _agendaHomeError = null;
    });
    try {
      final calendars = await _executeRemoteCommand(
        'agenda-email',
        'agenda.listarCalendarios',
        const {},
      );
      final messages = await _executeRemoteCommand(
        'agenda-email',
        'email.listar',
        {
          'busca': _emailSearch.text.trim(),
          'nao_lidos': _emailUnreadOnly,
          'pagina': 0,
        },
      );
      if (!mounted) return;
      setState(() {
        _agendaCalendars = (calendars['calendarios'] as List? ?? const [])
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        _emailMessages = (messages['mensagens'] as List? ?? const [])
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        _agendaHomeLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _agendaHomeError = '$error'.replaceFirst('HttpException: ', '');
        _agendaHomeLoading = false;
      });
    }
  }

  Future<void> _loadAgendaEvents() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 7));
    setState(() => _agendaHomeLoading = true);
    try {
      final result = await _executeRemoteCommand(
        'agenda-email',
        'agenda.listarEventos',
        {'inicio': start.toIso8601String(), 'fim': end.toIso8601String()},
      );
      if (!mounted) return;
      setState(() {
        _agendaEvents = (result['eventos'] as List? ?? const [])
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        _agendaEventsLoaded = true;
        _agendaHomeLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _agendaHomeError = '$error'.replaceFirst('HttpException: ', '');
        _agendaHomeLoading = false;
      });
    }
  }

  Future<void> _loadAgendaMessages() async {
    setState(() {
      _agendaHomeLoading = true;
      _agendaHomeError = null;
    });
    try {
      final result = await _executeRemoteCommand(
        'agenda-email',
        'email.listar',
        {
          'busca': _emailSearch.text.trim(),
          'nao_lidos': _emailUnreadOnly,
          'pagina': 0,
        },
      );
      if (!mounted) return;
      setState(() {
        _emailMessages = (result['mensagens'] as List? ?? const [])
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
        _agendaHomeLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _agendaHomeError = '$error'.replaceFirst('HttpException: ', '');
        _agendaHomeLoading = false;
      });
    }
  }

  Future<void> _runPresetCommand(
    String commandId,
    Map<String, dynamic> input,
  ) => _runPresetModuleCommand('moodle', commandId, input);

  Future<void> _runPresetModuleCommand(
    String moduleId,
    String commandId,
    Map<String, dynamic> input,
  ) async {
    final command = _commandById(moduleId, commandId);
    if (command == null || !_connected) return;
    if (command['requiresConfirmation'] == true) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${command['title']}?'),
          content: Text(
            '${command['description']}\n\nConfirma esta ação no computador?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Voltar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      final result = await _executeRemoteCommand(
        moduleId,
        commandId,
        input,
        confirmed: true,
      );
      if (mounted) {
        final message = '${result['message'] ?? 'Operação concluída.'}';
        final artifacts = (result['artifacts'] as List? ?? const [])
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            action: artifacts.isEmpty
                ? null
                : SnackBarAction(
                    label: artifacts.length == 1
                        ? 'Baixar arquivo'
                        : 'Baixar primeiro',
                    onPressed: () =>
                        unawaited(_downloadArtifact(artifacts.first)),
                  ),
          ),
        );
      }
      if (moduleId == 'agenda-email' && commandId == 'email.ler') {
        await _showTaskResult({
          'title': command['title'],
          'status': 'succeeded',
          'result': {'ok': true, ...result},
        });
      }
      if (command['mutates'] == true) {
        if (moduleId == 'moodle') await _loadMoodleHome();
        if (moduleId == 'agenda-email') await _loadAgendaHome();
        if (_hasOperationalWorkspace(moduleId)) {
          await _loadModuleWorkspace(moduleId);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          final message = '$error'.replaceFirst('HttpException: ', '');
          if (moduleId == 'agenda-email') {
            _agendaHomeError = message;
          } else {
            _moodleHomeError = message;
          }
        });
      }
    }
  }

  Widget _summaryCard(IconData icon, String value, String label) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xff00d4ff), size: 23),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _moduleCard(Map<String, dynamic> module) {
    final enabled = module['enabled'] == true;
    final accent = _moduleAccent(module);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? () => _openModule(module) : null,
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accent.withAlpha(enabled ? 40 : 22),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      _moduleIcon(module),
                      color: enabled ? accent : accent.withAlpha(150),
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    enabled
                        ? Icons.arrow_forward_rounded
                        : Icons.lock_outline_rounded,
                    color: enabled
                        ? accent
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 19,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${module['category'] ?? 'MÓDULO'}'.toUpperCase(),
                style: TextStyle(
                  color: enabled
                      ? accent
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${module['title']}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${module['description']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 13),
              Text(
                enabled ? 'Acessar módulo' : 'Disponível em breve',
                style: TextStyle(
                  color: enabled
                      ? accent
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState(IconData icon, String title, String description) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xff6c63ff), size: 38),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      );

  Widget _buildHome() => ListView(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
    children: [
      Text(
        'CENTRAL DE UTILIDADES',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 7),
      Text(
        'Gestor UFU',
        style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 5),
      Text(
        'Acesse pelo celular as ferramentas que você já usa no Windows.',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: ListTile(
          leading: Icon(
            _connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            color: _connected
                ? const Color(0xff00e676)
                : const Color(0xffffab00),
          ),
          title: Text(
            _connected ? 'Computador conectado' : 'Computador desconectado',
          ),
          subtitle: Text(
            _connected
                ? 'As operações são executadas neste computador.'
                : 'Conecte ao Gestor UFU no Windows pela VPN.',
          ),
          trailing: IconButton(
            onPressed: _connecting ? null : _connect,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Atualizar conexão',
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _summaryCard(
              Icons.apps_rounded,
              '${_modules.length}',
              'Módulos',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _summaryCard(
              Icons.sync_rounded,
              '${_activeTasks.length}',
              'Em andamento',
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          const Expanded(
            child: Text(
              'Módulos',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _selectedTab = 1;
              _selectedModuleId = null;
            }),
            child: const Text('Ver todos'),
          ),
        ],
      ),
      if (_modules.isEmpty)
        _emptyState(
          Icons.apps_outlined,
          _connected ? 'Nenhum módulo disponível' : 'Aguardando conexão',
          'Os módulos disponíveis no computador aparecerão aqui.',
        )
      else
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 640 ? 2 : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final module in _modules)
                  SizedBox(width: width, child: _moduleCard(module)),
              ],
            );
          },
        ),
    ],
  );

  Widget _buildModules() {
    final selection = _modules.where((item) => item['id'] == _selectedModuleId);
    if (selection.isNotEmpty) return _buildModuleDetail(selection.first);
    final query = _moduleFilter.trim().toLowerCase();
    final filtered = _modules
        .where(
          (item) =>
              query.isEmpty ||
              '${item['title']} ${item['category']} ${item['description']}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        const Text(
          'MÓDULOS DO GESTOR UFU',
          style: TextStyle(
            color: Color(0xff9ea2c4),
            fontSize: 11,
            letterSpacing: 1.3,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          onChanged: (value) => setState(() => _moduleFilter = value),
          decoration: const InputDecoration(
            hintText: 'Buscar módulo',
            prefixIcon: Icon(Icons.search_rounded),
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14)),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (filtered.isEmpty)
          _emptyState(
            Icons.search_off_rounded,
            'Nenhum módulo encontrado',
            'Tente buscar pelo nome ou pela categoria.',
          )
        else
          for (final module in filtered) _moduleCard(module),
      ],
    );
  }

  Widget _buildMoodleHome(Map<String, dynamic> module) {
    final accent = _moduleAccent(module);
    final data = _moodleHomeData;
    final terms = (data?['terms'] as List? ?? const [])
        .map((value) => '$value')
        .toList();
    final activeTerm = '${data?['activeTerm'] ?? ''}';
    final configs = (data?['configurations'] as List? ?? const [])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _selectedModuleId = null),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Todos os módulos'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accent.withAlpha(38),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(_moduleIcon(module), color: accent, size: 25),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${module['category']}'.toUpperCase(),
                    style: TextStyle(
                      color: accent,
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${module['title']}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Atualizar dados do Windows',
              onPressed: _moodleHomeLoading ? null : _loadMoodleHome,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (_moodleHomeLoading && data == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_moodleHomeError != null && data == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Não foi possível carregar o Config Moodle',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _moodleHomeError!,
                    style: const TextStyle(color: Color(0xffff8a80)),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _loadMoodleHome,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Tentar novamente'),
                  ),
                ],
              ),
            ),
          )
        else ...[
          if (_moodleHomeError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _moodleHomeError!,
                style: const TextStyle(color: Color(0xffff8a80)),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: terms.contains(activeTerm) ? activeTerm : null,
                  decoration: const InputDecoration(
                    labelText: 'Período letivo',
                    prefixIcon: Icon(Icons.calendar_month_rounded),
                  ),
                  items: [
                    for (final term in terms)
                      DropdownMenuItem(value: term, child: Text(term)),
                  ],
                  onChanged: (value) {
                    if (value != null && value != activeTerm) {
                      unawaited(
                        _runPresetCommand('moodle.selecionarPeriodo', {
                          'periodo': value,
                        }),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _connected ? () => _showMoodleAddMenu(module) : null,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Novo'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Configurações de $activeTerm',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${configs.length}',
                style: TextStyle(color: accent, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_moodleHomeLoading)
            const LinearProgressIndicator(minHeight: 2)
          else if (configs.isEmpty)
            _emptyState(
              Icons.menu_book_outlined,
              'Nenhuma configuração neste período',
              'Crie uma configuração vazia ou importe a planilha da disciplina.',
            )
          else
            for (final config in configs) _moodleConfigCard(config, accent),
        ],
      ],
    );
  }

  Widget _moodleConfigCard(Map<String, dynamic> config, Color accent) {
    final name = '${config['nome'] ?? 'Disciplina'}';
    final course = '${config['moodleCourseName'] ?? ''}';
    final courseId = config['moodleCourseId'];
    final start = DateTime.tryParse('${config['inicioSemestre'] ?? ''}');
    final sections = config['secoes'] ?? 0;
    final activities = config['atividades'] ?? 0;
    final id = '${config['id']}';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showMoodleConfigActions(config, accent),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: accent.withAlpha(35),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.menu_book_rounded, color: accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(Icons.more_vert_rounded, color: accent),
                ],
              ),
              const SizedBox(height: 10),
              if (course.isNotEmpty)
                Text(
                  course,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              Text(
                'Início: ${start == null ? 'não informado' : '${start.day.toString().padLeft(2, '0')}/${start.month.toString().padLeft(2, '0')}/${start.year}'}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 11),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _moodlePill(Icons.view_list_rounded, '$sections seções'),
                  _moodlePill(
                    Icons.checklist_rounded,
                    '$activities atividades',
                  ),
                  if (courseId != null)
                    _moodlePill(Icons.cloud_done_rounded, 'Moodle $courseId'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _runPresetCommand(
                      'moodle.exportarPlanilha',
                      {'configId': id},
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Exportar'),
                  ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: courseId == null
                        ? null
                        : () => _runPresetCommand('moodle.sincronizarAgora', {
                            'configId': id,
                          }),
                    icon: const Icon(Icons.sync_rounded, size: 18),
                    label: const Text('Sincronizar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moodlePill(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );

  Future<void> _showMoodleAddMenu(Map<String, dynamic> module) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('Nova configuração vazia'),
              subtitle: const Text('Começar uma disciplina do zero'),
              onTap: () {
                Navigator.pop(sheetContext);
                final command = _commandById(
                  'moodle',
                  'moodle.criarConfiguracao',
                );
                if (command != null) unawaited(_runCommand(command));
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_rounded),
              title: const Text('Importar planilha'),
              subtitle: const Text('Usar um arquivo .xlsx do telefone'),
              onTap: () {
                Navigator.pop(sheetContext);
                final command = _commandById(
                  'moodle',
                  'moodle.importarPlanilha',
                );
                if (command != null) unawaited(_runCommand(command));
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _showMoodleConfigActions(
    Map<String, dynamic> config,
    Color accent,
  ) async {
    final id = '${config['id']}';
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Text(
                '${config['nome']}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.menu_book_rounded, color: accent),
              title: const Text('Ver seções e atividades'),
              subtitle: const Text('Consultar a estrutura desta disciplina'),
              onTap: () => Navigator.pop(sheetContext, 'details'),
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Exportar planilha'),
              onTap: () => Navigator.pop(sheetContext, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Excluir configuração'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result == 'export') {
      await _runPresetCommand('moodle.exportarPlanilha', {'configId': id});
    } else if (result == 'delete') {
      await _runPresetCommand('moodle.excluir', {'configId': id});
    } else if (result == 'details') {
      await _showMoodleConfigDetails(id, accent);
    }
  }

  Future<void> _showMoodleConfigDetails(String id, Color accent) async {
    try {
      final result = await _executeRemoteCommand(
        'moodle',
        'moodle.obterConfiguracao',
        {'configId': id},
      );
      final config = Map<String, dynamic>.from(result['configuracao'] as Map);
      final sections = (config['sections'] as List? ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.72,
            maxChildSize: 0.94,
            builder: (context, scrollController) => ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
              children: [
                Text(
                  '${config['name']}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text('${sections.length} seções nesta configuração'),
                const SizedBox(height: 12),
                for (final section in sections)
                  Card(
                    child: ExpansionTile(
                      leading: Icon(Icons.view_list_rounded, color: accent),
                      title: Text('${section['name']}'),
                      subtitle: Text(
                        '${(section['activities'] as List? ?? const []).length} atividades',
                      ),
                      children: [
                        for (final activity
                            in section['activities'] as List? ?? const [])
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.check_circle_outline_rounded,
                            ),
                            title: Text('${(activity as Map)['name']}'),
                            subtitle: Text('${activity['activityType'] ?? ''}'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _moodleHomeError = '$error'.replaceFirst('HttpException: ', ''),
        );
      }
    }
  }

  Widget _buildAgendaHome(Map<String, dynamic> module) {
    final accent = _moduleAccent(module);
    final isEmail = _agendaTabIndex == 1;
    final commands = (module['commands'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    Map<String, dynamic>? findCommand(String id) {
      for (final command in commands) {
        if (command['id'] == id) return command;
      }
      return null;
    }

    String label(Map row, List<String> keys, [String fallback = '']) {
      for (final key in keys) {
        final value = row[key];
        if (value != null && '$value'.trim().isNotEmpty) return '$value';
      }
      return fallback;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _selectedModuleId = null),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Todos os módulos'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
        Row(
          children: [
            Icon(Icons.event_note_rounded, color: accent, size: 27),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Agendas e E-mails',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Atualizar',
              onPressed: _agendaHomeLoading
                  ? null
                  : () => isEmail ? _loadAgendaMessages() : _loadAgendaHome(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              icon: Icon(Icons.calendar_month_rounded),
              label: Text('Agenda'),
            ),
            ButtonSegment(
              value: 1,
              icon: Icon(Icons.mail_outline_rounded),
              label: Text('E-mails'),
            ),
          ],
          selected: {_agendaTabIndex},
          onSelectionChanged: (selection) {
            setState(() => _agendaTabIndex = selection.first);
            if (selection.first == 0 && !_agendaEventsLoaded)
              unawaited(_loadAgendaEvents());
            if (selection.first == 1) unawaited(_loadAgendaMessages());
          },
        ),
        if (_agendaHomeLoading) const LinearProgressIndicator(),
        if (_agendaHomeError != null) ...[
          const SizedBox(height: 10),
          Card(
            color: const Color(0xff492d36),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_agendaHomeError!),
            ),
          ),
        ],
        if (!isEmail) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Calendários conectados',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: () => _loadAgendaEvents(),
                icon: const Icon(Icons.event_available_rounded),
                label: const Text('Próximos 7 dias'),
              ),
            ],
          ),
          if (_agendaCalendars.isEmpty && !_agendaHomeLoading)
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Nenhum calendário conectado'),
              ),
            ),
          for (final calendar in _agendaCalendars)
            Card(
              child: ListTile(
                leading: Icon(Icons.calendar_today_rounded, color: accent),
                title: Text(
                  label(calendar, ['name', 'nome', 'summary'], 'Calendário'),
                ),
                subtitle: Text(
                  [
                    label(calendar, ['account', 'conta']),
                    label(calendar, ['provider', 'provedor']),
                    if (calendar['padrao_pessoal'] == true) 'Pessoal',
                    if (calendar['padrao_profissional'] == true) 'Profissional',
                  ].where((e) => e.isNotEmpty).join(' • '),
                ),
              ),
            ),
          if (_agendaEventsLoaded) ...[
            const SizedBox(height: 8),
            const Text(
              'Eventos',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            if (_agendaEvents.isEmpty)
              const Card(
                child: ListTile(
                  title: Text('Nenhum evento encontrado neste período'),
                ),
              ),
            for (final event in _agendaEvents)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.event_rounded),
                  title: Text(
                    label(event, ['titulo', 'summary', 'subject'], 'Evento'),
                  ),
                  subtitle: Text(
                    '${label(event, ['inicio'], 'Horário não informado')}\n${[
                      label(event, ['conta', 'account']),
                      label(event, ['calendario', 'calendar']),
                    ].where((e) => e.isNotEmpty).join(' • ')}',
                  ),
                  isThreeLine: true,
                ),
              ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: findCommand('agenda.criarEvento') == null
                ? null
                : () => _runCommand(findCommand('agenda.criarEvento')!),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Criar evento'),
          ),
        ] else ...[
          const SizedBox(height: 12),
          TextField(
            controller: _emailSearch,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _loadAgendaMessages(),
            decoration: InputDecoration(
              hintText: 'Buscar e-mails',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: _loadAgendaMessages,
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilterChip(
            label: const Text('Somente não lidos'),
            selected: _emailUnreadOnly,
            onSelected: (value) {
              setState(() => _emailUnreadOnly = value);
              unawaited(_loadAgendaMessages());
            },
          ),
          if (_emailMessages.isEmpty && !_agendaHomeLoading)
            const Card(
              child: ListTile(
                leading: Icon(Icons.mark_email_read_outlined),
                title: Text('Nenhuma mensagem encontrada'),
              ),
            ),
          for (final email in _emailMessages)
            Card(
              child: ListTile(
                leading: Icon(
                  email['lida'] == true
                      ? Icons.drafts_outlined
                      : Icons.mark_email_unread_rounded,
                  color: accent,
                ),
                title: Text(
                  label(email, ['assunto', 'subject'], '(Sem assunto)'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${label(email, ['remetente', 'from'])}\n${label(email, ['data', 'receivedDateTime'])}  •  ${label(email, ['conta', 'account'])}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                onTap: () =>
                    _runPresetModuleCommand('agenda-email', 'email.ler', {
                      'id': '${email['id']}',
                      'provider_id': '${email['provider_id']}',
                      'assunto': label(email, ['assunto', 'subject']),
                      'remetente': label(email, ['remetente', 'from']),
                      'conta': label(email, ['conta', 'account']),
                    }),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) => _runPresetModuleCommand(
                    'agenda-email',
                    'email.alterarLido',
                    {
                      'id': '${email['id']}',
                      'provider_id': '${email['provider_id']}',
                      'assunto': label(email, ['assunto', 'subject']),
                      'remetente': label(email, ['remetente', 'from']),
                      'conta': label(email, ['conta', 'account']),
                      'lida': value == 'read',
                    },
                  ),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: email['lida'] == true ? 'unread' : 'read',
                      child: Text(
                        email['lida'] == true
                            ? 'Marcar como não lido'
                            : 'Marcar como lido',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (findCommand('email.ler') == null)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Este computador não disponibiliza leitura remota de e-mails.',
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildOperationalWorkspace(Map<String, dynamic> module) {
    final moduleId = '${module['id']}';
    final accent = _moduleAccent(module);
    final data = _moduleWorkspaceData ?? const <String, dynamic>{};
    final commands = (module['commands'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final groups = _groupModuleCommands(moduleId, commands);
    Map<String, dynamic>? command(String id) {
      for (final value in commands) {
        if (value['id'] == id) return value;
      }
      return null;
    }

    final primary = switch (moduleId) {
      'audita-bancas' => 'auditaBancas.abrirPdf',
      'diario' => 'diario.importarPlanilha',
      'elabora-relato' => 'parecer.processos.criar',
      'planos-ensino' => 'planosEnsino.salvar',
      'planos-trabalho' => 'planosTrabalho.salvarCadastro',
      'ajusta-horarios' => 'ajustaHorarios.importarPlanilha',
      'equivalencia-alunos' => 'equivalencia.importarAnalise',
      'progressao' => 'progressao.criar',
      _ => '',
    };
    final primaryInput = moduleId == 'planos-ensino'
        ? const <String, dynamic>{'plano': <String, dynamic>{}}
        : const <String, dynamic>{};
    final records = switch (moduleId) {
      'audita-bancas' =>
        (data['documentos'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      'diario' =>
        (data['diarios'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      'elabora-relato' =>
        (data['processos'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      'planos-ensino' || 'planos-trabalho' =>
        (data['planos'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      'equivalencia-alunos' =>
        (data['cases'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      'progressao' =>
        (data['processos'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
      _ => <Map<String, dynamic>>[],
    };
    final recordTitle = switch (moduleId) {
      'audita-bancas' => 'Documentos auditados',
      'diario' => 'Diários salvos',
      'elabora-relato' => 'Processos de parecer',
      'planos-ensino' => 'Planos cadastrados',
      'planos-trabalho' => 'Planos de trabalho',
      'equivalencia-alunos' => 'Análises de alunos',
      'progressao' => 'Processos de carreira',
      _ => 'Período e horários',
    };
    final titleFor = (Map<String, dynamic> item) => switch (moduleId) {
      'audita-bancas' => '${item['nome'] ?? 'Documento'}',
      'diario' => '${item['nome'] ?? item['periodo'] ?? 'Diário'}',
      'elabora-relato' => '${item['nome'] ?? 'Processo'}',
      'planos-ensino' => '${item['nome'] ?? 'Plano de ensino'}',
      'planos-trabalho' => '${item['nome'] ?? 'Plano de trabalho'}',
      'equivalencia-alunos' => '${item['student'] ?? 'Análise'}',
      'progressao' => '${item['docente'] ?? 'Processo'}',
      _ => '${item['nome'] ?? ''}',
    };
    final subtitleFor = (Map<String, dynamic> item) => switch (moduleId) {
      'audita-bancas' =>
        '${item['origem'] ?? ''} • ${item['pendentes'] ?? 0} pendentes • ${item['aceitas'] ?? 0} aceitas',
      'diario' => '${item['lancamentos'] ?? 0} lançamentos',
      'elabora-relato' =>
        '${item['numeroSei'] ?? ''} • ${item['assunto'] ?? ''} • ${item['pendentes'] ?? 0} pendentes',
      'planos-ensino' =>
        'Código ${item['codigo'] ?? '—'} • Turma ${item['turma'] ?? '—'} • ${((item['faltando'] as List?) ?? const []).length} campos faltantes',
      'planos-trabalho' =>
        'Nº ${item['numero'] ?? '—'} • ${item['interessado'] ?? item['nomeArvore'] ?? ''}',
      'equivalencia-alunos' =>
        'Matrícula ${item['studentId'] ?? '—'} • ${item['status'] ?? ''} • ${item['blocks'] ?? 0} blocos',
      'progressao' =>
        '${item['movimento'] ?? ''} • ${item['pontos'] ?? '—'} pontos • ${item['lancamentos'] ?? 0} lançamentos',
      _ => '',
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _selectedModuleId = null),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Todos os módulos'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accent.withAlpha(38),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(_moduleIcon(module), color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${module['category'] ?? 'MÓDULO'}'.toUpperCase(),
                    style: TextStyle(
                      color: accent,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                  Text(
                    '${module['title']}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Atualizar dados do Windows',
              onPressed: _moduleWorkspaceLoading
                  ? null
                  : () => _loadModuleWorkspace(moduleId),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.dashboard_outlined),
              label: Text('Visão geral'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.tune_rounded),
              label: Text('Ações'),
            ),
          ],
          selected: {_moduleActionsTab},
          onSelectionChanged: (selection) =>
              setState(() => _moduleActionsTab = selection.first),
        ),
        if (_moduleWorkspaceLoading)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: LinearProgressIndicator(),
          ),
        if (_moduleWorkspaceError != null)
          Card(
            color: const Color(0xff492d36),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_moduleWorkspaceError!),
            ),
          ),
        if (!_moduleActionsTab) ...[
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: command(primary) == null
                  ? null
                  : () => _runCommand(command(primary)!, initial: primaryInput),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.add_circle_outline_rounded,
                      color: accent,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _primaryActionLabel(moduleId),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            _primaryActionHint(moduleId),
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: accent),
                  ],
                ),
              ),
            ),
          ),
          if (moduleId == 'diario') ...[
            const SizedBox(height: 10),
            _summaryCard(
              Icons.calendar_month_rounded,
              '${data['periodo'] ?? '—'}',
              'Período letivo',
            ),
            _summaryCard(
              Icons.edit_note_rounded,
              '${data['rascunho'] ?? 0}',
              'Aulas no rascunho',
            ),
          ],
          if (moduleId == 'ajusta-horarios') ...[
            const SizedBox(height: 10),
            _summaryCard(
              Icons.calendar_month_rounded,
              '${data['periodoLetivo'] ?? '—'}',
              'Período letivo',
            ),
            _summaryCard(
              Icons.menu_book_rounded,
              '${data['disciplinas'] ?? 0}',
              'Disciplinas na grade',
            ),
            _summaryCard(
              Icons.groups_rounded,
              '${(data['docentes'] as List? ?? const []).length}',
              'Docentes',
            ),
            _summaryCard(
              Icons.meeting_room_rounded,
              '${(data['salas'] as List? ?? const []).length}',
              'Salas',
            ),
            if (data['cursos'] is Map) ...[
              const SizedBox(height: 12),
              const Text(
                'Cursos',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              for (final item in (data['cursos'] as Map).entries)
                Card(
                  child: ListTile(
                    leading: Icon(Icons.school_outlined, color: accent),
                    title: Text('${item.value}'),
                    subtitle: Text('Código ${item.key}'),
                  ),
                ),
            ],
          ],
          if (moduleId == 'equivalencia-alunos') ...[
            const SizedBox(height: 10),
            _summaryCard(
              Icons.school_outlined,
              '${(data['curricula'] as List? ?? const []).length}',
              'Currículos',
            ),
            for (final curriculum in data['curricula'] as List? ?? const [])
              Card(
                child: ListTile(
                  leading: Icon(Icons.menu_book_rounded, color: accent),
                  title: Text('${(curriculum as Map)['course']}'),
                  subtitle: Text(
                    '${curriculum['name']} • ${curriculum['subjects']} disciplinas',
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  recordTitle,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${records.length}',
                style: TextStyle(color: accent, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (records.isEmpty &&
              !_moduleWorkspaceLoading &&
              moduleId != 'ajusta-horarios')
            Card(
              child: ListTile(
                leading: Icon(Icons.inbox_outlined, color: accent),
                title: const Text('Nenhum registro salvo ainda'),
                subtitle: const Text('Use a ação principal para começar.'),
              ),
            ),
          for (final record in records)
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: Icon(_workspaceRecordIcon(moduleId), color: accent),
                title: Text(
                  titleFor(record),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: subtitleFor(record).trim().isEmpty
                    ? null
                    : Text(
                        subtitleFor(record),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () =>
                    _showWorkspaceRecordActions(moduleId, record, commands),
              ),
            ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => setState(() => _moduleActionsTab = true),
            icon: const Icon(Icons.view_list_rounded),
            label: Text('Ver todas as ${commands.length} ações do módulo'),
          ),
        ] else ...[
          const SizedBox(height: 14),
          Text(
            '${module['description']}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          for (var index = 0; index < groups.length; index++)
            Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: index == 0,
                leading: Icon(groups[index].icon, color: accent),
                title: Text(
                  groups[index].title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text('${groups[index].commands.length} ações'),
                children: [
                  for (final item in groups[index].commands)
                    ListTile(
                      leading: Icon(
                        item['requiresConfirmation'] == true
                            ? Icons.verified_user_outlined
                            : Icons.play_arrow_rounded,
                        color: accent,
                      ),
                      title: Text('${item['title']}'),
                      subtitle: Text(
                        '${item['description'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _runCommand(item),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  String _primaryActionLabel(String moduleId) => switch (moduleId) {
    'audita-bancas' => 'Abrir PDF para revisar',
    'diario' => 'Importar planilha de aulas',
    'elabora-relato' => 'Criar processo de parecer',
    'planos-ensino' => 'Novo plano de ensino',
    'planos-trabalho' => 'Cadastrar plano de trabalho',
    'ajusta-horarios' => 'Importar grade de horários',
    'equivalencia-alunos' => 'Importar análise de aluno',
    'progressao' => 'Criar processo de progressão',
    _ => 'Nova operação',
  };

  String _primaryActionHint(String moduleId) => switch (moduleId) {
    'audita-bancas' =>
      'Selecione o arquivo PDF no celular; a análise roda no Windows.',
    'diario' =>
      'Escolha a planilha XLSX de aulas para preparar os lançamentos.',
    'elabora-relato' =>
      'Abra um novo fluxo de relatório, fundamentação e conclusão.',
    'planos-ensino' => 'Preencha e organize os dados do plano.',
    'planos-trabalho' => 'Cadastre os dados e documentos do plano.',
    'ajusta-horarios' =>
      'Envie a planilha da grade para o computador processar.',
    'equivalencia-alunos' => 'Selecione a planilha com os dados do estudante.',
    'progressao' => 'Comece a reunir atividades, pontos e comprovantes.',
    _ => '',
  };

  IconData _workspaceRecordIcon(String moduleId) => switch (moduleId) {
    'audita-bancas' => Icons.picture_as_pdf_rounded,
    'diario' => Icons.edit_calendar_rounded,
    'elabora-relato' => Icons.description_outlined,
    'planos-ensino' => Icons.menu_book_rounded,
    'planos-trabalho' => Icons.assignment_outlined,
    'equivalencia-alunos' => Icons.compare_arrows_rounded,
    'progressao' => Icons.trending_up_rounded,
    _ => Icons.folder_outlined,
  };

  Future<void> _showWorkspaceRecordActions(
    String moduleId,
    Map<String, dynamic> record,
    List<Map<String, dynamic>> commands,
  ) async {
    final id = '${record['id'] ?? ''}';
    final options = <(String, String, Map<String, dynamic>)>[];
    void add(String commandId, String title, Map<String, dynamic> input) {
      if (commands.any((item) => item['id'] == commandId)) {
        options.add((commandId, title, input));
      }
    }

    switch (moduleId) {
      case 'audita-bancas':
        add('auditaBancas.analisar', 'Analisar com IA', {'documento': id});
        add('auditaBancas.observacoes', 'Ver observações', {'documento': id});
        add('auditaBancas.exportarRelatorio', 'Exportar relatório', {
          'documento': id,
        });
        add('auditaBancas.exportarPdf', 'Exportar PDF anotado', {
          'documento': id,
        });
        break;
      case 'diario':
        add('diario.listar', 'Ver lançamentos', {
          'periodo': '${_moduleWorkspaceData?['periodo'] ?? ''}',
          'lancamentos': true,
        });
        add('diario.salvarJson', 'Exportar lançamentos', {
          'periodo': '${_moduleWorkspaceData?['periodo'] ?? ''}',
        });
        break;
      case 'elabora-relato':
        add('parecer.processos.abrir', 'Abrir este processo', {'id': id});
        break;
      case 'planos-ensino':
        add('planosEnsino.listar', 'Ver dados do plano', {'id': id});
        add('planosEnsino.exportarWord', 'Exportar Word', {'id': id});
        add('planosEnsino.inserirNoSei', 'Inserir no SEI', {'id': id});
        break;
      case 'planos-trabalho':
        add('planosTrabalho.listar', 'Ver dados do plano', {'id': id});
        add('planosTrabalho.abrirSei', 'Abrir processo no SEI', {'id': id});
        break;
      case 'equivalencia-alunos':
        add('equivalencia.gerarCertidao', 'Gerar certidão PDF', {'caseId': id});
        break;
      case 'progressao':
        add('progressao.listar', 'Ver lançamentos', {'processoId': id});
        add('progressao.gerarPdf', 'Gerar requerimento e relatório', {
          'processoId': id,
        });
        break;
    }

    if (options.isEmpty) {
      await _runCommand(
        commands.firstWhere(
          (item) => item['id'].toString().endsWith('.listar'),
        ),
      );
      return;
    }
    final selected = await showModalBottomSheet<(String, Map<String, dynamic>)>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                '${record['nome'] ?? record['student'] ?? record['docente'] ?? record['periodo'] ?? 'Opções'}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final option in options)
              ListTile(
                leading: const Icon(Icons.arrow_forward_rounded),
                title: Text(option.$2),
                onTap: () =>
                    Navigator.pop(sheetContext, (option.$1, option.$3)),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    final item = commands.firstWhere((value) => value['id'] == selected.$1);
    await _runCommand(item, initial: selected.$2);
  }

  Widget _buildModuleDetail(Map<String, dynamic> module) {
    if (module['id'] == 'moodle') return _buildMoodleHome(module);
    if (module['id'] == 'agenda-email') return _buildAgendaHome(module);
    if (_hasOperationalWorkspace('${module['id']}')) {
      return _buildOperationalWorkspace(module);
    }
    final commands = (module['commands'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final accent = _moduleAccent(module);
    final enabled = module['enabled'] == true;
    final sections = _groupModuleCommands('${module['id']}', commands);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _selectedModuleId = null),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Todos os módulos'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: accent.withAlpha(40),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(_moduleIcon(module), color: accent, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${module['category'] ?? 'MÓDULO'}'.toUpperCase(),
                    style: TextStyle(
                      color: accent,
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${module['title']}',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${module['description']}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'AÇÕES',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 11,
            letterSpacing: 1.3,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        if (!enabled)
          _emptyState(
            Icons.lock_outline_rounded,
            'Disponível em breve',
            'Este módulo ainda não está habilitado neste computador.',
          )
        else if (commands.isEmpty)
          _emptyState(
            Icons.info_outline_rounded,
            'Sem ações remotas',
            'As ações deste módulo ainda não estão disponíveis pelo celular.',
          )
        else ...[
          const SizedBox(height: 8),
          Text(
            'As funções estão agrupadas pelas etapas que você já conhece no computador.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < sections.length; index++)
            Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: index == 0,
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: accent.withAlpha(35),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(sections[index].icon, color: accent, size: 20),
                ),
                title: Text(
                  sections[index].title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${sections[index].commands.length} ${sections[index].commands.length == 1 ? 'função' : 'funções'}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                children: [
                  for (final command in sections[index].commands)
                    ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(20, 0, 14, 4),
                      title: Text(
                        '${command['title']}',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle:
                          command['description'] == null ||
                              '${command['description']}'.isEmpty
                          ? null
                          : Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${command['description']}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                      trailing: Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: accent,
                        size: 16,
                      ),
                      onTap: () => _runCommand(command),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  List<_ModuleActionSection> _groupModuleCommands(
    String moduleId,
    List<Map<String, dynamic>> commands,
  ) {
    final groups = <String, _ModuleActionSection>{};
    for (final command in commands) {
      final id = '${command['id']}';
      final (title, icon) = switch (moduleId) {
        'moodle' =>
          id.contains('Periodo')
              ? ('Período letivo', Icons.calendar_month_rounded)
              : id.contains('Planilha') || id.contains('exportar')
              ? ('Importar e exportar', Icons.import_export_rounded)
              : id.contains('sincron')
              ? ('Sincronização com Moodle', Icons.sync_rounded)
              : ('Configurações de disciplinas', Icons.menu_book_rounded),
        'progressao' =>
          id.contains('Lancamento') ||
                  id.contains('lancar') ||
                  id.contains('Anexo1')
              ? ('Atividades e pontuação', Icons.checklist_rounded)
              : id.toLowerCase().contains('sei')
              ? ('Processo no SEI', Icons.account_tree_rounded)
              : id.contains('Pdf') || id.contains('Comprovante')
              ? ('Requerimento e comprovantes', Icons.picture_as_pdf_rounded)
              : ('Processos de progressão', Icons.trending_up_rounded),
        'diario' =>
          id.contains('Portal')
              ? ('Preencher no Portal do Docente', Icons.public_rounded)
              : id.contains('importar') || id.contains('Json')
              ? ('Importar e exportar aulas', Icons.import_export_rounded)
              : ('Períodos e lançamentos', Icons.edit_calendar_rounded),
        'planos-ensino' =>
          id.toLowerCase().contains('sei')
              ? ('Enviar ao SEI', Icons.account_tree_rounded)
              : id.contains('Cronograma')
              ? ('Cronograma', Icons.event_note_rounded)
              : id.contains('importar') || id.contains('exportar')
              ? ('Importar e exportar', Icons.import_export_rounded)
              : ('Planos de ensino', Icons.menu_book_rounded),
        'elabora-relato' =>
          id.startsWith('parecer.processos')
              ? ('Processos de parecer', Icons.folder_open_rounded)
              : id.contains('comentarios')
              ? ('Comentários e anotações', Icons.comment_rounded)
              : id.contains('anexos')
              ? ('Documentos anexados', Icons.attach_file_rounded)
              : id.contains('.base.')
              ? ('Base de documentos', Icons.library_books_rounded)
              : id.contains('Sei') || id.contains('verificar')
              ? ('Revisar e inserir no SEI', Icons.account_tree_rounded)
              : id.startsWith('relato.')
              ? ('Árvore e documentos do processo', Icons.account_tree_rounded)
              : ('Rascunho do parecer', Icons.edit_note_rounded),
        _ => _fallbackActionSection(id, '${command['title']}'),
      };
      final section = groups.putIfAbsent(
        title,
        () => _ModuleActionSection(title: title, icon: icon, commands: []),
      );
      section.commands.add(command);
    }
    return groups.values.toList();
  }

  (String, IconData) _fallbackActionSection(String id, String title) {
    final lower = '$id $title'.toLowerCase();
    if (lower.contains('import') || lower.contains('export')) {
      return ('Importar e exportar', Icons.import_export_rounded);
    }
    if (lower.contains('sei') ||
        lower.contains('portal') ||
        lower.contains('moodle')) {
      return ('Integrações', Icons.hub_rounded);
    }
    if (lower.contains('excluir') || lower.contains('remover')) {
      return ('Gerenciar dados', Icons.settings_rounded);
    }
    return ('Funções do módulo', Icons.grid_view_rounded);
  }

  Widget _taskCard(Map<String, dynamic> task) {
    final progress = (task['progress'] as num?)?.toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_rounded, color: Color(0xff00d4ff)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${task['title']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              '${task['stage'] ?? task['status'] ?? 'Em andamento'}',
              style: const TextStyle(color: Color(0xff9ea2c4), fontSize: 12),
            ),
            const SizedBox(height: 11),
            LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(5),
            ),
            if (progress != null) ...[
              const SizedBox(height: 5),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(color: Color(0xff9ea2c4), fontSize: 11),
              ),
            ],
            if (task['cancelSupported'] == true && task['status'] == 'running')
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    try {
                      await _api!.cancelTask('${task['id']}');
                    } catch (error) {
                      if (mounted) setState(() => _error = '$error');
                    }
                  },
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Cancelar operação'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _taskStatusLabel(String status) => switch (status) {
    'succeeded' => 'Concluída',
    'failed' => 'Falhou',
    'cancelled' => 'Cancelada',
    'interrupted' => 'Interrompida',
    _ => status,
  };

  Color _taskStatusColor(String status) => switch (status) {
    'succeeded' => const Color(0xff00e676),
    'failed' => const Color(0xffff5252),
    'cancelled' || 'interrupted' => const Color(0xffffab00),
    _ => const Color(0xff9ea2c4),
  };

  String _taskDate(Map<String, dynamic> task) {
    final date = DateTime.tryParse('${task['updatedAt']}')?.toLocal();
    if (date == null) return '';
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${twoDigits(date.day)}/${twoDigits(date.month)}/${date.year} ${twoDigits(date.hour)}:${twoDigits(date.minute)}';
  }

  Widget _taskHistoryCard(Map<String, dynamic> task) {
    final status = '${task['status']}';
    final result = Map<String, dynamic>.from(
      task['result'] as Map? ?? const {},
    );
    final message = '${result['message'] ?? ''}'.trim();
    final details = Map<String, dynamic>.from(result)
      ..remove('ok')
      ..remove('message')
      ..remove('artifacts');
    final artifacts = (result['artifacts'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final color = _taskStatusColor(status);
    final date = _taskDate(task);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(
          status == 'succeeded'
              ? Icons.check_circle_outline_rounded
              : status == 'failed'
              ? Icons.error_outline_rounded
              : Icons.info_outline_rounded,
          color: color,
        ),
        title: Text('${task['title']}'),
        subtitle: Text(
          '${_taskStatusLabel(status)}${date.isEmpty ? '' : ' · $date'}',
          style: TextStyle(color: color, fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.isNotEmpty) ...[const Divider(height: 12), Text(message)],
          if (details.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(const JsonEncoder.withIndent('  ').convert(details)),
          ],
          for (final artifact in artifacts)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _downloadArtifact(artifact),
                icon: const Icon(Icons.download_rounded),
                label: Text('Baixar ${artifact['name']}'),
              ),
            ),
          if (message.isEmpty && details.isEmpty && artifacts.isEmpty)
            const Text('Esta operação não retornou detalhes adicionais.'),
        ],
      ),
    );
  }

  Widget _buildTasks() => ListView(
    padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
    children: [
      const Text(
        'OPERAÇÕES NO COMPUTADOR',
        style: TextStyle(
          color: Color(0xff9ea2c4),
          fontSize: 11,
          letterSpacing: 1.3,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Tarefas',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 18),
      if (_approvals.isNotEmpty) ...[
        const Text(
          'PRECISAM DA SUA CONFIRMAÇÃO',
          style: TextStyle(
            color: Color(0xffffab00),
            fontSize: 11,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (final item in _approvals)
          Card(
            color: const Color(0xff382c18),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${item['tool']}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text('${item['input']}'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => _answerApproval(item, false),
                        child: const Text('Recusar'),
                      ),
                      FilledButton(
                        onPressed: () => _answerApproval(item, true),
                        child: const Text('Autorizar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 14),
      ],
      if (_activeTasks.isEmpty)
        _emptyState(
          Icons.task_alt_rounded,
          'Nenhuma tarefa em andamento',
          'Quando você iniciar uma operação, o progresso aparecerá aqui.',
        )
      else ...[
        Text(
          'EM ANDAMENTO · ${_activeTasks.length}',
          style: const TextStyle(
            color: Color(0xff00d4ff),
            fontSize: 11,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (final task in _activeTasks.values) _taskCard(task),
      ],
      if (_taskHistory.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text(
          'HISTÓRICO RECENTE · ${_taskHistory.length}',
          style: const TextStyle(
            color: Color(0xff9ea2c4),
            fontSize: 11,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        for (final task in _taskHistory) _taskHistoryCard(task),
      ],
    ],
  );

  Future<void> _openRemotePowerShell() async {
    if (_terminalConnecting || _terminalSocket?.readyState == WebSocket.open) {
      return;
    }
    final api = _api;
    if (api == null || !_connected) {
      setState(
        () => _terminalError = 'Conecte ao computador Windows primeiro.',
      );
      return;
    }
    setState(() {
      _terminalConnecting = true;
      _terminalError = null;
    });
    try {
      final socket = await api.openPowerShell();
      if (!mounted) {
        await socket.close();
        return;
      }
      _terminalSocket = socket;
      socket.listen(
        (raw) {
          try {
            final message = Map<String, dynamic>.from(
              jsonDecode('$raw') as Map,
            );
            switch (message['type']) {
              case 'output':
                _remoteTerminal.write('${message['data'] ?? ''}');
              case 'error':
                if (mounted)
                  setState(() => _terminalError = '${message['message']}');
              case 'closed':
                if (mounted) {
                  setState(() {
                    _terminalSocket = null;
                    _terminalError =
                        'PowerShell encerrou: ${message['status'] ?? ''}';
                  });
                }
            }
          } catch (_) {}
        },
        onDone: () {
          if (mounted && identical(_terminalSocket, socket)) {
            setState(() {
              _terminalSocket = null;
              _terminalError ??= 'Conexão do PowerShell interrompida.';
            });
          }
        },
        onError: (Object error) {
          if (mounted) setState(() => _terminalError = 'PowerShell: $error');
        },
      );
    } catch (error) {
      if (mounted) setState(() => _terminalError = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _terminalConnecting = false);
    }
  }

  Future<void> _detachRemotePowerShell() async {
    final socket = _terminalSocket;
    _terminalSocket = null;
    await socket?.close();
  }

  Widget _buildRemotePowerShell() => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.terminal_rounded),
              const SizedBox(width: 8),
              const Expanded(child: Text('PowerShell do computador Windows')),
              Icon(
                _terminalSocket?.readyState == WebSocket.open
                    ? Icons.circle
                    : Icons.circle_outlined,
                size: 12,
                color: _terminalSocket?.readyState == WebSocket.open
                    ? Colors.green
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              IconButton(
                tooltip: _terminalSocket?.readyState == WebSocket.open
                    ? 'Desconectar terminal'
                    : 'Conectar ao PowerShell',
                onPressed: _terminalConnecting
                    ? null
                    : _terminalSocket?.readyState == WebSocket.open
                    ? _detachRemotePowerShell
                    : _openRemotePowerShell,
                icon: Icon(
                  _terminalSocket?.readyState == WebSocket.open
                      ? Icons.link_off_rounded
                      : Icons.link_rounded,
                ),
              ),
            ],
          ),
        ),
      ),
      if (_terminalError != null)
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            dense: true,
            title: Text(_terminalError!),
            trailing: IconButton(
              onPressed: () => setState(() => _terminalError = null),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ),
      Expanded(
        child: TerminalView(
          _remoteTerminal,
          controller: _remoteTerminalController,
          theme: TerminalThemes.whiteOnBlack,
          autofocus: true,
          keyboardType: TextInputType.multiline,
        ),
      ),
      if (_terminalConnecting) const LinearProgressIndicator(minHeight: 2),
    ],
  );

  Widget _buildAgent() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
    children: [
      if (_messages.isEmpty)
        Padding(
          padding: EdgeInsets.only(top: 12, bottom: 18),
          child: Text(
            'Converse com o Agente por texto ou voz. A transcrição é feita no celular quando há reconhecimento offline em português.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ),
      for (final message in _messages)
        Align(
          alignment: message.role == 'user'
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.all(13),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: message.role == 'user'
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  message.text,
                  style: TextStyle(
                    color: message.role == 'user'
                        ? Theme.of(context).colorScheme.onPrimaryContainer
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                for (final artifact in message.artifacts)
                  TextButton.icon(
                    onPressed: () => _downloadArtifact(artifact),
                    icon: const Icon(Icons.download_rounded),
                    label: Text('Baixar ${artifact['name']}'),
                  ),
              ],
            ),
          ),
        ),
      if (_assistantDraft.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(_assistantDraft),
          ),
        ),
    ],
  );

  Widget _agentComposer() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              hintText: _listening
                  ? 'Ouvindo… fale sua solicitação'
                  : 'Peça algo ao Agente…',
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Text(
                  _listening
                      ? 'Ouvindo…'
                      : _sending
                      ? 'Agente trabalhando no computador…'
                      : (_agentProviderLabel ?? 'Agente no computador'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _listening
                        ? const Color(0xffff5252)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                onPressed: _connected && !_sending ? _toggleMic : null,
                tooltip: _listening
                    ? 'Parar e enviar transcrição'
                    : 'Falar com o Agente',
                icon: Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                visualDensity: VisualDensity.compact,
                onPressed: _sending ? _cancelAgentMessage : () => _send(),
                tooltip: _sending ? 'Interromper o agente' : 'Enviar',
                icon: Icon(
                  _sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: _selectedModuleId == null
          ? Padding(
              padding: const EdgeInsets.all(11),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xff6c63ff), Color(0xff3d5afe)],
                  ),
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            )
          : IconButton(
              onPressed: () => setState(() => _selectedModuleId = null),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
      title: _selectedTab == 3
          ? Row(
              children: [
                const Text(
                  'Agente',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 3),
                Flexible(
                  child: PopupMenuButton<String>(
                    enabled: _connected && !_sending,
                    tooltip: 'Escolher agente no computador',
                    onSelected: _selectRemoteProvider,
                    itemBuilder: (context) => [
                      for (final provider in _agentProviders)
                        PopupMenuItem<String>(
                          value: '${provider['id']}',
                          child: Text('${provider['label']}'),
                        ),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(
                            _agentProviderShortLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_drop_down_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _pageTitle,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_selectedModuleId == null)
                  const Text(
                    'CENTRAL DE UTILIDADES',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.2,
                      color: Color(0xff9ea2c4),
                    ),
                  ),
              ],
            ),
      actions: [
        IconButton(
          onPressed: _chooseTheme,
          tooltip:
              'Aparência: tema ${widget.themeMode == ThemeMode.dark ? 'escuro' : 'claro'}',
          icon: Icon(
            widget.themeMode == ThemeMode.dark
                ? Icons.dark_mode_rounded
                : Icons.light_mode_rounded,
          ),
        ),
        IconButton(
          onPressed: () async {
            final enabled = !_speakResponses;
            setState(() => _speakResponses = enabled);
            const vault = FlutterSecureStorage();
            await vault.write(
              key: 'remote.speakResponses',
              value: enabled.toString(),
            );
            if (!_speakResponses) unawaited(_stopSpeaking());
          },
          tooltip: _speakResponses
              ? 'Desativar respostas em áudio'
              : 'Ativar respostas em áudio',
          icon: Icon(
            _speakResponses
                ? Icons.volume_up_rounded
                : Icons.volume_off_rounded,
          ),
        ),
        if (_selectedTab == 3)
          PopupMenuButton<String>(
            tooltip: 'Conexão com o computador',
            onSelected: (value) {
              if (value == 'settings') {
                _configure();
              } else if (!_connecting) {
                _connect();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'retry',
                child: Text(
                  _connected
                      ? 'Computador conectado'
                      : 'Conectar ao computador',
                ),
              ),
              const PopupMenuItem<String>(
                value: 'settings',
                child: Text('Configuração da conexão'),
              ),
            ],
            icon: Icon(
              _connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
              color: _connected
                  ? const Color(0xff00e676)
                  : const Color(0xffffab00),
            ),
          )
        else ...[
          IconButton(
            onPressed: _connecting ? null : _connect,
            tooltip: _connected ? 'Computador conectado' : 'Tentar conectar',
            icon: Icon(
              _connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
              color: _connected
                  ? const Color(0xff00e676)
                  : const Color(0xffffab00),
            ),
          ),
          IconButton(
            onPressed: _configure,
            tooltip: 'Conexão',
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
        const SizedBox(width: 4),
      ],
    ),
    body: Column(
      children: [
        if (_connecting) const LinearProgressIndicator(minHeight: 2),
        if (!_connected || _error != null)
          Material(
            color: const Color(0xff382c18),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: Color(0xffffab00),
                    size: 19,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      _error ??
                          'Conecte ao computador Windows pelo FortiClient.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (!_connected)
                    IconButton(
                      onPressed: _connecting ? null : _connect,
                      icon: const Icon(Icons.refresh_rounded),
                      tooltip: 'Tentar novamente',
                    ),
                ],
              ),
            ),
          ),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
            child: switch (_selectedTab) {
              0 => _buildHome(),
              1 => _buildModules(),
              2 => _buildTasks(),
              4 => _buildRemotePowerShell(),
              _ => _buildAgent(),
            },
          ),
        ),
        if (_selectedTab == 3) _agentComposer(),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedTab,
      onDestinationSelected: (index) {
        setState(() {
          _selectedTab = index;
          _selectedModuleId = null;
        });
        if (index == 4) {
          unawaited(_openRemotePowerShell());
        } else {
          unawaited(_detachRemotePowerShell());
        }
      },
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: 'Início',
        ),
        const NavigationDestination(
          icon: Icon(Icons.apps_outlined),
          selectedIcon: Icon(Icons.apps_rounded),
          label: 'Módulos',
        ),
        NavigationDestination(
          icon: Badge(
            isLabelVisible: _activeTasks.isNotEmpty,
            label: Text('${_activeTasks.length}'),
            child: const Icon(Icons.sync_outlined),
          ),
          selectedIcon: Badge(
            isLabelVisible: _activeTasks.isNotEmpty,
            label: Text('${_activeTasks.length}'),
            child: const Icon(Icons.sync_rounded),
          ),
          label: 'Tarefas',
        ),
        const NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          selectedIcon: Icon(Icons.auto_awesome_rounded),
          label: 'Agente',
        ),
        const NavigationDestination(
          icon: Icon(Icons.terminal_outlined),
          selectedIcon: Icon(Icons.terminal_rounded),
          label: 'PowerShell',
        ),
      ],
    ),
  );
}

class _ChatMessage {
  const _ChatMessage(this.role, this.text, {this.artifacts = const []});
  final String role;
  final String text;
  final List<Map<String, dynamic>> artifacts;
}

class _ModuleActionSection {
  _ModuleActionSection({
    required this.title,
    required this.icon,
    required this.commands,
  });

  final String title;
  final IconData icon;
  final List<Map<String, dynamic>> commands;
}
