import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/consulta_trecho.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/base_documentos_dialog.dart';

/// Aplica no editor o [texto] aceito (a [proposta] da IA, talvez editada
/// pelo relator); devolve a mensagem de erro ou null.
typedef AceitarProposta =
    Future<String?> Function(String texto, PropostaTexto proposta);

/// Dados de um comentário criado a partir da consulta.
typedef SalvarComentario = Future<void> Function(Map<String, dynamic> campos);

/// Caixa "Consultar a IA" sobre um trecho (ou o cursor) do parecer:
/// perguntas verificadas nas fontes da base e propostas de texto, que só
/// entram no relato quando o usuário clica em "Aceitar".
class ConsultaIaDialog extends StatefulWidget {
  const ConsultaIaDialog({
    required this.service,
    required this.trecho,
    required this.aceitar,
    required this.salvarComentario,
    super.key,
  });

  final ParecerService service;
  final TrechoConsultado trecho;
  final AceitarProposta aceitar;
  final SalvarComentario salvarComentario;

  @override
  State<ConsultaIaDialog> createState() => _ConsultaIaDialogState();
}

class _ConsultaIaDialogState extends State<ConsultaIaDialog> {
  final _pedido = TextEditingController();
  final _proposta = TextEditingController();
  bool _ocupado = false;
  String _etapa = '';
  String? _erro;
  RespostaConsulta? _resposta;
  PropostaTexto? _propostaIa;
  List<FonteConsulta> _fontes = const [];
  String _ultimaPergunta = '';
  bool _comentado = false;

  TrechoConsultado get t => widget.trecho;
  BaseDocumentosService get base => widget.service.base;

  @override
  void initState() {
    super.initState();
    base.carregar();
  }

  @override
  void dispose() {
    _pedido.dispose();
    _proposta.dispose();
    super.dispose();
  }

  Future<List<FonteConsulta>> _buscarFontes(String pedido) async {
    setState(() => _etapa = 'Conferindo a base de documentos…');
    final fontes = await base.fontesPara(
      '$pedido\n${t.texto.isEmpty ? '${t.anterior} ${t.posterior}' : t.texto}',
      processo: widget.service.arvore.documentos,
    );
    return fontes;
  }

