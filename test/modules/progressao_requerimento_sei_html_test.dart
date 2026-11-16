import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_requerimento_sei_html.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';

void main() {
  test('preenche o modelo preservando a estrutura e marcando a progressão', () {
    final processo = ProgressaoDocente(
      id: 'teste',
      docente: 'Josué Silva de Morais',
      siape: '1839411',
      lotacao: 'Faculdade de Engenharia Elétrica',
      dataAdmissao: DateTime(2011, 1, 26),
      dataDocumento: DateTime(2026, 11, 26),
      alvoId: 'magisterioSuperior|D|IV',
      intersticioInicio: DateTime(2025, 1, 21),
      intersticioFim: DateTime(2027, 1, 20),
      relatorioInicio: DateTime(2025, 1, 21),
      relatorioFim: DateTime(2026, 11, 26),
    );
    const modelo = '''
<p>REQUERIMENTO PARA DESENVOLVIMENTO NA CARREIRA DOCENTE</p>
<table><tr><td>Nome:</td><td><p class="Tabela_Texto_Alinhado_Esquerda">Nome</p></td><td>Lotação:</td><td>Lotação</td></tr>
<tr><td>SIAPE:</td><td>SIAPE</td><td>Admissão:</td><td>Admissão</td><td>Última progressão/promoção:</td><td>Anterior</td></tr>
<tr><td>Titulação:</td><td>Titulação</td><td>Regime de trabalho:</td><td>Regime</td></tr></table>
<table><tr><td>Período do relatório:</td><td>início</td><td>a</td><td>fim</td></tr>
<tr><td>Interstício:</td><td>início</td><td>a</td><td>fim</td></tr></table>
<table><tr><td>PROGRESSÃO</td></tr></table>
<table><tr><td>Classe</td><td>Associado</td><td></td><td>Do Nivel</td><td>Nivel</td><td>Para Nivel</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
<tr><td></td><td>D (Associado)</td><td></td><td></td><td>3</td><td>4</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr>
<tr><td></td><td>C (Adjunto)</td><td></td><td></td><td>2</td><td>3</td><td></td><td></td><td></td><td></td><td></td><td></td><td></td></tr></table>
<table><tr><td>PROMOÇÃO</td></tr></table>
<table><tr><td></td><td>D</td><td>4</td><td>E</td><td>1</td><td></td><td></td></tr></table>
<table><caption>Resumo da pontuação</caption>
<tr><td>A 1.1</td><td>Ensino</td><td>old</td></tr><tr><td>A 1.2</td><td>Orientação</td><td>old</td></tr>
<tr><td>A 1.3</td><td>Produção</td><td>old</td></tr><tr><td>A 1.4</td><td>Sem remuneração</td><td>old</td></tr>
<tr><td>A 1.5</td><td>Com remuneração</td><td>old</td></tr><tr><td>A 1.6</td><td>Gestão</td><td>old</td></tr>
<tr><td>A 1.7</td><td>Licenças</td><td>old</td></tr><tr><td colspan="2">Total</td><td>old</td></tr></table>
<p>Uberlândia dia 1 de Janeiro de 2000</p>
''';

    final merged = ProgressaoRequerimentoSeiHtml.merge(modelo, processo);
    expect(merged.ausentes, isEmpty);
    expect(merged.html, contains('Josué Silva de Morais'));
    expect(merged.html, contains('26/01/2011'));
    expect(merged.html, contains('21/01/2025'));
    expect(merged.html, contains('26/11/2026'));
    expect(merged.html, contains('Uberlândia dia 26 de Novembro de 2026'));
    expect(
      merged.html,
      contains('<td><p class="Tabela_Texto_Alinhado_Esquerda">X</p></td>'),
    );
    expect(merged.html, contains('>0</p>'));
  });

  test('preenche o modelo real do SEI/UFU (caixas em parágrafos e grade)', () {
    final modelo = File(
      'test/fixtures/progressao_requerimento_sei_modelo.html',
    ).readAsStringSync();
    final processo = ProgressaoDocente(
      id: 'teste',
      docente: 'Josué Silva de Morais',
      siape: '1839411',
      lotacao: 'Faculdade de Engenharia Elétrica',
      dataAdmissao: DateTime(2011, 1, 26),
      dataDocumento: DateTime(2026, 11, 26),
      alvoId: 'magisterioSuperior|D|IV',
      intersticioInicio: DateTime(2025, 1, 21),
      intersticioFim: DateTime(2027, 1, 20),
      relatorioInicio: DateTime(2025, 1, 21),
      relatorioFim: DateTime(2026, 11, 26),
    );
    final merged = ProgressaoRequerimentoSeiHtml.merge(modelo, processo);
    expect(merged.ausentes, isEmpty);
    expect(merged.html, contains('Josué Silva de Morais'));
    expect(merged.html, contains('(<span>X</span>) <strong>PROGRESSÃO'));
    expect(merged.html, contains('(<span>X</span>) C (Associado)'));
    expect(merged.html, contains('(<span>X</span>) 3'));
    expect(merged.html, isNot(contains('(<span>X</span>) 2')));
    expect(merged.html, isNot(contains('(<span>X</span>) <strong>PROMOÇÃO')));
    expect(RegExp(r'\(<span>X</span>\)').allMatches(merged.html).length, 3);
  });

  test('não salva modelo incompleto: informa os rótulos faltantes', () {
    final merged = ProgressaoRequerimentoSeiHtml.merge(
      '<p>modelo desconhecido</p>',
      const ProgressaoDocente(id: 'teste'),
    );
    expect(merged.ausentes, isNotEmpty);
    expect(merged.ausentes, contains('Nome:'));
    expect(merged.ausentes, contains('Tabela Resumo da pontuação'));
  });
}
