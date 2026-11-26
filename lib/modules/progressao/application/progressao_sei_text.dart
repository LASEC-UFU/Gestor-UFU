import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/modules/progressao/domain/resolucao_condir_03_2017.dart';

String especificacaoProcessoSei(ProgressaoDocente p) {
  final anterior = p.atual;
  String curta(PosicaoCarreira? posicao) {
    if (posicao == null) return '';
    final nivel = switch (posicao.nivel) {
      'I' => '1',
      'II' => '2',
      'III' => '3',
      'IV' => '4',
      _ => posicao.nivel,
    };
    return '${posicao.classe.replaceAll(' ', '')}$nivel';
  }

  final sigla = siglaUnidade(p.lotacao);
  final movimento = '${curta(anterior)} - ${curta(p.alvo)}';
  final inicio = p.intersticioInicio;
  final data = inicio == null
      ? ''
      : '${inicio.day.toString().padLeft(2, '0')}/${inicio.month.toString().padLeft(2, '0')}';
  return [p.docente.trim().toUpperCase(), sigla, movimento, data]
      .where((e) => e.isNotEmpty)
      .join(' ')
      .substring(
        0,
        [
                  p.docente.trim().toUpperCase(),
                  sigla,
                  movimento,
                  data,
                ].where((e) => e.isNotEmpty).join(' ').length >
                100
            ? 100
            : [
                p.docente.trim().toUpperCase(),
                sigla,
                movimento,
                data,
              ].where((e) => e.isNotEmpty).join(' ').length,
      );
}

String siglaUnidade(String lotacao) {
  final normalized = lotacao.toLowerCase();
  if (normalized.contains('engenharia el')) return 'FEELT';
  final ignorar = {'de', 'da', 'do', 'das', 'dos', 'e'};
  final iniciais = lotacao
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && !ignorar.contains(w.toLowerCase()))
      .map((w) => w.substring(0, 1).toUpperCase())
      .join();
  return iniciais;
}

String descricaoRequerimentoSei(ProgressaoDocente p) {
  final origem = p.atual?.descricaoClasseNivel ?? 'classe inicial';
  final alvo = p.promocao
      ? p.alvo.descricaoClasseNivel
      : 'nível ${p.alvo.nivel}';
  return '${p.tipoMovimento[0].toUpperCase()}${p.tipoMovimento.substring(1)} '
      'da $origem para $alvo - ${p.docente.trim()}';
}

String ultimaProgressaoDescricao(ProgressaoDocente p) =>
    p.atual?.descricaoClasseNivel ?? '';

String formatarDataSei(DateTime? data) {
  if (data == null) return '';
  return '${data.day.toString().padLeft(2, '0')}/'
      '${data.month.toString().padLeft(2, '0')}/${data.year}';
}

String dataPorExtensoSei(ProgressaoDocente p, DateTime? data) {
  if (data == null) return '';
  const meses = [
    'Janeiro',
    'Fevereiro',
    'Março',
    'Abril',
    'Maio',
    'Junho',
    'Julho',
    'Agosto',
    'Setembro',
    'Outubro',
    'Novembro',
    'Dezembro',
  ];
  return '${p.cidade.trim()} dia ${data.day} de ${meses[data.month - 1]} de ${data.year}';
}

String formatarPontuacaoSei(double valor) {
  final inteiro = valor.roundToDouble() == valor;
  final texto = inteiro ? valor.toStringAsFixed(0) : valor.toStringAsFixed(2);
  return texto.replaceAll('.', ',');
}

String tipoProcessoSugeridoSei(ProgressaoDocente p) =>
    'Pessoal: ${p.promocao ? 'Promoção' : 'Progressão'} Docente';
