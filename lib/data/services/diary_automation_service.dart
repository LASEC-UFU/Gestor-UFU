import 'dart:async';
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

class DiaryClearResult {
  const DiaryClearResult({required this.marked, required this.notFound});

  final int marked;
  final int notFound;
}

/// Automação local em Dart via Chrome DevTools Protocol (Puppeteer).
/// O navegador abre visível e mantém um perfil separado para preservar a sessão.
class DiaryAutomationService {
  Browser? _browser;
  Page? _page;
  bool _saveMonitorActive = false;

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
        final target = await page.evaluate<List<dynamic>>(
          _findPortalTextareaPositionScript,
          args: [entry.key],
        );
        if (target.length < 3) {
          notFound++;
          log(
            'N\u00e3o localizei um campo associado a ${entry.key}; nenhum campo global foi usado como alternativa.',
          );
          continue;
        }
        final x = (target[0] as num).toDouble();
        final y = (target[1] as num).toDouble();
        final index = (target[2] as num).toInt();
        final isEmpty = await page.evaluate<bool>(
          _isPortalTextareaEmptyScript,
          args: [index],
        );
        if (requireEmpty && !isEmpty) {
          skipped++;
          log('Campo ${entry.key} preservado: j\u00e1 tinha conte\u00fado.');
          continue;
        }

        await page.mouse.click(Point(x, y), clickCount: 2);
        await page.keyboard.down(Key.control);
        await page.keyboard.press(Key.keyA);
        await page.keyboard.up(Key.control);
        await page.keyboard.press(Key.delete);
        await page.keyboard.type(entry.value);
        await page.keyboard.press(Key.tab);
        final valueMatches = await page.evaluate<bool>(
          _isPortalTextareaValueScript,
          args: [index, entry.value],
        );
        if (!valueMatches) {
          notFound++;
          log('O campo ${entry.key} n\u00e3o manteve o texto digitado.');
          continue;
        }
        filled++;
        if (highlight) {
          await page.evaluate<bool>(
            _highlightPortalTextareaScript,
            args: [index],
          );
        }
        log('Campo ${entry.key} preenchido.');
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

  Future<DiaryClearResult> clearDiaryFields({
    required DiaryAutomationLog log,
  }) async {
    final page = _page;
    if (!isConnected || page == null) {
      throw StateError(
        'Abra o navegador e entre na tela do di\u00e1rio antes de limpar.',
      );
    }

    final dates = (await page.evaluate<List<dynamic>>(
      _collectPortalDiaryDatesScript,
    )).whereType<String>().toSet().toList();
    if (dates.isEmpty) {
      throw StateError(
        'N\u00e3o encontrei datas associadas aos campos do di\u00e1rio aberto.',
      );
    }

    var marked = 0;
    var notFound = 0;
    for (final date in dates) {
      log('Localizando o campo da data $date no Portal.');
      try {
        final target = await page.evaluate<List<dynamic>>(
          _findPortalTextareaPositionScript,
          args: [date],
        );
        if (target.length < 3) {
          notFound++;
          log('N\u00e3o localizei o campo associado a $date.');
          continue;
        }
        final x = (target[0] as num).toDouble();
        final y = (target[1] as num).toDouble();
        final index = (target[2] as num).toInt();
        await page.mouse.click(Point(x, y), clickCount: 2);
        await page.keyboard.down(Key.control);
        await page.keyboard.press(Key.keyA);
        await page.keyboard.up(Key.control);
        await page.keyboard.press(Key.delete);
        await page.keyboard.type('\u200B');
        await page.keyboard.press(Key.tab);
        final hasInvisibleMarker = await page.evaluate<bool>(
          _isPortalTextareaMarkerScript,
          args: [index],
        );
        if (hasInvisibleMarker) {
          marked++;
          log('Campo de $date limpo com marcador invis\u00edvel.');
        } else {
          notFound++;
          log(
            'N\u00e3o consegui inserir o marcador invis\u00edvel no campo de $date.',
          );
        }
      } catch (error) {
        notFound++;
        log('Falha ao limpar o campo de $date: $error');
      }
    }
    log(
      '$marked campo(s) marcado(s) como visualmente vazio(s) de ${dates.length} data(s) varrida(s); $notFound n\u00e3o localizado(s). A p\u00e1gina ficou aberta sem refresh. Confira e clique em Salvar no Portal para gravar.',
    );
    final monitorInstalled = await page.evaluate<bool>(
      _installPortalSaveMonitorScript,
    );
    if (monitorInstalled) unawaited(_monitorNextPortalSave(page, log));
    return DiaryClearResult(marked: marked, notFound: notFound);
  }

