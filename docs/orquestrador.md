# Orquestrador

Primeira aba da janela do **Agente de IA**. É o port para Dart/Flutter do [Orchestrator-AI](https://github.com/josuemoraisgh/orchestrator), originalmente uma extensão do VS Code.

O fluxo tem quatro passos:

1. **Pedido:** você descreve o trabalho na aba Orquestrador.
2. **Plano:** o **coordenador** responde com um plano de 1 a 12 tarefas.
3. **Execução:** você aprova, e cada tarefa vai para um **agente trabalhador** (Claude Code, Codex, Gemini ou Copilot), em paralelo.
4. **Revisão:** você confere o resultado de cada tarefa antes de concluí-la.

## Como usar

1. Em ⚙ **Configurações do Orquestrador**, escolha:
   - o coordenador;
   - os trabalhadores permitidos;
   - o paralelismo;
   - a pasta do projeto, se houver;
   - o AI Memory.
2. Na **Conversa**, peça o trabalho. O coordenador só planeja: ele lê o projeto, mas não edita nada nem dispara agentes.
3. No **Quadro**, revise o plano. **Editar plano** permite trocar agente, modelo, esforço, alvo, worktree e dependências. Depois, clique em **Aprovar e iniciar**.
4. Acompanhe as tarefas no quadro. Quando uma chegar a **Aguardando revisão**, use uma das ações:
   - **Confirmar critérios e concluir:** libera as tarefas que dependem desta;
   - **Pedir ajustes:** o mesmo agente continua a mesma sessão, com a sua orientação;
   - **Comentário em linha do diff:** a orientação aponta para uma linha adicionada;
   - **Marcar bloqueada.**
5. **Transferir para outro agente:** o novo agente recebe um pacote de continuidade com objetivo, critérios e eventos recentes.

**Pausar**, **Retomar** e **Cancelar** valem para a rodada inteira; **Cancelar tarefa** afeta só aquela tarefa.

## Onde as tarefas trabalham

- **`target: "gestor"`:** dados e telas do Gestor UFU, com as ferramentas do agente (comandos dos módulos, banco com desfazer, navegador e controle do computador). Não usa Git. O trabalhador roda no modo "Só o Gestor".
- **`target: "project"`:** a pasta do projeto configurada.
  - Se for um repositório Git, cada tarefa ganha uma **worktree isolada** (`orquestrador/<rodada>-<tarefa>-<tentativa>`) em `%LOCALAPPDATA%\GestorUFU\orquestrador\worktrees`, e o checkout original não é tocado.
  - `worktree: "current"` usa o checkout atual. É indicado só quando a tarefa precisa de arquivos que ainda não foram commitados.
  - `base` define a branch local de partida.
  - Arquivos ignorados pelo Git listados em `.worktreeinclude` (por exemplo `.env.local`) são copiados para a worktree, dentro de limites de quantidade e tamanho.
  - O quadro mostra os arquivos alterados e o diff, atualizados a cada 5 s durante a execução.

O botão 🔧 **Sincronizar e compilar** atualiza os upstreams configurados (somente fast-forward; para se houver alterações locais ou divergência) e depois roda o build configurado.

**Preparar projeto (.ai)** cria `.ai/README.md`, `.ai/specs/`, as skills genéricas e `orchestrator.json`, mas só quando `.ai` ainda não existe. Os arquivos `AGENTS.md`, `.github/copilot-instructions.md`, `.ai/specs`, `.ai/skills` e `.github/instructions` são lidos e entregues ao coordenador e aos trabalhadores.

## Estados

| Tarefa | Significado |
|---|---|
| Planejada | Plano ainda não aprovado. |
| Na fila | Esperando dependências concluídas e uma vaga livre. |
| Iniciando / Executando | O agente está trabalhando. O quadro mostra a última atividade. |
| Aguardando revisão | O agente terminou; falta a sua revisão. |
| Concluída | Critérios confirmados por você. |
| Falhou / Bloqueada | Erro do agente ou dependência que não terminou. Tente de novo, até o limite de tentativas, ou transfira. |
| Parada | O Gestor fechou durante a execução. Use **Tentar novamente**, que retoma a sessão salva quando o agente permite. |
| Cancelada | Cancelada por você. |

## Perfis (várias contas)

Em Configurações → **Perfis**, você pode cadastrar outras contas do Claude Code e do Codex. Cada perfil usa uma pasta própria em `%LOCALAPPDATA%\GestorUFU\orquestrador\perfis\<id>`:

- Claude Code: `CLAUDE_CONFIG_DIR`;
- Codex: `CODEX_HOME`, com `cli_auth_credentials_store = "file"`.

O botão **Entrar** abre o login oficial do CLI naquela conta. O coordenador recebe a lista de perfis e pode escolher um por tarefa (`profileId`). Cada perfil tem o próprio limite de tarefas simultâneas.

O Gestor nunca lê credenciais e nunca troca de conta para contornar limites. Um plano que use um perfil inexistente, ou de outro agente, é recusado na aprovação.

## AI Memory

O Gestor usa o runtime oficial do [AI Memory](https://github.com/akitaonrails/ai-memory) (MIT, Copyright (c) 2026 Fabio Akita) e não reimplementa a memória.

- **Instalação:** só acontece quando você clica em **Instalar** nas configurações. O Gestor baixa a release fixada (`v3.4.5`, Windows x64), confere tamanho e SHA-256, extrai com proteção contra caminhos maliciosos e roda `init` e `serve` em uma pasta privada (`%LOCALAPPDATA%\GestorUFU\ai-memory`), escutando só em `127.0.0.1`.
- **Autenticação:** o token de máquina criado pelo `init` fica nessa pasta e não é entregue aos agentes.
- **O que o Orquestrador grava e lê:**
  - uma **página por tarefa** (`orquestrador/tarefas/<rodada>/<tarefa>.md`, escopo `gestor-ufu/<projeto>`), criada com `create_only` e conferida por leitura de volta;
  - um **relatório por tentativa** (`…/agentes/<agente>-tentativa-<n>.md`), gravado a partir do relatório final do agente;
  - o contexto verificado, incluindo relatórios de tentativas anteriores, que entra no pedido do trabalhador;
  - uma consulta `memory_query` antes de cada plano, entregue ao coordenador.
- **Estado:** a memória só aparece como "verificada" quando a leitura de volta confirma o que foi gravado.

O AI Memory fica **neste computador**. Já o quadro, o diário e as transferências do Orquestrador ficam no banco compartilhado do Gestor e sincronizam entre computadores.

## Roteamento e economia de tokens

O coordenador recebe uma skill de roteamento (`lib/orchestrator/application/orq_routing_skill.dart`). Ela é fixa no prompt de sistema, e os CLIs reaproveitam esse trecho do cache. A skill ensina:

- **Faixa de modelo por tipo de tarefa:**
  - **econômico** (haiku, mini, flash, lite, luna) com esforço `low`, para tarefas mecânicas;
  - **padrão** (sonnet, codex padrão) com `medium`, para código do dia a dia;
  - **forte** (opus, pro, fable, terra, max) com `high`, só para trabalho difícil ou depois de uma falha.
  - O critério é o custo por tarefa concluída: retrabalho sai mais caro que um modelo melhor.
- **Agente por perfil de uso:**
  - Claude: código em vários arquivos e PDF;
  - Codex: a variante mini rende cerca de 4 vezes mais uso na assinatura;
  - Gemini: contexto grande e barato;
  - Copilot: créditos por modelo × tokens, então só modelos econômicos;
  - tarefas do Gestor: qualquer agente na faixa econômica.
- **Arquivos:**
  - planilhas pelo `read_spreadsheet`: resumo primeiro, depois só o intervalo;
  - importação no Gestor pelo comando do módulo, que lê o arquivo sozinho;
  - `.docx` pelo `read_document`;
  - `browser_snapshot` em vez de capturas de tela; controle do computador só como último recurso.
- **Plano:** tarefas pequenas e autocontidas; passos mecânicos agrupados; dependências em vez de reexplorar; "pedir ajustes" em vez de nova tentativa.

**Catálogo de modelos.** O coordenador recebe a lista real de modelos de cada conta, com a faixa de cada um. A lista vem do cache das abas ou da consulta do próprio CLI, que não gasta tokens, e é atualizada a cada hora.

**Medidas que reduzem tokens automaticamente:**

| Item | Antes | Agora |
|---|---|---|
| Trabalhador de projeto (guia + ferramentas) | ~6.200 tokens | ~700 tokens (só `read_spreadsheet`, `read_document` e modelos) |
| Ferramentas do coordenador | ~3.700 tokens | ~440 tokens |
| Orientações do projeto, branches, catálogo e perfis | a cada mensagem | uma vez por conversa; reenvio só quando mudam |
| Quadro enviado ao coordenador | até ~3.300 tokens | compacto: rodadas ativas + a última, resultados resumidos |
| Esforço do coordenador | padrão da conta | `medium` (configurável) |

## Dados

| Chave | Conteúdo |
|---|---|
| `orquestrador.config.v1` | Configurações. A pasta do projeto é guardada por computador. |
| `orquestrador.runs.v1` | IDs das rodadas, as mais recentes primeiro (até 40). |
| `orquestrador.run.<id>` | Rodada e tarefas (estado, resultado, sessão, worktree, arquivos alterados). |
| `orquestrador.events.<id>` | Eventos das tarefas (até 240 por tarefa). |
| `orquestrador.handoffs.v1` | Transferências (pendente, reivindicada uma vez, sessão iniciada, cancelada, expirada). |
| `orquestrador.chat.v1` | Conversa com o coordenador e estado da sessão dele. |

Resultados, erros, eventos e contextos passam por **redação de segredos** antes de serem gravados: chaves de API, tokens, senhas e blocos de chave privada são substituídos por `[REDACTED]`.

Uma tarefa executa num computador só, e o quadro mostra qual. Se o Gestor fechar no meio da execução, a tarefa fica **Parada**.

## Segurança

- **Coordenador:** sempre em modo Planejar, somente leitura.
- **Trabalhadores de projeto:**
  - usam a permissão escolhida nas configurações (padrão: Editar automaticamente, dentro da worktree);
  - pedidos de aprovação aparecem no topo da aba;
  - controle do computador e comandos destrutivos do Gestor pedem aprovação, salvo no modo Ignorar permissões.
- **Transferência:**
  - é aceita só quando você pede, ou quando a tarefa falhou ou ficou bloqueada;
  - o novo agente é reivindicado antes de o atual parar, e a reivindicação é desfeita se a parada falhar.
- **Conteúdo recebido:** memória e transferências entram como evidência histórica, nunca como instruções.

## Limitações conhecidas

- A reivindicação única de transferências é garantida dentro de um mesmo Gestor. Entre computadores diferentes, o banco sincroniza com atraso.
- Worktrees e o AI Memory são locais ao computador que executa a tarefa.
- O quadro mostra estado, última atividade, relatório e diff, mas não a transcrição completa ao vivo do agente.
- O Lich (adaptador de compatibilidade da extensão, AGPL) não foi portado: os quatro agentes do Gestor já têm adaptadores próprios.

## Código

- `lib/orchestrator/domain/`: modelo (`OrqRun`, `OrqTask`), validação do plano e redação de segredos.
- `lib/orchestrator/application/`:
  - `orq_controller.dart`: coordenador, agendador, trabalhadores, revisão e transferência;
  - `orq_journal.dart`: diário;
  - `git_worktrees.dart`: worktrees, diff e upstreams;
  - `ai_memory.dart`: runtime e ponte do AI Memory;
  - `orq_settings.dart`: configurações e perfis;
  - `project_setup.dart`: "Preparar projeto (.ai)".
- `lib/presentation/pages/orchestrator/orchestrator_view.dart`: a aba (Conversa, Quadro e Configurações).
- A janela do agente ([ai_agent_window.dart](../lib/presentation/pages/ai_agent_window.dart)) fornece a fábrica de agentes (`_orqBackend`): o mesmo código das abas, com servidor MCP próprio para cada agente do Orquestrador.
- Testes: `test/orchestrator/`.
