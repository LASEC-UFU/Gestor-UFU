import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill diarioSkill() => ModuleSkill(
  title: 'Preenche Diários',
  summary: 'Conteúdos de aula por data e preenchimento do Portal do Docente.',
  body:
      '''
## Para que serve
Monta os conteúdos lecionados por data (aulas teóricas -T e práticas -P) de
cada disciplina e preenche automaticamente o diário eletrônico no Portal do
Docente (diarioEletronico), num navegador Edge controlado pelo app.

## Onde fica cada ação (tela Preenche Diários)
- Seletor de período letivo e "Períodos letivos" (criar/renomear/remover);
  "Novo período letivo".
- Disciplinas (diários salvos): escolher, "Salvar diário atual", "Salvar como
  outro diário", "Remover disciplina selecionada", "Copiar diário de qual
  período?" (traz um diário de outro período, com opção de ajustar datas).
- Fontes de dados: "Importar Excel" (escolhe a aba), carregar JSON e "Salvar
  JSON", "Conectar ao Moodle" (gera as aulas a partir de uma configuração do
  Config Moodle salva ou de um curso do Moodle ao vivo: "Escolha uma
  configuração salva" / "Escolha uma disciplina do Moodle").
- Lançamentos: "Adicionar aula manualmente", Editar, Remover, "Limpar todos os
  lançamentos", "Ajustar datas" (desloca datas; "Escolher nova data no
  calendário").
- Portal do Docente: "Acesso ao Portal do Docente" (login é do usuário),
  abrir navegador, "Preencher diário" (com confirmação; opções Todas / Só T /
  Só P / Selecionadas), "Limpar diário no Portal" (com marcador invisível),
  "Extrair diários do Portal" (traz para o Gestor o que já está lançado),
  "Verificar diários sem preenchimento" e "Copiar datas ausentes".
- Log da operação com "Copiar log".

## Importação de planilha (.xlsx/.xlsm/.xltx/.xltm)
- Cabeçalho procurado nas 10 primeiras linhas: coluna "Data" (ou "Dia"),
  "Modalidade…" e "Matéria Lecionada" (aceita também "Matéria", "Conteúdo",
  "Conteúdo lecionado", "Descrição"). Sem cabeçalho, usa colunas A (data),
  B (modalidade) e D (conteúdo).
- Data: data do Excel, texto DD/MM/AAAA ou fórmula simples (=A2+7).
- Modalidade contendo "teor" → -T; contendo "prat" → -P. Linhas sem data,
  modalidade reconhecida ou conteúdo são ignoradas.
- O resultado é MESCLADO ao rascunho (datas iguais são sobrescritas).
Modelos: `create_template("diario_planilha", rows: [[data, modalidade,
conteúdo], …])` ou `create_template("diario_json", data: {...})`.

## Importação JSON
Objeto {"DD/MM/AAAA -T": "conteúdo", "DD/MM/AAAA -P": "…"}; valores precisam
ser texto; sem sufixo assume -P. Carregar JSON SUBSTITUI o rascunho.

## Banco
${termScopedSkillNote('preenche_diarios_period_data_v1_')}
Valor: { "draftEntries": {"DD/MM/AAAA -T": "conteúdo"}, "sourceLabel":
texto|null, "selectedDiaryId": id|null, "savedDiaries": [ { "id": uuid,
"name": "nome do diário", "entries": {...}, "sourceLabel": texto|null } ] }
Chaves: data com 2 dígitos, ano com 4, espaço, hífen e tipo ("05/03/2026 -T").
Duas aulas do mesmo tipo no mesmo dia podem usar "-T2" (pergunte se não
estiver claro). `draftEntries` é a área de trabalho e espelha o diário
selecionado: ao alterar o diário `selectedDiaryId`, altere TAMBÉM
`draftEntries`. Nomes de diários são únicos; diário novo = item novo em
`savedDiaries` com uuid novo.

## Comandos (run_command)
diario.listar, diario.importarPlanilha, diario.carregarJson, diario.salvarJson,
diario.definirLancamentos, diario.abrirPortal e diario.preencherPortal (pede
confirmação).
Prefira os comandos às gravações diretas no banco: eles aplicam as mesmas
regras da tela.
''',
);