  Future<void> _monitorNextPortalSave(Page page, DiaryAutomationLog log) async {
    if (_saveMonitorActive) return;
    _saveMonitorActive = true;
    try {
      await page.waitForNavigation(
        timeout: const Duration(minutes: 3),
        wait: Until.domContentLoaded,
      );
      final result = await page.evaluate<List<dynamic>>(
        _readPortalSaveDiagnosticsScript,
      );
      if (result.length >= 8) {
        log(
          'Diagn\u00f3stico do Salvar: ${result[1]} marcador(es) invis\u00edvel(is), ${result[2]} espa\u00e7o(s) comum(ns) e ${result[3]} vazio(s) enviados de ${result[0]}; a resposta trouxe ${result[7]} marcador(es), ${result[4]} campo(s) vazio(s) e ${result[6]} preenchido(s) de ${result[5]}.',
        );
      } else {
        log(
          'O Portal recarregou, mas o diagn\u00f3stico do envio n\u00e3o estava dispon\u00edvel.',
        );
      }
    } on TimeoutException {
      // The user may decide not to save; do not show a misleading error.
    } catch (error) {
      log(
        'N\u00e3o consegui verificar o resultado do Salvar no Portal: $error',
      );
    } finally {
      _saveMonitorActive = false;
    }
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

const _installPortalSaveMonitorScript = r'''() => {
  const form = document.querySelector('form#salvarConteudoDiario');
  if (!form) return false;
  const key = '__gestorUfuDiaryClearSubmission';
  const marker = '\u200B';
  sessionStorage.removeItem(key);
  form.addEventListener('submit', () => {
    const values = Array.from(form.querySelectorAll('textarea'))
      .map(field => field.value || '');
    const markers = values.filter(value => value === marker).length;
    const spaces = values.filter(value => value === ' ').length;
    const empty = values.filter(value => value === '').length;
    sessionStorage.setItem(key, JSON.stringify({total: values.length, markers, spaces, empty}));
  }, {capture: true, once: true});
  return true;
}''';

const _readPortalSaveDiagnosticsScript = r'''() => {
  const key = '__gestorUfuDiaryClearSubmission';
  const raw = sessionStorage.getItem(key);
  if (!raw) return [];
  const before = JSON.parse(raw);
  const marker = '\u200B';
  const form = document.querySelector('form#salvarConteudoDiario');
  const values = Array.from(form?.querySelectorAll('textarea') || [])
    .map(field => field.value || '');
  const markers = values.filter(value => value === marker).length;
  const spaces = values.filter(value => value === ' ').length;
  const empty = values.filter(value => value === '').length;
  const populated = values.filter(value => value.trim().length > 0).length;
  return [before.total, before.markers, before.spaces, before.empty, empty, values.length, populated, markers];
}''';
const _findPortalTextareaPositionScript = r'''(key) => {
  const norm = value => (value || '').toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[\u2013\u2014\u2212]/g, '-')
    .replace(/\s+/g, ' ').trim();
  const visible = element => !!element && !!element.offsetParent;
  const wanted = norm(key);
  const fields = Array.from(document.querySelectorAll('textarea'))
    .filter(element => visible(element) && !element.disabled && !element.readOnly);
  const rowFor = field => field.closest('tr') || field.closest('.form-group') ||
    field.closest('.row') || field.parentElement?.parentElement || field.parentElement;
  const index = fields.findIndex(field => {
    const row = rowFor(field);
    return row && visible(row) && norm(row.textContent).includes(wanted);
  });
  if (index < 0) return [];
  const field = fields[index];
  field.scrollIntoView({behavior: 'auto', block: 'center', inline: 'nearest'});
  const rect = field.getBoundingClientRect();
  return [rect.left + rect.width / 2, rect.top + rect.height / 2, index];
}''';

const _isPortalTextareaEmptyScript = r'''(index) => {
  const visible = element => !!element && !!element.offsetParent;
  const fields = Array.from(document.querySelectorAll('textarea'))
    .filter(element => visible(element) && !element.disabled && !element.readOnly);
  const value = fields[index]?.value || '';
  return !!fields[index] && (!(value.trim()) || value === '\u200B');
}''';

const _isPortalTextareaValueScript = r'''(index, value) => {
  const visible = element => !!element && !!element.offsetParent;
  const fields = Array.from(document.querySelectorAll('textarea'))
    .filter(element => visible(element) && !element.disabled && !element.readOnly);
  return !!fields[index] && fields[index].value === value;
}''';

const _isPortalTextareaMarkerScript = r'''(index) => {
  const visible = element => !!element && !!element.offsetParent;
  const fields = Array.from(document.querySelectorAll('textarea'))
    .filter(element => visible(element) && !element.disabled && !element.readOnly);
  return !!fields[index] && fields[index].value === '\u200B';
}''';

const _highlightPortalTextareaScript = r'''(index) => {
  const visible = element => !!element && !!element.offsetParent;
  const fields = Array.from(document.querySelectorAll('textarea'))
    .filter(element => visible(element) && !element.disabled && !element.readOnly);
  const field = fields[index];
  if (!field) return false;
  const oldOutline = field.style.outline;
  field.style.outline = '3px solid orange';
  setTimeout(() => { field.style.outline = oldOutline; }, 1200);
  return true;
}''';
const _clickSaveButtonScript = r'''() => {
  const norm = value => (value || '').normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').toLowerCase().trim();
  const visible = element => !!element && !!element.offsetParent;
  const fields = Array.from(document.querySelectorAll('textarea')).filter(visible);
  const diaryForm = fields[0]?.form || fields[0]?.closest('form') || null;
  const findSave = root => Array.from(root.querySelectorAll(
    'button, input[type="submit"], input[type="button"], a[role="button"]'))
    .find(element => {
      if (!visible(element) || element.disabled) return false;
      const label = norm(element.innerText || element.value || element.getAttribute('aria-label'));
      return /^(salvar|gravar|salvar alteracoes|gravar alteracoes)$/.test(label);
    });
  const target = (diaryForm && findSave(diaryForm)) || findSave(document);
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
