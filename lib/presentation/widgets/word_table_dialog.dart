import 'dart:convert';
import 'dart:io';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/web_table_clipboard.dart';
import 'package:gestor_ufu/data/word_table_generator.dart';
import 'package:gestor_ufu/domain/entities/course_config.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showWordTableDialog(
  BuildContext context,
  CourseConfig config,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => WordTableDialog(config: config),
  );
}

class WordTableDialog extends StatefulWidget {
  final CourseConfig config;

  const WordTableDialog({super.key, required this.config});

  @override
  State<WordTableDialog> createState() => _WordTableDialogState();
}

class _WordTableDialogState extends State<WordTableDialog> {
  WordTablePreset _preset = WordTablePreset.practice;
  final Set<WordTableColumn> _columns = {
    WordTableColumn.date,
    WordTableColumn.modality,
    WordTableColumn.classGroup,
    WordTableColumn.taughtSubject,
  };

  WordTableOptions get _options =>
      WordTableOptions(preset: _preset, columns: _columns);

  int get _rowCount =>
      WordTableGenerator.buildRows(widget.config, _options).length;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tabela para Word'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<WordTablePreset>(
                segments: const [
                  ButtonSegment(
                    value: WordTablePreset.practice,
                    label: Text('Prática'),
                    icon: Icon(Icons.science_outlined),
                  ),
                  ButtonSegment(
                    value: WordTablePreset.theory,
                    label: Text('Teórica'),
                    icon: Icon(Icons.menu_book_outlined),
                  ),
                  ButtonSegment(
                    value: WordTablePreset.all,
                    label: Text('Todas'),
                    icon: Icon(Icons.table_rows_outlined),
                  ),
                ],
                selected: {_preset},
                onSelectionChanged: (value) {
                  setState(() => _preset = value.first);
                },
              ),
              const SizedBox(height: 16),
              Text(
                'Linhas encontradas: $_rowCount',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              const Text(
                'Colunas',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: WordTableColumn.values.map((column) {
                  final selected = _columns.contains(column);
                  return FilterChip(
                    label: Text(column.label),
                    selected: selected,
                    onSelected: (value) {
                      setState(() {
                        if (value) {
                          _columns.add(column);
                        } else if (_columns.length > 1) {
                          _columns.remove(column);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fechar'),
        ),
        OutlinedButton.icon(
          onPressed: _rowCount == 0 ? null : _saveHtml,
          icon: const Icon(Icons.save_alt),
          label: const Text('Salvar HTML'),
        ),
        ElevatedButton.icon(
          onPressed: _rowCount == 0 ? null : _copyTable,
          icon: const Icon(Icons.content_copy),
          label: const Text('Copiar'),
        ),
      ],
    );
  }

  Future<void> _copyTable() async {
    final text = WordTableGenerator.generateTsv(widget.config, _options);
    var copiedAsTable = false;
    if (kIsWeb) {
      final html = WordTableGenerator.generateHtml(widget.config, _options);
      copiedAsTable = await copyHtmlTableForWeb(html: html, plainText: text);
    }
    if (!copiedAsTable) {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          copiedAsTable
              ? 'Tabela copiada como tabela. Cole no Word.'
              : 'Tabela copiada. Cole no Word.',
        ),
        backgroundColor: AppTheme.accentGreen,
      ),
    );
  }

  Future<void> _saveHtml() async {
    final html = WordTableGenerator.generateHtml(widget.config, _options);
    final bytes = Uint8List.fromList(utf8.encode(html));
    final filename = _safeFileName(
      '${widget.config.name}_${_preset.label}_word.html',
    );
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Salvar tabela para Word',
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: ['html'],
      bytes: bytes,
    );
    if (result == null || !mounted) return;
    if (!kIsWeb) {
      File(result).writeAsBytesSync(bytes);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Tabela HTML salva com sucesso!'),
        backgroundColor: AppTheme.accentGreen,
      ),
    );
  }

  String _safeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]+'), '_');
  }
}
