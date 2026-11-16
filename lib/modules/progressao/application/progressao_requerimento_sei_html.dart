import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:gestor_ufu/modules/progressao/application/progressao_sei_text.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/modules/progressao/domain/resolucao_condir_03_2017.dart';

typedef RequerimentoMerge = ({String html, List<String> ausentes});

/// Preenche o modelo nativo do SEI, preservando a estrutura e alterando
/// somente as células de valores reconhecidas por seus rótulos.
class ProgressaoRequerimentoSeiHtml {
  const ProgressaoRequerimentoSeiHtml._();

  static RequerimentoMerge merge(String modelo, ProgressaoDocente p) {
    final fragment = html_parser.parseFragment(modelo);
    final ausentes = <String>[];
    final tabelas = fragment.querySelectorAll('table');
    final valores = <String, String>{
      'Nome:': p.docente.trim(),
      'Lotacao:': p.lotacao.trim(),
      'SIAPE:': p.siape.trim(),
      'Admissao:': formatarDataSei(p.dataAdmissao),
      'Ultima progressao/promocao:': ultimaProgressaoDescricao(p),
      'Titulacao:': _titulacao(p),
      'Regime de trabalho:': _regime(p),
    };
    for (final entry in valores.entries) {
      final celulaRotulo = _cellForLabel(tabelas, entry.key);
      final seguinte = celulaRotulo == null ? null : _nextCell(celulaRotulo);
      if (seguinte == null || entry.value.isEmpty) {
        ausentes.add(entry.key);
      } else {
        _writeCell(seguinte, entry.value);
      }
    }

    _periodo(
      tabelas,
      'Periodo do relatorio:',
      p.relatorioInicio,
      p.relatorioFim,
      ausentes,
    );
    _periodo(
      tabelas,
      'Intersticio:',
      p.intersticioInicio,
      p.intersticioFim,
      ausentes,
    );
    if (p.relatorioInicio != null &&
        p.intersticioInicio != null &&
        p.relatorioInicio!.isBefore(p.intersticioInicio!)) {
      final justificativa = _tableWithLabel(
        tabelas,
        'Justificativa em caso de alteracao do intersticio:',
      );
      final row = justificativa == null
          ? null
          : _rows(justificativa).skip(1).firstOrNull;
      final cell = row?.querySelector('td');
      if (cell == null || p.justificativaIntersticio.trim().isEmpty) {
        ausentes.add('Justificativa em caso de alteração do interstício');
      } else {
        _writeCell(cell, p.justificativaIntersticio.trim());
      }
    }

    _marcarTipo(tabelas, p, ausentes);
    _marcarMovimento(tabelas, p, ausentes);
    _preencherPontuacao(tabelas, p, ausentes);
    _preencherDataFinal(fragment, p, ausentes);

    return (html: fragment.outerHtml, ausentes: ausentes.toSet().toList());
  }

  static String _titulacao(ProgressaoDocente p) => switch (p.titulacao) {
    Titulacao.graduacao => 'Graduado',
    Titulacao.mestrado => 'Mestre',
    Titulacao.doutorado => 'Doutor',
  };

  static String _regime(ProgressaoDocente p) => switch (p.regime) {
    Regime.de => 'DE',
    Regime.h40 => '40h',
    Regime.h20 => '20h',
  };

  static void _periodo(
    List<Element> tabelas,
    String label,
    DateTime? inicio,
    DateTime? fim,
    List<String> ausentes,
  ) {
    final cell = _cellForLabel(tabelas, label);
    final row = cell?.parent;
    final cells = row?.querySelectorAll('td,th') ?? const <Element>[];
    if (cells.length < 4 || inicio == null || fim == null) {
      ausentes.add(label);
      return;
    }
    _writeCell(cells[1], formatarDataSei(inicio));
    _writeCell(cells[3], formatarDataSei(fim));
  }

