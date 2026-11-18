import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo Audita Bancas entregue ao Agente de IA.
ModuleSkill auditaBancasSkill() => const ModuleSkill(
  title: 'Audita Bancas',
  summary:
      'Revisão assistida de TCCs, dissertações e teses em PDF, com '
      'critérios da banca, observações ancoradas e PDF anotado.',
  body: '''
## Para que serve
Na tela (`/audita-bancas`), o usuário abre o PDF de um TCC, dissertação ou
tese (o Gestor guarda uma cópia; o original não muda), informa critérios,
rubrica ou normas da banca e clica em "Analisar com IA". Cada observação fica
ancorada num trecho do PDF, com o problema, por que importa e como melhorar;
o painel de observações leva o PDF até o trecho. O usuário aceita, rejeita,
edita ou cria observações num trecho selecionado. As aceitas vão para o PDF
anotado; há também um relatório em texto.

## Comandos
- `auditaBancas.listar`; `auditaBancas.abrirPdf` {caminho}.
- `auditaBancas.analisar` {documento, criterios?}: envia o texto ao modelo
  (exige aprovação). Use só os critérios fornecidos; não invente normas.
- `auditaBancas.observacoes` {documento}.
- `auditaBancas.revisar` {documento, observacao, revisao: pendente|aceita|
  rejeitada}; `auditaBancas.editarObservacao` {documento, observacao,
  problema?, importancia?, melhoria?, categoria?};
  `auditaBancas.excluirObservacao` {documento, observacao}.
- `auditaBancas.exportarRelatorio` {documento, caminho?};
  `auditaBancas.exportarPdf` {documento, caminho?} (só as aceitas).

Escreva observações em frases completas, para o autor do trabalho: qual é o
problema, por que importa e o que fazer.

Códigos de erro: arquivo_nao_encontrado, formato_nao_suportado,
documento_inexistente, observacao_inexistente, ia_indisponivel, sem_texto,
leitura_falhou, limite, sem_aceitas, exportacao_falhou.

## Limitações
PDFs digitalizados (sem camada de texto) não podem ser analisados (sem OCR).
A exportação do PDF anotado usa o Poppler (pdftotext e pdftoppm), que vem
no instalador do Gestor; o PDF exportado é rasterizado.

## Banco
`audita_bancas.v1.documento.<id>`: documento e observações.
''',
);
