import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:xml/xml.dart';

/// Importa e preenche modelos de Plano de Trabalho sem automação externa.
/// Os arquivos XLSX são editados no pacote ZIP/XML para preservar fórmulas,
/// estilos, validações, imagens e demais componentes que o app não altera.
class PlanilhaTrabalhoService {
  static const _sections = <String, _SheetSpec>{
    'informacoes e resumo': _SheetSpec(
      'Informações e Resumo',
      {'A7': 'Docente:', 'A8': 'Unidade:', 'A9': 'Regime de trabalho:'},
      0,
      const {},
      {
        'B7': ('Docente', 'texto'),
        'B8': ('Unidade', 'texto'),
        'B9': ('Regime de trabalho', 'texto'),
      },
    ),
    'aulas': _SheetSpec(
      'Aulas',
      {
        'A12': 'Disciplina',
        'B12': 'Tipo',
        'C12': 'Aulas teóricas semanais por turma',
        'D12': 'Turmas teóricas',
        'E12': 'Aulas práticas semanais por turma',
        'F12': 'Turmas práticas',
        'I12': 'Carga horária atendimento',
        'P12': 'Carga horária preparação',
      },
      14,
      {
        'A': ('Disciplina', 'texto'),
        'B': ('Tipo', 'texto'),
        'C': ('Aulas teóricas por turma', 'numero'),
        'D': ('Turmas teóricas', 'numero'),
        'E': ('Aulas práticas por turma', 'numero'),
        'F': ('Turmas práticas', 'numero'),
        'I': ('Atendimento: horas', 'numero'),
        'K': ('Atendimento: minutos', 'numero'),
        'P': ('Preparação: horas', 'numero'),
        'R': ('Preparação: minutos', 'numero'),
      },
    ),
    'projetos de ensino': _SheetSpec(
      'Projetos de ensino',
      {
        'B1': 'Projetos de ensino',
        'A10': 'Descrição',
        'B10': 'Carga Horária estimada',
      },
      11,
      {
        'A': ('Projeto', 'texto'),
        'B': ('Horas', 'numero'),
        'D': ('Minutos', 'numero'),
      },
    ),
    'orientacoes': _SheetSpec(
      'Orientações',
      {
        'A10': 'Orientação/Supervisão',
        'B10': 'Observação/Especificação',
        'C10': 'Qtde prevista',
        'D10': 'Carga Horária\npor orientação',
      },
      11,
      {
        'A': ('Tipo', 'texto'),
        'B': ('Especificação', 'texto'),
        'C': ('Quantidade', 'numero'),
        'D': ('Horas', 'numero'),
        'F': ('Minutos', 'numero'),
      },
    ),
    'pesquisa': _SheetSpec(
      'Pesquisa',
      {
        'B1': 'Atividades de Pesquisa',
        'A10': 'Descrição',
        'B10': 'Carga Horária estimada',
      },
      11,
      {
        'A': ('Pesquisa', 'texto'),
        'B': ('Horas', 'numero'),
        'D': ('Minutos', 'numero'),
      },
    ),
    'extensao': _SheetSpec(
      'Extensão',
      {
        'B1': 'Atividades de Extensão',
        'A10': 'Descrição da atividade',
        'B10': 'Carga Horária estimada',
      },
      11,
      {
        'A': ('Atividade', 'texto'),
        'B': ('Horas', 'numero'),
        'D': ('Minutos', 'numero'),
      },
    ),
    'gestao': _SheetSpec(
      'Gestão',
      {
        'D1': 'Atividades de Gestão',
        'A11': 'Tipo',
        'C11': 'Especificação',
        'D11': 'Carga Horária',
      },
      12,
      {
        'A': ('Tipo', 'texto'),
        'C': ('Especificação', 'texto'),
        'D': ('Horas', 'numero'),
        'F': ('Minutos', 'numero'),
      },
    ),
    'outras': _SheetSpec(
      'Outras',
      {
        'B1': 'Outras atividades',
        'A12': 'Descrição',
        'D12': 'Carga Horária estimada',
      },
      13,
      {
        'A': ('Atividade', 'texto'),
        'D': ('Horas', 'numero'),
        'F': ('Minutos', 'numero'),
      },
    ),
    'afastamentos': _SheetSpec(
      'Afastamentos',
      {'C1': 'Afastamentos/Licenças', 'A11': 'Tipo', 'B11': 'Período'},
      12,
      {
        'A': ('Tipo', 'texto'),
        'B': ('Início', 'data'),
        'D': ('Fim', 'data'),
        'E': ('Horas', 'numero'),
        'G': ('Minutos', 'numero'),
      },
    ),
    'remuneradas': _SheetSpec(
      'Remuneradas',
      {'A7': 'Descrição', 'B7': 'Local', 'C7': 'Horários'},
      7,
      {
        'A': ('Atividade', 'texto'),
        'B': ('Local', 'texto'),
        'C': ('Horários', 'texto'),
      },
    ),
    'observacoes': _SheetSpec(
      'Observações',
      {'C1': 'Observações'},
      0,
      const {},
      {'A5': ('Observações', 'texto')},
    ),
  };

