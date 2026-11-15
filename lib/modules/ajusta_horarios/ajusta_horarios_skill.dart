import 'package:gestor_ufu/modules/ajusta_horarios/domain/ajusta_horarios.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill ajustaHorariosSkill() => ModuleSkill(
  title: 'Ajusta Horários',
  summary: 'Grade semanal por curso, período, docente e sala.',
  body:
      '''
## Para que serve
Monta as grades semanais (segunda a sexta, 16 faixas de horário) das
disciplinas/turmas de cada período letivo, com visões por curso, docente e
sala, e controla a distribuição docente (cargas por turma).

## Onde fica cada ação (tela Ajusta Horários)
- Visões: "Grade por curso" (escolhe curso e período), "Grade por docente",
  "Grade por sala", e a aba "Distribuição Docente".
- Seletor de período letivo, "Novo período letivo" e "Períodos letivos".
- Disciplinas: "Nova disciplina" / "Adicionar disciplina ou copiar um
  modelo", "Editar disciplinas", "Nova turma", "Remover turma", "Remover
  disciplina inteira", "Copiar disciplina para outro semestre", "Optativas".
  Ao editar: modalidade (teórica, prática, EAD, extensão), turma (A1, B, U…),
  docentes, sala, cursos/períodos de oferta e clique nas faixas da grade;
  "Salvar disciplina e horários".
- Cadastros: "Editar cursos", "Editar docentes" (Novo docente), "Editar salas"
  (Nova sala).
- Exportar: "Exportar grade em CSV" (separador ;, UTF-8), "Exportar grade em
  PDF" e "Exportar grades por docente" (escolhe os períodos).
- "Importar base da planilha" (.xlsm/.xlsx) — ver abaixo.

## Importação de planilha
O app procura primeiro a aba "Banco"; se não houver, a aba "BDados".
1) Aba BDados (SUBSTITUI toda a base do período e limpa a distribuição):
   dados a partir da linha 3; colunas por posição:
   A ID (ignorado) | B Cursos/Períodos "período,curso;período,curso" |
   C Horários "faixa,dia;faixa,dia" onde dia = 2 (segunda) … 6 (sexta) e
   faixa = 1…16 | D Código | E Sigla | F Disciplina | G Turma |
   H Docentes (separados por vírgula) | I Sala | J CH teórica | K CH prática.
   Curso: 1…5 (veja a lista abaixo); período: 1…11.
2) Aba Banco (atualiza só a Distribuição Docente, mantém as grades):
   cabeçalho na linha 1 (nomes, ordem livre): Período | Sigla | Disciplina |
   Turma | Docente | Opção (Sigla Turma) | CH_T | CH_P | CH EAD | CH Extensão.
   Obrigatórios: Docente e Opção (Sigla Turma) ou Disciplina.
Modelos: `create_template("ajusta_horarios_bdados", rows: [...])` e
`create_template("ajusta_horarios_banco", rows: [...])`, cada linha na ordem
das colunas acima.

Cursos padrão (program): ${horarioProgramas.entries.map((e) => '${e.key} = ${e.value}').join('; ')}.
Dias (weekday no banco): 1 = segunda … 5 = sexta.
Faixas de horário (valor de `slot`, começa em 1):
${horarioFaixas.asMap().entries.map((e) => '  ${e.key + 1}: ${e.value}').join('\n')}

## Banco
Disciplinas/turmas: ${termScopedSkillNote('ajusta_horarios_disciplinas_2026_2_ca_v2_')}
Valor: lista de HorarioDisciplina { id, subjectId (agrupa turmas da mesma
disciplina), modality ("theory"|"practice"|"ead"|"extension"|"legacy"),
code, acronym, name, className, teachers [nomes], room,
coursePeriods [{program, period}], slots [{weekday 1..5, slot 1..16}],
theoryHours, practiceHours, eadHours, extensionHours, … }.
Distribuição docente: ${termScopedSkillNote('ajusta_horarios_distribuicao_docente_')}
— lista de {teacher, discipline, period, theoryHours, practiceHours,
eadHours, extensionHours}.
Docentes e salas do período: prefixos `ajusta_horarios_docentes_cadastrados_`
e `ajusta_horarios_salas_cadastradas_` (listas de textos).
Cursos: `ajusta_horarios_cursos` ({"<program>": "nome"}).
Leia registros existentes antes de criar novos e siga o mesmo padrão.

## Comandos (run_command)
- `ajustaHorarios.listar` {term?, program+periods | teacher | room}: sem filtro, resumo do período (cursos, totais, docentes, salas); com filtro, as disciplinas com turma, docentes, sala e horários.
- `ajustaHorarios.distribuicao` {term?, teacher?}: distribuição docente (aba Banco).
- `ajustaHorarios.importarPlanilha` {path, term?} (pede confirmação): aba Banco → distribuição docente; aba BDados → SUBSTITUI a base do período. Gere o arquivo antes com `create_template`.
- `ajustaHorarios.exportarGradeCsv` {term?, program+periods | teacher | room, path?}: grade semanal em CSV.
O PDF colorido da grade é gerado pela tela ("Exportar PDF"); navegue até `/ajusta-horarios` e oriente o usuário.
Códigos de erro: periodo_nao_encontrado, filtro_invalido, planilha_invalida, arquivo_nao_encontrado.

Prefira os comandos às gravações diretas no banco: eles aplicam as mesmas
regras da tela.
''',
);
