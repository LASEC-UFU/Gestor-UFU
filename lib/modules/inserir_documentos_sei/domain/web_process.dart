import 'package:gestor_ufu/platform/command/module_command.dart';

enum WebAction {
  fill('Preencher campo'),
  click('Clicar'),
  select('Selecionar opção'),
  check('Marcar caixa'),
  uncheck('Desmarcar caixa'),
  wait('Aguardar elemento'),
  waitText('Aguardar texto'),
  read('Ler texto'),
  upload('Anexar arquivo'),
  navigate('Abrir endereço'),
  pause('Pausar');

  const WebAction(this.label);
  final String label;
  bool get needsSelector => this != navigate && this != pause;
  bool get usesValue => !const [wait, read, check, uncheck].contains(this);
}

class WebStep {
  const WebStep({
    required this.id,
    required this.action,
    this.name = '',
    this.selector = '',
    this.value = '',
    this.transform = 'none',
    this.framePath = const [],
    this.timeoutSeconds = 30,
  });

  final String id, name, selector, value, transform;
  final WebAction action;
  final List<int> framePath;
  final int timeoutSeconds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'action': action.name,
    'selector': selector,
    'value': value,
    'transform': transform,
    'framePath': framePath,
    'timeoutSeconds': timeoutSeconds,
  };

  factory WebStep.fromJson(Map<String, dynamic> json) {
    final action = WebAction.values
        .where((a) => a.name == json['action'])
        .firstOrNull;
    if (action == null) {
      throw const CommandException(
        'acao_invalida',
        'Tipo de ação não reconhecido.',
      );
    }
    return WebStep(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      action: action,
      selector: json['selector'] as String? ?? '',
      value: json['value'] as String? ?? '',
      transform: json['transform'] as String? ?? 'none',
      framePath: (json['framePath'] as List? ?? []).cast<int>(),
      timeoutSeconds: json['timeoutSeconds'] as int? ?? 30,
    );
  }

  String resolve(Map<String, String> row) {
    if (!action.usesValue) return '';
    var result = value.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (
      match,
    ) {
      final field = match[1]!.trim();
      if (!row.containsKey(field)) {
        throw CommandException(
          'campo_ausente',
          'O lote não contém o campo "$field".',
        );
      }
      return row[field]!;
    });
    result = switch (transform) {
      'digits' => result.replaceAll(RegExp(r'\D'), ''),
      'trim' => result.trim(),
      'upper' => result.toUpperCase(),
      'lower' => result.toLowerCase(),
      _ => result,
    };
    if (action == WebAction.navigate) validateWebUrl(result);
    if (action == WebAction.pause) {
      final seconds = double.tryParse(result.replaceAll(',', '.'));
      if (seconds == null || seconds < 0 || seconds > 60) {
        throw const CommandException(
          'pausa_invalida',
          'A pausa precisa estar entre 0 e 60 segundos.',
        );
      }
    }
    return result;
  }
}

class WebRecord {
  const WebRecord({
    required this.id,
    required this.values,
    this.status = 'pending',
    this.message = '',
    this.outputPath = '',
    this.completedAt = '',
    this.extracted = const {},
  });
  final String id, status, message, outputPath, completedAt;
  final Map<String, String> values, extracted;

  String get label =>
      values['nome_completo'] ??
      values['nome'] ??
      values.values.firstOrNull ??
      id;
  bool get pending => status == 'pending';
  String get statusLabel => switch (status) {
    'running' => 'Em execução',
    'success' => 'Concluído',
    'failed' => 'Falhou',
    'review' => 'Conferir resultado',
    _ => 'Pendente',
  };
  WebRecord result(
    String status,
    String message, {
    String outputPath = '',
    Map<String, String> extracted = const {},
  }) => WebRecord(
    id: id,
    values: values,
    status: status,
    message: message,
    outputPath: outputPath,
    extracted: extracted,
    completedAt: DateTime.now().toIso8601String(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'values': values,
    'status': status,
    'message': message,
    'outputPath': outputPath,
    'completedAt': completedAt,
    'extracted': extracted,
  };
  factory WebRecord.fromJson(Map<String, dynamic> json) => WebRecord(
    id: json['id'] as String,
    values: stringValues(json['values'] as Map),
    status: json['status'] == 'running'
        ? 'review'
        : json['status'] as String? ?? 'pending',
    message: json['status'] == 'running'
        ? 'Execução interrompida. Confira o site antes de repetir.'
        : json['message'] as String? ?? '',
    outputPath: json['outputPath'] as String? ?? '',
    completedAt: json['completedAt'] as String? ?? '',
    extracted: stringValues(json['extracted'] as Map? ?? {}),
  );
}

Map<String, String> stringValues(Map values) {
  if (values.values.any((value) => value is Map || value is List)) {
    throw const CommandException(
      'dados_invalidos',
      'Cada campo do lote precisa ser um texto, número ou booleano.',
    );
  }
  return {
    for (final entry in values.entries)
      '${entry.key}': entry.value?.toString() ?? '',
  };
}

class WebProcess {
  const WebProcess({
    required this.id,
    required this.name,
    required this.url,
    this.steps = const [],
    this.records = const [],
    this.successText = '',
    this.outputDirectory = '',
    this.captureArtifacts = true,
    this.delayMinMs = 1500,
    this.delayMaxMs = 2800,
  });
  final String id, name, url, successText, outputDirectory;
  final List<WebStep> steps;
  final List<WebRecord> records;
  final bool captureArtifacts;
  final int delayMinMs, delayMaxMs;

