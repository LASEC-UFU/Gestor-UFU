# Progressão / Promoção — montar o processo completo no SEI pela aba Resumo

> Especificação + prompt de implementação. Levantada em 16/11/2026 a partir do
> processo de referência **23117.081252/2024-03** (progressão D II → D III de
> Josué Silva de Morais, aberto pela CADFEELT) e do código atual do módulo
> `lib/modules/progressao`.

## 1. Objetivo

Na aba **Resumo** do processo de progressão, um único botão
**"Montar processo no SEI"** deve:

1. **Criar um processo novo** no SEI *ou* usar o processo já aberto/informado
   (o usuário escolhe);
2. incluir e **preencher automaticamente** o documento interno
   **"Requerimento de Progressão / Promoção Docente"**
   (título impresso: *REQUERIMENTO PARA DESENVOLVIMENTO NA CARREIRA DOCENTE*);
3. incluir **todos os comprovantes** dos lançamentos (documentos externos);
4. incluir o **comprovante da última titulação** (diploma);
5. incluir, **por último**, o **Relatório de Atividades** em PDF.

Em todos os passos, **o que já estiver no processo não é inserido de novo**
(vale para o requerimento, os comprovantes, a titulação e o relatório; os
documentos cancelados não contam).

Nada é **assinado** automaticamente: o usuário confere e assina o requerimento
no SEI (assinatura é ato pessoal).

## 2. O processo de referência (como está no SEI hoje)

### 2.1 Propriedades do processo (Consultar/Alterar Processo)

| Campo | Valor no 23117.081252/2024-03 | Regra para o novo |
|---|---|---|
| Tipo do Processo | **Pessoal: Progressão Docente** | Progressão → **Pessoal: Progressão Docente** (`id_tipo_procedimento` 100001296); Promoção → **Pessoal: Promoção Docente** (100001297). Ambos conferidos no SEI/UFU em 16/11/2026. A lista inicial do "Iniciar Processo" só mostra os tipos já usados; para ver todos: `exibirTiposProcedimento('T')` (ícone "Exibir todos os tipos"), depois `escolher(<id>)`. Escolher pelo **texto** (os ids podem mudar); configurável (`tipoProcessoSei`). |
| Especificação | `JOSUÉ SILVA DE MORAIS FEELT D2 - D3 21/01` | Padrão: `<DOCENTE EM MAIÚSCULAS> <SIGLA DA UNIDADE> <classe><nível origem> - <classe><nível alvo> <dd/mm do início do interstício>`. Para o processo atual: `JOSUÉ SILVA DE MORAIS FEELT D3 - D4 21/01`. Editável antes do envio (máx. 100 caracteres no SEI). |
| Prioridade | (vazio) | Não preencher. |
| Classificação por Assuntos | `023.12 - REESTRUTURAÇÕES E ALTERAÇÕES SALARIAIS (Inclusive Ascensão e Progressão Funcional; Avaliação de Desempenho; ...)` | Vem automaticamente do tipo do processo. Não mexer, só conferir. |
| Interessados | `Josué Silva de Morais (josue)` | O próprio docente (usuário logado). Buscar pelo nome no autocompletar e escolher a sugestão que contém o login. |
| Observações desta unidade | (vazio) | Não preencher. |
| Nível de Acesso | **Restrito**, hipótese legal **Informação Pessoal (Art. 31 da Lei nº 12.527/2011)** | Igual. |
| Data de autuação | 27/11/2024 | Automática. |

O processo foi aberto na unidade do docente (CADFEELT). A automação **não
troca de unidade**: usa a que está selecionada no SEI e mostra o nome dela
no log para o usuário conferir (canto superior direito, ex.: `COCCA`/`CADFEELT`).

### 2.2 Árvore de documentos (lida integralmente com "Abrir todas as pastas", `a[id^="anchorAP"]`)

O SEI divide a árvore em pastas/volumes (I…V) carregadas sob demanda; a
leitura só é confiável depois de abrir todas (os nós ficam "Aguarde..." até
carregar). Ordem real do processo de referência:

