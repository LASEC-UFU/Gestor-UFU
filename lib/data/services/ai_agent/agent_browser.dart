import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';

/// Navegador controlado pelo Agente de IA (puppeteer sobre Edge/Chrome).
///
/// Roda na janela principal, então continua aberto em segundo plano mesmo
/// com a janela do agente fechada. É um navegador visível e de verdade: o
/// usuário pode usá-lo ao mesmo tempo que o agente. O perfil fica em
/// %APPDATA%\GestorUFU\agente\navegador, então os logins são lembrados.
///
/// Recursos: abrir e navegar, ler a página (com referências numeradas para
/// os elementos), clicar, digitar, teclas, selecionar, rolar, esperar,
/// executar JavaScript, capturas de tela, abas, gravação das ações do
/// usuário e monitoramento de erros (console, exceções, requisições).
class AgentBrowser {
  AgentBrowser._();

  static final instance = AgentBrowser._();

  Browser? _browser;
  Page? _page;
  final _attached = <Page>{};
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Erros e eventos observados (console, exceções, rede, diálogos).
  final _logs = <Map<String, Object?>>[];
  static const _maxLogs = 500;

  /// Gravação das ações feitas no navegador (pelo usuário ou pelo agente).
  bool _recording = false;
  DateTime? _recordStart;
  final _recorded = <Map<String, Object?>>[];

  bool get isOpen => _browser?.isConnected ?? false;
  bool get isRecording => _recording;

  /// Executa uma ferramenta `browser_*` e devolve um mapa serializável.
  Future<Map<String, Object?>> run(
    String name,
    Map<String, dynamic> input,
  ) async {
    switch (name) {
      case 'browser_open':
        return _open(input);
      case 'browser_close':
        await close();
        return {'ok': true, 'message': 'Navegador fechado.'};
      case 'browser_status':
        return _status();
    }
    if (!isOpen) {
      if (name == 'browser_logs' || name == 'browser_record') {
        if (name == 'browser_logs') return _logsResult(input);
        return _record(input);
      }
      throw StateError(
        'O navegador do agente não está aberto. Use browser_open primeiro.',
      );
    }
    switch (name) {
      case 'browser_navigate':
        return _navigate(input);
      case 'browser_snapshot':
        return _snapshot(input);
      case 'browser_act':
        return _act(input);
      case 'browser_eval':
        return _eval(input);
      case 'browser_screenshot':
        return _screenshot(input);
      case 'browser_tabs':
        return _tabs(input);
      case 'browser_record':
        return _record(input);
      case 'browser_logs':
        return _logsResult(input);
    }
    throw StateError('Ferramenta de navegador desconhecida: $name');
  }

  // ------------------------------------------------------------ abrir/fechar

  Future<Map<String, Object?>> _open(Map<String, dynamic> input) async {
    final url = '${input['url'] ?? ''}'.trim();
    if (!isOpen) {
      final exe = await _findBrowser();
      if (exe == null) {
        throw StateError('Não encontrei o Microsoft Edge nem o Google Chrome.');
      }
      final profile = _profileDirectory();
      await Directory(profile).create(recursive: true);
      final browser = await _connectOrStart(
        exe,
        profile,
        headless: input['headless'] == true,
      );
      _browser = browser;
      _subscriptions.add(
        browser.onTargetCreated.listen((target) async {
          try {
            final page = await target.pageOrNull;
            if (page != null) await _attach(page);
          } catch (_) {}
        }),
      );
      unawaited(browser.disconnected.then((_) => _reset()));
      final pages = await browser.pages;
      final page = pages.isEmpty ? await browser.newPage() : pages.first;
      for (final existing in pages) {
        await _attach(existing);
      }
      await _attach(page);
      _page = page;
    }
    if (url.isNotEmpty) await _goto(_page!, url);
    await _page!.bringToFront();
    return _pageInfo(_page!, extra: {'ok': true});
  }

