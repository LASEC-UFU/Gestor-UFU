import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:gestor_ufu/domain/entities/moodle_entities.dart';

class MoodleDatasource {
  // ── Sessão web para chamadas AJAX ──────────────────────────────────────
  // Funções como core_update_inplace_editable são marcadas como 'ajax'
  // no Moodle e NÃO estão em nenhum serviço web externo por padrão.
  //
  // Estratégia: gerenciamento 100% MANUAL de cookies.
  // dart:io HttpClient tem um cookie jar interno, mas ele pode falhar
  // silenciosamente com cookies SameSite, load balancers, etc.
  // Aqui capturamos TODOS os Set-Cookie de TODA resposta e reenviamos
  // manualmente em toda requisição subsequente.
  final Map<String, String> _cookies = {};
  String? _sesskey;
  String? _sessionError;
  String? _diagInfo; // Passos de diagnóstico para depuração

  // Credenciais guardadas em memória para recriar sessão quando expirar
  String? _loginUsername;
  String? _loginPassword;

  /// Define credenciais para estabelecimento de sessão AJAX sob demanda.
  /// Chamado ao carregar credencial salva (que inclui a senha).
  void setCredentials(String username, String password) {
    _loginUsername = username;
    _loginPassword = password;
  }

  Future<Map<String, dynamic>> _callWs(
    String baseUrl,
    String token,
    String function, {
    Map<String, String> params = const {},
    bool usePost = false,
  }) async {
    final baseParams = {
      'wstoken': token,
      'wsfunction': function,
      'moodlewsrestformat': 'json',
    };

    late final http.Response response;
    if (usePost) {
      final uri = Uri.parse('$baseUrl/webservice/rest/server.php');
      response = await http.post(uri, body: {...baseParams, ...params});
    } else {
      final uri = Uri.parse(
        '$baseUrl/webservice/rest/server.php',
      ).replace(queryParameters: {...baseParams, ...params});
      response = await http.get(uri);
    }
    if (response.statusCode != 200) {
      throw MoodleException('HTTP ${response.statusCode}');
    }
    final body = json.decode(response.body);
    if (body is Map && body.containsKey('exception')) {
      throw MoodleException(body['message'] ?? body['exception']);
    }
    return {'data': body};
  }

  /// Serviços externos tentados na ordem: primeiro um serviço personalizado
  /// com permissões de escrita, depois o serviço mobile padrão.
  static const _services = [
    'config_moodle_service', // Serviço externo criado pelo admin com funções de edição
    'moodle_mobile_app', // Serviço padrão (somente leitura em muitos Moodles)
  ];

  /// Indica se a sessão AJAX foi estabelecida com sucesso.
  bool get hasAjaxSession =>
      _cookies.containsKey('MoodleSession') && _sesskey != null;

  /// Indica se é possível tentar AJAX (sessão ativa OU credenciais para criá-la).
  /// No ambiente web, AJAX via HttpClient não é suportado.
  bool get _canAttemptAjax =>
      !kIsWeb && (hasAjaxSession || _loginUsername != null);

  /// Motivo da falha na sessão AJAX (null se sucesso).
  String? get sessionError => _sessionError;

  // ── Gerenciamento manual de cookies ────────────────────────────────────

  /// Extrai TODOS os cookies de uma resposta HTTP via headers raw.
  /// Não depende de dart:io Cookie parser (que pode falhar com SameSite etc).
  void _storeCookies(io.HttpClientResponse resp) {
    final headers = resp.headers['set-cookie'];
    if (headers == null) return;
    for (final header in headers) {
      final idx = header.indexOf('=');
      if (idx > 0) {
        final name = header.substring(0, idx).trim();
        final rest = header.substring(idx + 1);
        final semiIdx = rest.indexOf(';');
        final value = (semiIdx >= 0 ? rest.substring(0, semiIdx) : rest).trim();
        _cookies[name] = value;
      }
    }
  }