  Map<String, dynamic> capture(String path) {
    final workbook = _open(path);
    final sheets = _validatedSheets(workbook);
    final fields = <Map<String, dynamic>>[];
    final formulas = <String>[];
    for (final entry in _sections.entries) {
      final section = entry.key;
      final spec = entry.value;
      final sheet = sheets[section]!;
      for (final fixed in spec.fixed.entries) {
        _captureCell(
          sheet,
          section,
          spec,
          fixed.key,
          fixed.value.$1,
          fixed.value.$2,
          fields,
          formulas,
        );
      }
      for (var row = spec.startRow; row < sheet.maxRows; row++) {
        for (final column in spec.columns.entries) {
          final address = '${column.key}${row + 1}';
          final cell = sheet.cell(CellIndex.indexByString(address));
          if (cell.value == null && cell.cellStyle == null) continue;
          _captureCell(
            sheet,
            section,
            spec,
            address,
            '${column.value.$1} — linha ${row - spec.startRow + 1}',
            column.value.$2,
            fields,
            formulas,
          );
        }
      }
    }
    return {
      'version': 1,
      'origin': File(path).uri.pathSegments.last,
      'fields': fields,
      'ignoredFormulas': formulas,
    };
  }

  List<Map<String, dynamic>> newFields(
    Map<String, dynamic> stored,
    String templatePath,
  ) {
    final fresh = capture(templatePath);
    final existing = (stored['fields'] as List? ?? [])
        .whereType<Map>()
        .map((field) => '${field['section']}!${field['cell']}')
        .toSet();
    return (fresh['fields'] as List)
        .whereType<Map>()
        .where(
          (field) => !existing.contains('${field['section']}!${field['cell']}'),
        )
        .map((field) => Map<String, dynamic>.from(field)..['value'] = null)
        .toList();
  }

  List<Map<String, dynamic>> preview(Map<String, dynamic> stored, String path) {
    final workbook = _open(path);
    final sheets = _validatedSheets(workbook);
    final rules = _WorkbookRules.load(path, workbook);
    final result = <Map<String, dynamic>>[];
    for (final raw in stored['fields'] as List? ?? []) {
      if (raw is! Map) continue;
      final field = Map<String, dynamic>.from(raw);
      final value = field['value'];
      if (value == null || value == '') continue;
      final section = field['section'] as String;
      final address = field['cell'] as String;
      final spec = _sections[section];
      final sheet = sheets[section];
      if (spec == null || sheet == null || !_isAllowedCell(spec, address)) {
        throw FormatException(
          'O campo ${field['sheet']}!$address não pertence ao modelo reconhecido.',
        );
      }
      final cell = sheet.cell(CellIndex.indexByString(address));
      if (cell.value is FormulaCellValue) {
        throw FormatException(
          'O campo ${field['sheet']}!$address contém fórmula e não pode ser substituído.',
        );
      }
      _validateValue(
        value,
        field['type'] as String,
        field['sheet'] as String,
        address,
      );
      rules.validate(section, address, field['type'] as String, value);
      final current = _readValue(cell.value, field['type'] as String);
      result.add({...field, 'current': current});
    }
    if (result.isEmpty)
      throw const FormatException(
        'Não há valores preenchidos para transferir.',
      );
    return result;
  }

