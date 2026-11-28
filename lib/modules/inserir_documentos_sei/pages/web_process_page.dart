import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/domain/web_process.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';

class WebProcessPage extends StatefulWidget {
  const WebProcessPage({required this.service, super.key});
  final WebProcessService service;
  @override
  State<WebProcessPage> createState() => _WebProcessPageState();
}

class _WebProcessPageState extends State<WebProcessPage> {
  WebProcessService get service => widget.service;
  String? _selected;
  bool _loading = true;
  final _selectedRows = <String>{};

  @override
  void initState() {
    super.initState();
    service.addListener(_changed);
    _guard(() async {
      await service.load();
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!service.projects.any((p) => p.id == _selected)) {
        _selected = service.projects.firstOrNull?.id;
        _selectedRows.clear();
      }
      final current = service.projects
          .where((p) => p.id == _selected)
          .firstOrNull;
      _selectedRows.removeWhere(
        (id) => !(current?.records.any((r) => r.id == id) ?? false),
      );
    });
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _message(error is CommandException ? error.message : '$error');
    }
  }

  Future<T?> _editorDialog<T>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    // Os campos permanecem montados durante a animação de fechamento.
    await route.completed;
    return result;
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _projectDialog([WebProcess? item]) async {
    final name = TextEditingController(text: item?.name ?? '');
    final url = TextEditingController(text: item?.url ?? '');
    final success = TextEditingController(text: item?.successText ?? '');
    final directory = TextEditingController(text: item?.outputDirectory ?? '');
    final minDelay = TextEditingController(
      text: '${(item?.delayMinMs ?? 1500) / 1000}',
    );
    final maxDelay = TextEditingController(
      text: '${(item?.delayMaxMs ?? 2800) / 1000}',
    );
    var capture = item?.captureArtifacts ?? true;
    final form = GlobalKey<FormState>();
    final result = await _editorDialog<Map<String, dynamic>>(
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(item == null ? 'Novo processo' : 'Configurar processo'),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Nome do processo',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Informe o nome.' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: url,
                      decoration: const InputDecoration(
                        labelText: 'Endereço inicial do site',
                        hintText: 'https://...',
                      ),
                      validator: (v) {
                        try {
                          validateWebUrl(v ?? '');
                          return null;
                        } catch (_) {
                          return 'Informe uma URL http ou https.';
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: success,
                      decoration: const InputDecoration(
                        labelText: 'Texto que confirma a conclusão (opcional)',
                        helperText: 'Ex.: Sua resposta foi registrada',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: minDelay,
                            decoration: const InputDecoration(
                              labelText: 'Intervalo mínimo (segundos)',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (v) =>
                                double.tryParse(
                                      (v ?? '').replaceAll(',', '.'),
                                    ) ==
                                    null
                                ? 'Número inválido'
                                : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: maxDelay,
                            decoration: const InputDecoration(
                              labelText: 'Intervalo máximo (segundos)',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (v) =>
                                double.tryParse(
                                      (v ?? '').replaceAll(',', '.'),
                                    ) ==
                                    null
                                ? 'Número inválido'
                                : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: directory,
                      decoration: InputDecoration(
                        labelText: 'Pasta dos resultados (opcional)',
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.folder_open),
                          onPressed: () async {
                            final path = await FilePicker.platform
                                .getDirectoryPath();
                            if (path != null) directory.text = path;
                          },
                        ),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Salvar capturas antes e depois de cada registro',
                      ),
                      subtitle: const Text(
                        'Imagem da página, HTML, endereço e registro de execução.',
                      ),
                      value: capture,
                      onChanged: (v) => update(() => capture = v),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                Navigator.pop(context, <String, dynamic>{
                  if (item != null) ...item.toJson(),
                  'name': name.text.trim(),
                  'url': url.text.trim(),
                  'successText': success.text.trim(),
                  'outputDirectory': directory.text.trim(),
                  'delayMinMs':
                      (double.parse(minDelay.text.replaceAll(',', '.')) * 1000)
                          .round(),
                  'delayMaxMs':
                      (double.parse(maxDelay.text.replaceAll(',', '.')) * 1000)
                          .round(),
                  'captureArtifacts': capture,
                });
              },
              child: const Text('Salvar processo'),
            ),
          ],
        ),
      ),
    );
    for (final c in [name, url, success, directory, minDelay, maxDelay]) {
      c.dispose();
    }
    if (result == null) return;
    await _guard(() async {
      final saved = await service.saveProcess(result);
      if (mounted) {
        setState(() {
          _selected = saved.id;
          _selectedRows.clear();
        });
      }
    });
  }

  Future<void> _useProcessTemplate([WebProcess? source]) => _guard(() async {
    if (service.projects.isEmpty) return;
    var sourceId = source?.id ?? service.projects.first.id;
    final name = TextEditingController(
      text: '${service.project(sourceId).name} - cópia',
    );
    var includeData = false;
    final result = await _editorDialog<Map<String, dynamic>>(
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Usar processo como modelo'),
          content: SizedBox(
            width: 600,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: sourceId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Processo existente',
                  ),
                  items: service.projects
                      .map(
                        (p) =>
                            DropdownMenuItem(value: p.id, child: Text(p.name)),
                      )
                      .toList(),
                  onChanged: (id) => update(() {
                    sourceId = id!;
                    name.text = '${service.project(sourceId).name} - cópia';
                  }),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Nome do novo processo',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: includeData,
                  onChanged: (v) => update(() => includeData = v ?? false),
                  title: const Text('Copiar também os dados do lote'),
                  subtitle: const Text(
                    'Os registros copiados começarão como pendentes.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'processId': sourceId,
                'name': name.text,
                'includeData': includeData,
              }),
              child: const Text('Criar processo'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    if (result == null) return;
    final item = await service.duplicateProcess(
      result['processId'] as String,
      name: result['name'] as String,
      includeData: result['includeData'] as bool,
    );
    if (mounted) {
      setState(() {
        _selected = item.id;
        _selectedRows.clear();
      });
    }
  });

  Future<void> _importProject() => _guard(() async {
    final file = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = file?.files.single.path;
    if (path == null) return;
    final item = await service.importProcess(path);
    if (mounted) {
      setState(() {
        _selected = item.id;
        _selectedRows.clear();
      });
    }
  });

  Future<void> _exportProject(WebProcess item) => _guard(() async {
    final path = await FilePicker.platform.saveFile(
      fileName: 'processo-web.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path != null) {
      _message(
        'Processo exportado: ${await service.exportProcess(item.id, path)}',
      );
    }
  });

  Future<void> _stepDialog(WebProcess item, [WebStep? old]) async {
    final name = TextEditingController(text: old?.name ?? '');
    final selector = TextEditingController(text: old?.selector ?? '');
    final value = TextEditingController(text: old?.value ?? '');
    final timeout = TextEditingController(text: '${old?.timeoutSeconds ?? 30}');
    var action = old?.action ?? WebAction.fill;
    var actionWasChosen = old != null;
    var transform = old?.transform ?? 'none';
    var framePath = old?.framePath ?? <int>[];
    var picking = false;
    String? error;
    final form = GlobalKey<FormState>();
    final result = await _editorDialog<WebStep>(
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(old == null ? 'Adicionar ação' : 'Editar ação'),
          content: SizedBox(
            width: 690,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Nome da etapa (opcional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<WebAction>(
                      initialValue: action,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de ação',
                      ),
                      items: WebAction.values
                          .map(
                            (a) => DropdownMenuItem(
                              value: a,
                              child: Text(a.label),
                            ),
                          )
                          .toList(),
                      onChanged: picking
                          ? null
                          : (v) => update(() {
                              action = v!;
                              actionWasChosen = true;
                            }),
                    ),
                    if (action.needsSelector) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: selector,
                        decoration: const InputDecoration(
                          labelText: 'ID ou seletor do componente HTML',
                          hintText: 'Ex.: #nome, id=nome ou input[name="nome"]',
                        ),
                        validator: (v) =>
                            action.needsSelector && (v ?? '').trim().isEmpty
                            ? 'Selecione um componente.'
                            : null,
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.ads_click),
                          label: Text(
                            picking
                                ? 'Clique no componente no navegador…'
                                : 'Selecionar componente na página',
                          ),
                          onPressed: picking
                              ? null
                              : () async {
                                  update(() {
                                    picking = true;
                                    error = null;
                                  });
                                  try {
                                    final picked = await service.pickElement(
                                      item.id,
                                    );
                                    if (!dialogContext.mounted) return;
                                    selector.text = picked.selector;
                                    if (name.text.isEmpty) {
                                      name.text = picked.label;
                                    }
                                    update(() {
                                      framePath = picked.framePath;
                                      if (!actionWasChosen) {
                                        action = switch (picked.role) {
                                          'button' => WebAction.click,
                                          'checkbox' => WebAction.check,
                                          _ => switch (picked.inputType) {
                                            'checkbox' => WebAction.check,
                                            'file' => WebAction.upload,
                                            _ => switch (picked.tag) {
                                              'select' => WebAction.select,
                                              'button' ||
                                              'a' => WebAction.click,
                                              _ => WebAction.fill,
                                            },
                                          },
                                        };
                                      }
                                    });
                                  } catch (e) {
                                    if (dialogContext.mounted) {
                                      update(() => error = e.toString());
                                    }
                                  } finally {
                                    if (dialogContext.mounted) {
                                      update(() => picking = false);
                                    }
                                  }
                                },
                        ),
                      ),
                      if (framePath.isNotEmpty)
                        Text(
                          'Componente em quadro interno: ${framePath.map((i) => i + 1).join(' → ')}',
                        ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: value,
                      enabled: !const [
                        WebAction.wait,
                        WebAction.check,
                        WebAction.uncheck,
                        WebAction.read,
                      ].contains(action),
                      decoration: InputDecoration(
                        labelText: switch (action) {
                          WebAction.navigate => 'Endereço a abrir',
                          WebAction.pause => 'Segundos de pausa',
                          WebAction.click => 'Texto exato do botão (opcional)',
                          WebAction.upload => 'Caminho do arquivo',
                          _ => 'Valor',
                        },
                        helperText:
                            'Texto fixo ou {{campo}} para usar um valor de cada registro.',
                      ),
                    ),
                    if (item.fields.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final field in item.fields)
                            ActionChip(
                              label: Text('{{$field}}'),
                              onPressed: () => value.text = '{{$field}}',
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: transform,
                            decoration: const InputDecoration(
                              labelText: 'Ajuste do valor',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'none',
                                child: Text('Manter como está'),
                              ),
                              DropdownMenuItem(
                                value: 'digits',
                                child: Text('Somente números'),
                              ),
                              DropdownMenuItem(
                                value: 'trim',
                                child: Text('Remover espaços nas pontas'),
                              ),
                              DropdownMenuItem(
                                value: 'upper',
                                child: Text('Letras maiúsculas'),
                              ),
                              DropdownMenuItem(
                                value: 'lower',
                                child: Text('Letras minúsculas'),
                              ),
                            ],
                            onChanged: (v) => update(() => transform = v!),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 150,
                          child: TextFormField(
                            controller: timeout,
                            decoration: const InputDecoration(
                              labelText: 'Espera máxima (s)',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (v) {
                              final n = int.tryParse(v ?? '');
                              return n == null || n < 1 || n > 120
                                  ? 'Use 1 a 120'
                                  : null;
                            },
                          ),
                        ),
                      ],
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (picking) service.stop();
                Navigator.pop(dialogContext);
              },
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: picking
                  ? null
                  : () {
                      if (!form.currentState!.validate()) return;
                      Navigator.pop(
                        dialogContext,
                        WebStep(
                          id: old?.id ?? const Uuid().v4(),
                          name: name.text.trim(),
                          action: action,
                          selector: selector.text.trim(),
                          value: value.text,
                          transform: transform,
                          framePath: framePath,
                          timeoutSeconds: int.parse(timeout.text),
                        ),
                      );
                    },
              child: const Text('Salvar ação'),
            ),
          ],
        ),
      ),
    );
    for (final c in [name, selector, value, timeout]) {
      c.dispose();
    }
    if (result == null) return;
    await _guard(() async {
      await service.saveSteps(item.id, [
        if (old == null) ...item.steps,
        if (old == null) result,
        if (old != null)
          for (final step in item.steps) step.id == old.id ? result : step,
      ]);
    });
  }

  Future<void> _editRecord(WebProcess item, [WebRecord? row]) async {
    final controllers = <String, TextEditingController>{
      for (final field in {...item.fields, ...?row?.values.keys})
        field: TextEditingController(text: row?.values[field] ?? ''),
    };
    if (controllers.isEmpty) controllers['nome'] = TextEditingController();
    final newField = TextEditingController();
    final result = await _editorDialog<Map<String, String>>(
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(row == null ? 'Novo registro' : 'Editar registro'),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in controllers.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TextField(
                        controller: entry.value,
                        decoration: InputDecoration(labelText: entry.key),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: newField,
                          decoration: const InputDecoration(
                            labelText: 'Nome de um novo campo',
                            hintText: 'Ex.: matricula',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Adicionar campo',
                        icon: const Icon(Icons.add),
                        onPressed: () {
                          final field = newField.text.trim();
                          if (field.isNotEmpty &&
                              !controllers.containsKey(field)) {
                            update(() {
                              controllers[field] = TextEditingController();
                              newField.clear();
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                for (final entry in controllers.entries)
                  entry.key: entry.value.text,
              }),
              child: const Text('Salvar registro'),
            ),
          ],
        ),
      ),
    );
    for (final c in controllers.values) {
      c.dispose();
    }
    newField.dispose();
    if (result != null) {
      await _guard(
        () => service.saveRecord(item.id, result, recordId: row?.id),
      );
    }
  }

  Future<void> _importData(WebProcess item) => _guard(() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final count = await service.importData(item.id, path);
    _message('$count registros importados.');
  });
  Future<void> _exportData(WebProcess item) => _guard(() async {
    final path = await FilePicker.platform.saveFile(
      fileName: 'dados.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path != null) {
      _message('Dados exportados: ${await service.exportData(item.id, path)}');
    }
  });
  Future<void> _dataTemplate(WebProcess item) => _guard(() async {
    final path = await FilePicker.platform.saveFile(
      fileName: 'modelo-dados.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    final fields = item.fields.isEmpty ? ['nome'] : item.fields;
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert([
        {for (final field in fields) field: ''},
      ]),
    );
    _message('Modelo JSON salvo.');
  });

  Future<void> _execute(WebProcess item) async {
    final ids = _selectedRows.isEmpty ? null : _selectedRows.toList();
    final count = item.records.isEmpty
        ? 1
        : item.records
              .where((r) => r.pending && (ids == null || ids.contains(r.id)))
              .length;
    if (count == 0) {
      _message('Selecione registros pendentes.');
      return;
    }
    if (!await _confirm(
      'Executar ${item.name}?',
      'Serão executadas ${item.steps.length} etapas para $count registro(s) em:\n${item.url}\n\n${item.steps.asMap().entries.map((e) => '${e.key + 1}. ${e.value.name.isEmpty ? e.value.action.label : e.value.name}').join('\n')}',
    )) {
      return;
    }
    await _guard(() async {
      final result = await service.run(item.id, recordIds: ids);
      _message(
        'Concluídos: ${result['success']} · Falhas: ${result['failed']}',
      );
    });
  }

  Widget _configuration(WebProcess item) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              SelectableText(item.url),
              const SizedBox(height: 16),
              Text(
                'Confirmação: ${item.successText.isEmpty ? 'Somente conclusão das etapas' : item.successText}',
              ),
              Text(
                'Intervalo entre registros: ${item.delayMinMs / 1000} a ${item.delayMaxMs / 1000} segundos',
              ),
              Text(
                'Resultados: ${item.outputDirectory.isEmpty ? 'Documentos / GestorUFU Agente / AcoesWeb' : item.outputDirectory}',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: service.busy
                        ? null
                        : () => _guard(() => service.openSite(item.id)),
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Abrir site / fazer login'),
                  ),
                  OutlinedButton.icon(
                    onPressed: service.busy ? null : () => _projectDialog(item),
                    icon: const Icon(Icons.settings),
                    label: const Text('Configurar processo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: service.busy ? null : () => _exportProject(item),
                    icon: const Icon(Icons.download),
                    label: const Text('Exportar processo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: service.busy
                        ? null
                        : () => _useProcessTemplate(item),
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('Usar processo como modelo'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Cada processo usa seu próprio navegador. Faça login nele quando necessário; a sessão fica salva neste computador.',
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        '1. Configure as etapas na ordem desejada.\n2. Importe ou cadastre os dados do lote.\n3. Confira e execute os registros pendentes.',
      ),
    ],
  );

  Widget _steps(WebProcess item) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: service.busy ? null : () => _stepDialog(item),
              icon: const Icon(Icons.add),
              label: const Text('Adicionar ação'),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Text(
                'As ações serão executadas nesta ordem. Use as setas para reordenar.',
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: item.steps.isEmpty
            ? const Center(
                child: Text(
                  'Adicione a primeira ação e selecione um componente na página.',
                ),
              )
            : ListView.builder(
                itemCount: item.steps.length,
                itemBuilder: (context, index) {
                  final step = item.steps[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: ListTile(
                      leading: CircleAvatar(child: Text('${index + 1}')),
                      title: Text(
                        step.name.isEmpty ? step.action.label : step.name,
                      ),
                      subtitle: Text(
                        '${step.action.label}${step.selector.isEmpty ? '' : ' · ${step.selector}'}${step.value.isEmpty ? '' : '\n${step.value}'}',
                      ),
                      isThreeLine: step.value.isNotEmpty,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Mover para cima',
                            icon: const Icon(Icons.arrow_upward),
                            onPressed: service.busy || index == 0
                                ? null
                                : () => _guard(() async {
                                    final steps = [...item.steps];
                                    steps.insert(
                                      index - 1,
                                      steps.removeAt(index),
                                    );
                                    await service.saveSteps(item.id, steps);
                                  }),
                          ),
                          IconButton(
                            tooltip: 'Mover para baixo',
                            icon: const Icon(Icons.arrow_downward),
                            onPressed:
                                service.busy || index == item.steps.length - 1
                                ? null
                                : () => _guard(() async {
                                    final steps = [...item.steps];
                                    steps.insert(
                                      index + 1,
                                      steps.removeAt(index),
                                    );
                                    await service.saveSteps(item.id, steps);
                                  }),
                          ),
                          IconButton(
                            tooltip: 'Editar ação',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: service.busy
                                ? null
                                : () => _stepDialog(item, step),
                          ),
                          IconButton(
                            tooltip: 'Remover ação',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: service.busy
                                ? null
                                : () async {
                                    if (await _confirm(
                                      'Remover ação?',
                                      'A ação será retirada desta sequência.',
                                    )) {
                                      await _guard(
                                        () => service.saveSteps(
                                          item.id,
                                          item.steps
                                              .where((s) => s.id != step.id)
                                              .toList(),
                                        ),
                                      );
                                    }
                                  },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget _data(WebProcess item) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: service.busy ? null : () => _editRecord(item),
              icon: const Icon(Icons.add),
              label: const Text('Novo registro'),
            ),
            OutlinedButton.icon(
              onPressed: service.busy ? null : () => _importData(item),
              icon: const Icon(Icons.upload_file),
              label: const Text('Importar JSON'),
            ),
            OutlinedButton(
              onPressed: service.busy ? null : () => _exportData(item),
              child: const Text('Exportar dados'),
            ),
            TextButton(
              onPressed: service.busy ? null : () => _dataTemplate(item),
              child: const Text('Salvar modelo JSON'),
            ),
            Text(
              '${item.records.length} registros · ${item.records.where((r) => r.pending).length} pendentes',
            ),
          ],
        ),
      ),
      Expanded(
        child: item.records.isEmpty
            ? const Center(
                child: Text(
                  'Importe uma lista JSON ou cadastre registros.\nSem lote, o processo executa uma única vez usando valores fixos.',
                  textAlign: TextAlign.center,
                ),
              )
            : SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    onSelectAll: service.busy
                        ? null
                        : (checked) => setState(() {
                            if (checked == true) {
                              _selectedRows.addAll(
                                item.records.map((r) => r.id),
                              );
                            } else {
                              _selectedRows.clear();
                            }
                          }),
                    columns: [
                      const DataColumn(label: Text('Situação')),
                      for (final field in item.fields)
                        DataColumn(label: Text(field)),
                      const DataColumn(label: Text('Ações')),
                    ],
                    rows: [
                      for (final row in item.records)
                        DataRow(
                          selected: _selectedRows.contains(row.id),
                          onSelectChanged: service.busy
                              ? null
                              : (selected) => setState(() {
                                  if (selected == true) {
                                    _selectedRows.add(row.id);
                                  } else {
                                    _selectedRows.remove(row.id);
                                  }
                                }),
                          cells: [
                            DataCell(
                              Tooltip(
                                message: row.message,
                                child: Chip(
                                  label: Text(row.statusLabel),
                                  backgroundColor: switch (row.status) {
                                    'success' => Colors.green.withValues(
                                      alpha: .16,
                                    ),
                                    'failed' => Colors.red.withValues(
                                      alpha: .16,
                                    ),
                                    'review' => Colors.orange.withValues(
                                      alpha: .16,
                                    ),
                                    _ => null,
                                  },
                                ),
                              ),
                            ),
                            for (final field in item.fields)
                              DataCell(
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 220,
                                  ),
                                  child: Tooltip(
                                    message: row.values[field] ?? '',
                                    child: Text(
                                      row.values[field] ?? '',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                            DataCell(
                              PopupMenuButton<String>(
                                enabled: !service.busy,
                                onSelected: (action) => _guard(() async {
                                  if (action == 'edit') {
                                    await _editRecord(item, row);
                                  }
                                  if (action == 'remove' &&
                                      await _confirm(
                                        'Remover registro?',
                                        row.label,
                                      )) {
                                    await service.removeRecord(item.id, row.id);
                                  }
                                  if (action == 'reset' &&
                                      await _confirm(
                                        'Executar este registro novamente?',
                                        'Confira o resultado no site antes de repetir. O registro voltará a pendente.',
                                      )) {
                                    await service.resetRecord(item.id, row.id);
                                  }
                                }),
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Editar registro'),
                                  ),
                                  if (!row.pending)
                                    const PopupMenuItem(
                                      value: 'reset',
                                      child: Text('Marcar como pendente'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remover registro'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
      ),
    ],
  );

  Widget _execution(WebProcess item) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: service.busy ? null : () => _execute(item),
              icon: const Icon(Icons.play_arrow),
              label: Text(
                _selectedRows.isEmpty
                    ? 'Executar pendentes'
                    : 'Executar seleção',
              ),
            ),
            OutlinedButton.icon(
              onPressed: service.busy ? service.stop : null,
              icon: const Icon(Icons.stop),
              label: const Text('Parar após etapa atual'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(service.stage.isEmpty ? 'Pronto para executar.' : service.stage),
        const SizedBox(height: 8),
        if (service.busy) LinearProgressIndicator(value: service.progress),
        const SizedBox(height: 16),
        Expanded(
          child: Card(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [for (final line in service.log) SelectableText(line)],
            ),
          ),
        ),
        for (final row
            in item.records.where((r) => r.outputPath.isNotEmpty).take(3))
          SelectableText('Resultado de ${row.label}: ${row.outputPath}'),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final item = service.projects.where((p) => p.id == _selected).firstOrNull;
    return ModuleScaffold(
      moduleId: 'inserir-documentos-sei',
      actions: [
        FilledButton.icon(
          onPressed: service.busy ? null : () => _projectDialog(),
          icon: const Icon(Icons.add),
          label: const Text('Novo processo'),
        ),
        PopupMenuButton<String>(
          enabled: !service.busy,
          onSelected: (action) => _guard(() async {
            if (action == 'template') await _useProcessTemplate();
            if (action == 'import') await _importProject();
            if (action == 'remove' &&
                item != null &&
                await _confirm('Remover processo?', item.name)) {
              await service.removeProcess(item.id);
            }
          }),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'template',
              enabled: service.projects.isNotEmpty,
              child: const Text('Usar processo como modelo'),
            ),
            const PopupMenuItem(
              value: 'import',
              child: Text('Importar processo'),
            ),
            if (item != null)
              const PopupMenuItem(
                value: 'remove',
                child: Text('Remover processo'),
              ),
          ],
        ),
      ],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : service.projects.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.touch_app_rounded, size: 56),
                  const SizedBox(height: 16),
                  const Text(
                    'Crie uma sequência de ações para executar em um site.',
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton(
                        onPressed: () => _projectDialog(),
                        child: const Text('Novo processo'),
                      ),
                      OutlinedButton(
                        onPressed: _importProject,
                        child: const Text('Importar processo'),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_selected),
                    initialValue: _selected,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Processo'),
                    items: service.projects
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: service.busy
                        ? null
                        : (id) => setState(() {
                            _selected = id;
                            _selectedRows.clear();
                          }),
                  ),
                ),
                if (item != null)
                  Expanded(
                    child: DefaultTabController(
                      key: ValueKey(item.id),
                      length: 4,
                      child: Column(
                        children: [
                          const TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            tabs: [
                              Tab(text: 'Configuração'),
                              Tab(text: 'Etapas'),
                              Tab(text: 'Dados do lote'),
                              Tab(text: 'Execução'),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _configuration(item),
                                _steps(item),
                                _data(item),
                                _execution(item),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
