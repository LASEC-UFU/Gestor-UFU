import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_sei_text.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';

void main() {
  final processo = ProgressaoDocente(
    id: 'teste',
    docente: 'Josué Silva de Morais',
    lotacao: 'Faculdade de Engenharia Elétrica',
    alvoId: 'magisterioSuperior|D|IV',
    intersticioInicio: DateTime(2025, 1, 21),
    dataDocumento: DateTime(2026, 11, 26),
  );

  test(
    'gera especificação curta com sigla, movimento e início do interstício',
    () {
      expect(
        especificacaoProcessoSei(processo),
        'JOSUÉ SILVA DE MORAIS FEELT D3 - D4 21/01',
      );
      expect(
        tipoProcessoSugeridoSei(processo),
        'Pessoal: Progress\u00e3o Docente',
      );
      expect(
        tipoProcessoSugeridoSei(
          processo.copyWith(alvoId: 'magisterioSuperior|B|I'),
        ),
        'Pessoal: Promo\u00e7\u00e3o Docente',
      );
    },
  );

  test('gera descrição e posição anterior para o requerimento', () {
    expect(
      descricaoRequerimentoSei(processo),
      'Progressão da classe D nível III para nível IV - Josué Silva de Morais',
    );
    expect(ultimaProgressaoDescricao(processo), 'classe D nível III');
  });

  test('formata datas e pontuação no padrão do requerimento', () {
    expect(formatarDataSei(DateTime(2026, 11, 26)), '26/11/2026');
    expect(
      dataPorExtensoSei(processo, processo.dataDocumento),
      'Uberlândia dia 26 de Novembro de 2026',
    );
    expect(formatarPontuacaoSei(2087), '2087');
    expect(formatarPontuacaoSei(2087.02), '2087,02');
  });
}
