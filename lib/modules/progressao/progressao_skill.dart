import 'package:gestor_ufu/modules/progressao/domain/resolucao_condir_03_2017.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia da Progressão / Promoção entregue ao Agente de IA, com o catálogo
/// do Anexo 1 gerado do próprio domínio.
ModuleSkill progressaoSkill() => ModuleSkill(
  title: 'Progressão / Promoção',
  summary: 'Processo de progressão docente (Anexo 1, Res. 03/2017 CONDIR).',
  body:
      '''
## Para que serve
Monta o processo de progressão/promoção docente: dados do requerimento,
lançamentos de atividades pontuadas pelo Anexo 1 da Resolução 03/2017 do
CONDIR (com as alterações da Res. 05/2018), comprovantes organizados em
pastas, PDF final e envio dos comprovantes ao SEI.

## Onde fica cada ação (tela Progressão / Promoção)
- Lista de processos: "Novo processo", "Duplicar", "Excluir processo".
- No processo: docente, SIAPE, lotação, destinatário, cidade, carreira,
  regime, titulação, posição alvo, interstício e período do relatório ("Fim =
  início + 24 meses"), textos de assiduidade/avaliação didática/conclusão,
  "Escolher logotipo" (PNG/JPG do cabeçalho do PDF).
- Lançamentos: "Adicionar item" / "Escolher item do Anexo 1", "Linha",
  quantidade, período, início/fim, descrição; comprovante (PDF/JPG/PNG) é
  copiado e renomeado para a pasta do processo ("Abrir pasta", "Atualizar
  nomes dos arquivos", "Abrir comprovante", "Remover comprovante").
- "Gerar PDF" (relatório com pontuação) e "Enviar comprovantes ao SEI".
O app calcula a pontuação; você ajuda a escolher o item certo, a quantidade
(horas, meses, alunos, trabalhos, dias…) e a descrição a partir dos
comprovantes que o usuário anexar.

## Banco
Chave: `progressao_docente.v1` — lista de processos: { id, docente, siape,
lotacao, destinatario, cidade, dataDocumento (ISO), carreira
("magisterioSuperior"|"ebtt"), regime ("de"|"h40"|"h20"), titulacao
("graduacao"|"mestrado"|"doutorado"), alvoId ("<carreira>|<classe>|<nivel>"),
intersticioInicio/Fim, relatorioInicio/Fim (ISO), semestres,
textoAssiduidade, textoAvaliacaoDidatica, avaliacoesDidaticas [texto],
textoAvaliacaoConclusao, logoPath, pastaComprovantes, tipoDocumentoSei,
lancamentos: [ { id, item (número do Anexo 1), periodo (ex. "2023/01"),
descricao, comprovante (caminho relativo à pasta, ex.
"A1.1_Ensino/arquivo.pdf", ou texto), quantidade (número), inicio/fim (ISO
ou null) } ], atualizadoEm }.
Use SOMENTE números de item do catálogo abaixo. Não apague comprovantes nem
altere `pastaComprovantes`/`logoPath` (caminhos locais).

## Catálogo do Anexo 1 (item: descrição — regra de pontuação)
${_anexo1()}

## Diagnóstico assistido da automação do SEI
- Para investigar o fluxo de criação do processo, inicie um fluxo retomável com
  `workflow_start` (módulo `progressao`) e registre cada passo com
  `workflow_checkpoint`. Inspecione a tela antes e depois das ações usando as
  ferramentas de navegador/computador; registre os rótulos, resultado e erro.
- Se depender de login, seleção de unidade ou outra ação manual, registre com
  `workflow_request_user`, pergunte na conversa e retome somente após a resposta.
- Não repita a mesma abordagem mais de duas vezes. Se não resolver, conclua com
  `workflow_finish` usando `handoff` e entregue o relatório Markdown gerado para
  correção do código.
- Na interface, ao criar processo novo, aguarde o login e a unidade no SEI; só
  prossiga depois do clique do usuário em **Criar processo e montar dossiê**.

## Comandos (run_command)
progressao.listar, progressao.itensAnexo1 (busca no catálogo), progressao.criar,
progressao.lancar, progressao.removerLancamento, progressao.anexarComprovante,
progressao.gerarPdf, progressao.duplicar, progressao.excluir (pede
confirmação), progressao.abrirSei, progressao.enviarComprovantesSei e
progressao.montarProcessoSei (pedem confirmação). Prefira os comandos às
gravações diretas no banco.
''',
);

String _anexo1() {
  final buffer = StringBuffer();
  TabelaAnexo1? tabela;
  for (final item in anexo1) {
    if (item.tabela != tabela) {
      tabela = item.tabela;
      buffer.writeln(
        '\n### ${tabela.codigo} ${tabela.titulo} (${tabela.faixa})',
      );
    }
    var descricao = item.descricao.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (descricao.length > 170) {
      descricao = '${descricao.substring(0, 170)}…';
    }
    buffer.writeln('- ${item.numero}: $descricao — ${item.regra}');
  }
  return buffer.toString();
}

/// Skills que ainda não migraram para o seu módulo.