  /// Aplica todos os cookies armazenados em uma requisição HTTP.
  void _applyCookies(io.HttpClientRequest req) {
    if (_cookies.isNotEmpty) {
      req.headers.set(
        'Cookie',
        _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
  }

  /// Invalida a sessão AJAX atual.
  void _invalidateSession([String? reason]) {
    _cookies.clear();
    _sesskey = null;
    if (reason != null) _sessionError = reason;
  }

  /// Extrai a sesskey embutida no HTML de uma página Moodle.
  String? _findSesskey(String body) {
    // "sesskey":"abc123" (em blocos JS)
    var match = RegExp(r'"sesskey"\s*:\s*"([^"]+)"').firstMatch(body);
    // name="sesskey" value="abc123" (hidden fields)
    match ??= RegExp(r'name="sesskey"[^>]*value="([^"]+)"').firstMatch(body);
    // value="abc123" name="sesskey" (ordem invertida)
    match ??= RegExp(r'value="([^"]+)"[^>]*name="sesskey"').firstMatch(body);
    return match?.group(1);
  }

  /// Estabelece sessão web via formulário de login HTML do Moodle.
  /// Gerenciamento 100% manual de cookies — sem depender do cookie jar.
  /// No ambiente web (Flutter Web), esta operação não é suportada devido a
  /// restrições de CORS e acesso a cookies.
  Future<void> _establishSession(
    String baseUrl,
    String username,
    String password,
  ) async {
    if (kIsWeb) {
      _sessionError = 'Sessão AJAX não suportada no navegador';
      return;
    }
    _invalidateSession();
    _sessionError = null;
    _diagInfo = '';

    // Guardar credenciais para retry automático
    _loginUsername = username;
    _loginPassword = password;

    final client = io.HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;

    try {
      // 1. GET na página de login para obter o logintoken (CSRF)
      final getReq = await client.getUrl(Uri.parse('$baseUrl/login/index.php'));
      final getResp = await getReq.close();
      _storeCookies(getResp);
      final loginHtml = await getResp.transform(utf8.decoder).join();

      _diagInfo =
          'GET login:${getResp.statusCode} cookies:[${_cookies.keys.join(",")}]';

      // Aceitar múltiplos formatos do campo logintoken
      final tokenMatch = RegExp(
        r'name="logintoken"[^>]*value="([^"]+)"',
      ).firstMatch(loginHtml);
      final token =
          tokenMatch?.group(1) ??
          RegExp(
            r'value="([^"]+)"[^>]*name="logintoken"',
          ).firstMatch(loginHtml)?.group(1);

      if (token == null) {
        _sessionError = 'logintoken não encontrado. $_diagInfo';
        _cookies.clear();
        return;
      }

      // 2. POST no formulário de login com TODOS os cookies da etapa 1
      final postReq = await client.postUrl(
        Uri.parse('$baseUrl/login/index.php'),
      );
      postReq.followRedirects = false;
      _applyCookies(
        postReq,
      ); // Envia cookies do GET (inclui MoodleSession inicial + load balancer)
      postReq.headers.contentType = io.ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      final formBody = Uri(
        queryParameters: {
          'username': username,
          'password': password,
          'logintoken': token,
        },
      ).query;
      postReq.write(formBody);
      final postResp = await postReq.close();
      _storeCookies(
        postResp,
      ); // Captura novo MoodleSession (pós session_regenerate_id)
      await postResp.drain<void>();

      _diagInfo =
          '$_diagInfo → POST login:${postResp.statusCode} cookies:[${_cookies.keys.join(",")}]';

      if (postResp.statusCode == 200) {
        _sessionError = 'Login falhou (HTTP 200). $_diagInfo';
        _cookies.clear();
        return;
      }

      // 3. Seguir redirect MANUALMENTE com TODOS os cookies
      final location = postResp.headers.value('location');
      final targetUrl = (location != null && location.startsWith('http'))
          ? location
          : '$baseUrl${location ?? '/my/'}';

      final pageReq = await client.getUrl(Uri.parse(targetUrl));
      _applyCookies(pageReq); // Envia cookies atualizados (pós-login)
      final pageResp = await pageReq.close();
      _storeCookies(pageResp); // Captura qualquer cookie renovado
      final dashHtml = await pageResp.transform(utf8.decoder).join();

      _sesskey = _findSesskey(dashHtml);

      _diagInfo =
          '$_diagInfo → GET redirect:${pageResp.statusCode} cookies:[${_cookies.keys.join(",")}] sesskey:${_sesskey != null ? "OK" : "NULL"}';

      if (_sesskey == null) {
        _sessionError = 'sesskey não encontrada. $_diagInfo';
        _cookies.clear();
        return;
      }
    } catch (e) {
      _sessionError = '$e. $_diagInfo';
      _cookies.clear();
    } finally {
      client.close(); // Fecha o client — cookies são gerenciados manualmente
    }
  }

  /// Chama uma função AJAX do Moodle usando a sessão web.
  /// Cria um HttpClient novo a cada chamada e envia cookies manualmente.
  Future<Map<String, dynamic>> _callAjax(
    String baseUrl,
    String function,
    Map<String, dynamic> args,
  ) async {
    // Se não tem sessão mas tem credenciais, tenta criar uma sob demanda
    if (!hasAjaxSession && _loginUsername != null) {
      await _establishSession(baseUrl, _loginUsername!, _loginPassword!);
    }
    if (!hasAjaxSession) {
      throw MoodleException(_sessionError ?? 'Sessão AJAX não estabelecida');
    }

    try {
      return await _doAjaxCall(baseUrl, function, args);
    } catch (e) {
      // Se erro de sessão, tenta recriar e chamar novamente (1 retry)
      if (_isSessionExpiredError(e) && _loginUsername != null) {
        await _establishSession(baseUrl, _loginUsername!, _loginPassword!);
        if (hasAjaxSession) {
          return await _doAjaxCall(baseUrl, function, args);
        }
      }
      rethrow;
    }
  }

  /// Verifica se o erro indica sessão expirada/inválida.
  bool _isSessionExpiredError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('sessão') ||
        msg.contains('session') ||
        msg.contains('expired') ||
        msg.contains('expirou') ||
        msg.contains('finalizada') ||
        msg.contains('servicenotavailable');
  }

  /// Executa a chamada AJAX real (sem retry).
  Future<Map<String, dynamic>> _doAjaxCall(
    String baseUrl,
    String function,
    Map<String, dynamic> args,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/lib/ajax/service.php'
      '?sesskey=$_sesskey&info=$function',
    );

    // Novo client a cada chamada — cookies são enviados manualmente
    final client = io.HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = io.ContentType.json;
      _applyCookies(
        request,
      ); // Envia TODOS os cookies (MoodleSession + load balancer + outros)
      request.headers.set('X-Requested-With', 'XMLHttpRequest');
      request.write(
        json.encode([
          {'index': 0, 'methodname': function, 'args': args},
        ]),
      );

      final response = await request.close();
      _storeCookies(response); // Atualiza cookies se renovados pelo servidor
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw MoodleException('AJAX HTTP ${response.statusCode}');
      }