  Future<List<Map<String, dynamic>>> fillCopy({
    required String sourcePath,
    required String destinationPath,
    required Map<String, dynamic> data,
  }) async {
    final source = File(sourcePath);
    final destination = File(destinationPath);
    if (pSame(sourcePath, destinationPath)) {
      throw const FormatException(
        'Escolha outro nome: a planilha original será preservada.',
      );
    }
    final extension = _extension(sourcePath);
    if (!{'.xlsx', '.xlsm'}.contains(extension) ||
        _extension(destinationPath) != extension) {
      throw const FormatException(
        'A cópia deve manter a extensão .xlsx ou .xlsm do modelo.',
      );
    }
    final original = await source.readAsBytes();
    final decoded = ZipDecoder().decodeBytes(original);
    if (decoded.files.any((file) => file.name.startsWith('_xmlsignatures/'))) {
      throw const FormatException(
        'A planilha tem assinatura digital; use uma cópia de modelo sem assinatura.',
      );
    }
    final operations = preview(data, sourcePath);
    final workbookFile = decoded.findFile('xl/workbook.xml');
    final relsFile = decoded.findFile('xl/_rels/workbook.xml.rels');
    if (workbookFile == null || relsFile == null)
      throw const FormatException('Estrutura XLSX inválida.');
    final workbookDoc = XmlDocument.parse(
      utf8.decode(workbookFile.content as List<int>),
    );
    final relsDoc = XmlDocument.parse(
      utf8.decode(relsFile.content as List<int>),
    );
    final relationshipById = <String, String>{};
    for (final relationship in relsDoc.findAllElements('Relationship')) {
      relationshipById[relationship.getAttribute('Id') ?? ''] =
          relationship.getAttribute('Target') ?? '';
    }
    final sheetPaths = <String, String>{};
    for (final sheet in workbookDoc.findAllElements('sheet')) {
      final relation = sheet.attributes
          .where((attribute) => attribute.name.local == 'id')
          .map((attribute) => attribute.value)
          .firstOrNull;
      final target = relationshipById[relation] ?? '';
      if (target.isEmpty) continue;
      final normalizedTarget = target.startsWith('/')
          ? target.substring(1)
          : 'xl/$target';
      sheetPaths[_normalize(sheet.getAttribute('name') ?? '')] =
          _normalizeZipPath(normalizedTarget);
    }
    final bySheet = <String, List<Map<String, dynamic>>>{};
    for (final operation in operations) {
      final section = operation['section'] as String;
      final path = sheetPaths[section];
      if (path == null)
        throw FormatException(
          'A aba ${operation['sheet']} não foi localizada no arquivo.',
        );
      (bySheet[path] ??= []).add(operation);
    }
    for (final entry in bySheet.entries) {
      final archiveFile = decoded.findFile(entry.key);
      if (archiveFile == null)
        throw FormatException('A aba ${entry.key} está ausente no arquivo.');
      final document = XmlDocument.parse(
        utf8.decode(archiveFile.content as List<int>),
      );
      for (final operation in entry.value) {
        _writeCell(
          document,
          operation['cell'] as String,
          operation['value'],
          operation['type'] as String,
        );
      }
      _replaceArchiveFile(
        decoded,
        entry.key,
        utf8.encode(document.toXmlString()),
      );
    }
    var calcPr = workbookDoc.findAllElements('calcPr').firstOrNull;
    if (calcPr == null) {
      calcPr = XmlElement(XmlName('calcPr'));
      workbookDoc.rootElement.children.add(calcPr);
    }
    calcPr
      ..setAttribute('calcMode', 'auto')
      ..setAttribute('fullCalcOnLoad', '1')
      ..setAttribute('forceFullCalc', '1');
    _replaceArchiveFile(
      decoded,
      'xl/workbook.xml',
      utf8.encode(workbookDoc.toXmlString()),
    );
    final bytes = ZipEncoder().encode(decoded);
    if (bytes == null)
      throw const FormatException(
        'Não foi possível gerar a cópia da planilha.',
      );
    await destination.writeAsBytes(bytes, flush: true);
    return operations;
  }

  String displayValue(Object? value, String type) {
    if (value == null || value == '') return '';
    if (type == 'data') {
      final date = DateTime.tryParse(value.toString());
      if (date == null) return value.toString();
      return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    }
    return value.toString();
  }

