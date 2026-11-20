import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

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
};
const _speechOutput = MethodChannel('br.ufu.gestor.mobile/tts');

void main() => runApp(const GestorRemoteApp());

class GestorRemoteApp extends StatelessWidget {
  const GestorRemoteApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Gestor UFU Remoto',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff0f1123),
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xff6c63ff),
            brightness: Brightness.dark,
          ).copyWith(
            primary: const Color(0xff6c63ff),
            secondary: const Color(0xff00d4ff),
            surface: const Color(0xff1e2045),
          ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff0f1123),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xff1e2045),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xff171932),
        indicatorColor: const Color(0xff6c63ff).withAlpha(60),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? Colors.white
                : const Color(0xff9ea2c4),
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
    ),
    home: const RemoteHomePage(),
  );
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});
  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage>
    with WidgetsBindingObserver {
  final _speech = stt.SpeechToText();
  final _input = TextEditingController();
  final _messages = <_ChatMessage>[];
  List<Map<String, dynamic>> _modules = [];
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
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
    } catch (e) {
      final staleSocket = _socket;
      _socket = null;
      await staleSocket?.close();
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
    await _stopSpeaking();
    setState(() {
      _sending = true;
      _input.clear();
      _messages.add(_ChatMessage('user', text));
      _error = null;
    });
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
    Map<String, dynamic> command,
  ) async {
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
        text: '${spec['default'] ?? ''}',
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

  Future<void> _runCommand(Map<String, dynamic> command) async {
    if (!_connected) return;
    final input = await _parameters(command);
    if (input == null) return;
    try {
      var task = await _api!.runCommand(
        '${command['id']}',
        input,
        confirmed: true,
      );
      if (mounted)
        setState(
          () => _messages.add(
            _ChatMessage('system', 'Tarefa iniciada: ${task['title']}'),
          ),
        );
      while (mounted &&
          !{
            'succeeded',
            'failed',
            'cancelled',
            'interrupted',
          }.contains(task['status'])) {
        await Future<void>.delayed(const Duration(seconds: 2));
        task = await _api!.task('${task['id']}');
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
          _ChatMessage('system', _taskSummary(task), artifacts: artifacts),
        );
      });
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
    super.dispose();
  }

  String get _pageTitle {
    final modules = _modules.where((item) => item['id'] == _selectedModuleId);
    if (modules.isNotEmpty) return '${modules.first['title']}';
    return switch (_selectedTab) {
      0 => 'Início',
      1 => 'Módulos',
      2 => 'Tarefas',
      _ => 'Agente',
    };
  }

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
    });
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
                  style: const TextStyle(
                    color: Color(0xff9ea2c4),
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
                    color: enabled ? accent : Colors.white38,
                    size: 19,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '${module['category'] ?? 'MÓDULO'}'.toUpperCase(),
                style: TextStyle(
                  color: enabled ? accent : Colors.white54,
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
                style: const TextStyle(
                  color: Color(0xff9ea2c4),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 13),
              Text(
                enabled ? 'Acessar módulo' : 'Disponível em breve',
                style: TextStyle(
                  color: enabled ? accent : Colors.white54,
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
              style: const TextStyle(
                color: Color(0xff9ea2c4),
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
      const Text(
        'CENTRAL DE UTILIDADES',
        style: TextStyle(
          color: Color(0xff9ea2c4),
          fontSize: 11,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 7),
      const Text(
        'Gestor UFU',
        style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 5),
      const Text(
        'Acesse pelo celular as ferramentas que você já usa no Windows.',
        style: TextStyle(color: Color(0xff9ea2c4), height: 1.4),
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

  Widget _buildModuleDetail(Map<String, dynamic> module) {
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
          style: const TextStyle(color: Color(0xff9ea2c4), height: 1.45),
        ),
        const SizedBox(height: 22),
        const Text(
          'AÇÕES',
          style: TextStyle(
            color: Color(0xff9ea2c4),
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
          const Text(
            'As funções estão agrupadas pelas etapas que você já conhece no computador.',
            style: TextStyle(color: Color(0xff9ea2c4), height: 1.4),
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
                  style: const TextStyle(color: Color(0xff9ea2c4)),
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

  Widget _buildAgent() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
    children: [
      if (_messages.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 18),
          child: Text(
            'Converse com o Agente por texto ou voz. A transcrição é feita no celular quando há reconhecimento offline em português.',
            style: TextStyle(color: Color(0xff9ea2c4), height: 1.45),
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
                  ? const Color(0xff3b3978)
                  : const Color(0xff1e2045),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(message.text),
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
              color: const Color(0xff1e2045),
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
      decoration: const BoxDecoration(
        color: Color(0xff171932),
        border: Border(top: BorderSide(color: Color(0xff2a2d52))),
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
              fillColor: const Color(0xff151730),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                onPressed: _sending ? _cancelAgentMessage : () => _send(),
                tooltip: _sending ? 'Interromper o agente' : 'Enviar',
                icon: Icon(
                  _sending ? Icons.stop_circle_outlined : Icons.send_rounded,
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_listening)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Text(
                    'Ouvindo…',
                    style: TextStyle(
                      color: Color(0xffff5252),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              SizedBox(
                width: 62,
                height: 62,
                child: FloatingActionButton(
                  onPressed: _connected && !_sending ? _toggleMic : null,
                  backgroundColor: _listening ? const Color(0xffff5252) : null,
                  tooltip: _listening
                      ? 'Parar e enviar transcrição'
                      : 'Falar com o Agente',
                  child: Icon(
                    _listening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 29,
                  ),
                ),
              ),
              if (_sending)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
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
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _pageTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
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
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xff0f1123), Color(0xff1a0a33)],
              ),
            ),
            child: switch (_selectedTab) {
              0 => _buildHome(),
              1 => _buildModules(),
              2 => _buildTasks(),
              _ => _buildAgent(),
            },
          ),
        ),
        if (_selectedTab == 3) _agentComposer(),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedTab,
      onDestinationSelected: (index) => setState(() {
        _selectedTab = index;
        _selectedModuleId = null;
      }),
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
