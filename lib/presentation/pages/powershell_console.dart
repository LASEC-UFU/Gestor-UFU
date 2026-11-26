import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Console local. Commands are sent to a real PowerShell process on Windows;
/// environment values are inherited and never displayed or logged.
class PowerShellConsole extends StatefulWidget {
  const PowerShellConsole({super.key});
  @override
  State<PowerShellConsole> createState() => _PowerShellConsoleState();
}

class _PowerShellConsoleState extends State<PowerShellConsole> {
  final _command = TextEditingController();
  final _output = <String>[];
  Process? _process;
  StreamSubscription<String>? _stdout, _stderr;
  String _cwd = Directory.current.path;
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDirectoryAndStart());
  }

  Future<void> _loadDirectoryAndStart() async {
    final prefs = await SharedPreferences.getInstance();
    final configured = prefs.getString('powershell.initial_directory');
    if (configured != null && Directory(configured).existsSync()) {
      _cwd = configured;
    }
    await _start();
  }

  @override
  void dispose() {
    _command.dispose();
    unawaited(_stdout?.cancel());
    unawaited(_stderr?.cancel());
    _process?.kill();
    super.dispose();
  }

  Future<void> _start() async {
    if (!Platform.isWindows) {
      setState(() => _error = 'A aba PowerShell requer Windows.');
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final p = await Process.start(
        'powershell.exe',
        const [
          '-NoLogo',
          '-NoProfile',
          '-NoExit',
          '-Command',
          r"$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); Write-Output ('Gestor UFU | PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' | ' + (Get-Location).Path)",
        ],
        workingDirectory: _cwd,
        runInShell: true,
      );
      _process = p;
      _stdout = p.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((s) {
            if (mounted) setState(() => _output.add(s));
          });
      _stderr = p.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((s) {
            if (mounted) setState(() => _output.add(s));
          });
      p.exitCode.then((code) {
        if (mounted && _process == p) {
          setState(() {
            _output.add('[PowerShell encerrou com código $code]');
            _process = null;
          });
        }
      });
    } catch (e) {
      _error = 'Não foi possível iniciar PowerShell: $e';
    }
    if (mounted) setState(() => _starting = false);
  }

  Future<void> _send() async {
    final text = _command.text;
    if (text.trim().isEmpty || _process == null) return;
    setState(() {
      _output.add('PS> $text');
      _command.clear();
    });
    _process!.stdin.writeln(text);
    await _process!.stdin.flush();
  }

  Future<void> _chooseDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath();
    if (selected == null || !Directory(selected).existsSync()) return;
    await (await SharedPreferences.getInstance()).setString(
      'powershell.initial_directory',
      selected,
    );
    _process?.kill();
    await _stdout?.cancel();
    await _stderr?.cancel();
    setState(() {
      _cwd = selected;
      _process = null;
      _output.clear();
    });
    await _start();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              const Icon(Icons.terminal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'PowerShell local • $_cwd\nExecutável: powershell.exe • Versão exibida ao iniciar',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Escolher diretório inicial',
                onPressed: _chooseDirectory,
                icon: const Icon(Icons.folder_open),
              ),
              IconButton(
                tooltip: 'Interromper processo',
                onPressed: _process == null ? null : () => _process!.kill(),
                icon: const Icon(Icons.stop_circle_outlined),
              ),
              IconButton(
                tooltip: 'Reiniciar sessão',
                onPressed: _starting
                    ? null
                    : () async {
                        _process?.kill();
                        await _stdout?.cancel();
                        await _stderr?.cancel();
                        setState(() => _process = null);
                        await _start();
                      },
                icon: const Icon(Icons.restart_alt),
              ),
              IconButton(
                tooltip: 'Limpar visualização',
                onPressed: () => setState(_output.clear),
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: Container(
          color: const Color(0xFF111827),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          child: ListView.builder(
            reverse: false,
            itemCount: _output.length,
            itemBuilder: (_, i) => SelectableText(
              _output[i],
              style: const TextStyle(
                color: Color(0xFFE5E7EB),
                fontFamily: 'Consolas',
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _command,
                enabled: _process != null,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(
                  prefixText: 'PS> ',
                  hintText: 'Digite um comando',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Executar',
              onPressed: _process == null ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    ],
  );
}
