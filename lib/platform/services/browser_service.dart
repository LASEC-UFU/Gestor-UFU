import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';

/// Navegadores controlados pelo Gestor (Edge/Chrome via puppeteer) —
/// docs/arquitetura/decisoes.md, D5.
///
/// Cada uso tem o SEU perfil (pasta própria: logins e sessão independentes):
/// Portal do Docente, SEI dos Planos de Ensino, SEI dos Planos de Trabalho e
/// da Progressão, navegador do Agente. O serviço apenas acha o navegador,
/// abre com o perfil e conecta — ou reconecta, se aquele perfil já estiver
/// aberto (ex.: o Gestor foi reiniciado).
///
/// O Edge repassa a execução para outro processo, então o puppeteer não
/// consegue ler o endereço de depuração do processo que lançou. Por isso o
/// navegador é iniciado aqui e a conexão usa o arquivo `DevToolsActivePort`
/// que ele grava no perfil.
class BrowserService {
  const BrowserService._();

  /// Pasta de perfil em %LOCALAPPDATA%\GestorUFU\<name> (padrão das
  /// automações; os nomes existentes não mudam para manter os logins).
  static String localProfile(String name) => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'GestorUFU',
    name,
  );

  /// Edge (preferido) ou Chrome instalado.
  static Future<String?> findExecutable() async {
    final programFiles = Platform.environment['PROGRAMFILES'] ?? '';
    final programFilesX86 = Platform.environment['PROGRAMFILES(X86)'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = [
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      p.join(programFilesX86, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      p.join(programFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      p.join(programFiles, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      p.join(programFilesX86, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      p.join(localAppData, 'Google', 'Chrome', 'Application', 'chrome.exe'),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  /// Abre (ou reconecta) o navegador do perfil [profileDir].
  static Future<Browser> open({
    required String profileDir,
    bool headless = false,
  }) async {
    await Directory(profileDir).create(recursive: true);
    final portFile = File(p.join(profileDir, 'DevToolsActivePort'));
    final existing = await _tryConnect(portFile);
    if (existing != null) return existing;
    final exe = await findExecutable();
    if (exe == null) {
      throw StateError('Não encontrei o Microsoft Edge nem o Google Chrome.');
    }
    try {
      if (await portFile.exists()) await portFile.delete();
    } catch (_) {}
    await Process.start(exe, [
      '--remote-debugging-port=0',
      '--user-data-dir=$profileDir',
      '--no-first-run',
      '--no-default-browser-check',
      '--start-maximized',
      if (headless) '--headless=new',
      'about:blank',
    ], mode: ProcessStartMode.detached);
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final browser = await _tryConnect(portFile);
      if (browser != null) return browser;
    }
    throw StateError(
      'O navegador abriu, mas não liberou a conexão de automação. Feche as '
      'janelas deste navegador e tente de novo.',
    );
  }

  /// Primeira aba do navegador (cria uma se não houver).
  static Future<Page> firstPage(Browser browser) async {
    final pages = await browser.pages;
    return pages.isEmpty ? await browser.newPage() : pages.first;
  }

  static Future<Browser?> _tryConnect(File portFile) async {
    try {
      if (!await portFile.exists()) return null;
      final lines = await portFile.readAsLines();
      if (lines.length < 2 || int.tryParse(lines.first.trim()) == null) {
        return null;
      }
      return await puppeteer
          .connect(
            browserWsEndpoint:
                'ws://127.0.0.1:${lines.first.trim()}${lines[1].trim()}',
            defaultViewport: null,
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
  }
}