- **Pasta I**
  1. `Requerimento de Progressão / Promoção Docente 5908759` (interno; o rótulo do nó é o **tipo + nº SEI**, sem a descrição)
  2. `Portaria - MembroColegiadoCA_2021.pdf`, `Portaria - MembroNDE_2022_3.pdf`, `Portaria - CoordenadorEstagio.pdf`, `Portaria - CoordenadorSubstituto.pdf`, `Portaria - COMPFEELT.pdf`, `Portaria - SEI_5348489_Portaria_de_Pessoal_2215.pdf`
  3. `Comprovante - 2023-1_FEELT32602_Avaliacao1.pdf`, `Comprovante - 2023-2_FEELT32002_Avaliacao2.pdf`, `Comprovante - Avaliação de Desempenho Docente_2022_1.pdf` … `_2024_1.pdf` (avaliações didáticas)
  4. `Diário - 2024-1_ININDII_A_9_72.pdf` … (padrão `<semestre>_<disciplina>_<turma>_<nº alunos>_<CH>.pdf`)
- **Pasta II**: demais `Diário - ...` (2023-2 a 2022-1)
- **Pasta III**: últimos diários, `Relatório - proexc_tvBox.pdf`, `Relatório - projetos_extensão_2023.pdf`, `Comprovante - matheus_010623_301123.pdf` (bolsistas), `Comprovante - projeto_CNPq ...`, `Declaração _4586517.html` … (bancas)
- **Pasta IV**: mais `Declaração _....html`; `Relatório de Atividades - Josué Silva de Morais (5915155)` **cancelado**; `Declaração 5917033…5925224` e `E-mail 5927101` (da tramitação); dois relatórios **cancelados** (5947946, 5948019); **`Comprovante - Diploma de Doutorado (5960031)`**; `Parecer 37` (CADFEELT)
- **Pasta V**: `Comprovante - Premiação RBF`, **`Relatório de Atividades - Josué Silva de Morais (5961509)`** (versão válida) e a tramitação: Decisão Administrativa 138, Ofício 309, Despacho 2624, Histórico, E-mails, Parecer 27, Ofício 42, Minuta/Portaria de Pessoal 759, Despacho 47, Termo, Portaria 2478/2025.

Lições para a automação:
- Documentos cancelados continuam na árvore (o `insertExternalBatch` já os ignora pela palavra "cancelado"; conferir também pelo estilo/ícone do nó).
- O relatório foi refeito 3 vezes (cancelar → incluir de novo). A automação deve permitir **substituir** o relatório: só incluir um novo depois que o antigo estiver cancelado pelo usuário.
- Os documentos externos aparecem como `<Tipo> - <Nome na Árvore> (<nº SEI>)`: a deduplicação deve comparar o nome na árvore **sem** o nº entre parênteses.

Observação: no processo de 2024 o tipo do documento externo variava conforme o
comprovante (Portaria, Comprovante, Diário, Declaração). Hoje o Gestor manda
tudo como **Comprovante** (`tipoDocumentoSei`). Ver item 5.4.

### 2.3 Metadados dos documentos externos (Consultar Registro de Documento Externo)

| Documento | Tipo | Data | Nome na Árvore | Formato | Acesso |
|---|---|---|---|---|---|
| Comprovante de atividade | Comprovante | data da inclusão | `- 2023-1_FEELT32602_Avaliacao1.pdf` (o SEI mostra "Comprovante - <nome na árvore>") | Nato-digital | **Restrito** – Informação Pessoal (Art. 31 da Lei 12.527/2011) |
| Diploma | Comprovante | data da inclusão | `- Diploma de Doutorado` | Nato-digital | Público |
| Relatório | **Relatório** | data da inclusão | `de Atividades - Josué Silva de Morais` (aparece "Relatório de Atividades - ...") | Nato-digital | Público |

Remetente, Interessados, Classificação e Observações ficam vazios nos externos.

### 2.4 Requerimento (documento interno) — propriedades

- Tipo: **Requerimento de Progressão / Promoção Docente**
- Descrição: `Progressão da classe D nível II para nível III - Josué Silva de Morais`
  → padrão: `<Progressão|Promoção> da classe <C> nível <origem> para <nível/classe alvo> - <Docente>`
  (para o caso atual: `Progressão da classe D nível III para nível IV - Josué Silva de Morais`)
