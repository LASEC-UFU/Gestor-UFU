import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia da Equivalência de Alunos entregue ao Agente de IA.
const equivalenciaSkill = ModuleSkill(
  title: 'Equivalência de Alunos',
  summary: 'Aproveitamento de disciplinas entre currículos e certidão.',
  body: '''
## Para que serve
Registra os currículos (disciplinas e cargas) e as análises de transferência
de cada aluno: blocos que ligam disciplinas do currículo atual às cursadas no
currículo anterior, com situação e certidão de estudos em PDF.

## Onde fica cada ação (tela Equivalência de Alunos)
- "Currículos": cadastra currículos (curso + nome) e suas disciplinas —
  "Editar e importar disciplinas" (planilha), "Cadastrar disciplina
  manualmente", remover.
- "Nova análise" / "Importar planilha" (análise pronta); em cada análise:
  aluno, matrícula, currículo atual e anterior, situação (Em análise,
  Deferida, Indeferida), observações, "Adicionar bloco", "Agrupar com outro
  bloco", catálogo de disciplinas ("Aplicar catálogo"), "Salvar análise".
- "Imprimir certidão de estudos em PDF".

## Importar disciplinas do currículo (.xlsx/.xlsm)
Optativas, estágio, atividades complementares, equivalências automáticas e
linhas de total são ignoradas. Cabeçalho nas 30 primeiras linhas (qualquer aba, ordem livre). Reconhece:
código ("Código Disciplina", "Cód Disc", "Código Componente", "Código",
"Sigla"), nome ("Nome Disciplina", "Disciplina", "Componente") — obrigatório
—, "CH Teórica", "CH Prática", "CH Total", "Tipo"/"Natureza" e "Estrutura
Curricular". Modelo: `create_template("equivalencia_curriculo", rows: [...])`
(colunas: código, nome, CH T, CH P, CH total, tipo, estrutura).

## Importar análise (aba "Equivalencia")
A1 = nome do aluno, A2 = matrícula; dados a partir da linha 7:
A período | B código atual | C disciplina atual | D CH T | E CH P | (F) |
G Saldo | H código anterior | I disciplina anterior | J CH T | K CH P.
Linhas cuja coluna G está MESCLADA formam um bloco (várias disciplinas de um
lado ↔ do outro); linhas soltas viram blocos individuais. Exige um currículo
atual selecionado. Modelo: `create_template("equivalencia_analise", rows:
[...], options: {student, student_id, blocks: [[1,2]]})`.

## Banco
Chave: `student_equivalencies.blocks.v1` — { "curricula": [ { id, course,
name, subjects: [ {code, name, theoretical, practical} ] } ], "cases": [ {
id, student, studentId, currentCurriculumId, priorCurriculumId, status ("Em
análise"|"Deferida"|"Indeferida"), notes, blocks: [ { id, period, current:
[subject], prior: [subject] } ], currentCatalog: [subject], priorCatalog:
[subject] } ] }. Cargas (theoretical/practical) são inteiros (horas).

## Comandos (run_command)
equivalencia.listar, equivalencia.importarCurriculo, equivalencia.importarAnalise,
equivalencia.gerarCertidao e equivalencia.removerAnalise (pede confirmação).
Prefira os comandos às gravações diretas no banco: eles aplicam as mesmas
regras da tela.
''',
);
