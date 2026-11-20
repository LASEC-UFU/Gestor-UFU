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
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2459b3)),
      useMaterial3: true,
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
  final _shownTaskSummaries = <String>{};
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
        if ({
          'queued',
          'running',
          'cancel_requested',
        }.contains(task['status'])) {
          _activeTasks['${task['id']}'] = task;
        } else {
          _activeTasks.remove('${task['id']}');
        }
      case 'snapshot':
        final tasks = event['tasks'] as List? ?? const [];
        _activeTasks.clear();
        for (final rawTask in tasks) {
          final task = Map<String, dynamic>.from(rawTask as Map);
          if ({
            'running',
            'queued',
            'cancel_requested',
          }.contains(task['status'])) {
            _activeTasks['${task['id']}'] = task;
          } else if (_shownTaskSummaries.add('${task['id']}')) {
            final result = Map<String, dynamic>.from(
              task['result'] as Map? ?? const {},
            );
            final artifacts = (result['artifacts'] as List? ?? const [])
                .map((x) => Map<String, dynamic>.from(x as Map))
                .toList();
            _messages.add(
              _ChatMessage('system', _taskSummary(task), artifacts: artifacts),
            );
          }
        }
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
      _shownTaskSummaries.add('${task['id']}');
      setState(
        () => _messages.add(
          _ChatMessage('system', _taskSummary(task), artifacts: artifacts),
        ),
      );
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Gestor UFU'),
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
        Icon(
          _connected ? Icons.cloud_done : Icons.cloud_off,
          color: _connected ? Colors.green : Colors.red,
        ),
        IconButton(
          onPressed: _configure,
          tooltip: 'Conexão',
          icon: const Icon(Icons.settings_rounded),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_connecting) const LinearProgressIndicator(),
        if (!_connected)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error ?? 'Conecte ao computador Windows pelo FortiClient.',
              style: const TextStyle(color: Colors.red),
            ),
          ),
        if (_approvals.isNotEmpty) ...[
          for (final item in _approvals)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Confirmação necessária: ${item['tool']}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
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
        ],
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            children: [
              for (final task in _activeTasks.values)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${task['title']} • ${task['status']}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (task['stage'] != null) Text('${task['stage']}'),
                        LinearProgressIndicator(
                          value: (task['progress'] as num?)?.toDouble(),
                        ),
                        if (task['cancelSupported'] == true &&
                            task['status'] == 'running')
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () async {
                                try {
                                  await _api!.cancelTask('${task['id']}');
                                } catch (error) {
                                  if (mounted)
                                    setState(() => _error = '$error');
                                }
                              },
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('Cancelar'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              if (_messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    'Fale com o Agente ou abra um módulo. O Android transcreve no aparelho quando há reconhecimento offline em português; o áudio não é enviado ao Gestor nem consome tokens de IA nesta etapa.',
                  ),
                ),
              for (final message in _messages)
                Align(
                  alignment: message.role == 'user'
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxWidth: 560),
                    decoration: BoxDecoration(
                      color: message.role == 'user'
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
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
                            icon: const Icon(Icons.download),
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
                    margin: const EdgeInsets.all(4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(_assistantDraft),
                  ),
                ),
              if (_modules.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 20, bottom: 4),
                  child: Text(
                    'MÓDULOS E AÇÕES',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                for (final module in _modules)
                  if (module['enabled'] == true)
                    ExpansionTile(
                      title: Text('${module['title']}'),
                      subtitle: Text('${module['description']}'),
                      children: [
                        for (final raw
                            in module['commands'] as List? ?? const [])
                          ListTile(
                            title: Text('${(raw as Map)['title']}'),
                            subtitle: Text(
                              '${raw['description']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.play_arrow),
                            onTap: () =>
                                _runCommand(Map<String, dynamic>.from(raw)),
                          ),
                      ],
                    ),
              ],
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: _listening
                    ? 'Ouvindo em português… envia após uma pausa ou ao parar'
                    : 'Peça algo ao Agente…',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: _sending ? _cancelAgentMessage : () => _send(),
                  tooltip: _sending ? 'Interromper o agente' : 'Enviar',
                  icon: Icon(
                    _sending ? Icons.stop_circle_outlined : Icons.send_rounded,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_listening)
                  const Padding(
                    padding: EdgeInsets.only(right: 14),
                    child: Text(
                      'Ouvindo…',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                SizedBox(
                  width: 78,
                  height: 78,
                  child: FloatingActionButton.large(
                    onPressed: _connected && !_sending ? _toggleMic : null,
                    backgroundColor: _listening ? Colors.red : null,
                    tooltip: _listening
                        ? 'Parar e enviar transcrição'
                        : 'Falar com o Agente',
                    child: Icon(
                      _listening ? Icons.stop_rounded : Icons.mic_rounded,
                      size: 34,
                    ),
                  ),
                ),
                if (_sending)
                  const Padding(
                    padding: EdgeInsets.only(left: 14),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChatMessage {
  const _ChatMessage(this.role, this.text, {this.artifacts = const []});
  final String role;
  final String text;
  final List<Map<String, dynamic>> artifacts;
}