- Nome na Árvore: vazio
- Interessados: o docente
- Classificação: 023.12 (automática)
- Nível de acesso: **Público**
- Texto inicial: **Documento Modelo / Texto padrão do tipo** (o próprio formulário).

### 2.5 Conteúdo do requerimento (campos do formulário)

Cabeçalho: *REQUERIMENTO PARA DESENVOLVIMENTO NA CARREIRA DOCENTE* / "Sr.(a) Diretor(a)" /
"Venho requerer, à Direção da Unidade Acadêmica, desenvolvimento na Carreira de
Magistério Federal, nos termos da Resolução CONDIR nº 03/2017, Lei nº 12772/2012 e
Portaria MEC 554/2013, de acordo com o informado abaixo."

Tabela 1 (identificação):

| Rótulo no SEI | Valor 2024 | Fonte no Gestor |
|---|---|---|
| Nome | Josue Silva de Morais | `docente` |
| Lotação | Faculdade de Engenharia Elétrica | `lotacao` |
| SIAPE | 1839411 | `siape` |
| Admissão | 26/01/2011 | **campo novo** `dataAdmissao` |
| Última progressão/promoção | Classe D nível II | derivar da posição **de origem** (`alvo` − 1 nível), ex.: "Classe D nível III" |
| Titulação | Doutor | `titulacao` (rótulo masculino/feminino: Doutor(a), Mestre, Especialista, Graduado) |
| Regime de trabalho | DE | `regime` (DE / 40h / 20h) |

Tabela 2 (períodos):

| Linha | Valor 2024 | Fonte |
|---|---|---|
| Período do relatório | 26/01/2023 a 30/11/2024 | `relatorioInicio` / `relatorioFim` |
| Interstício | 26/01/2023 a 25/01/2025 | `intersticioInicio` / `intersticioFim` |
| Justificativa em caso de alteração do interstício | (vazio) | **campo novo** `justificativaIntersticio` (obrigatório quando `relatorioInicio < intersticioInicio`, aviso que já existe na Conferência) |

Marcação "(Marcar com um X a opção desejada)":

- **PROGRESSÃO** (mudança de nível – Lei 12.772/2012, art. 12, § 2º): X na
  caixa de Progressão; X na linha da **classe** (A, B, C, D do Magistério
  Superior, ou D I…D IV do EBTT); X na caixa **"Do Nível"** do nível de origem
  (a coluna "Para Nível" é texto fixo).
  *Confirmado no HTML (2024, D II → D III): X na caixa de classe da linha
  "D (Associado)" e X na caixa "Do Nível" da linha cujo "do" é 2 (a linha de
  "C (Adjunto)"). As caixas de nível são independentes das de classe: localizar
  pela linha "Do Nível = n". Para D III → D IV: classe na linha D, nível na
  linha com "3 → 4" (também a linha D).*
- **PROMOÇÃO** (mudança de classe – art. 12, § 3º): X na caixa de Promoção e na
  linha da posição atual → promoção para (A→B, B→C, C→D, D→E Titular; EBTT
  D I→D II, ..., D IV→Titular).

Tabela "Resumo da pontuação":

| TABELA | Descrição | Pontuação |
|---|---|---|
| A 1.1 | Atividades de ensino (itens 1 a 12) | soma da tabela |
| A 1.2 | Atividades de orientação (itens 13 a 28) | |
| A 1.3 | Produção intelectual (itens 29 a 88) | |
| A 1.4 | ... sem remuneração suplementar (itens 89 a 102) | |
| A 1.5 | ... com remuneração suplementar (itens 103 a 113) | |
| A 1.6 | Atividades de gestão (itens 114 a 162) | |
| A 1.7 | Licenças, situações especiais e afastamentos (itens 163 a 167) | |
| Total | | soma |

Usar **os mesmos totais do Resumo/PDF do Gestor** (já respeitam limites por
item). Formato numérico: inteiro quando não há fração; senão vírgula decimal
com até 2 casas (ex.: `2087,02`).

Fecho: "Nestes termos, pede deferimento." / `Uberlândia dia 30 de Novembro de 2024`
→ `<cidade> dia <d> de <Mês> de <aaaa>` com `dataDocumento` (mês com inicial
maiúscula, como no modelo). Links "Progressão" e "Promoção" e o bloco de
assinatura são do próprio SEI: **não mexer**.

