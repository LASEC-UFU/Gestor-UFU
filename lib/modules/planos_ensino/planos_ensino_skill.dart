import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill planosEnsinoSkill() => ModuleSkill(
  title: 'Planos de Ensino',
  summary: 'Formulário do plano de ensino, Word, cronograma e SEI.',
  body: '''
## Para que serve
Cadastra os planos de ensino no formato da UFU, gera o .docx e insere o plano
no SEI (pelo Edge controlado pelo app).

## Onde fica cada ação (tela Planos de Ensino)
- "Novo formulário", "Editar plano", "Remover plano".
- "Importar Word" (.docx), "Exportar Word (.docx)".
- "Importar backup" / "Exportar backup" (JSON com todos os planos).
- No formulário: "Extrair do Config Moodle" (preenche os cronogramas a partir
  de uma configuração do Config Moodle; pergunta "Mesclar" ou "Substituir"),
  "Aplicar tabela colada" (cronograma colado do Excel), "Salvar no cadastro".
- "Inserir no SEI": abre o SEI no Edge (endereço configurável) e insere o
  plano; antes confere campos obrigatórios ("Plano incompleto").

## Importar Word (.docx)
Lê os títulos das seções (podem ter numeração "1." / "2)"): Ementa,
Justificativa, Objetivo geral, Objetivos específicos, Programa teórico,
Programa prático, Técnicas de ensino, Recursos didáticos, Recursos
audiovisuais, Avaliação, Calendário e distribuição de pontos, Horário de
atendimento, Atividade de recuperação, Atendimento especial, Cronograma
teórico, Cronograma prático, Bibliografia básica, Bibliografia complementar.
Cronogramas: linhas "DD/MM/AAAA<TAB>atividade". Identificação lida de tabelas
(rótulo | valor) ou de linhas "Rótulo: valor": Componente curricular, Código,
Unidade ofertante, Período/Série, Turma, Natureza, Professor(a), Ano/Semestre,
Carga horária teórica/prática/total, Observações.

## Aplicar tabela colada (cronograma)
Texto com colunas separadas por TAB (copiado do Excel), 1ª linha = cabeçalho
com "Data" e "Modalidade" obrigatórias; conteúdo em "Matéria Lecionada"
(ou "Matéria"/"Conteúdo") ou "Atividades" (várias separadas por | , cada uma
com prefixo T/P ou Teórica/Prática); "Descrição Moodle" opcional (o trecho a
partir de "Quanto às provas" vai para o calendário de avaliações).
Modelo: `create_template("plano_ensino_cronograma", rows: [...])`.

## Importar backup (JSON)
Lista de planos; cada plano é mesclado pelo `id`.
Modelo: `create_template("plano_ensino_json", data: [...])`.

## Campos obrigatórios (para inserir no SEI)
Componente curricular, Código, Unidade ofertante, Período/Série, Turma, cargas
teórica/prática/total, Professor(a), Ano/Semestre, Ementa, Justificativa,
Objetivo geral, Objetivos específicos, Programa teórico, Técnicas de ensino,
Recursos didáticos, Recursos audiovisuais, Avaliação, Calendário de
avaliações, Horário de atendimento, Atividade de recuperação, Atendimento
especial e Cronograma teórico (o prático quando houver carga prática).

## Banco
Chave: `gestor_ufu_planos_ensino_v1` — lista de planos:
{ id, updatedAt (ISO), identificacao: { nome, unidade_ofertante, codigo,
  periodo_serie, turma, carga_teorica, carga_pratica, carga_total, natureza
  ("Obrigatória"/"Optativa"), professor, ano_semestre, observacoes },
  ementa, justificativa, objetivo_geral, objetivos_especificos,
  programa_teorico, programa_pratico, metodologia_tecnicas,
  metodologia_recursos, metodologia_audiovisuais,
  cronograma_teorico [{data: "DD/MM/AAAA", atividade}], cronograma_pratico,
  avaliacao_geral, avaliacao_provas, horario_atendimento,
  atividade_recuperacao, atendimento_especial,
  bibliografia_basica [texto], bibliografia_complementar [texto] }
Textos são strings (podem ter quebras de linha). Atualize `updatedAt`.

## Comandos (run_command)
planosEnsino.listar, planosEnsino.salvar, planosEnsino.importarWord,
planosEnsino.exportarWord, planosEnsino.importarBackup, planosEnsino.exportarBackup,
planosEnsino.aplicarCronograma, planosEnsino.cronogramaDoMoodle,
planosEnsino.remover (pede confirmação), planosEnsino.abrirSei e
planosEnsino.inserirNoSei (pede confirmação).
Prefira os comandos às gravações diretas no banco: eles aplicam as mesmas
regras da tela.
''',
);
