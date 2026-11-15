# Inventário do ponto de partida (etapa 1)

Branch: `refactor/plataforma-modulos`, a partir de `8f24274` (v1.1.41).

## Qualidade
- `flutter analyze`: 129 avisos informativos, 0 erros, 0 avisos (warnings).
- `flutter test` (rodar por unidade virtual, pelo espaço em `C:\Source Local`:
  `subst X: "C:\Source Local"` e `flutter test` em `X:\Gestor-UFU`):
  39 passam, 3 falham — todos em `test/progressao_page_test.dart`, porque a
  tela passou a ter o `ThemeSelector` e o teste não fornece o
  `ThemeController`. Corrigido na migração da Progressão.

## Rotas e telas
| Rota | Tela | Módulo |
|---|---|---|
| `/` | DashboardPage | plataforma |
| `/moodle` | HomePage | moodle |
| `/editor/:id` | TableEditorPage | moodle |
| `/sync/:id` | SyncPreviewPage | moodle |
| `/diario` | PreencheDiariosPage | diario |
| `/sei` | SeiTreePage | sei |
| `/planos-ensino` | PlanosEnsinoPage | planos-ensino |
| `/planos-trabalho` | PlanosTrabalhoPage | planos-trabalho |
| `/ajusta-horarios` | AjustaHorariosPage | ajusta-horarios |
| `/equivalencia-alunos` | EquivalenciaAlunosPage | equivalencia-alunos |
| `/progressao` | ProgressaoPage | progressao |
"Inserir Documentos no SEI": cartão desativado, sem rota (não é módulo ainda).

## Janelas secundárias (`main.dart`, por `payload['type']`)
- `aiAgent` — janela do Agente de IA (plataforma).
- `scheduleEditor`, `teacherEditor`, `roomEditor` — editores do Ajusta
  Horários; hoje `main.dart` importa `ajusta_horarios_page.dart`.

## Persistência (SharedPreferences, sincronizado pelo SharedPreferencesSyncService)
20 arquivos chamam `SharedPreferences.getInstance()`.
- Plataforma: `dashboard.module_order.v1`, `dashboard.hidden_modules.v1`,
  tema (`ThemeController.storageKey`), `__gestor_ufu_cloud_sync_*` (metadados
  da sincronização, não sincronizados), backup (`preferences_backup_service`).
- Períodos letivos (compartilhados): `ajusta_horarios_periodos_letivos`,
  `ajusta_horarios_periodo_letivo` — lidos/gravados em 3 lugares
  (config_controller, ajusta_horarios_page/store, preenche_diarios_page).
- moodle: `config_moodle_data`, `moodle_config_history_v1`, `last_moodle_url`.
- diario: `preenche_diarios_period_data_v1_<token>`,
  `preenche_diarios_entries_v1` (antiga), `preenche_diarios_period_data_migrated_v1`,
  `portal_docente_url`, `portal_docente_credentials_v1` (credencial).
- sei: `sei_tree_address_url`.
- planos-ensino: `gestor_ufu_planos_ensino_v1`, `planos_ensino_sei_url`.
- planos-trabalho: `gestor_ufu_planos_trabalho_v1`, `planos_trabalho_sei_url`.
- ajusta-horarios: `ajusta_horarios_disciplinas_2026_2_ca_v2_<token>`,
  `ajusta_horarios_distribuicao_docente_<token>`,
  `ajusta_horarios_docentes_cadastrados_<token>`,
  `ajusta_horarios_salas_cadastradas_<token>`, `ajusta_horarios_cursos`,
  seleções de tela e ~12 marcadores de migração.
- equivalencia: `student_equivalencies.blocks.v1` (principal) e
  `student_equivalencies.v1` (antiga, lida só para migrar). Hipótese "uma
  chave" confirmada com ressalvas: o PDF usa as fontes
  `C:/Windows/Fonts/arial.ttf` e `arialbd.ttf`; há importação de currículo e de
  análise (.xlsx) e exportação do PDF.
- progressao: `progressao_docente.v1`, mais a pasta de comprovantes do
  processo (arquivos fora do banco).
- agente: `gestor_ufu_agente_conversa_v1_<id>` (histórico, sincronizado);
  configurações e chaves de API no cofre do Windows.

## Automações de navegador (Edge via puppeteer)
- `diary_automation_service` (Portal do Docente, perfil próprio, reconexão por
  DevToolsActivePort);
- `planos_ensino_automation_service` (SEI);
- `plano_trabalho_automation_service` (SEI);
- `agent_browser` (navegador do agente, conexão por DevToolsActivePort).
Cada um tem sua cópia de `_findEdge`/`_profileDirectory`.

## Ações de botões (fonte dos comandos)
Levantadas nas skills de `agent_skills.dart` (seção "Onde fica cada ação" de
cada módulo). Viram comandos módulo a módulo na etapa 5.
