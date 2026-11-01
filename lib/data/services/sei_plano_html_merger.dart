import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Applies plan data to the native HTML model loaded by SEI.
///
/// This deliberately refuses to create a replacement document: the supplied
/// HTML must contain the official Plan of Teaching sections.
class SeiPlanoHtmlMerger {
  static ({String html, int substitutions}) merge(
    String modelHtml,
    Map<String, dynamic> plan,
  ) {
    final fragment = html_parser.parseFragment(modelHtml);
    final elements = fragment.querySelectorAll('*');
    final modelText = _norm(fragment.text ?? '');
    if (modelText.isEmpty ||
        !modelText.contains('identificacao') ||
        !_hasSection(elements, 2, 'ementa') ||
        !_hasSection(elements, 7, 'avaliacao')) {
      throw StateError(
        'O editor não contém o modelo nativo de Plano de Ensino do SEI. '
        'Nenhuma versão genérica foi gravada; selecione o tipo correto e tente novamente.',
      );
    }

    final fields = Map<String, dynamic>.from(plan);
    final identity = Map<String, dynamic>.from(
      fields['identificacao'] as Map? ?? {},
    );
    final identityReplaced = _replaceIdentityTable(fragment, identity);
    var substitutions = identityReplaced ? 8 : 0;
    final missing = <String>[];
    if (!identityReplaced) missing.add('Identificação');

    void fill(String prompt, String value, int number, String section) {
      if (_replacePrompt(fragment, prompt, value)) {
        substitutions++;
      } else if (_insertAfterSection(fragment, number, section, value)) {
        substitutions++;
      } else {
        missing.add(section);
      }
    }

    fill('ementa aprovada', _str(fields, 'ementa'), 2, 'Ementa');
    fill(
      'importancia dos conteudos',
      _str(fields, 'justificativa'),
      3,
      'Justificativa',
    );

    final objectives = _section(fragment, 4, 'objetivo');
    if (objectives == null || !_sectionExists(fragment, 5, 'programa')) {
      missing.add('Objetivos');
    } else {
      _removeObjectivesBetween(
        fragment,
        objectives,
        _section(fragment, 5, 'programa')!,
      );
      final general = _labelledContent(
        'Objetivo Geral:',
        _str(fields, 'objetivo_geral'),
      );
      _insertAfter(objectives, general);
      _insertAfter(
        general,
        _labelledContent(
          'Objetivos Específicos:',
          _str(fields, 'objetivos_especificos'),
        ),
      );
      substitutions += 2;
    }

    final program = _section(fragment, 5, 'programa');
    if (program == null) {
      missing.add('Programa');
    } else {
      final theoreticalProgram = _labelledContent(
        'Dimensão Teórica:',
        _str(fields, 'programa_teorico'),
      );
      _insertAfter(program, theoreticalProgram);
      _insertAfter(
        theoreticalProgram,
        _labelledContent('Dimensão Prática:', _str(fields, 'programa_pratico')),
      );
      substitutions += 2;
    }

    final methodology = [
      'Técnicas de ensino: ${_str(fields, 'metodologia_tecnicas')}',
      'Recursos didáticos: ${_str(fields, 'metodologia_recursos')}',
      'Recursos audiovisuais: ${_str(fields, 'metodologia_audiovisuais')}',
    ].where((value) => value.trim().isNotEmpty).join('\n');
    fill('descrever a forma de organizacao', methodology, 6, 'Metodologia');

    final evaluation = [
      _str(fields, 'avaliacao_geral'),
      _str(fields, 'avaliacao_provas'),
      _withLabel(
        'Horário de Atendimento:',
        _str(fields, 'horario_atendimento'),
      ),
      _withLabel(
        'Atividade de Recuperação:',
        _str(fields, 'atividade_recuperacao'),
      ),
      _withLabel('Atendimento Especial:', _str(fields, 'atendimento_especial')),
    ].where((value) => value.trim().isNotEmpty).join('\n');
    fill(
      'descrever o tipo/modalidade de avaliacao',
      evaluation,
      7,
      'Avaliação',
    );

    final basicReferences = _replaceBibliography(
      fragment,
      'bibliografia basica',
      'bibliografia complementar',
      _strings(fields, 'bibliografia_basica'),
    );
    final complementaryReferences = _replaceBibliography(
      fragment,
      'bibliografia complementar',
      'aprovacao',
      _strings(fields, 'bibliografia_complementar'),
    );
    final basicFallback =
        !basicReferences &&
        _replacePrompt(
          fragment,
          'no minimo 3',
          _strings(fields, 'bibliografia_basica').join('\n'),
        );
    final complementaryFallback =
        !complementaryReferences &&
        _replacePrompt(
          fragment,
          'no minimo 5',
          _strings(fields, 'bibliografia_complementar').join('\n'),
        );
    if (basicReferences || basicFallback) {
      substitutions++;
    } else {
      missing.add('Bibliografia Básica');
    }
    if (complementaryReferences || complementaryFallback) {
      substitutions++;
    } else {
      missing.add('Bibliografia Complementar');
    }

    _removeTemplateInstructions(fragment);
    if (missing.isNotEmpty) {
      throw StateError(
        'Não encontrei no modelo do SEI as seções: ${missing.join(', ')}. Nenhum documento foi alterado.',
      );
    }

    final theoretical = _rows(fields, 'cronograma_teorico');
    final practical = _rows(fields, 'cronograma_pratico');
    _validateScheduleRows(theoretical, 'teórico');
    _validateScheduleRows(practical, 'prático');
    final evaluationTitle = _section(fragment, 7, 'avaliacao');
    if ((theoretical.isNotEmpty || practical.isNotEmpty) &&
        evaluationTitle == null) {
      throw StateError(
        'Não encontrei a seção Avaliação para posicionar os cronogramas. Nenhum documento foi alterado.',
      );
    }
    if (theoretical.isNotEmpty || practical.isNotEmpty) {
      final insertion = _nativeInsertionPoint(evaluationTitle!);
      _insertBefore(
        insertion,
        _scheduleLabel('Cronograma das atividades curriculares:', top: true),
      );
      if (theoretical.isNotEmpty)
        _insertBefore(insertion, _schedule('Dimensão Teórica', theoretical));
      if (practical.isNotEmpty)
        _insertBefore(insertion, _schedule('Dimensão Prática', practical));
      substitutions++;
    }
    if (substitutions < 8) {
      throw StateError(
        'O modelo do SEI não apresentou os campos esperados. Nenhum documento foi alterado.',
      );
    }
    return (html: fragment.outerHtml, substitutions: substitutions);
  }