### 2.6 HTML real do requerimento (lido de `documento_visualizar` do doc 5908759)

Conteúdo do editor (classes do SEI; células de rótulo têm
`<p ... readonly="readonly">` e fundo `#ccc`; células de valor são `<p
class="Tabela_Texto_Alinhado_Esquerda">valor</p>` sem `readonly`). Ordem dos
blocos e o que preencher:

| # | Bloco | Estrutura | Preencher |
|---|---|---|---|
| 1 | Título + "Sr.(a) Diretor(a)" + parágrafo de abertura | `p.Texto_Centralizado`, `p.Texto_Alinhado_Esquerda[readonly]` | nada |
| 2 | TABELA 1 (identificação) | linha 1: `Nome:` · valor (colspan 3) · `Lotação:` · valor (colspan 2); linha 2: `SIAPE:` · valor · `Admissão:` · valor · `Última progressão/promoção:` (colspan 2) · valor; linha 3: `Titulação:` · valor (colspan 3) · `Regime de trabalho:` (colspan 2) · valor | célula **seguinte** a cada rótulo |
| 3 | TABELA 2 (períodos) | `Período do relatório:` · início · `a` · fim · texto fixo; `Interstício:` · início · `a` · fim · texto fixo (fundo `#def`) | 2ª e 4ª células de cada linha (dd/mm/aaaa) |
| 4 | TABELA 3 (justificativa, `border=0`) | linha 1 rótulo `Justificativa em caso de alteração do interstício:`; linha 2 `<td style="background-color:#def; border:1px solid #000">&nbsp;</td>` (sem `<p>`) | linha 2: `<p class="Tabela_Texto_Alinhado_Esquerda">texto</p>` ou manter `&nbsp;` |
| 5 | "(Marcar com um X a opção desejada)" | parágrafo | nada |
| 6 | TABELA 4 (caixa PROGRESSÃO) | `td[border:1px solid; width:3%] > p.Tabela_Texto_Centralizado` + rótulo **PROGRESSÃO** | `X` se progressão; senão `&nbsp;` |
| 7 | TABELA 5 (grade da progressão) | 13 colunas: MS = [caixa classe] [classe] [sep] [caixa Do Nível] [do] [para] · [sep cinza] · EBTT = [caixa classe] [classe] [sep] [caixa Do Nível] [do] [para]. Linhas: `A (Auxiliar, Assistente-A ou Adjunto-A)` (sem níveis) / `B (Assistente)` 1→2 / `C (Adjunto)` 2→3 / `D (Associado)` 3→4; EBTT `D I` / `D II` 1→2 / `D III` 2→3 / `D IV` 3→4 | MS: X na **col 0** da linha da classe e X na **col 3** da linha cujo "do" (col 4) = nível de origem. EBTT: col 7 e col 10 do mesmo jeito. ⚠ No modelo, a caixa "Do Nível" (col 3/10) tem `readonly` — o X só entra via `setData` (o editor não deixa digitar). |
| 8 | TABELA 6 (caixa PROMOÇÃO) | igual à 4, rótulo **PROMOÇÃO** | `X` se promoção |
| 9 | TABELA 7 (grade da promoção) | MS: [caixa] [classe atual] [nível] [classe destino] [nível] · sep · EBTT idem. Linhas `A (Auxiliar) 2 → B (Assistente) 1`, `B 2 → C (Adjunto) 1`, `C (Adjunto) 4 → D (Associado) 1`, `D (Associado) 4 → E (Titular) 1`; EBTT `D I 2 → D II 1`, `D II 2 → D III 1`, `D III 4 → D IV 1`, `D IV 4 → Titular 1` | X na caixa (col 0 ou col 6) da linha da classe atual |
| 10 | "Resumo da pontuação" + TABELA 8 | cabeçalho `TABELA / Descrição das atividades / Pontuação`; linhas `A 1.1`…`A 1.7` (col 0 readonly, col 1 descrição editável, col 2 pontuação **readonly**); última `Total` (colspan 2) · total (**readonly**) | col 2 de cada linha e o total (também via `setData`) |
| 11 | Fecho | `Nestes termos, pede deferimento.` / `Uberlândia dia 30 de Novembro de 2024` | substituir o parágrafo que começa com `<cidade> dia` |
| 12 | Orientações / links Progressão e Promoção | parágrafos | nada |

