# Decisões de arquitetura

## D1 — Plataforma e módulos
O Gestor UFU é uma plataforma (`lib/platform/`) que oferece recursos comuns, e
cada funcionalidade é um módulo (`lib/modules/<id>/`) compilado junto com o
app — não há carregamento de plugins em tempo de execução.

Dependências permitidas:
- `platform/` não importa módulos nem `app/`;
- `modules/<id>/` importa `platform/`, `core/` e o próprio módulo, nunca outro
  módulo;
- `app/` (composição) importa tudo: instancia os módulos em
  `installed_modules.dart` e liga os contratos entre eles.

Dados de outro módulo são obtidos por um contrato em `platform/contracts/`,
implementado pelo módulo dono e registrado em `app/`. A dependência é opcional
e validada na ativação do módulo que a usa.

## D2 — Comandos
Toda ação de botão que altera dados, lê/gera arquivos ou automatiza um
navegador vira um comando do módulo (`ModuleCommand`).
- Contrato interno em tipos Dart; o JSON schema é só o adaptador do agente.
- Comandos não usam `BuildContext`, diálogos nem seletores de arquivo: a tela
  resolve as interações e chama o comando com parâmetros.
- Comandos rodam na janela principal (dona do cache e do estado). A janela do
  agente os executa pelo canal `gestor_ufu_ai_agent_host`.
- Política de aprovação por comando (`CommandApproval.none` ou `.required`):
  com `.required`, o agente pede confirmação no chat antes de executar.
- O contrato cresce conforme o uso concreto (pré-condições, progresso,
  desfazer) — sem abstração antecipada.

## D3 — Telas
Toda tela principal de módulo usa `ModuleScaffold`: primeira linha com
Voltar, ícone e título do módulo, ações do módulo e, fixos à direita, o botão
do Agente de IA e o seletor de tema. Telas densas (editor, prévia de
sincronização, janelas secundárias) usam variantes com o mesmo cabeçalho.

## D4 — Persistência
O banco continua sendo o SharedPreferences sincronizado. Acesso por um
armazenamento com namespace do módulo, chaves versionadas e migrações
explícitas. Chaves existentes não mudam de nome (compatibilidade com dados e
backups já sincronizados).

## D5 — Navegador
Um serviço da plataforma unifica achar o Edge/Chrome, abrir com perfil e
conectar/reconectar pelo DevToolsActivePort. Cada uso tem perfil e sessão
próprios (Portal do Docente, SEI, agente); o serviço não compartilha a mesma
janela entre usos.
