import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integration_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

List<ModuleCommand> integrationCommands(IntegrationService api) => [
  ModuleCommand(
    id: 'agenda.listar_calendarios',
    title: 'Listar calendários conectados',
    description:
        'Lista calendários reais das contas conectadas e informa provedor, conta e id de origem.',
    run: (_, _) async {
      final prefs = await SharedPreferences.getInstance();
      final personal = prefs.getString('calendar.default.personal') ?? '';
      final professional =
          prefs.getString('calendar.default.professional') ?? '';
      Map<String, String> classifications = {};
      try {
        classifications = Map<String, String>.from(
          jsonDecode(prefs.getString('calendar.classification') ?? '{}') as Map,
        );
      } catch (_) {}
      final calendars = await api.calendars();
      return CommandResult.ok(
        data: {
          'calendarios': [
            for (final c in calendars)
              {
                ...c,
                'classificacao':
                    classifications['${c['provider_id']}:${c['id']}'] ??
                    'Pessoal',
                'padrao_pessoal': '${c['provider_id']}:${c['id']}' == personal,
                'padrao_profissional':
                    '${c['provider_id']}:${c['id']}' == professional,
              },
          ],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'agenda.listar_eventos',
    title: 'Consultar eventos',
    description:
        'Consulta eventos no período ISO informado. Devolve título, horário, conta, provedor, calendário e ids de origem, sem enviar descrição ao modelo.',
    inputSchema: {
      'type': 'object',
      'required': ['inicio', 'fim'],
      'properties': {
        'inicio': {
          'type': 'string',
          'description': 'Data/hora ISO 8601 com fuso',
        },
        'fim': {'type': 'string', 'description': 'Data/hora ISO 8601 com fuso'},
        'calendar_id': {'type': 'string'},
        'provider_id': {
          'type': 'string',
          'enum': ['google_calendar', 'microsoft_calendar'],
        },
      },
    },
    run: (input, _) async {
      final from = DateTime.tryParse(input.requireString('inicio'));
      final to = DateTime.tryParse(input.requireString('fim'));
      if (from == null || to == null || !to.isAfter(from))
        throw const CommandException(
          'periodo_invalido',
          'Informe início e fim ISO válidos; o fim deve ser posterior ao início.',
        );
      final calendars = await api.calendars();
      final id = input.optionalString('calendar_id'),
          provider = input.optionalString('provider_id');
      final selected = calendars
          .where(
            (c) =>
                (id == null || '${c['id']}' == id) &&
                (provider == null || '${c['provider_id']}' == provider),
          )
          .toList();
      if (selected.isEmpty)
        throw const CommandException(
          'calendario_inexistente',
          'Nenhum calendário conectado corresponde aos identificadores informados.',
        );
      final events = await api.events(from, to, selected);
      return CommandResult.ok(
        data: {
          'eventos': [
            for (final e in events)
              {
                'id': e['id'],
                'titulo': e['summary'] ?? e['subject'],
                'inicio': e['start'],
                'fim': e['end'],
                'dia_inteiro':
                    e['isAllDay'] ?? ((e['start'] as Map?)?['date'] != null),
                'conta': e['account'],
                'provedor': e['provider'],
                'calendario': e['calendar'],
                'provider_id': e['provider_id'],
                'calendar_id': e['calendar_id'],
              },
          ],
        },
      );
    },
  ),
  ModuleCommand(
    id: 'agenda.criar_evento',
    title: 'Criar evento de agenda',
    description:
        'Cria evento em calendário configurado. Antes de executar, apresente título, horário/fuso, pessoal/profissional e destino e solicite confirmação explícita. Se categoria não estiver clara, pergunte. Escrita externa exige confirmação.',
    inputSchema: {
      'type': 'object',
      'required': ['categoria', 'titulo', 'inicio', 'fim'],
      'properties': {
        'categoria': {
          'type': 'string',
          'enum': ['Pessoal', 'Profissional'],
        },
        'titulo': {'type': 'string'},
        'inicio': {
          'type': 'string',
          'description': 'ISO 8601 com fuso horário',
        },
        'fim': {'type': 'string', 'description': 'ISO 8601 com fuso horário'},
        'descricao': {'type': 'string'},
        'calendar_id': {'type': 'string'},
        'provider_id': {
          'type': 'string',
          'enum': ['google_calendar', 'microsoft_calendar'],
        },
        'online_teams': {'type': 'boolean'},
      },
    },
    approval: CommandApproval.required,
    mutates: true,
    run: (input, _) async {
      final category = input.requireString('categoria');
      if (!['Pessoal', 'Profissional'].contains(category))
        throw const CommandException(
          'categoria_invalida',
          'Escolha Pessoal ou Profissional.',
        );
      final prefs = await SharedPreferences.getInstance();
      final key =
          prefs.getString('calendar.default.${category.toLowerCase()}') ?? '';
      final all = await api.calendars();
      final requestedId = input.optionalString('calendar_id');
      final requestedProvider = input.optionalString('provider_id');
      final cal = all
          .where(
            (c) => requestedId != null
                ? '${c['id']}' == requestedId &&
                      (requestedProvider == null ||
                          '${c['provider_id']}' == requestedProvider)
                : '${c['provider_id']}:${c['id']}' == key,
          )
          .firstOrNull;
      if (cal == null)
        throw CommandException(
          'destino_nao_configurado',
          'Nenhum calendário padrão $category configurado. Escolha um calendário na tela Agendas e E-mails.',
        );
      final start = DateTime.tryParse(input.requireString('inicio')),
          end = DateTime.tryParse(input.requireString('fim'));
      if (start == null || end == null || !end.isAfter(start))
        throw const CommandException(
          'horario_invalido',
          'Informe horários ISO 8601 válidos e fim posterior ao início.',
        );
      final google = cal['provider_id'] == 'google_calendar';
      final event = <String, dynamic>{
        'provider_id': cal['provider_id'],
        'calendar_id': cal['id'],
        'summary': input.requireString('titulo'),
        'subject': input.requireString('titulo'),
        'description': input.optionalString('descricao'),
        'body': {
          'contentType': 'text',
          'content': input.optionalString('descricao') ?? '',
        },
        'start': _date(start, google),
        'end': _date(end, google),
        'isOnlineMeeting': input.flag('online_teams'),
        'onlineMeetingProvider': 'teams',
      };
      await api.saveEvent(event, action: 'create');
      return CommandResult.ok(
        message:
            'Evento criado em ${cal['provider']} • ${cal['account']} • ${cal['name']}.',
      );
    },
  ),
  ModuleCommand(
    id: 'agenda.atualizar_evento',
    title: 'Atualizar evento',
    description:
        'Altera evento na agenda de origem. Consulte primeiro os eventos, mostre os dados identificadores e as mudanças propostas ao usuário e peça confirmação explícita antes de executar.',
    inputSchema: {
      'type': 'object',
      'required': [
        'id',
        'calendar_id',
        'provider_id',
        'titulo',
        'inicio',
        'fim',
      ],
      'properties': {
        'id': {'type': 'string'},
        'calendar_id': {'type': 'string'},
        'provider_id': {
          'type': 'string',
          'enum': ['google_calendar', 'microsoft_calendar'],
        },
        'titulo': {'type': 'string'},
        'inicio': {'type': 'string'},
        'fim': {'type': 'string'},
      },
    },
    approval: CommandApproval.required,
    mutates: true,
    run: (input, _) async {
      final provider = input.requireString('provider_id');
      final start = DateTime.tryParse(input.requireString('inicio')),
          end = DateTime.tryParse(input.requireString('fim'));
      if (start == null || end == null || !end.isAfter(start))
        throw const CommandException(
          'horario_invalido',
          'Informe início e fim ISO válidos.',
        );
      await api.saveEvent({
        'id': input.requireString('id'),
        'calendar_id': input.requireString('calendar_id'),
        'provider_id': provider,
        'summary': input.requireString('titulo'),
        'subject': input.requireString('titulo'),
        'start': _date(start, provider == 'google_calendar'),
        'end': _date(end, provider == 'google_calendar'),
      }, action: 'update');
      return const CommandResult.ok(
        message: 'Evento atualizado na agenda de origem.',
      );
    },
  ),
  ModuleCommand(
    id: 'agenda.excluir_evento',
    title: 'Excluir evento',
    description:
        'Exclui evento na agenda de origem. Consulte primeiro agenda.listar_eventos e confirme com o usuário título, horário, conta, provedor e calendário antes da aprovação desta exclusão.',
    inputSchema: {
      'type': 'object',
      'required': ['id', 'calendar_id', 'provider_id'],
      'properties': {
        'id': {'type': 'string'},
        'calendar_id': {'type': 'string'},
        'provider_id': {
          'type': 'string',
          'enum': ['google_calendar', 'microsoft_calendar'],
        },
      },
    },
    approval: CommandApproval.required,
    mutates: true,
    run: (input, _) async {
      await api.saveEvent({
        'id': input.requireString('id'),
        'calendar_id': input.requireString('calendar_id'),
        'provider_id': input.requireString('provider_id'),
      }, action: 'delete');
      return const CommandResult.ok(
        message: 'Evento excluído na agenda de origem.',
      );
    },
  ),
  ModuleCommand(
    id: 'email.listar',
    title: 'Consultar mensagens',
    description:
        'Lista metadados de mensagens das contas conectadas. Não retorna corpos de mensagem. Use não_lidos para filtrar; consulta somente os resultados necessários.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'busca': {
          'type': 'string',
          'description': 'Termos de busca no provedor',
        },
        'nao_lidos': {'type': 'boolean'},
        'pagina': {
          'type': 'integer',
          'minimum': 0,
          'maximum': 20,
          'description': 'Página zero-indexed para carregar mais resultados.',
        },
      },
    },
    run: (input, _) async {
      final rows = await api.messages(
        query: input.optionalString('busca') ?? '',
        unreadOnly: input.flag('nao_lidos'),
        page: ((input['pagina'] as num?)?.toInt() ?? 0),
      );
      return CommandResult.ok(
        data: {
          'mensagens': [
            for (final m in rows)
              {
                'id': m['id'],
                'assunto': m['subject'],
                'remetente': m['from'],
                'data': m['receivedDateTime'],
                'lida': m['isRead'],
                'conta': m['account'],
                'provider_id': m['provider_id'],
              },
          ],
          if (rows.length >= 30)
            'proxima_pagina': ((input['pagina'] as num?)?.toInt() ?? 0) + 1,
        },
      );
    },
  ),
  ModuleCommand(
    id: 'email.ler',
    title: 'Ler mensagem original',
    description:
        'Obtém o corpo da mensagem indicada e o fornece ao modelo configurado. Isso compartilha o conteúdo da mensagem com a IA: antes, informe claramente essa transferência e obtenha consentimento explícito para a mensagem identificada por remetente, assunto e conta.',
    inputSchema: {
      'type': 'object',
      'required': ['id', 'provider_id'],
      'properties': {
        'id': {'type': 'string'},
        'provider_id': {
          'type': 'string',
          'enum': ['google_mail', 'microsoft_mail'],
        },
        'assunto': {'type': 'string'},
        'remetente': {'type': 'string'},
        'conta': {'type': 'string'},
      },
    },
    approval: CommandApproval.required,
    run: (input, _) async {
      final message = await api.messageById(
        input.requireString('provider_id'),
        input.requireString('id'),
      );
      _verifyMessage(message, input);
      final body = await api.readMessage(message);
      return CommandResult.ok(
        data: {
          'assunto': message['subject'],
          'remetente': message['from'],
          'conta': message['account'],
          'conteudo': body,
        },
      );
    },
  ),
  ModuleCommand(
    id: 'email.alterar_lido',
    title: 'Alterar estado de leitura',
    description:
        'Marca uma mensagem como lida ou não lida na conta original. Antes, identifique remetente, assunto e conta e solicite confirmação explícita. Não envia, exclui, arquiva nem move mensagens.',
    inputSchema: {
      'type': 'object',
      'required': [
        'id',
        'provider_id',
        'assunto',
        'remetente',
        'conta',
        'lida',
      ],
      'properties': {
        'id': {'type': 'string'},
        'provider_id': {
          'type': 'string',
          'enum': ['google_mail', 'microsoft_mail'],
        },
        'assunto': {'type': 'string'},
        'remetente': {'type': 'string'},
        'conta': {'type': 'string'},
        'lida': {'type': 'boolean'},
      },
    },
    approval: CommandApproval.required,
    mutates: true,
    run: (input, _) async {
      final message = await api.messageById(
        input.requireString('provider_id'),
        input.requireString('id'),
      );
      _verifyMessage(message, input);
      await api.setRead(message, input.flag('lida'));
      return const CommandResult.ok(
        message: 'Estado de leitura alterado na conta de origem.',
      );
    },
  ),
];

void _verifyMessage(Map<String, dynamic> message, CommandInput input) {
  for (final pair in [
    ('assunto', 'subject'),
    ('remetente', 'from'),
    ('conta', 'account'),
  ]) {
    if (input.requireString(pair.$1).toLowerCase() !=
        ('${message[pair.$2] ?? ''}').toLowerCase())
      throw const CommandException(
        'mensagem_alterada',
        'A mensagem não corresponde aos dados confirmados. Consulte novamente e confirme o alvo correto.',
      );
  }
}

Map<String, dynamic> _date(DateTime d, bool google) => google
    ? {'dateTime': _offset(d), 'timeZone': 'America/Sao_Paulo'}
    : {'dateTime': d.toUtc().toIso8601String(), 'timeZone': 'UTC'};
String _offset(DateTime d) {
  // ISO inputs carrying Z or an explicit offset parse as UTC. Convert them
  // back to the user's local wall time before attaching the local offset.
  d = d.toLocal();
  final o = d.timeZoneOffset;
  final n = o.abs();
  return '${d.toIso8601String()}${o.isNegative ? '-' : '+'}${n.inHours.toString().padLeft(2, '0')}:${(n.inMinutes % 60).toString().padLeft(2, '0')}';
}