Valores de 2024 gravados no documento: Nome `Josue Silva de Morais`, Lotação
`Faculdade de Engenharia Elétrica`, SIAPE `1839411`, Admissão `26/01/2011`,
Última progressão `Classe D nível II`, Titulação `Doutor`, Regime `DE`,
Relatório `26/01/2023 a 30/11/2024`, Interstício `26/01/2023 a 25/01/2025`,
pontuação 1471 / 50 / 44 / 111 / 0 / 298 / 0, total `1974`.

Implementação recomendada para preencher (no editor, via `infraEditor.editor`):
`getData()` da root principal → `DOMParser` → localizar as tabelas **pelo texto
dos rótulos** (não por índice) → alterar só o texto dos `<p>` das células de
valor/caixas (preservar classes e estilos) → `setData()` → plugin `Salvar`.
Normalizar acentos e espaços (`&nbsp;`) ao comparar rótulos. Se algum rótulo
não for encontrado, abortar sem salvar e listar os faltantes.

## 3. O que o Gestor já faz (código atual, commit 548c8ff)

- `SeiAutomationService` (`lib/platform/services/sei_automation_service.dart`):
  Edge próprio via Puppeteer (perfil `EdgePlanoTrabalhoProfile`),
  `insertExternalDocument` (Incluir Documento → Externo → tipo, data de hoje,
  nº, nome na árvore, nato-digital, **acesso Público fixo**, anexa e salva,
  confirma o nó na árvore) e `insertExternalBatch` (varredura prévia da árvore
  abrindo todas as pastas/volumes, pula nós cujo texto contém o Nome na Árvore e
  que não estão cancelados, envia em sequência, para no 1º erro, varredura final).
- `ProgressaoService.enviarDossieSei(id)`: no **processo já aberto**, envia
  comprovantes (`rotuloComprovante`, tipo `tipoDocumentoSei`), depois a titulação
  (`Comprovante da última titulação - <Doutorado>`, tipo Comprovante) e por
  último o relatório (`gerarRelatorio` → `Relatorio_Atividades_<Docente>.pdf`,
  tipo **Relatório**, nome `de Atividades - <Docente>`).
- Aba Resumo: abre o Edge; a Conferência exige `comprovanteTitulacao`
  (pasta `Titulacao/Comprovante_<titulacao>.<ext>`).
- Elabora Relato (`sei_parecer_automation.dart`) e Planos de Ensino já **geram
  documento interno** e escrevem no editor CKEditor 5 do SEI
  (`window.infraEditor.editor`, várias *roots*, `getData/setData`, plugin
  `Salvar`): **reaproveitar esse padrão** para o requerimento.

**Lacunas:** (a) criar o processo; (b) requerimento interno preenchido;
(c) nível de acesso configurável (hoje sempre Público); (d) reconhecer
titulação/relatório já existentes com nomes diferentes (ex.:
"Comprovante - Diploma de Doutorado"); (e) guardar o número do processo SEI no
processo do Gestor; (f) campos novos `dataAdmissao`, `justificativaIntersticio`.

## 4. Fluxo desejado (botão "Montar processo no SEI")

Pré-checagem local (sem abrir o SEI) — bloquear com lista de pendências:
docente, SIAPE, lotação, admissão, datas do relatório/interstício, alvo,
`atingeReferencia` (só aviso), todos os comprovantes existentes na pasta,
titulação arquivada, justificativa quando o relatório começa antes do
interstício. Gerar o PDF do relatório antes de começar (falhou → não envia nada).

Diálogo de opções (mostrar antes de começar e gravar no processo):

- `( ) Criar processo novo` / `( ) Usar processo existente nº [__________]`
  (pré-preenchido com `processoSei` salvo; vazio = o que estiver aberto no Edge)
- Tipo do processo, Especificação (pré-preenchida, editável), Interessado
- Nível de acesso dos comprovantes: Restrito – Informação Pessoal (padrão) / Público
- Checkboxes: incluir requerimento / comprovantes / titulação / relatório (todas marcadas)