  static void _marcarTipo(
    List<Element> tabelas,
    ProgressaoDocente p,
    List<String> ausentes,
  ) {
    final alvo = p.promocao ? 'Promocao' : 'Progressao';
    final row = tabelas
        .expand(_rows)
        .firstWhereOrNull(
          (r) => _cells(r).any((cell) => _norm(cell.text) == _norm(alvo)),
        );
    final cell = row == null ? null : _cells(row).firstOrNull;
    if (cell == null) {
      ausentes.add('Caixa $alvo');
      return;
    }
    _writeCell(cell, 'X');
  }

  static void _marcarMovimento(
    List<Element> tabelas,
    ProgressaoDocente p,
    List<String> ausentes,
  ) {
    final origem = p.atual;
    if (origem == null) {
      ausentes.add('Posição de origem');
      return;
    }
    final grid = _movementGrid(tabelas, p.promocao);
    if (grid == null) {
      ausentes.add(p.promocao ? 'Grade de promoção' : 'Grade de progressão');
      return;
    }
    if (p.promocao) {
      final boxIndex = origem.carreira == Carreira.ebtt ? 6 : 0;
      final classKey = _norm(origem.classe);
      final row = _rows(grid).firstWhereOrNull((candidate) {
        final cells = _cells(candidate);
        return cells.length > boxIndex &&
            cells.length > 1 &&
            _norm(cells[1].text).startsWith(classKey);
      });
      final cells = row == null ? const <Element>[] : _cells(row);
      if (cells.length <= boxIndex) {
        ausentes.add('Caixa da promocao ${origem.descricaoClasseNivel}');
      } else {
        _writeCell(cells[boxIndex], 'X');
      }
      return;
    }

    final cellsByClass = origem.carreira == Carreira.ebtt ? 7 : 0;
    final classRow = _rows(grid).firstWhereOrNull((row) {
      final cells = _cells(row);
      final position = cells.length > 1 ? _norm(cells[1].text) : '';
      return position.startsWith(_norm(origem.classe)) &&
          (origem.carreira != Carreira.magisterioSuperior ||
              position.contains(_className(origem.classe)));
    });
    final classCells = classRow == null ? const <Element>[] : _cells(classRow);
    if (classCells.length <= cellsByClass) {
      ausentes.add('Caixa da classe ${origem.classe}');
    } else {
      _writeCell(classCells[cellsByClass], 'X');
    }

    final fromIndex = origem.carreira == Carreira.ebtt ? 11 : 4;
    final levelBox = origem.carreira == Carreira.ebtt ? 10 : 3;
    final nivelOrigem = switch (origem.nivel) {
      'I' => '1',
      'II' => '2',
      'III' => '3',
      'IV' => '4',
      _ => origem.nivel,
    };
    final levelRow = _rows(grid).firstWhereOrNull((row) {
      final cells = _cells(row);
      return cells.length > fromIndex &&
          _norm(cells[fromIndex].text) == _norm(nivelOrigem);
    });
    final levelCells = levelRow == null ? const <Element>[] : _cells(levelRow);
    if (levelCells.length <= levelBox) {
      ausentes.add('Caixa do nível ${origem.nivel}');
    } else {
      _writeCell(levelCells[levelBox], 'X');
    }
  }

  static int _promotionRowIndex(PosicaoCarreira origem) {
    if (origem.carreira == Carreira.ebtt) {
      return switch (origem.classe) {
        'D I' => 0,
        'D II' => 1,
        'D III' => 2,
        'D IV' => 3,
        _ => -1,
      };
    }
    return switch (origem.classe) {
      'A' => 0,
      'B' => 1,
      'C' => 2,
      'D' => 3,
      _ => -1,
    };
  }

  static String _className(String classe) => switch (classe) {
    'A' => 'auxiliar',
    'B' => 'assistente',
    'C' => 'adjunto',
    'D' => 'associado',
    _ => 'titular',
  };