  static bool _replaceIdentityTable(
    DocumentFragment fragment,
    Map<String, dynamic> data,
  ) {
    final candidates = fragment.querySelectorAll('table').where((table) {
      final text = _norm(table.text);
      return [
        'componente curricular',
        'unidade ofertante',
        'codigo',
        'observacoes',
      ].every(text.contains);
    }).toList();
    if (candidates.isEmpty) return false;
    final old = candidates.reduce(
      (a, b) => a.text.length < b.text.length ? a : b,
    );
    final table = Element.tag('table')
      ..attributes['border'] = '1'
      ..attributes['style'] =
          'width:100%;border-collapse:collapse;table-layout:fixed;font-size:10pt;margin:4px 0 10px;';
    final widths = Element.tag('colgroup');
    for (var i = 0; i < 5; i++) {
      widths.append(Element.tag('col')..attributes['style'] = 'width:20%;');
    }
    table.append(widths);
    void row(List<(String, String, String, int)> cells) {
      final tr = Element.tag('tr');
      for (final cell in cells) {
        final (tag, label, value, span) = cell;
        final node = Element.tag(tag);
        if (span > 1) node.attributes['colspan'] = '$span';
        node.attributes['style'] =
            'border:1px solid #888;padding:5px;vertical-align:top;font-family:Arial,sans-serif;font-size:10pt;overflow-wrap:anywhere;word-break:break-word;${tag == 'th' ? 'background:#dedede;font-weight:bold;' : ''}';
        if (tag == 'th') {
          node.text = label;
        } else {
          if (label.isNotEmpty) {
            node.append(Element.tag('strong')..text = label);
            node.append(Element.tag('br'));
          }
          _appendLines(node, value);
        }
        tr.append(node);
      }
      table.append(tr);
    }

    String value(String key) => data[key]?.toString() ?? '';
    row([('th', 'Componente Curricular', '', 1), ('td', '', value('nome'), 4)]);
    row([
      ('th', 'Unidade Ofertante', '', 1),
      ('td', '', value('unidade_ofertante'), 4),
    ]);
    row([
      ('td', 'Código:', value('codigo'), 2),
      ('td', 'Período/Série:', value('periodo_serie'), 1),
      ('td', 'Turma:', value('turma'), 2),
    ]);
    row([('th', 'Carga Horária', '', 3), ('th', 'Natureza', '', 2)]);
    final nature = _norm(value('natureza'));
    row([
      ('td', 'Teórica:', value('carga_teorica'), 1),
      ('td', 'Prática:', value('carga_pratica'), 1),
      ('td', 'Total:', value('carga_total'), 1),
      ('td', 'Obrigatória:', nature == 'obrigatoria' ? '( X )' : '(   )', 1),
      ('td', 'Optativa:', nature == 'optativa' ? '( X )' : '(   )', 1),
    ]);
    row([
      ('td', 'Professor(a):', value('professor'), 3),
      ('td', 'Ano/Semestre:', value('ano_semestre'), 2),
    ]);
    row([('th', 'Observações', '', 1), ('td', '', value('observacoes'), 4)]);
    old.replaceWith(table);
    return true;
  }