### Passo 0 — SEI pronto
Abrir/focar o Edge do módulo (`abrirSei`), esperar o usuário logado (detectar
o menu "Iniciar Processo"; se aparecer a tela de login, pedir login e aguardar,
sem nunca digitar senha). Registrar no log a **unidade atual**.

### Passo 1 — Processo
- **Existente:** pesquisar o número na "Pesquisa rápida" (campo
  `#txtPesquisaRapida`) e esperar `acao=procedimento_trabalhar`. Conferir que o
  número na raiz da árvore é o informado.
- **Novo:** menu **Iniciar Processo** → filtrar/escolher **Pessoal: Progressão
  Docente** (pode exigir clicar em "Exibir todos os tipos") → preencher
  Especificação, Interessado (autocompletar + seleção), Nível de acesso
  **Restrito** + Hipótese legal **Informação Pessoal (Art. 31 da Lei nº
  12.527/2011)** → Salvar. Ler o número gerado na raiz da árvore e **gravar em
  `processoSei`** imediatamente (se algo falhar depois, a próxima execução usa
  esse processo em vez de criar outro).
  Proteção contra duplicidade: se `processoSei` já estiver preenchido e o usuário
  escolher "novo", pedir confirmação explícita.

### Passo 2 — Requerimento (interno)
1. Varredura da árvore: se existir nó **não cancelado** cujo texto comece por
   "Requerimento de Progressão / Promoção Docente" → **não criar**; registrar
   "já existente" e (opcional, com confirmação) oferecer **atualizar o conteúdo**
   se ele ainda não estiver assinado (sem ícone de assinatura / caneta).
2. Senão: Incluir Documento → tipo **Requerimento de Progressão / Promoção
   Docente** → Texto inicial "Nenhum"/padrão (o modelo do tipo já traz o
   formulário) → Descrição (item 2.4) → Interessado → Nível de acesso **Público**
   → Salvar → esperar o editor.
3. No editor: ler o HTML da root principal, preencher **pelas células vizinhas
   dos rótulos** (procurar `td` cujo texto normalizado é "Nome:", "Lotação:",
   "SIAPE:", "Admissão:", "Última progressão/promoção:", "Titulação:",
   "Regime de trabalho:", "Período do relatório:", "Interstício:" e escrever na
   célula seguinte / nas células "a"), marcar os X localizando as linhas pelo
   texto ("PROGRESSÃO", "D (Associado)", Do Nível = n ...), preencher o resumo
   por "A 1.1"…"A 1.7"/"Total" e a linha "Uberlândia dia ...". Nunca reescrever o
   documento inteiro: alterar só as células; se algum rótulo não for encontrado,
   **não salvar**, mostrar quais faltaram e deixar o editor aberto.
4. Salvar (plugin Salvar) e conferir que salvou; **não assinar**. Log: "Requerimento
   preenchido. Confira e assine no SEI."

> Na implementação, antes de codificar os seletores, capturar o HTML real do
> modelo (abrir um requerimento novo num processo de teste e salvar
> `editor.getData()` em arquivo) e escrever testes com esse HTML fixo.

### Passo 3 — Comprovantes (externos)
`insertExternalBatch` com `lancamentosComComprovante(p)` na ordem do relatório
(tabela → item → linha), tipo `tipoDocumentoSei` (padrão Comprovante), nome na
árvore `rotuloComprovante` (≤ 50 caracteres), **acesso conforme a opção**
(padrão Restrito + Informação Pessoal). Pula os que já estão na árvore.

### Passo 4 — Última titulação
Externo tipo **Comprovante**, nome na árvore **`Diploma de <Doutorado|Mestrado|...>`**
(igual ao processo de referência). Considerar "já existente" se houver nó não
cancelado contendo "Diploma de <titulação>" **ou** "última titulação". Acesso
Público (como no modelo) ou o mesmo dos comprovantes, conforme a opção.

### Passo 5 — Relatório de Atividades (por último)
Gerar o PDF (`ProgressaoPdfService.gerarRelatorio`), externo tipo
**Relatório**, nome na árvore `de Atividades - <Docente>`, acesso Público.
Já existente (não cancelado) → **não** reenviar; avisar: "Para substituir,
cancele o relatório antigo no SEI e rode de novo" (como foi feito em 2024, com
as versões canceladas).