  dynamic parseValue(String text, String type) {
    final value = text.trim();
    if (value.isEmpty) return null;
    if (type == 'numero') {
      final parsed = double.tryParse(value.replaceAll(',', '.'));
      if (parsed == null || parsed < 0 || parsed >= 1000000) {
        throw const FormatException('Informe um número entre 0 e 999999.');
      }
      return parsed == parsed.roundToDouble() ? parsed.toInt() : parsed;
    }
    if (type == 'data') {
      final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(value);
      if (match == null)
        throw const FormatException('Informe a data no formato DD/MM/AAAA.');
      final date = DateTime(
        int.parse(match[3]!),
        int.parse(match[2]!),
        int.parse(match[1]!),
      );
      if (date.day != int.parse(match[1]!) ||
          date.month != int.parse(match[2]!)) {
        throw const FormatException('Informe uma data válida.');
      }
      return date.toIso8601String();
    }
    return value;
  }

  void _captureCell(
    Sheet sheet,
    String section,
    _SheetSpec spec,
    String address,
    String label,
    String type,
    List<Map<String, dynamic>> fields,
    List<String> formulas,
  ) {
    final cell = sheet.cell(CellIndex.indexByString(address));
    if (cell.value is FormulaCellValue) {
      formulas.add('${sheet.sheetName}!$address');
      return;
    }
    fields.add({
      'section': section,
      'sheet': sheet.sheetName,
      'cell': address,
      'label': label,
      'type': type,
      'value': _readValue(cell.value, type),
    });
  }

  Excel _open(String path) {
    final file = File(path);
    if (!file.existsSync() || !{'.xlsx', '.xlsm'}.contains(_extension(path))) {
      throw const FormatException(
        'Selecione uma planilha Excel .xlsx ou .xlsm existente.',
      );
    }
    final workbook = Excel.decodeBytes(file.readAsBytesSync());
    _validatedSheets(workbook);
    return workbook;
  }

  Map<String, Sheet> _validatedSheets(Excel workbook) {
    final sheets = <String, Sheet>{};
    for (final entry in workbook.tables.entries) {
      final key = _normalize(entry.key);
      if (_sections.containsKey(key)) sheets[key] = entry.value;
    }
    final missing = _sections.keys
        .where((key) => !sheets.containsKey(key))
        .toList();
    if (missing.isNotEmpty) {
      throw FormatException(
        'O modelo não contém as abas esperadas: ${missing.map((key) => _sections[key]!.name).join(', ')}.',
      );
    }
    for (final entry in _sections.entries) {
      final sheet = sheets[entry.key]!;
      if (sheet.maxRows > 2000)
        throw FormatException(
          'A aba ${sheet.sheetName} excede o limite reconhecido.',
        );
      for (final anchor in entry.value.anchors.entries) {
        final cell = sheet.cell(CellIndex.indexByString(anchor.key));
        if (_normalize(_readValue(cell.value, 'texto')?.toString() ?? '') !=
            _normalize(anchor.value)) {
          throw FormatException(
            'O modelo mudou em ${sheet.sheetName}!${anchor.key}; confira o cabeçalho antes de gravar.',
          );
        }
      }
    }
    return sheets;
  }

  Object? _readValue(CellValue? value, String type) {
    if (value == null || value is FormulaCellValue) return null;
    if (value is DateCellValue)
      return value.asDateTimeLocal().toIso8601String();
    if (value is IntCellValue) return value.value;
    if (value is DoubleCellValue) return value.value;
    if (value is TextCellValue) return value.value.toString();
    if (value is BoolCellValue) return value.value;
    return value.toString();
  }

  bool _isAllowedCell(_SheetSpec spec, String address) {
    if (spec.fixed.containsKey(address)) return true;
    final match = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(address);
    return match != null &&
        spec.columns.containsKey(match[1]) &&
        int.parse(match[2]!) > spec.startRow;
  }

  void _validateValue(Object value, String type, String sheet, String address) {
    if (type == 'numero' && (value is! num || value < 0 || value >= 1000000)) {
      throw FormatException(
        '$sheet!$address deve ser um número de 0 a 999999.',
      );
    }
    if (type == 'texto' && value is! String) {
      throw FormatException('$sheet!$address deve conter texto.');
    }
    if (type == 'data' && DateTime.tryParse(value.toString()) == null) {
      throw FormatException('$sheet!$address contém uma data inválida.');
    }
  }

