import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/equivalencia/domain/equivalencia_models.dart';

class EquivalenciaHistoryWindowApp extends StatefulWidget {
  const EquivalenciaHistoryWindowApp({
    required this.caseId,
    required this.student,
    required this.entries,
    required this.channelName,
    required this.isLight,
    super.key,
  });

  final String caseId, student, channelName;
  final List<HistoricalSubject> entries;
  final bool isLight;

  @override
  State<EquivalenciaHistoryWindowApp> createState() =>
      _EquivalenciaHistoryWindowAppState();
}

class _EquivalenciaHistoryWindowAppState
    extends State<EquivalenciaHistoryWindowApp> {
  late String _caseId = widget.caseId;
  late String _student = widget.student;
  late List<HistoricalSubject> _entries = [...widget.entries];
  late final WindowMethodChannel _channel = WindowMethodChannel(
    widget.channelName,
    mode: ChannelMode.bidirectional,
  );

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'setHistory') return false;
      final payload = Map<String, dynamic>.from(call.arguments as Map);
      if (!mounted) return false;
      setState(() {
        _caseId = payload['caseId'] as String;
        _student = payload['student'] as String? ?? '';
        _entries = (payload['entries'] as List)
            .map(
              (item) => HistoricalSubject.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
      });
      return true;
    });
  }

  Future<void> _save(List<HistoricalSubject> entries) async {
    setState(() => _entries = entries);
    await _channel.invokeMethod<bool>('saveHistory', {
      'caseId': _caseId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    });
  }

  Future<void> _close() async {
    try {
      await _channel.invokeMethod<bool>('closed');
    } finally {
      await (await WindowController.fromCurrentEngine()).hide();
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: widget.isLight ? ThemeMode.light : ThemeMode.dark,
    home: Scaffold(
      appBar: AppBar(
        title: Text('Histórico visual · $_student'),
        actions: [
          TextButton.icon(
            onPressed: _close,
            icon: const Icon(Icons.check),
            label: const Text('Concluir'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: EquivalenciaHistoryGrid(
          student: _student,
          entries: _entries,
          onChanged: _save,
        ),
      ),
    ),
  );
}

class EquivalenciaHistoryGrid extends StatefulWidget {
  const EquivalenciaHistoryGrid({
    required this.student,
    required this.entries,
    required this.onChanged,
    super.key,
  });

  final String student;
  final List<HistoricalSubject> entries;
  final Future<void> Function(List<HistoricalSubject>) onChanged;

  @override
  State<EquivalenciaHistoryGrid> createState() =>
      _EquivalenciaHistoryGridState();
}

class _EquivalenciaHistoryGridState extends State<EquivalenciaHistoryGrid> {
  final _horizontalScrollController = ScrollController();
  static const _statuses = ['Não cursada', 'Dispensado', 'Aprovado'];

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    super.dispose();
  }

  Future<void> _scrollPeriods(double direction) async {
    if (!_horizontalScrollController.hasClients) return;
    final position = _horizontalScrollController.position;
    final target = (position.pixels + position.viewportDimension * direction)
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    await _horizontalScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  Color _color(String status) => switch (status) {
    'Dispensado' => Colors.blue.shade300,
    'Aprovado' => Colors.lightGreen.shade400,
    _ => Colors.grey.shade300,
  };

  Future<void> _cycle(HistoricalSubject entry) async {
    if (entry.status == 'Dispensado') return;
    final index = widget.entries.indexOf(entry);
    if (index < 0) return;
    final updated = [...widget.entries];
    updated[index] = entry.copyWith(
      status: entry.status == 'Aprovado' ? 'Não cursada' : 'Aprovado',
    );
    try {
      await widget.onChanged(updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Não foi possível salvar o histórico: $error'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final periods = widget.entries
        .map(
          (entry) =>
              entry.subject.period.isEmpty ? 'Optativas' : entry.subject.period,
        )
        .toSet()
        .toList();
    periods.sort((a, b) {
      if (a == 'Optativas') return 1;
      if (b == 'Optativas') return -1;
      final aNumber =
          int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '') ?? 0;
      final bNumber =
          int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '') ?? 0;
      return aNumber.compareTo(bNumber);
    });
    final grouped = <String, List<HistoricalSubject>>{
      for (final period in periods)
        period: widget.entries
            .where(
              (entry) =>
                  (entry.subject.period.isEmpty
                      ? 'Optativas'
                      : entry.subject.period) ==
                  period,
            )
            .toList(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Clique para alternar entre não cursada e aprovado. Azul: dispensado por equivalência, com alteração apenas nos blocos. Verde: indisponível para equivalência.',
                    ),
                    for (final status in _statuses)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 16,
                            height: 16,
                            color: _color(status),
                          ),
                          const SizedBox(width: 5),
                          Text(status),
                        ],
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Períodos anteriores',
                onPressed: () => _scrollPeriods(-0.8),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Próximos períodos',
                onPressed: () => _scrollPeriods(0.8),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: _horizontalScrollController,
            thumbVisibility: true,
            interactive: true,
            child: SingleChildScrollView(
              controller: _horizontalScrollController,
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final period in periods)
                    SizedBox(
                      width: 210,
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.all(4),
                            padding: const EdgeInsets.all(10),
                            color: AppTheme.divider,
                            child: Text(
                              period,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemCount: grouped[period]!.length,
                              itemBuilder: (context, index) {
                                final entry = grouped[period]![index];
                                return Card(
                                  color: _color(entry.status),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: entry.status == 'Dispensado'
                                        ? null
                                        : () => _cycle(entry),
                                    child: Padding(
                                      padding: const EdgeInsets.all(9),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.subject.code,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(entry.subject.name),
                                          const SizedBox(height: 6),
                                          Text(
                                            '${entry.subject.theoretical}T + ${entry.subject.practical}P · ${entry.subject.hours} h · ${entry.status}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
