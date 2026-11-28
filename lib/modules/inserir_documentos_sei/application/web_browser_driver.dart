import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:puppeteer/puppeteer.dart';

import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/browser_service.dart';

abstract class WebBrowserDriver {
  Future<void> open(WebProcess process);
  Future<void> navigate(String url);
  Future<PickedWebElement> pick(bool Function() cancelled);
  Future<String?> perform(WebStep step, String value);
  Future<void> capture(String directory, String name);
  Future<void> startRecording();
  Future<void> stopRecording(String directory);
}

class PuppeteerWebBrowserDriver implements WebBrowserDriver {
  PuppeteerWebBrowserDriver({this.pageFactory});
  final Future<Page> Function(WebProcess)? pageFactory;
  final _pages = <String, Page>{};
  Page? _current;
  StreamSubscription<Request>? _requests;
  StreamSubscription<Response>? _responses;
  final _network = <Map<String, Object?>>[];

  Page get _page =>
      _current ??
      (throw const CommandException(
        'navegador_fechado',
        'Abra o site do processo.',
      ));

  @override
  Future<void> open(WebProcess process) async {
    validateWebUrl(process.url);
    var page = _pages[process.id];
    if (page == null || page.isClosed) {
      final safeId = process.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      if (pageFactory != null) {
        page = await pageFactory!(process);
      } else {
        final browser = await BrowserService.open(
          profileDir: BrowserService.localProfile('AutomacaoWeb_$safeId'),
        );
        page = await BrowserService.firstPage(browser);
      }
      _pages[process.id] = page;
    }
    _current = page;
    if (page.url == null || page.url == 'about:blank') {
      await navigate(process.url);
    }
    await page.bringToFront();
  }

  @override
  Future<void> navigate(String url) async {
    validateWebUrl(url);
    await _page.goto(
      url,
      wait: Until.domContentLoaded,
      timeout: const Duration(seconds: 45),
    );
  }

  List<int> _pathFor(Frame frame) {
    final path = <int>[];
    var current = frame;
    while (current.parentFrame != null) {
      final parent = current.parentFrame!;
      path.insert(0, parent.childFrames.indexOf(current));
      current = parent;
    }
    return path;
  }

