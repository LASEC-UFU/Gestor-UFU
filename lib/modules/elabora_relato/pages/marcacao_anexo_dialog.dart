import 'package:flutter/material.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/consulta_trecho.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';

/// Caixa de uma marcação num documento anexado: cor, perguntas à IA sobre
/// o trecho (explicação em linguagem simples, termos, pontos de atenção e
/// relação com as normas da base) e o comentário, que a IA pode ajudar a
/// redigir. Devolve a marcação atualizada (null = cancelado).
class MarcacaoAnexoDialog extends StatefulWidget {
  const MarcacaoAnexoDialog({
    required this.service,
    required this.documento,
    required this.local,
    required this.marcacao,
    required this.antes,
    required this.depois,
    this.perguntarAoAbrir = false,
    super.key,
  });

  final ParecerService service;
  final String documento;
  final String local;
  final MarcacaoAnexo marcacao;
  final String antes;
  final String depois;

  /// Abre já pedindo a explicação do trecho à IA.
  final bool perguntarAoAbrir;

  @override
  State<MarcacaoAnexoDialog> createState() => _MarcacaoAnexoDialogState();
}

class _MarcacaoAnexoDialogState extends State<MarcacaoAnexoDialog> {
  late final _pergunta = TextEditingController(text: widget.marcacao.pergunta);
  late final _comentario = TextEditingController(
    text: widget.marcacao.comentario,
  );
  late String _cor = widget.marcacao.cor;
  late String _revisao = widget.marcacao.revisao;
  late String _explicacaoGuardada = widget.marcacao.explicacaoIa;
  ExplicacaoTrecho? _explicacao;
  List<FonteConsulta> _fontes = const [];
  bool _ocupado = false;
  String _etapa = '';
  String? _erro;

  MarcacaoAnexo get m => widget.marcacao;

  static const _atalhos = [
    (
      'Explicar',
      'Explique em linguagem simples o que este trecho diz e o que ele '
          'implica para o parecer.',
    ),
    (
      'Implicações',
      'O que este trecho implica para a decisão do conselho? O que o relator '
          'precisa conferir?',
    ),
    (
      'Normas',
      'Este trecho está de acordo com as normas da base? Aponte fundamento ou '
          'contradição.',
    ),
    ('Termos e siglas', 'Explique os termos técnicos e as siglas do trecho.'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.perguntarAoAbrir) {
      if (_pergunta.text.trim().isEmpty) _pergunta.text = _atalhos.first.$2;
      WidgetsBinding.instance.addPostFrameCallback((_) => _perguntar());
    }
  }

  @override
  void dispose() {
    _pergunta.dispose();
    _comentario.dispose();
    super.dispose();
  }

