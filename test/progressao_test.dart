import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/data/services/progressao_pdf_service.dart';
import 'package:gestor_ufu/domain/entities/progressao.dart';
import 'package:gestor_ufu/domain/progressao/resolucao_condir_03_2017.dart';

ProgressaoDocente exemploModelo() {
  var seq = 0;
  LancamentoProgressao l(
    int item,
    double qtd, {
    String periodo = '',
    String descricao = '',
    String comprovante = '',
  }) => LancamentoProgressao(
    id: '${seq++}',
    item: item,
    quantidade: qtd,
    periodo: periodo,
    descricao: descricao,
    comprovante: comprovante,
  );
  final aulas = <double>[1, 1, 6, 1, 4, 72, 18, 18, 72, 15, 72, 18, 18, 72];
  aulas.addAll([72, 18, 18, 72, 72, 18, 18, 72]);
  return ProgressaoDocente(
    id: 'x',
    docente: 'Josué Silva de Morais',
    siape: '1839411',
    lotacao: 'Faculdade de Engenharia Elétrica',
    destinatario:
        'Diretor da Faculdade de Engenharia Elétrica Prof. Dr. Sérgio Ferreira de Paula Silva',
    dataDocumento: DateTime(2024, 11, 30),
    alvoId: 'magisterioSuperior|D|III',
    intersticioInicio: DateTime(2023, 1, 26),
    intersticioFim: DateTime(2025, 1, 25),
    relatorioInicio: DateTime(2023, 1, 26),
    relatorioFim: DateTime(2024, 11, 30),
    semestres: '2022/01 parcial; 2022/02; 2023/01; 2023/02; 2024/01',
    avaliacoesDidaticas: const [
      '2023/01 – FEELT32602 – Instrumentação Industrial II (2023-1_FEELT32602_Avaliacao1.pdf)',
    ],
    lancamentos: [
      for (final (i, a) in aulas.indexed)
        l(
          1,
          a,
          periodo: '2023/01',
          descricao: 'Instrumentação Industrial I – A$i',
          comprovante: '2023-1_ININDI_A$i.pdf',
        ),
      for (var i = 0; i < 7; i++)
        l(14, 4, periodo: '2023/01', descricao: 'Aluno $i – TCC'),
      l(15, 22, descricao: 'Coordenação de Iniciação em Extensão com Bolsa'),
      l(43, 1, descricao: 'Melhores do Ano de 2022 da Receita Federal'),
      l(76, 11, descricao: 'Bancas de TCC'),
      l(91, 11, descricao: 'Coordenação de projeto'),
      l(92, 22, descricao: 'Membro do projeto CNPq'),
      l(93, 22, descricao: 'Programa Além do Horizonte'),
      l(93, 12, descricao: 'Projetos de engenharia civil'),
      l(137, 22, descricao: 'Coordenação de Estágio Supervisionado'),
      l(149, 7, descricao: 'Comissão do Congrad'),
      l(153, 5, descricao: 'Comissão de Estágio Probatório'),
      l(154, 5, descricao: 'Colegiado do curso'),
      l(155, 22, descricao: 'NDE'),
    ],
  );
}

void main() {
  test('catálogo cobre os 167 itens do Anexo 1 em ordem', () {
    expect(anexo1.length, 167);
    for (var i = 0; i < anexo1.length; i++) {
      expect(anexo1[i].numero, i + 1);
    }
    // Alterações da Resolução SEI 05/2018.
    expect(itemAnexo1(147)!.pontos, 15);
    expect(itemAnexo1(150)!.pontos, 10);
  });

  test('pontuação de referência dos Anexos 2 e 3', () {
    PosicaoCarreira pos(String id) => posicaoPorId(id)!;
    expect(
      pontuacaoReferencia(
        alvo: pos('magisterioSuperior|D|III'),
        regime: Regime.de,
        titulacao: Titulacao.doutorado,
      ),
      920,
    );
    expect(
      pontuacaoReferencia(
        alvo: pos('magisterioSuperior|C|II'),
        regime: Regime.h20,
        titulacao: Titulacao.mestrado,
      ),
      330,
    );
    expect(
      pontuacaoReferencia(
        alvo: pos('ebtt|D IV|3'),
        regime: Regime.de,
        titulacao: Titulacao.mestrado,
      ),
      840,
    );
    expect(
      pontuacaoReferencia(
        alvo: pos('magisterioSuperior|E|'),
        regime: Regime.h40,
        titulacao: Titulacao.doutorado,
      ),
      1000,
    );
    expect(posicaoAnterior(pos('magisterioSuperior|D|I'))!.classe, 'C');
  });

  test('reproduz o total do relatório modelo (1281 pontos)', () {
    final p = exemploModelo();
    expect(p.referencia, 920);
    expect(p.promocao, isFalse);
    expect(p.totalTabela(TabelaAnexo1.ensino), 748);
    expect(p.totalTabela(TabelaAnexo1.orientacao), 50);
    expect(p.totalTabela(TabelaAnexo1.producao), 74);
    expect(p.totalTabela(TabelaAnexo1.semRemuneracao), 111);
    expect(p.totalTabela(TabelaAnexo1.gestao), 298);
    expect(p.total, 1281);
    expect(p.atingeReferencia, isTrue);
  });

  test('aplica teto do item e fração da referência por dia', () {
    final p = ProgressaoDocente(
      id: 'y',
      alvoId: 'magisterioSuperior|D|I',
      lancamentos: const [
        LancamentoProgressao(id: '1', item: 14, quantidade: 200),
        LancamentoProgressao(id: '2', item: 116, quantidade: 550),
      ],
    );
    expect(p.pontosItem(14), 160);
    expect(p.pontosItem(116), closeTo(550 * 840 / 1000, 1e-9));
  });

  test('meses completos e dias entre datas', () {
    expect(mesesCompletos(DateTime(2023, 1, 26), DateTime(2024, 11, 30)), 22);
    expect(mesesCompletos(DateTime(2023, 6, 1), DateTime(2023, 11, 30)), 6);
    expect(mesesCompletos(DateTime(2023, 1, 26), DateTime(2023, 5, 31)), 4);
    expect(mesesCompletos(DateTime(2023, 1, 26), DateTime(2023, 12, 30)), 11);
    expect(diasEntre(DateTime(2017, 1, 21), DateTime(2017, 3, 14)), 52);
  });

  test('serialização preserva os dados', () {
    final p = exemploModelo();
    final copy = ProgressaoDocente.fromJson(p.toJson());
    expect(copy.total, p.total);
    expect(copy.lancamentos.length, p.lancamentos.length);
    expect(copy.alvoId, p.alvoId);
  });

  test('gera o PDF do requerimento e relatório', () async {
    final bytes = await ProgressaoPdfService().gerar(exemploModelo());
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final out = Platform.environment['PROGRESSAO_PDF_OUT'];
    if (out != null && out.isNotEmpty) {
      await File(out).writeAsBytes(bytes);
    }
  });
}
