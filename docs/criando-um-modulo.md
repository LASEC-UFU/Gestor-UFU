# Criando um módulo no Gestor UFU

O Gestor UFU funciona como uma plataforma: a base (`lib/platform/`) oferece os recursos comuns, e cada funcionalidade é um **módulo** em `lib/modules/<id>/`. Um módulo novo aparece no painel e ganha rota, cabeçalho padrão (Voltar · título · ações · Agente e Tema) e integração com o Agente de IA, tudo a partir de uma única classe.

O exemplo completo e testado é [`lib/modules/_modelo/`](../lib/modules/_modelo/) (Anotações), com o teste [`test/modules/modelo_module_test.dart`](../test/modules/modelo_module_test.dart). As regras de arquitetura estão em [`docs/arquitetura/decisoes.md`](arquitetura/decisoes.md).

## Passo a passo

1. Copie `lib/modules/_modelo/` para `lib/modules/<id>/` e troque `modelo`/`Modelo`/`Nota` pelos nomes do módulo.
2. Preencha o descritor (`<id>_module.dart`): id, título, descrição, ícone, cor, categoria do painel e rota.
3. Escreva a regra de negócio no serviço (`application/<id>_service.dart`).
4. Exponha cada ação da tela como comando (`application/<id>_commands.dart`).
5. Escreva a skill (`<id>_skill.dart`): é o que o agente lê para ajudar o usuário.
6. Registre o módulo em [`lib/app/installed_modules.dart`](../lib/app/installed_modules.dart). A posição na lista é a ordem do painel.
7. Escreva testes dos comandos em `test/modules/<id>_test.dart`.

## Estrutura

```
lib/modules/<id>/
  <id>_module.dart        descritor (GestorModule): painel, rotas, janelas, skill, comandos, modelos
  <id>_skill.dart         guia para o Agente de IA
  <id>_templates.dart     modelos de arquivo das importações (opcional)
  domain/                 entidades e regras puras (sem Flutter, sem banco)
  data/                   leitura e gravação no banco (KeyValueStore)
  application/            serviço (regra de negócio) e comandos
  pages/                  telas (só interação: diálogos, seletores, layout)
```

## Regras de dependência

- Um módulo importa só `lib/platform/`, `lib/core/`, `lib/domain/entities/` e o próprio código. Nunca importa outro módulo.
- `lib/platform/` nunca importa módulos.
- Quando um módulo precisa de dados de outro, a interface fica em `lib/platform/contracts/`. O módulo que oferece os dados a registra em `activate` (`services.registerContract<T>(...)`), e o que usa os lê com `services.contract<T>()`. A dependência é opcional: trate o `null`. Exemplo: `MoodlePlanning`, usado por Diários e Planos de Ensino.

## Recursos da plataforma

| Recurso | Onde | Uso |
|---|---|---|
| Banco compartilhado | `KeyValueStore` (`services.store`) | `readJson`/`writeJson`/`readString`/`readStringList`..., sincronizado entre computadores |
| Chave por período letivo | `KeyValueStore.termScoped(prefixo, período)` | dados que mudam a cada semestre |
| Períodos letivos | `AcademicTermService` (`services.terms`) | `load`, `active`, `terms`, `setActive`, `create` |
| Arquivos de saída | `GestorPaths` | `outputPath(pedido, nomePadrão, sub:)` e `readInput(path)` (erro `arquivo_nao_encontrado`) |
| Navegador (Edge) | `BrowserService` | `open(profileDir: BrowserService.localProfile('<Nome>Profile'))`, um perfil por finalidade |
| SEI | `SeiAutomationService` | abrir o SEI, inserir documento externo, ler a árvore do processo |
| Navegação | `NavigationService.go(rota)` | trocar de tela fora de um `BuildContext` |
| Cabeçalho | `ModuleScaffold` / `ModuleHeader` | obrigatório em toda tela de módulo |
| Modelos de planilha | `SheetTemplate.xlsx(aba, linhas)` / `SheetTemplate.json(...)` | arquivos de exemplo do `create_template` |

## Banco

- Use o prefixo do módulo e uma versão na chave (ex.: `modelo.notas.v1`).
- Depois de publicada, a chave não muda de nome: os dados já estão sincronizados em outros computadores. Para mudar o formato, crie a chave `v2` e migre a partir da `v1`.
- Nunca grave senhas, tokens ou credenciais no banco. Eles ficam no armazenamento seguro do Windows. O agente é impedido de ler chaves com `credential`, `password`, `senha` ou `token`.
- Quando o banco muda por fora (outro computador, ou o agente gravando direto), a plataforma chama `onExternalDataChanged()`. Recarregue o estado e avise a tela, com `notifyListeners` no serviço ou um `ValueNotifier` escutado pela tela.

## Comandos

Um comando é o que um botão faz, executável pela tela, pelo menu "/" e pelo agente (`list_commands` / `run_command`).

- Id `<módulo>.<ação>` em camelCase, ex.: `equivalencia.importarCurriculo`.
- Sem `BuildContext`, diálogos ou seletores de arquivo: quem chama resolve a interação e passa caminhos e valores na entrada.
- Valide a entrada com `input.requireString(...)` / `optionalString(...)`. Erros esperados são `CommandException(código, mensagem)`, com códigos estáveis em snake_case que o agente recebe como `{ok: false, code, message}`.
- `approval: CommandApproval.required` para ações destrutivas ou externas (remover, substituir uma base, enviar ao SEI): o agente mostra um cartão de aprovação antes de executar.
- `mutates: true` quando o comando altera o banco: a janela do agente avisa a principal para recarregar.
- `inputSchema` é o JSON schema mostrado ao agente. Descreva cada campo e de onde vêm os ids (ex.: "id de modelo.listar").
- Os comandos rodam na janela principal, onde estão o cache e o estado.

## Tela

- Use `ModuleScaffold(moduleId: '<id>', actions: [...], body: ...)`. Título, ícone e cor vêm do descritor.
- Telas densas que montam o próprio `Scaffold` usam `ModuleHeader` na primeira linha.
- A tela chama o serviço, o mesmo que os comandos usam, e escuta suas mudanças para se redesenhar quando o agente altera os dados.
- Janelas secundárias (editores em outra janela) são declaradas em `windows` no descritor e abertas com `desktop_multi_window`. Exemplo em `ajusta_horarios_module.dart`.

## Skill do agente

A skill é o manual que o agente lê quando o usuário está no módulo, ou quando pergunta sobre ele. Inclua:

- para que serve o módulo e onde fica cada ação na tela;
- os comandos com os parâmetros e os códigos de erro;
- os formatos de importação (colunas, abas) e o modelo correspondente do `create_template`.

## Testes

- Comandos: crie o serviço com `SharedPreferences.setMockInitialValues({})` e `KeyValueStore()`, e execute `command.run(input, CommandOrigin.test)`.
- Modelos de arquivo: gere o modelo, importe-o pelo comando e confira o resultado.
- Rode os testes pela unidade virtual: o espaço em `C:\Source Local` quebra os hooks nativos.

  ```
  subst X: "C:\Source Local"
  cd X:\Gestor-UFU
  flutter test
  ```

- [`test/platform/installed_templates_test.dart`](../test/platform/installed_templates_test.dart) confere que todo módulo com tela tem skill e que os ids de comando são únicos.
