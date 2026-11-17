import 'package:flutter/material.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';

/// Abre o simulado de arguição.
Future<void> mostrarSimuladoArguicao(
  BuildContext context,
  ParecerService service,
) => showDialog<void>(
  context: context,
  builder: (_) => _SimuladoArguicaoDialog(service: service),
);

/// Simulado de arguição: as "possíveis perguntas" guardadas nos
/// comentários da análise, uma de cada vez, com a resposta escondida até o
/// relator pedir. O resultado (acertou / rever) fica no comentário.
class _SimuladoArguicaoDialog extends StatefulWidget {
  const _SimuladoArguicaoDialog({required this.service});

  final ParecerService service;

  @override
  State<_SimuladoArguicaoDialog> createState() =>
      _SimuladoArguicaoDialogState();
}

class _SimuladoArguicaoDialogState extends State<_SimuladoArguicaoDialog> {
  late List<String> _ordem;
  int _atual = 0;
  bool _mostrar = false;
  bool _soRever = false;
  int _acertos = 0;
  int _rever = 0;

  ParecerService get service => widget.service;

  @override
  void initState() {
    super.initState();
    _montar(embaralhar: false);
  }

  List<Map<String, dynamic>> get _todas => service.perguntasArguicao();

  static bool _marcadaRever(Map<String, dynamic> c) {
    final t = c['treino'];
    return t is! Map || t['ultimo'] != 'acertou';
  }

  void _montar({required bool embaralhar}) {
    final lista = [
      for (final c in _todas)
        if (!_soRever || _marcadaRever(c)) '${c['id']}',
    ];
    if (embaralhar) lista.shuffle();
    _ordem = lista;
    _atual = 0;
    _mostrar = false;
    _acertos = 0;
    _rever = 0;
  }

  Map<String, dynamic>? get _pergunta {
    if (_atual >= _ordem.length) return null;
    final id = _ordem[_atual];
    return _todas.where((c) => '${c['id']}' == id).firstOrNull;
  }

  Future<void> _responder(bool acertou) async {
    final c = _pergunta;
    if (c == null) return;
    await service.registrarTreino('${c['id']}', acertou: acertou);
    if (!mounted) return;
    setState(() {
      acertou ? _acertos++ : _rever++;
      _atual++;
      _mostrar = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final total = _todas.length;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      title: Row(
        children: [
          const Icon(Icons.record_voice_over_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Simulado de arguição')),
          IconButton(
            tooltip: 'Fechar',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 480,
        child: total == 0
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Ainda não há perguntas. Use "⋮ › Analisar a seção com a '
                    'base" no painel de comentários de cada seção: cada '
                    'apontamento traz uma possível pergunta da arguição e a '
                    'resposta oral sugerida.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      FilterChip(
                        label: const Text('Só as que preciso rever'),
                        selected: _soRever,
                        onSelected: (v) => setState(() {
                          _soRever = v;
                          _montar(embaralhar: false);
                        }),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _montar(embaralhar: true)),
                        icon: const Icon(Icons.shuffle, size: 18),
                        label: const Text('Embaralhar e recomeçar'),
                      ),
                      const Spacer(),
                      Text(
                        _ordem.isEmpty
                            ? '0 perguntas'
                            : '${(_atual + 1).clamp(1, _ordem.length)} de '
                                  '${_ordem.length}',
                        style: tema.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: _ordem.isEmpty ? 0 : _atual / _ordem.length,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _pergunta == null
                        ? _resultado(tema)
                        : _cartao(tema, _pergunta!),
                  ),
                ],
              ),
      ),
      actions: [
        if (_pergunta != null && !_mostrar)
          FilledButton.icon(
            onPressed: () => setState(() => _mostrar = true),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Mostrar resposta'),
          ),
        if (_pergunta != null && _mostrar) ...[
          OutlinedButton.icon(
            onPressed: () => _responder(false),
            icon: const Icon(Icons.replay),
            label: const Text('Preciso rever'),
          ),
          FilledButton.icon(
            onPressed: () => _responder(true),
            icon: const Icon(Icons.check),
            label: const Text('Respondi bem'),
          ),
        ],
        if (_pergunta != null)
          TextButton(
            onPressed: () => setState(() {
              _atual++;
              _mostrar = false;
            }),
            child: const Text('Pular'),
          ),
      ],
    );
  }

  Widget _resultado(ThemeData tema) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.emoji_events_outlined, size: 40, color: tema.hintColor),
        const SizedBox(height: 8),
        Text(
          _ordem.isEmpty
              ? 'Nenhuma pergunta marcada para rever.'
              : 'Fim do simulado: $_acertos respondida(s) bem, $_rever para '
                    'rever.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () => setState(() {
            _soRever = true;
            _montar(embaralhar: true);
          }),
          child: const Text('Treinar as que preciso rever'),
        ),
      ],
    ),
  );

  Widget _cartao(ThemeData tema, Map<String, dynamic> c) {
    final secao = ParecerSecao.porId('${c['secao']}')?.titulo ?? '';
    final treino = c['treino'] is Map ? c['treino'] as Map : const {};
    final resposta = <String, String>{
      'Resposta oral sugerida': '${c['resposta_oral'] ?? ''}',
      'Em palavras simples': '${c['explicacao_simples'] ?? ''}',
      'Por que importa': '${c['importancia'] ?? ''}',
      'Referência': '${c['referencia'] ?? ''}',
      'Citação literal da fonte': '${c['citacao_literal'] ?? ''}',
    }..removeWhere((_, v) => v.trim().isEmpty);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              secao,
              if ('${c['trecho'] ?? ''}'.trim().isNotEmpty)
                'sobre: "${c['trecho']}"',
            ].where((x) => x.isNotEmpty).join(' · '),
            style: tema.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            ParecerService.perguntaArguicao(c),
            style: tema.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (treino.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Treinos anteriores: ${treino['acertos'] ?? 0} bem, '
                '${treino['rever'] ?? 0} para rever.',
                style: tema.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          if (!_mostrar)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: tema.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Responda em voz alta e depois clique em "Mostrar resposta".',
                style: TextStyle(color: tema.hintColor),
              ),
            )
          else if (resposta.isEmpty)
            const Text('Não há resposta sugerida para esta pergunta.')
          else
            for (final e in resposta.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.key,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SelectableText(e.value),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
