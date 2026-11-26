import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';

/// Texto como o pdf.js devolve (linhas quebradas, hifenização).
const _paginaPdf1 =
    'OFÍCIO Nº 12/2026/PROGRAD\n'
    'Encaminhamos a proposta de alteração do PPC do curso de Engenharia\n'
    'Mecânica, que inclui 10% da carga horária em atividades de exten-\n'
    'são, conforme a Resolução CONGRAD nº 46/2022.\n';
const _paginaPdf2 =
    'A proposta foi aprovada pelo Colegiado em 3 de março de 2026.\n'
    'A carga horária total permanece a mesma.\n';

/// Parágrafos como o pdftotext + segmentação do Gestor devolvem.
const _pars = [
  (texto: 'OFÍCIO Nº 12/2026/PROGRAD', pagina: 1, titulo: true),
  (
    texto:
        'Encaminhamos a proposta de alteração do PPC do curso de Engenharia '
        'Mecânica, que inclui 10% da carga horária em atividades de '
        'extensão, conforme a Resolução CONGRAD nº 46/2022.',
    pagina: 1,
    titulo: false,
  ),
  (
    texto: 'A proposta foi aprovada pelo Colegiado em 3 de março de 2026.',
    pagina: 2,
    titulo: false,
  ),
  (texto: 'A carga horária total permanece a mesma.', pagina: 2, titulo: false),
];

void main() {
  test('localizar trecho apesar de quebras, hífen, acentos e maiúsculas', () {
    final r = localizarTrecho('atividades de extensão, conforme', _paginaPdf1)!;
    expect(
      _paginaPdf1.substring(r.inicio, r.fim),
      'atividades de exten-\nsão, conforme',
    );
    expect(localizarTrecho('ENGENHARIA MECANICA', _paginaPdf1), isNotNull);
    expect(localizarTrecho('não existe aqui', _paginaPdf1), isNull);
    expect(localizarTrecho('   ', _paginaPdf1), isNull);
    // Várias ocorrências: a mais próxima de "perto".
    const t = 'carga horária ... texto ... carga horária';
    expect(localizarTrecho('carga horária', t, perto: 30)!.inicio, 28);
  });

  test('marcação feita no PDF ganha também a âncora da visão Texto', () {
    final ini = _paginaPdf1.indexOf('10% da carga');
    final m = AnexosProcessoService.novaMarcacaoPdf(
      pagina: 1,
      textoPagina: _paginaPdf1,
      inicio: ini,
      fim: ini + '10% da carga horária'.length,
      pars: _pars,
      cor: 'azul',
    );
    expect(m.pdfPagina, 1);
    expect(m.texto, '10% da carga horária');
    expect(m.paragrafo, 1);
    expect(_pars[1].texto.substring(m.inicio, m.fim), '10% da carga horária');
    expect(AnexosProcessoService.localMarcacao(m, _pars), 'p. 1, parágrafo 2');

    // Trecho que só existe no PDF (cabeçalho cortado): fica sem parágrafo.
    final solta = AnexosProcessoService.novaMarcacaoPdf(
      pagina: 2,
      textoPagina: 'Rodapé só do PDF',
      inicio: 0,
      fim: 6,
      pars: _pars,
    );
    expect(solta.paragrafo, -1);
    expect(AnexosProcessoService.localMarcacao(solta, _pars), 'p. 2');
  });

  test('marcação feita no Texto é localizada no PDF (página certa)', () {
    final p = _pars[1].texto;
    final i = p.indexOf('atividades de extensão');
    final m = AnexosProcessoService.novaMarcacao(
      paragrafo: 1,
      textoParagrafo: p,
      inicio: i,
      fim: i + 'atividades de extensão'.length,
    );
    final ancorada = AnexosProcessoService.ancorarNoPdf(m, [
      _paginaPdf1,
      _paginaPdf2,
    ], _pars)!;
    expect(ancorada.pdfPagina, 1);
    expect(
      _paginaPdf1.substring(ancorada.pdfInicio, ancorada.pdfFim),
      'atividades de exten-\nsão',
    );
    final colegiado = AnexosProcessoService.novaMarcacao(
      paragrafo: 2,
      textoParagrafo: _pars[2].texto,
      inicio: 0,
      fim: 10,
    );
    expect(
      AnexosProcessoService.ancorarNoPdf(colegiado, [
        _paginaPdf1,
        _paginaPdf2,
      ], _pars)!.pdfPagina,
      2,
    );
  });

  test('contexto da página para a IA inclui a página vizinha', () {
    final ini = _paginaPdf2.indexOf('Colegiado');
    final c = AnexosProcessoService.contextoPdf(
      [_paginaPdf1, _paginaPdf2],
      2,
      ini,
      ini + 9,
    );
    expect(c.antes, contains('Resolução CONGRAD'));
    expect(c.antes, endsWith('aprovada pelo '));
    expect(c.depois, startsWith(' em 3 de março'));
  });

  test('âncora do PDF no JSON e atualização em lote', () async {
    SharedPreferences.setMockInitialValues({});
    final m = const MarcacaoAnexo(
      id: 'a',
      paragrafo: -1,
      inicio: 0,
      fim: 0,
      texto: 'x',
      pdfPagina: 3,
      pdfInicio: 10,
      pdfFim: 20,
    );
    final volta = MarcacaoAnexo.fromJson(m.toJson());
    expect((volta.pdfPagina, volta.pdfInicio, volta.pdfFim), (3, 10, 20));
    expect(MarcacaoAnexo.fromJson({'id': 'b'}).pdfPagina, 0);

    final anexo = AnexoProcesso(
      id: 'doc',
      nome: 'oficio.pdf',
      hash: 'h',
      extensao: '.pdf',
      marcacoes: [
        m,
        const MarcacaoAnexo(
          id: 'c',
          paragrafo: 0,
          inicio: 0,
          fim: 1,
          texto: 'y',
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'parecer_anexos.p1': jsonEncode([anexo.toJson()]),
    });
    final s = AnexosProcessoService(pasta: () async => '.');
    await s.usarProcesso('p1');
    final c = s.anexos.single.marcacoes.firstWhere((x) => x.id == 'c');
    await s.atualizarMarcacoes('doc', [
      c.ancorada(pdfPagina: 1, pdfInicio: 5, pdfFim: 6),
    ]);
    final relido = AnexosProcessoService(pasta: () async => '.');
    await relido.usarProcesso('p1');
    final ordem = relido.anexos.single.marcacoes.map((x) => x.id).toList();
    expect(ordem, ['c', 'a']); // página 1 antes da página 3
    expect(relido.anexos.single.marcacoes.first.pdfPagina, 1);
  });
}