  /// O Edge passa a execução para outro processo e o puppeteer não consegue
  /// ler o endereço de depuração pelo processo que lançou. Por isso o
  /// navegador é iniciado aqui e a conexão usa o arquivo DevToolsActivePort
  /// do perfil. Se ele já estiver aberto (ex.: o Gestor foi reiniciado),
  /// apenas reconecta.
  static Future<Browser> _connectOrStart(
    String exe,
    String profile, {
    required bool headless,
  }) async {
    final portFile = File(p.join(profile, 'DevToolsActivePort'));
    final existing = await _tryConnect(portFile);
    if (existing != null) return existing;
    try {
      if (await portFile.exists()) await portFile.delete();
    } catch (_) {}
    await Process.start(exe, [
      '--remote-debugging-port=0',
      '--user-data-dir=$profile',
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
      'O navegador abriu, mas não liberou a conexão de automação. Feche '
      'as janelas do navegador do agente e tente de novo.',
    );
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

  Future<void> close() async {
    final browser = _browser;
    _reset();
    try {
      await browser?.close();
    } catch (_) {}
  }

  void _reset() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _attached.clear();
    _browser = null;
    _page = null;
  }

  static String _profileDirectory() {
    final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    return p.join(base, 'GestorUFU', 'agente', 'navegador');
  }

  static Future<String?> _findBrowser() async {
    final programFiles = Platform.environment['PROGRAMFILES'] ?? '';
    final programFilesX86 = Platform.environment['PROGRAMFILES(X86)'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = [
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

  // ------------------------------------------------------------ monitoramento

  /// Liga monitoramento de erros e o gravador numa aba.
  Future<void> _attach(Page page) async {
    if (!_attached.add(page)) return;
    void log(String kind, String text, {String? url}) {
      _logs.add({
        'time': DateTime.now().toIso8601String(),
        'kind': kind,
        'text': text.length > 1000 ? '${text.substring(0, 1000)}…' : text,
        'url': url ?? page.url,
      });
      if (_logs.length > _maxLogs) _logs.removeAt(0);
    }

    _subscriptions
      ..add(
        page.onConsole.listen((message) {
          final text = message.text ?? '';
          // Eventos do gravador chegam por console.debug marcado.
          if (text.startsWith(_recordPrefix)) {
            if (!_recording) return;
            try {
              _recorded.add(
                Map<String, Object?>.from(
                  jsonDecode(text.substring(_recordPrefix.length)) as Map,
                ),
              );
              if (_recorded.length > 2000) _recorded.removeAt(0);
            } catch (_) {}
            return;
          }
          final type = message.typeName;
          if (type == 'error' || type == 'warning' || type == 'warn') {
            log('console_$type', message.text ?? '', url: message.url);
          }
        }),
      )
      ..add(page.onError.listen((error) => log('page_error', '$error')))
      ..add(
        page.onRequestFailed.listen(
          (request) => log(
            'request_failed',
            '${request.method} ${request.failure ?? 'falhou'}',
            url: request.url,
          ),
        ),
      )
      ..add(
        page.onResponse.listen((response) {
          if (response.status >= 400) {
            log(
              'http_${response.status}',
              '${response.request.method} ${response.status}',
              url: response.url,
            );
          }
        }),
      )
      ..add(
        page.onDialog.listen((dialog) async {
          log('dialog', '${dialog.type.name}: ${dialog.message ?? ''}');
          // Alertas travariam a automação: aceita e registra.
          try {
            await dialog.accept();
          } catch (_) {}
        }),
      )
      ..add(
        page.onFrameNavigated.listen((frame) {
          if (frame.parentFrame != null) return;
          if (_recording) {
            _recorded.add({
              'type': 'navigate',
              'url': frame.url,
              't': DateTime.now().millisecondsSinceEpoch,
            });
          }
        }),
      );
    try {
      await page.evaluateOnNewDocument(_recorderScript);
      await page.evaluate(_recorderScript);
    } catch (_) {
      // Páginas internas (edge://) não aceitam scripts.
    }
  }

  static const _recordPrefix = '__gestorRecord ';

  static const _recorderScript = r'''() => {
  if (window.__gestorRecorderInstalled) return;
  window.__gestorRecorderInstalled = true;
  const sel = (el) => {
    if (!el || el.nodeType !== 1) return '';
    if (el.id) return '#' + CSS.escape(el.id);
    const tag = el.tagName.toLowerCase();
    for (const attr of ['name', 'data-testid', 'aria-label', 'placeholder']) {
      const v = el.getAttribute(attr);
      if (v) return tag + '[' + attr + '="' + v.replace(/"/g, '\\"') + '"]';
    }
    const parts = [];
    let e = el;
    while (e && e.nodeType === 1 && parts.length < 5) {
      let s = e.tagName.toLowerCase();
      if (e.id) { parts.unshift('#' + CSS.escape(e.id)); break; }
      const sib = [...(e.parentNode ? e.parentNode.children : [])]
        .filter((x) => x.tagName === e.tagName);
      if (sib.length > 1) s += ':nth-of-type(' + (sib.indexOf(e) + 1) + ')';
      parts.unshift(s);
      e = e.parentElement;
    }
    return parts.join(' > ');
  };
  const label = (el) => ((el.innerText || el.value || el.getAttribute('aria-label') ||
    el.getAttribute('placeholder') || '') + '').trim().slice(0, 80);
  const send = (o) => {
    try {
      console.debug('__gestorRecord ' + JSON.stringify(Object.assign(
        { url: location.href, t: Date.now() }, o)));
    } catch (e) {}
  };
  document.addEventListener('click', (e) => {
    const el = (e.target.closest && e.target.closest(
      'a,button,input,select,textarea,[role],[onclick],label,summary')) || e.target;
    send({ type: 'click', selector: sel(el), text: label(el) });
  }, true);
  document.addEventListener('change', (e) => {
    const el = e.target;
    const value = el.type === 'password' ? '(senha oculta)' :
      ((el.value || '') + '').slice(0, 200);
    send({ type: 'input', selector: sel(el), value });
  }, true);
  document.addEventListener('keydown', (e) => {
    if (['Enter', 'Escape', 'Tab'].includes(e.key)) {
      send({ type: 'key', key: e.key, selector: sel(e.target) });
    }
  }, true);
  document.addEventListener('submit', (e) =>
    send({ type: 'submit', selector: sel(e.target) }), true);
}''';

  Map<String, Object?> _logsResult(Map<String, dynamic> input) {
    final kinds = (input['kinds'] as List?)?.map((e) => '$e').toSet();
    final limit = (input['limit'] as num?)?.toInt() ?? 100;
    final filtered = [
      for (final entry in _logs)
        if (kinds == null || kinds.any((k) => '${entry['kind']}'.startsWith(k)))
          entry,
    ];
    final result = {
      'total': filtered.length,
      'logs': filtered.length > limit
          ? filtered.sublist(filtered.length - limit)
          : filtered,
    };
    if (input['clear'] == true) _logs.clear();
    return result;
  }

  // ------------------------------------------------------------ gravação

  Map<String, Object?> _record(Map<String, dynamic> input) {
    final action = '${input['action'] ?? 'status'}';
    switch (action) {
      case 'start':
        _recorded.clear();
        _recording = true;
        _recordStart = DateTime.now();
        return {
          'recording': true,
          'message':
              'Gravando. As ações feitas no navegador do agente (cliques, '
              'campos preenchidos, teclas, navegação) serão registradas.',
        };
      case 'stop':
        _recording = false;
        return {
          'recording': false,
          'started_at': _recordStart?.toIso8601String(),
          'events': List.of(_recorded),
        };
      default:
        return {
          'recording': _recording,
          'started_at': _recordStart?.toIso8601String(),
          'events': List.of(_recorded),
        };
    }
  }

  // ------------------------------------------------------------ navegação

  Future<void> _goto(Page page, String url) async {
    final target = url.contains('://') ? url : 'https://$url';
    try {
      await page.goto(
        target,
        wait: Until.domContentLoaded,
        timeout: const Duration(seconds: 45),
      );
    } on TimeoutException {
      // Páginas lentas: segue com o que carregou.
    }
  }

  Future<Map<String, Object?>> _navigate(Map<String, dynamic> input) async {
    final page = _page!;
    final action = '${input['action'] ?? 'goto'}';
    switch (action) {
      case 'back':
        await page.goBack(wait: Until.domContentLoaded);
      case 'forward':
        await page.goForward(wait: Until.domContentLoaded);
      case 'reload':
        await page.reload(wait: Until.domContentLoaded);
      default:
        final url = '${input['url'] ?? ''}'.trim();
        if (url.isEmpty) throw StateError('Informe a url.');
        await _goto(page, url);
    }
    return _pageInfo(page, extra: {'ok': true});
  }

  Future<Map<String, Object?>> _pageInfo(
    Page page, {
    Map<String, Object?> extra = const {},
  }) async {
    String? title;
    try {
      title = await page.title;
    } catch (_) {}
    return {...extra, 'url': page.url, 'title': title};
  }

  Future<Map<String, Object?>> _status() async {
    if (!isOpen) {
      return {'open': false, 'recording': _recording, 'logs': _logs.length};
    }
    return {
      'open': true,
      'recording': _recording,
      'logs': _logs.length,
      ...await _pageInfo(_page!),
    };
  }

  // ------------------------------------------------------------ leitura

  /// Lista os elementos interativos visíveis com uma referência numérica
  /// (data-agent-ref) e o texto da página.
  Future<Map<String, Object?>> _snapshot(Map<String, dynamic> input) async {
    final page = _page!;
    final maxText = (input['max_text'] as num?)?.toInt() ?? 6000;
    final result = await page.evaluate<Map<dynamic, dynamic>>(
      r'''(maxText) => {
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const query = 'a,button,input,select,textarea,summary,[role=button],[role=link],' +
    '[role=tab],[role=menuitem],[role=checkbox],[role=option],[onclick],[contenteditable=true]';
  const items = [];
  let n = 0;
  for (const el of document.querySelectorAll(query)) {
    if (!visible(el) || el.disabled) continue;
    n += 1;
    el.setAttribute('data-agent-ref', String(n));
    const label = ((el.getAttribute('aria-label') || el.innerText || el.value ||
      el.getAttribute('placeholder') || el.getAttribute('title') || el.name || '') + '')
      .replace(/\s+/g, ' ').trim().slice(0, 100);
    const item = { ref: n, tag: el.tagName.toLowerCase(), label };
    if (el.type) item.type = el.type;
    if (el.getAttribute('role')) item.role = el.getAttribute('role');
    if (el.href) item.href = el.href;
    if (el.tagName === 'SELECT') {
      item.options = [...el.options].slice(0, 30).map((o) => o.text.trim());
      item.value = el.value;
    } else if (el.type === 'checkbox' || el.type === 'radio') {
      item.checked = el.checked;
    } else if ('value' in el && el.type !== 'password' && el.value) {
      item.value = (el.value + '').slice(0, 100);
    }
    items.push(item);
    if (items.length >= 300) break;
  }
  const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n');
  return { elements: items, text: text.slice(0, maxText), text_length: text.length };
}''',
      args: [maxText],
    );
    return {
      ...await _pageInfo(page),
      ...Map<String, Object?>.from(result),
      'hint':
          'Use browser_act com "ref" (número do elemento) para clicar/digitar.',
    };
  }

  // ------------------------------------------------------------ ações

  String _selectorOf(Map<String, dynamic> input) {
    final ref = input['ref'];
    if (ref != null) return '[data-agent-ref="$ref"]';
    final selector = '${input['selector'] ?? ''}'.trim();
    if (selector.isNotEmpty) return selector;
    throw StateError('Informe "ref" (de browser_snapshot) ou "selector".');
  }

  /// Marca o primeiro elemento clicável que contém [text] e devolve o seletor.
  Future<String> _selectorForText(Page page, String text) async {
    final found = await page.evaluate<bool>(
      r'''(text) => {
  const wanted = text.toLowerCase();
  const all = [...document.querySelectorAll(
    'a,button,input[type=submit],input[type=button],summary,label,[role],[onclick],li,span,div')];
  const el = all.find((e) => {
    const t = ((e.innerText || e.value || e.getAttribute('aria-label') || '') + '')
      .trim().toLowerCase();
    const r = e.getBoundingClientRect();
    return t && t.includes(wanted) && r.width > 0 && r.height > 0 &&
      t.length < wanted.length + 60;
  });
  if (!el) return false;
  document.querySelectorAll('[data-agent-target]').forEach((e) =>
    e.removeAttribute('data-agent-target'));
  el.setAttribute('data-agent-target', '1');
  return true;
}''',
      args: [text],
    );
    if (found != true) throw StateError('Nenhum elemento com o texto "$text".');
    return '[data-agent-target="1"]';
  }

  Future<Map<String, Object?>> _act(Map<String, dynamic> input) async {
    final page = _page!;
    final action = '${input['action'] ?? ''}';
    String selector() => _selectorOf(input);
    switch (action) {
      case 'click':
        final target =
            input['text'] != null &&
                input['ref'] == null &&
                input['selector'] == null
            ? await _selectorForText(page, '${input['text']}')
            : selector();
        try {
          await page.click(target);
        } catch (_) {
          // Elemento coberto/fora da tela: clica por JavaScript.
          await page.evaluate(
            '(s) => { const el = document.querySelector(s); if (!el) throw new Error("não encontrado: " + s); el.scrollIntoView({block: "center"}); el.click(); }',
            args: [target],
          );
        }
      case 'type':
        final target = selector();
        final text = '${input['text'] ?? ''}';
        if (input['clear'] != false) {
          await page.evaluate(
            '(s) => { const el = document.querySelector(s); if (!el) throw new Error("não encontrado: " + s); el.focus(); if ("value" in el) { el.value = ""; el.dispatchEvent(new Event("input", {bubbles: true})); } else if (el.isContentEditable) { el.textContent = ""; } }',
            args: [target],
          );
        }
        await page.type(target, text);
        if (input['submit'] == true) await page.keyboard.press(Key.enter);
      case 'press':
        final key = _key('${input['key'] ?? ''}');
        if (key == null) {
          await page.keyboard.type('${input['key'] ?? ''}');
        } else {
          await page.keyboard.press(key);
        }
      case 'select':
        await page.select(selector(), ['${input['value'] ?? ''}']);
      case 'hover':
        await page.hover(selector());
      case 'check':
        await page.evaluate(
          '(s, v) => { const el = document.querySelector(s); if (el && el.checked !== v) el.click(); }',
          args: [selector(), input['value'] != false],
        );
      case 'scroll':
        final dy = (input['dy'] as num?)?.toInt() ?? 600;
        if (input['ref'] != null || input['selector'] != null) {
          await page.evaluate(
            '(s) => document.querySelector(s)?.scrollIntoView({block: "center"})',
            args: [selector()],
          );
        } else {
          await page.evaluate('(dy) => window.scrollBy(0, dy)', args: [dy]);
        }
      case 'wait':
        final timeout = Duration(
          milliseconds: (input['timeout_ms'] as num?)?.toInt() ?? 15000,
        );
        if (input['selector'] != null) {
          await page.waitForSelector(
            '${input['selector']}',
            visible: true,
            timeout: timeout,
          );
        } else if (input['text'] != null) {
          await page.waitForFunction(
            '(t) => document.body && document.body.innerText.includes(t)',
            args: ['${input['text']}'],
            timeout: timeout,
          );
        } else {
          await Future<void>.delayed(
            Duration(milliseconds: (input['ms'] as num?)?.toInt() ?? 1000),
          );
        }
      case 'upload':
        final element = await page.$(selector());
        await element.uploadFile([File('${input['path'] ?? ''}')]);
      default:
        throw StateError(
          'Ação inválida "$action". Use click, type, press, select, hover, '
          'check, scroll, wait ou upload.',
        );
    }
    // Dá tempo para navegações/re-renderizações disparadas pela ação.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return _pageInfo(page, extra: {'ok': true, 'action': action});
  }

  static Key? _key(String name) => switch (name.toLowerCase()) {
    'enter' || 'return' => Key.enter,
    'tab' => Key.tab,
    'escape' || 'esc' => Key.escape,
    'backspace' => Key.backspace,
    'delete' || 'del' => Key.delete,
    'space' || ' ' => Key.space,
    'arrowup' || 'up' => Key.arrowUp,
    'arrowdown' || 'down' => Key.arrowDown,
    'arrowleft' || 'left' => Key.arrowLeft,
    'arrowright' || 'right' => Key.arrowRight,
    'pageup' => Key.pageUp,
    'pagedown' => Key.pageDown,
    'home' => Key.home,
    'end' => Key.end,
    'f5' => Key.f5,
    _ => null,
  };

  Future<Map<String, Object?>> _eval(Map<String, dynamic> input) async {
    final script = '${input['script'] ?? ''}'.trim();
    if (script.isEmpty) throw StateError('Informe o script.');
    // Aceita uma expressão ou um corpo de função com "return".
    final function = script.contains('return')
        ? 'async () => { $script }'
        : 'async () => ($script)';
    final result = await _page!.evaluate<Object?>(function);
    String text;
    try {
      text = jsonEncode(result);
    } catch (_) {
      text = jsonEncode('$result');
    }
    if (text.length > 20000) {
      return {'result_truncated': text.substring(0, 20000)};
    }
    return {'result': jsonDecode(text)};
  }

  Future<Map<String, Object?>> _screenshot(Map<String, dynamic> input) async {
    final page = _page!;
    final bytes = await page.screenshot(
      format: ScreenshotFormat.jpeg,
      quality: 70,
      fullPage: input['full_page'] == true,
    );
    return {
      ...await _pageInfo(page),
      'image_base64': base64Encode(bytes),
      'image_mime': 'image/jpeg',
    };
  }

  Future<Map<String, Object?>> _tabs(Map<String, dynamic> input) async {
    final browser = _browser!;
    final action = '${input['action'] ?? 'list'}';
    var pages = await browser.pages;
    switch (action) {
      case 'new':
        final page = await browser.newPage();
        await _attach(page);
        _page = page;
        final url = '${input['url'] ?? ''}'.trim();
        if (url.isNotEmpty) await _goto(page, url);
        await page.bringToFront();
      case 'select':
        final index = (input['index'] as num?)?.toInt() ?? 0;
        if (index < 0 || index >= pages.length) {
          throw StateError('Aba $index não existe.');
        }
        _page = pages[index];
        await _attach(_page!);
        await _page!.bringToFront();
      case 'close':
        final index = (input['index'] as num?)?.toInt();
        final page = index == null ? _page! : pages[index];
        await page.close();
        _attached.remove(page);
        pages = await browser.pages;
        if (pages.isEmpty) {
          _page = await browser.newPage();
          await _attach(_page!);
        } else if (page == _page) {
          _page = pages.last;
        }
    }
    pages = await browser.pages;
    return {
      'tabs': [
        for (var i = 0; i < pages.length; i++)
          {
            'index': i,
            'url': pages[i].url,
            'title': await _safeTitle(pages[i]),
            'current': pages[i] == _page,
          },
      ],
    };
  }

  static Future<String?> _safeTitle(Page page) async {
    try {
      return await page.title;
    } catch (_) {
      return null;
    }
  }
}
