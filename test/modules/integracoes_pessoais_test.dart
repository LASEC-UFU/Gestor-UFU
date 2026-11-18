import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integration_commands.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integration_service.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

void main() {
  test('exposes only the requested calendar and mail operations', () {
    final commands = integrationCommands(IntegrationService());
    final ids = {for (final c in commands) c.id};
    expect(
      ids,
      containsAll([
        'agenda.listar_calendarios',
        'agenda.listar_eventos',
        'agenda.criar_evento',
        'agenda.atualizar_evento',
        'agenda.excluir_evento',
        'email.listar',
        'email.ler',
        'email.alterar_lido',
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
      for (final c in integrationCommands(IntegrationService())) c.id: c,
    };
    for (final id in [
      'agenda.criar_evento',
      'agenda.atualizar_evento',
      'agenda.excluir_evento',
      'email.ler',
      'email.alterar_lido',
    ]) {
      expect(commands[id]!.approval, CommandApproval.required, reason: id);
    }
    for (final id in [
      'agenda.listar_calendarios',
      'agenda.listar_eventos',
      'email.listar',
    ]) {
      expect(commands[id]!.approval, CommandApproval.none, reason: id);
    }
  });
}
