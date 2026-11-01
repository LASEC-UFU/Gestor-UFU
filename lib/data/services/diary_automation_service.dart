import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';

typedef DiaryAutomationLog = void Function(String message);

class DiaryFillResult {
  const DiaryFillResult({
    required this.filled,
    required this.notFound,
    required this.skipped,
    required this.saveButtonClicked,
    required this.saveConfirmation,
  });

  final int filled;
  final int notFound;
  final int skipped;
  final bool saveButtonClicked;
  final String? saveConfirmation;
}

/// Automação local em Dart via Chrome DevTools Protocol (Puppeteer).
/// O navegador abre visível e mantém um perfil separado para preservar a sessão.
class DiaryAutomationService {
  Browser? _browser;
  Page? _page;

  bool get isConnected =>
      _browser?.isConnected == true && _page != null && !_page!.isClosed;

  Future<String> openBrowser(
    String url, {
    String? username,
    String? password,
    DiaryAutomationLog? log,
  }) async {
    final existingBrowser = _browser;
    final existingPage = _page;
    if (existingBrowser?.isConnected == true &&
        existingPage != null &&
        !existingPage.isClosed) {
      await existingPage.goto(url, wait: Until.domContentLoaded);
      await _tryPortalLogin(
        existingPage,
        username: username,
        password: password,
        log: log,
      );
      await existingPage.bringToFront();
      return existingPage.url ?? url;
    }

    final edgePath = await _findEdgeExecutable();
    if (edgePath == null) {
      throw StateError(
        'Não encontrei o Microsoft Edge. Instale o Edge ou confira os caminhos em Program Files.',
      );
    }

    final profileDir = _profileDirectory();
    await Directory(profileDir).create(recursive: true);
    _browser = await puppeteer.launch(
      executablePath: edgePath,
      headless: false,
      defaultViewport: null,
      userDataDir: profileDir,
      args: const ['--start-maximized'],
      timeout: const Duration(seconds: 45),
      waitForInitialPage: true,
    );
    final pages = await _browser!.pages;
    _page = pages.isEmpty ? await _browser!.newPage() : pages.first;
    await _page!.goto(url, wait: Until.domContentLoaded);
    await _tryPortalLogin(
      _page!,
      username: username,
      password: password,
      log: log,
    );
    await _page!.bringToFront();
    return _page!.url ?? url;
  }

  Future<void> _tryPortalLogin(
    Page page, {
    String? username,
    String? password,
    DiaryAutomationLog? log,
  }) async {
    if (username == null || username.trim().isEmpty || password == null) {
      return;
    }
    final host = Uri.tryParse(page.url ?? '')?.host.toLowerCase() ?? '';
    if (host != 'ufu.br' && !host.endsWith('.ufu.br')) {
      log?.call(
        'Login automático não executado: o endereço atual não pertence ao domínio UFU.',
      );
      return;
    }

    // The portal may render its login form after the initial page load.
    // Check the page and its frames for up to 30 seconds without submitting.
    var result = 'password_not_found';
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      for (final frame in page.frames) {
        final frameHost = Uri.tryParse(frame.url)?.host.toLowerCase() ?? '';
        if (frameHost != 'ufu.br' && !frameHost.endsWith('.ufu.br')) continue;
        try {
          final candidate = await frame.evaluate<String>(
            _portalLoginScript,
            args: [username.trim(), password],
          );
          if (candidate == 'filled' || candidate == 'username_not_found') {
            result = candidate;
            break;
          }
          if (candidate == 'password_found') result = candidate;
        } catch (_) {
          // A frame can navigate while being inspected; retry on the next pass.
        }
      }
      if (result == 'filled' || result == 'username_not_found') break;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    switch (result) {
      case 'filled':
        log?.call(
          'Login preenchido com as credenciais salvas. Confira os campos e clique em Entrar no portal.',
        );
      case 'username_not_found':
        log?.call(
          'Encontrei o campo de senha, mas não identifiquei o campo de usuário; conclua o login manualmente.',
        );
      default:
        log?.call(
          'Não consegui identificar com segurança o formulário do portal; conclua o login manualmente.',
        );
    }
  }

