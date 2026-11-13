import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:gestor_ufu/core/utils/debug_options.dart';
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

class PortalDiaryDownload {
  const PortalDiaryDownload({
    required this.term,
    required this.code,
    required this.name,
    required this.className,
    required this.diaryFieldId,
    required this.originFieldId,
    required this.typeFieldId,
  });

  final String term;
  final String code;
  final String name;
  final String className;
  final String diaryFieldId;
  final String originFieldId;
  final String typeFieldId;
}

class PortalDiaryDownloadResult {
  const PortalDiaryDownloadResult({
    required this.downloaded,
    required this.failed,
  });

  final int downloaded;
  final int failed;
}

/// Automação local em Dart via Chrome DevTools Protocol (Puppeteer).
/// O navegador abre visível e mantém um perfil separado para preservar a sessão.
class DiaryAutomationService {
  static final DiaryAutomationService instance = DiaryAutomationService();

  Browser? _browser;
  Page? _page;
  bool _saveMonitorActive = false;
  HttpServer? _debugServer;
  StreamSubscription<HttpRequest>? _debugServerSubscription;
  String? _debugToken;
  File? _debugBridgeInfoFile;
  String? _debugDiaryListUrl;

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
      await _startDebugBridge(log);
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
    final activePortFile = File(p.join(profileDir, 'DevToolsActivePort'));
    if (await activePortFile.exists()) {
      try {
        final activePort = (await activePortFile.readAsLines()).first.trim();
        if (int.tryParse(activePort) != null) {
          _browser = await puppeteer.connect(
            browserUrl: 'http://127.0.0.1:$activePort',
            defaultViewport: null,
          );
          final existingPages = await _browser!.pages;
          _page = existingPages.isEmpty
              ? await _browser!.newPage()
              : existingPages.first;
          await _page!.goto(url, wait: Until.domContentLoaded);
          await _tryPortalLogin(
            _page!,
            username: username,
            password: password,
            log: log,
          );
          await _page!.bringToFront();
          await _startDebugBridge(log);
          return _page!.url ?? url;
        }
      } catch (error) {
        log?.call(
          'NÃ£o consegui reconectar ao Edge jÃ¡ aberto; tentando iniciar uma nova sessÃ£o: $error',
        );
        _browser = null;
        _page = null;
      }
    }
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
    await _startDebugBridge(log);
    return _page!.url ?? url;
  }

  Future<void> _startDebugBridge(DiaryAutomationLog? log) async {
    if (!kDebugMode || !diaryAutomationDebugEnabled || _debugServer != null) {
      return;
    }
    final token = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _debugServer = server;
    _debugToken = token;
    _debugServerSubscription = server.listen((request) {
      unawaited(_handleDebugRequest(request));
    });
    final infoFile = File(
      p.join(Directory.systemTemp.path, 'GestorUFU', 'diary-debug-bridge.json'),
    );
    await infoFile.parent.create(recursive: true);
    await infoFile.writeAsString(
      jsonEncode({'port': server.port, 'token': token}),
      flush: true,
    );
    _debugBridgeInfoFile = infoFile;
    log?.call(
      'Canal local de diagnóstico do Edge ativo (somente debug; vinculado a localhost).',
    );
  }

  Future<void> _handleDebugRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final remoteAddress = request.connectionInfo?.remoteAddress;
      if (remoteAddress == null ||
          !remoteAddress.isLoopback ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $_debugToken') {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      final page = _page;
      if (!isConnected || page == null) {
        await _writeDebugJson(response, HttpStatus.serviceUnavailable, {
          'error': 'Edge/Puppeteer não está conectado.',
        });
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/status') {
        final state = await page.evaluate<Map<String, dynamic>>(
          _inspectPortalDiaryPageScript,
        );
        state['frames'] = [for (final frame in page.frames) frame.url];
        state['browserPages'] = [
          for (final browserPage in await _browser!.pages)
            await browserPage.evaluate<Map<String, dynamic>>(
              _inspectPortalDiaryPageScript,
            ),
        ];
        await _writeDebugJson(response, HttpStatus.ok, state);
        return;
      }
      if (request.method == 'GET' && path == '/api/help') {
        await _writeDebugJson(response, HttpStatus.ok, {
          'routes': {
            'GET /api/status': 'Estado e resumo da página atual do Edge.',
            'GET /api/screenshot': 'Captura PNG da página atual.',
            'GET /api/diaries':
                'Linhas encontradas e parâmetros do botão Baixar.',
            'POST /api/download-diario':
                'JSON {"index": N}; aciona a seta Baixar e salva o PDF de teste em pasta temporaria.',
            'POST /api/back-to-list': 'Volta à lista do Diário Eletrônico.',
          },
        });
        return;
      }
      if (request.method == 'GET' && path == '/api/screenshot') {
        response.headers.contentType = ContentType('image', 'png');
        response.headers.set('Cache-Control', 'no-store');
        response.add(await page.screenshot());
        await response.close();
        return;
      }
      if (request.method == 'GET' && path == '/api/diaries') {
        final diaries = await findPortalDiaryDownloads();
        await _writeDebugJson(response, HttpStatus.ok, {
          'count': diaries.length,
          'diaries': [
            for (var index = 0; index < diaries.length; index++)
              {
                'index': index,
                'term': diaries[index].term,
                'code': diaries[index].code,
                'name': diaries[index].name,
                'class': diaries[index].className,
                'arguments': [
                  diaries[index].diaryFieldId,
                  diaries[index].originFieldId,
                  diaries[index].typeFieldId,
                ],
              },
          ],
        });
        return;
      }
      if (request.method == 'POST' && path == '/api/download-diario') {
        final payload = await _readDebugJson(request);
        final index = payload['index'];
        if (index is! int) {
          await _writeDebugJson(response, HttpStatus.badRequest, {
            'error': 'Informe o indice do diario na lista atual.',
          });
          return;
        }
        final diaries = await findPortalDiaryDownloads();
        if (index < 0 || index >= diaries.length) {
          await _writeDebugJson(response, HttpStatus.badRequest, {
            'error': 'Indice fora da lista atual (${diaries.length} diarios).',
          });
          return;
        }
        final diary = diaries[index];
        final directory = Directory(
          p.join(Directory.systemTemp.path, 'GestorUFU', 'DiaryDebugDownloads'),
        );
        await directory.create(recursive: true);
        final before = await _listDownloadedFiles(directory);
        await _browser!.browser.setDownloadBehavior(
          'allow',
          downloadPath: directory.path,
        );
        var clicked = false;
        File? file;
        try {
          clicked = await _invokePortalDiaryDownload(
            page,
            diary,
            const Duration(seconds: 10),
          );
          if (clicked) {
            file = await _waitForDownloadedFile(
              directory,
              before,
              const Duration(seconds: 45),
            );
          }
        } finally {
          await _browser!.browser.setDownloadBehavior('default');
        }
        await _writeDebugJson(response, HttpStatus.ok, {
          'clicked': clicked,
          'downloaded': file != null,
          'index': index,
          'term': diary.term,
          'code': diary.code,
          'class': diary.className,
          'arguments': [
            diary.diaryFieldId,
            diary.originFieldId,
            diary.typeFieldId,
          ],
          'file': file?.path,
          'directory': directory.path,
        });
        return;
      }
      if (request.method == 'POST' && path == '/api/back-to-list') {
        final listUrl = _debugDiaryListUrl;
        if (listUrl == null || listUrl.isEmpty) {
          await _writeDebugJson(response, HttpStatus.conflict, {
            'error': 'Leia a lista de diários antes de voltar para ela.',
          });
          return;
        }
        await page.goto(listUrl, wait: Until.domContentLoaded);
        await _writeDebugJson(response, HttpStatus.ok, {'url': page.url});
        return;
      }
      await _writeDebugJson(response, HttpStatus.notFound, {
        'error': 'Rota de diagnóstico inexistente.',
      });
    } catch (error) {
      await _writeDebugJson(response, HttpStatus.internalServerError, {
        'error': '$error',
      });
    }
  }

  Future<Map<String, dynamic>> _readDebugJson(HttpRequest request) async {
    if (request.contentLength > 4096) {
      throw const HttpException('Corpo da requisição excede 4 KB.');
    }
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return <String, dynamic>{};
    final value = jsonDecode(text);
    if (value is! Map) {
      throw const FormatException('JSON precisa ser um objeto.');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> _writeDebugJson(
    HttpResponse response,
    int statusCode,
    Object body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    response.write(jsonEncode(body));
    await response.close();
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
    try {
      if (await page.evaluate<bool>(_isAuthenticatedPortalPageScript)) {
        log?.call('Sessão autenticada do Portal do Docente detectada.');
        return;
      }
    } catch (_) {
      // The page may still be navigating; continue with the normal login check.
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

  Future<List<PortalDiaryDownload>> findPortalDiaryDownloads() async {
    final page = _page;
    if (!isConnected || page == null) {
      throw StateError(
        'Abra o Portal do Docente e entre em Diário Eletrônico.',
      );
    }
    final rows = await page.evaluate<List<dynamic>>(
      _collectPortalDiaryDownloadsScript,
    );
    if (rows.isEmpty) {
      throw StateError(
        'Não encontrei a tabela com as colunas Ano/Período e Baixar. Abra a lista de Diários de Classe no Portal e tente novamente.',
      );
    }
    if (rows.first is List && (rows.first as List).first == '__error__') {
      final first = rows.first as List;
      final reason = first.length > 1 ? first[1].toString() : null;
      throw StateError(reason ?? 'Não foi possível ler a tabela de diários.');
    }
    final diaries = rows
        .whereType<List<dynamic>>()
        .where((row) => row.length >= 7)
        .map((row) {
          return PortalDiaryDownload(
            term: row[0].toString(),
            code: row[1].toString(),
            name: row[2].toString(),
            className: row[3].toString(),
            diaryFieldId: row[4].toString(),
            originFieldId: row[5].toString(),
            typeFieldId: row[6].toString(),
          );
        })
        .toList();
    if (diaries.isNotEmpty) _debugDiaryListUrl = page.url;
    return diaries;
  }

  Future<PortalDiaryDownloadResult> downloadPortalDiaries(
    List<PortalDiaryDownload> diaries,
    String directoryPath, {
    required DiaryAutomationLog log,
  }) async {
    final page = _page;
    if (!isConnected || page == null) {
      throw StateError('A sessão do Portal do Docente não está conectada.');
    }
    final listUrl = page.url;
    if (listUrl == null || listUrl.isEmpty) {
      throw StateError(
        'Não consegui identificar a página da lista de diários.',
      );
    }
    final outputDirectory = Directory(directoryPath);
    await outputDirectory.create(recursive: true);
    await _browser!.browser.setDownloadBehavior(
      'allow',
      downloadPath: outputDirectory.path,
    );
    var downloaded = 0;
    var failed = 0;
    try {
      for (var index = 0; index < diaries.length; index++) {
        final diary = diaries[index];
        final detail = '${diary.term} · ${diary.code} · ${diary.className}';
        log('Baixando ${index + 1}/${diaries.length}: $detail.');
        try {
          final pdfFilesBefore = await _listDownloadedFiles(outputDirectory);
          final clicked = await _invokePortalDiaryDownload(
            page,
            diary,
            const Duration(seconds: 20),
          );
          if (!clicked) {
            failed++;
            log('Não localizei a ação baixarDiario para $detail.');
            continue;
          }
          log('Baixar acionado; aguardando o PDF direto do Portal.');
          final newFile = await _waitForDownloadedFile(
            outputDirectory,
            pdfFilesBefore,
            const Duration(seconds: 45),
          );
          if (newFile == null) {
            failed++;
            log('O Portal não concluiu o download de $detail em 45 segundos.');
            continue;
          }
          downloaded++;
          log('Arquivo original salvo: ${p.basename(newFile.path)}.');
        } catch (error) {
          failed++;
          log('Falha ao baixar $detail: $error');
        } finally {
          if (page.url != listUrl) {
            try {
              await page.goto(listUrl, wait: Until.domContentLoaded);
              await Future<void>.delayed(const Duration(milliseconds: 500));
            } catch (error) {
              log('Nao consegui voltar a lista para continuar: $error');
            }
          }
        }
      }
    } finally {
      await _browser!.browser.setDownloadBehavior('default');
    }
    return PortalDiaryDownloadResult(downloaded: downloaded, failed: failed);
  }

  Future<Map<String, DateTime>> _listDownloadedFiles(
    Directory directory,
  ) async {
    final files = <String, DateTime>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) files[entity.path] = await entity.lastModified();
    }
    return files;
  }

  Future<bool> _invokePortalDiaryDownload(
    Page page,
    PortalDiaryDownload diary,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final position = await page.evaluate<List<dynamic>>(
          _invokePortalDiaryDownloadScript,
          args: [diary.diaryFieldId, diary.originFieldId, diary.typeFieldId],
        );
        if (position.length >= 2) {
          await page.mouse.click(
            Point(
              (position[0] as num).toDouble(),
              (position[1] as num).toDouble(),
            ),
          );
          return true;
        }
      } catch (_) {
        // Aguarda a lista ficar pronta e tenta novamente o clique exato da linha.
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  Future<File?> _waitForDownloadedFile(
    Directory directory,
    Map<String, DateTime> existingFiles,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final candidates = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            entity.path.toLowerCase().endsWith('.crdownload') ||
            entity.path.toLowerCase().endsWith('.tmp')) {
          continue;
        }
        final previousModified = existingFiles[entity.path];
        final currentModified = await entity.lastModified();
        if (previousModified == null ||
            currentModified.isAfter(previousModified)) {
          candidates.add(entity);
        }
      }
      if (candidates.isNotEmpty) {
        candidates.sort(
          (left, right) =>
              right.lastModifiedSync().compareTo(left.lastModifiedSync()),
        );
        return candidates.first;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return null;
  }

  Future<void> close() async {
    final subscription = _debugServerSubscription;
    _debugServerSubscription = null;
    await subscription?.cancel();
    final debugServer = _debugServer;
    _debugServer = null;
    await debugServer?.close(force: true);
    _debugToken = null;
    final infoFile = _debugBridgeInfoFile;
    _debugBridgeInfoFile = null;
    if (infoFile != null && await infoFile.exists()) {
      await infoFile.delete();
    }
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
    const profileName = 'EdgeDiarioProfile';
    if (localAppData == null || localAppData.isEmpty) {
      return p.join(Directory.systemTemp.path, 'GestorUFU', profileName);
    }
    return p.join(localAppData, 'GestorUFU', profileName);
  }
}

const _isAuthenticatedPortalPageScript = r'''() => {
  const body = (document.body?.innerText || '').normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const visiblePassword = Array.from(document.querySelectorAll('input[type="password"]'))
    .some(element => !!element.offsetParent);
  return !visiblePassword && (body.includes('diarios de classe') || body.includes('sair'));
}''';

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

const _collectPortalDiaryDownloadsScript = r'''() => {
  const norm = value => (value || '').toLowerCase().normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, ' ').trim();
  const termPattern = /(\d{4})\s*[\/-]\s*([12])/;
  const tables = Array.from(document.querySelectorAll('table'));
  const downloadArgs = action => {
    const onclick = action?.getAttribute('onclick') || '';
    const match = onclick.match(/baixarDiario\s*\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*\)/i);
    return match ? match.slice(1, 4) : null;
  };
  const actionsWithDiaryId = Array.from(document.querySelectorAll('a[onclick],button[onclick],[onclick]'))
    .filter(action => downloadArgs(action));
  const diagnostics = [];
  for (const table of tables) {
    const tableRows = Array.from(table.querySelectorAll('tr'));
    const rowCells = row => Array.from(row.children)
      .filter(cell => cell.tagName === 'TH' || cell.tagName === 'TD');
    const headerRow = tableRows.find(row => {
      const cells = rowCells(row).map(cell => norm(cell.innerText || cell.textContent));
      return cells.some(cell => /ano\s*\/?\s*periodo/.test(cell)) &&
        cells.some(cell => cell === 'baixar');
    });
    if (!headerRow) continue;
    const headers = rowCells(headerRow)
      .map(cell => norm(cell.innerText || cell.textContent));
    const termIndex = headers.findIndex(header => /ano\s*\/?\s*periodo/.test(header));
    const downloadIndex = headers.findIndex(header => /^baixar$/.test(header));
    if (termIndex < 0 || downloadIndex < 0) {
      diagnostics.push(headers.join(' | ') || norm(headerRow.innerText));
      continue;
    }
    const rows = tableRows.filter(row => row !== headerRow && rowCells(row).length > downloadIndex);
    const output = [];
    for (let rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      const row = rows[rowIndex];
      const cells = rowCells(row);
      if (cells.length <= Math.max(termIndex, downloadIndex)) continue;
      const termText = (cells[termIndex].innerText || cells[termIndex].textContent || '').trim();
      const match = termText.match(termPattern);
      if (!match) continue;
      const downloadCell = cells[downloadIndex];
      const action = downloadCell.querySelector('a[onclick],button[onclick],[onclick]');
      const args = downloadArgs(action);
      if (!args) continue;
      const code = (cells[headers.findIndex(h => h === 'codigo')]?.innerText || '').trim();
      const name = (cells[headers.findIndex(h => h.includes('nome da disciplina'))]?.innerText || '').trim();
      const className = (cells[headers.findIndex(h => h === 'turma')]?.innerText || '').trim();
      output.push([`${match[1]}_${match[2]}`, code, name, className, ...args]);
    }
    if (output.length) return output;
    diagnostics.push(`Tabela com cabeçalho identificado, mas sem botão Baixar reconhecido. Cabeçalhos: ${headers.join(' | ')}`);
  }
  if (diagnostics.length) {
    return [['__error__', `Encontrei tabelas, mas não consegui reconhecer as colunas Ano/Período e Baixar. Cabeçalhos lidos: ${diagnostics.join(' || ')}`]];
  }
  return [['__error__', `Não encontrei linhas baixáveis. Tabelas: ${tables.length}; ações com ID de diário: ${actionsWithDiaryId.length}. Confirme que a página terminou de carregar.`]];
}''';

const _invokePortalDiaryDownloadScript =
    r'''(diaryFieldId, originFieldId, typeFieldId) => {
  const norm = value => (value || '').toLowerCase().normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, ' ').trim();
  const wanted = [diaryFieldId, originFieldId, typeFieldId];
  const tables = Array.from(document.querySelectorAll('table'));
  for (const table of tables) {
    const rows = Array.from(table.querySelectorAll('tr'));
    const cellsOf = row => Array.from(row.children)
      .filter(cell => cell.tagName === 'TH' || cell.tagName === 'TD');
    const header = rows.find(row => {
      const labels = cellsOf(row).map(cell => norm(cell.innerText || cell.textContent));
      return labels.some(label => /ano\s*\/?\s*periodo/.test(label)) &&
        labels.some(label => label === 'baixar');
    });
    if (!header) continue;
    const labels = cellsOf(header).map(cell => norm(cell.innerText || cell.textContent));
    const downloadIndex = labels.findIndex(label => label === 'baixar');
    for (const row of rows) {
      if (row === header) continue;
      const cell = cellsOf(row)[downloadIndex];
      if (!cell) continue;
      const action = Array.from(cell.querySelectorAll('a[onclick],button[onclick],[onclick]'))
        .find(element => {
      const match = (element.getAttribute('onclick') || '').match(
        /baixarDiario\s*\(\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*\)/i);
      return match && match.slice(1, 4).every((value, index) => value === wanted[index]);
        });
      if (action) {
        action.scrollIntoView({behavior: 'auto', block: 'center', inline: 'nearest'});
        const rect = action.getBoundingClientRect();
        if (!rect.width || !rect.height) return [];
        return [rect.left + rect.width / 2, rect.top + rect.height / 2];
      }
    }
  }
  return [];
}''';

const _inspectPortalDiaryPageScript = r'''() => {
  const norm = value => (value || '').toLowerCase().normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, ' ').trim();
  const tables = Array.from(document.querySelectorAll('table'));
  const summaries = tables.map((table, tableIndex) => {
    const rows = Array.from(table.querySelectorAll('tr'));
    const cellsOf = row => Array.from(row.children)
      .filter(cell => cell.tagName === 'TH' || cell.tagName === 'TD');
    const header = rows.find(row => {
      const labels = cellsOf(row).map(cell => norm(cell.innerText || cell.textContent));
      return labels.some(label => /ano\s*\/?\s*periodo/.test(label)) &&
        labels.some(label => label === 'baixar');
    });
    if (!header) return {tableIndex, rowCount: rows.length, headers: []};
    const headers = cellsOf(header).map(cell => (cell.innerText || cell.textContent || '').trim());
    const labels = headers.map(norm);
    const downloadIndex = labels.findIndex(label => label === 'baixar');
    const rowsWithButtons = rows.filter(row => {
      if (row === header) return false;
      const cell = cellsOf(row)[downloadIndex];
      return !!cell?.querySelector('[onclick]');
    });
    return {
      tableIndex,
      headers,
      dataRowCount: rows.filter(row => row !== header).length,
      baixarRowsWithOnclick: rowsWithButtons.length,
      sample: rowsWithButtons.slice(0, 25).map(row => {
        const cells = cellsOf(row);
        const cell = cells[downloadIndex];
        const action = cell?.querySelector('[onclick]');
        const image = action?.querySelector('img');
        return {
          row: (row.innerText || row.textContent || '').trim(),
          onclick: action?.getAttribute('onclick') || null,
          image: image?.getAttribute('src') || null,
          alt: image?.getAttribute('alt') || null,
          href: action?.getAttribute('href') || null,
          rect: action ? (() => {
            const rect = action.getBoundingClientRect();
            return {x: rect.x, y: rect.y, width: rect.width, height: rect.height};
          })() : null,
        };
      }),
    };
  });
  const buttons = Array.from(document.querySelectorAll(
    'button,a,[role="button"],input[type="button"],input[type="submit"]'))
    .filter(element => {
      const rect = element.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    })
    .map(element => ({
      text: (element.innerText || element.textContent || element.value || '').trim(),
      title: element.title || '',
      alt: element.querySelector('img')?.alt || element.alt || '',
      onclick: element.getAttribute('onclick') || '',
    }))
    .filter(item => /baixar|voltar/i.test([item.text, item.title, item.alt, item.onclick].join(' ')))
    .slice(0, 30);
  return {
    url: location.href,
    title: document.title,
    headings: Array.from(document.querySelectorAll('h1,h2,h3'))
      .map(item => (item.innerText || item.textContent || '').trim()).filter(Boolean).slice(0, 12),
    viewport: {width: innerWidth, height: innerHeight, devicePixelRatio},
    baixarDiarioFunction: typeof window.baixarDiario === 'function'
      ? String(window.baixarDiario).slice(0, 3000) : null,
    tables: summaries,
    buttons,
    bodyExcerpt: (document.body?.innerText || '').trim().slice(0, 4000),
  };
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