  Future<void> _perguntar() async {
    final ia = widget.service.ia;
    if (ia == null) {
      setState(() => _erro = 'O Agente de IA não está configurado.');
      return;
    }
    final pergunta = _pedido.text.trim();
    setState(() {
      _ocupado = true;
      _erro = null;
      _resposta = null;
      _propostaIa = null;
      _comentado = false;
    });
    try {
      final fontes = await _buscarFontes(pergunta);
      if (!mounted) return;
      setState(
        () =>
            _etapa = 'Consultando a IA (${fontes.length} trecho(s) de fontes)…',
      );
      final raw = await ia.gerar(
        sistema: ConsultaTrecho.sistemaPergunta,
        prompt: ConsultaTrecho.promptPergunta(t, pergunta, fontes),
      );
      if (!mounted) return;
      setState(() {
        _fontes = fontes;
        _ultimaPergunta = pergunta;
        _resposta = ConsultaTrecho.lerPergunta(raw, fontes);
      });
    } catch (e) {
      if (mounted) setState(() => _erro = 'Falha na consulta: ${_msg(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _etapa = '';
        });
      }
    }
  }

  Future<void> _propor() async {
    final ia = widget.service.ia;
    if (ia == null) {
      setState(() => _erro = 'O Agente de IA não está configurado.');
      return;
    }
    final instrucao = _pedido.text.trim();
    setState(() {
      _ocupado = true;
      _erro = null;
      _resposta = null;
      _propostaIa = null;
    });
    try {
      final fontes = await _buscarFontes(instrucao);
      if (!mounted) return;
      setState(() => _etapa = 'Pedindo a proposta à IA…');
      final raw = await ia.gerar(
        sistema: ConsultaTrecho.sistemaProposta,
        prompt: ConsultaTrecho.promptProposta(t, instrucao, fontes),
      );
      if (!mounted) return;
      final proposta = ConsultaTrecho.lerProposta(raw, fontes);
      setState(() {
        _fontes = fontes;
        if (proposta == null) {
          _erro = 'A IA não devolveu um texto. Tente reformular o pedido.';
        } else {
          _propostaIa = proposta;
          _proposta.text = proposta.texto;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _erro = 'Falha na consulta: ${_msg(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _etapa = '';
        });
      }
    }
  }

  Future<void> _aceitar() async {
    final texto = _proposta.text.trim();
    if (texto.isEmpty) return;
    setState(() => _ocupado = true);
    final erro = await widget.aceitar(texto, _propostaIa!);
    if (!mounted) return;
    if (erro == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _ocupado = false;
        _erro = erro;
      });
    }
  }

  Future<void> _comentar() async {
    final r = _resposta;
    if (r == null) return;
    final e = r.evidencias.firstOrNull;
    await widget.salvarComentario({
      // O ponto é a resposta; a avaliação vira etiqueta (não substitui o
      // texto).
      'texto': r.resposta,
      'avaliacao': r.avaliacao.rotulo,
      'categoria': 'consulta_ia',
      'pergunta': _ultimaPergunta,
      'referencia': r.evidencias.isEmpty
          ? 'Fundamento não localizado nas fontes'
          : r.evidencias.map((x) => x.fonte.referencia).toSet().join('; '),
      'citacao_literal': e != null && e.citacaoConfirmada ? e.citacao : '',
      'status': 'revisar',
    });
    if (mounted) setState(() => _comentado = true);
  }

  static String _msg(Object e) => switch (e) {
    StateError(:final message) => message,
    _ => '$e'.replaceFirst('Exception: ', ''),
  };

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      title: Row(
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Consultar a IA')),
          IconButton(
            tooltip: 'Fechar (o relato não é alterado)',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _trechoBox(tema),
              const SizedBox(height: 8),
              _statusBase(tema),
              const SizedBox(height: 10),
              TextField(
                controller: _pedido,
                minLines: 2,
                maxLines: 5,
                enabled: !_ocupado,
                decoration: InputDecoration(
                  labelText: 'Pergunta ou instrução',
                  hintText: t.soCursor
                      ? 'Ex.: Escreva um parágrafo citando o prazo previsto '
                            'na resolução.'
                      : 'Ex.: Estão me pedindo para mudar este texto para '
                            '"…". Isso é plausível?',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final (rotulo, texto) in [
                    if (!t.soCursor)
                      (
                        'Está fundamentado?',
                        'O que este trecho afirma está fundamentado nas normas e documentos?',
                      ),
                    if (!t.soCursor)
                      (
                        'Explicar',
                        'Explique em linguagem simples o que o trecho afirma e qual norma o sustenta.',
                      ),
                    if (!t.soCursor)
                      (
                        'Aprimorar redação',
                        'Aprimore a redação, mantendo o sentido.',
                      ),
                    if (!t.soCursor)
                      (
                        'Mais conciso',
                        'Deixe o trecho mais conciso, sem perder informação.',
                      ),
                    if (t.soCursor)
                      (
                        'Continuar o texto',
                        'Escreva a continuação adequada neste ponto.',
                      ),
                  ])
                    ActionChip(
                      label: Text(rotulo),
                      onPressed: _ocupado
                          ? null
                          : () => setState(() => _pedido.text = texto),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _ocupado ? null : _perguntar,
                    icon: const Icon(Icons.policy_outlined),
                    label: const Text('Perguntar às fontes'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _ocupado ? null : _propor,
                    icon: const Icon(Icons.edit_note),
                    label: Text(
                      t.soCursor
                          ? 'Propor texto para inserir'
                          : 'Propor novo texto',
                    ),
                  ),
                ],
              ),
              if (_ocupado) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
                if (_etapa.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_etapa, style: tema.textTheme.bodySmall),
                  ),
              ],
              if (_erro != null) ...[
                const SizedBox(height: 10),
                Text(_erro!, style: TextStyle(color: tema.colorScheme.error)),
              ],
              if (_resposta != null) ..._respostaView(tema, _resposta!),
              if (_propostaIa != null) ..._propostaView(tema, _propostaIa!),
            ],
          ),
        ),
      ),
      actions: [
        if (_resposta != null)
          TextButton.icon(
            onPressed: _comentado || _ocupado ? null : _comentar,
            icon: Icon(_comentado ? Icons.check : Icons.add_comment_outlined),
            label: Text(
              _comentado ? 'Comentário salvo' : 'Salvar como comentário',
            ),
          ),
        if (_propostaIa != null) ...[
          TextButton(
            onPressed: _ocupado
                ? null
                : () => setState(() {
                    _propostaIa = null;
                    _proposta.clear();
                  }),
            child: const Text('Descartar'),
          ),
          FilledButton.icon(
            onPressed: _ocupado ? null : _aceitar,
            icon: const Icon(Icons.check),
            label: Text(
              t.soCursor ? 'Aceitar e inserir' : 'Aceitar e substituir',
            ),
          ),
        ] else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
      ],
    );
  }

  Widget _trechoBox(ThemeData tema) {
    final estilo = tema.textTheme.bodyMedium;
    return Container(
      constraints: const BoxConstraints(maxHeight: 140),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tema.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: t.soCursor
            ? Text.rich(
                TextSpan(
                  style: estilo,
                  children: [
                    const TextSpan(
                      text: 'Inserir no cursor: ',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(text: '…${_fim(t.anterior, 160)}'),
                    TextSpan(
                      text: ' ▌ ',
                      style: TextStyle(
                        color: tema.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextSpan(text: '${_ini(t.posterior, 160)}…'),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Trecho selecionado (${t.texto.length} caracteres)',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(t.texto, style: estilo),
                ],
              ),
      ),
    );
  }

  static String _fim(String s, int n) =>
      s.length <= n ? s : s.substring(s.length - n);
  static String _ini(String s, int n) => s.length <= n ? s : s.substring(0, n);

  Widget _statusBase(ThemeData tema) {
    return ListenableBuilder(
      listenable: base,
      builder: (context, _) {
        final b = base.base;
        final texto = !base.configurada
            ? 'Nenhuma pasta de documentos escolhida: a IA usará só os '
                  'documentos lidos da árvore do SEI.'
            : base.preparando
            ? 'Preparando a base: ${base.etapa} (${base.progresso}/${base.total})'
            : b == null
            ? 'Base ainda não preparada em ${base.pasta}.'
            : 'Base: ${b.documentos.length} documento(s), '
                  '${b.totalTrechos} trechos'
                  '${b.semTexto.isEmpty ? '' : ' · ${b.semTexto.length} sem texto extraível'}'
                  ' · ${p.basename(base.pasta)}';
        return Row(
          children: [
            Icon(Icons.folder_open_outlined, size: 16, color: tema.hintColor),
            const SizedBox(width: 6),
            Expanded(child: Text(texto, style: tema.textTheme.bodySmall)),
            TextButton(
              onPressed: () => mostrarBaseDocumentos(context, base),
              child: const Text('Base de documentos…'),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _respostaView(ThemeData tema, RespostaConsulta r) {
    final cor = switch (r.avaliacao) {
      Avaliacao.fundamentado => Colors.green.shade700,
      Avaliacao.contradiz => tema.colorScheme.error,
      Avaliacao.parcial => Colors.orange.shade800,
      Avaliacao.semInformacao || Avaliacao.indefinido => tema.hintColor,
    };
    return [
      const Divider(height: 24),
      Row(
        children: [
          Icon(Icons.circle, size: 12, color: cor),
          const SizedBox(width: 6),
          Text(
            r.avaliacao.rotulo,
            style: TextStyle(fontWeight: FontWeight.bold, color: cor),
          ),
        ],
      ),
      const SizedBox(height: 6),
      SelectableText(r.resposta.isEmpty ? '(sem explicação)' : r.resposta),
      if (r.avaliacao == Avaliacao.indefinido)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'A IA não estruturou a resposta: as referências acima não foram '
            'conferidas com a base.',
            style: TextStyle(color: tema.colorScheme.error, fontSize: 12),
          ),
        ),
      if (r.descartadas > 0)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${r.descartadas} referência(s) da IA a fontes inexistentes '
            'foram descartadas.',
            style: tema.textTheme.bodySmall,
          ),
        ),
      if (r.evidencias.isEmpty && r.avaliacao != Avaliacao.indefinido)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _fontes.isEmpty
                ? 'Nenhum trecho relevante foi encontrado na base nem nos '
                      'documentos do processo.'
                : 'Nenhuma evidência foi apontada nas ${_fontes.length} '
                      'fonte(s) consultadas.',
            style: tema.textTheme.bodySmall,
          ),
        ),
      for (final e in r.evidencias) _evidencia(tema, e),
    ];
  }

  Widget _evidencia(ThemeData tema, Evidencia e) {
    final f = e.fonte;
    final relacao = switch (_Relacao.de(e.relacao)) {
      'apoia' => ('apoia', Colors.green.shade700),
      'contradiz' => ('contradiz', tema.colorScheme.error),
      _ => ('contexto', tema.hintColor),
    };
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  f.caminho.isEmpty
                      ? Icons.account_tree_outlined
                      : Icons.description_outlined,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    f.referencia,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Chip(
                  label: Text(relacao.$1),
                  labelStyle: TextStyle(color: relacao.$2, fontSize: 11),
                  visualDensity: VisualDensity.compact,
                ),
                if (f.caminho.isNotEmpty)
                  IconButton(
                    tooltip: 'Abrir o documento original',
                    icon: const Icon(Icons.open_in_new, size: 18),
                    onPressed: () => _abrir(p.join(f.caminho, f.arquivo)),
                  ),
              ],
            ),
            if (e.comentario.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(e.comentario),
            ],
            const SizedBox(height: 6),
            Text(
              e.citacaoConfirmada
                  ? 'Texto original (citação conferida na fonte):'
                  : 'Texto original da fonte (a citação da IA não foi '
                        'encontrada literalmente; exibido o trecho):',
              style: tema.textTheme.bodySmall,
            ),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: relacao.$2, width: 3)),
                color: tema.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  e.citacaoConfirmada ? e.citacao : f.texto,
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text:
                        '"${e.citacaoConfirmada ? e.citacao : f.texto}" (${f.referencia})',
                  ),
                ),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copiar citação'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _propostaView(ThemeData tema, PropostaTexto pr) => [
    const Divider(height: 24),
    Text(
      t.soCursor
          ? 'Texto proposto para inserir'
          : 'Texto proposto (substituirá o trecho)',
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 6),
    TextField(
      controller: _proposta,
      minLines: 3,
      maxLines: 12,
      enabled: !_ocupado,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        helperText:
            'Revise e ajuste se quiser. Nada muda no relato até você clicar '
            'em "Aceitar". Depois, Ctrl+Z no editor desfaz.',
      ),
    ),
    if (pr.justificativa.isNotEmpty) ...[
      const SizedBox(height: 8),
      Text(
        'Justificativa: ${pr.justificativa}',
        style: tema.textTheme.bodySmall,
      ),
    ],
    for (final a in pr.alertas)
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: Colors.orange.shade800,
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(a)),
          ],
        ),
      ),
    if (pr.fontes.isNotEmpty) ...[
      const SizedBox(height: 8),
      Text(
        'Fontes usadas: ${pr.fontes.map((f) => f.referencia).join('; ')}',
        style: tema.textTheme.bodySmall,
      ),
    ],
  ];

  Future<void> _abrir(String caminho) async {
    try {
      await Process.start('explorer.exe', [caminho]);
    } catch (_) {}
  }
}

/// Normaliza a relação devolvida pela IA ("Apoia", "contradição"…).
class _Relacao {
  const _Relacao._();

  static String de(String s) {
    final x = s.toLowerCase();
    if (x.startsWith('apoi') || x.startsWith('fundament')) return 'apoia';
    if (x.startsWith('contradi')) return 'contradiz';
    return 'contexto';
  }
}