  Future<DiaryFillResult> fillEntries(
    Map<String, String> entries, {
    required bool requireEmpty,
    required bool highlight,
    required DiaryAutomationLog log,
  }) async {
    final page = _page;
    if (!isConnected || page == null) {
      throw StateError(
        'Abra o navegador e entre na tela do diário antes de preencher.',
      );
    }
    if (entries.isEmpty) {
      throw StateError('Não há lançamentos para preencher.');
    }
    try {
      await page.waitForSelector(
        'textarea',
        timeout: const Duration(seconds: 8),
      );
    } catch (_) {
      throw StateError(
        'Não encontrei campos de texto na página atual. Abra o formulário do diário no Edge e tente novamente.',
      );
    }

    var filled = 0;
    var notFound = 0;
    var skipped = 0;
    for (final entry in entries.entries) {
      log('Procurando o campo relacionado a ${entry.key}.');
      try {
        final result = await page.evaluate<String>(
          _fillRelatedTextareaScript,
          args: [entry.key, entry.value, requireEmpty, highlight],
        );
        switch (result) {
          case 'filled':
            filled++;
            log('Campo ${entry.key} preenchido.');
          case 'skipped':
            skipped++;
            log('Campo ${entry.key} preservado: já tinha conteúdo.');
          default:
            notFound++;
            log(
              'Não localizei um campo associado a ${entry.key}; nenhum campo global foi usado como alternativa.',
            );
        }
      } catch (error) {
        notFound++;
        log('Falha ao preencher ${entry.key}: $error');
      }
    }

    var saveClicked = false;
    String? confirmation;
    try {
      saveClicked = await page.evaluate<bool>(_clickSaveButtonScript);
      if (saveClicked) {
        log('Botão Salvar/Gravar acionado. Aguardando confirmação do portal.');
        await Future<void>.delayed(const Duration(seconds: 2));
        confirmation = await page.evaluate<String>(_saveConfirmationScript);
        if (confirmation.trim().isNotEmpty) {
          log('O portal exibiu: ${confirmation.trim()}');
        } else {
          log(
            'Não encontrei um indicador verificável de gravação. Confira a página do portal.',
          );
        }
      } else {
        log(
          'Botão Salvar/Gravar não localizado. Revise e grave manualmente no portal.',
        );
      }
    } catch (error) {
      log('Não foi possível confirmar a gravação: $error');
    }

    return DiaryFillResult(
      filled: filled,
      notFound: notFound,
      skipped: skipped,
      saveButtonClicked: saveClicked,
      saveConfirmation: confirmation,
    );
  }

  Future<List<String>> findPortalDiaryDates() async {
    final page = _page;
    if (!isConnected || page == null) {
      throw StateError(
        'Abra o navegador e entre na tela do diário antes de buscar as datas.',
      );
    }
    return (await page.evaluate<List<dynamic>>(
      _collectPortalDiaryDatesScript,
    )).whereType<String>().toSet().toList();
  }

  Future<void> close() async {
    final browser = _browser;
    _browser = null;
    _page = null;
    if (browser?.isConnected == true) await browser!.close();
  }

