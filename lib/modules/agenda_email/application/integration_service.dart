import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:gestor_ufu/platform/command/module_command.dart';

/// OAuth and provider API boundary. Tokens are stored only in Windows secure
/// storage; no secret/token is exposed to widgets or agent tools.
class IntegrationService {
  IntegrationService({FlutterSecureStorage? secureStorage, http.Client? client})
    : _secure = secureStorage ?? const FlutterSecureStorage(),
      _client = client;
  final FlutterSecureStorage _secure;
  http.Client? _client;
  http.Client get _http => _client ??= http.Client();

  static const googleClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID',
  );
  static const microsoftClientId = String.fromEnvironment(
    'MICROSOFT_OAUTH_CLIENT_ID',
  );
  static const _googleClientIdKey = 'integrations.oauth.google.client_id';
  static const _googleClientSecretKey =
      'integrations.oauth.google.client_secret';
  static const _microsoftClientIdKey = 'integrations.oauth.microsoft.client_id';
  static const providers = [
    'google_calendar',
    'google_mail',
    'microsoft_calendar',
    'microsoft_mail',
  ];

  Future<bool> connected(String provider) async =>
      (await _readToken(provider)) != null;

  /// IDs públicos das aplicações OAuth. O segredo do cliente Google, quando
  /// fornecido pelo tipo de credencial, não é devolvido à interface.
  Future<Map<String, String>> configuracaoOauth() async => {
    'google': await _clientId(google: true),
    'microsoft': await _clientId(google: false),
    'googleSecretConfigured':
        (await _secure.read(key: _googleClientSecretKey)) == null
        ? 'false'
        : 'true',
  };

  Future<void> salvarConfiguracaoOauth({
    required String google,
    required String microsoft,
    String googleClientSecret = '',
  }) async {
    await _saveClientId(_googleClientIdKey, google, googleClientId);
    await _saveClientId(_microsoftClientIdKey, microsoft, microsoftClientId);
    if (googleClientSecret.trim().isNotEmpty) {
      await _secure.write(
        key: _googleClientSecretKey,
        value: googleClientSecret.trim(),
      );
    }
  }

  Future<void> _saveClientId(String key, String value, String bundled) async {
    final id = value.trim();
    // Um --dart-define é a configuração corporativa/pacote. Campo vazio
    // volta a usá-lo, em vez de deixar uma configuração antiga escondida.
    if (id.isEmpty || id == bundled) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: id);
    }
  }

  Future<String> _clientId({required bool google}) async {
    final bundled = google ? googleClientId : microsoftClientId;
    if (bundled.isNotEmpty) return bundled;
    return (await _secure.read(
          key: google ? _googleClientIdKey : _microsoftClientIdKey,
        ))?.trim() ??
        '';
  }

  Future<String> _googleClientSecret() async =>
      (await _secure.read(key: _googleClientSecretKey))?.trim() ?? '';

  Future<void> disconnect(String provider) async {
    await _secure.delete(key: 'integrations.$provider');
  }

  Future<void> connectGoogle({required bool mail}) async => _authorize(
    mail ? 'google_mail' : 'google_calendar',
    await _clientId(google: true),
    google: true,
    scopes: mail
        ? 'https://www.googleapis.com/auth/gmail.modify'
        : 'https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly',
  );
  Future<void> connectMicrosoftCalendar() async => _authorize(
    'microsoft_calendar',
    await _clientId(google: false),
    google: false,
    scopes: 'offline_access User.Read Calendars.ReadWrite',
  );
  Future<void> connectMicrosoftMail() async => _authorize(
    'microsoft_mail',
    await _clientId(google: false),
    google: false,
    scopes: 'offline_access User.Read Mail.ReadWrite',
  );

  Future<void> _authorize(
    String provider,
    String clientId, {
    required bool google,
    required String scopes,
  }) async {
    if (clientId.isEmpty) {
      throw StateError(
        'Não configurado: compile o aplicativo com --dart-define=${google ? 'GOOGLE_OAUTH_CLIENT_ID' : 'MICROSOFT_OAUTH_CLIENT_ID'}=<client-id>.',
      );
    }
    final verifier = _random(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final servers = <HttpServer>[
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ];
    try {
      servers.add(
        await HttpServer.bind(
          InternetAddress.loopbackIPv6,
          servers.first.port,
          v6Only: true,
        ),
      );
    } catch (_) {
      // IPv4 localhost remains available if IPv6 loopback is disabled.
    }
    final redirect = google
        ? 'http://127.0.0.1:${servers.first.port}'
        : 'http://localhost:${servers.first.port}';
    final state = _random(24);
    final uri = google
        ? Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
            'client_id': clientId,
            'redirect_uri': redirect,
            'response_type': 'code',
            'scope': scopes,
            'access_type': 'offline',
            'prompt': 'consent',
            'state': state,
            'code_challenge': challenge,
            'code_challenge_method': 'S256',
          })
        : Uri.https(
            'login.microsoftonline.com',
            '/common/oauth2/v2.0/authorize',
            {
              'client_id': clientId,
              'redirect_uri': redirect,
              'response_type': 'code',
              'response_mode': 'query',
              'scope': scopes,
              'state': state,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
            },
          );
    await Process.start('rundll32.exe', [
      'url.dll,FileProtocolHandler',
      uri.toString(),
    ], mode: ProcessStartMode.detached);
    try {
      final request = await Future.any(
        servers.map((server) => server.first),
      ).timeout(const Duration(minutes: 3));
      if (!request.connectionInfo!.remoteAddress.isLoopback ||
          request.method != 'GET' ||
          request.uri.path != '/') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        throw StateError(
          'Callback OAuth local inesperado. Tente conectar a conta novamente.',
        );
      }
      final params = request.uri.queryParameters;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<html><meta charset="utf-8"><body>Autenticação recebida. Você pode fechar esta janela e voltar ao Gestor UFU.</body></html>',
      );
      await request.response.close();
      if (params['state'] != state) {
        throw StateError('Resposta OAuth inválida (state não confere).');
      }
      if (params['error'] != null) {
        throw StateError(
          _oauthError(params['error']!, params['error_description'] ?? ''),
        );
      }
      final code = params['code'];
      if (code == null) {
        throw StateError('O provedor não retornou o código de autorização.');
      }
      final tokenUri = google
          ? Uri.https('oauth2.googleapis.com', '/token')
          : Uri.https('login.microsoftonline.com', '/common/oauth2/v2.0/token');
      final googleClientSecret = google ? await _googleClientSecret() : '';
      final response = await _http.post(
        tokenUri,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirect,
          'code_verifier': verifier,
          if (google && googleClientSecret.isNotEmpty)
            'client_secret': googleClientSecret,
          if (!google) 'scope': scopes,
        },
      );
      if (response.statusCode != 200) throw StateError(_tokenError(response));
      final token = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      token['expires_at'] = DateTime.now()
          .add(
            Duration(seconds: (token['expires_in'] as num?)?.toInt() ?? 3600),
          )
          .toIso8601String();
      await _secure.write(
        key: 'integrations.$provider',
        value: jsonEncode(token),
      );
    } finally {
      for (final server in servers) {
        await server.close(force: true);
      }
    }
  }

  Future<Map<String, dynamic>?> _readToken(String provider) async {
    final raw = await _secure.read(key: 'integrations.$provider');
    if (raw == null) return null;
    final token = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (DateTime.tryParse(
          '${token['expires_at']}',
        )?.isAfter(DateTime.now().add(const Duration(minutes: 2))) ==
        true) {
      return token;
    }
    final refresh = token['refresh_token'];
    if (refresh == null) {
      await disconnect(provider);
      return null;
    }
    final google = provider.startsWith('google');
    final endpoint = google
        ? Uri.https('oauth2.googleapis.com', '/token')
        : Uri.https('login.microsoftonline.com', '/common/oauth2/v2.0/token');
    final clientId = await _clientId(google: google);
    if (clientId.isEmpty) {
      throw StateError('OAuth client ID is no longer configured.');
    }
    final googleClientSecret = google ? await _googleClientSecret() : '';
    final response = await _http.post(
      endpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': '$refresh',
        if (google && googleClientSecret.isNotEmpty)
          'client_secret': googleClientSecret,
      },
    );
    if (response.statusCode != 200) {
      await disconnect(provider);
      throw StateError(_tokenError(response));
    }
    final fresh = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    fresh['refresh_token'] ??= refresh;
    fresh['expires_at'] = DateTime.now()
        .add(Duration(seconds: (fresh['expires_in'] as num?)?.toInt() ?? 3600))
        .toIso8601String();
    await _secure.write(
      key: 'integrations.$provider',
      value: jsonEncode(fresh),
    );
    return fresh;
  }

  Future<http.Response> _api(
    String provider,
    String url, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final token = await _readToken(provider);
    if (token == null) throw StateError('Conta desconectada.');
    final uri = Uri.parse(url);
    final request = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer ${token['access_token']}'
      ..headers['Accept'] = 'application/json'
      // OAuth APIs are sometimes reached through university inspection
      // proxies. Avoid pooled sockets and compressed responses, which can
      // surface as a malformed chunk-extension error in dart:io.
      ..headers['Connection'] = 'close'
      ..headers['Accept-Encoding'] = 'identity';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    late final http.Response response;
    try {
      final streamed = await _http.send(request);
      response = await http.Response.fromStream(streamed);
    } on HttpException catch (error) {
      final isCreate = method.toUpperCase() == 'POST';
      throw StateError(
        'A resposta do provedor ${provider.startsWith('google') ? 'Google' : 'Microsoft'} veio incompleta ou inválida (${error.message}). '
        '${isCreate ? 'Confira a agenda antes de tentar novamente, pois o evento pode ter sido gravado.' : 'Tente novamente em instantes.'}',
      );
    } on http.ClientException catch (error) {
      final isCreate = method.toUpperCase() == 'POST';
      throw StateError(
        'A comunicação com o provedor ${provider.startsWith('google') ? 'Google' : 'Microsoft'} falhou (${error.message}). '
        '${isCreate ? 'Confira a agenda antes de tentar novamente, pois o evento pode ter sido gravado.' : 'Tente novamente em instantes.'}',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_apiError(response, provider));
    }
    return response;
  }

  Future<List<Map<String, dynamic>>> calendars() async {
    final out = <Map<String, dynamic>>[];
    String texto(dynamic value, String fallback) {
      final text = '${value ?? ''}'.trim();
      return text.isEmpty || text == 'null' ? fallback : text;
    }

    if (await connected('google_calendar')) {
      final r =
          jsonDecode(
                (await _api(
                  'google_calendar',
                  'https://www.googleapis.com/calendar/v3/users/me/calendarList',
                )).body,
              )
              as Map;
      final gmailProfile = await connected('google_mail')
          ? (jsonDecode(
                  (await _api(
                    'google_mail',
                    'https://gmail.googleapis.com/gmail/v1/users/me/profile',
                  )).body,
                )
                as Map)['emailAddress']
          : null;
      for (final x in (r['items'] as List? ?? [])) {
        final item = Map<String, dynamic>.from(x as Map);
        final owner = item['owner'];
        final account = owner is Map
            ? owner['email'] ??
                  gmailProfile ??
                  (item['primary'] == true ? item['id'] : 'Google')
            : gmailProfile ?? (item['primary'] == true ? item['id'] : 'Google');
        out.add({
          ...item,
          // CalendarList da Google chama o título visível de `summary`,
          // enquanto o Microsoft Graph o chama de `name`.
          'name': texto(
            item['summaryOverride'] ?? item['summary'] ?? item['id'],
            'Calendário Google',
          ),
          'provider': 'Google',
          'account': texto(account, 'Google'),
          'provider_id': 'google_calendar',
        });
      }
    }
    if (await connected('microsoft_calendar')) {
      final me =
          jsonDecode(
                (await _api(
                  'microsoft_calendar',
                  'https://graph.microsoft.com/v1.0/me?%24select=displayName,mail,userPrincipalName',
                )).body,
              )
              as Map;
      final account =
          me['mail'] ??
          me['userPrincipalName'] ??
          me['displayName'] ??
          'Microsoft 365';
      final r =
          jsonDecode(
                (await _api(
                  'microsoft_calendar',
                  'https://graph.microsoft.com/v1.0/me/calendars?%24select=id,name,owner,isDefaultCalendar',
                )).body,
              )
              as Map;
      for (final x in (r['value'] as List? ?? [])) {
        final item = Map<String, dynamic>.from(x as Map);
        out.add({
          ...item,
          'name': texto(item['name'] ?? item['id'], 'Calendário Microsoft'),
          'provider': 'Microsoft 365',
          'account': texto(account, 'Microsoft 365'),
          'provider_id': 'microsoft_calendar',
        });
      }
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> events(
    DateTime from,
    DateTime to,
    List<Map<String, dynamic>> selected,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final c in selected) {
      final provider = '${c['provider_id']}';
      final id = Uri.encodeComponent('${c['id']}');
      final url = provider == 'google_calendar'
          ? 'https://www.googleapis.com/calendar/v3/calendars/$id/events?timeMin=${Uri.encodeComponent(from.toUtc().toIso8601String())}&timeMax=${Uri.encodeComponent(to.toUtc().toIso8601String())}&singleEvents=true&orderBy=startTime&maxResults=250'
          : 'https://graph.microsoft.com/v1.0/me/calendars/$id/calendarView?startDateTime=${Uri.encodeComponent(from.toUtc().toIso8601String())}&endDateTime=${Uri.encodeComponent(to.toUtc().toIso8601String())}&%24top=100';
      var next = url;
      var pages = 0;
      while (next.isNotEmpty && pages++ < 5) {
        final r = jsonDecode((await _api(provider, next)).body) as Map;
        for (final raw
            in (r[provider == 'google_calendar' ? 'items' : 'value'] as List? ??
                [])) {
          out.add({
            ...Map<String, dynamic>.from(raw as Map),
            'provider': c['provider'],
            'account': c['account'],
            'calendar': c['name'] ?? 'Calendário sem nome',
            'provider_id': provider,
            'calendar_id': c['id'],
          });
        }
        if (provider == 'google_calendar') {
          final pageToken = r['nextPageToken'];
          next = pageToken is String && pageToken.isNotEmpty
              ? '$url&pageToken=${Uri.encodeComponent(pageToken)}'
              : '';
        } else {
          final pageLink = r['@odata.nextLink'];
          next = pageLink is String ? pageLink : '';
        }
      }
    }
    return out;
  }

  Future<void> saveEvent(
    Map<String, dynamic> event, {
    required String action,
  }) async {
    final provider = '${event['provider_id']}';
    final calendar = Uri.encodeComponent('${event['calendar_id']}');
    final url = provider == 'google_calendar'
        ? 'https://www.googleapis.com/calendar/v3/calendars/$calendar/events${action == 'create' ? '' : '/${Uri.encodeComponent('${event['id']}')}'}'
        : 'https://graph.microsoft.com/v1.0/me/calendars/$calendar/events${action == 'create' ? '' : '/${Uri.encodeComponent('${event['id']}')}'}';
    final allowed = provider == 'google_calendar'
        ? [
            'summary',
            'description',
            'start',
            'end',
            'location',
            'recurrence',
            'attendees',
          ]
        : [
            'subject',
            'body',
            'start',
            'end',
            'location',
            'isAllDay',
            'isOnlineMeeting',
            'onlineMeetingProvider',
            'recurrence',
          ];
    final payload = {
      for (final key in allowed)
        if (event.containsKey(key)) key: event[key],
    };
    await _api(
      provider,
      url,
      method: switch (action) {
        'create' => 'POST',
        'update' => 'PATCH',
        'delete' => 'DELETE',
        _ => 'PATCH',
      },
      body: action == 'delete' ? null : payload,
    );
  }

  Future<List<Map<String, dynamic>>> messages({
    String query = '',
    bool unreadOnly = false,
    int page = 0,
  }) async {
    if (page < 0 || page > 20) {
      throw const FormatException('A paginação vai de 0 a 20.');
    }
    final out = <Map<String, dynamic>>[];
    if (await connected('google_mail')) {
      final profile =
          jsonDecode(
                (await _api(
                  'google_mail',
                  'https://gmail.googleapis.com/gmail/v1/users/me/profile',
                )).body,
              )
              as Map;
      final gmailAccount = '${profile['emailAddress'] ?? 'Gmail'}';
      final q = [
        if (query.isNotEmpty) query,
        if (unreadOnly) 'is:unread',
      ].join(' ');
      var list =
          jsonDecode(
                (await _api(
                  'google_mail',
                  'https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=30&q=${Uri.encodeComponent(q)}',
                )).body,
              )
              as Map;
      var currentPage = 0;
      while (true) {
        if (currentPage == page) {
          for (final m in (list['messages'] as List? ?? [])) {
            final id = '${(m as Map)['id']}';
            final full =
                jsonDecode(
                      (await _api(
                        'google_mail',
                        'https://gmail.googleapis.com/gmail/v1/users/me/messages/$id?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date',
                      )).body,
                    )
                    as Map;
            out.add({..._gmailMessage(full), 'account': gmailAccount});
          }
        }
        if (currentPage >= page) break;
        final pageToken = list['nextPageToken'];
        if (pageToken is! String || pageToken.isEmpty) break;
        list = jsonDecode(
          (await _api(
            'google_mail',
            'https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=30&q=${Uri.encodeComponent(q)}&pageToken=${Uri.encodeComponent(pageToken)}',
          )).body,
        );
        currentPage++;
      }
    }
    if (await connected('microsoft_mail')) {
      final filter = unreadOnly ? '&%24filter=isRead%20eq%20false' : '';
      final search = query.isEmpty
          ? ''
          : '&%24search=${Uri.encodeComponent('"$query"')}';
      final me =
          jsonDecode(
                (await _api(
                  'microsoft_mail',
                  'https://graph.microsoft.com/v1.0/me?%24select=displayName,mail,userPrincipalName',
                )).body,
              )
              as Map;
      final account =
          me['mail'] ??
          me['userPrincipalName'] ??
          me['displayName'] ??
          'Microsoft 365';
      var next =
          'https://graph.microsoft.com/v1.0/me/messages?%24top=30&%24select=id,subject,from,receivedDateTime,isRead$filter$search';
      var currentPage = 0;
      while (next.isNotEmpty) {
        final r = jsonDecode((await _api('microsoft_mail', next)).body) as Map;
        if (currentPage == page) {
          for (final m in (r['value'] as List? ?? [])) {
            final item = Map<String, dynamic>.from(m as Map);
            out.add({
              ...item,
              'from':
                  ((item['from'] as Map?)?['emailAddress']
                      as Map?)?['address'] ??
                  '',
              'provider_id': 'microsoft_mail',
              'account': '$account',
            });
          }
        }
        if (currentPage >= page) break;
        final pageLink = r['@odata.nextLink'];
        next = pageLink is String ? pageLink : '';
        currentPage++;
      }
    }
    final unique = <String, Map<String, dynamic>>{};
    for (final message in out) {
      unique['${message['provider_id']}:${message['id']}'] = message;
    }
    return unique.values.toList();
  }

  Map<String, dynamic> _gmailMessage(Map raw) {
    final headers = (((raw['payload'] as Map?)?['headers']) as List? ?? []);
    String header(String name) =>
        '${headers.whereType<Map>().where((x) => '${x['name']}'.toLowerCase() == name.toLowerCase()).map((x) => x['value']).firstOrNull ?? ''}';
    String body(Map p) {
      final data = (p['body'] as Map?)?['data'];
      if (data is String) {
        return utf8.decode(
          base64Url.decode(base64Url.normalize(data)),
          allowMalformed: true,
        );
      }
      for (final part in (p['parts'] as List? ?? [])) {
        final value = body(Map<String, dynamic>.from(part as Map));
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    return {
      'id': raw['id'],
      'threadId': raw['threadId'],
      'subject': header('subject'),
      'from': header('from'),
      'receivedDateTime': DateTime.fromMillisecondsSinceEpoch(
        int.tryParse('${raw['internalDate']}') ?? 0,
      ).toIso8601String(),
      'isRead': !((raw['labelIds'] as List? ?? []).contains('UNREAD')),
      'body': body(Map<String, dynamic>.from(raw['payload'] as Map? ?? {})),
      'provider_id': 'google_mail',
      'account': 'Gmail',
    };
  }

  Future<String> readMessage(Map<String, dynamic> message) async {
    final provider = '${message['provider_id']}';
    if (provider == 'google_mail') {
      final raw =
          jsonDecode(
                (await _api(
                  provider,
                  'https://gmail.googleapis.com/gmail/v1/users/me/messages/${Uri.encodeComponent('${message['id']}')}?format=full',
                )).body,
              )
              as Map;
      return _gmailBody(
        Map<String, dynamic>.from(raw['payload'] as Map? ?? {}),
      );
    }
    final raw =
        jsonDecode(
              (await _api(
                provider,
                'https://graph.microsoft.com/v1.0/me/messages/${Uri.encodeComponent('${message['id']}')}?%24select=body',
              )).body,
            )
            as Map;
    final content = '${(raw['body'] as Map?)?['content'] ?? ''}';
    return html_parser.parseFragment(content).text ?? content;
  }

  Future<Map<String, dynamic>> messageById(String provider, String id) async {
    if (provider == 'google_mail') {
      final raw =
          jsonDecode(
                (await _api(
                  provider,
                  'https://gmail.googleapis.com/gmail/v1/users/me/messages/${Uri.encodeComponent(id)}?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date',
                )).body,
              )
              as Map;
      final profile =
          jsonDecode(
                (await _api(
                  provider,
                  'https://gmail.googleapis.com/gmail/v1/users/me/profile',
                )).body,
              )
              as Map;
      return {
        ..._gmailMessage(raw),
        'account': '${profile['emailAddress'] ?? 'Gmail'}',
      };
    }
    if (provider == 'microsoft_mail') {
      final raw =
          jsonDecode(
                (await _api(
                  provider,
                  'https://graph.microsoft.com/v1.0/me/messages/${Uri.encodeComponent(id)}?%24select=id,subject,from,receivedDateTime,isRead',
                )).body,
              )
              as Map;
      final me =
          jsonDecode(
                (await _api(
                  provider,
                  'https://graph.microsoft.com/v1.0/me?%24select=mail,userPrincipalName',
                )).body,
              )
              as Map;
      return {
        ...Map<String, dynamic>.from(raw),
        'provider_id': provider,
        'account':
            '${me['mail'] ?? me['userPrincipalName'] ?? 'Microsoft 365'}',
        'from':
            ((raw['from'] as Map?)?['emailAddress'] as Map?)?['address'] ?? '',
      };
    }
    throw const CommandException(
      'provedor_invalido',
      'Provedor de mensagens inválido.',
    );
  }

  String _gmailBody(Map p) {
    final data = (p['body'] as Map?)?['data'];
    if (data is String && data.isNotEmpty) {
      return utf8.decode(
        base64Url.decode(base64Url.normalize(data)),
        allowMalformed: true,
      );
    }
    for (final part in (p['parts'] as List? ?? [])) {
      final found = _gmailBody(Map<String, dynamic>.from(part as Map));
      if (found.isNotEmpty) return found;
    }
    return '';
  }

  Future<void> setRead(Map<String, dynamic> message, bool read) async {
    if (message['provider_id'] == 'google_mail') {
      await _api(
        'google_mail',
        'https://gmail.googleapis.com/gmail/v1/users/me/messages/${message['id']}/modify',
        method: 'POST',
        body: {
          if (read) 'removeLabelIds': ['UNREAD'] else 'addLabelIds': ['UNREAD'],
        },
      );
    } else {
      await _api(
        'microsoft_mail',
        'https://graph.microsoft.com/v1.0/me/messages/${Uri.encodeComponent('${message['id']}')}',
        method: 'PATCH',
        body: {'isRead': read},
      );
    }
  }

  static String _random(int count) {
    final r = Random.secure();
    return base64Url
        .encode(List.generate(count, (i) => r.nextInt(256)))
        .replaceAll('=', '');
  }

  static String _oauthError(String e, String description) =>
      e.contains('admin') ||
          description.toLowerCase().contains('admin') ||
          e.contains('consent')
      ? 'A instituição precisa liberar o consentimento administrativo do aplicativo (CTIC/administrador UFU). Detalhe do provedor: $description'
      : 'Autorização recusada pelo provedor: $description';
  static String _tokenError(http.Response r) {
    if (r.body.contains('client_secret is missing')) {
      return 'O Google aceitou o login, mas exige o Client Secret desta aplicação para concluir a conexão. Abra Configurações de conexão e informe o Google OAuth Client Secret.';
    }
    return 'Falha na autorização OAuth (${r.statusCode}): ${_safeError(r.body)}';
  }

  static String _apiError(http.Response r, String provider) {
    if (r.statusCode == 401) {
      return 'Sessão expirada ou sem consentimento. Desconecte e conecte a conta novamente.';
    }
    if (r.statusCode == 403 && provider.startsWith('google')) {
      final raw = r.body.toLowerCase();
      if (raw.contains('accessnotconfigured') ||
          raw.contains('service_disabled') ||
          raw.contains('has not been used')) {
        return 'A Google Calendar API não está ativada neste projeto. No Google Cloud Console, abra APIs e serviços → Biblioteca, ative “Google Calendar API”, aguarde alguns minutos e clique em Atualizar.';
      }
      if (raw.contains('insufficientpermissions') ||
          raw.contains('insufficient permission')) {
        return 'O Google não concedeu os escopos necessários ao calendário. Desconecte o Google Calendar e conecte novamente, aceitando todas as permissões solicitadas.';
      }
      return 'O Google recusou a leitura dos calendários: ${_safeError(r.body)}';
    }
    if (r.statusCode == 403) {
      return 'Permissão insuficiente ou consentimento administrativo pendente. Na UFU, solicite ao CTIC a aprovação dos escopos delegados configurados para este aplicativo.';
    }
    if (r.statusCode == 429) {
      return 'Limite de requisições do provedor atingido. Aguarde e tente novamente.';
    }
    return 'Falha do provedor (${r.statusCode}): ${_safeError(r.body)}';
  }

  static String _safeError(String body) {
    try {
      final j = jsonDecode(body) as Map;
      final error =
          j['error_description'] ??
          j['error'] ??
          j['message'] ??
          'erro do provedor';
      return '$error'.replaceAll(
        RegExp(
          r'(access_token|refresh_token|client_secret)\s*[:=]\s*[^\s,]+',
          caseSensitive: false,
        ),
        '[credential redacted]',
      );
    } catch (_) {
      return 'resposta inválida';
    }
  }
}
