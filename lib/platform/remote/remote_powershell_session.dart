import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pty2/flutter_pty2.dart';

import 'package:gestor_ufu/platform/services/gestor_process_environment.dart';

/// Interactive PowerShell session shared with an authenticated mobile client.
/// It accepts terminal keystrokes only over the existing pinned HTTPS service.
class RemotePowerShellSession {
  PtySession? _session;
  WebSocket? _socket;
  StreamSubscription<String>? _output;
  String _workingDirectory = '';
  String _scrollback = '';
  static const _scrollbackLimit = 160000;

  bool get running => _session != null;

  Future<void> attach(WebSocket socket, String sourceAddress) async {
    await _ensureSession();
    final previous = _socket;
    _socket = socket;
    if (previous != null && !identical(previous, socket)) {
      await previous.close(
        WebSocketStatus.goingAway,
        'Substituída por nova sessão.',
      );
    }
    await _log('conectou $sourceAddress');
    if (_scrollback.isNotEmpty) _send({'type': 'output', 'data': _scrollback});
    socket.listen(
      _handleMessage,
      onDone: () {
        if (identical(_socket, socket)) _socket = null;
        unawaited(_log('desconectou $sourceAddress'));
      },
      onError: (_) {
        if (identical(_socket, socket)) _socket = null;
        unawaited(_log('conexão interrompida $sourceAddress'));
      },
      cancelOnError: true,
    );
  }

  Future<void> _ensureSession() async {
    if (_session != null) return;
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'O PowerShell remoto está disponível somente no Windows.',
      );
    }
    _workingDirectory = await GestorProcessEnvironment.workspaceDirectory();
    final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final session = await Pty.spawn(
      PtySpawnOptions(
        executable:
            '$windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        arguments: const [
          '-NoLogo',
          '-NoExit',
          '-Command',
          r'$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
        ],
        workingDirectory: _workingDirectory,
        environment: PtyEnvironment.inherit(
          overrides: GestorProcessEnvironment.variablesFor(_workingDirectory),
        ),
        size: const PtySize(columns: 100, rows: 30),
      ),
    );
    _session = session;
    _scrollback = '';
    _output = session.utf8Output().listen(
      (chunk) {
        _scrollback += chunk;
        if (_scrollback.length > _scrollbackLimit) {
          _scrollback = _scrollback.substring(
            _scrollback.length - _scrollbackLimit,
          );
        }
        _send({'type': 'output', 'data': chunk});
      },
      onError: (Object error) {
        _send({'type': 'error', 'message': '$error'});
      },
    );
    unawaited(
      session.done.then((exit) {
        _send({'type': 'closed', 'status': '$exit'});
        if (identical(_session, session)) _session = null;
      }),
    );
    await _log('iniciou PowerShell em $_workingDirectory');
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String || raw.length > 32768) return;
    Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return;
    }
    switch (message['type']) {
      case 'input':
        final data = message['data'];
        if (data is String && data.length <= 16000) {
          unawaited(_session?.input.writeUtf8(data));
        }
      case 'resize':
        final columns = message['columns'];
        final rows = message['rows'];
        if (columns is int &&
            rows is int &&
            columns >= 10 &&
            columns <= 300 &&
            rows >= 5 &&
            rows <= 150) {
          _session?.resize(PtySize(columns: columns, rows: rows));
        }
    }
  }

  void _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(message));
    } catch (_) {}
  }

  Future<void> _log(String event) async {
    try {
      final dir = Directory(GestorProcessEnvironment.gestorHome);
      await dir.create(recursive: true);
      await File(
        '${dir.path}${Platform.pathSeparator}remote-powershell.log',
      ).writeAsString(
        '${DateTime.now().toUtc().toIso8601String()} $event\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(
          WebSocketStatus.goingAway,
          'Serviço remoto encerrado.',
        );
      } catch (_) {}
    }
    await _output?.cancel();
    _output = null;
    final session = _session;
    _session = null;
    if (session != null) {
      session.kill();
      await session.close();
    }
  }
}
