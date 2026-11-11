import 'package:gestor_ufu/domain/entities/progressao.dart';
import 'package:gestor_ufu/domain/progressao/resolucao_condir_03_2017.dart';

/// Limite do campo "Nome na Árvore" do SEI.
const limiteNomeArvoreSei = 50;

/// Extensões aceitas como comprovante (todas aceitas pelo SEI como documento
/// externo).
const extensoesComprovante = ['pdf', 'jpg', 'jpeg', 'png'];

const _semAcento = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', //
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c', 'ñ': 'n',
};

String removerAcentos(String valor) {
  final out = StringBuffer();
  for (final ch in valor.split('')) {
    final lower = ch.toLowerCase();
    final troca = _semAcento[lower];
    if (troca == null) {
      out.write(ch);
    } else {
      out.write(ch == lower ? troca : troca.toUpperCase());
    }
  }
  return out.toString();
}

/// Trecho seguro para nome de arquivo: ASCII, palavras unidas por "_".
String slugComprovante(String valor) => removerAcentos(valor)
    .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');

/// Subpasta de cada tabela do Anexo 1 (ex.: `A1.1_Ensino`).
String subpastaTabela(TabelaAnexo1 tabela) => switch (tabela) {
  TabelaAnexo1.ensino => 'A1.1_Ensino',
  TabelaAnexo1.orientacao => 'A1.2_Orientacao',
  TabelaAnexo1.producao => 'A1.3_Producao',
  TabelaAnexo1.semRemuneracao => 'A1.4_Sem_remuneracao',
  TabelaAnexo1.comRemuneracao => 'A1.5_Com_remuneracao',
  TabelaAnexo1.gestao => 'A1.6_Gestao',
  TabelaAnexo1.licencas => 'A1.7_Licencas',
};

/// Corta em [limite] caracteres sem deixar palavra pela metade, quando possível.
String _truncar(String nome, int limite) {
  if (nome.length <= limite) return nome;
  var trecho = nome.substring(0, limite);
  final corte = trecho.lastIndexOf('_');
  if (nome[limite] != '_' && corte > limite ~/ 2) {
    trecho = trecho.substring(0, corte);
  }
  return trecho.replaceAll(RegExp(r'_+$'), '');
}

/// Nome (sem extensão) do comprovante do lançamento. É também o "Nome na
/// Árvore" usado no SEI, por isso cabe em [limiteNomeArvoreSei] caracteres:
/// `A1.1_It001-02_2023-1_Instrumentacao_Industrial_I`.
///
/// [ordem] é a posição (1, 2, ...) do lançamento entre as linhas do item.
String nomeBaseComprovante(
  LancamentoProgressao l,
  int ordem, {
  int sufixo = 1,
}) {
  final tabela = TabelaAnexo1.doItem(l.item);
  final partes = [
    tabela.codigo,
    'It${l.item.toString().padLeft(3, '0')}-${ordem.toString().padLeft(2, '0')}',
    // 2023/01 -> 2023-1
    removerAcentos(l.periodo.trim())
        .replaceAll('/0', '/')
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), ''),
    slugComprovante(
      l.descricao.trim().isEmpty
          ? (itemAnexo1(l.item)?.descricao ?? '')
          : l.descricao,
    ),
  ].where((e) => e.isNotEmpty);
  final extra = sufixo > 1 ? '_$sufixo' : '';
  return _truncar(partes.join('_'), limiteNomeArvoreSei - extra.length) + extra;
}

/// Caminho relativo (com `/`) dentro da pasta de comprovantes do processo.
String caminhoRelativoComprovante(
  LancamentoProgressao l,
  int ordem,
  String extensao, {
  int sufixo = 1,
}) {
  final ext = extensao.toLowerCase().replaceFirst('.', '');
  return '${subpastaTabela(TabelaAnexo1.doItem(l.item))}/'
      '${nomeBaseComprovante(l, ordem, sufixo: sufixo)}.$ext';
}

/// Posição (1, 2, ...) do lançamento entre as linhas do mesmo item.
int ordemNoItem(ProgressaoDocente p, LancamentoProgressao l) {
  final i = p.lancamentosDoItem(l.item).indexWhere((e) => e.id == l.id);
  return i < 0 ? p.lancamentosDoItem(l.item).length + 1 : i + 1;
}

/// Lançamentos com comprovante, na ordem do relatório (tabela, item, linha) —
/// a mesma ordem em que são enviados ao SEI.
List<LancamentoProgressao> lancamentosComComprovante(ProgressaoDocente p) => [
  for (final numero in p.itensUsados())
    for (final l in p.lancamentosDoItem(numero))
      if (l.comprovanteArquivado) l,
];