  void _writeCell(
    XmlDocument document,
    String address,
    Object? value,
    String type,
  ) {
    final root = document.rootElement;
    final sheetData = root.findElements('sheetData').firstOrNull;
    if (sheetData == null)
      throw const FormatException('A planilha não contém sheetData.');
    final coords = _cellCoordinates(address);
    final rowNumber = coords.$2;
    var row = sheetData
        .findElements('row')
        .where((item) => item.getAttribute('r') == '$rowNumber')
        .firstOrNull;
    if (row == null) {
      row = XmlElement(XmlName('row'), [
        XmlAttribute(XmlName('r'), '$rowNumber'),
      ]);
      final nextRow = sheetData
          .findElements('row')
          .where(
            (item) =>
                int.tryParse(item.getAttribute('r') ?? '') != null &&
                int.parse(item.getAttribute('r')!) > rowNumber,
          )
          .firstOrNull;
      if (nextRow == null) {
        sheetData.children.add(row);
      } else {
        sheetData.children.insert(sheetData.children.indexOf(nextRow), row);
      }
    }
    var cell = row
        .findElements('c')
        .where((item) => item.getAttribute('r') == address)
        .firstOrNull;
    if (cell == null) {
      cell = XmlElement(XmlName('c'), [XmlAttribute(XmlName('r'), address)]);
      final nextCell = row
          .findElements('c')
          .where(
            (item) =>
                _cellCoordinates(item.getAttribute('r') ?? 'A1').$1 > coords.$1,
          )
          .firstOrNull;
      if (nextCell == null) {
        row.children.add(cell);
      } else {
        row.children.insert(row.children.indexOf(nextCell), cell);
      }
    }
    if (cell.findElements('f').isNotEmpty)
      throw FormatException(
        'O campo $address contém fórmula e não será sobrescrito.',
      );
    cell.children.clear();
    cell.attributes.removeWhere(
      (attribute) => attribute.name.local != 'r' && attribute.name.local != 's',
    );
    if (value == null || value == '') return;
    if (type == 'data') {
      final date = DateTime.parse(value.toString());
      final serial = date.difference(DateTime(1899, 12, 30)).inDays;
      cell.children.add(XmlElement(XmlName('v'), [], [XmlText('$serial')]));
      return;
    }
    if (type == 'numero') {
      cell.children.add(XmlElement(XmlName('v'), [], [XmlText('$value')]));
      return;
    }
    cell.attributes.add(XmlAttribute(XmlName('t'), 'inlineStr'));
    cell.children.add(
      XmlElement(XmlName('is'), [], [
        XmlElement(
          XmlName('t'),
          [
            XmlAttribute(
              XmlName('space', 'http://www.w3.org/XML/1998/namespace'),
              'preserve',
            ),
          ],
          [XmlText(value.toString())],
        ),
      ]),
    );
  }

