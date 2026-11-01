import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';
import 'package:config_moodle/core/utils/text_encoding.dart';

const _plansKey = 'gestor_ufu_planos_ensino_v1';

class PlanosEnsinoService {
  Future<List<Map<String, dynamic>>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_plansKey);
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  Future<void> save(Map<String, dynamic> plan) async {
    final plans = await list();
    final index = plans.indexWhere((item) => item['id'] == plan['id']);
    final copy = Map<String, dynamic>.from(plan);
    copy['updatedAt'] = DateTime.now().toIso8601String();
    if (index < 0) {
      plans.add(copy);
    } else {
      plans[index] = copy;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_plansKey, jsonEncode(plans));
  }

  Future<void> remove(String id) async {
    final plans = await list();
    plans.removeWhere((plan) => plan['id'] == id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_plansKey, jsonEncode(plans));
  }

  Map<String, dynamic> emptyPlan(String id) => {
    'id': id,
    'updatedAt': DateTime.now().toIso8601String(),
    'identificacao': <String, dynamic>{
      'nome': '',
      'unidade_ofertante': 'Faculdade de Engenharia Elétrica',
      'codigo': '',
      'periodo_serie': '',
      'turma': '',
      'carga_teorica': '',
      'carga_pratica': '',
      'carga_total': '',
      'natureza': 'Obrigatória',
      'professor': '',
      'ano_semestre': '',
      'observacoes': '',
    },
    'ementa': '',
    'justificativa': '',
    'objetivo_geral': '',
    'objetivos_especificos': '',
    'programa_teorico': '',
    'programa_pratico': '',
    'metodologia_tecnicas': '',
    'metodologia_recursos': '',
    'metodologia_audiovisuais': '',
    'cronograma_teorico': <Map<String, String>>[],
    'cronograma_pratico': <Map<String, String>>[],
    'avaliacao_geral': '',
    'avaliacao_provas': '',
    'horario_atendimento': '',
    'atividade_recuperacao': '',
    'atendimento_especial': '',
    'bibliografia_basica': <String>[],
    'bibliografia_complementar': <String>[],
  };

  Map<String, dynamic> normalize(Map<String, dynamic> input, String id) {
    final plan = emptyPlan(id)..addAll(input);
    final ident = Map<String, dynamic>.from(
      plan['identificacao'] as Map? ?? {},
    );
    final defaults = Map<String, dynamic>.from(
      emptyPlan(id)['identificacao'] as Map,
    );
    plan['identificacao'] = {...defaults, ...ident};
    for (final key in ['cronograma_teorico', 'cronograma_pratico']) {
      plan[key] = (plan[key] as List? ?? [])
          .whereType<Map>()
          .map(
            (row) => {
              'data': row['data'].toString(),
              'atividade': row['atividade'].toString(),
            },
          )
          .toList();
    }
    for (final key in ['bibliografia_basica', 'bibliografia_complementar']) {
      plan[key] = (plan[key] as List? ?? [])
          .map((item) => item.toString())
          .toList();
    }
    return plan;
  }

  static Map<String, dynamic> applyPastedSchedule(
    Map<String, dynamic> plan,
    String text,
  ) {
    final lines = text.trim().split(RegExp(r'\r?\n'));
    if (lines.length < 2)
      throw const FormatException('Cole a tabela com cabeçalhos e aulas.');
    final headers = lines.first.split('\t').map(_normalize).toList();
    final dateCol = headers.indexOf('data');
    final modalityCol = headers.indexOf('modalidade');
    if (dateCol < 0 || modalityCol < 0) {
      throw const FormatException(
        'A tabela precisa conter as colunas Data e Modalidade.',
      );
    }
    final subjectCol = headers.indexWhere(
      (value) =>
          value.contains('materia lecionada') ||
          value == 'materia' ||
          value == 'conteudo',
    );
    final activityCol = headers.indexWhere(
      (value) => value == 'atividades' || value == 'atividade',
    );
    final moodleCol = headers.indexWhere(
      (value) => value.contains('moodle') && value.contains('descri'),
    );
    final theory = <Map<String, String>>[];
    final practice = <Map<String, String>>[];
    final descriptions = <String>[];
    for (final line in lines.skip(1)) {
      final cells = line.split('\t');
      String cell(int index) =>
          index >= 0 && index < cells.length ? cells[index].trim() : '';
      final rowDate = _parseScheduleDate(cell(dateCol));
      final rowModality = _scheduleModality(cell(modalityCol));
      final activityText = cell(activityCol);
      final candidates = activityText
          .split(RegExp(r'\s*[|\n]\s*'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      if (candidates.isEmpty) {
        final subject = cell(subjectCol);
        final normalizedSubject = _normalize(subject);
        if (subject.isNotEmpty &&
            !_isScheduleBlock(normalizedSubject) &&
            (_scheduleModality(subject) != null ||
                (rowModality != null && rowDate != null))) {
          candidates.add(subject);
        }
      }
      for (final candidate in candidates) {
        final modality =
            _scheduleModality(candidate) ??
            (candidates.length == 1 ? rowModality : null);
        if (modality == null) continue;
        final embeddedDate = _dateInsideScheduleActivity(candidate);
        final date = embeddedDate ?? rowDate;
        if (date == null) continue;
        final activity = _cleanScheduleActivity(candidate);
        if (activity.isEmpty || _isScheduleBlock(_normalize(activity)))
          continue;
        final row = {'data': date, 'atividade': activity};
        (modality == 'T' ? theory : practice).add(row);
      }
      if (cell(moodleCol).isNotEmpty) descriptions.add(cell(moodleCol));
    }
    _sortAndDeduplicateSchedule(theory);
    _sortAndDeduplicateSchedule(practice);
    if (theory.isEmpty && practice.isEmpty) {
      throw const FormatException(
        'Nenhuma aula teórica/prática com data válida foi encontrada.',
      );
    }
    final updated = Map<String, dynamic>.from(plan);
    updated['cronograma_teorico'] = theory;
    updated['cronograma_pratico'] = practice;
    final joined = descriptions.join('\n');
    final index = _normalize(joined).indexOf('quanto as provas');
    if (index >= 0)
      updated['avaliacao_provas'] = joined.substring(index).trim();
    return updated;
  }

  static String? _scheduleModality(String value) {
    final normalized = _normalize(value);
    if (normalized.contains('teor') ||
        RegExp(r'^\s*(?:aula\s+)?t(?:\s|[-:]|$)').hasMatch(normalized)) {
      return 'T';
    }
    if (normalized.contains('prat') ||
        RegExp(r'^\s*(?:aula\s+)?p(?:\s|[-:]|$)').hasMatch(normalized)) {
      return 'P';
    }
    return null;
  }

  static String? _parseScheduleDate(String value) {
    final match = RegExp(
      r'^(\d{1,2})/(\d{1,2})/(\d{4})$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final year = int.parse(match.group(3)!);
    final date = DateTime(year, month, day);
    if (date.day != day || date.month != month || date.year != year) {
      return null;
    }
    return '${day.toString().padLeft(2, '0')}/${month.toString().padLeft(2, '0')}/$year';
  }

  static String? _dateInsideScheduleActivity(String value) {
    final normalized = _normalize(value);
    if (!normalized.contains('realizar-se-a')) return null;
    final match = RegExp(
      r'realizar-se-a\s*:\s*(\d{1,2}/\d{1,2}/\d{4})',
    ).firstMatch(normalized);
    return match == null ? null : _parseScheduleDate(match.group(1)!);
  }

  static String _cleanScheduleActivity(String value) {
    var activity = repairMojibake(value.trim());
    activity = activity.replaceFirst(
      RegExp(r'\s*\([^)]*realizar-se-.[^)]*\)\.?\s*$', caseSensitive: false),
      '',
    );
    activity = activity.replaceFirst(
      RegExp(r'\s*[-–—]?\s*realizar-se-.:.*$', caseSensitive: false),
      '',
    );
    final separator = activity.indexOf(':');
    if (separator >= 0 &&
        _scheduleModality(activity.substring(0, separator)) != null) {
      activity = activity.substring(separator + 1);
    }
    return activity
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.\s]+$'), '')
        .trim();
  }

  static bool _isScheduleBlock(String normalized) =>
      normalized.startsWith('bloco ') ||
      normalized.startsWith('semana ') ||
      normalized.startsWith('horario de ') ||
      normalized.startsWith('sem aula') ||
      normalized.startsWith('feriado');

  static void _sortAndDeduplicateSchedule(List<Map<String, String>> rows) {
    final unique = <String, Map<String, String>>{};
    for (final row in rows) {
      unique['${row['data']}\u0000${_normalize(row['atividade']!)}'] = row;
    }
    rows
      ..clear()
      ..addAll(unique.values)
      ..sort((a, b) {
        final dateA = _parseScheduleDate(a['data']!)!;
        final dateB = _parseScheduleDate(b['data']!)!;
        final partsA = dateA.split('/').map(int.parse).toList();
        final partsB = dateB.split('/').map(int.parse).toList();
        final order = DateTime(
          partsA[2],
          partsA[1],
          partsA[0],
        ).compareTo(DateTime(partsB[2], partsB[1], partsB[0]));
        return order != 0 ? order : a['atividade']!.compareTo(b['atividade']!);
      });
  }

  static List<String> missingFields(Map<String, dynamic> plan) {
    final missing = <String>[];
    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    const identity = <String, String>{
      'nome': 'Componente curricular',
      'codigo': 'Código',
      'unidade_ofertante': 'Unidade ofertante',
      'periodo_serie': 'Período/Série',
      'turma': 'Turma',
      'carga_teorica': 'Carga horária teórica',
      'carga_pratica': 'Carga horária prática',
      'carga_total': 'Carga horária total',
      'professor': 'Professor(a)',
      'ano_semestre': 'Ano/Semestre',
    };
    for (final field in identity.entries) {
      if (ident[field.key].toString().trim().isEmpty) missing.add(field.value);
    }
    const fields = <String, String>{
      'ementa': 'Ementa',
      'justificativa': 'Justificativa',
      'objetivo_geral': 'Objetivo geral',
      'objetivos_especificos': 'Objetivos específicos',
      'programa_teorico': 'Programa teórico',
      'metodologia_tecnicas': 'Técnicas de ensino',
      'metodologia_recursos': 'Recursos didáticos',
      'metodologia_audiovisuais': 'Recursos audiovisuais',
      'avaliacao_geral': 'Avaliação',
      'avaliacao_provas': 'Calendário de avaliações',
      'horario_atendimento': 'Horário de atendimento',
      'atividade_recuperacao': 'Atividade de recuperação',
      'atendimento_especial': 'Atendimento especial',
    };
    for (final field in fields.entries) {
      if (plan[field.key].toString().trim().isEmpty) missing.add(field.value);
    }
    if ((plan['cronograma_teorico'] as List).isEmpty)
      missing.add('Cronograma teórico');
    final practice = _normalize(ident['carga_pratica'].toString());
    final exemptPractice = RegExp(
      r'^0+(?:[,.]0+)?(?:\s*(?:h|horas?|ha|h/a|aulas?))?$',
    ).hasMatch(practice);
    if (!exemptPractice) {
      if (plan['programa_pratico'].toString().trim().isEmpty)
        missing.add('Programa prático');
      if ((plan['cronograma_pratico'] as List).isEmpty)
        missing.add('Cronograma prático');
    }
    if ((plan['bibliografia_basica'] as List).isEmpty)
      missing.add('Bibliografia básica');
    if ((plan['bibliografia_complementar'] as List).isEmpty)
      missing.add('Bibliografia complementar');
    return missing;
  }

  static String renderHtml(Map<String, dynamic> plan) {
    final out = StringBuffer(
      '<html><head><meta charset="utf-8"><style>body{font-family:Arial,sans-serif;font-size:11pt;line-height:1.35}h1{text-align:center}h2{font-size:12pt;border-bottom:1px solid #555}p{text-align:justify}table{width:100%;border-collapse:collapse}th,td{border:1px solid #333;padding:5px;text-align:left;vertical-align:top}</style></head><body><h1>PLANO DE ENSINO</h1>',
    );
    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    const labels = <String, String>{
      'nome': 'Componente Curricular',
      'codigo': 'Código',
      'unidade_ofertante': 'Unidade Ofertante',
      'periodo_serie': 'Período/Série',
      'turma': 'Turma',
      'carga_teorica': 'Carga horária teórica',
      'carga_pratica': 'Carga horária prática',
      'carga_total': 'Carga horária total',
      'natureza': 'Natureza',
      'professor': 'Professor(a)',
      'ano_semestre': 'Ano/Semestre',
      'observacoes': 'Observações',
    };
    out.write('<h2>1. Identificação</h2><table>');
    for (final item in labels.entries) {
      final value = ident[item.key].toString().trim();
      if (value.isNotEmpty)
        out.write(
          '<tr><th>${_escape(item.value)}</th><td>${_escape(value)}</td></tr>',
        );
    }
    void section(String title, String key) {
      final value = plan[key].toString().trim();
      if (value.isEmpty) return;
      out.write('<h2>${_escape(title)}</h2>');
      for (final line in value.split('\n')) {
        if (line.trim().isNotEmpty) out.write('<p>${_escape(line.trim())}</p>');
      }
    }

    section('2. Ementa', 'ementa');
    section('3. Justificativa', 'justificativa');
    section('4. Objetivo geral', 'objetivo_geral');
    section('Objetivos específicos', 'objetivos_especificos');
    section('5. Programa teórico', 'programa_teorico');
    section('Programa prático', 'programa_pratico');
    section('6. Técnicas de ensino', 'metodologia_tecnicas');
    section('Recursos didáticos', 'metodologia_recursos');
    section('Recursos audiovisuais', 'metodologia_audiovisuais');
    void schedule(String title, String key) {
      final rows = (plan[key] as List).whereType<Map>().toList();
      if (rows.isEmpty) return;
      out.write(
        '<h2>${_escape(title)}</h2><table><tr><th>Data</th><th>Atividade</th></tr>',
      );
      for (final row in rows) {
        out.write(
          '<tr><td>${_escape(row['data'].toString())}</td><td>${_escape(row['atividade'].toString())}</td></tr>',
        );
      }
      out.write('</table>');
    }

    schedule('Cronograma teórico', 'cronograma_teorico');
    schedule('Cronograma prático', 'cronograma_pratico');
    section('7. Avaliação', 'avaliacao_geral');
    section('Calendário de avaliações', 'avaliacao_provas');
    section('8. Horário de atendimento', 'horario_atendimento');
    section('Atividade de recuperação', 'atividade_recuperacao');
    section('Atendimento especial', 'atendimento_especial');
    void bibliography(String title, String key) {
      final items = (plan[key] as List)
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList();
      if (items.isEmpty) return;
      out.write('<h2>${_escape(title)}</h2><ol>');
      for (final item in items) {
        out.write('<li>${_escape(item)}</li>');
      }
      out.write('</ol>');
    }

    bibliography('9. Bibliografia básica', 'bibliografia_basica');
    bibliography('Bibliografia complementar', 'bibliografia_complementar');
    out.write('</body></html>');
    return out.toString();
  }

  static Uint8List exportDocx(Map<String, dynamic> plan) {
    final paragraphs = <String>[];
    void line(String value, {bool bold = false}) {
      if (value.trim().isEmpty) return;
      final run =
          '<w:r>${bold ? '<w:rPr><w:b/></w:rPr>' : ''}<w:t xml:space="preserve">${_xmlEscape(value)}</w:t></w:r>';
      paragraphs.add('<w:p>$run</w:p>');
    }

    void section(String title, String key) {
      final value = plan[key]?.toString() ?? '';
      if (value.trim().isEmpty) return;
      line(title, bold: true);
      for (final part in value.split('\n')) {
        if (part.trim().isNotEmpty) line(part.trim());
      }
    }

    line('PLANO DE ENSINO', bold: true);
    line('1. Identificação', bold: true);
    final ident = Map<String, dynamic>.from(plan['identificacao'] as Map);
    const labels = <String, String>{
      'nome': 'Componente Curricular',
      'codigo': 'Código',
      'unidade_ofertante': 'Unidade Ofertante',
      'periodo_serie': 'Período/Série',
      'turma': 'Turma',
      'carga_teorica': 'Carga horária teórica',
      'carga_pratica': 'Carga horária prática',
      'carga_total': 'Carga horária total',
      'natureza': 'Natureza',
      'professor': 'Professor(a)',
      'ano_semestre': 'Ano/Semestre',
      'observacoes': 'Observações',
    };
    for (final item in labels.entries) {
      final value = ident[item.key]?.toString() ?? '';
      if (value.trim().isNotEmpty) line(item.value + ': ' + value);
    }
    section('2. Ementa', 'ementa');
    section('3. Justificativa', 'justificativa');
    section('4. Objetivo geral', 'objetivo_geral');
    section('Objetivos específicos', 'objetivos_especificos');
    section('5. Programa teórico', 'programa_teorico');
    section('Programa prático', 'programa_pratico');
    section('6. Técnicas de ensino', 'metodologia_tecnicas');
    section('Recursos didáticos', 'metodologia_recursos');
    section('Recursos audiovisuais', 'metodologia_audiovisuais');
    void schedule(String title, String key) {
      final rows = (plan[key] as List).whereType<Map>().toList();
      if (rows.isEmpty) return;
      line(title, bold: true);
      for (final row in rows) {
        line(row['data'].toString() + '\t' + row['atividade'].toString());
      }
    }

    schedule('Cronograma teórico', 'cronograma_teorico');
    schedule('Cronograma prático', 'cronograma_pratico');
    section('7. Avaliação', 'avaliacao_geral');
    section('Calendário e distribuição de pontos', 'avaliacao_provas');
    section('8. Horário de atendimento', 'horario_atendimento');
    section('Atividade de recuperação', 'atividade_recuperacao');
    section('Atendimento especial', 'atendimento_especial');
    void bibliography(String title, String key) {
      final values = (plan[key] as List)
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList();
      if (values.isEmpty) return;
      line(title, bold: true);
      for (var i = 0; i < values.length; i++) {
        line((i + 1).toString() + '. ' + values[i]);
      }
    }

    bibliography('9. Bibliografia básica', 'bibliografia_basica');
    bibliography('Bibliografia complementar', 'bibliografia_complementar');
    const doc =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{{content}}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>';
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          '[Content_Types].xml',
          0,
          utf8.encode(
            '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
          ),
        ),
      )
      ..addFile(
        ArchiveFile(
          '_rels/.rels',
          0,
          utf8.encode(
            '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
          ),
        ),
      )
      ..addFile(
        ArchiveFile(
          'word/document.xml',
          0,
          utf8.encode(doc.replaceFirst('{{content}}', paragraphs.join())),
        ),
      );
    return Uint8List.fromList(ZipEncoder().encode(archive) ?? <int>[]);
  }

  Map<String, dynamic> importDocx(Uint8List bytes, String id) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final file = archive.findFile('word/document.xml');
    if (file == null)
      throw const FormatException('O DOCX não contém word/document.xml.');
    final xml = XmlDocument.parse(utf8.decode(file.content as List<int>));
    final plan = emptyPlan(id);
    final elements = xml.descendants.whereType<XmlElement>();
    String textOf(XmlElement element) => element.descendants
        .whereType<XmlElement>()
        .where((node) => node.name.local == 't')
        .map((node) => node.innerText)
        .join();
    final paragraphs = elements
        .where((element) => element.name.local == 'p')
        .map(textOf)
        .toList();
    final sections = <String, String>{
      'ementa': 'ementa',
      'justificativa': 'justificativa',
      'objetivo geral': 'objetivo_geral',
      'objetivos específicos': 'objetivos_especificos',
      'programa teórico': 'programa_teorico',
      'programa prático': 'programa_pratico',
      'técnicas de ensino': 'metodologia_tecnicas',
      'recursos didáticos': 'metodologia_recursos',
      'recursos audiovisuais': 'metodologia_audiovisuais',
      'avaliação': 'avaliacao_geral',
      'calendário e distribuição de pontos': 'avaliacao_provas',
      'horário de atendimento': 'horario_atendimento',
      'atividade de recuperação': 'atividade_recuperacao',
      'atendimento especial': 'atendimento_especial',
      'cronograma teórico': '@cronograma_teorico',
      'cronograma prático': '@cronograma_pratico',
      'bibliografia básica': '@bibliografia_basica',
      'bibliografia complementar': '@bibliografia_complementar',
    };
    String? current;
    final collected = <String, List<String>>{};
    for (final line in paragraphs) {
      final normalized = _normalize(
        line.replaceFirst(RegExp(r'^\d+[.)]\s*'), ''),
      );
      final match = sections.entries
          .where((item) => normalized == _normalize(item.key))
          .firstOrNull;
      if (match != null) {
        current = match.value;
        if (current.startsWith('@')) {
          final key = current.substring(1);
          if (key.startsWith('cronograma_')) {
            plan[key] = <Map<String, String>>[];
          } else {
            plan[key] = <String>[];
          }
        } else {
          collected[current] = [];
        }
      } else if (current != null && line.trim().isNotEmpty) {
        if (current.startsWith('@cronograma_')) {
          final cells = line.split('\t');
          if (cells.length >= 2 &&
              RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(cells.first.trim())) {
            (plan[current.substring(1)] as List).add({
              'data': cells.first.trim(),
              'atividade': cells.skip(1).join(' ').trim(),
            });
          }
        } else if (current.startsWith('@bibliografia_')) {
          (plan[current.substring(1)] as List).add(
            line.replaceFirst(RegExp(r'^\d+[.)]\s*'), '').trim(),
          );
        } else {
          collected[current]!.add(line.trim());
        }
      }
    }
    for (final item in collected.entries) {
      plan[item.key] = item.value.join('\n').trim();
    }
    final identity = Map<String, dynamic>.from(plan['identificacao'] as Map);
    const fields = <String, String>{
      'componente curricular': 'nome',
      'código': 'codigo',
      'codigo': 'codigo',
      'unidade ofertante': 'unidade_ofertante',
      'período/série': 'periodo_serie',
      'periodo/serie': 'periodo_serie',
      'turma': 'turma',
      'natureza': 'natureza',
      'professor(a)': 'professor',
      'ano/semestre': 'ano_semestre',
      'carga horária teórica': 'carga_teorica',
      'carga horária prática': 'carga_pratica',
      'carga horária total': 'carga_total',
      'observações': 'observacoes',
    };
    for (final row in elements.where((element) => element.name.local == 'tr')) {
      final cells = row.descendants
          .whereType<XmlElement>()
          .where((node) => node.name.local == 'tc')
          .toList();
      if (cells.length < 2) continue;
      final field =
          fields[_normalize(textOf(cells.first).replaceAll(':', '').trim())];
      if (field != null) identity[field] = textOf(cells.skip(1).first).trim();
    }
    for (final line in paragraphs) {
      for (final field in fields.entries) {
        if (_normalize(line).startsWith(_normalize(field.key + ':'))) {
          identity[field.value] = line.substring(line.indexOf(':') + 1).trim();
        }
      }
    }
    plan['identificacao'] = identity;
    return plan;
  }
}

String _normalize(String value) => repairMojibake(value)
    .toLowerCase()
    .replaceAll(RegExp(r'[áàãâä]'), 'a')
    .replaceAll(RegExp(r'[éèêë]'), 'e')
    .replaceAll(RegExp(r'[íìîï]'), 'i')
    .replaceAll(RegExp(r'[óòôõö]'), 'o')
    .replaceAll(RegExp(r'[úùûü]'), 'u')
    .replaceAll('ç', 'c')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
