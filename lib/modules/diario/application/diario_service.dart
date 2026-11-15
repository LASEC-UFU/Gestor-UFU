import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' hide Border;

import 'package:gestor_ufu/modules/diario/data/diary_automation_service.dart';
import 'package:gestor_ufu/modules/diario/application/diario_lancamentos.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Regras do Preenche Diários usadas pelos comandos (e pelo Agente de IA).
///
/// Formato gravado por período letivo (mesmo da tela):
/// `{draftEntries, sourceLabel, selectedDiaryId, savedDiaries}`. O rascunho
/// (`draftEntries`) espelha o diário selecionado.
class DiarioService {
  DiarioService(this._store, this._terms);

  final KeyValueStore _store;
  final AcademicTermService _terms;

  static const periodPrefix = 'preenche_diarios_period_data_v1_';
  static const portalUrlKey = 'portal_docente_url';
  static const _credentialsKey = 'portal_docente_credentials_v1';
  static const defaultPortalUrl =
      'https://www.portaldocente.ufu.br/diarioEletronico';

  DiaryAutomationService get portal => DiaryAutomationService.instance;

  Future<String> _term(String? term) async {
    await _terms.load();
    if (term == null || term.trim().isEmpty) return _terms.active;
    final normalized = AcademicTermService.normalize(term);
    if (!_terms.terms.contains(normalized)) {
      throw CommandException(
        'periodo_inexistente',
        'Período "$term" não existe. Períodos: ${_terms.terms.join(', ')}.',
      );
    }
    return normalized;
  }

