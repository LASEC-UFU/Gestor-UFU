# Gestor UFU

**Configurador de disciplinas Moodle com recálculo automático de datas.**

Gestor UFU é uma aplicação Flutter multiplataforma (Windows, Android, Web, macOS, Linux, iOS) que permite planejar a estrutura completa de uma disciplina — seções, atividades, datas, visibilidade e ordenação — e sincronizar tudo diretamente com o Moodle, eliminando o trabalho manual repetitivo de configurar cursos a cada semestre.

---

## Índice

1. [Visão Geral](#visão-geral)
2. [Funcionalidades Principais](#funcionalidades-principais)
3. [Requisitos](#requisitos)
4. [Instalação](#instalação)
5. [Primeiro Uso — Passo a Passo](#primeiro-uso--passo-a-passo)
6. [Tela Inicial (Home)](#tela-inicial-home)
7. [Editor de Tabela](#editor-de-tabela)
8. [Sistema de Macros de Data](#sistema-de-macros-de-data)
9. [Vinculação com o Moodle](#vinculação-com-o-moodle)
10. [Avaliação de Correspondência (Evaluate)](#avaliação-de-correspondência-evaluate)
11. [Sincronização com o Moodle](#sincronização-com-o-moodle)
12. [Importação e Exportação de Planilhas](#importação-e-exportação-de-planilhas)
13. [Importação Direta do Moodle](#importação-direta-do-moodle)
14. [Visibilidade de Atividades](#visibilidade-de-atividades)
15. [Reordenação de Atividades](#reordenação-de-atividades)
16. [Tipos de Atividade Suportados](#tipos-de-atividade-suportados)
17. [Referência de API Moodle](#referência-de-api-moodle)
18. [Estrutura do Projeto](#estrutura-do-projeto)
19. [Build & Release (CI/CD)](#build--release-cicd)
20. [Desenvolvimento](#desenvolvimento)
21. [Solução de Problemas](#solução-de-problemas)
22. [Licença](#licença)

---

## Visão Geral

Como professor ou coordenador, você provavelmente já enfrentou o trabalho tedioso de configurar dezenas de atividades no Moodle a cada início de semestre: ajustar datas de abertura e fechamento, renomear seções, ordenar módulos, definir visibilidades. O **Gestor UFU** resolve isso:

1. **Você define a estrutura da disciplina uma única vez** — seja criando do zero, importando de uma planilha Excel ou buscando de um curso Moodle existente.
2. **Altera a data de início do semestre** — e todas as datas são recalculadas automaticamente usando offsets relativos e macros inteligentes.
3. **Sincroniza com o Moodle** — nomes, visibilidade e ordenação das atividades são atualizados em lote via API, em poucos segundos.

O resultado: o que antes levava horas de cliques manuais agora leva segundos.

---

## Funcionalidades Principais

| Funcionalidade | Descrição |
|----------------|-----------|
| **Criação de configurações** | Crie estruturas de disciplina com seções, atividades, datas e tipos |
| **Macros de data** | Nomes de atividades com datas dinâmicas (`<DD/MM/YYYY>`, `<DD/MM/YYYY + 7>`) que se atualizam ao mudar o semestre |
| **Importação de Excel (.xlsx)** | Importe estruturas prontas de planilhas com detecção de duplicatas |
| **Exportação para Excel** | Exporte qualquer configuração para .xlsx para backup ou compartilhamento |
| **Importação do Moodle** | Busque a estrutura de um curso existente diretamente do Moodle |
| **Download de template** | Baixe uma planilha de exemplo para entender o formato esperado |
| **Login no Moodle** | Autenticação via token com persistência de credenciais |
| **Vinculação curso ↔ config** | Associe sua configuração local a um curso real do Moodle |
| **Avaliação automática** | Algoritmo de correspondência (Jaro-Winkler + posição + vínculo) sugere links entre itens locais e do Moodle |
| **Sincronização** | Atualize nomes de seções, nomes de atividades, visibilidade e ordenação no Moodle |
| **Visibilidade 3 estados** | Oculto, Visível ou Stealth (disponível mas não listado) |
| **Reordenação drag-and-drop** | Reorganize atividades dentro e entre seções com drag-and-drop |
| **Seleção múltipla** | Selecione várias atividades (Shift+Click / Ctrl+Click) e mova em lote |
| **Design responsivo** | Interface adapta-se de celular (1 coluna) a desktop (4 colunas) |
| **Tema dark moderno** | Interface glassmorphic com gradientes e tipografia Google Fonts (Poppins) |

---

## Requisitos

### Para usar o aplicativo

| Plataforma | Requisito |
|-----------|-----------|
| **Windows** | Windows 10 ou superior (x64) |
| **Android** | Android 5.0 (API 21) ou superior |
| **Web** | Navegador moderno (Chrome, Edge, Firefox) |

### Para desenvolvimento

- **Flutter SDK** ≥ 3.11.3
- **Dart SDK** ≥ 3.11.3
- **Moodle** com web services habilitados (REST protocol + Mobile services)
- Conta Moodle com permissão de **edição** no curso alvo

### Configuração do Moodle (Administrador)

Para que a sincronização funcione, o administrador do Moodle precisa garantir:

1. **Habilitar Web Services:** `Administração > Plugins > Web services > Gerenciar protocolos` → ativar **REST protocol**
2. **Habilitar Mobile Services:** `Administração > Plugins > Mobile app > Mobile services` (necessário para obtenção de token)
3. **Verificar capacidades do usuário:** O usuário precisa ter a role de **Editing Teacher** ou **Manager** no curso

> **Nota:** O Gestor UFU tenta autenticar primeiro via serviço customizado (`config_moodle_service`) e depois via `moodle_mobile_app`. Se nenhum funcionar, verifique se o web service está habilitado para o protocolo REST.

---

## Instalação

### Windows (MSI)

1. Acesse a página de [Releases](https://github.com/josuemoraisgh/config_moodle/releases)
2. Baixe o arquivo `GestorUFU-X.Y.Z-windows.msi`
3. Execute o instalador e siga as instruções
4. O aplicativo ficará disponível no Menu Iniciar e na Área de Trabalho

### Android (APK)

1. Acesse a página de [Releases](https://github.com/josuemoraisgh/config_moodle/releases)
2. Baixe o arquivo `GestorUFU-X.Y.Z-android.apk`
3. No dispositivo, habilite "Instalar de fontes desconhecidas"
4. Instale o APK

### A partir do código-fonte

```bash
git clone https://github.com/josuemoraisgh/config_moodle.git
cd config_moodle
flutter pub get
flutter run          # Executa no dispositivo/emulador conectado
flutter run -d windows  # Executa especificamente no Windows
flutter run -d chrome   # Executa no navegador
```

---

## Primeiro Uso — Passo a Passo

Aqui está um guia completo para configurar sua primeira disciplina:

### Passo 1: Faça login no Moodle

1. Abra o Gestor UFU
2. Clique no ícone de conexão no canto superior direito da tela inicial
3. Preencha:
   - **URL do Moodle**: ex. `https://moodle.suainstituicao.edu.br`
   - **Usuário**: seu login do Moodle
   - **Senha**: sua senha do Moodle
4. Clique em "Entrar"
5. Se bem-sucedido, aparerecerá seu nome e um ícone verde de conectado

### Passo 2: Crie ou importe uma configuração

**Opção A — Criar do zero:**
1. Clique no botão `+` (FAB) no canto inferior direito
2. Selecione "Novo vazio"
3. Digite o nome da disciplina
4. A configuração será criada com a data de hoje como início do semestre

**Opção B — Importar planilha:**
1. Clique no `+` → "Importar Planilha"
2. Selecione um arquivo `.xlsx` no formato esperado (veja [Importação de Planilhas](#importação-e-exportação-de-planilhas))
3. Se já existir uma configuração com o mesmo nome, você pode substituí-la ou criar uma cópia

**Opção C — Importar do Moodle:**
1. Clique no `+` → "Importar do Moodle"
2. Selecione o curso na lista
3. Escolha a data de início do semestre
4. Todas as seções e atividades serão importadas com IDs Moodle já vinculados

### Passo 3: Edite a estrutura no Editor de Tabela

1. Clique na configuração recém-criada para abrir o Editor
2. Ajuste a data de início do semestre se necessário (botão de calendário no topo)
3. Adicione/edite seções e atividades (veja [Editor de Tabela](#editor-de-tabela))

### Passo 4: Vincule ao curso do Moodle

1. No Editor, clique no chip "Sem curso" no topo da barra
2. Selecione o curso Moodle correspondente
3. Vincule cada seção e atividade (manualmente ou via avaliação automática)

### Passo 5: Avalie e sincronize

1. Clique em "Avaliar" (ícone de avaliação) para gerar a correspondência
2. Revise os scores de correspondência (verde ≥ 80%, amarelo ≥ 50%, vermelho < 50%)
3. Clique em "Sincronizar" (ícone de sync) para enviar as alterações ao Moodle

---

## Tela Inicial (Home)

A tela inicial é o painel central do aplicativo, onde todas as configurações são listadas.

### Barra Superior

| Elemento | Função |
|----------|--------|
| **Título** | "Gestor UFU" |
| **Status de conexão** | Exibe o nome do usuário logado (verde) ou "Desconectado" (cinza) |
| **Botão de login** | Abre o diálogo de autenticação Moodle |

### Grade de Configurações

Cada configuração aparece como um card com:

| Elemento | Descrição |
|----------|-----------|
| **Nome** | Título da disciplina (com macros resolvidas visualmente) |
| **Data de início** | Data de início do semestre (formato dd/MM/yyyy) |
| **Seções** | Badge mostrando a quantidade de seções |
| **Status Moodle** | Ícone verde se vinculada a um curso, cinza se não |
| **Botão XLSX** | Exporta a configuração para planilha Excel |
| **Menu (⋮)** | Opções: Sincronizar, Exportar, Excluir |

### Botão Flutuante (+)

Ao clicar, apresenta um menu com 4 opções:

1. **Novo vazio** — Cria uma configuração em branco com apenas o nome
2. **Importar Planilha** — Abre seletor de arquivos para importar `.xlsx`
3. **Download Template** — Gera e salva uma planilha modelo para referência
4. **Importar do Moodle** — Busca a estrutura de um curso existente (requer login)

### Estado Vazio

Se não houver nenhuma configuração, uma mensão de boas-vindas é exibida com botões de ação para criar ou importar.

---

## Editor de Tabela

É a tela principal de edição, onde você define toda a estrutura da disciplina.

### Barra de Ação (Topo)

| Botão | Ícone | Ação |
|-------|-------|------|
| **Voltar** | ← | Retorna à tela inicial |
| **Nome da config** | Texto editável | Clique para renomear a disciplina |
| **Chip do curso** | Chip colorido | Mostra o curso Moodle vinculado; clique para vincular/desvincular |
| **Desvincular tudo** | Ícone vermelho | Remove TODOS os vínculos Moodle (seções + atividades) |
| **Avaliar** | Ícone azul | Executa o algoritmo de correspondência local ↔ Moodle |
| **Sincronizar** | Ícone cyan | Abre a tela de sincronização (disponível após avaliação) |

### Cabeçalho de Data

| Elemento | Função |
|----------|--------|
| **Data do semestre** | Exibe a data base (dd/MM/yyyy) |
| **Expandir/Recolher** | Alterna todas as seções |
| **Alterar data** | Abre DatePicker; ao mudar, **todas** as datas são recalculadas proporcionalmente |

### Seções

Cada seção é um card colapsável contendo:

| Campo | Descrição |
|-------|-----------|
| **Badge numérico** | Índice de ordem da seção (arrastável para reordenar) |
| **Nome** | Texto editável (suporta macros de data) |
| **Vínculo Moodle** | Mostra a seção Moodle vinculada ou "Sem vínculo"; clique no picker para vincular |
| **Data** | Calculada como `semesterStart + offsetDays`; mostra também o delta em relação à seção anterior |
| **Visibilidade** | Ícone de olho: alterna visível/oculto |
| **Calendário** | Abre DatePicker para ajustar a data (recalcula o offset) |
| **Menu (⋮)** | Editar, Excluir seção, Adicionar atividade |
| **Score** | Após avaliação, mostra tooltip com scores de link/nome/posição |

### Atividades (dentro de cada seção)

Cada atividade é uma linha individual com:

| Campo | Descrição |
|-------|-----------|
| **Handle de arraste** | Aparece em modo de seleção múltipla; arraste para reordenar |
| **Badge de tipo** | Badge colorido: "Tarefa", "Questionário", "Fórum", etc. |
| **Nome** | Texto editável com macros; ao passar o mouse, exibe as datas resolvidas |
| **Offsets** | "Abre: +Nd HH:MM / Fecha: +Nd HH:MM" relativo à data da seção |
| **Vínculo Moodle** | Picker inline para selecionar o módulo Moodle correspondente |
| **Score** | Após avaliação: verde (≥80%), amarelo (50-80%), vermelho (<50%), cinza (sem correspondência) |
| **Visibilidade** | 0=oculta, 1=visível, 2=stealth |

### Seleção Múltipla

- **Shift+Click**: seleciona um intervalo de atividades
- **Ctrl+Click**: alterna seleção de atividades individuais
- **FAB**: mostra "N selecionadas — arraste pelo handle"
- **Escape**: desfaz toda a seleção
- Atividades selecionadas podem ser movidas em lote para outra seção via drag-and-drop

---

## Sistema de Macros de Data

Um dos recursos mais poderosos do Gestor UFU é o sistema de macros. Em vez de digitar datas fixas nos nomes de atividades, você usa marcadores que são resolvidos automaticamente quando a data do semestre muda.

### Macros Disponíveis

| Macro | Descrição | Exemplo de entrada | Resultado (baseDate = 16/02/2026) |
|-------|-----------|-------------------|-----------------------------------|
| `<DD/MM/YYYY>` | Data da seção completa | `"Atividade de <DD/MM/YYYY>"` | `"Atividade de 16/02/2026"` |
| `<DD/MM/YYYY + N>` | Data da seção + N dias | `"Prazo: <DD/MM/YYYY + 7>"` | `"Prazo: 23/02/2026"` |
| `<DD/MM/YYYY - N>` | Data da seção - N dias | `"Início: <DD/MM/YYYY - 3>"` | `"Início: 13/02/2026"` |
| `<DD>` | Dia (2 dígitos) | `"Dia <DD>"` | `"Dia 16"` |
| `<D>` | Dia (sem zero à esquerda) | `"Dia <D>"` | `"Dia 16"` |
| `<MM>` | Mês (2 dígitos) | `"Mês <MM>"` | `"Mês 02"` |
| `<M>` | Mês (sem zero à esquerda) | `"Mês <M>"` | `"Mês 2"` |
| `<YYYY>` | Ano (4 dígitos) | `"Ano <YYYY>"` | `"Ano 2026"` |

### Sufixos de Contexto

Macros podem ter sufixos que indicam **qual data** usar:

| Sufixo | Significado | Exemplo |
|--------|-------------|---------|
| *(nenhum)* | Usa a data da seção | `<DD/MM/YYYY>` |
| `AI` | Usa a data de **abertura** da atividade | `<DD/MM/YYYY>AI` |
| `AF` | Usa a data de **fechamento** da atividade | `<DD/MM/YYYY>AF` |

### Exemplos Práticos

```
Nome da atividade no template:
  "Teórica Quarta: Aula de <DD/MM/YYYY>"
  
Com semesterStart = 16/02/2026 e sectionOffset = 0:
  → "Teórica Quarta: Aula de 16/02/2026"

Com semesterStart = 17/02/2027 e sectionOffset = 0:
  → "Teórica Quarta: Aula de 17/02/2027"

---

Nome com offset:
  "BLOCO 01 (Inicia: <DD/MM/YYYY> e Termina: <DD/MM/YYYY + 7>)."
  
Com semesterStart = 16/02/2026 e sectionOffset = 0:
  → "BLOCO 01 (Inicia: 16/02/2026 e Termina: 23/02/2026)."

---

Nome com data de abertura/fechamento:
  "Tarefa <DD/MM/YYYY>AI a <DD/MM/YYYY>AF"
  
Com openDate = 16/02/2026 e closeDate = 23/02/2026:
  → "Tarefa 16/02/2026 a 23/02/2026"
```

### Substituição Reversa

Quando você importa de uma planilha ou do Moodle, o Gestor UFU detecta datas no formato `dd/MM/yyyy` nos nomes e as substitui automaticamente por macros. A prioridade de detecção é:

1. Data exata da abertura da atividade → `<DD/MM/YYYY>AI`
2. Data exata do fechamento da atividade → `<DD/MM/YYYY>AF`
3. Data relativa à seção → `<DD/MM/YYYY>` ou `<DD/MM/YYYY ± N>`

---

## Vinculação com o Moodle

A vinculação é o processo de associar os itens da sua configuração local aos itens reais do Moodle. É necessária para que a sincronização saiba o que atualizar.

### Hierarquia de Vinculação

```
Configuração ←→ Curso Moodle (moodleCourseId)
  └── Seção local ←→ Seção Moodle (moodleSectionId)
        └── Atividade local ←→ Módulo Moodle (moodleModuleId)
```

### Como Vincular

**Nível de Curso:**
1. No Editor de Tabela, clique no chip "Sem curso" na barra superior
2. Selecione o curso desejado no picker (lista cursos onde você é editor)
3. O chip mudará para verde com o nome do curso

**Nível de Seção:**
1. Em cada seção, clique no texto "Sem vínculo" (ou no ícone de link)
2. No picker que aparece, selecione a seção Moodle correspondente
3. As atividades da seção ficarão disponíveis para vinculação

**Nível de Atividade:**
1. Em cada atividade, clique no texto "Sem vínculo"
2. No picker, selecione o módulo Moodle (apenas módulos da seção vinculada são exibidos)
3. O nome offline do módulo (`moodleModuleName`) é salvo para exibição quando estiver sem internet

### Vinculação Automática (via Avaliação)

Ao clicar em "Avaliar", o algoritmo:
1. Compara nomes usando **Jaro-Winkler** (similaridade fonética)
2. Verifica posição relativa na lista
3. Sugere links para itens não vinculados com score > 30%
4. Na tela de sync, você pode aceitar ou rejeitar as sugestões

---

## Avaliação de Correspondência (Evaluate)

O algoritmo de correspondência gera um **score de 0 a 100%** para cada par local ↔ Moodle, baseado em três fatores:

### Composição do Score

| Fator | Peso | Cálculo |
|-------|------|---------|
| **Link** | 33% | 1.0 se vinculado manualmente, 0.0 se não |
| **Nome** | 33% | Jaro-Winkler entre o nome local (resolvido) e o nome do Moodle |
| **Posição** | 33% | 1.0 se na mesma posição relativa entre os vinculados, 0.0 se não |

### Interpretação Visual

| Cor | Score | Significado |
|-----|-------|-------------|
| 🟢 Verde | ≥ 80% | Correspondência forte — provavelmente correto |
| 🟡 Amarelo | 50-80% | Correspondência parcial — revise |
| 🔴 Vermelho | < 50% | Correspondência fraca — provavelmente incorreto |
| ⚪ Cinza | Sem score | Sem correspondência disponível |

### Sugestões para Itens Não Vinculados

Para seções e atividades sem vínculo, o algoritmo busca o melhor candidato Moodle:
- Calcula Jaro-Winkler entre o nome local e todos os candidatos disponíveis
- Filtra candidatos com score ≥ 0.3
- Apresenta o melhor na tela de sync para confirmação

---

## Sincronização com o Moodle

A sincronização é o processo final que aplica as alterações ao Moodle. É feita em 2 etapas.

### Etapa 0: Confirmação de Links (se necessário)

Se houver itens não vinculados com sugestões:
- Uma lista mostra cada item não vinculado com a sugestão e o score de confiança
- Você pode aceitar a sugestão ou escolher manualmente de um dropdown
- Clique em "Confirmar e Sincronizar" para prosseguir

### Etapa 1: Execução da Sincronização

O processo executa, para cada seção vinculada:

1. **Atualização do nome da seção** — Se o nome local (resolvido) difere do nome no Moodle, atualiza via API
2. **Atualização de visibilidade** — Para cada atividade: hidden (0), show (1), ou stealth (2)
3. **Atualização de nomes de atividades** — Se o nome local difere do Moodle (tratamento especial para labels/áreas de texto)
4. **Reordenação** — Compara a ordem desejada (local) com a ordem atual (Moodle) e move módulos fora de posição

### Progresso em Tempo Real

Durante a sync, a UI exibe:
- Barra de progresso (0-100%)
- Mensagens ao vivo: "Atualizando seção: ...", "Visibilidade: ...", "Reordenando..."
- Ao final: resumo de sucesso ou lista de erros

### Tratamento de Erros

| Erro | Comportamento |
|------|---------------|
| **Permissão negada (nomes)** | Pula atualizações de nome restantes, conta quantas foram ignoradas |
| **Sessão AJAX expirada** | Tenta re-autenticar automaticamente e retenta |
| **Erro HTTP** | Registra o erro e continua com os próximos itens |
| **Erro de rede** | Aborta e exibe mensagem |

### Log de Reordenação

Após a sincronização, um log detalhado é gerado mostrando:
- A ordem desejada vs. a ordem atual no Moodle
- Cada operação `moveModule` executada
- Resultado de cada chamada de API

---

## Importação e Exportação de Planilhas

### Formato da Planilha (.xlsx)

O Gestor UFU espera planilhas no seguinte formato:

#### Cabeçalho (linhas iniciais)

```
Linha 1: "Inicio do Semestre"  |  <data dd/MM/yyyy ou serial Excel>
Linha 2: "Disciplina"          |  <nome da disciplina>
Linha 3: "Moodle Course ID"    |  <ID do curso> (opcional)
```

#### Tabela de Dados

| Ordem | Dias Início | Hora Início | Dias Término | Hora Término | Nome | Tipo | Visível | Descrição | Moodle ID |
|-------|-------------|-------------|--------------|--------------|------|------|---------|-----------|-----------|
| 1 | 0 | | | | BLOCO 01 | Seção | S | | 70348 |
| | 0 | 08:00 | 7 | 17:00 | Prática: Aula de <DD/MM/YYYY> | Tarefa | S | | 750109 |
| | 0 | 08:00 | 7 | 17:00 | Teórica Quarta | Questionário | S | | 750068 |
| 2 | 7 | | | | BLOCO 02 | Seção | S | | 122802 |

**Regras:**
- **Tipo "Seção"**: Define uma nova seção. O campo "Ordem" é o índice, "Dias Início" é o offset em dias a partir da data de início do semestre
- **Demais tipos**: São atividades dentro da última seção declarada
- **Dias Início/Término**: Offsets relativos à data de referência da seção
- **Hora**: Formato HH:MM (ex.: "08:00", "23:59")
- **Visível**: "S" = sim, "N" = não
- **Moodle ID**: ID do módulo Moodle (opcional, para revinculação)

### Exportação

1. Na tela inicial, clique no botão XLSX no card da configuração
2. Ou use o menu (⋮) → "Exportar"
3. O arquivo `.xlsx` será gerado com todos os dados atuais

### Download do Template

1. Na tela inicial, clique no `+` → "Download Template"
2. Um arquivo de exemplo será salvo com:
   - 3 semanas de amostra
   - Atividades de diferentes tipos (Prática, Teórica)
   - Datas demonstrando offsets e macros

### Detecção de Duplicatas

Ao importar uma planilha cujo nome já existe:
- O app pergunta: **Substituir** a configuração existente ou **Criar cópia**?
- "Substituir" mantém o mesmo ID (e vínculos Moodle existentes)
- "Criar cópia" gera um novo ID independente

---

## Importação Direta do Moodle

Uma alternativa à planilha é importar diretamente do Moodle:

1. Faça login no Moodle (se ainda não estiver)
2. Clique no `+` → "Importar do Moodle"
3. Selecione o curso na lista de cursos onde você é editor
4. Escolha a data de início do semestre via DatePicker
5. O Gestor UFU busca:
   - Todas as seções do curso
   - Todos os módulos de cada seção (com IDs, nomes, tipos, datas)
   - Restrições de data (abertura/fechamento) de cada módulo
6. Uma configuração é criada com:
   - Seções e atividades na mesma ordem do Moodle
   - IDs Moodle já vinculados
   - Datas convertidas em offsets relativos
   - Nomes com datas convertidas em macros automaticamente

---

## Visibilidade de Atividades

O Gestor UFU suporta 3 estados de visibilidade, espelhando o comportamento do Moodle:

| Valor | Estado | No Moodle |
|-------|--------|-----------|
| **0** | Oculto | Atividade completamente invisível para alunos |
| **1** | Visível | Atividade visível e acessível normalmente |
| **2** | Stealth | Atividade acessível via link direto, mas não aparece na listagem |

### Como Alterar

- No Editor de Tabela, clique no ícone de olho de cada atividade para alternar entre os estados
- Na sincronização, a visibilidade local é aplicada ao Moodle via `core_course_edit_module` (ações: `hide`, `show`, `stealth`)

---

## Reordenação de Atividades

### No Editor (Local)

- **Dentro da seção**: Arraste atividades pelo handle para reposicionar
- **Entre seções**: Selecione atividades (Shift/Ctrl+Click), então arraste para outra seção
- **Seções**: Arraste pelo badge numérico para reorganizar seções inteiras

### No Moodle (Sincronização)

Na sincronização, o Gestor UFU compara a ordem local com a ordem do Moodle e move módulos que estão fora de posição:

1. Determina a `desiredOrder` (IDs dos módulos na ordem local)
2. Obtém a `currentOrder` do Moodle (filtrada para módulos vinculados)
3. Se as ordens diferem, executa chamadas `cm_move` na API AJAX
4. Itera do último ao primeiro módulo, colocando cada um ANTES do próximo na sequência desejada (`targetcmid` = "colocar antes deste módulo")
5. Módulos em seções diferentes são movidos primeiro para a seção correta

> **Nota técnica:** O parâmetro `targetcmid` na API `cm_move` do Moodle significa "colocar ANTES deste módulo". `targetcmid=null` significa "colocar no final da seção".

---

## Tipos de Atividade Suportados

O Gestor UFU reconhece todos os tipos de módulo do Moodle. Os mais comuns:

| Tipo (modname) | Nome Exibido | Possui Datas |
|----------------|--------------|--------------|
| `assign` | Tarefa | ✅ (abertura, entrega) |
| `quiz` | Questionário | ✅ (abertura, fechamento) |
| `feedback` | Pesquisa | ✅ |
| `choice` | Escolha | ✅ |
| `forum` | Fórum | ❌ |
| `resource` | Arquivo | ❌ |
| `url` | URL | ❌ |
| `page` | Página | ❌ |
| `folder` | Pasta | ❌ |
| `label` | Área de texto e mídia | ❌ (atualização de nome tratada especialmente) |
| `wiki` | Wiki | ❌ |
| `glossary` | Glossário | ❌ |
| `lesson` | Lição | ❌ |
| `h5pactivity` | H5P | ❌ |

> Tipos não reconhecidos são exibidos com o `modname` original do Moodle.

---

## Referência de API Moodle

O Gestor UFU utiliza as seguintes APIs do Moodle:

| Endpoint | Tipo | Finalidade |
|----------|------|------------|
| `/login/token.php` | REST POST | Obtenção de token de autenticação |
| `/login/index.php` | HTML POST | Estabelecimento de sessão AJAX (cookies + sesskey) |
| `/lib/ajax/service.php` | AJAX POST | Chamadas de funções AJAX (requer sesskey) |
| `/webservice/rest/server.php` | REST GET/POST | Chamadas de web service |

### Funções Web Service

| Função | Uso |
|--------|-----|
| `core_webservice_get_site_info` | Informações do site e do usuário logado |
| `core_enrol_get_users_courses` | Listar cursos do usuário |
| `core_course_get_contents` | Obter seções, módulos e datas de um curso |

### Funções AJAX

| Função | Uso |
|--------|-----|
| `core_update_inplace_editable` | Atualizar nomes de seções e módulos inline |
| `core_course_edit_module` | Alterar visibilidade (hide/show/stealth) |
| `core_courseformat_update_course` (`cm_move`) | Mover módulos entre posições/seções |

---

## Estrutura do Projeto

O projeto segue **Clean Architecture** com separação em camadas:

```
lib/
├── main.dart                          # Ponto de entrada, providers, MaterialApp
├── core/
│   ├── router/
│   │   └── app_router.dart            # Definição de rotas (GoRouter)
│   ├── theme/
│   │   └── app_theme.dart             # Cores, gradientes, tipografia
│   └── utils/
│       ├── date_calculator.dart        # Cálculos de data e offsets
│       ├── macro_resolver.dart         # Resolução e reversão de macros
│       ├── responsive.dart             # Breakpoints responsivos
│       └── string_matcher.dart         # Jaro-Winkler e busca de correspondência
├── data/
│   ├── template_generator.dart         # Geração de planilha template
│   ├── datasources/
│   │   ├── local_datasource.dart       # Persistência local (JSON)
│   │   └── moodle_datasource.dart      # Cliente HTTP para APIs Moodle
│   └── repositories/
│       ├── config_repository_impl.dart # CRUD + import/export XLSX
│       └── moodle_repository_impl.dart # Wrapper sobre MoodleDatasource
├── domain/
│   ├── entities/
│   │   ├── course_config.dart          # CourseConfig, SectionEntry, ActivityEntry
│   │   └── moodle_entities.dart        # MoodleCredential, MoodleCourse, MoodleSection, etc.
│   └── repositories/
│       ├── i_config_repository.dart    # Interface do repositório de config
│       └── i_moodle_repository.dart    # Interface do repositório Moodle
└── presentation/
    ├── controllers/
    │   ├── auth_controller.dart        # Autenticação Moodle
    │   ├── config_controller.dart      # CRUD de configurações
    │   └── sync_controller.dart        # Correspondência, sugestões, sincronização
    ├── pages/
    │   ├── home_page.dart              # Tela inicial com grid de configs
    │   ├── table_editor_page.dart      # Editor principal de seções/atividades
    │   ├── sync_preview_page.dart      # Confirmação de links + progresso de sync
    │   └── moodle_link_page.dart       # Vinculação manual (interface alternativa)
    └── widgets/
        ├── common_widgets.dart         # GlassCard, GradientButton, StatusChip, EmptyState
        ├── inline_edit_text.dart       # Campo de texto editável inline
        └── inline_link_picker.dart     # Picker inline para seleção de links Moodle
```

---

## Build & Release (CI/CD)

O projeto inclui um workflow GitHub Actions para build e release automatizados.

### Disparando uma Release

1. Vá em **Actions** → **"Flutter Build & Release (Gestor UFU)"**
2. Clique em **"Run workflow"**
3. Preencha:
   - **Versão**: ex. `v1.0.0`, `V1.2.3-RC1`
   - **Notas** (opcional): descrição da release
4. O workflow executa:
   - **Normalização de versão** (remove prefixo `v/V`, gera formato WiX `X.Y.Z.W`)
   - **Build Windows MSI** (Flutter build + WiX Toolset para instalador)
   - **Build Android APK** (Flutter build com Java 17)
   - **Criação de Release** no GitHub com ambos os artefatos anexados

### Artefatos Gerados

| Artefato | Nome | Descrição |
|----------|------|-----------|
| **MSI** | `GestorUFU-X.Y.Z-windows.msi` | Instalador Windows com atalhos no Menu Iniciar e Área de Trabalho |
| **APK** | `GestorUFU-X.Y.Z-android.apk` | Pacote Android instalável |

---

## Desenvolvimento

### Pré-requisitos

```bash
# Instalar Flutter (se necessário)
# https://docs.flutter.dev/get-started/install

# Verificar a instalação
flutter doctor

# Clonar o repositório
git clone https://github.com/josuemoraisgh/config_moodle.git
cd config_moodle
```

### Comandos Úteis

```bash
# Instalar dependências
flutter pub get

# Executar no Windows
flutter run -d windows

# Executar no navegador
flutter run -d chrome

# Executar análise estática
dart analyze lib/

# Executar testes
flutter test

# Build de release (Windows)
flutter build windows --release

# Build de release (APK)
flutter build apk --release

# Gerar APK com bundle
flutter build appbundle --release
```

### Dependências Principais

| Pacote | Versão | Finalidade |
|--------|--------|------------|
| `provider` | ^6.1.2 | Gerenciamento de estado reativo |
| `go_router` | ^14.8.1 | Navegação declarativa |
| `google_fonts` | ^6.2.1 | Tipografia Poppins |
| `http` | ^1.4.0 | Requisições HTTP para APIs Moodle |
| `shared_preferences` | ^2.5.3 | Persistência de credenciais Moodle |
| `file_picker` | ^8.3.7 | Seleção de arquivos para importação |
| `excel` | ^4.0.6 | Leitura e escrita de planilhas .xlsx |
| `intl` | ^0.20.2 | Formatação de datas (dd/MM/yyyy) |
| `path_provider` | ^2.1.5 | Diretório de documentos do app |
| `uuid` | ^4.5.1 | Geração de IDs únicos |
| `collection` | ^1.19.1 | Utilitários de coleção (ListEquality, etc.) |

---

## Solução de Problemas

### Login falha com "Token not found"

- **Causa:** Web services não estão habilitados no Moodle
- **Solução:** O administrador deve habilitar o protocolo REST em `Administração > Plugins > Web services > Gerenciar protocolos`

### Login falha com "Invalid login"

- **Causa:** Credenciais incorretas ou conta bloqueada
- **Solução:** Verifique usuário/senha. Tente fazer login diretamente no Moodle pelo navegador

### Nomes de atividades não atualizam ("Permission denied")

- **Causa:** A sessão AJAX expirou ou o usuário não tem permissão de edição inline
- **Solução:** Faça logout e login novamente. Verifique se você tem role de "Editing Teacher" ou "Manager" no curso

### Visibilidade "Stealth" não funciona

- **Causa:** O Moodle precisa ter a funcionalidade de stealth habilitada
- **Solução:** O administrador deve habilitar em `Administração > Aparência > Avançado > Permitir atividades stealth`

### Reordenação não persiste

- **Causa historicamente resolvida:** O parâmetro `targetcmid` significa "colocar ANTES", não "depois"
- **Estado atual:** Corrigido — a sincronização itera do último ao primeiro módulo

### Planilha não importa corretamente

- **Causa:** Formato incorreto
- **Solução:** Baixe o template de exemplo e siga a estrutura. Apenas `.xlsx` é suportado (`.xls` antigo não é aceito)

### Erro "Session expired" durante sincronização

- **Causa:** A sessão AJAX do Moodle expirou durante operações longas
- **Solução:** O app tenta re-autenticar automaticamente. Se persistir, faça logout/login e sincronize novamente

---

## Licença

Este software é distribuído gratuitamente pelo autor.

O software é fornecido "como está", sem garantias expressas ou implícitas. O uso é de responsabilidade exclusiva do usuário.

**Autor:** Josue Morais — [GitHub](https://github.com/josuemoraisgh)
