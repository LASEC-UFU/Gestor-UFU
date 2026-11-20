import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gestor_ufu/modules/agenda_email/application/integration_service.dart';
import 'package:gestor_ufu/modules/agenda_email/application/preferencias_agenda.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';

/// Tela do módulo Agendas e E-mails: contas conectadas, agendas (eventos,
/// classificação Pessoal/Profissional) e e-mails (metadados, leitura sob
/// pedido e estado lido). Usa o mesmo serviço dos comandos do agente.
class AgendaEmailPage extends StatefulWidget {
  const AgendaEmailPage({
    required this.api,
    required this.preferencias,
    super.key,
  });

  final IntegrationService api;
  final PreferenciasAgenda preferencias;

  @override
  State<AgendaEmailPage> createState() => _AgendaEmailPageState();
}

class _AgendaEmailPageState extends State<AgendaEmailPage>
    with SingleTickerProviderStateMixin {
  IntegrationService get _api => widget.api;
  final _search = TextEditingController();
  late final _tabs = TabController(length: 2, vsync: this);
  final _connected = <String, bool>{};
  final _calendars = <Map<String, dynamic>>[];
  final _events = <Map<String, dynamic>>[];
  final _messages = <Map<String, dynamic>>[];
  final _classification = <String, String>{};
  bool _unread = false, _busy = false;
  late DateTime _weekStart;
  int _mailPage = 0;
  bool _hasMoreMail = false;
  String? _error;
  String _defaultPersonal = '', _defaultProfessional = '';
  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _weekStart = DateTime(
      today.year,
      today.month,
      today.day - today.weekday + 1,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    _tabs.dispose();
    super.dispose();
  }

  String _key(Map c) => '${c['provider_id']}:${c['id']}';
  Future<void> _load() async {
    final prefs = widget.preferencias;
    _defaultPersonal = await prefs.calendarioPessoal();
    _defaultProfessional = await prefs.calendarioProfissional();
    _classification.addAll(await prefs.classificacao());
    await _refreshConnections();
  }

  Future<void> _refreshConnections() async {
    for (final p in IntegrationService.providers) {
      try {
        _connected[p] = await _api.connected(p);
      } catch (e) {
        _connected[p] = false;
        _error = '$e';
      }
    }
    if (mounted) setState(() {});
    await _loadCalendars();
    if (_tabs.index == 1) await _loadMessages();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _connect(String id) => _run(() async {
    switch (id) {
      case 'google_calendar':
        await _api.connectGoogle(mail: false);
      case 'google_mail':
        await _api.connectGoogle(mail: true);
      case 'microsoft_calendar':
        await _api.connectMicrosoftCalendar();
      case 'microsoft_mail':
        await _api.connectMicrosoftMail();
    }
    _connected[id] = true;
    await _loadCalendars();
    await _loadMessages();
  });
  Future<void> _disconnect(String id) => _run(() async {
    await _api.disconnect(id);
    _connected[id] = false;
    await _loadCalendars();
    await _loadMessages();
  });

  Future<void> _abrirConfiguracoesConexao() async {
    final atual = await _api.configuracaoOauth();
    if (!mounted) return;
    final google = TextEditingController(text: atual['google']);
    final microsoft = TextEditingController(text: atual['microsoft']);
    final googleSecret = TextEditingController();
    final segredoGoogleSalvo = atual['googleSecretConfigured'] == 'true';
    final salvar = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          icon: const Icon(Icons.settings_outlined),
          title: const Text('Configurações de conexão'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Informe os IDs das aplicações OAuth do Gestor. Senhas e '
                    'tokens da sua conta nunca são solicitados aqui.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: google,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Google OAuth Client ID',
                      hintText: '…apps.googleusercontent.com',
                      helperText:
                          'Google Cloud Console → cliente OAuth de aplicativo para computador.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: googleSecret,
                    autocorrect: false,
                    obscureText: true,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Google OAuth Client Secret (se fornecido)',
                      helperText: segredoGoogleSalvo
                          ? 'Um segredo já está salvo com proteção do Windows. Deixe vazio para mantê-lo.'
                          : 'Necessário quando o Google informar “client_secret is missing”.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: microsoft,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Microsoft OAuth Application (client) ID',
                      hintText: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                      helperText:
                          'Microsoft Entra ID → Registro de aplicativo → Application (client) ID.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Para contas institucionais, o CTIC pode precisar conceder '
                    'consentimento para Calendars.ReadWrite e Mail.ReadWrite.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Divider(height: 32),
                  Text(
                    'Contas conectadas',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  _contaConfiguracao(
                    'google_calendar',
                    'Google Calendar',
                    'Eventos e calendários de origem',
                    setLocal,
                  ),
                  _contaConfiguracao(
                    'google_mail',
                    'Gmail',
                    'Leitura e estado lido/não lido',
                    setLocal,
                  ),
                  _contaConfiguracao(
                    'microsoft_calendar',
                    'Microsoft Calendar',
                    'Calendars.ReadWrite; pode exigir consentimento CTIC',
                    setLocal,
                  ),
                  _contaConfiguracao(
                    'microsoft_mail',
                    'Microsoft Outlook',
                    'Mail.ReadWrite; pode exigir consentimento CTIC',
                    setLocal,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    if (salvar == true) {
      await _run(() async {
        await _api.salvarConfiguracaoOauth(
          google: google.text,
          microsoft: microsoft.text,
          googleClientSecret: googleSecret.text,
        );
      });
    }
    google.dispose();
    microsoft.dispose();
    googleSecret.dispose();
  }

  Widget _contaConfiguracao(
    String id,
    String titulo,
    String detalhe,
    void Function(VoidCallback fn) atualizarDialog,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(_connected[id] == true ? Icons.link : Icons.link_off),
    title: Text(titulo),
    subtitle: Text(detalhe),
    trailing: TextButton(
      onPressed: _busy
          ? null
          : () async {
              if (_connected[id] == true) {
                await _disconnect(id);
              } else {
                await _connect(id);
              }
              atualizarDialog(() {});
            },
      child: Text(_connected[id] == true ? 'Desconectar' : 'Conectar'),
    ),
  );

  Future<void> _loadCalendars() async {
    if (!_connected.values.any((v) => v)) {
      if (mounted) {
        setState(() {
          _calendars.clear();
          _events.clear();
        });
      }
      return;
    }
    try {
      final rows = await _api.calendars();
      if (mounted) {
        setState(() {
          _calendars
            ..clear()
            ..addAll(rows);
        });
      }
      await _loadEvents();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadEvents() async {
    final selected = _calendars
        .where((c) => _classification[_key(c)] != 'hidden')
        .toList();
    if (selected.isEmpty) {
      if (mounted) setState(_events.clear);
      return;
    }
    final list = await _api.events(
      _weekStart,
      _weekStart.add(const Duration(days: 7)),
      selected,
    );
    if (mounted) {
      setState(() {
        _events
          ..clear()
          ..addAll(list)
          ..sort((a, b) => _eventStart(a).compareTo(_eventStart(b)));
      });
    }
  }

  Future<void> _saveCalendarPrefs() async {
    await widget.preferencias.salvar(
      pessoal: _defaultPersonal,
      profissional: _defaultProfessional,
      classificacao: _classification,
    );
    await _loadEvents();
    if (mounted) setState(() {});
  }

  Future<void> _loadMessages({bool append = false}) async {
    if (!_connected.containsValue(true)) return;
    final page = append ? _mailPage + 1 : 0;
    final list = await _api.messages(
      query: _search.text.trim(),
      unreadOnly: _unread,
      page: page,
    );
    if (mounted) {
      setState(() {
        if (!append) _messages.clear();
        final ids = {
          for (final m in _messages) '${m['provider_id']}:${m['id']}',
        };
        _messages.addAll(
          list.where((m) => ids.add('${m['provider_id']}:${m['id']}')),
        );
        _mailPage = page;
        _hasMoreMail = list.length >= 30;
        _messages.sort(
          (a, b) =>
              '${b['receivedDateTime']}'.compareTo('${a['receivedDateTime']}'),
        );
      });
    }
  }

  DateTime _eventStart(Map e) {
    final start = e['start'] as Map? ?? {};
    final value = '${start['dateTime'] ?? start['date'] ?? ''}';
    final normalized =
        e['provider_id'] == 'microsoft_calendar' &&
            !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)
        ? '${value}Z'
        : value;
    return DateTime.tryParse(normalized) ?? DateTime(9999);
  }

  String _title(Map e) => '${e['summary'] ?? e['subject'] ?? '(Sem título)'}';
  String _startText(Map e) {
    final start = e['start'] as Map? ?? {};
    final allDay = start['date'] != null || e['isAllDay'] == true;
    final dt = start['date'] != null || e['provider_id'] != 'microsoft_calendar'
        ? DateTime.tryParse('${start['dateTime'] ?? start['date']}')
        : _eventStart(e);
    return dt == null
        ? 'Horário não informado'
        : allDay
        ? 'Dia inteiro • ${MaterialLocalizations.of(context).formatShortDate(dt)}'
        : '${MaterialLocalizations.of(context).formatShortDate(dt)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(dt.toLocal()))}';
  }

  String _calendarKey(String cat) =>
      cat == 'Pessoal' ? _defaultPersonal : _defaultProfessional;
  Future<void> _createEvent(String category) async {
    final key = _calendarKey(category);
    final cal = _calendars.where((c) => _key(c) == key).firstOrNull;
    if (cal == null) {
      setState(
        () => _error = 'Configure primeiro o calendário padrão $category.',
      );
      return;
    }
    final result = await _eventForm(category: category, calendar: cal);
    if (result == null) return;
    final confirmed = await _confirm(
      'Criar evento',
      _eventSummary(result, cal),
    );
    if (!confirmed) return;
    await _run(() async {
      await _api.saveEvent(result, action: 'create');
      await _loadEvents();
    });
  }

  Future<void> _editEvent(Map<String, dynamic> event) async {
    final cal = _calendars
        .where(
          (c) =>
              '${c['id']}' == '${event['calendar_id']}' &&
              '${c['provider_id']}' == '${event['provider_id']}',
        )
        .firstOrNull;
    if (cal == null) return;
    final result = await _eventForm(
      category: 'Editar',
      calendar: cal,
      existing: event,
    );
    if (result == null) return;
    final confirmed = await _confirm(
      'Confirmar alteração',
      _eventSummary(result, cal),
    );
    if (!confirmed) return;
    await _run(() async {
      await _api.saveEvent(result, action: 'update');
      await _loadEvents();
    });
  }

  Future<void> _deleteEvent(Map<String, dynamic> event) async {
    if (!await _confirm(
      'Excluir evento',
      '${_title(event)}\n${_startText(event)}\n${event['account']} • ${event['provider']} • ${event['calendar']}',
    )) {
      return;
    }
    await _run(() async {
      await _api.saveEvent(event, action: 'delete');
      await _loadEvents();
    });
  }

  String _eventSummary(Map<String, dynamic> e, Map c) =>
      '${_title(e)}\n${_startText(e)}\n${c['account']} • ${c['provider']} • ${c['name']}';
  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;
  Future<Map<String, dynamic>?> _eventForm({
    required String category,
    required Map calendar,
    Map<String, dynamic>? existing,
  }) async {
    final title = TextEditingController(text: _title(existing ?? {}));
    final now = DateTime.now().add(const Duration(hours: 1));
    var allDay =
        existing != null &&
        (existing['isAllDay'] == true ||
            (existing['start'] as Map?)?['date'] != null);
    var start = existing == null
        ? DateTime(now.year, now.month, now.day, now.hour)
        : allDay
        ? _eventStart(existing)
        : _eventStart(existing).toLocal();
    final rawEnd = existing == null
        ? null
        : DateTime.tryParse(
            '${((existing['end'] as Map?)?['dateTime'] ?? (existing['end'] as Map?)?['date'])}',
          );
    var end = existing == null
        ? start.add(const Duration(hours: 1))
        : rawEnd == null
        ? start.add(const Duration(hours: 1))
        : allDay
        ? DateTime(rawEnd.year, rawEnd.month, rawEnd.day - 1)
        : rawEnd.toLocal();
    var teams = existing?['isOnlineMeeting'] == true;
    final provider = '${calendar['provider_id']}';
    final form = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
            existing == null ? 'Novo evento $category' : 'Editar evento',
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Título'),
                ),
                ListTile(
                  title: Text(
                    'Início: ${MaterialLocalizations.of(ctx).formatShortDate(start)}${allDay ? '' : ' ${MaterialLocalizations.of(ctx).formatTimeOfDay(TimeOfDay.fromDateTime(start))}'}',
                  ),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: start,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (!ctx.mounted) return;
                    if (d == null) return;
                    if (allDay) {
                      setLocal(() => start = DateTime(d.year, d.month, d.day));
                      return;
                    }
                    final t = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(start),
                    );
                    if (t != null) {
                      setLocal(
                        () => start = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          t.hour,
                          t.minute,
                        ),
                      );
                    }
                  },
                ),
                ListTile(
                  title: Text(
                    'Fim: ${MaterialLocalizations.of(ctx).formatShortDate(end)}${allDay ? '' : ' ${MaterialLocalizations.of(ctx).formatTimeOfDay(TimeOfDay.fromDateTime(end))}'}',
                  ),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: end,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (!ctx.mounted) return;
                    if (d == null) return;
                    if (allDay) {
                      setLocal(() => end = DateTime(d.year, d.month, d.day));
                      return;
                    }
                    final t = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(end),
                    );
                    if (t != null) {
                      setLocal(
                        () => end = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          t.hour,
                          t.minute,
                        ),
                      );
                    }
                  },
                ),
                CheckboxListTile(
                  value: allDay,
                  title: const Text('Dia inteiro'),
                  onChanged: (v) => setLocal(() => allDay = v ?? false),
                ),
                if (provider == 'microsoft_calendar')
                  CheckboxListTile(
                    value: teams,
                    title: const Text('Reunião online do Teams'),
                    onChanged: allDay
                        ? null
                        : (v) => setLocal(() => teams = v ?? false),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'summary': title.text.trim(),
                'subject': title.text.trim(),
                'start': _providerDate(provider, start, allDay: allDay),
                'end': _providerDate(
                  provider,
                  end,
                  allDay: allDay,
                  endOfAllDay: true,
                ),
                'isAllDay': allDay,
                'provider_id': provider,
                'calendar_id': calendar['id'],
                'id': existing?['id'],
                'isOnlineMeeting': teams,
                'onlineMeetingProvider': 'teams',
              }),
              child: const Text('Continuar'),
            ),
          ],
        ),
      ),
    );
    title.dispose();
    if (form == null || '${form['summary']}'.isEmpty) return null;
    return {...?existing, ...form};
  }

  Map<String, dynamic> _providerDate(
    String provider,
    DateTime d, {
    bool allDay = false,
    bool endOfAllDay = false,
  }) {
    if (allDay) {
      final date = DateTime(d.year, d.month, d.day + (endOfAllDay ? 1 : 0));
      final text =
          '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      return provider == 'google_calendar'
          ? {'date': text}
          : {'dateTime': '${text}T00:00:00', 'timeZone': 'UTC'};
    }
    return provider == 'google_calendar'
        ? {'dateTime': _offsetIso(d), 'timeZone': 'America/Sao_Paulo'}
        : {'dateTime': d.toUtc().toIso8601String(), 'timeZone': 'UTC'};
  }

  String _offsetIso(DateTime d) {
    final offset = d.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final n = offset.abs();
    return '${d.toIso8601String()}$sign${n.inHours.toString().padLeft(2, '0')}:${(n.inMinutes % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _openMessage(Map<String, dynamic> m) async {
    String body;
    try {
      body = await _api.readMessage(m);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${m['subject'] ?? '(Sem assunto)'}\n${m['from']} • ${m['account']}',
        ),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: SelectableText(body.replaceAll(RegExp(r'<[^>]*>'), ' ')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fechar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (await _confirm(
                'Alterar estado da mensagem',
                '${m['subject']}\n${m['from']}\nConta: ${m['account']}\nMarcar como ${m['isRead'] == true ? 'não lida' : 'lida'}?',
              )) {
                await _run(() async {
                  await _api.setRead(m, m['isRead'] != true);
                  await _loadMessages();
                });
              }
            },
            child: Text(
              m['isRead'] == true ? 'Marcar não lida' : 'Marcar lida',
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ModuleScaffold(
    moduleId: 'agenda-email',
    subtitle: 'Agendas e e-mails das contas Google e Microsoft',
    actions: [
      IconButton(
        tooltip: 'Configurações de conexão OAuth',
        onPressed: _busy ? null : _abrirConfiguracoesConexao,
        icon: const Icon(Icons.settings_outlined),
      ),
      IconButton(
        tooltip: 'Atualizar',
        onPressed: _busy ? null : () => _run(_refreshConnections),
        icon: const Icon(Icons.refresh),
      ),
    ],
    body: _corpo(),
  );

  Widget _corpo() => Column(
    children: [
      if (_error != null || _busy)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Column(
            children: [
              if (_error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Text(_error!),
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'Agenda'),
          Tab(text: 'E-mail'),
        ],
        onTap: (i) {
          if (i == 1) unawaited(_loadMessages());
        },
      ),
      Expanded(
        child: TabBarView(
          controller: _tabs,
          children: [_calendarView(), _mailView()],
        ),
      ),
    ],
  );
  Widget _calendarView() => Column(
    children: [
      _calendarToolbar(),
      Expanded(
        child: _calendars.isEmpty
            ? Center(
                child: TextButton.icon(
                  onPressed: _abrirConfiguracoesConexao,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Conecte uma agenda em Configurações'),
                ),
              )
            : Row(
                children: [
                  SizedBox(width: 272, child: _calendarSidebar()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _weekGrid()),
                ],
              ),
      ),
    ],
  );

  Widget _calendarToolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Row(
      children: [
        FilledButton.icon(
          onPressed: _calendars.isEmpty
              ? null
              : () => _createEvent('Profissional'),
          icon: const Icon(Icons.add),
          label: const Text('Criar'),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Semana anterior',
          onPressed: () {
            setState(
              () => _weekStart = _weekStart.subtract(const Duration(days: 7)),
            );
            unawaited(_loadEvents());
          },
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: 'Próxima semana',
          onPressed: () {
            setState(
              () => _weekStart = _weekStart.add(const Duration(days: 7)),
            );
            unawaited(_loadEvents());
          },
          icon: const Icon(Icons.chevron_right),
        ),
        TextButton(
          onPressed: () {
            final today = DateTime.now();
            setState(
              () => _weekStart = DateTime(
                today.year,
                today.month,
                today.day - today.weekday + 1,
              ),
            );
            unawaited(_loadEvents());
          },
          child: const Text('Hoje'),
        ),
        const SizedBox(width: 12),
        Text(_weekTitle(), style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        const Chip(
          avatar: Icon(Icons.calendar_view_week_outlined, size: 18),
          label: Text('Semana'),
        ),
      ],
    ),
  );

  String _weekTitle() {
    final end = _weekStart.add(const Duration(days: 6));
    return '${MaterialLocalizations.of(context).formatMediumDate(_weekStart)} — ${MaterialLocalizations.of(context).formatMediumDate(end)}';
  }

  Widget _calendarSidebar() => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      Text('Meus calendários', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      for (final c in _calendars)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          secondary: CircleAvatar(
            radius: 6,
            backgroundColor: _calendarColor(c),
          ),
          value: _classification[_key(c)] != 'hidden',
          title: Text('${c['name']}', overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${c['provider']}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          onChanged: (show) {
            setState(
              () => _classification[_key(c)] = show == true
                  ? (_classification[_key(c)] == 'hidden'
                        ? 'Pessoal'
                        : _classification[_key(c)] ?? 'Pessoal')
                  : 'hidden',
            );
            unawaited(_saveCalendarPrefs());
          },
        ),
      const Divider(height: 28),
      Text('Calendários padrão', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      _defaultPicker('Pessoal', _defaultPersonal, (v) {
        _defaultPersonal = v;
        unawaited(_saveCalendarPrefs());
      }),
      const SizedBox(height: 10),
      _defaultPicker('Profissional', _defaultProfessional, (v) {
        _defaultProfessional = v;
        unawaited(_saveCalendarPrefs());
      }),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: _abrirConfiguracoesConexao,
        icon: const Icon(Icons.settings_outlined),
        label: const Text('Gerenciar conexões'),
      ),
    ],
  );

  Widget _weekGrid() => LayoutBuilder(
    builder: (context, constraints) => Column(
      children: [
        Row(
          children: [
            for (var index = 0; index < 7; index++)
              Expanded(
                child: _dayHeader(_weekStart.add(Duration(days: index))),
              ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              for (var index = 0; index < 7; index++)
                Expanded(
                  child: _dayColumn(
                    _weekStart.add(Duration(days: index)),
                    index < 6,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _dayHeader(DateTime day) {
    final today = DateUtils.isSameDay(day, DateTime.now());
    const weekdays = ['SEG', 'TER', 'QUA', 'QUI', 'SEX', 'SÁB', 'DOM'];
    return Container(
      height: 58,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            weekdays[day.weekday - 1],
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 3),
          CircleAvatar(
            radius: 15,
            backgroundColor: today
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            foregroundColor: today
                ? Theme.of(context).colorScheme.onPrimary
                : null,
            child: Text('${day.day}'),
          ),
        ],
      ),
    );
  }

  Widget _dayColumn(DateTime day, bool divider) {
    final dayEvents = _events
        .where(
          (event) => DateUtils.isSameDay(_eventStart(event).toLocal(), day),
        )
        .toList();
    return Container(
      decoration: BoxDecoration(
        border: divider
            ? Border(right: BorderSide(color: Theme.of(context).dividerColor))
            : null,
      ),
      child: ListView(
        padding: const EdgeInsets.all(5),
        children: [
          for (final event in dayEvents) _eventBlock(event),
          if (dayEvents.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Icon(
                Icons.more_horiz,
                size: 16,
                color: Theme.of(context).disabledColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _eventBlock(Map<String, dynamic> event) => InkWell(
    onTap: () => _editEvent(event),
    onLongPress: () => _deleteEvent(event),
    borderRadius: BorderRadius.circular(5),
    child: Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _eventColor(event).withValues(alpha: 0.18),
        border: Border(left: BorderSide(color: _eventColor(event), width: 3)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        '${_eventTime(event)} ${_title(event)}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelMedium,
      ),
    ),
  );

  String _eventTime(Map event) => (event['start'] as Map?)?['date'] != null
      ? 'Todo dia'
      : MaterialLocalizations.of(
          context,
        ).formatTimeOfDay(TimeOfDay.fromDateTime(_eventStart(event).toLocal()));

  Color _eventColor(Map event) {
    final calendar = _calendars
        .where(
          (item) =>
              '${item['id']}' == '${event['calendar_id']}' &&
              '${item['provider_id']}' == '${event['provider_id']}',
        )
        .firstOrNull;
    return _calendarColor(calendar ?? event);
  }

  Color _calendarColor(Map calendar) {
    final raw = '${calendar['backgroundColor'] ?? ''}'.trim();
    final hex = raw.startsWith('#') ? raw.substring(1) : raw;
    if (RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return Color(0xFF000000 | int.parse(hex, radix: 16));
    }
    const palette = [
      Color(0xFF1A73E8), // azul
      Color(0xFF0B8043), // verde
      Color(0xFFE37400), // laranja
      Color(0xFF9334E6), // roxo
      Color(0xFFC5221F), // vermelho
      Color(0xFF00838F), // turquesa
      Color(0xFF5F6368), // cinza
    ];
    final id =
        '${calendar['provider_id']}:${calendar['id'] ?? calendar['calendar_id']}';
    return palette[id.hashCode.abs() % palette.length];
  }

  Widget _defaultPicker(
    String label,
    String current,
    ValueChanged<String> onChanged,
  ) {
    final selected = _calendars
        .where((calendar) => _key(calendar) == current)
        .firstOrNull;
    return ListTile(
      dense: true,
      minVerticalPadding: 2,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: Theme.of(context).textTheme.labelMedium),
      subtitle: Text(
        selected == null
            ? 'Não definido'
            : '${selected['provider']} • ${selected['name']}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Escolher calendário padrão $label',
        icon: const Icon(Icons.arrow_drop_down),
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final calendar in _calendars)
            PopupMenuItem(
              value: _key(calendar),
              child: SizedBox(
                width: 260,
                child: Text(
                  '${calendar['provider']} • ${calendar['name']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mailView() => Row(
    children: [
      SizedBox(width: 220, child: _mailSidebar()),
      const VerticalDivider(width: 1),
      Expanded(child: _mailContent()),
    ],
  );

  Widget _mailSidebar() => Padding(
    padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Escrever'),
        ),
        const SizedBox(height: 14),
        _mailNav('Caixa de entrada', Icons.inbox_outlined, !_unread),
        _mailNav('Não lidos', Icons.mark_email_unread_outlined, _unread),
        _mailNav('Com estrela', Icons.star_border, false),
        const Spacer(),
        TextButton.icon(
          onPressed: _abrirConfiguracoesConexao,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Gerenciar contas'),
        ),
      ],
    ),
  );

  Widget _mailNav(String label, IconData icon, bool selected) => ListTile(
    dense: true,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    selected: selected,
    selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
    leading: Icon(icon),
    title: Text(label),
    onTap: label == 'Não lidos'
        ? () {
            setState(() => _unread = true);
            unawaited(_loadMessages());
          }
        : label == 'Caixa de entrada'
        ? () {
            setState(() => _unread = false);
            unawaited(_loadMessages());
          }
        : null,
  );

  Widget _mailContent() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar remetente ou assunto',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _run(() => _loadMessages()),
              ),
            ),
            FilterChip(
              label: const Text('Não lidos'),
              selected: _unread,
              onSelected: (v) {
                setState(() => _unread = v);
                unawaited(_loadMessages());
              },
            ),
          ],
        ),
      ),
      Expanded(
        child: _messages.isEmpty
            ? Center(
                child: TextButton.icon(
                  onPressed: _abrirConfiguracoesConexao,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text(
                    'Conecte Gmail ou Outlook em Configurações',
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Card(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        headingRowColor: WidgetStatePropertyAll(
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                        columns: const [
                          DataColumn(label: Text('')),
                          DataColumn(label: Text('ASSUNTO')),
                          DataColumn(label: Text('REMETENTE')),
                          DataColumn(label: Text('CONTA / ORIGEM')),
                          DataColumn(label: Text('RECEBIDO')),
                        ],
                        rows: [
                          for (final m in _messages)
                            DataRow(
                              onSelectChanged: (_) => _openMessage(m),
                              cells: [
                                DataCell(
                                  Icon(
                                    m['isRead'] == true
                                        ? Icons.drafts_outlined
                                        : Icons.mark_email_unread_outlined,
                                    color: m['isRead'] == true
                                        ? null
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 300,
                                    child: Text(
                                      '${m['subject'] ?? '(Sem assunto)'}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 220,
                                    child: Text(
                                      '${m['from']}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 190,
                                    child: Text(
                                      '${m['account']} • ${m['provider']}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                DataCell(Text('${m['receivedDateTime']}')),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_hasMoreMail)
                    Center(
                      child: TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(() => _loadMessages(append: true)),
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Carregar mais mensagens'),
                      ),
                    ),
                ],
              ),
      ),
    ],
  );
}
