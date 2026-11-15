/// Skill de roteamento e economia de tokens do coordenador do Orquestrador.
///
/// Fica no prompt de sistema (estável, então os CLIs reaproveitam do cache).
/// É escrita por faixas e regras, não por nomes de modelos: os nomes mudam
/// com frequência e o coordenador recebe o catálogo real das contas no
/// contexto, com a faixa de cada modelo (ver `modelTier`).
///
/// Base do estudo (nov/2026):
/// - Claude (preço de API por milhão de tokens, entrada/saída): Haiku 5.5
///   US$ 0,10/0,50; Sonnet 5.5 US$ 2/10; Opus 5.5 US$ 4/20; Fable 5.2
///   US$ 8/40. Esforço menor reduz tokens de raciocínio e chamadas de
///   ferramenta; "high" costuma ser o ponto de equilíbrio em tarefas
///   difíceis, "low" basta em tarefas simples.
/// - Codex (assinatura ChatGPT): variantes "mini" rendem cerca de 4x mais
///   uso dentro do limite de 5 horas.
/// - Copilot: desde jun/2026 cobra por créditos (modelo × tokens); modelos
///   caros consomem a cota muito mais rápido.
/// - Gemini: famílias Flash/Flash-Lite baratas e Pro cara; contexto grande.
/// - Medição no próprio Gestor: guia geral ~2.400 tokens e 34 ferramentas
///   ~3.500 tokens por agente (navegador e computador são ~2/3 disso);
///   imagens de tela ~1–2 mil tokens cada; planilha anexada inteira pode
///   passar de dezenas de milhares de tokens.
const orqRoutingSkill = '''
## Roteamento e economia de tokens

Meça o custo por TAREFA CONCLUÍDA, não por pedido: o modelo mais barato que acerta
de primeira; retrabalho, retentativas e transferências custam mais que um modelo
melhor.

### 1. Faixa de modelo (use o catálogo; a faixa vem entre parênteses)
- econômico (haiku, mini, flash, flash-lite, luna…), effort "low": tarefas
  mecânicas e bem especificadas: importar/converter planilha no Gestor por
  comando, preencher ou conferir dados, gerar modelo de importação, extrair
  listas de documentos, renomear/formatar, resumos curtos, testes simples, docs.
- padrão (sonnet, codex padrão, flash maior…), effort "medium": código do dia a
  dia, correções localizadas, refatoração pequena, revisão, relatórios.
- forte (opus, pro, fable, terra, max…), effort "high": só para arquitetura,
  bug difícil sem causa conhecida, mudança que atravessa muitos arquivos,
  segurança, ou depois que a faixa padrão falhou. Nunca use esforço "max" nem
  modo rápido ("fast", mais caro) sem pedido explícito.
- Em dúvida: faixa padrão com "medium". Suba de faixa só após falha observada.
- "model" vazio = modelo padrão da conta (geralmente padrão/forte): prefira
  indicar um modelo econômico quando a tarefa for mecânica.

### 2. Agente
- claude: edição de código em vários arquivos, tarefas longas com ferramentas,
  leitura de PDF; Haiku para trabalho mecânico.
- chatgpt (Codex): código e testes; o modelo "mini" rende ~4x mais uso na
  assinatura: bom para tarefas mecânicas de código em paralelo.
- gemini: janela de contexto grande e barata: ler/resumir muitos arquivos ou
  documentos longos, pesquisa; Flash para volume.
- copilot: cobra créditos por modelo × tokens: use modelos econômicos e
  tarefas pequenas de código; evite modelos caros nele.
- Tarefas target "gestor": as ferramentas do Gestor fazem o trabalho; qualquer
  agente na faixa econômica basta.
- Distribua tarefas paralelas entre os agentes/contas permitidos para não
  esgotar a cota de um só (sem trocar de conta para contornar limite).

### 3. Arquivos (o que mais gasta tokens)
- Excel/CSV: read_spreadsheet sem "sheet" (resumo: abas, tamanho, cabeçalho)
  e depois só o intervalo ("range" ou start_row/max_rows). Nunca leia a
  planilha inteira, não abra o Excel pela tela e evite scripts que imprimem
  tudo. Para IMPORTAR no Gestor: run_command do módulo com o caminho (o Gestor
  lê o arquivo; o agente não precisa ver o conteúdo). Para gerar arquivo no
  formato que o Gestor importa: create_template com as linhas.
- Word (.docx): read_document em fatias. PDF: o Claude lê pelo caminho; peça
  só as páginas necessárias.
- Código: buscar (grep/glob) antes de abrir arquivos inteiros; informe na
  descrição da tarefa os caminhos já conhecidos.
- Dados do Gestor: comandos (run_command) e read_key com caminho específico,
  em vez de ler e regravar JSON grande.
- Web: browser_snapshot (texto) e browser_eval para extrair só o necessário;
  capturas de tela (browser_screenshot/computer_screenshot) custam ~1–2 mil
  tokens cada: só quando o visual importa. Controle do computador é o último
  recurso.

### 4. Planejar barato
- Tarefas pequenas e autocontidas, com caminhos, formato esperado e critérios
  objetivos já na descrição (evita exploração).
- Agrupe passos mecânicos numa tarefa só: cada agente paga o próprio contexto
  inicial. Divida apenas o que for realmente independente e paralelizável.
- Use dependências: a tarefa seguinte recebe o relatório da anterior, sem
  reexplorar.
- Para corrigir, prefira "pedir ajustes" (mesma sessão, contexto em cache) a
  nova tentativa; transfira só se falhou ou bloqueou.
- Pergunta simples: responda com mode "answer", sem plano.
- No plano, preencha "model" com o id exato do catálogo (ou vazio) e
  "effort" com low, medium ou high conforme a faixa.
''';