  static bool _replacePrompt(
    DocumentFragment root,
    String prompt,
    String value,
  ) {
    final needle = _norm(prompt);
    final candidates = root
        .querySelectorAll('p,div,td,th,li')
        .where((node) => _norm(node.text).contains(needle))
        .toList();
    final targets = candidates
        .where(
          (node) => !candidates.any(
            (other) => other != node && _isDescendant(node, other),
          ),
        )
        .toList();
    if (targets.isEmpty) return false;
    final target = targets.first;
    if (target.localName == 'p') {
      final replacement = Element.tag('div');
      _appendLines(replacement, value);
      target.replaceWith(replacement);
    } else {
      target.nodes.clear();
      _appendLines(target, value);
    }
    return true;
  }

  static bool _hasSection(List<Element> nodes, int number, String name) =>
      _sectionIn(nodes, number, name) != null;
  static bool _sectionExists(DocumentFragment root, int number, String name) =>
      _section(root, number, name) != null;
  static Element? _section(DocumentFragment root, int number, String name) =>
      _sectionIn(
        root.querySelectorAll('table,p,h1,h2,h3,div,td,th,strong,b'),
        number,
        name,
      );
  static Element? _sectionIn(Iterable<Element> nodes, int number, String name) {
    final normalizedName = _norm(name);
    final expression = RegExp(
      '^$number\\s*\\.?\\s*${RegExp.escape(normalizedName)}(?:\\s|\$)',
    );
    final matches = nodes.where((node) {
      final text = _norm(node.text);
      return text.length <= 160 &&
          (expression.hasMatch(text) || text == normalizedName);
    }).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) => a.text.length.compareTo(b.text.length));
    var chosen = matches.first;
    if (chosen.localName == 'td' ||
        chosen.localName == 'th' ||
        chosen.localName == 'strong' ||
        chosen.localName == 'b') {
      chosen = chosen.parent ?? chosen;
    }
    final table = _ancestor(chosen, 'table');
    if (table != null && table.text.length <= 220) return table;
    return chosen;
  }

  static bool _insertAfterSection(
    DocumentFragment root,
    int n,
    String name,
    String value,
  ) {
    final anchor = _section(root, n, name);
    if (anchor == null) return false;
    _insertAfter(anchor, _content(value));
    return true;
  }

  static void _removeObjectivesBetween(
    DocumentFragment root,
    Element start,
    Element end,
  ) {
    final nodes = root.querySelectorAll('table').where((table) {
      final text = _norm(table.text);
      return text.length <= 1600 &&
          (text.contains('objetivo geral') ||
              text.contains('objetivos especificos')) &&
          _inDocumentRange(root, start, table, end);
    }).toList();
    for (final node in nodes) {
      node.remove();
    }
  }

  static bool _inDocumentRange(
    DocumentFragment root,
    Element start,
    Element candidate,
    Element end,
  ) {
    final all = root.querySelectorAll('*');
    final a = all.indexOf(start),
        c = all.indexOf(candidate),
        b = all.indexOf(end);
    return a >= 0 && c > a && b > c;
  }

  static Element _labelledContent(String label, String value) {
    final wrapper = Element.tag('div');
    wrapper.append(_paragraph(label, bold: true));
    _appendLines(wrapper, value);
    return wrapper;
  }

  static Element _content(String value) {
    final wrapper = Element.tag('div');
    _appendLines(wrapper, value);
    return wrapper;
  }

  static Element _paragraph(String value, {bool bold = false}) {
    final paragraph = Element.tag('p')
      ..attributes['style'] =
          'font-family:Arial,sans-serif;font-size:10.5pt;line-height:1.2;margin:3px 0 6px;text-align:justify;overflow-wrap:anywhere;';
    if (bold)
      paragraph.append(Element.tag('strong')..text = value);
    else
      paragraph.text = value;
    return paragraph;
  }

  static void _appendLines(Element parent, String value) {
    final lines = value
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .where((line) => line.trim().isNotEmpty);
    for (final line in lines) {
      parent.append(_paragraph(line.trim()));
    }
  }

  static void _insertAfter(Element anchor, Element node) {
    final parent = anchor.parent;
    if (parent == null) return;
    parent.nodes.insert(parent.nodes.indexOf(anchor) + 1, node);
  }

  static Element _nativeInsertionPoint(Element title) =>
      _ancestor(title, 'table') ?? title;

  static Element? _ancestor(Element node, String tag) {
    Element? current = node;
    while (current != null) {
      if (current.localName == tag) return current;
      current = current.parent;
    }
    return null;
  }

  static void _insertBefore(Element anchor, Element node) {
    final parent = anchor.parent;
    if (parent == null) return;
    parent.nodes.insert(parent.nodes.indexOf(anchor), node);
  }

  static Element _schedule(String title, List<Map<String, String>> rows) {
    final wrapper = Element.tag('div');
    wrapper.append(_scheduleLabel(title));
    final table = Element.tag('table')
      ..attributes['border'] = '1'
      ..attributes['style'] =
          'width:100%;border-collapse:collapse;table-layout:fixed;margin:3px 0 10px;font-family:Arial,sans-serif;font-size:9.5pt;';
    final colgroup = Element.tag('colgroup');
    for (final width in ['15%', '85%']) {
      colgroup.append(
        Element.tag('col')
          ..attributes['width'] = width
          ..attributes['style'] = 'width:$width;',
      );
    }
    table.append(colgroup);
    final thead = Element.tag('thead')
      ..attributes['style'] = 'display:table-header-group;';
    final header = Element.tag('tr');
    for (final (label, width) in [('Data', '15%'), ('Atividades', '85%')]) {
      header.append(
        Element.tag('th')
          ..attributes['width'] = width
          ..text = label
          ..attributes['style'] =
              'background:#eee;padding:5px;text-align:center;border:1px solid #777;width:$width;',
      );
    }
    thead.append(header);
    table.append(thead);
    final tbody = Element.tag('tbody');
    for (final row in rows) {
      final tr = Element.tag('tr')
        ..attributes['style'] = 'page-break-inside:avoid;';
      for (final (key, width) in [('data', '15%'), ('atividade', '85%')]) {
        tr.append(
          Element.tag('td')
            ..attributes['width'] = width
            ..text = (row[key] ?? '')
            ..attributes['style'] =
                'border:1px solid #777;padding:4px;vertical-align:top;overflow-wrap:anywhere;word-break:break-word;width:$width;',
        );
      }
      tbody.append(tr);
    }
    table.append(tbody);
    wrapper.append(table);
    return wrapper;
  }

  static Element _scheduleLabel(String text, {bool top = false}) {
    final label = Element.tag('p')
      ..attributes['style'] =
          'font-family:Arial,sans-serif;font-size:10.5pt;line-height:1.15;font-weight:bold;margin:${top ? '7px 0 4px' : '7px 0 4px'};text-align:left;'
      ..text = text;
    return label;
  }

  static void _validateScheduleRows(
    List<Map<String, String>> rows,
    String modality,
  ) {
    final datePattern = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$');
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final match = datePattern.firstMatch(row['data'] ?? '');
      final activity = row['atividade']?.trim() ?? '';
      if (match == null || activity.isEmpty) {
        throw StateError(
          'Aula ${index + 1} do cronograma $modality está sem data válida ou descrição. Nenhuma tabela foi criada.',
        );
      }
      final day = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final year = int.parse(match.group(3)!);
      final date = DateTime(year, month, day);
      if (date.day != day || date.month != month || date.year != year) {
        throw StateError(
          'A data ${row['data']} da aula ${index + 1} não existe. Nenhuma tabela foi criada.',
        );
      }
    }
  }

  static bool _replaceBibliography(
    DocumentFragment root,
    String title,
    String next,
    List<String> values,
  ) {
    final heading = _findTextNode(root, title);
    final end = _findTextNode(root, next);
    if (heading == null ||
        end == null ||
        heading.parent == null ||
        heading.parent != end.parent)
      return false;
    final siblings = heading.parent!.nodes;
    final startIndex = siblings.indexOf(heading),
        endIndex = siblings.indexOf(end);
    if (endIndex <= startIndex) return false;
    siblings.removeRange(startIndex + 1, endIndex);
    var insertion = startIndex + 1;
    for (final value in values.where((item) => item.trim().isNotEmpty)) {
      final p = _paragraph(value.trim());
      siblings.insert(insertion++, p);
    }
    return true;
  }

  static Element? _findTextNode(DocumentFragment root, String phrase) {
    final needle = _norm(phrase);
    final matches =
        root.querySelectorAll('p,div,td,th,h1,h2,h3,strong,b').where((node) {
          final text = _norm(node.text);
          return text.contains(needle) && text.length <= needle.length + 24;
        }).toList()..sort((a, b) => a.text.length.compareTo(b.text.length));
    if (matches.isEmpty) return null;
    var node = matches.first;
    if (['strong', 'b', 'td', 'th'].contains(node.localName))
      node = node.parent ?? node;
    return node;
  }

  static void _removeTemplateInstructions(DocumentFragment root) {
    const phrases = [
      'copiar da ficha de disciplina',
      'explicitar a importancia dos conteudos',
      'objetivos propostos',
      'programa organizado em unidades',
      'descrever a forma de organizacao',
      'descrever o tipo/modalidade de avaliacao',
      'instrumentos/formas a serem empregados',
      'deve-se seguir o art. 163',
      'sera utilizada no decorrer das aulas',
      'cada titulo citado deve ter um exemplar',
      'para enriquecimento dos estudos',
      'no minimo 3',
      'no minimo 5',
    ];
    final candidates = root.querySelectorAll('p,div,li').toList();
    for (final node in candidates) {
      final text = _norm(node.text);
      if (text.isNotEmpty &&
          phrases.any(text.contains) &&
          !candidates.any(
            (other) => other != node && _isDescendant(node, other),
          )) {
        node.remove();
      }
    }
  }

  static bool _isDescendant(Element ancestor, Element candidate) {
    Element? parent = candidate.parent;
    while (parent != null) {
      if (identical(parent, ancestor)) return true;
      parent = parent.parent;
    }
    return false;
  }

  static List<Map<String, String>> _rows(
    Map<String, dynamic> plan,
    String key,
  ) => (plan[key] as List? ?? [])
      .whereType<Map>()
      .map(
        (row) => {
          'data': row['data']?.toString() ?? '',
          'atividade': row['atividade']?.toString() ?? '',
        },
      )
      .toList();
  static List<String> _strings(Map<String, dynamic> plan, String key) =>
      (plan[key] as List? ?? []).map((item) => item.toString()).toList();
  static String _str(Map<String, dynamic> plan, String key) =>
      plan[key]?.toString() ?? '';
  static String _withLabel(String label, String value) =>
      value.trim().isEmpty ? '' : '$label\n$value';
  static String _norm(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[áàãâä]'), 'a')
      .replaceAll(RegExp(r'[éèêë]'), 'e')
      .replaceAll(RegExp(r'[íìîï]'), 'i')
      .replaceAll(RegExp(r'[óòôõö]'), 'o')
      .replaceAll(RegExp(r'[úùûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
