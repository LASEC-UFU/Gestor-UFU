import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill elaboraRelatoSkill() => const ModuleSkill(
  title: 'Parecer / Relato',
  summary:
      'Pareceres no modelo "Parecer" do SEI: relatório (árvore do processo '
      'e resumos), fundamentação, conclusão e inserção no SEI.',
  body: '''
## Para que serve
Monta um parecer no estilo dos pareceres de conselho da UFU (ex.: Parecer
93/2026/CONGRAD) e o insere no SEI no tipo de documento "Parecer", como os
Planos de Ensino. A tela (`/elabora-relato`) tem três abas, cada uma com um
editor HTML igual ao do SEI (CKEditor 5 com os estilos do SEI):
- I. RELATÓRIO — etapa 1 "Extrair árvore" (inventário do processo) e etapa
  2 "Redigir relatório" (editor);
- II. FUNDAMENTAÇÃO E ANÁLISE;
- III. CONCLUSÃO ("CONSIDERANDO…" e o voto).
"Dados do parecer": assunto, ementa, vocativo, abertura, fecho e signatário.
PARECER Nº, PROCESSO Nº e INTERESSADO(S) são preenchidos pelo SEI.

## Etapa 1 do relatório: árvore do processo
1. `relato.abrirSei` {url?}: abre o Edge no SEI; o usuário entra e abre o
   processo. Espere ele confirmar.
2. `relato.extrairArvore` {lerConteudo?}: lê a árvore (ordem, nome, tipo/
   número, código SEI, id interno, data e resumo estimados).
3. Resumos: `relato.resumirComIa` {apenasVazios?} pede ao provedor
   configurado; ou escreva você mesmo lendo `relato.textoDocumento` {ordem}
   e gravando com `relato.atualizarResumos` {itens:[{ordem,resumo,data?}]}.
   Estilo do resumo: uma frase curta, minúscula, sem tipo/número/data e sem
   ponto final ("encaminhamento do processo pela SEGER à relatora
   solicitando apreciação, análise e parecer").
4. `parecer.inserirInventario` {porPastas?, introducao?}: insere no
   relatório "1. Ofício 12 (link SEI) – de 03 de março de 2025, resumo;".
`relato.relatorioArvore` {path?} devolve o inventário em texto.

## Redigir e inserir
- `parecer.ler` / `parecer.definir` (campos e HTML das seções relatorio,
  fundamentacao, conclusao). Use parágrafos `<p class="Texto_Justificado_
  Recuo_Primeira_Linha">`; links SEI `<a class="ancora_sei"
  id="lnkSei{id_documento}">{número SEI}</a>` (id interno ≠ número SEI).
- `parecer.inserirSei`: só após confirmação do usuário. Gera o documento
  "Parecer" no processo aberto (ou preenche o editor de Parecer aberto) e
  salva sem assinar.

Códigos de erro: endereco_invalido, sei_fechado, fora_do_sei, arvore_vazia,
em_andamento, sem_extracao, ia_indisponivel, documento_inexistente,
falha_sei, tempo_esgotado.

## Banco
`sei_tree_address_url` (endereço do SEI), `parecer_relato_inventario`
(último inventário), `parecer_relato_rascunho` (rascunho) e
`parecer_relato_estilos_sei` (estilos capturados do editor do SEI).
''',
);
