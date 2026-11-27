import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

import 'package:gestor_ufu/platform/services/gestor_process_environment.dart';

/// Terminal interactivo ligado a uma sessão PowerShell real por ConPTY.
class PowerShellConsole extends StatefulWidget {
  const PowerShellConsole({super.key});

  @override
  State<PowerShellConsole> createState() => _PowerShellConsoleState();
}

class _PowerShellConsoleState extends State<PowerShellConsole> {
  final _terminal = Terminal(maxLines: 20000);
  final _terminalController = TerminalController();
  PtySession? _session;
  StreamSubscription<String>? _outputSubscription;
  String _cwd = '';
  String? _error;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _writeToPowerShell;
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _session?.resize(
        PtySize(
          columns: width,
          rows: height,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
        ),
      );
    };
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted) unawaited(_loadWorkspaceAndStart());
    });
  }

  @override
  void dispose() {
    _terminalController.dispose();
    unawaited(_outputSubscription?.cancel());
    final session = _session;
    if (session != null) {
      session.kill();
      unawaited(session.close());
    }
    super.dispose();
  }

  Future<void> _loadWorkspaceAndStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldDirectory = prefs.getString('powershell.initial_directory');
      _cwd = await GestorProcessEnvironment.workspaceDirectory(
        preferred: oldDirectory,
      );
      if (oldDirectory != null && oldDirectory.trim().isNotEmpty) {
        await GestorProcessEnvironment.setWorkspaceDirectory(_cwd);
      }
      await _start();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Não foi possível abrir o workspace: $error');
      }
    }
  }

  String get _powerShellExecutable {
    final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return '$windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  }

  Future<void> _start() async {
    if (!Platform.isWindows) {
      setState(() {
        _starting = false;
        _error =
            'A sessão PowerShell local está disponível somente no Windows.';
      });
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final session = await Pty.spawn(
        PtySpawnOptions(
          executable: _powerShellExecutable,
          arguments: const [
            '-NoLogo',
            '-NoExit',
            '-Command',
            r'$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
          ],
          workingDirectory: _cwd,
          environment: PtyEnvironment.inherit(
            overrides: GestorProcessEnvironment.variablesFor(_cwd),
          ),
          size: PtySize(
            columns: _terminal.viewWidth > 0 ? _terminal.viewWidth : 100,
            rows: _terminal.viewHeight > 0 ? _terminal.viewHeight : 30,
          ),
        ),
      );
      _session = session;
      _outputSubscription = session.utf8Output().listen(
        _terminal.write,
        onError: (Object error) {
          if (mounted) {
            setState(() => _error = 'Falha lendo o PowerShell: $error');
          }
        },
      );
      unawaited(
        session.done.then((exit) {
          if (mounted && identical(_session, session)) {
            setState(() {
              _session = null;
              _starting = false;
            });
            final status = exit is PtyExitCode
                ? 'código ${exit.code}'
                : 'sinal ${(exit as PtySignalExit).signal}';
            _terminal.write('\r\n[PowerShell encerrou: $status]\r\n');
          }
        }),
      );
    } catch (error) {
      _error = 'Não foi possível iniciar o PowerShell: $error';
    }
    if (mounted) setState(() => _starting = false);
  }

  void _writeToPowerShell(String data) {
    final session = _session;
    if (session != null) unawaited(session.input.writeUtf8(data));
  }

  Future<void> _stopSession() async {
    final session = _session;
    _session = null;
    await _outputSubscription?.cancel();
    _outputSubscription = null;
    if (session != null) {
      session.kill();
      await session.close();
    }
  }

  Future<void> _restart() async {
    await _stopSession();
    if (!mounted) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    await _start();
  }

  Future<void> _chooseDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath();
    if (selected == null || !Directory(selected).existsSync()) return;
    try {
      _cwd = await GestorProcessEnvironment.setWorkspaceDirectory(selected);
      await (await SharedPreferences.getInstance()).setString(
        'powershell.initial_directory',
        _cwd,
      );
      await _stopSession();
      _terminal.write('\x1b[2J\x1b[H');
      if (mounted) setState(() {});
      await _start();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Não foi possível trocar a pasta: $error');
      }
    }
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    _terminalController.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _pasteClipboard() async {
    final text = (await Clipboard.getData('text/plain'))?.text;
    if (text != null) _terminal.paste(text);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            children: [
              Icon(
                Icons.terminal_rounded,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message:
                      'Pasta compartilhada com os agentes: $_cwd\n'
                      r'$env:GESTOR_UFU_HOME, $env:GESTOR_UFU_WORKSPACE e $env:GESTOR_UFU_OUTPUT',
                  child: Text(
                    'Windows PowerShell • $_cwd',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Escolher workspace compartilhado com os agentes',
                onPressed: _chooseDirectory,
                icon: const Icon(Icons.folder_open_rounded),
              ),
              IconButton(
                tooltip: 'Colar',
                onPressed: _pasteClipboard,
                icon: const Icon(Icons.content_paste_rounded),
              ),
              IconButton(
                tooltip: 'Copiar seleção',
                onPressed: _copySelection,
                icon: const Icon(Icons.content_copy_rounded),
              ),
              IconButton(
                tooltip: 'Limpar tela',
                onPressed: () => _terminal.write('\x1b[2J\x1b[H'),
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              IconButton(
                tooltip: 'Reiniciar sessão',
                onPressed: _starting ? null : _restart,
                icon: const Icon(Icons.restart_alt_rounded),
              ),
            ],
          ),
        ),
      ),
      if (_error != null)
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            title: Text(_error!),
            trailing: IconButton(
              tooltip: 'Fechar aviso',
              onPressed: () => setState(() => _error = null),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ),
      Expanded(
        child: TerminalView(
          _terminal,
          controller: _terminalController,
          theme: TerminalThemes.whiteOnBlack,
          autofocus: true,
          onSecondaryTapDown: (details, offset) async {
            if (_terminalController.selection != null) {
              await _copySelection();
            } else {
              await _pasteClipboard();
            }
          },
        ),
      ),
      if (_starting) const LinearProgressIndicator(minHeight: 2),
    ],
  );
}
