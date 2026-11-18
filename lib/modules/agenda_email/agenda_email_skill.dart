import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo Agendas e E-mails entregue ao Agente de IA.
ModuleSkill agendaEmailSkill() => const ModuleSkill(
  title: 'Agendas e E-mails',
  summary:
      'Agendas e e-mails das contas Google e Microsoft conectadas: consultar '
      'e editar eventos, ler mensagens sob pedido e marcar lido/não lido.',
  body: '''
## Para que serve
A tela (`/agendas-e-emails`) conecta contas Google (Calendar, Gmail) e
Microsoft (Calendário, Outlook) por OAuth, sem pedir senhas. Na aba Agenda,
o usuário vê os eventos, classifica cada calendário como Pessoal ou
Profissional e escolhe o calendário padrão de cada um; na aba E-mail, lista
as mensagens (só metadados) e abre o conteúdo quando quiser. Eventos e
mensagens continuam nos provedores.

## Agenda
- `agenda.listarCalendarios`: calendários (provider_id, id, conta,
  classificação e se é o padrão pessoal/profissional).
- `agenda.listarEventos` {inicio, fim (ISO 8601 com fuso), calendar_id?,
  provider_id?}: eventos do intervalo (recorrências expandidas).
- `agenda.criarEvento` {categoria Pessoal|Profissional, titulo, inicio, fim,
  descricao?, calendar_id?, provider_id?, online_teams?}: sem calendar_id usa
  o padrão da categoria. online_teams=true cria reunião Teams só em conta
  Microsoft.
- `agenda.atualizarEvento` {id, calendar_id, provider_id, titulo?, inicio?,
  fim?} e `agenda.excluirEvento` {id, calendar_id, provider_id}: consulte o
  evento antes.
Pedidos ambíguos sobre Pessoal/Profissional: pergunte a categoria. Antes de
criar, alterar ou excluir, mostre título, horário com fuso, conta, provedor e
calendário e peça confirmação (os três comandos exigem aprovação).

## E-mail
- `email.listar` {busca?, nao_lidos?, pagina?}: só metadados (id,
  assunto, remetente, data, lida, conta, provider_id).
- `email.ler` {id, provider_id, assunto?, remetente?, conta?}: o corpo da mensagem é enviado ao modelo;
  avise o usuário, identifique assunto/remetente/conta e peça
  consentimento (exige aprovação).
- `email.alterarLido` {id, provider_id, lida, assunto?, remetente?,
  conta?}: confirme assunto, remetente e
  conta antes (exige aprovação).
Não envie, exclua, arquive, mova nem responda mensagens. Tokens ficam no
armazenamento seguro do Windows: nunca peça nem mostre tokens.

## Banco
`agenda_email.calendario_pessoal.v1`, `agenda_email.calendario_profissional.v1`
e `agenda_email.classificacao.v1`. Configuração de OAuth e aprovação do CTIC:
docs/integracoes-agenda-email-audita-powershell.md.
''',
);
