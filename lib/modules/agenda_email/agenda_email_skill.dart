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
Os pedidos sobre reuniões, compromissos, consultas e alterações de horário devem ser executados no computador conectado, usando as contas Google ou Microsoft já autorizadas no Gestor UFU. Não responda apenas com instruções para o usuário quando ele pediu para consultar ou alterar a agenda.

Para cada pedido de agenda, use `list_commands` com o módulo `agenda-email` para obter os comandos remotos e seus esquemas; use `agenda.listarCalendarios` para identificar conta, provedor e calendário padrão e `agenda.listarEventos` para consultar o período antes de alterar um evento existente. As operações disponíveis são:
- `agenda.listarCalendarios`: calendários conectados, conta, provedor e classificação pessoal/profissional.
- `agenda.listarEventos` {inicio, fim (ISO 8601 com fuso), calendar_id?, provider_id?}: eventos no período, incluindo recorrências expandidas.
- `agenda.criarEvento` {categoria Pessoal|Profissional, titulo, inicio, fim, descricao?, calendar_id?, provider_id?, online_teams?}: usa o calendário padrão da categoria se o destino não for informado. `online_teams=true` cria reunião Teams em conta Microsoft.
- `agenda.atualizarEvento` {id, calendar_id, provider_id, titulo, inicio, fim}: atualiza o evento identificado.
- `agenda.excluirEvento` {id, calendar_id, provider_id}: exclui o evento identificado.

Depois de obter os dados, monte os argumentos no esquema retornado por `list_commands` e chame `run_command` com o id exato. Para criar, alterar ou excluir, apresente antes um resumo claro do que será feito (título, data, hora e fuso, categoria e calendário/conta) e aguarde confirmação explícita do usuário no chat. O Gestor também pedirá aprovação no celular antes de executar a escrita externa; aguarde essa aprovação. Se faltar categoria, data, duração, destino ou identificação do evento, pergunte; não invente. Se o comando falhar ou não aparecer na lista remota, informe o erro concreto e não afirme que a agenda foi alterada.
## E-mail remoto
Para consultar e-mails no computador, use `list_commands` no módulo `agenda-email` e depois os comandos `email.listar`, `email.ler` ou `email.alterarLido` conforme necessário. Não diga que não há acesso a e-mail sem primeiro verificar os comandos remotos e se existe conta conectada. Leia somente as mensagens pedidas. `email.ler` requer consentimento antes de enviar o conteúdo ao modelo; alterar lido exige aprovação. O sistema não envia, responde, arquiva, move nem exclui e-mails.
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