  Future<Map<String, dynamic>> _read(String term) async {
    final data = await _store.readJson(
      KeyValueStore.termScoped(periodPrefix, term),
    );
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Map<String, String> _draft(Map<String, dynamic> data) {
    final raw = data['draftEntries'];
    return raw is Map
        ? DiarioLancamentos.validate(raw).valid
        : <String, String>{};
  }

  /// Grava o rascunho e o espelha no diário selecionado.
  Future<void> _write(
    String term,
    Map<String, dynamic> data,
    Map<String, String> entries,
    String? sourceLabel,
  ) async {
    final sorted = DiarioLancamentos.sortMap(entries);
    final selected = data['selectedDiaryId'];
    final diaries = [
      for (final d
          in (data['savedDiaries'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(d),
    ];
    for (final diary in diaries) {
      if (selected != null && diary['id'] == selected) {
        diary['entries'] = sorted;
        diary['sourceLabel'] = sourceLabel;
      }
    }
    await _store.writeJson(KeyValueStore.termScoped(periodPrefix, term), {
      'draftEntries': sorted,
      'sourceLabel': sourceLabel,
      'selectedDiaryId': selected,
      'savedDiaries': diaries,
    });
  }

  Future<Map<String, Object?>> list({
    String? term,
    bool entries = false,
  }) async {
    final t = await _term(term);
    final data = await _read(t);
    final draft = _draft(data);
    return {
      'periodo': t,
      'periodos': _terms.terms,
      'rascunho': draft.length,
      if (entries) 'lancamentos': draft,
      'diarioSelecionado': data['selectedDiaryId'],
      'diarios': [
        for (final d
            in (data['savedDiaries'] as List? ?? const []).whereType<Map>())
          {
            'id': d['id'],
            'nome': d['name'],
            'lancamentos': (d['entries'] as Map?)?.length ?? 0,
          },
      ],
    };
  }

  /// Importa a planilha (aba [sheet] ou a primeira) e MESCLA no rascunho
  /// (ou substitui com [replace]).
  Future<DiarioImport> importWorkbook(
    String path, {
    String? sheet,
    String? term,
    bool replace = false,
  }) async {
    final bytes = await GestorPaths.readInput(path);
    final Excel workbook;
    try {
      workbook = Excel.decodeBytes(bytes);
    } on Object catch (error) {
      throw CommandException('arquivo_invalido', 'Planilha ilegível: $error');
    }
    if (workbook.tables.isEmpty) {
      throw const CommandException(
        'aba_nao_encontrada',
        'O arquivo não contém abas legíveis.',
      );
    }
    final name = sheet ?? workbook.tables.keys.first;
    final table = workbook.tables[name];
    if (table == null) {
      throw CommandException(
        'aba_nao_encontrada',
        'Aba "$name" não encontrada. Abas: ${workbook.tables.keys.join(', ')}.',
      );
    }
    final result = DiarioLancamentos.parseWorksheet(table);
    if (result.valid.isEmpty) {
      throw const CommandException(
        'sem_lancamentos',
        'Não encontrei linhas com Data, Modalidade e Matéria Lecionada (ou '
            'Conteúdo). Confira os cabeçalhos e os dados da aba.',
      );
    }
    final t = await _term(term);
    final data = await _read(t);
    await _write(
      t,
      data,
      replace ? result.valid : {..._draft(data), ...result.valid},
      'Excel · ${File(path).uri.pathSegments.last} · $name',
    );
    return result;
  }

  /// Carrega um JSON {"DD/MM/AAAA -T": "conteúdo"} SUBSTITUINDO o rascunho.
  Future<DiarioValidation> importJson(String path, {String? term}) async {
    final raw = jsonDecode(utf8.decode(await GestorPaths.readInput(path)));
    final validated = DiarioLancamentos.validate(raw);
    if (validated.valid.isEmpty) {
      throw CommandException(
        'json_invalido',
        validated.errors.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
      );
    }
    final t = await _term(term);
    await _write(
      t,
      await _read(t),
      validated.valid,
      'JSON · ${File(path).uri.pathSegments.last}',
    );
    return validated;
  }

  Future<String> exportJson({String? path, String? term}) async {
    final t = await _term(term);
    final target = await GestorPaths.outputPath(
      path,
      'dados_diario.json',
      sub: 'diario',
    );
    await File(target).writeAsString(
      const JsonEncoder.withIndent('  ').convert(_draft(await _read(t))),
    );
    return target;
  }

  /// Define lançamentos diretamente ({"DD/MM/AAAA -T": "conteúdo"}); valor
  /// vazio remove a aula.
  Future<DiarioValidation> setEntries(
    Map<String, dynamic> entries, {
    String? term,
    bool replace = false,
  }) async {
    final removals = [
      for (final e in entries.entries)
        if ('${e.value}'.trim().isEmpty) e.key,
    ];
    final validated = DiarioLancamentos.validate({
      for (final e in entries.entries)
        if ('${e.value}'.trim().isNotEmpty) e.key: '${e.value}',
    });
    final t = await _term(term);
    final data = await _read(t);
    final draft = replace ? <String, String>{} : _draft(data);
    for (final key in removals) {
      final normalized = DiarioLancamentos.normalizeKey(key);
      if (normalized != null) draft.remove(normalized);
    }
    draft.addAll(validated.valid);
    await _write(t, data, draft, data['sourceLabel'] as String?);
    return validated;
  }

  // ---------------------------------------------------------- Portal

  Future<String> openPortal({String? url}) async {
    final target =
        url ?? await _store.readString(portalUrlKey) ?? defaultPortalUrl;
    if (url != null) await _store.writeString(portalUrlKey, url);
    String? username, password;
    final credentials = await _store.readJson(_credentialsKey);
    if (credentials is Map) {
      // Usadas só pelo navegador (login automático); nunca devolvidas.
      username = credentials['username'] as String?;
      password = credentials['password'] as String?;
    }
    return portal.openBrowser(target, username: username, password: password);
  }

  /// Preenche o diário aberto no Edge com os lançamentos do rascunho
  /// ([only] = "T" ou "P" filtra o tipo).
  Future<DiaryFillResult> fillPortal({
    String? term,
    String? only,
    bool requireEmpty = true,
    bool highlight = true,
    void Function(String)? log,
  }) async {
    if (!portal.isConnected) {
      throw const CommandException(
        'portal_fechado',
        'Abra o Portal (diario.abrirPortal), faça login e abra o diário '
            'antes de preencher.',
      );
    }
    final draft = _draft(await _read(await _term(term)));
    final selected = only == null
        ? draft
        : {
            for (final e in draft.entries)
              if (e.key.endsWith('-$only')) e.key: e.value,
          };
    if (selected.isEmpty) {
      throw const CommandException(
        'sem_lancamentos',
        'Não há lançamentos no rascunho para preencher.',
      );
    }
    return portal.fillEntries(
      DiarioLancamentos.sortMap(selected),
      requireEmpty: requireEmpty,
      highlight: highlight,
      log: log ?? (_) {},
    );
  }
}
