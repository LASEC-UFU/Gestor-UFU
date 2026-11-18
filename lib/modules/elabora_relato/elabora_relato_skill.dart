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

## Processos
A tela abre numa lista de processos (como a Progressão). Cada processo tem
o seu rascunho do parecer, comentários, inventário da árvore e pasta da
base de documentos.
- `parecer.processos.listar`: processos (id, nome, número SEI, assunto…)
  e qual está aberto.
- `parecer.processos.abrir` {id}; `parecer.processos.criar` {nome,
  numeroSei?, copiarDe?} (copiarDe = id de um processo a copiar).
Os demais comandos agem no processo aberto (sem nenhum aberto, no mais
recente) e aceitam `processo` (id) para escolher outro. Confirme com o
usuário em qual processo trabalhar quando houver mais de um.

## Documentos do processo (leitura e marcação)
Aba "Documentos do processo": o relator anexa arquivos (PDF com texto,
DOCX, TXT/MD, HTML) só para ler; marca trechos com cores, pergunta à IA o
que dizem e guarda comentários. O texto não é editado. PDFs abrem na
visão "PDF original" (pdf.js, como no arquivo, com as marcações por
cima) ou na visão "Texto"; cada marcação guarda a página do PDF e o
parágrafo do texto (`parecer.anexos.listar` mostra os dois).
- `parecer.anexos.listar`; `parecer.anexos.ler` {anexo, inicio?,
  quantidade?} (parágrafos numerados com página);
  `parecer.anexos.marcar` {anexo, paragrafo, trecho literal,
  comentario?, cor?}.
Ao explicar um trecho, use só o documento e as fontes da base; cite o
documento e a página/parágrafo.

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
- `parecer.verificar`: pendências antes do SEI (comentários "para
  revisão", artigos citados que não estão na base, campos vazios). Mostre
  ao usuário antes de inserir.
- `parecer.inserirSei`: só após confirmação do usuário. Gera o documento
  "Parecer" no processo aberto (ou preenche o editor de Parecer aberto) e
  salva sem assinar. O botão "Inserir no SEI" fica no cabeçalho do módulo.

## Comentários, rastreabilidade e simulado
Os comentários ficam no rascunho, fora do HTML enviado ao SEI. Escreva cada
um para quem vai lê-lo: `texto` = o ponto que precisa de atenção (frase
completa), `importancia` = por que merece revisão, `sugestao` = o que fazer
para melhorar; nada de rótulos soltos. O trecho já aparece destacado no
documento: não o repita no texto. Na tela, o painel de comentários (comum
aos documentos HTML e PDF) leva o documento até o trecho de cada comentário.
Ao aceitar
uma proposta da IA baseada em fontes, o Gestor cria um comentário
"rastreabilidade" com arquivo, localização e trecho de cada fonte. A
análise da seção guarda `pergunta_arguicao` e `resposta_oral`, usadas no
"Simulado de arguição" (barra da seção).
- `parecer.comentarios.listar` {secao?}; `parecer.comentarios.adicionar`
  {secao, trecho, texto, categoria?, status?, referencia?,
  citacao_literal?, explicacao_simples?, importancia?, pergunta_arguicao?,
  resposta_oral?, contra_argumento?}; `parecer.comentarios.excluir` {id}.

## OBRIGATÓRIO: anotações de defesa do voto
Sempre que você redigir ou reescrever uma seção do parecer
(`parecer.definir` com relatorio, fundamentacao ou conclusao), anote a
seção em seguida, na mesma tarefa, sem esperar o usuário pedir. O relator
será interpelado em plenário e precisa ter, em cada ponto do texto, a
defesa pronta. Não entregue o parecer sem essas anotações.
1. Releia a seção (`parecer.ler`) e escolha os pontos que podem ser
   contestados: cada afirmação de fato (datas, votações, documentos),
   cada norma citada, cada conclusão jurídica, cada pedido acolhido ou
   negado e cada item do voto. Em geral, de 4 a 10 por seção. A
   conclusão deve ter uma anotação para cada item do voto.
2. Para cada ponto, chame `parecer.comentarios.adicionar` com
   `categoria: "defesa"` e:
   - `trecho`: cópia literal de uma frase curta da seção (o texto visível,
     sem tags e sem quebra de linha); se falhar com trecho_nao_encontrado,
     use um pedaço menor da mesma frase;
   - `texto`: o que o trecho afirma e por que se sustenta (2 a 4 frases);
   - `referencia` e `citacao_literal`: a fonte exata (arquivo da base,
     artigo, página ou ata), conferida com `parecer.base.buscar`; a citação
     é copiada da fonte, nunca reescrita;
   - `explicacao_simples`: o argumento em linguagem de conversa;
   - `pergunta_arguicao`: a objeção mais provável de quem discorda (use os
     argumentos da parte contrária, do recurso ou das atas);
   - `resposta_oral`: resposta de até 3 frases para falar em plenário;
   - `contra_argumento`: o que dizer se a pessoa insistir, incluindo o
     ponto fraco honesto do argumento, quando houver;
   - `status`: `confirmado` se o fato foi conferido na base; `revisar` se
     veio só do usuário ou de documento que não está na base (diga isso no
     `texto`). Nunca invente norma, artigo, número, data ou placar.
3. Ao terminar, diga ao usuário quantas anotações criou por seção e quais
   ficaram "para revisão". Lembre que elas aparecem no editor (trecho
   destacado; clique para ver tudo) e no "Simulado de arguição".
Ao alterar uma seção já anotada, liste os comentários: exclua os que não
se aplicam mais e crie os que faltam.

## Base de documentos de consulta
O relator escolhe uma pasta com normas, resoluções e anexos. O Gestor
grava nela `base_consulta.gestor.json` (trechos com arquivo, página,
artigo, seção e parágrafo) sem alterar os originais e só reprocessa
arquivos novos/alterados. A pasta é vigiada: a base se atualiza sozinha
alguns segundos depois de arquivos serem adicionados, alterados ou
removidos (e é conferida de novo antes de cada consulta).
- `parecer.base.preparar` {pasta?, forcar?}: prepara/atualiza a base.
- `parecer.base.buscar` {consulta, limite?}: trechos relevantes (base +
  documentos lidos da árvore do SEI). Ao fundamentar, cite o arquivo
  original e a localização devolvidos; se nada for encontrado, diga isso.
PDFs digitalizados (sem camada de texto) ficam marcados "requer_ocr": o
Gestor não faz OCR.
No editor, o usuário consulta a IA sobre um trecho com o botão direito;
as propostas só entram no texto quando ele clica em "Aceitar".

Códigos de erro: base_sem_pasta, consulta_vazia, endereco_invalido, sei_fechado, fora_do_sei, arvore_vazia,
em_andamento, sem_extracao, ia_indisponivel, documento_inexistente,
falha_sei, tempo_esgotado, trecho_nao_encontrado, secao_invalida,
comentario_inexistente.

## Banco
Por processo (`<id>`): `parecer_processo.<id>` (nome, número SEI, datas),
`parecer_relato_rascunho.<id>` (rascunho e comentários),
`parecer_relato_inventario.<id>` (inventário da árvore) e
`parecer_base_documentos_pasta.<id>` (pasta da base). Gerais:
`sei_tree_address_url` (endereço do SEI) e `parecer_relato_estilos_sei`
(estilos do editor do SEI). As chaves sem `.<id>` são do rascunho único
anterior, migrado para o processo `migrado`.
''',
);
