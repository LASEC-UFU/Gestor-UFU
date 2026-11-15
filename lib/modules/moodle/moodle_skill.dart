import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill moodleSkill() => ModuleSkill(
  title: 'Config Moodle',
  summary: 'Planejamento de disciplinas (seções e atividades do Moodle).',
  body: '''
## Para que serve
Monta o cronograma de uma disciplina no Moodle (seções semanais e atividades
com datas) a partir da data de início do semestre, e sincroniza com o curso
real no Moodle (cria/atualiza seções e atividades, datas e visibilidade).

## Onde fica cada ação (tela Config Moodle)
- Botão "Novo" abre: "Nova Configuração Vazia" (criar do zero), "Importar
  Planilha" (.xlsx), "Baixar Planilha Modelo" e "Importar do Moodle" (cria a
  configuração a partir de um curso existente; pede login no Moodle e a data
  de início do semestre). Se já existir configuração com o mesmo nome, o app
  pergunta "Criar nova" ou "Substituir".
- No cartão de cada configuração (menu): Sincronizar Moodle (prévia das
  mudanças antes de aplicar, com log), Exportar XLSX, Tabela Word (gera HTML
  com a tabela para colar no Word), Histórico e backups (versões
  anteriores), Excluir. Clicar no cartão abre o editor.
- Editor (tabela): Nova Seção, Adicionar Atividade, Editar/Renomear, arrastar
  para reordenar, Datas Especiais (feriados e trocas de dia, botão "Adicionar
  feriado"), Vincular Seção / Desvincular (liga seções às do Moodle), data de
  cada seção. Tipos com horário de abertura/fechamento: Tarefa, Questionário,
  Pesquisa, Escolha.
- "Baixar Planilha Modelo" gera o mesmo modelo de `create_template(template:
  "moodle_planilha")` (formato da importação, com exemplos).

## Importação de planilha (.xlsx) — formato aceito
Cada aba vira uma configuração (nome = nome da aba), exceto as abas
`_Datas Especiais` e `_Trocas de Dia`.
- Em qualquer linha acima do cabeçalho: célula "Inicio do Semestre:" com a
  data logo à direita (data do Excel); "Disciplina:" com o nome do curso no
  Moodle à direita; "Moodle Course ID:" com o id à direita.
- Cabeçalho (linha que contém "Ordem" e "Tipo"): Ordem | Dias Início | Hora
  Início | Dias Término | Hora Término | Nome | Tipo | Modalidade | Visível |
  Descrição Moodle | Moodle ID | Moodle Module Name | Dia Semana Esperado.
  Obrigatórias: Nome, Tipo e Dias Início (a ordem das colunas é livre).
- Linha de seção: Tipo = "Seção", Ordem = número, Dias Início = dias desde o
  início do semestre, Visível = Sim/Não, Descrição Moodle = HTML/texto.
- Linhas seguintes (até a próxima seção) são atividades daquela seção: Dias
  Início/Término = dias contados a partir da data da SEÇÃO; Hora = "HH:MM";
  Tipo = nome em português (Tarefa, Questionário, Fórum, Arquivo, URL,
  Página, Pasta, Wiki, Glossário, Lição, H5P, Base de dados, Diário, Presença,
  ConferênciaWeb, Jitsi, Livro, Pacote SCORM, Conteúdo do pacote IMS,
  Certificado Simples, Checklist, GeoGebra, Laboratório de Avaliação,
  Pesquisa, Escolha, Atividade Hot Potatoes, Área de texto e mídia);
  Modalidade = Teórica ou Prática (vazio = não informado); Visível = Sim, Não
  ou Stealth; Dia Semana Esperado = 1 (segunda) … 7 (domingo).
- Aba `_Datas Especiais`: coluna Data (feriados/dias sem aula).
- Aba `_Trocas de Dia`: Data | Dia Semana Efetivo (1–7).
- Datas escritas nos nomes/descrições viram macros automaticamente. Macros:
  <DD/MM/YYYY>, <DD/MM/YYYY + 7>, <DD/MM/YYYY - 2>, <DD>, <D>, <MM>, <M>,
  <YYYY> (somas em dias, relativas à data da seção); sufixo AI = data de
  abertura da atividade, AF = data de fechamento (ex.: "<DD/MM/YYYY>AF").
Modelo: `create_template("moodle_planilha", rows: [...], options:
{sheet_name, course_name, moodle_course_id, semester_start, holidays,
day_swaps})`;
cada linha de `rows` segue a ordem das 13 colunas acima.

## Diagnóstico de importação
"Nenhuma configuração encontrada"/aba ignorada: falta a linha com "Ordem" e
"Tipo", ou faltam as colunas Nome/Tipo/Dias Início, ou não há nenhuma linha
"Seção" antes das atividades. Data de início ausente → usa a data de hoje.

## Banco
Chave: `config_moodle_data` — JSON objeto { <idDaConfig>: CourseConfig }.
Histórico de versões (somente leitura): `moodle_config_history_v1`.
CourseConfig: id (uuid = chave), name, academicTerm, moodleCourseId
(int|null), moodleCourseName, semesterStartDate/createdAt/updatedAt (ISO),
holidayDates [ISO], daySwapDates {"<ISO>": weekday}, sections [SectionEntry].
SectionEntry: id, orderIndex, name, date (ISO), offsetDays,
referenceDaysOffset, moodleSectionId (int|null), visible, moodleDescription,
activities [ActivityEntry].
ActivityEntry: id, name, activityType (nome em PORTUGUÊS, ex. "Tarefa"),
openDate/closeDate (ISO|null), openOffsetDays/closeOffsetDays (relativos à
seção), openTimeMinutes/closeTimeMinutes (minutos desde 00:00),
moodleModuleId, moodleModuleName, modality ("Teórica"|"Prática"|null),
visibility (0 oculto, 1 visível, 2 stealth), expectedWeekday (1–7|null).
Mantenha orderIndex sequencial, offsetDays = date − semesterStartDate e
atualize updatedAt. Não altere ids do Moodle sem pedido explícito.

## Comandos (run_command)
moodle.listar, moodle.importarPlanilha, moodle.exportarPlanilha, moodle.excluir
(pede confirmação), moodle.abrirEditor e moodle.abrirSincronizacao (abre a
prévia para o usuário conferir e aplicar). Modelo: create_template
moodle_planilha.
Prefira os comandos às gravações diretas no banco: eles aplicam as mesmas
regras da tela.
''',
);