  List<String> get fields => {
    for (final row in records) ...row.values.keys,
    for (final step in steps.where((s) => s.action.usesValue))
      for (final match in RegExp(
        r'\{\{\s*([^{}]+?)\s*\}\}',
      ).allMatches(step.value))
        match[1]!.trim(),
  }.toList();

  WebProcess copyWith({List<WebStep>? steps, List<WebRecord>? records}) =>
      WebProcess(
        id: id,
        name: name,
        url: url,
        steps: steps ?? this.steps,
        records: records ?? this.records,
        successText: successText,
        outputDirectory: outputDirectory,
        captureArtifacts: captureArtifacts,
        delayMinMs: delayMinMs,
        delayMaxMs: delayMaxMs,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'successText': successText,
    'outputDirectory': outputDirectory,
    'captureArtifacts': captureArtifacts,
    'delayMinMs': delayMinMs,
    'delayMaxMs': delayMaxMs,
    'steps': steps.map((s) => s.toJson()).toList(),
    'records': records.map((r) => r.toJson()).toList(),
  };
  factory WebProcess.fromJson(Map<String, dynamic> json) => WebProcess(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    url: json['url'] as String? ?? '',
    successText: json['successText'] as String? ?? '',
    outputDirectory: json['outputDirectory'] as String? ?? '',
    captureArtifacts: json['captureArtifacts'] as bool? ?? true,
    delayMinMs: json['delayMinMs'] as int? ?? 1500,
    delayMaxMs: json['delayMaxMs'] as int? ?? 2800,
    steps: (json['steps'] as List? ?? [])
        .map((s) => WebStep.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
    records: (json['records'] as List? ?? [])
        .map((r) => WebRecord.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList(),
  );

  void validate({bool forExecution = false}) {
    if (name.trim().isEmpty) {
      throw const CommandException('nome_vazio', 'Informe o nome do processo.');
    }
    validateWebUrl(url);
    if (delayMinMs < 0 || delayMaxMs < delayMinMs || delayMaxMs > 60000) {
      throw const CommandException(
        'intervalo_invalido',
        'O intervalo entre registros deve ficar entre 0 e 60 segundos.',
      );
    }
    final ids = <String>{};
    for (final step in steps) {
      if (step.id.isEmpty || !ids.add(step.id)) {
        throw const CommandException(
          'etapa_invalida',
          'Cada etapa precisa de um identificador único.',
        );
      }
      if (step.action.needsSelector && step.selector.trim().isEmpty) {
        throw const CommandException(
          'seletor_vazio',
          'Selecione o componente HTML da etapa.',
        );
      }
      if (step.timeoutSeconds < 1 ||
          step.timeoutSeconds > 120 ||
          step.framePath.any((i) => i < 0)) {
        throw const CommandException(
          'etapa_invalida',
          'Confira o tempo limite e o quadro da etapa.',
        );
      }
      if (!const [
        'none',
        'digits',
        'trim',
        'upper',
        'lower',
      ].contains(step.transform)) {
        throw const CommandException(
          'transformacao_invalida',
          'Transformação de valor não reconhecida.',
        );
      }
    }
    if (forExecution && steps.isEmpty) {
      throw const CommandException(
        'sem_etapas',
        'Cadastre as etapas antes de executar.',
      );
    }
    if (records.map((r) => r.id).toSet().length != records.length) {
      throw const CommandException(
        'dados_invalidos',
        'Os registros precisam de identificadores únicos.',
      );
    }
  }
}

Uri validateWebUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !const ['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const CommandException(
      'url_invalida',
      'Informe um endereço http ou https sem credenciais na URL.',
    );
  }
  return uri;
}

class PickedWebElement {
  const PickedWebElement({
    required this.selector,
    required this.label,
    required this.tag,
    this.inputType = '',
    this.role = '',
    this.framePath = const [],
    this.options = const [],
  });
  final String selector, label, tag, inputType, role;
  final List<int> framePath;
  final List<Map<String, String>> options;
  Map<String, Object?> toJson() => {
    'selector': selector,
    'label': label,
    'tag': tag,
    'inputType': inputType,
    'role': role,
    'framePath': framePath,
    'options': options,
  };
}
