import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/modules/agenda_email/application/agenda_email_commands.dart';
import 'package:gestor_ufu/modules/agenda_email/application/integration_service.dart';
import 'package:gestor_ufu/modules/agenda_email/application/preferencias_agenda.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

void main() {
  test('exposes only the requested calendar and mail operations', () {
    final commands = agendaEmailCommands(IntegrationService());
    final ids = {for (final c in commands) c.id};
    expect(
      ids,
      containsAll([
        'agenda.listarCalendarios',
        'agenda.listarEventos',
        'agenda.criarEvento',
        'agenda.atualizarEvento',
        'agenda.excluirEvento',
        'email.listar',
        'email.ler',
        'email.alterarLido',
      ]),
    );
    expect(
      ids.any(
        (id) =>
            id.contains('enviar') ||
            id.contains('arquivar') ||
            id.contains('mover') ||
            id.contains('responder'),
      ),
      isFalse,
    );
  });
  test('every external write asks for explicit approval', () {
    final commands = {
      for (final c in agendaEmailCommands(IntegrationService())) c.id: c,
    };
    for (final id in [
      'agenda.criarEvento',
      'agenda.atualizarEvento',
      'agenda.excluirEvento',
      'email.ler',
      'email.alterarLido',
    ]) {
      expect(commands[id]!.approval, CommandApproval.required, reason: id);
    }
    for (final id in [
      'agenda.listarCalendarios',
      'agenda.listarEventos',
      'email.listar',
    ]) {
      expect(commands[id]!.approval, CommandApproval.none, reason: id);
    }
  });

  group('preferências', () {
    test('migra as chaves antigas e acha o padrão profissional', () async {
      SharedPreferences.setMockInitialValues({
        'calendar.default.personal': 'google_calendar:pessoal',
        'calendar.default.professional': 'microsoft_calendar:ufu',
        'calendar.classification': '{"microsoft_calendar:ufu":"Profissional"}',
      });
      final p = PreferenciasAgenda();
      expect(await p.calendarioPadrao('Pessoal'), 'google_calendar:pessoal');
      // Antes, "Profissional" procurava a chave "...profissional" e não
      // achava o calendário gravado pela tela em "...professional".
      expect(
        await p.calendarioPadrao('Profissional'),
        'microsoft_calendar:ufu',
      );
      expect(await p.classificacao(), {
        'microsoft_calendar:ufu': 'Profissional',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PreferenciasAgenda.profissionalKey),
        'microsoft_calendar:ufu',
      );

      await p.salvar(
        pessoal: 'a',
        profissional: 'b',
        classificacao: {'a': 'Pessoal'},
      );
      final outra = PreferenciasAgenda();
      expect(await outra.calendarioPessoal(), 'a');
      expect(await outra.calendarioProfissional(), 'b');
    });
  });

  test('ids dos comandos em camelCase (padrão dos módulos)', () {
    for (final c in agendaEmailCommands(IntegrationService())) {
      expect(c.id, matches(RegExp(r'^[a-z]+\.[a-z][a-zA-Z]*$')), reason: c.id);
    }
  });
}