  Future<String?> _findEdgeExecutable() async {
    final candidates = <String>[
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      if (Platform.environment['PROGRAMFILES(X86)'] case final path?)
        p.join(path, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      if (Platform.environment['PROGRAMFILES'] case final path?)
        p.join(path, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  String _profileDirectory() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      return p.join(
        Directory.systemTemp.path,
        'GestorUFU',
        'EdgeDiarioProfile',
      );
    }
    return p.join(localAppData, 'GestorUFU', 'EdgeDiarioProfile');
  }
}

const _portalLoginScript = r'''(username, password) => {
  const visible = element => !!element && !!element.offsetParent;
  const passwordInput = Array.from(document.querySelectorAll('input[type="password"]'))
    .find(visible);
  if (!passwordInput) return 'password_not_found';

  const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
  const usernameInput = inputs.find(input => {
    if (input === passwordInput) return false;
    const hint = [input.name, input.id, input.placeholder, input.autocomplete]
      .join(' ').toLowerCase();
    return /user|login|email|cpf|matricula/.test(hint);
  }) || inputs.find(input => {
    if (input === passwordInput) return false;
    const type = (input.type || 'text').toLowerCase();
    return type === 'text' || type === 'email' || type === 'tel';
  });
  if (!usernameInput) return 'username_not_found';

  const setValue = (element, value) => {
    const setter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype, 'value').set;
    setter.call(element, value);
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
  };
  setValue(usernameInput, username);
  setValue(passwordInput, password);

  usernameInput.dispatchEvent(new Event('blur', { bubbles: true }));
  passwordInput.dispatchEvent(new Event('blur', { bubbles: true }));
  return 'filled';
}''';

const _collectPortalDiaryDatesScript = r'''() => {
  const visible = element => !!element && !!element.offsetParent;
  const found = new Set();
  const datePattern = /\b\d{1,2}\/\d{1,2}\/\d{4}\s*[-–—]?\s*[TP]\b/gi;
  for (const textarea of Array.from(document.querySelectorAll('textarea')).filter(visible)) {
    const row = textarea.closest('tr') || textarea.closest('.form-group') ||
      textarea.closest('.row') || textarea.parentElement?.parentElement ||
      textarea.parentElement;
    if (!row || !visible(row)) continue;
    const text = row.innerText || row.textContent || '';
    for (const match of text.matchAll(datePattern)) {
      found.add(match[0].replace(/\s+/g, ' ').replace(/[-–—]?\s*([TP])$/i, ' -$1'));
    }
  }
  return Array.from(found);
}''';

const _fillRelatedTextareaScript = r'''(key, text, requireEmpty, highlight) => {
  const norm = value => (value || '').toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[\u2013\u2014\u2212]/g, '-')
    .replace(/\s+/g, ' ').trim();
  const wanted = norm(key);
  const visible = element => !!element && !!element.offsetParent;
  const rows = ['tr', '.row', '.linha', '.form-group', 'li', '.item']
    .flatMap(selector => Array.from(document.querySelectorAll(selector)))
    .filter(element => visible(element) && norm(element.textContent).includes(wanted));

  let textarea = null;
  for (const row of rows) {
    const inside = row.querySelector('textarea');
    if (inside) { textarea = inside; break; }
    if (row.tagName === 'TR') {
      const cells = Array.from(row.children);
      const labelIndex = cells.findIndex(cell => norm(cell.textContent).includes(wanted));
      if (labelIndex >= 0) {
        for (let index = labelIndex + 1; index < cells.length; index++) {
          const next = cells[index].querySelector('textarea');
          if (next) { textarea = next; break; }
        }
        if (textarea) break;
      }
    }
  }

  if (!textarea) {
    const labels = Array.from(document.querySelectorAll('body *'))
      .filter(element => visible(element) && norm(element.textContent).includes(wanted));
    for (const label of labels) {
      let sibling = label.nextElementSibling;
      for (let step = 0; step < 5 && sibling; step++, sibling = sibling.nextElementSibling) {
        if (sibling.tagName === 'TEXTAREA') { textarea = sibling; break; }
        const nearby = sibling.querySelector?.('textarea');
        if (nearby) { textarea = nearby; break; }
      }
      if (!textarea) textarea = label.querySelector?.('textarea') || null;
      if (textarea) break;
    }
  }

  if (!textarea) return 'notFound';
  if (requireEmpty && (textarea.value || '').trim()) return 'skipped';
  textarea.scrollIntoView({behavior: 'auto', block: 'center', inline: 'nearest'});
  textarea.focus();
  textarea.value = text || '';
  textarea.dispatchEvent(new Event('input', {bubbles: true}));
  textarea.dispatchEvent(new Event('change', {bubbles: true}));
  if (highlight) {
    const oldOutline = textarea.style.outline;
    textarea.style.outline = '3px solid orange';
    setTimeout(() => { textarea.style.outline = oldOutline; }, 1200);
  }
  return 'filled';
}''';

const _clickSaveButtonScript = r'''() => {
  const norm = value => (value || '').normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
  const controls = Array.from(document.querySelectorAll(
    'button, input[type="submit"], input[type="button"], a[role="button"]'));
  const target = controls.find(element => {
    if (!element.offsetParent || element.disabled) return false;
    const label = norm(element.innerText || element.value || element.getAttribute('aria-label'));
    return /^(salvar|gravar|salvar alteracoes|gravar alteracoes)$/.test(label);
  });
  if (!target) return false;
  target.click();
  return true;
}''';

const _saveConfirmationScript = r'''() => {
  const norm = value => (value || '').normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
  const alerts = Array.from(document.querySelectorAll(
    '[role="alert"], .alert-success, .toast-success, .mensagemSucesso, .success'));
  const alert = alerts.find(element => element.offsetParent && norm(element.innerText));
  if (alert) return alert.innerText.trim().slice(0, 180);
  const body = norm(document.body?.innerText);
  const match = body.match(/[^\n]*(?:salvo|salva|gravado|gravada|atualizado|atualizada|sucesso)[^\n]*/);
  return match ? match[0].trim().slice(0, 180) : '';
}''';