  @override
  Future<PickedWebElement> pick(bool Function() cancelled) async {
    final script = await rootBundle.loadString(
      'assets/web_automation/picker.js',
    );
    final armed = <Frame>{};
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    await _page.bringToFront();
    try {
      while (DateTime.now().isBefore(deadline) && !cancelled()) {
        for (final frame in _page.frames) {
          try {
            if (armed.add(frame)) await frame.evaluate(script);
            final value = await frame.evaluate<Map?>(
              '() => window.__gestorWebPicker?.result || null',
            );
            if (value == null) continue;
            if (value['cancelled'] == true) {
              throw const CommandException('cancelado', 'Seleção cancelada.');
            }
            return PickedWebElement(
              selector: value['selector'] as String,
              label: value['label'] as String,
              tag: value['tag'] as String,
              inputType: value['inputType'] as String,
              role: value['role'] as String? ?? '',
              framePath: _pathFor(frame),
              options: (value['options'] as List)
                  .map((o) => Map<String, String>.from(o as Map))
                  .toList(),
            );
          } on CommandException {
            rethrow;
          } catch (_) {
            // Um quadro pode ser removido enquanto a página carrega.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
      throw const CommandException('cancelado', 'Seleção encerrada.');
    } finally {
      for (final frame in armed) {
        try {
          await frame.evaluate('() => window.__gestorWebPicker?.cleanup()');
        } catch (_) {}
      }
    }
  }

  Frame _frame(WebStep step) {
    var frame = _page.mainFrame;
    for (final index in step.framePath) {
      if (index >= frame.childFrames.length) {
        throw const CommandException(
          'quadro_ausente',
          'O quadro selecionado não existe nesta página. Selecione o componente novamente.',
        );
      }
      frame = frame.childFrames[index];
    }
    return frame;
  }

  Future<String> _resolveSelector(
    Frame frame,
    String raw,
    Duration timeout,
  ) async {
    final watch = Stopwatch()..start();
    while (true) {
      try {
        return await frame.evaluate<String>(
          r'''raw => {
          const id = raw.startsWith('id=') ? raw.slice(3) : raw;
          return document.getElementById(id) ? '#' + CSS.escape(id) : raw;
        }''',
          args: [raw],
        );
      } catch (error) {
        final message = error.toString().toLowerCase();
        if (watch.elapsed >= timeout ||
            !(message.contains('context was destroyed') ||
                message.contains('cannot find context'))) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _click(Frame frame, ElementHandle element) async {
    final navigation = frame
        .waitForNavigation(
          timeout: const Duration(seconds: 2),
          wait: Until.domContentLoaded,
        )
        .then<void>((_) {})
        .catchError((_) {});
    // O clique ocorre uma única vez; somente a espera pela navegação é tolerante.
    await element.click();
    await Future.any<void>([
      navigation,
      Future<void>.delayed(const Duration(milliseconds: 450)),
    ]);
  }

  @override
  Future<String?> perform(WebStep step, String value) async {
    final timeout = Duration(seconds: step.timeoutSeconds);
    if (step.action == WebAction.navigate) {
      await navigate(value);
      return null;
    }
    if (step.action == WebAction.pause) {
      final seconds = double.tryParse(value.replaceAll(',', '.'));
      if (seconds == null || seconds < 0 || seconds > 60) {
        throw const CommandException(
          'pausa_invalida',
          'A pausa precisa estar entre 0 e 60 segundos.',
        );
      }
      await Future<void>.delayed(
        Duration(milliseconds: (seconds * 1000).round()),
      );
      return null;
    }
    final frame = _frame(step);
    final selector = await _resolveSelector(frame, step.selector, timeout);
    if (step.action == WebAction.waitText) {
      final handle = await frame.waitForFunction(
        '(selector, text) => [...document.querySelectorAll(selector)].some(el => el.getClientRects().length && getComputedStyle(el).visibility !== "hidden" && (el.innerText || el.textContent || "").includes(text))',
        args: [selector, value],
        timeout: timeout,
      );
      await handle.dispose();
      return null;
    }
    // Google Forms também mantém inputs ocultos com o mesmo identificador.
    // Resolva o componente visível entre todos os resultados do seletor.
    final handle = await frame.waitForFunction(
      r'''(selector, allowHidden, editable) => [...document.querySelectorAll(selector)].find(el => {
        if (allowHidden) return true;
        const style = getComputedStyle(el);
        return el.getClientRects().length > 0 && style.visibility !== 'hidden' && style.visibility !== 'collapse' && el.type !== 'hidden'
          && (!editable || (!el.disabled && !el.readOnly && el.getAttribute('aria-disabled') !== 'true'));
      }) || false''',
      args: [
        selector,
        step.action == WebAction.upload,
        step.action == WebAction.fill,
      ],
      timeout: timeout,
    );
    final element = handle.asElement;
    if (element == null) {
      await handle.dispose();
      throw const CommandException(
        'elemento_ausente',
        'Componente HTML não encontrado.',
      );
    }
    try {
      switch (step.action) {
        case WebAction.fill:
          await element.evaluate(r'''el => {
            el.focus();
            if (el.isContentEditable) { el.textContent = ''; }
            else {
              const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
              if (!setter) throw new Error('O componente não é um campo de texto.');
              setter.call(el, '');
            }
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
          }''');
          if (value.isNotEmpty) await element.type(value);
          final filled = await element.evaluate<bool>(
            '(el, value) => (el.isContentEditable ? el.textContent : el.value) === value',
            args: [value],
          );
          if (filled != true) {
            throw const CommandException(
              'preenchimento_incompleto',
              'O campo não recebeu o valor completo. O processo foi interrompido antes das próximas etapas.',
            );
          }
        case WebAction.click:
          if (value.isEmpty) {
            await _click(frame, element);
          } else {
            final buttons = await frame.$$(selector);
            var found = false;
            try {
              for (final button in buttons) {
                final visible = await button.evaluate<bool>(
                  'el => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden"',
                );
                if (visible != true) continue;
                final label = await button.evaluate<String>(
                  'el => (el.innerText || el.value || el.textContent || "").trim()',
                );
                if (label == value.trim()) {
                  await _click(frame, button);
                  found = true;
                  break;
                }
              }
            } finally {
              for (final button in buttons) {
                await button.dispose();
              }
            }
            if (!found) {
              throw CommandException(
                'elemento_ausente',
                'Não encontrei o botão com o texto "$value".',
              );
            }
          }
        case WebAction.select:
          final option = await element.evaluate<String?>(
            '(el, value) => [...el.options].find(o => o.value === value || o.text.trim() === value)?.value ?? null',
            args: [value],
          );
          if (option == null) {
            throw CommandException(
              'opcao_ausente',
              'Opção "$value" não encontrada.',
            );
          }
          await element.select([option]);
        case WebAction.check:
        case WebAction.uncheck:
          final checked = await element.evaluate<bool>(
            'el => el.checked ?? (el.getAttribute("aria-checked") === "true")',
          );
          if (checked != (step.action == WebAction.check)) {
            await _click(frame, element);
          }
        case WebAction.read:
          return await element.evaluate<String>(
            'el => (el.innerText || el.textContent || el.value || "").trim()',
          );
        case WebAction.upload:
          final file = File(value);
          if (!await file.exists()) {
            throw const CommandException(
              'arquivo_nao_encontrado',
              'Arquivo para anexar não encontrado.',
            );
          }
          await element.uploadFile([file]);
        case WebAction.wait:
          break;
        case WebAction.waitText:
        case WebAction.navigate:
        case WebAction.pause:
          break;
      }
    } finally {
      await element.dispose();
    }
    return null;
  }

  @override
  Future<void> capture(String directory, String name) async {
    await Directory(directory).create(recursive: true);
    await File(
      p.join(directory, '$name.html'),
    ).writeAsString(await _page.content ?? '', encoding: utf8);
    await File(
      p.join(directory, '$name.url'),
    ).writeAsString(_page.url ?? '', encoding: utf8);
    await File(
      p.join(directory, '$name.png'),
    ).writeAsBytes(await _page.screenshot());
  }

  String _urlForLog(String value) {
    final uri = Uri.tryParse(value);
    return uri == null ? '' : '${uri.scheme}://${uri.host}${uri.path}';
  }

  @override
  Future<void> startRecording() async {
    await _requests?.cancel();
    await _responses?.cancel();
    _network.clear();
    _requests = _page.onRequest.listen((r) {
      if (_network.length < 5000) {
        _network.add({
          'type': 'request',
          'method': r.method,
          'url': _urlForLog(r.url),
        });
      }
    });
    _responses = _page.onResponse.listen((r) {
      if (_network.length < 5000) {
        _network.add({
          'type': 'response',
          'status': r.status,
          'url': _urlForLog(r.url),
        });
      }
    });
  }

  @override
  Future<void> stopRecording(String directory) async {
    await _requests?.cancel();
    await _responses?.cancel();
    _requests = null;
    _responses = null;
    await File(
      p.join(directory, 'rede.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(_network));
    _network.clear();
  }
}