      try {
        final decoded = json.decode(body);
        if (decoded is List && decoded.isNotEmpty) {
          final result = decoded[0] as Map<String, dynamic>;
          if (result['error'] == true) {
            final ex = result['exception'] as Map<String, dynamic>?;
            throw MoodleException(
              ex?['message'] as String? ?? 'Erro AJAX desconhecido',
            );
          }
          return {'data': result['data']};
        }
      } on FormatException {
        _invalidateSession('Sessão expirada (resposta não-JSON)');
      }
      throw MoodleException('Resposta AJAX inesperada');
    } finally {
      client.close();
    }
  }

  Future<MoodleCredential> login(
    String baseUrl,
    String username,
    String password,
  ) async {
    String? token;
    String? lastError;

    for (final service in _services) {
      final uri = Uri.parse('$baseUrl/login/token.php');
      final response = await http.post(
        uri,
        body: {'username': username, 'password': password, 'service': service},
      );

      if (response.statusCode != 200) continue;

      final body = json.decode(response.body) as Map<String, dynamic>;
      if (body.containsKey('error')) {
        lastError = body['error'] as String;
        continue;
      }

      token = body['token'] as String;
      break;
    }

    if (token == null) {
      throw MoodleException(lastError ?? 'Falha na conexão com o Moodle');
    }

    // Estabelecer sessão web para chamadas AJAX (renomear seções/módulos)
    await _establishSession(baseUrl, username, password);
    // Credenciais já guardadas em _establishSession para retry automático

    // Get user info
    final info = await _callWs(baseUrl, token, 'core_webservice_get_site_info');
    final data = info['data'] as Map<String, dynamic>;

    return MoodleCredential(
      moodleUrl: baseUrl,
      username: username,
      password: password,
      token: token,
      userId: data['userid'] as int,
      fullname: data['fullname'] as String? ?? username,
      savedAt: DateTime.now(),
    );
  }

  Future<List<MoodleCourse>> getCourses(
    String token,
    String baseUrl,
    int userId,
  ) async {
    final result = await _callWs(
      baseUrl,
      token,
      'core_enrol_get_users_courses',
      params: {'userid': userId.toString()},
    );
    final list = result['data'] as List;
    return list
        .map((c) => MoodleCourse.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<List<MoodleSection>> getCourseContents(
    String token,
    String baseUrl,
    int courseId,
  ) async {
    final result = await _callWs(
      baseUrl,
      token,
      'core_course_get_contents',
      params: {'courseid': courseId.toString()},
    );
    final list = result['data'] as List;
    return list
        .map((s) => MoodleSection.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  Future<void> updateSectionName(
    String token,
    String baseUrl,
    int sectionId,
    String newName,
  ) async {
    // Pares (component, itemtype) conforme o formato do curso:
    // format_tiles usa 'sectionnamenl', os demais usam 'sectionname'
    final variants = [
      ('format_tiles', 'sectionnamenl'),
      ('core_courseformat', 'sectionname'),
      ('format_topics', 'sectionname'),
      ('format_weeks', 'sectionname'),
      ('format_onetopic', 'sectionname'),
    ];
    final ajaxErrors = <String>[];
    if (_canAttemptAjax) {
      for (final (comp, itemtype) in variants) {
        try {
          await _callAjax(baseUrl, 'core_update_inplace_editable', {
            'component': comp,
            'itemtype': itemtype,
            'itemid': sectionId.toString(),
            'value': newName,
          });
          return;
        } catch (e) {
          ajaxErrors.add('$comp/$itemtype(id=$sectionId): $e');
        }
      }
    }
    // Fallback para WS token (requer configuração do admin)
    try {
      await _callWs(
        baseUrl,
        token,
        'core_update_inplace_editable',
        usePost: true,
        params: {
          'component': 'core_courseformat',
          'itemtype': 'sectionname',
          'itemid': sectionId.toString(),
          'value': newName,
        },
      );
    } catch (wsError) {
      throw MoodleException(
        'AJAX: ${ajaxErrors.isNotEmpty ? ajaxErrors.join(' | ') : _sessionError ?? "não tentado"}. '
        'WS: $wsError',
      );
    }
  }

  Future<void> updateModuleVisibility(
    String token,
    String baseUrl,
    int moduleId,
    int visibility,
  ) async {
    // 0=hide, 1=show, 2=stealth
    final action = switch (visibility) {
      0 => 'hide',
      2 => 'stealth',
      _ => 'show',
    };
    // Tentar AJAX primeiro
    if (_canAttemptAjax) {
      try {
        await _callAjax(baseUrl, 'core_course_edit_module', {
          'id': moduleId.toString(),
          'action': action,
        });
        return;
      } catch (_) {}
    }
    // Fallback para WS token
    await _callWs(
      baseUrl,
      token,
      'core_course_edit_module',
      usePost: true,
      params: {'id': moduleId.toString(), 'action': action},
    );
  }

  Future<void> updateModuleName(
    String token,
    String baseUrl,
    int moduleId,
    String newName,
  ) async {
    // core_course confirmado via DevTools; core_courseformat como fallback
    final components = ['core_course', 'core_courseformat'];
    final ajaxErrors = <String>[];
    if (_canAttemptAjax) {
      for (final comp in components) {
        try {
          await _callAjax(baseUrl, 'core_update_inplace_editable', {
            'component': comp,
            'itemtype': 'activityname',
            'itemid': moduleId.toString(),
            'value': newName,
          });
          return;
        } catch (e) {
          ajaxErrors.add('$comp(id=$moduleId): $e');
        }
      }
    }
    try {
      await _callWs(
        baseUrl,
        token,
        'core_update_inplace_editable',
        usePost: true,
        params: {
          'component': 'core_courseformat',
          'itemtype': 'activityname',
          'itemid': moduleId.toString(),
          'value': newName,
        },
      );
    } catch (wsError) {
      throw MoodleException(
        'AJAX: ${ajaxErrors.isNotEmpty ? ajaxErrors.join(' | ') : _sessionError ?? "não tentado"}. '
        'WS: $wsError',
      );
    }
  }

  Future<void> updateLabelContent(
    String token,
    String baseUrl,
    int moduleId,
    int instanceId,
    String htmlContent,
  ) async {
    final params = {
      'component': 'mod_label',
      'itemtype': 'content',
      'itemid': instanceId.toString(),
      'value': htmlContent,
    };
    final ajaxErrors = <String>[];
    if (_canAttemptAjax) {
      // Tentar inplace_editable: mod_label (Moodle 4.0+), mod_text (Moodle 4.5+)
      for (final comp in ['mod_label', 'mod_text']) {
        try {
          params['component'] = comp;
          await _callAjax(baseUrl, 'core_update_inplace_editable', params);
          return;
        } catch (e) {
          ajaxErrors.add('$comp(instance=$instanceId): $e');
          continue;
        }
      }

      // Fallback: submeter formulário modedit.php (funciona em qualquer versão)
      try {
        await _updateLabelContentViaForm(baseUrl, moduleId, htmlContent);
        return;
      } catch (e) {
        ajaxErrors.add('modedit.php(cmid=$moduleId): $e');
      }
    }
    try {
      await _callWs(
        baseUrl,
        token,
        'core_update_inplace_editable',
        usePost: true,
        params: params,
      );
    } catch (wsError) {
      throw MoodleException(
        'AJAX: ${ajaxErrors.isNotEmpty ? ajaxErrors.join(" | ") : _sessionError ?? "não tentado"}. '
        'WS: $wsError',
      );
    }
  }

  /// Atualiza conteúdo de label via formulário de edição (modedit.php).
  /// Fallback quando core_update_inplace_editable não suporta mod_label.
  Future<void> _updateLabelContentViaForm(
    String baseUrl,
    int cmid,
    String newHtmlContent,
  ) async {
    if (!hasAjaxSession && _loginUsername != null) {
      await _establishSession(baseUrl, _loginUsername!, _loginPassword!);
    }
    if (!hasAjaxSession) {
      throw MoodleException('Sessão necessária para edição via formulário');
    }

    final client = io.HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    try {
      // 1. GET página do formulário de edição
      final getReq = await client.getUrl(
        Uri.parse('$baseUrl/course/modedit.php?update=$cmid'),
      );
      _applyCookies(getReq);
      final getResp = await getReq.close();
      _storeCookies(getResp);
      final html = await getResp.transform(utf8.decoder).join();

      if (getResp.statusCode != 200) {
        throw MoodleException('Formulário HTTP ${getResp.statusCode}');
      }

      // 2. Extrair campos do formulário
      final fields = <String, String>{};

      // Todos os inputs hidden
      for (final m in RegExp(
        r'<input[^>]+type=["\x27]hidden["\x27][^>]*>',
        caseSensitive: false,
      ).allMatches(html)) {
        final tag = m.group(0)!;
        final name = RegExp(
          r'name=["\x27]([^"\x27]*)["\x27]',
        ).firstMatch(tag)?.group(1);
        final value = RegExp(
          r'value=["\x27]([^"\x27]*)["\x27]',
        ).firstMatch(tag)?.group(1);
        if (name != null && name.isNotEmpty) {
          fields[name] = _decodeHtmlEntities(value ?? '');
        }
      }

      // Checkboxes marcados
      for (final m in RegExp(
        r'<input[^>]+type=["\x27]checkbox["\x27][^>]*checked[^>]*>',
        caseSensitive: false,
      ).allMatches(html)) {
        final tag = m.group(0)!;
        final name = RegExp(
          r'name=["\x27]([^"\x27]*)["\x27]',
        ).firstMatch(tag)?.group(1);
        final value = RegExp(
          r'value=["\x27]([^"\x27]*)["\x27]',
        ).firstMatch(tag)?.group(1);
        if (name != null) {
          fields[name] = value ?? '1';
        }
      }

      // introeditor[itemid] — ID da área de rascunho (critical)
      final draftMatch =
          RegExp(
            r'name=["\x27]introeditor\[itemid\]["\x27][^>]*value=["\x27](\d+)["\x27]',
          ).firstMatch(html) ??
          RegExp(
            r'value=["\x27](\d+)["\x27][^>]*name=["\x27]introeditor\[itemid\]["\x27]',
          ).firstMatch(html);
      if (draftMatch != null) {
        fields['introeditor[itemid]'] = draftMatch.group(1)!;
      }

      // introeditor[format] — formato HTML = 1
      if (!fields.containsKey('introeditor[format]')) {
        final fmtMatch = RegExp(
          r'name=["\x27]introeditor\[format\]["\x27][^>]*value=["\x27](\d+)["\x27]',
        ).firstMatch(html);
        fields['introeditor[format]'] = fmtMatch?.group(1) ?? '1';
      }

      // Definir novo conteúdo
      fields['introeditor[text]'] = newHtmlContent;

      // Garantir sesskey e showdescription
      fields['sesskey'] = _sesskey!;
      fields['showdescription'] = '1';

      // Botão de submissão
      fields['submitbutton2'] = 'Salvar e voltar ao curso';
      fields.remove('cancel');

      // 3. POST do formulário
      final postReq = await client.postUrl(
        Uri.parse('$baseUrl/course/modedit.php'),
      );
      postReq.followRedirects = false;
      _applyCookies(postReq);
      postReq.headers.contentType = io.ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );

      final bodyParts = <String>[];
      fields.forEach((k, v) {
        bodyParts.add('${Uri.encodeComponent(k)}=${Uri.encodeComponent(v)}');
      });
      postReq.write(bodyParts.join('&'));

      final postResp = await postReq.close();
      _storeCookies(postResp);
      await postResp.drain<void>();

      // 302/303 = sucesso (redirect para página do curso)
      if (postResp.statusCode == 302 || postResp.statusCode == 303) {
        return;
      }

      throw MoodleException(
        'Formulário não salvou (HTTP ${postResp.statusCode})',
      );
    } finally {
      client.close();
    }
  }

  /// Decodifica entidades HTML básicas em valores de atributos do formulário.
  String _decodeHtmlEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  // ── Mapeamento modname → campos de data do modedit.php ─────────────────

  static const _openDateFieldNames = <String, String>{
    'assign': 'allowsubmissionsfromdate',
    'quiz': 'timeopen',
    'choice': 'timeopen',
    'feedback': 'timeopen',
    'lesson': 'available',
    'data': 'timeavailablefrom',
    'workshop': 'submissionstart',
    'scorm': 'timeopen',
  };

  static const _closeDateFieldNames = <String, String>{
    'assign': 'duedate',
    'quiz': 'timeclose',
    'choice': 'timeclose',
    'feedback': 'timeclose',
    'lesson': 'deadline',
    'data': 'timeavailableto',
    'workshop': 'submissionend',
    'scorm': 'timeclose',
  };

  /// Atualiza datas de abertura e/ou encerramento de um módulo via
  /// formulário modedit.php. Faz scraping completo do formulário para
  /// preservar TODOS os campos existentes e modifica apenas as datas.
  /// Retorna descrição do resultado (sucesso ou detalhes do erro).
  Future<String> updateModuleDates(
    String baseUrl,
    int cmid,
    String modname,
    DateTime? openDate,
    DateTime? closeDate,
  ) async {
    final openField = _openDateFieldNames[modname];
    final closeField = _closeDateFieldNames[modname];
    if (openField == null && closeField == null) {
      return 'modname "$modname" não suportado para datas';
    }

    if (!hasAjaxSession && _loginUsername != null) {
      await _establishSession(baseUrl, _loginUsername!, _loginPassword!);
    }
    if (!hasAjaxSession) {
      throw MoodleException('Sessão necessária para edição de datas');
    }

    final client = io.HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    try {
      // 1. GET página do formulário de edição
      final getReq = await client.getUrl(
        Uri.parse('$baseUrl/course/modedit.php?update=$cmid'),
      );
      _applyCookies(getReq);
      final getResp = await getReq.close();
      _storeCookies(getResp);
      final html = await getResp.transform(utf8.decoder).join();

      if (getResp.statusCode != 200) {
        throw MoodleException('GET formulário HTTP ${getResp.statusCode}');
      }

      // Verificar se a página é realmente o formulário de edição
      if (!html.contains('modedit.php') && !html.contains('moodleform')) {
        // Pode ser redirecionamento para login
        if (html.contains('login/index.php') || html.contains('logintoken')) {
          _invalidateSession('Sessão expirada ao acessar formulário');
          throw MoodleException('Sessão expirada – precisa relogar');
        }
        throw MoodleException(
          'Página retornada não é formulário de edição (cmid=$cmid)',
        );
      }

      // 2. Extrair TODOS os campos do formulário (moodleform)
      final fields = _parseAllFormFields(html);

      if (fields.isEmpty) {
        throw MoodleException(
          'Nenhum campo encontrado no formulário (cmid=$cmid)',
        );
      }

      // Garantir sesskey
      fields['sesskey'] = _sesskey!;

      // Registro dos valores antes da alteração para log
      final logParts = <String>[];

      // 3. Atualizar campos de data
      if (openField != null && openDate != null) {
        _setDateFields(fields, openField, openDate);
        logParts.add(
          'open=$openField → ${openDate.day}/${openDate.month}/${openDate.year} '
          '${openDate.hour}:${openDate.minute.toString().padLeft(2, "0")}',
        );
      } else if (openField != null && openDate == null) {
        fields.remove('$openField[enabled]');
        logParts.add('open=$openField → desabilitado');
      }

      if (closeField != null && closeDate != null) {
        _setDateFields(fields, closeField, closeDate);
        logParts.add(
          'close=$closeField → ${closeDate.day}/${closeDate.month}/${closeDate.year} '
          '${closeDate.hour}:${closeDate.minute.toString().padLeft(2, "0")}',
        );
      } else if (closeField != null && closeDate == null) {
        fields.remove('$closeField[enabled]');
        logParts.add('close=$closeField → desabilitado');
      }

      // Botão de submissão
      fields['submitbutton2'] = 'Salvar e voltar ao curso';
      fields.remove('cancel');

      // 4. POST do formulário
      final postReq = await client.postUrl(
        Uri.parse('$baseUrl/course/modedit.php'),
      );
      postReq.followRedirects = false;
      _applyCookies(postReq);
      postReq.headers.contentType = io.ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );

      final bodyParts = <String>[];
      fields.forEach((k, v) {
        bodyParts.add('${Uri.encodeComponent(k)}=${Uri.encodeComponent(v)}');
      });
      postReq.write(bodyParts.join('&'));

      final postResp = await postReq.close();
      _storeCookies(postResp);

      if (postResp.statusCode == 302 || postResp.statusCode == 303) {
        // Redirect = sucesso no Moodle. Seguir redirect para confirmar.
        final location = postResp.headers.value('location');
        await postResp.drain<void>();

        if (location != null) {
          // Verificar se redireciona para a página do curso (sucesso)
          // e não para o próprio formulário (erro de validação)
          if (location.contains('modedit.php')) {
            // Redireciona de volta para o formulário → possível erro
            final verifyReq = await client.getUrl(
              Uri.parse(
                location.startsWith('http') ? location : '$baseUrl$location',
              ),
            );
            _applyCookies(verifyReq);
            final verifyResp = await verifyReq.close();
            _storeCookies(verifyResp);
            final verifyHtml = await verifyResp.transform(utf8.decoder).join();

            // Verificar se há mensagens de erro no formulário
            if (verifyHtml.contains('class="error"') ||
                verifyHtml.contains('alert-danger') ||
                verifyHtml.contains('notifyproblem')) {
              final errorMatch = RegExp(
                r'class="error"[^>]*>([^<]+)<',
              ).firstMatch(verifyHtml);
              final errorMsg = errorMatch?.group(1) ?? 'erro de validação';
              throw MoodleException('Moodle rejeitou: $errorMsg (cmid=$cmid)');
            }
          }
        }
        return 'OK [${logParts.join("; ")}] → redirect ${postResp.statusCode}';
      }

      // POST não redirecionou — ler corpo para identificar erros
      final postBody = await postResp.transform(utf8.decoder).join();

      // Verificar mensagens de erro do Moodle
      if (postBody.contains('class="error"') ||
          postBody.contains('alert-danger') ||
          postBody.contains('notifyproblem') ||
          postBody.contains('loginerrors')) {
        final errorMatch = RegExp(
          r'(?:class="error"|alert-danger|notifyproblem)[^>]*>([^<]{1,200})',
        ).firstMatch(postBody);
        final errorMsg = errorMatch?.group(1)?.trim() ?? 'erro desconhecido';
        throw MoodleException(
          'Moodle erro: $errorMsg (HTTP ${postResp.statusCode}, cmid=$cmid)',
        );
      }

      // Sessão expirada?
      if (postBody.contains('login/index.php') ||
          postBody.contains('logintoken')) {
        _invalidateSession('Sessão expirada ao salvar formulário');
        throw MoodleException(
          'Sessão expirada ao salvar (HTTP ${postResp.statusCode})',
        );
      }

      throw MoodleException(
        'Formulário não salvou (HTTP ${postResp.statusCode}, '
        '${postBody.length} bytes, cmid=$cmid)',
      );
    } finally {
      client.close();
    }
  }

  /// Define os sub-campos de data do Moodle (day/month/year/hour/minute/enabled).
  void _setDateFields(
    Map<String, String> fields,
    String fieldName,
    DateTime date,
  ) {
    fields['$fieldName[enabled]'] = '1';
    fields['$fieldName[day]'] = date.day.toString();
    fields['$fieldName[month]'] = date.month.toString();
    fields['$fieldName[year]'] = date.year.toString();
    fields['$fieldName[hour]'] = date.hour.toString();
    fields['$fieldName[minute]'] = date.minute.toString();
  }

  /// Extrai TODOS os campos de um formulário Moodle (moodleform) do HTML.
  /// Captura: hidden inputs, text inputs, number inputs, selects (valor
  /// selecionado), checkboxes marcados, radio buttons selecionados e
  /// textareas.
  Map<String, String> _parseAllFormFields(String html) {
    final fields = <String, String>{};

    // ── Inputs (hidden, text, number, email, submit, etc.) ──
    for (final m in RegExp(
      r'<input\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = m.group(0)!;
      final type =
          RegExp(
            r'''type=["']([^"']*)["']''',
          ).firstMatch(tag)?.group(1)?.toLowerCase() ??
          'text';

      final name = RegExp(
        r'''name=["']([^"']*)["']''',
      ).firstMatch(tag)?.group(1);
      if (name == null || name.isEmpty) continue;

      final value =
          RegExp(r'''value=["']([^"']*)["']''').firstMatch(tag)?.group(1) ?? '';

      if (type == 'checkbox') {
        if (RegExp(r'\bchecked\b', caseSensitive: false).hasMatch(tag)) {
          fields[name] = _decodeHtmlEntities(value.isEmpty ? '1' : value);
        }
      } else if (type == 'radio') {
        if (RegExp(r'\bchecked\b', caseSensitive: false).hasMatch(tag)) {
          fields[name] = _decodeHtmlEntities(value);
        }
      } else if (type != 'submit' && type != 'button' && type != 'reset') {
        fields[name] = _decodeHtmlEntities(value);
      }
    }

    // ── Selects (capturar option selected) ──
    for (final m in RegExp(
      r'<select\b[^>]*name=["'
      "'"
      r']([^"'
      "'"
      r']*)["'
      "'"
      r'][^>]*>(.*?)</select>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(html)) {
      final name = m.group(1)!;
      final options = m.group(2)!;
      // Procurar option com selected
      final selMatch = RegExp(
        r'<option\b[^>]*selected[^>]*value=["'
        "'"
        r']([^"'
        "'"
        r']*)["'
        "'"
        r']',
        caseSensitive: false,
      ).firstMatch(options);
      // Formato alternativo: value antes de selected
      final selMatch2 =
          selMatch ??
          RegExp(
            r'<option\b[^>]*value=["'
            "'"
            r']([^"'
            "'"
            r']*)["'
            "'"
            r'][^>]*selected',
            caseSensitive: false,
          ).firstMatch(options);
      if (selMatch2 != null) {
        fields[name] = _decodeHtmlEntities(selMatch2.group(1)!);
      }
    }

    // ── Textareas ──
    for (final m in RegExp(
      r'<textarea\b[^>]*name=["'
      "'"
      r']([^"'
      "'"
      r']*)["'
      "'"
      r'][^>]*>(.*?)</textarea>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(html)) {
      final name = m.group(1)!;
      final content = m.group(2)!;
      fields[name] = _decodeHtmlEntities(content);
    }

    return fields;
  }

  /// Move um módulo para depois de outro módulo na mesma seção.
  /// Usa core_courseformat_update_course com action=cm_move.
  /// Se [targetCmId] for null, move para o início da seção [targetSectionId].
  Future<String> moveModule(
    String token,
    String baseUrl,
    int courseId,
    int moduleId,
    int? targetCmId,
    int targetSectionId,
  ) async {
    if (_canAttemptAjax) {
      try {
        final args = <String, dynamic>{
          'action': 'cm_move',
          'courseid': courseId,
          'ids': [moduleId],
          'targetsectionid': targetSectionId,
        };
        if (targetCmId != null) {
          args['targetcmid'] = targetCmId;
        }
        final resp = await _callAjax(
          baseUrl,
          'core_courseformat_update_course',
          args,
        );
        return resp.toString();
      } catch (e) {
        throw MoodleException('Mover módulo $moduleId: $e');
      }
    }
    throw MoodleException('Sessão AJAX necessária para mover módulos');
  }
}

class MoodleException implements Exception {
  final String message;
  MoodleException(this.message);
  @override
  String toString() => 'MoodleException: $message';
}
