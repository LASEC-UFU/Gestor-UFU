import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:gestor_ufu/domain/entities/progressao.dart';
import 'package:gestor_ufu/domain/progressao/resolucao_condir_03_2017.dart';

/// Gera o PDF "Requerimento + Relatório de Atividades" no formato do modelo
/// usado na UFU para progressão/promoção (Resolução 03/2017 CONDIR).
class ProgressaoPdfService {
  static const _azul = PdfColor.fromInt(0xFF2F5496);
  static const _verde = PdfColor.fromInt(0xFFEAF1DD);
  static const _cinza = PdfColor.fromInt(0xFFF2F2F2);
  static const _vermelho = PdfColor.fromInt(0xFFE00000);
  static const _meses = [
    'janeiro',
    'fevereiro',
    'março',
    'abril',
    'maio',
    'junho',
    'julho',
    'agosto',
    'setembro',
    'outubro',
    'novembro',
    'dezembro',
  ];

  Future<Uint8List> gerar(ProgressaoDocente p, {DateTime? hoje}) async {
    final fonts = await _Fonts.load();
    final logo = await _logo(p.logoPath);
    final doc = pw.Document(
      title: 'Relatório de Atividades - ${p.docente}',
      author: p.docente,
      theme: pw.ThemeData.withFont(
        base: fonts.regular,
        bold: fonts.bold,
        italic: fonts.italic,
        boldItalic: fonts.bold,
      ),
    );
    final b = _Builder(p, fonts, logo, hoje ?? DateTime.now());
    doc.addPage(b.pagina((ctx) => b.requerimento(), mostrarNome: false));
    doc.addPage(b.pagina((ctx) => b.capa(), mostrarNome: false));
    doc.addPage(b.pagina((ctx) => b.sumario()));
    doc.addPage(
      pw.MultiPage(
        pageTheme: b.tema,
        header: (ctx) => b.cabecalho(true),
        footer: b.rodape,
        build: (ctx) => b.secoes(),
      ),
    );
    return doc.save();
  }

  Future<pw.ImageProvider?> _logo(String path) async {
    if (path.trim().isEmpty) return null;
    try {
      final file = File(path.trim());
      if (!await file.exists()) return null;
      return pw.MemoryImage(await file.readAsBytes());
    } on Object {
      return null;
    }
  }

  static String data(DateTime? d) => d == null
      ? '__/__/____'
      : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String dataExtenso(DateTime d) =>
      '${d.day} de ${_meses[d.month - 1]} de ${d.year}';

  static String pontos(double v) {
    final rounded = (v * 100).roundToDouble() / 100;
    return formatarNumero(rounded);
  }
}

class _Fonts {
  _Fonts(this.regular, this.bold, this.italic, this.titulo);

  final pw.Font regular;
  final pw.Font bold;
  final pw.Font italic;
  final pw.Font titulo;

  static Future<pw.Font?> _ttf(List<String> names) async {
    for (final name in names) {
      final file = File('C:/Windows/Fonts/$name');
      try {
        if (await file.exists()) {
          return pw.Font.ttf(ByteData.sublistView(await file.readAsBytes()));
        }
      } on Object {
        // Tenta a próxima fonte.
      }
    }
    return null;
  }

  static Future<_Fonts> load() async {
    final regular =
        await _ttf(['calibri.ttf', 'arial.ttf']) ?? pw.Font.helvetica();
    final bold =
        await _ttf(['calibrib.ttf', 'arialbd.ttf']) ?? pw.Font.helveticaBold();
    final italic =
        await _ttf(['calibrii.ttf', 'ariali.ttf']) ??
        pw.Font.helveticaOblique();
    final titulo = await _ttf(['georgia.ttf', 'cambria.ttf']) ?? regular;
    return _Fonts(regular, bold, italic, titulo);
  }
}

class _Builder {
  _Builder(this.p, this.f, this.logo, this.hoje);

  final ProgressaoDocente p;
  final _Fonts f;
  final pw.ImageProvider? logo;
  final DateTime hoje;
  int _secao = 0;
  int _tabela = 0;

  pw.PageTheme get tema => pw.PageTheme(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(70, 36, 56, 40),
  );

