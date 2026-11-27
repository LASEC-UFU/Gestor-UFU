import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_browser_driver.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

class WebProcessService extends ChangeNotifier {
  WebProcessService(
    this.store, {
    WebBrowserDriver? driver,
    Future<void> Function(Duration)? delay,
  }) : driver = driver ?? PuppeteerWebBrowserDriver(),
       _delay = delay ?? Future<void>.delayed;

  static const key = 'inserir_documentos_sei.projects.v1';
  final KeyValueStore store;
  final WebBrowserDriver driver;
  final Future<void> Function(Duration) _delay;
  final _uuid = const Uuid();
  List<WebProcess> _projects = [];
  List<WebProcess> get projects => List.unmodifiable(_projects);
  bool busy = false;
  bool _cancelled = false;
  String stage = '';
  String? activeProjectId;
  double progress = 0;
  final List<String> log = [];

  WebProcess project(String id) =>
      _projects.where((p) => p.id == id).firstOrNull ??
      (throw const CommandException(
        'processo_nao_encontrado',
        'Processo não encontrado.',
      ));

  Future<void> load() async {
    if (busy) return;
    final raw = await store.readJson(key);
    _projects = (raw as List? ?? [])
        .map((p) => WebProcess.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList();
    notifyListeners();
  }

  void _idle() {
    if (busy) {
      throw const CommandException(
        'em_execucao',
        'Aguarde a operação atual ou peça para parar.',
      );
    }
  }

  Future<void> _persist() async {
    await store.writeJson(key, _projects.map((p) => p.toJson()).toList());
    notifyListeners();
  }

  Future<WebProcess> saveProcess(Map<String, dynamic> json) async {
    _idle();
    final id = json['id'] as String? ?? _uuid.v4();
    final old = _projects.where((p) => p.id == id).firstOrNull;
    final data = <String, dynamic>{
      if (old != null) ...old.toJson(),
      ...json,
      'id': id,
    };
    final steps = (data['steps'] as List? ?? [])
        .map(
          (s) => <String, dynamic>{
            ...Map<String, dynamic>.from(s as Map),
            if (s['id'] == null || s['id'] == '') 'id': _uuid.v4(),
          },
        )
        .toList();
    final item = WebProcess.fromJson({...data, 'steps': steps});
    item.validate();
    if (old == null) {
      _projects.add(item);
    } else {
      _projects[_projects.indexOf(old)] = item;
    }
    await _persist();
    return item;
  }

  Future<WebProcess> addPalmeloTemplate() async {
    final json =
        jsonDecode(
              await rootBundle.loadString('assets/web_automation/palmelo.json'),
            )
            as Map<String, dynamic>;
    return saveProcess(json);
  }

  Future<void> removeProcess(String id) async {
    _idle();
    project(id);
    _projects.removeWhere((p) => p.id == id);
    await _persist();
  }

  Future<void> saveSteps(String id, List<WebStep> steps) =>
      saveProcess({'id': id, 'steps': steps.map((s) => s.toJson()).toList()});

  Future<void> saveRecord(
    String processId,
    Map<String, String> values, {
    String? recordId,
  }) async {
    _idle();
    final item = project(processId);
    final records = [...item.records];
    final record = WebRecord(id: recordId ?? _uuid.v4(), values: values);
    final index = records.indexWhere((r) => r.id == record.id);
    if (index < 0) {
      records.add(record);
    } else {
      records[index] = record;
    }
    _replace(item.copyWith(records: records));
    await _persist();
  }

  void _replace(WebProcess item) =>
      _projects[_projects.indexWhere((p) => p.id == item.id)] = item;

  Future<int> importData(String id, String path) async {
    _idle();
    final item = project(id);
    final raw = jsonDecode(utf8.decode(await GestorPaths.readInput(path)));
    if (raw is! List || raw.any((r) => r is! Map)) {
      throw const CommandException(
        'dados_invalidos',
        'O arquivo precisa ser uma lista JSON de objetos, como dados.json.',
      );
    }
    final records = [
      for (final row in raw)
        WebRecord(id: _uuid.v4(), values: stringValues(row as Map)),
    ];
    _replace(item.copyWith(records: [...item.records, ...records]));
    await _persist();
    return records.length;
  }

  Future<void> removeRecord(String id, String recordId) async {
    _idle();
    final item = project(id);
    _replace(
      item.copyWith(
        records: item.records.where((r) => r.id != recordId).toList(),
      ),
    );
    await _persist();
  }

  Future<void> resetRecord(String id, String recordId) async {
    _idle();
    final item = project(id);
    final records = [
      for (final row in item.records)
        if (row.id == recordId)
          WebRecord(id: row.id, values: row.values)
        else
          row,
    ];
    _replace(item.copyWith(records: records));
    await _persist();
  }

  Future<String> exportProcess(String id, String? path) async {
    final item = project(id);
    final output = await GestorPaths.outputPath(
      path,
      'processo-web.json',
      sub: 'AcoesWeb',
    );
    final json = item.toJson()..['records'] = [];
    await File(output).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'format': 'gestor-web-process-v1', 'process': json}),
    );
    return output;
  }

  Future<WebProcess> importProcess(String path) async {
    _idle();
    final raw = jsonDecode(utf8.decode(await GestorPaths.readInput(path)));
    if (raw is! Map ||
        raw['format'] != 'gestor-web-process-v1' ||
        raw['process'] is! Map) {
      throw const CommandException(
        'processo_invalido',
        'Selecione um processo exportado pelo Criar Ações na Web.',
      );
    }
    final json = Map<String, dynamic>.from(raw['process'] as Map)..remove('id');
    json['records'] = [];
    return saveProcess(json);
  }

  Future<String> exportData(String id, String? path) async {
    final output = await GestorPaths.outputPath(
      path,
      'dados.json',
      sub: 'AcoesWeb',
    );
    await File(output).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(project(id).records.map((r) => r.values).toList()),
    );
    return output;
  }

  Future<void> openSite(String id) async {
    _idle();
    await driver.open(project(id));
    await driver.navigate(project(id).url);
    notifyListeners();
  }

  Future<PickedWebElement> pickElement(String id) async {
    _idle();
    busy = true;
    _cancelled = false;
    activeProjectId = id;
    stage = 'Clique no componente no navegador. Esc cancela.';
    notifyListeners();
    try {
      await driver.open(project(id));
      return await driver.pick(() => _cancelled);
    } finally {
      busy = false;
      stage = '';
      activeProjectId = null;
      notifyListeners();
    }
  }

  void stop() {
    _cancelled = true;
    stage = 'Parando após a etapa atual…';
    notifyListeners();
  }

  void _check(CommandExecutionContext? context) {
    if (_cancelled || (context?.cancellationRequested ?? false)) {
      throw const CommandException(
        'cancelado',
        'Execução interrompida pelo usuário.',
      );
    }
  }

  void _stage(String text, CommandExecutionContext? context) {
    stage = text;
    log.add(text);
    if (log.length > 500) log.removeAt(0);
    context?.reportProgress(text, fraction: progress);
    notifyListeners();
  }

  Future<void> _rowResult(String id, WebRecord record) async {
    final item = project(id);
    _replace(
      item.copyWith(
        records: [
          for (final row in item.records) row.id == record.id ? record : row,
        ],
      ),
    );
    await _persist();
  }

  Future<Map<String, Object?>> run(
    String id, {
    List<String>? recordIds,
    CommandExecutionContext? context,
  }) async {
    _idle();
    final item = project(id);
    item.validate(forExecution: true);
    var rows = item.records
        .where(
          (r) => r.pending && (recordIds == null || recordIds.contains(r.id)),
        )
        .toList();
    if (item.records.isEmpty && recordIds == null) {
      rows = [WebRecord(id: _uuid.v4(), values: const {})];
    }
    if (rows.isEmpty) {
      throw const CommandException(
        'sem_pendentes',
        'Não há registros pendentes. Para repetir, marque o registro como pendente.',
      );
    }
    // Validação completa antes de abrir o navegador ou alterar a página.
    for (final row in rows) {
      for (final step in item.steps) {
        step.resolve(row.values);
      }
    }
    if (item.records.isEmpty) {
      _replace(item.copyWith(records: rows));
      await _persist();
    }
    busy = true;
    _cancelled = false;
    activeProjectId = id;
    progress = 0;
    log.clear();
    notifyListeners();
    var success = 0;
    var failed = 0;
    var stopped = false;
    var directory = '';
    try {
      final base = item.outputDirectory.isEmpty
          ? await GestorPaths.outputDir('AcoesWeb')
          : item.outputDirectory;
      directory = p.join(
        base,
        DateTime.now().microsecondsSinceEpoch.toString(),
      );
      await Directory(directory).create(recursive: true);
      await driver.open(item);
      await driver.startRecording();
      for (var i = 0; i < rows.length; i++) {
        _check(context);
        final row = rows[i];
        final output = p.join(
          directory,
          'registro_${(i + 1).toString().padLeft(3, '0')}',
        );
        await Directory(output).create(recursive: true);
        await _rowResult(
          id,
          row.result('running', 'Iniciando', outputPath: output),
        );
        final extracted = <String, String>{};
        try {
          await driver.navigate(item.url);
          if (item.captureArtifacts) await driver.capture(output, 'antes');
          for (var s = 0; s < item.steps.length; s++) {
            _check(context);
            final step = item.steps[s];
            progress = (i + s / item.steps.length) / rows.length;
            _stage(
              'Registro ${i + 1}/${rows.length} · Etapa ${s + 1}/${item.steps.length} · ${step.name.isEmpty ? step.action.label : step.name}',
              context,
            );
            final read = await driver.perform(step, step.resolve(row.values));
            if (read != null) {
              extracted[step.name.isEmpty ? step.id : step.name] = read;
            }
          }
          _check(context);
          if (item.successText.isNotEmpty) {
            await driver.perform(
              WebStep(
                id: 'confirmar',
                action: WebAction.waitText,
                selector: 'body',
                value: item.successText,
              ),
              item.successText,
            );
          }
          if (item.captureArtifacts) await driver.capture(output, 'depois');
          await _rowResult(
            id,
            row.result(
              'success',
              item.successText.isEmpty
                  ? 'Etapas concluídas.'
                  : 'Conclusão confirmada na página.',
              outputPath: output,
              extracted: extracted,
            ),
          );
          success++;
        } catch (error) {
          final cancelled =
              _cancelled || (context?.cancellationRequested ?? false);
          final message = error is CommandException
              ? error.message
              : error.toString();
          try {
            if (item.captureArtifacts) await driver.capture(output, 'erro');
          } catch (_) {}
          await _rowResult(
            id,
            row.result(
              cancelled ? 'review' : 'failed',
              message,
              outputPath: output,
              extracted: extracted,
            ),
          );
          _stage(message, context);
          failed++;
          if (cancelled) {
            stopped = true;
            break;
          }
        }
        progress = (i + 1) / rows.length;
        notifyListeners();
        if (i < rows.length - 1) {
          final ms =
              item.delayMinMs +
              Random().nextInt(item.delayMaxMs - item.delayMinMs + 1);
          for (var elapsed = 0; elapsed < ms; elapsed += 100) {
            _check(context);
            await _delay(Duration(milliseconds: min(100, ms - elapsed)));
          }
        }
      }
    } on CommandException catch (error) {
      if (error.code != 'cancelado') rethrow;
      stopped = true;
    } finally {
      try {
        if (directory.isNotEmpty && await Directory(directory).exists()) {
          await driver.stopRecording(directory);
          await File(p.join(directory, 'resumo.json')).writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'processId': id,
              'success': success,
              'failed': failed,
              'cancelled': stopped,
              'records': project(id).records
                  .where((r) => rows.any((row) => row.id == r.id))
                  .map((r) => r.toJson())
                  .toList(),
              'log': log,
            }),
          );
        }
      } finally {
        busy = false;
        activeProjectId = null;
        stage =
            'Concluídos: $success · Falhas: $failed${stopped ? ' · Interrompido' : ''}';
        notifyListeners();
      }
    }
    return {
      'success': success,
      'failed': failed,
      'cancelled': stopped,
      'outputPath': directory,
    };
  }
}
