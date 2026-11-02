# Checklist do inventário do Gestor UFU

**Referência do código:** versão `1.1.7+9`, commit `8d404b1e10e4369689476a995894d4e6fe086b05`
**Data da revisão:** 02/11/2026
**Ambiente visual:** clone Windows local, dados fictícios, preferências isoladas do aplicativo instalado.

Este checklist foi obtido a partir das rotas, páginas e serviços Flutter/Dart, complementado por navegação real na cópia de demonstração. “Código” significa inspeção estática; “Execução” significa que a tela foi aberta; “Não exercitado” significa que o procedimento de ponta a ponta depende de dados/conta/arquivo e não foi submetido como se fosse comprovado.

## Rotas

| Rota/tela | Fonte principal | Status | Manual/captura |
|---|---|---|---|
| Painel `/` | `dashboard_page.dart` | Execução | Primeiros passos; `inicio-dashboard*.jpg` |
| Config Moodle `/moodle` | `home_page.dart` | Execução | Config Moodle; lista/criação/editor capturados |
| Editor da tabela `/editor/:id` | `table_editor_page.dart` | Execução parcial | Seções, atividade, contexto capturados |
| Vínculo Moodle `/sync/:id` | `sync_preview_page.dart` | Código; não autenticado | Explicado; integração não exercitada |
| Mapeamento de seção/atividade | `moodle_link_page.dart` | Código; não autenticado | Explicado em Config Moodle |
| Extrair Árvore `/sei` | `sei_tree_page.dart` | Execução do estado inicial | Captura `sei-conectar-vazio.jpg`; resultado não exercitado |
| Preenche Diários `/diario` | `preenche_diarios_page.dart` | Execução | Inicial, nova aula, calendário capturados |
| Planos de Ensino `/planos-ensino` | `planos_ensino_page.dart` | Execução | Lista vazia, identificação e cronogramas capturados |
| Planos de Trabalho `/planos-trabalho` | `planos_trabalho_page.dart` | Execução da lista vazia | Captura `planos-trabalho-vazio.jpg`; modelo não exercitado |
| Ajusta Horários `/ajusta-horarios` | `ajusta_horarios_page.dart` | Execução | Curso, docente e distribuição capturados |
| Inserir Documentos no SEI | Cartão do dashboard | Indisponível | Cartão “Em breve”, sem rota funcional |

## Funcionalidades e interações identificadas

- **Geral:** tema claro/escuro persistido; arquivo de dados local/compartilhado; senha de arquivo quando configurada; cartões de módulo visíveis/ocultos e reordenáveis; backup completo JSON importar/exportar; atualização por GitHub Releases. Coberto em `site/primeiros-passos.html`. A atualização não foi disparada nem uma instalação limpa revalidada.
- **Config Moodle:** criar vazio, importar XLSX, baixar modelo, importar cursos Moodle, resolução de nomes duplicados; cartão com abrir, sincronizar, exportar XLSX/Word, histórico e excluir; criar/editar/reordenar/ocultar/remover seções; criar/editar/reordenar/remover atividade; datas fixas/relativas, calendário, feriado/substituição; login Moodle; vincular seções e atividades; rever prévia e sincronizar. Coberto em `site/config-moodle.html`. Operações remotas não exercitadas.
- **Preenche Diários:** importar Excel/JSON, buscar cronograma Moodle/Config Moodle, aplicar por mesclar/substituir, adicionar/editar/remover/limpar aula, data digitável/calendário, modalidade, descrição, ajuste de datas com prévia, histórico/backup de semestre, exportar JSON, credenciais do Portal, abrir Edge, opções de sobrescrita/destaque, automação e log. Coberto em `site/preenche-diarios.html`; autenticação/envio ao portal não exercitados.
- **SEI:** configurar endereço, abrir Edge, login manual, extrair árvore do processo, mensagens de progresso, revisar tabela (nome, tipo/número, código, data, resumo), copiar/exportar. Coberto em `site/sei.html`; processo e extração não exercitados.
- **Planos de Ensino:** CRUD de planos, import/export backup, import Word, campos do formulário por abas, cronograma TSV, extrair Config Moodle/colar tabela, aplicar dados, editar/excluir, exportar Word, inserir no SEI e confirmação. Coberto em `site/planos-ensino.html`; importações/exportações e inserção não exercitadas.
- **Planos de Trabalho:** CRUD, importar planilha preenchida, abrir Excel, selecionar/substituir modelo, mapear campos por aba/célula/tipo, filtrar prévia, gerar cópia/PDF e inserir documento no SEI; endereços persistidos e log. Coberto em `site/planos-trabalho.html`; importação e geração não exercitadas.
- **Ajusta Horários:** período atual, criar período vazio/copiar outro, cursos add/remove, períodos 1–10 e optativas, disciplinas CRUD, cadastro de docentes, múltiplas modalidades e turmas, sala/docentes/horários, validação visual de carga, grade por curso/docente, duplo clique para associação, distribuição docente com filtro e edição da associação, PDF colorido/CSV, importar/exportar base e persistência de seleção/rolagem. Coberto em `site/ajusta-horarios.html`. Apenas três abas de leitura foram exercitadas visualmente; não foram alterados registros além do seed demonstrativo.
- **Atalhos:** não há catálogo global de atalhos no código consultado. Há duplo clique em horário da grade e menus contextuais em cartões/seções/atividades. Registrar outros atalhos apenas após confirmação.
- **Perfis:** não existe camada interna de perfis/papéis; autorização remota é da própria plataforma institucional.

## Capturas de tela

Capturas reais na cópia isolada do programa:

- Dashboard claro/escuro, configurações gerais.
- Config Moodle: lista vazia, opções de criação/importação, formulário, cartão, editor, seção, menu contextual e atividade.
- Preenche Diários: tela vazia, diálogo de aula e calendário nativo.
- SEI: tela inicial/desconectada.
- Planos de Ensino: lista vazia, identificação e cronogramas.
- Planos de Trabalho: lista vazia.
- Ajusta Horários: grade por curso, grade por docente e distribuição docente.

As capturas estão sob `docs/manual/site/assets/screenshots/`. Não foram capturados: confirmação de exclusão/substituição real, menus de seletor em todos estados, resultados de conexão Moodle/Portal/SEI, extração de processo, importação Word/Excel de produção, saída de PDF/CSV e edição completa de horários. Motivos: essas operações demandam contas institucionais, modelos reais ou escrita remota; a demonstração foi mantida isolada e sem dados pessoais. O site descreve os caminhos presentes no código e sinaliza os limites em cada página.