  void _replaceArchiveFile(Archive archive, String path, List<int> bytes) {
    final old = archive.findFile(path);
    if (old != null) archive.removeFile(old);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  (int, int) _cellCoordinates(String address) {
    final match = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(address);
    if (match == null)
      throw FormatException('Referência de célula inválida: $address');
    var column = 0;
    for (final rune in match[1]!.codeUnits) {
      column = column * 26 + rune - 64;
    }
    return (column, int.parse(match[2]!));
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('ç', 'c')
      .replaceAll(RegExp('[áàãâä]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[íìîï]'), 'i')
      .replaceAll(RegExp('[óòõôö]'), 'o')
      .replaceAll(RegExp('[úùûü]'), 'u')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _normalizeZipPath(String path) {
    final parts = <String>[];
    for (final part in path.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  String _extension(String path) =>
      path.substring(path.lastIndexOf('.')).toLowerCase();
  bool pSame(String left, String right) =>
      File(left).absolute.path.toLowerCase() ==
      File(right).absolute.path.toLowerCase();
}

class _SheetSpec {
  const _SheetSpec(
    this.name,
    this.anchors,
    this.startRow,
    this.columns, [
    this.fixed = const {},
  ]);
  final String name;
  final Map<String, String> anchors;
  final int startRow;
  final Map<String, (String, String)> columns;
  final Map<String, (String, String)> fixed;
}

class _WorkbookRules {
  _WorkbookRules(
    this._archive,
    this._sheetPaths,
    this._definedNames,
    this._workbook,
  );

  final Archive _archive;
  final Map<String, String> _sheetPaths;
  final Map<String, String> _definedNames;
  final Excel _workbook;
  final Map<String, XmlDocument> _sheetDocuments = {};

  static _WorkbookRules load(String path, Excel workbook) {
    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    final workbookXml = _xml(archive, 'xl/workbook.xml');
    final relationsXml = _xml(archive, 'xl/_rels/workbook.xml.rels');
    final relations = <String, String>{};
    for (final relation in relationsXml.findAllElements('Relationship')) {
      relations[relation.getAttribute('Id') ?? ''] =
          relation.getAttribute('Target') ?? '';
    }
    final paths = <String, String>{};
    for (final sheet in workbookXml.findAllElements('sheet')) {
      final relationId = sheet.attributes
          .where((attribute) => attribute.name.local == 'id')
          .map((attribute) => attribute.value)
          .firstOrNull;
      final target = relations[relationId] ?? '';
      if (target.isEmpty) continue;
      final path = target.startsWith('/') ? target.substring(1) : 'xl/$target';
      paths[_norm(sheet.getAttribute('name') ?? '')] = _normalizePath(path);
    }
    final names = <String, String>{};
    for (final element in workbookXml.findAllElements('definedName')) {
      final name = element.getAttribute('name');
      if (name != null) names[name] = element.innerText.trim();
    }
    return _WorkbookRules(archive, paths, names, workbook);
  }

  void validate(String section, String address, String type, Object value) {
    final requiredList = _listName(section, address);
    if (requiredList != null) _validateNamedList(requiredList, value);
    if (type == 'numero') _validateNumber(section, address, value as num);
  }

  void _validateNamedList(String listName, Object value) {
    final formula = _definedNames[listName];
    if (formula == null) {
      throw FormatException(
        'Não encontrei a lista "$listName" exigida pelo modelo.',
      );
    }
    final expression = formula.startsWith('=') ? formula.substring(1) : formula;
    final range = RegExp(
      r"^(?:'([^']+)'|([^!]+))!\$?([A-Z]+)\$?(\d+)(?::\$?([A-Z]+)\$?(\d+))?$",
    ).firstMatch(expression);
    final values = <String>[];
    if (range != null) {
      final sheetName = _norm(range[1] ?? range[2] ?? '');
      final sheet = _workbook.tables.entries
          .where((entry) => _norm(entry.key) == sheetName)
          .map((entry) => entry.value)
          .firstOrNull;
      if (sheet == null) {
        throw FormatException(
          'Não foi possível abrir a aba da lista "$listName".',
        );
      }
      final first = _coordinates('${range[3]}${range[4]}');
      final last = _coordinates(
        '${range[5] ?? range[3]}${range[6] ?? range[4]}',
      );
      for (var row = first.$2; row <= last.$2; row++) {
        for (var column = first.$1; column <= last.$1; column++) {
          final cell = sheet.cell(
            CellIndex.indexByColumnRow(
              columnIndex: column - 1,
              rowIndex: row - 1,
            ),
          );
          final text = _cellText(cell.value).trim();
          if (text.isNotEmpty) values.add(text);
        }
      }
    } else {
      final constant = RegExp(r'^"(.*)"$').firstMatch(expression);
      if (constant == null) {
        throw FormatException(
          'Não foi possível ler os valores da lista "$listName".',
        );
      }
      values.addAll(constant[1]!.split(',').map((item) => item.trim()));
    }
    if (!values.contains(value.toString().trim())) {
      throw FormatException(
        'O valor "$value" não consta na lista "$listName" do modelo.',
      );
    }
  }

  void _validateNumber(String section, String address, num value) {
    final path = _sheetPaths[section];
    if (path == null) return;
    final document = _sheetDocuments.putIfAbsent(
      path,
      () => _xml(_archive, path),
    );
    for (final rule in document.findAllElements('dataValidation')) {
      final kind = rule.getAttribute('type');
      if (kind != 'whole' && kind != 'decimal') continue;
      if (!_containsCell(rule.getAttribute('sqref') ?? '', address)) continue;
      if (kind == 'whole' && value.toDouble() != value.toInt()) {
        throw FormatException(
          'O campo $section!$address aceita somente números inteiros.',
        );
      }
      final first = double.tryParse(
        rule.findElements('formula1').firstOrNull?.innerText.trim() ?? '',
      );
      final second = double.tryParse(
        rule.findElements('formula2').firstOrNull?.innerText.trim() ?? '',
      );
      final operator = rule.getAttribute('operator') ?? 'between';
      bool valid;
      switch (operator) {
        case 'between':
          if (first == null || second == null)
            throw FormatException(
              'Não foi possível conferir os limites de $section!$address.',
            );
          valid = value >= first && value <= second;
        case 'notBetween':
          if (first == null || second == null)
            throw FormatException(
              'Não foi possível conferir os limites de $section!$address.',
            );
          valid = value < first || value > second;
        case 'equal':
          valid = first != null && value == first;
        case 'notEqual':
          valid = first != null && value != first;
        case 'greaterThan':
          valid = first != null && value > first;
        case 'lessThan':
          valid = first != null && value < first;
        case 'greaterThanOrEqual':
          valid = first != null && value >= first;
        case 'lessThanOrEqual':
          valid = first != null && value <= first;
        default:
          throw FormatException(
            'Regra numérica desconhecida em $section!$address.',
          );
      }
      if (!valid)
        throw FormatException(
          'O valor $value não atende à validação de $section!$address.',
        );
    }
  }

  static XmlDocument _xml(Archive archive, String path) {
    final file = archive.findFile(path);
    if (file == null)
      throw FormatException('Arquivo XLSX inválido: $path não encontrado.');
    return XmlDocument.parse(utf8.decode(file.content as List<int>));
  }

  static String? _listName(String section, String address) {
    const lists = <String, Map<String, String>>{
      'informacoes e resumo': {'B9': 'Regimes'},
      'aulas': {'B': 'Disciplinas'},
      'orientacoes': {'A': 'Orientação_Tipo'},
      'gestao': {'A': 'Gestão'},
      'afastamentos': {'A': 'Afastamentos'},
    };
    final values = lists[section];
    if (values == null) return null;
    final column = RegExp(r'^([A-Z]+)').firstMatch(address)?.group(1);
    return values[address] ?? (column == null ? null : values[column]);
  }

  static String _cellText(CellValue? value) {
    if (value is TextCellValue) return value.value.toString();
    if (value == null || value is FormulaCellValue) return '';
    return value.toString();
  }

  static (int, int) _coordinates(String address) {
    final match = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(address);
    if (match == null)
      throw FormatException('Referência de célula inválida: $address');
    var column = 0;
    for (final unit in match[1]!.codeUnits) column = column * 26 + unit - 64;
    return (column, int.parse(match[2]!));
  }

  static bool _containsCell(String ranges, String address) {
    final target = _coordinates(address);
    for (final range in ranges.split(RegExp(r'\s+'))) {
      final bounds = range.split(':');
      if (bounds.isEmpty) continue;
      final start = _coordinates(bounds.first.replaceAll(r'$', ''));
      final end = _coordinates(
        (bounds.length > 1 ? bounds.last : bounds.first).replaceAll(r'$', ''),
      );
      if (target.$1 >= start.$1 &&
          target.$1 <= end.$1 &&
          target.$2 >= start.$2 &&
          target.$2 <= end.$2)
        return true;
    }
    return false;
  }

  static String _normalizePath(String path) {
    final pieces = <String>[];
    for (final piece in path.replaceAll('\\', '/').split('/')) {
      if (piece.isEmpty || piece == '.') continue;
      if (piece == '..') {
        if (pieces.isNotEmpty) pieces.removeLast();
      } else {
        pieces.add(piece);
      }
    }
    return pieces.join('/');
  }

  static String _norm(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[áàãâä]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[íìîï]'), 'i')
      .replaceAll(RegExp('[óòõôö]'), 'o')
      .replaceAll(RegExp('[úùûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
