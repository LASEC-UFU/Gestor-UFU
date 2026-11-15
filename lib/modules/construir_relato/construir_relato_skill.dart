import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo entregue ao Agente de IA.
ModuleSkill construirRelatoSkill() => const ModuleSkill(
  title: 'Construir Relato',
  summary: 'Relatos de processos do SEI (árvore de documentos e inventário).',
  body: '''
## Para que serve
Reúne ferramentas para montar o relato de um processo do SEI (ex.: para um
parecer). Hoje tem uma funcionalidade; outras virão.

## Funcionalidade: Extrair árvore de processo
Lê a árvore de um processo aberto no SEI (no Edge controlado pelo app) e
monta o inventário dos documentos: ordem, nome na árvore, tipo/número,
código SEI, data e resumo.

Comandos (run_command):
1. `relato.abrirSei` {url?}: abre o Edge no SEI. O usuário faz o login e
   abre o processo; espere ele confirmar.
2. `relato.extrairArvore` {lerConteudo?}: lê a árvore (abre todas as
   pastas). Com lerConteudo (padrão) busca o texto de cada documento para
   estimar a data (assinatura eletrônica, data por extenso ou numérica) e o
   resumo (linha "Assunto:"/"Objeto:" ou primeiro parágrafo). PDFs externos
   ficam sem data/resumo. Avise que esses campos precisam de revisão.
3. `relato.relatorioArvore` {path?}: texto no formato para parecer
   ("1. Ofício 12 (1234567), de 03/03/2025 – resumo"); com path salva .txt
   (padrão Documentos/GestorUFU Agente/construir_relato).

Códigos de erro: endereco_invalido, sei_fechado (Edge não aberto pelo app),
fora_do_sei (aba saiu do SEI), arvore_vazia (nenhum processo aberto),
em_andamento, sem_extracao.

Na tela (`/construir-relato`, aba "Extrair árvore de processo"): "Abrir
Edge"/"Ir para o SEI", depois "Extrair árvore"; "Copiar relatório" ou
"Exportar .txt".

## Banco
Só guarda o último endereço do SEI (`sei_tree_address_url`). Ajude o usuário
a interpretar e organizar o inventário (ex.: listar só os comprovantes,
conferir numeração, montar o texto do relato); só grave algo se ele pedir.
''',
);
