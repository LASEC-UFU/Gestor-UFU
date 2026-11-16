import 'package:flutter_test/flutter_test.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/sei_parecer_html.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';

/// Trecho editável do modelo "Parecer" do SEI (como aparece no editor).
const _modelo = '''
<table><tbody>
<tr><td><p class="Tabela_Texto_Alinhado_Esquerda">ASSUNTO:</p></td><td><p class="Tabela_Texto_Alinhado_Esquerda">Digite aqui o texto do assunto... .... .</p></td></tr>
<tr><td><p>&nbsp;</p></td><td><p class="Tabela_Texto_Alinhado_Esquerda">Digite aqui o texto do item da ementa... .... .</p></td></tr>
</tbody></table>
<p>&nbsp;</p>
<p class="Texto_Justificado_Recuo_Primeira_Linha">Senhor [[nome do cargo da autoridade a quem o Parecer será submetido]],</p>
<p>&nbsp;</p>
<p class="Texto_Alinhado_Esquerda"><strong>I. RELATÓRIO</strong></p>
<p class="Item_Nivel1">Digite aqui o texto do item... .... .</p>
<p class="Item_Nivel1">Digite aqui o texto do item... .... .</p>
<p class="Texto_Alinhado_Esquerda"><strong>II. FUNDAMENTAÇÃO</strong></p>
<p class="Item_Nivel1">Digite aqui o texto do item... .... .</p>
<p class="Citacao">Citação. Citação.</p>
<p class="Texto_Alinhado_Esquerda"><strong>III. CONCLUSÃO</strong></p>
<p class="Item_Nivel1">Digite aqui o texto do item... .... .</p>
<p>&nbsp;</p>
<p class="Texto_Justificado_Recuo_Primeira_Linha">À consideração superior.</p>
<p>Nome do servidor</p>
<p>Cargo/função do servidor</p>
''';

void main() {
  test('documento da árvore guarda o id interno e gera link SEI', () {
    final doc = SeiDocumento.fromTree(
      1,
      'Parecer 4 (7856895)',
      href: 'controlador.php?acao=arvore_visualizar&id_documento=8711521&x=1',
    ).copyWith(data: '03/03/2025', resumo: 'parecer da relatora favorável');
    expect(doc.idDocumento, '8711521');
    expect(
      SeiParecerHtml.item(doc),
      'Parecer 4 (<a class="ancora_sei" id="lnkSei8711521">7856895</a>) – '
      'de 03 de março de 2025, parecer da relatora favorável',
    );
    final html = SeiParecerHtml.inventario([doc]);
    expect(html, contains('1. Parecer 4 (<a class="ancora_sei"'));
    expect(html, endsWith('favorável.</p>'));
  });

  test('inventário separa pastas a cada 20 documentos', () {
    final docs = [
      for (var i = 1; i <= 25; i++) SeiDocumento.fromTree(i, 'Despacho $i'),
    ];
    final html = SeiParecerHtml.inventario(docs);
    expect(html, contains('Pasta I<'));
    expect(html, contains('Pasta II<'));
    expect(html, contains('25. Despacho 25.'));
  });

  test('encaixa o rascunho nos campos do modelo do SEI', () {
    const p = Parecer(
      assunto: 'Alteração da Resolução nº 46/2022',
      ementa: 'Aprova as Normas Gerais da Graduação.',
      vocativo: 'Senhor Presidente,\nSenhores(as) Conselheiros(as),',
      abertura: 'Em cumprimento ao Despacho 262/2024, transcrevo o relato.',
      relatorio: '<p class="Texto_Justificado">1. Ofício 1;</p>',
      fundamentacao: '<p class="Texto_Justificado_Recuo_Primeira_Linha">Análise.</p>',
      conclusao: '<p>CONSIDERANDO o disposto…</p>',
      nomeSignatario: 'Fulano de Tal',
      cargoSignatario: 'Relator',
    );
    final r = SeiParecerHtmlMerger.merge(_modelo, p);
    final h = r.html;
    expect(h, isNot(contains('Digite aqui')));
    expect(h, isNot(contains('Citação')));
    expect(h, contains('Alteração da Resolução nº 46/2022'));
    expect(h, contains('Aprova as Normas Gerais da Graduação.'));
    expect(h, contains('Senhor Presidente,'));
    expect(h, contains('Senhores(as) Conselheiros(as),'));
    expect(h, contains('II. FUNDAMENTAÇÃO E ANÁLISE'));
    expect(h, contains('Fulano de Tal'));
    expect(h, contains('À consideração superior.'));
    final ordem = [
      'Senhor Presidente',
      'Em cumprimento',
      'I. RELATÓRIO',
      '1. Ofício 1;',
      'II. FUNDAMENTAÇÃO',
      'Análise.',
      'III. CONCLUSÃO',
      'CONSIDERANDO',
      'À consideração',
    ].map(h.indexOf).toList();
    expect(ordem.every((i) => i >= 0), isTrue);
    expect([...ordem]..sort(), ordem);
    expect(r.avisos, isEmpty);

    // Reaplicar (atualizar um parecer já inserido) não duplica nada.
    final again = SeiParecerHtmlMerger.merge(h, p).html;
    expect('Em cumprimento'.allMatches(again).length, 1);
    expect('Senhores(as)'.allMatches(again).length, 1);
    expect('1. Ofício 1;'.allMatches(again).length, 1);
  });

  test('recusa HTML que não é o modelo de Parecer', () {
    expect(
      () => SeiParecerHtmlMerger.merge('<p>Despacho</p>', const Parecer()),
      throwsStateError,
    );
  });

  test('lê a resposta de resumos da IA', () {
    final r = SeiArvoreService.lerResumos(
      'Segue:\n```json\n[{"ordem": 2, "resumo": "encaminhamento do processo."}]\n```',
    );
    expect(r, {2: 'encaminhamento do processo'});
  });
}