  pw.Page pagina(pw.BuildCallback build, {bool mostrarNome = true}) => pw.Page(
    pageTheme: tema,
    build: (ctx) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        cabecalho(mostrarNome),
        pw.Expanded(child: build(ctx)),
        rodape(ctx),
      ],
    ),
  );

  // ----------------------------------------------------------------- moldura
  pw.Widget cabecalho(bool mostrarNome) => pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 18),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        if (logo != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(right: 8),
            child: pw.Image(logo!, height: 46),
          ),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.only(bottom: 3),
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(width: .8)),
            ),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      if (p.lotacao.trim().isNotEmpty)
                        pw.Text(
                          p.lotacao.trim(),
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      pw.Text(
                        'Universidade Federal de Uberlândia',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                    ],
                  ),
                ),
                if (mostrarNome && p.docente.trim().isNotEmpty)
                  pw.Text(
                    p.docente.trim(),
                    style: pw.TextStyle(
                      fontSize: 9,
                      font: f.italic,
                      fontStyle: pw.FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  pw.Widget rodape(pw.Context ctx) => pw.Container(
    alignment: pw.Alignment.centerRight,
    margin: const pw.EdgeInsets.only(top: 10),
    child: pw.Text(
      '${ctx.pageNumber}',
      style: const pw.TextStyle(fontSize: 10),
    ),
  );

  // -------------------------------------------------------------- textos-base
  PosicaoCarreira get _alvo => p.alvo;
  PosicaoCarreira? get _atual => p.atual;
  String get _art => artigoAvaliacao(_alvo);
  bool get _art6 => _art == 'art. 6º';

  String get _carreiraTexto => p.carreira == Carreira.magisterioSuperior
      ? 'carreira do magistério superior'
      : 'carreira do magistério do ensino básico, técnico e tecnológico';

  String get _movimentoTexto {
    final atual = _atual;
    final de = atual == null
        ? ''
        : 'da ${atual.descricaoClasseNivel} (${atual.denominacao(p.titulacao)}) ';
    return '${p.tipoMovimento} ${de}para a ${_alvo.descricaoClasseNivel} (${_alvo.denominacao(p.titulacao)})';
  }

  String get _referente {
    final atual = _atual;
    final t = p.tipoMovimento;
    final cap = '${t[0].toUpperCase()}${t.substring(1)}';
    return atual == null
        ? '$cap para a ${_alvo.descricaoClasseNivel}'
        : '$cap da ${atual.descricaoClasseNivel} para a ${_alvo.descricaoClasseNivel}';
  }

  String get _incisoAssiduidade => _art6
      ? 'O inciso II do § 1º do art. 6º'
      : 'O inciso I do parágrafo único do art. 5º';

  String get _incisoDidatico => _art6
      ? 'O inciso III do § 1º do art. 6º'
      : 'O inciso II do parágrafo único do art. 5º';

  String get _incisoPontuacao => switch (_art) {
    'art. 6º' => 'inciso V do § 1º do art. 6º',
    'art. 7º' => 'inciso III do art. 7º',
    'art. 8º' => 'inciso III do art. 8º',
    _ => 'inciso III do parágrafo único do art. 5º',
  };

  String get _referencia => p.referencia == null ? '___' : '${p.referencia}';

  // ------------------------------------------------------------- requerimento
  pw.Widget requerimento() {
    final dataDoc = p.dataDocumento ?? hoje;
    final ref = _atual == null
        ? 'Ref.: ${_capitalizar(p.tipoMovimento)} para ${_alvo.denominacao(p.titulacao)}.'
        : 'Ref.: ${_capitalizar(p.tipoMovimento)} de ${_atual!.denominacao(p.titulacao)} para ${_alvo.denominacao(p.titulacao)}.';
    final texto =
        'Conforme estabelece a Resolução Nº 03/2017, do Conselho Diretor, com as alterações '
        'da Resolução SEI Nº 05/2018, que regulamenta a avaliação docente da $_carreiraTexto, '
        'venho, por meio desta, requerer avaliação de desempenho para efeito de $_movimentoTexto, '
        'considerando o interstício de 24 meses (dois anos) de efetivo exercício no nível atual '
        '(período de referência de ${ProgressaoPdfService.data(p.intersticioInicio)} a '
        '${ProgressaoPdfService.data(p.intersticioFim)}). O relatório de atividades anexo '
        'contempla o período de ${ProgressaoPdfService.data(p.relatorioInicio)} a '
        '${ProgressaoPdfService.data(p.relatorioFim)}. Para a ${p.tipoMovimento} requerida, '
        'conforme estabelece o $_art da supracitada resolução, as atividades desenvolvidas pelo '
        'docente devem contabilizar uma pontuação mínima de $_referencia pontos, para o docente '
        'com título de ${p.titulacao.rotulo} em regime de ${p.regime.rotulo.toLowerCase()}, além de '
        'demonstrar desempenho didático, assiduidade, responsabilidade e qualidade no exercício '
        'de suas atividades. Assim, segue em anexo relatório de atividades comprovando todos os '
        'requisitos exigidos pela regulamentação atual.';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.SizedBox(height: 8),
        pw.Text(
          '${p.cidade}, ${ProgressaoPdfService.dataExtenso(dataDoc)}',
          textAlign: pw.TextAlign.right,
          style: const pw.TextStyle(fontSize: 11),
        ),
        pw.SizedBox(height: 36),
        pw.Text(
          'Ao ${p.destinatario.trim().isEmpty ? 'Diretor(a) da Unidade' : p.destinatario.trim()}',
          style: const pw.TextStyle(fontSize: 11),
        ),
        pw.SizedBox(height: 30),
        pw.Text(
          ref,
          textAlign: pw.TextAlign.right,
          style: const pw.TextStyle(fontSize: 11),
        ),
        pw.SizedBox(height: 30),
        _paragrafo(texto, recuo: true, espaco: 9),
        pw.SizedBox(height: 26),
        pw.Text('Atenciosamente,', style: const pw.TextStyle(fontSize: 11)),
        pw.SizedBox(height: 70),
        pw.Text(
          'Prof. ${p.docente.trim()}.',
          style: const pw.TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------- capa
  pw.Widget capa() {
    pw.TableRow linha(String rotulo, String valor) => pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Text(rotulo, style: const pw.TextStyle(fontSize: 10.5)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Text(valor, style: const pw.TextStyle(fontSize: 10.5)),
        ),
      ],
    );
    return pw.Column(
      children: [
        pw.SizedBox(height: 70),
        pw.Text(
          'RELATÓRIO DE ATIVIDADES',
          style: pw.TextStyle(font: f.regular, fontSize: 24),
        ),
        pw.SizedBox(height: 34),
        pw.Text(
          'RESOLUÇÃO 03/2017 CONDIR',
          style: pw.TextStyle(font: f.regular, fontSize: 24),
        ),
        pw.SizedBox(height: 50),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10),
          child: pw.Table(
            columnWidths: const {
              0: pw.FixedColumnWidth(130),
              1: pw.FlexColumnWidth(),
            },
            children: [
              linha('Docente:', p.docente),
              linha('Lotação:', p.lotacao),
              linha('Regime de Trabalho:', p.regime.textoRelatorio),
              linha('M. Siape:', p.siape),
              linha(
                'Interstício:',
                '${ProgressaoPdfService.data(p.intersticioInicio)} a ${ProgressaoPdfService.data(p.intersticioFim)}',
              ),
              linha(
                'Período do relatório:',
                '${ProgressaoPdfService.data(p.relatorioInicio)} a ${ProgressaoPdfService.data(p.relatorioFim)}',
              ),
              if (p.semestres.trim().isNotEmpty)
                linha('Semestres considerados:', p.semestres.trim()),
              linha('Referente:', _referente),
              linha(
                'Pontuação de referência:',
                '$_referencia pontos (${tabelaReferencia(p.carreira, p.regime)})',
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ sumário
  pw.Widget sumario() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.SizedBox(height: 10),
      pw.Center(
        child: pw.Text(
          'Sumário',
          style: pw.TextStyle(font: f.regular, fontSize: 20),
        ),
      ),
      pw.SizedBox(height: 30),
      pw.DefaultTextStyle(
        style: const pw.TextStyle(fontSize: 10.5),
        child: pw.TableOfContent(),
      ),
    ],
  );

  // ------------------------------------------------------------------- seções
  pw.Widget _titulo(String texto) {
    _secao++;
    final t = '$_secao - $texto';
    return pw.Header(
      level: 0,
      title: t,
      margin: const pw.EdgeInsets.only(bottom: 12, top: 4),
      padding: const pw.EdgeInsets.only(bottom: 3),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: ProgressaoPdfService._azul, width: .8),
        ),
      ),
      child: pw.Text(
        t,
        style: pw.TextStyle(
          font: f.titulo,
          fontSize: 19,
          color: ProgressaoPdfService._azul,
        ),
      ),
    );
  }

  pw.Widget _paragrafo(String texto, {bool recuo = false, double espaco = 5}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Text(
          '${recuo ? '        ' : ''}$texto',
          textAlign: pw.TextAlign.justify,
          style: pw.TextStyle(fontSize: 11, lineSpacing: espaco),
        ),
      );

  List<pw.Widget> secoes() {
    _secao = 0;
    _tabela = 0;
    final out = <pw.Widget>[];
    final noventaDias =
        p.relatorioFim != null &&
        p.intersticioFim != null &&
        p.relatorioFim!.isBefore(p.intersticioFim!);

    out
      ..add(_titulo('Introdução'))
      ..add(
        _paragrafo(
          'O presente relatório visa atender aos desígnios da Resolução Nº 03/2017, do Conselho '
          'Diretor, com as alterações da Resolução SEI Nº 05/2018, que regulamenta a progressão '
          'e promoção do docente da $_carreiraTexto. Este documento compreende a descrição das '
          'atividades desenvolvidas durante o período de '
          '${ProgressaoPdfService.data(p.relatorioInicio)} a ${ProgressaoPdfService.data(p.relatorioFim)}'
          '${noventaDias ? ', dentro, portanto, dos 90 dias anteriores à data de referência (${ProgressaoPdfService.data(p.intersticioFim)}) permitidos pelo § 4º do art. 3º da mencionada Resolução' : ''}. '
          'A estrutura do presente documento está fundamentada no $_art da citada resolução e no '
          'roteiro de pontuação contido nos anexos da mesma.',
        ),
      )
      ..add(pw.SizedBox(height: 10))
      ..add(_titulo('Assiduidade, responsabilidade e qualidade do trabalho'))
      ..add(
        _paragrafo(
          '$_incisoAssiduidade da Resolução 03/2017 indica que a Comissão de Avaliação deve '
          'considerar em seu parecer a assiduidade, responsabilidade e qualidade do trabalho '
          'docente durante o interstício de 24 meses considerado. ${p.textoAssiduidade.trim()}',
        ),
      )
      ..add(pw.NewPage())
      ..add(_titulo('Avaliação Didática'))
      ..add(
        _paragrafo(
          '$_incisoDidatico estabelece que a Comissão de Avaliação deve considerar, em seu '
          'parecer, o desempenho didático do docente, avaliado com a participação do corpo '
          'discente. ${p.textoAvaliacaoDidatica.trim()}',
        ),
      );
    for (final a in p.avaliacoesDidaticas.where((a) => a.trim().isNotEmpty)) {
      out.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(left: 18, bottom: 4),
          child: pw.Bullet(
            text: a.trim(),
            style: const pw.TextStyle(fontSize: 10.5),
          ),
        ),
      );
    }
    if (p.textoAvaliacaoConclusao.trim().isNotEmpty) {
      out
        ..add(pw.SizedBox(height: 6))
        ..add(_paragrafo(p.textoAvaliacaoConclusao.trim()));
    }

    const titulos = {
      TabelaAnexo1.ensino: 'Atividades de Ensino',
      TabelaAnexo1.orientacao: 'Atividades de Orientação',
      TabelaAnexo1.producao: 'Produção Intelectual',
      TabelaAnexo1.semRemuneracao:
          'Atividades de ensino, extensão e pesquisa - sem remuneração suplementar',
      TabelaAnexo1.comRemuneracao:
          'Atividades de ensino, extensão e pesquisa - com remuneração suplementar',
      TabelaAnexo1.gestao: 'Atividades Administrativas',
      TabelaAnexo1.licencas: 'Licenças, situações especiais e afastamentos',
    };
    for (final tabela in TabelaAnexo1.values) {
      final itens = p.itensUsados(tabela);
      if (itens.isEmpty) continue;
      final titulo = titulos[tabela]!;
      out
        ..add(pw.NewPage())
        ..add(_titulo(titulo))
        ..add(_paragrafo(_introTabela(tabela)));
      if (tabela == TabelaAnexo1.producao) {
        for (final grupo in [
          'Produção bibliográfica e divulgação',
          'Produção artística',
          'Produção técnica',
        ]) {
          final doGrupo = itens
              .where((n) => itemAnexo1(n)!.subgrupo == grupo)
              .toList();
          if (doGrupo.isEmpty) continue;
          out.addAll(_tabelaItens('$grupo.', doGrupo));
        }
      } else {
        out.addAll(_tabelaItens('$titulo.', itens));
      }
      out.add(
        _caixaTotal(
          'Total de pontos para ${titulo.toLowerCase()} = '
          '${ProgressaoPdfService.pontos(p.totalTabela(tabela))}',
        ),
      );
    }

    out
      ..add(pw.NewPage())
      ..add(_titulo('Desempenho final'));
    _tabela++;
    out
      ..add(
        _paragrafo(
          'As atividades desenvolvidas no interstício considerado, de acordo com as premissas da '
          'Res. CONDIR 03/2017, culminaram no desempenho, detalhado por tipo de atividade, '
          'constante da Tabela ${_romano(_tabela)}.',
        ),
      )
      ..add(_legenda('Tabela ${_romano(_tabela)} – Desempenho final.'))
      ..add(_tabelaResumo())
      ..add(pw.SizedBox(height: 18))
      ..add(_paragrafo(_conclusao()));
    return out;
  }

  String _introTabela(TabelaAnexo1 tabela) {
    if (tabela == TabelaAnexo1.ensino) {
      final semestres = p.semestres.trim().isEmpty
          ? ''
          : ' compreende os semestres ${p.semestres.trim().replaceAll(RegExp(r';\s*$'), '')}.';
      return 'O interstício considerado (${ProgressaoPdfService.data(p.relatorioInicio)} a '
          '${ProgressaoPdfService.data(p.relatorioFim)})${semestres.isEmpty ? '.' : semestres} '
          'Todos os documentos que comprovam as atividades realizadas estão anexados ao presente '
          'processo SEI e indicados na cor vermelha nas tabelas apresentadas na sequência.';
    }
    if (tabela == TabelaAnexo1.gestao || tabela == TabelaAnexo1.licencas) {
      final fracao = p
          .itensUsados(tabela)
          .any(
            (n) => itemAnexo1(n)!.tipo == TipoPontuacao.fracaoReferenciaPorDia,
          );
      return 'Este tópico contempla as ${tabela.titulo.toLowerCase()} realizadas durante o '
          'período considerado (${tabela.codigo}, ${tabela.faixa}).'
          '${fracao ? ' Os itens pontuados por fração da pontuação de referência utilizam a referência de $_referencia pontos.' : ''}';
    }
    return 'Este tópico contempla as ${tabela.titulo[0].toLowerCase()}${tabela.titulo.substring(1)} '
        'realizadas durante o período considerado (${tabela.codigo}, ${tabela.faixa}).';
  }

  List<pw.Widget> _tabelaItens(String legenda, List<int> itens) {
    _tabela++;
    final out = <pw.Widget>[_legenda('Tabela ${_romano(_tabela)} – $legenda')];
    for (final numero in itens) {
      final item = itemAnexo1(numero)!;
      final lancs = p.lancamentosDoItem(numero);
      out.add(_cabecalhoItem(item));
      out.add(
        pw.Table(
          border: const pw.TableBorder(
            left: pw.BorderSide(width: .5),
            right: pw.BorderSide(width: .5),
            bottom: pw.BorderSide(width: .5),
            horizontalInside: pw.BorderSide(
              width: .3,
              color: PdfColors.grey500,
            ),
            verticalInside: pw.BorderSide(width: .3, color: PdfColors.grey500),
          ),
          columnWidths: const {
            0: pw.FixedColumnWidth(52),
            1: pw.FlexColumnWidth(),
            2: pw.FixedColumnWidth(42),
            3: pw.FixedColumnWidth(52),
          },
          children: [
            pw.TableRow(
              repeat: true,
              decoration: const pw.BoxDecoration(
                color: ProgressaoPdfService._cinza,
              ),
              children: [
                _cel('Período', centro: true, negrito: true),
                _cel('Atividade / comprovante', negrito: true),
                _cel('Qtd.', centro: true, negrito: true),
                _cel('Pontuação', centro: true, negrito: true),
              ],
            ),
            for (final l in lancs)
              pw.TableRow(
                children: [
                  _cel(l.periodo, centro: true),
                  _celAtividade(l),
                  _cel(formatarNumero(l.quantidade), centro: true),
                  _cel(
                    ProgressaoPdfService.pontos(p.pontosLancamento(l)),
                    centro: true,
                  ),
                ],
              ),
            pw.TableRow(
              children: [
                _cel(''),
                _cel(
                  item.teto != null && p.pontosBrutosItem(numero) > item.teto!
                      ? 'Subtotal do item $numero (limitado a ${formatarNumero(item.teto!)} pontos)'
                      : 'Subtotal do item $numero',
                  direita: true,
                  negrito: true,
                ),
                _cel(''),
                _cel(
                  ProgressaoPdfService.pontos(p.pontosItem(numero)),
                  centro: true,
                  negrito: true,
                ),
              ],
            ),
          ],
        ),
      );
      out.add(pw.SizedBox(height: 8));
    }
    return out;
  }

  pw.Widget _cabecalhoItem(ItemAnexo1 item) => pw.Container(
    decoration: pw.BoxDecoration(
      color: ProgressaoPdfService._verde,
      border: pw.Border.all(width: .5),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: 30,
          padding: const pw.EdgeInsets.all(4),
          alignment: pw.Alignment.topCenter,
          child: pw.Text(
            '${item.numero}',
            style: pw.TextStyle(fontSize: 9, font: f.bold),
          ),
        ),
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(4),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                left: pw.BorderSide(width: .5),
                right: pw.BorderSide(width: .5),
              ),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  item.descricao,
                  textAlign: pw.TextAlign.justify,
                  style: const pw.TextStyle(fontSize: 9),
                ),
                if (item.nota.isNotEmpty)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 2),
                    child: pw.Text(
                      item.nota,
                      textAlign: pw.TextAlign.justify,
                      style: pw.TextStyle(
                        fontSize: 7,
                        font: f.italic,
                        fontStyle: pw.FontStyle.italic,
                      ),
                    ),
                  ),
                if (item.alteradoPor.isNotEmpty)
                  pw.Text(
                    'Redação dada pela ${item.alteradoPor}.',
                    style: pw.TextStyle(
                      fontSize: 7,
                      font: f.italic,
                      fontStyle: pw.FontStyle.italic,
                    ),
                  ),
              ],
            ),
          ),
        ),
        pw.Container(
          width: 94,
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(
            item.tipo == TipoPontuacao.fracaoReferenciaPorDia
                ? '${item.regra} ($_referencia/${item.divisor} = ${ProgressaoPdfService.pontos(item.valorUnitario((p.referencia ?? 0).toDouble()))} por dia)'
                : item.regra,
            style: const pw.TextStyle(fontSize: 8),
          ),
        ),
      ],
    ),
  );

  pw.Widget _celAtividade(LancamentoProgressao l) {
    final spans = <pw.InlineSpan>[pw.TextSpan(text: l.descricao.trim())];
    if (l.inicio != null && l.fim != null) {
      spans.add(
        pw.TextSpan(
          text:
              '${l.descricao.trim().isEmpty ? '' : ' – '}${ProgressaoPdfService.data(l.inicio)} a ${ProgressaoPdfService.data(l.fim)}',
        ),
      );
    }
    if (l.rotuloComprovante.isNotEmpty) {
      spans
        ..add(const pw.TextSpan(text: ' ('))
        ..add(
          pw.TextSpan(
            text: l.rotuloComprovante,
            style: const pw.TextStyle(color: ProgressaoPdfService._vermelho),
          ),
        )
        ..add(const pw.TextSpan(text: ')'));
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
      child: pw.RichText(
        text: pw.TextSpan(
          style: const pw.TextStyle(fontSize: 8.5),
          children: spans,
        ),
      ),
    );
  }

  pw.Widget _cel(
    String texto, {
    bool centro = false,
    bool direita = false,
    bool negrito = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
    child: pw.Text(
      texto,
      textAlign: centro
          ? pw.TextAlign.center
          : direita
          ? pw.TextAlign.right
          : pw.TextAlign.left,
      style: pw.TextStyle(fontSize: 8.5, font: negrito ? f.bold : f.regular),
    ),
  );

  pw.Widget _legenda(String texto) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 6, bottom: 3),
    child: pw.Center(
      child: pw.Text(texto, style: const pw.TextStyle(fontSize: 10)),
    ),
  );

  pw.Widget _caixaTotal(String texto) => pw.Container(
    margin: const pw.EdgeInsets.symmetric(horizontal: 60, vertical: 10),
    padding: const pw.EdgeInsets.all(5),
    decoration: pw.BoxDecoration(
      color: ProgressaoPdfService._verde,
      border: pw.Border.all(width: .6),
    ),
    child: pw.Center(
      child: pw.Text(texto, style: const pw.TextStyle(fontSize: 9.5)),
    ),
  );

  pw.Widget _tabelaResumo() => pw.Table(
    border: pw.TableBorder.all(width: .5),
    columnWidths: const {
      0: pw.FixedColumnWidth(48),
      1: pw.FlexColumnWidth(),
      2: pw.FixedColumnWidth(70),
    },
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: ProgressaoPdfService._cinza),
        children: [
          _cel('Anexo', centro: true, negrito: true),
          _cel('Descrição', centro: true, negrito: true),
          _cel('Pontuação', centro: true, negrito: true),
        ],
      ),
      for (final t in TabelaAnexo1.values)
        pw.TableRow(
          children: [
            _cel(t.codigo, centro: true),
            _cel('${t.titulo} (${t.faixa})'),
            _cel(ProgressaoPdfService.pontos(p.totalTabela(t)), centro: true),
          ],
        ),
      pw.TableRow(
        children: [
          _cel(''),
          _cel('Total de Pontos', direita: true, negrito: true),
          _cel(
            ProgressaoPdfService.pontos(p.total),
            centro: true,
            negrito: true,
          ),
        ],
      ),
      pw.TableRow(
        children: [
          _cel(''),
          _cel(
            'Pontuação de referência (${tabelaReferencia(p.carreira, p.regime)})',
            direita: true,
          ),
          _cel(_referencia, centro: true),
        ],
      ),
    ],
  );

  String _conclusao() {
    final total = ProgressaoPdfService.pontos(p.total);
    final buffer = StringBuffer();
    if (p.referencia == null) {
      buffer.write(
        'A pontuação total obtida foi de $total pontos. Não há pontuação de referência '
        'definida nos Anexos 2 e 3 para a combinação de classe, nível e titulação informada.',
      );
    } else if (p.atingeReferencia) {
      final comp = p.total > p.referencia! ? 'superior' : 'igual';
      buffer.write(
        'A pontuação obtida, $total pontos, é $comp à pontuação de referência para a '
        '${p.tipoMovimento}, $_referencia pontos, cumprindo assim o requerido pelo '
        '$_incisoPontuacao da Resolução 03/2017 do CONDIR.',
      );
    } else {
      buffer.write(
        'A pontuação obtida, $total pontos, é inferior à pontuação de referência para a '
        '${p.tipoMovimento}, $_referencia pontos, exigida pelo $_incisoPontuacao da '
        'Resolução 03/2017 do CONDIR.',
      );
    }
    if (_art6 && p.totalTabela(TabelaAnexo1.producao) > 0) {
      buffer.write(
        ' Adicionalmente, a produção intelectual exigida pelo inciso IV do § 1º do art. 6º é '
        'comprovada pelas tabelas de Produção Intelectual deste relatório e está em concordância '
        'com o art. 9º da Portaria/MEC nº 554, de 20 de junho de 2013.',
      );
    }
    return buffer.toString();
  }

  static String _capitalizar(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static String _romano(int n) {
    const valores = [10, 9, 5, 4, 1];
    const simbolos = ['X', 'IX', 'V', 'IV', 'I'];
    var resto = n;
    final out = StringBuffer();
    for (var i = 0; i < valores.length; i++) {
      while (resto >= valores[i]) {
        out.write(simbolos[i]);
        resto -= valores[i];
      }
    }
    return out.toString();
  }
}
