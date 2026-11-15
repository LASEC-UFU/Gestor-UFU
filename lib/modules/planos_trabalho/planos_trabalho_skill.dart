import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill planosTrabalhoSkill() => ModuleSkill(
  title: 'Planos de Trabalho',
  summary: 'Plano de trabalho docente: planilha oficial e envio ao SEI.',
  body: '''
## Para que serve
Guarda os planos de trabalho docente, transfere os dados da planilha oficial
de um ano para o modelo novo (preservando fórmulas e formatação) e insere o
PDF do plano no processo do SEI como documento externo.

## Onde fica cada ação (tela Planos de Trabalho)
- "Novo plano" / "Editar cadastro" / "Remover plano": nome do plano, número
  do processo SEI, nome na árvore, interessado e o PDF ("Selecionar PDF").
- "Inserir no SEI": abre o SEI no Edge e insere o PDF como documento externo.
- "Dados e preenchimento Excel":
  · "Importar dados de planilha" — lê a planilha oficial já preenchida
    (.xlsx/.xlsm) e guarda os valores (campos com fórmula são ignorados);
  · "Atualizar campos do modelo" — compara com um modelo novo e acrescenta os
    campos que surgiram;
  · editar cada campo ("Editar campo", "Mostrar campos vazios");
  · "Salvar dados"; "Salvar e preencher planilha" — gera uma CÓPIA do modelo
    escolhido com os valores (prévia antes; campos vazios não substituem).

## Planilha oficial (formato exigido)
Precisa ter TODAS as abas, com os cabeçalhos nas células indicadas (senão:
"O modelo não contém as abas esperadas" ou "O modelo mudou em …"):
- Informações e Resumo: A7 "Docente:", A8 "Unidade:", A9 "Regime de
  trabalho:" — valores em B7, B8, B9.
- Aulas: cabeçalho na linha 12; dados a partir da 15: A Disciplina, B Tipo,
  C aulas teóricas semanais por turma, D turmas teóricas, E aulas práticas
  por turma, F turmas práticas, I/K atendimento (horas/minutos), P/R
  preparação (horas/minutos).
- Projetos de ensino, Pesquisa, Extensão: cabeçalho na linha 10; dados a
  partir da 12: A descrição, B horas, D minutos.
- Orientações: cabeçalho linha 10; dados da 12: A tipo, B especificação,
  C quantidade, D horas, F minutos.
- Gestão: cabeçalho linha 11; dados da 13: A tipo, C especificação, D horas,
  F minutos.
- Outras: cabeçalho linha 12; dados da 14: A atividade, D horas, F minutos.
- Afastamentos: cabeçalho linha 11; dados da 13: A tipo, B início, D fim,
  E horas, G minutos.
- Remuneradas: cabeçalho linha 7; dados da 8: A atividade, B local, C horários.
- Observações: texto em A5.
Não há modelo gerado pelo agente: a planilha é o arquivo oficial da UFU.
Para preencher, edite os valores guardados no banco e use "Salvar e preencher
planilha".

## Banco
Chave: `gestor_ufu_planos_trabalho_v1` — lista de { id, nome, numero,
nomeArvore, interessado, pdfPath (caminho local; não altere),
spreadsheetData: { version: 1, origin: nome do arquivo, fields: [ { section,
sheet, cell (ex. "B7"), label, type ("texto"|"numero"|"data"), value } ],
ignoredFormulas: [...] } | null }.
Para mudar um valor, altere `value` do campo (section + cell) com patch_json.

## Comandos (run_command)
planosTrabalho.listar, planosTrabalho.salvarCadastro, planosTrabalho.remover
(pede confirmação), planosTrabalho.importarPlanilha, planosTrabalho.definirCampo,
planosTrabalho.preencherPlanilha, planosTrabalho.abrirSei e
planosTrabalho.inserirNoSei (pede confirmação).
Prefira os comandos às gravações diretas no banco: eles aplicam as mesmas
regras da tela.
''',
);