### Passo 6 — Conferência final
Reabrir todas as pastas, conferir que requerimento, todos os comprovantes,
titulação e relatório estão na árvore; resumo no log:
`Processo 23117.xxxxxx/2026-xx: requerimento (novo|existente), N comprovantes
incluídos, M já existentes, titulação, relatório. Pendente: assinar o
requerimento.` Gravar `processoSei` e `enviadoSeiEm` no processo do Gestor.

Cancelamento: botão "Parar" (já existe `envio.cancelar`) entre documentos.
Erro em qualquer documento → parar o lote (comportamento atual) e mostrar o que
já foi feito; uma nova execução continua de onde parou graças à deduplicação.

## 5. Mudanças de código sugeridas

1. **Domínio** (`progressao.dart`): `dataAdmissao (DateTime?)`,
   `justificativaIntersticio (String)`, `processoSei (String)`,
   `especificacaoSei (String)`, `tipoProcessoSei (String, padrão 'Pessoal: Progressão Docente')`,
   `acessoComprovantesSei (enum restrito|publico, padrão restrito)`,
   `enviadoSeiEm (DateTime?)`, com `copyWith`/`toJson`/`fromJson` tolerantes.
   Campos na aba de dados do processo (Admissão, Justificativa) e na aba Resumo
   (opções do SEI).
2. **Plataforma** (`sei_automation_service.dart`):
   - `Future<String> iniciarProcesso({tipo, especificacao, interessado, restrito, hipoteseLegal})` → retorna o número;
   - `Future<void> abrirProcesso(String numero)` (pesquisa rápida);
   - `Future<String> unidadeAtual()`;
   - parâmetro `nivelAcesso` (+ `hipoteseLegal`) em `insertExternalDocument`/`insertExternalBatch`
     (hoje `_fillMetadataScript` força Público);
   - `nomesAlternativos` em `SeiDocumentoExterno` para a deduplicação;
   - `Future<bool> existeDocumento(String prefixo)` reutilizando `_documentNodes`.
3. **Módulo**: `progressao_requerimento_sei.dart` (gera o documento interno e
   preenche o formulário, padrão do `sei_parecer_automation.dart`) e
   `ProgressaoService.montarProcessoSei(id, opcoes)` orquestrando os passos
   1–6 (reaproveitando `enviarDossieSei`). Comando `progressao.montarProcessoSei`
   (`requires_approval: true`) para o agente.
4. **UI (Resumo)**: botão "Montar processo no SEI" + diálogo de opções + log
   (o painel de envio atual), mostrando o número do processo com link "Abrir no SEI".
5. **Testes**: geradores puros (especificação, descrição, texto da data,
   "última progressão", formatação dos pontos, mapeamento do X) e o
   preenchimento do HTML do modelo capturado (fixture). Rodar `flutter analyze` e
   `flutter test`.

## 6. Critérios de aceitação

- Processo novo criado com tipo, especificação, interessado e acesso iguais ao
  item 2.1, e número gravado no Gestor.
- Requerimento criado como 1º documento, todos os campos da seção 2.5
  preenchidos com os dados do Gestor, salvo e **não assinado**.
- Rodar duas vezes seguidas não duplica nada (2ª execução: tudo "já existente").
- Em processo existente com "Comprovante - Diploma de Doutorado", a titulação não
  é reenviada.
- Relatório sempre o último documento incluído pela automação.
- Comprovantes com o nível de acesso escolhido (padrão Restrito – Informação Pessoal).
- Nenhuma senha digitada; nada assinado ou tramitado automaticamente.

## 7. Dados para o processo atual (Associado III → IV)

- Especificação: `JOSUÉ SILVA DE MORAIS FEELT D3 - D4 21/01`
- Descrição do requerimento: `Progressão da classe D nível III para nível IV - Josué Silva de Morais`
- Última progressão/promoção: Classe D nível III · Titulação: Doutor · Regime: DE
- Admissão: 26/01/2011 (do requerimento de 2024)
- Período do relatório: 21/01/2025 a 26/11/2026 · Interstício: 21/01/2025 a 20/01/2027
- Pontuação (Gestor, 16/11/2026): total **2087,02** (referência 960). Os totais por tabela
  saem do Resumo no momento do envio.
- Data: `Uberlândia dia 26 de Novembro de 2026`