  static void _preencherPontuacao(
    List<Element> tabelas,
    ProgressaoDocente p,
    List<String> ausentes,
  ) {
    final table = _tableWithLabel(tabelas, 'Resumo da pontuacao');
    if (table == null) {
      ausentes.add('Tabela Resumo da pontuação');
      return;
    }
    for (var i = 0; i < 7; i++) {
      final label = 'a1.${i + 1}';
      final row = _rows(table).firstWhereOrNull(
        (r) => _norm(_cells(r).firstOrNull?.text ?? '').contains(_norm(label)),
      );
      final cells = row == null ? const <Element>[] : _cells(row);
      if (row == null || cells.length < 3) {
        ausentes.add('Pontuação $label');
      } else {
        _writeCell(
          cells[2],
          formatarPontuacaoSei(p.totalTabela(TabelaAnexo1.values[i])),
        );
      }
    }
    final totalRow = _rows(table).firstWhereOrNull(
      (r) => _norm(r.text).contains('total') && _cells(r).length >= 2,
    );
    if (totalRow == null) {
      ausentes.add('Pontuação total');
    } else {
      _writeCell(_cells(totalRow).last, formatarPontuacaoSei(p.total));
    }
  }

  static void _preencherDataFinal(
    DocumentFragment fragment,
    ProgressaoDocente p,
    List<String> ausentes,
  ) {
    final alvo = _norm('${p.cidade} dia');
    final paragrafos = fragment.querySelectorAll('p');
    final dateParagraph = paragrafos.firstWhereOrNull(
      (paragraph) => _norm(paragraph.text).startsWith(alvo),
    );
    if (dateParagraph == null || p.dataDocumento == null) {
      ausentes.add('Data por extenso do requerimento');
    } else {
      dateParagraph.text = dataPorExtensoSei(p, p.dataDocumento);
    }
  }

  static Element? _movementGrid(List<Element> tabelas, bool promocao) {
    final candidates = tabelas.where((table) {
      final text = _norm(table.text);
      final rows = _rows(table);
      return text.contains('associado') &&
          text.contains('nivel') &&
          rows.length >= 3 &&
          rows.any((r) => _cells(r).length >= 6);
    }).toList();
    if (candidates.isEmpty) return null;
    // No modelo SEI, a grade de progressao vem antes da grade de promocao.
    return promocao ? candidates.last : candidates.first;
  }

  static List<Element> _rows(Element table) => table
      .querySelectorAll('tr')
      .where((row) => _ancestorTag(row, 'table') == table)
      .toList();

  static List<Element> _cells(Element row) => row
      .querySelectorAll('td,th')
      .where((cell) => _ancestorTag(cell, 'tr') == row)
      .toList();

  static Element? _ancestorTag(Node? node, String tag) {
    var current = node;
    while (current != null) {
      if (current is Element && current.localName == tag) return current;
      current = current.parent;
    }
    return null;
  }

  static Element? _tableWithLabel(List<Element> tables, String label) {
    final target = _norm(label);
    return tables.firstWhereOrNull(
      (table) => _norm(table.text).contains(target),
    );
  }

  static Element? _cellForLabel(List<Element> tables, String label) {
    final target = _norm(label);
    for (final table in tables) {
      for (final cell in table.querySelectorAll('td,th')) {
        if (_norm(cell.text) == target) return cell;
      }
    }
    return null;
  }

  static Element? _nextCell(Element cell) {
    final row = cell.parent;
    if (row == null) return null;
    final cells = row.querySelectorAll('td,th');
    final index = cells.indexOf(cell);
    return index >= 0 && index + 1 < cells.length ? cells[index + 1] : null;
  }

  static void _writeCell(Element cell, String value) {
    final paragraph = cell.querySelector('p');
    if (paragraph != null) {
      paragraph.text = value;
    } else {
      cell.nodes.clear();
      cell.append(
        Element.tag('p')
          ..classes.add('Tabela_Texto_Alinhado_Esquerda')
          ..text = value,
      );
    }
  }

  static String _norm(String text) => text
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('à', 'a')
      .replaceAll('ã', 'a')
      .replaceAll('â', 'a')
      .replaceAll('é', 'e')
      .replaceAll('ê', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ô', 'o')
      .replaceAll('õ', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;

  T? firstWhereOrNull(bool Function(T) test) {
    for (final value in this) {
      if (test(value)) return value;
    }
    return null;
  }
}