  Future<List<FonteConsulta>> _buscarFontes(String consulta) async {
    try {
      return await widget.service.base.fontesPara(
        consulta,
        processo: widget.service.arvore.documentos,
        limiteBase: 5,
        limiteProcesso: 2,
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> _perguntar() async {
    final ia = widget.service.ia;
    if (ia == null) {
      setState(() => _erro = 'O Agente de IA não está configurado.');
      return;
    }
    setState(() {
      _ocupado = true;
      _erro = null;
      _etapa = 'Procurando normas relacionadas na base…';
    });
    try {
      final fontes = await _buscarFontes('${_pergunta.text}\n${m.texto}');
      if (!mounted) return;
      setState(() => _etapa = 'Consultando a IA…');
      final raw = await ia.gerar(
        sistema: ConsultaTrecho.sistemaExplicacao,
        prompt: ConsultaTrecho.promptExplicacao(
          documento: widget.documento,
          local: widget.local,
          trecho: m.texto,
          antes: widget.antes,
          depois: widget.depois,
          pergunta: _pergunta.text,
          fontes: fontes,
        ),
      );
      if (!mounted) return;
      final e = ConsultaTrecho.lerExplicacao(raw, fontes);
      setState(() {
        _fontes = fontes;
        _explicacao = e;
        _explicacaoGuardada = e.resumo;
        if (_comentario.text.trim().isEmpty && e.comentario.isNotEmpty) {
          _comentario.text = e.comentario;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _erro = 'Falha na consulta: $e');
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _etapa = '';
        });
      }
    }
  }

  Future<void> _melhorarComentario() async {
    final ia = widget.service.ia;
    if (ia == null) {
      setState(() => _erro = 'O Agente de IA não está configurado.');
      return;
    }
    setState(() {
      _ocupado = true;
      _erro = null;
      _etapa = 'Redigindo o comentário com a IA…';
    });
    try {
      final raw = await ia.gerar(
        sistema: ConsultaTrecho.sistemaComentario,
        prompt: ConsultaTrecho.promptComentario(
          documento: widget.documento,
          local: widget.local,
          trecho: m.texto,
          antes: widget.antes,
          depois: widget.depois,
          anotacao: _comentario.text,
          explicacao: _explicacaoGuardada,
          fontes: _fontes,
        ),
      );
      final texto = ConsultaTrecho.lerComentario(raw);
      if (mounted && texto.isNotEmpty) {
        setState(() => _comentario.text = texto);
      }
    } catch (e) {
      if (mounted) setState(() => _erro = 'Falha na consulta: $e');
    } finally {
      if (mounted) {
        setState(() {
          _ocupado = false;
          _etapa = '';
        });
      }
    }
  }

  void _salvar() => Navigator.pop(
    context,
    m.copyWith(
      cor: _cor,
      comentario: _comentario.text.trim(),
      explicacaoIa: _explicacaoGuardada,
      pergunta: _explicacao == null ? m.pergunta : _pergunta.text.trim(),
      revisao: _revisao,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      title: Row(
        children: [
          const Icon(Icons.border_color_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Marcação · ${widget.documento}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Cancelar',
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
              Text(widget.local, style: tema.textTheme.bodySmall),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 130),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Color(coresMarcacao[_cor]!).withAlpha(90),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(child: SelectableText(m.texto)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Cor: ', style: tema.textTheme.bodySmall),
                  for (final e in coresMarcacao.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InkWell(
                        onTap: () => setState(() => _cor = e.key),
                        customBorder: const CircleBorder(),
                        child: Tooltip(
                          message: e.key,
                          child: CircleAvatar(
                            radius: 11,
                            backgroundColor: Color(e.value),
                            child: _cor == e.key
                                ? const Icon(
                                    Icons.check,
                                    size: 14,
                                    color: Colors.black87,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const Divider(height: 24),
              Text(
                'Perguntar à IA sobre o trecho',
                style: tema.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _pergunta,
                enabled: !_ocupado,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText:
                      'Ex.: O que significa "carga horária extensionista"?',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (m.pergunta == 'audita_banco') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _revisao,
                  decoration: const InputDecoration(
                    labelText: 'Revisão da observação',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'pendente',
                      child: Text('Pendente'),
                    ),
                    DropdownMenuItem(value: 'aceito', child: Text('Aceitar')),
                    DropdownMenuItem(
                      value: 'rejeitado',
                      child: Text('Rejeitar'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _revisao = v);
                  },
                ),
              ],
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final (rotulo, texto) in _atalhos)
                    ActionChip(
                      label: Text(rotulo),
                      onPressed: _ocupado
                          ? null
                          : () {
                              _pergunta.text = texto;
                              _perguntar();
                            },
                    ),
                  FilledButton.tonalIcon(
                    onPressed: _ocupado ? null : _perguntar,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: const Text('Perguntar'),
                  ),
                ],
              ),
              if (_ocupado) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
                Text(_etapa, style: tema.textTheme.bodySmall),
              ],
              if (_erro != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _erro!,
                    style: TextStyle(color: tema.colorScheme.error),
                  ),
                ),
              if (_explicacao != null)
                ..._explicacaoView(tema, _explicacao!)
              else if (_explicacaoGuardada.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Explicação guardada', style: tema.textTheme.labelLarge),
                SelectableText(_explicacaoGuardada),
              ],
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text('Comentário', style: tema.textTheme.titleSmall),
                  ),
                  TextButton.icon(
                    onPressed: _ocupado ? null : _melhorarComentario,
                    icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                    label: Text(
                      _comentario.text.trim().isEmpty
                          ? 'Escrever com IA'
                          : 'Melhorar com IA',
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _comentario,
                enabled: !_ocupado,
                minLines: 3,
                maxLines: 10,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText:
                      'Sua anotação sobre o trecho (o que diz, por que importa, '
                      'o que conferir). A IA pode completar ou deixar mais clara.',
                  border: OutlineInputBorder(),
                ),
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
        FilledButton.icon(
          onPressed: _ocupado ? null : _salvar,
          icon: const Icon(Icons.check),
          label: const Text('Salvar marcação'),
        ),
      ],
    );
  }

  List<Widget> _explicacaoView(ThemeData tema, ExplicacaoTrecho e) => [
    const SizedBox(height: 12),
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tema.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(e.resposta.isEmpty ? '(sem resposta)' : e.resposta),
          if (!e.estruturada)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Resposta em texto livre: referências não conferidas.',
                style: TextStyle(color: tema.colorScheme.error, fontSize: 12),
              ),
            ),
          if (e.pontosAtencao.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Pontos de atenção', style: tema.textTheme.labelLarge),
            for (final x in e.pontosAtencao) Text('• $x'),
          ],
          if (e.termos.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Termos', style: tema.textTheme.labelLarge),
            for (final t in e.termos)
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${t.termo}: ',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(text: t.significado),
                  ],
                ),
              ),
          ],
          if (e.evidencias.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Normas e documentos', style: tema.textTheme.labelLarge),
            for (final ev in e.evidencias)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${ev.fonte.referencia}'
                      '${ev.relacao.isEmpty ? '' : ' · ${ev.relacao}'}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (ev.comentario.isNotEmpty) Text(ev.comentario),
                    Text(
                      ev.citacaoConfirmada
                          ? '"${ev.citacao}"'
                          : 'Trecho da fonte (citação da IA não conferida): '
                                '"${ev.fonte.texto.length > 400 ? '${ev.fonte.texto.substring(0, 399)}…' : ev.fonte.texto}"',
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),
          ],
          if (e.descartadas > 0)
            Text(
              '${e.descartadas} referência(s) a fontes inexistentes '
              'descartadas.',
              style: tema.textTheme.bodySmall,
            ),
          if (e.comentario.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _comentario.text = e.comentario),
                icon: const Icon(Icons.south, size: 16),
                label: const Text('Usar o comentário sugerido'),
              ),
            ),
          ],
        ],
      ),
    ),
  ];
}
