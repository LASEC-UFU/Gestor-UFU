import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integration_service.dart';

class IntegracoesPessoaisPage extends StatefulWidget {
  const IntegracoesPessoaisPage({super.key});
  @override
  State<IntegracoesPessoaisPage> createState() =>
      _IntegracoesPessoaisPageState();
}

class _IntegracoesPessoaisPageState extends State<IntegracoesPessoaisPage>
    with SingleTickerProviderStateMixin {
  final _api = IntegrationService();
  final _search = TextEditingController();
  late final _tabs = TabController(length: 2, vsync: this);
  final _connected = <String, bool>{};
  final _calendars = <Map<String, dynamic>>[];
  final _events = <Map<String, dynamic>>[];
  final _messages = <Map<String, dynamic>>[];
  final _classification = <String, String>{};
  bool _unread = false, _busy = false;
  int _mailPage = 0;
  bool _hasMoreMail = false;
  String? _error;
  String _defaultPersonal = '', _defaultProfessional = '';
  @override
  void initState() {
    super.initState();
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
    final prefs = await SharedPreferences.getInstance();
    _defaultPersonal = prefs.getString('calendar.default.personal') ?? '';
    _defaultProfessional =
        prefs.getString('calendar.default.professional') ?? '';
    final raw = prefs.getString('calendar.classification');
    if (raw != null)
      try {
        _classification.addAll(
          Map<String, String>.from(jsonDecode(raw) as Map),
        );
      } catch (_) {}
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
  Future<void> _loadCalendars() async {
    if (!_connected.values.any((v) => v)) {
      if (mounted)
        setState(() {
          _calendars.clear();
          _events.clear();
        });
      return;
    }
    try {
      final rows = await _api.calendars();
      if (mounted)
        setState(() {
          _calendars
            ..clear()
            ..addAll(rows);
        });
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
    final now = DateTime.now();
    final list = await _api.events(
      DateTime(now.year, now.month, now.day),
      DateTime(now.year, now.month, now.day + 14),
      selected,
    );
    if (mounted)
      setState(() {
        _events
          ..clear()
          ..addAll(list)
          ..sort((a, b) => _eventStart(a).compareTo(_eventStart(b)));
      });
  }

  Future<void> _saveCalendarPrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('calendar.default.personal', _defaultPersonal);
    await p.setString('calendar.default.professional', _defaultProfessional);
    await p.setString('calendar.classification', jsonEncode(_classification));
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
    if (mounted)
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
    ))
      return;
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
                    if (t != null)
                      setLocal(
                        () => start = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          t.hour,
                          t.minute,
                        ),
                      );
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
                    if (t != null)
                      setLocal(
                        () => end = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          t.hour,
                          t.minute,
                        ),
                      );
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

  Widget _providerCard(String id, String title, String detail) => Card(
    child: ListTile(
      leading: Icon(_connected[id] == true ? Icons.link : Icons.link_off),
      title: Text(title),
      subtitle: Text(detail),
      trailing: _connected[id] == true
          ? TextButton(
              onPressed: _busy ? null : () => _disconnect(id),
              child: const Text('Desconectar'),
            )
          : TextButton(
              onPressed: _busy ? null : () => _connect(id),
              child: const Text('Conectar'),
            ),
    ),
  );
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Agendas e E-mails',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'As mensagens e eventos permanecem nos provedores de origem. Senhas não são solicitadas. Permissões delegadas são exibidas pelo provedor durante OAuth.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _providerCard(
                  'google_calendar',
                  'Google Calendar',
                  'calendar.events + calendarlist.readonly',
                ),
                _providerCard(
                  'google_mail',
                  'Gmail',
                  'gmail.modify: leitura e estado lido',
                ),
                _providerCard(
                  'microsoft_calendar',
                  'Microsoft Calendar',
                  'Calendars.ReadWrite; pode exigir consentimento CTIC',
                ),
                _providerCard(
                  'microsoft_mail',
                  'Microsoft Outlook',
                  'Mail.ReadWrite; pode exigir consentimento CTIC',
                ),
              ],
            ),
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
  Widget _calendarView() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (_calendars.isNotEmpty) ...[
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              onPressed: () => _createEvent('Pessoal'),
              icon: const Icon(Icons.add),
              label: const Text('Nova atividade pessoal'),
            ),
            OutlinedButton.icon(
              onPressed: () => _createEvent('Profissional'),
              icon: const Icon(Icons.add),
              label: const Text('Nova atividade profissional'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Calendários disponíveis',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final c in _calendars)
          Card(
            child: ListTile(
              leading: const Icon(Icons.calendar_today),
              title: Text('${c['name']}'),
              subtitle: Text('${c['account']} • ${c['provider']}'),
              trailing: DropdownButton<String>(
                value: _classification[_key(c)] ?? 'Pessoal',
                items: const [
                  DropdownMenuItem(value: 'Pessoal', child: Text('Pessoal')),
                  DropdownMenuItem(
                    value: 'Profissional',
                    child: Text('Profissional'),
                  ),
                  DropdownMenuItem(value: 'hidden', child: Text('Oculto')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _classification[_key(c)] = v);
                  unawaited(_saveCalendarPrefs());
                },
              ),
            ),
          ),
        _defaultPicker('Atividades pessoais', _defaultPersonal, (v) {
          _defaultPersonal = v;
          unawaited(_saveCalendarPrefs());
        }),
        _defaultPicker('Atividades profissionais', _defaultProfessional, (v) {
          _defaultProfessional = v;
          unawaited(_saveCalendarPrefs());
        }),
        const Divider(),
        Text(
          'Próximos 14 dias',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final e in _events)
          Card(
            child: ListTile(
              title: Text(_title(e)),
              subtitle: Text(
                '${_startText(e)}\n${e['account']} • ${e['provider']} • ${e['calendar']}',
              ),
              isThreeLine: true,
              onTap: () => _editEvent(e),
              trailing: PopupMenuButton<String>(
                onSelected: (v) =>
                    v == 'edit' ? _editEvent(e) : _deleteEvent(e),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Editar')),
                  PopupMenuItem(value: 'delete', child: Text('Excluir')),
                ],
              ),
            ),
          ),
      ] else
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Conecte uma conta de agenda para carregar calendários de origem.',
          ),
        ),
    ],
  );
  Widget _defaultPicker(
    String label,
    String current,
    ValueChanged<String> onChanged,
  ) => DropdownButtonFormField<String>(
    initialValue: _calendars.any((c) => _key(c) == current) ? current : null,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final c in _calendars)
        DropdownMenuItem(
          value: _key(c),
          child: Text(
            '${c['provider']} • ${c['name']}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );
  Widget _mailView() => Column(
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
            ? const Center(
                child: Text('Conecte Gmail ou Outlook, ou ajuste a busca.'),
              )
            : ListView.builder(
                itemCount: _messages.length + (_hasMoreMail ? 1 : 0),
                itemBuilder: (ctx, i) {
                  if (i == _messages.length)
                    return Center(
                      child: TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(() => _loadMessages(append: true)),
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Carregar mais mensagens'),
                      ),
                    );
                  final m = _messages[i];
                  return ListTile(
                    leading: Icon(
                      m['isRead'] == true
                          ? Icons.drafts_outlined
                          : Icons.mark_email_unread_outlined,
                    ),
                    title: Text(
                      '${m['subject'] ?? '(Sem assunto)'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${m['from']} • ${m['account']}\n${m['receivedDateTime']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _openMessage(m),
                  );
                },
              ),
      ),
    ],
  );
}
