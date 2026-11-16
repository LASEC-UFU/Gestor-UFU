import 'package:flutter/material.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/extrair_arvore_view.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/parecer_editor.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

const _laranja = Color(0xFFFFB454);

String _dica(ParecerSecao s) => switch (s) {
  ParecerSecao.relatorio =>
    'Relato do processo: apresente o objeto e liste os documentos (use '
        '"1 · Extrair árvore" para gerar a lista e os resumos).',
  ParecerSecao.fundamentacao =>
    'Fundamentação e análise: histórico, normas aplicáveis, manifestações '
        'dos órgãos consultados e análise da relatoria.',
  ParecerSecao.conclusao =>
    'Conclusão: "CONSIDERANDO…" e o voto ("sou, salvo melhor juízo…, de '
        'PARECER FAVORÁVEL…").',
};

/// Aba de uma seção do parecer (II. FUNDAMENTAÇÃO E ANÁLISE, III.
/// CONCLUSÃO): barra do parecer e o editor HTML.
class ParecerSecaoView extends StatelessWidget {
  const ParecerSecaoView({
    required this.secao,
    required this.service,
    super.key,
  });

  final ParecerSecao secao;
  final ParecerService service;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 14, 28, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ParecerBarra(service: service, titulo: secao.titulo),
        const SizedBox(height: 12),
        Expanded(
          child: ParecerEditor(
            secao: secao,
            service: service,
            dica: _dica(secao),
          ),
        ),
      ],
    ),
  );
}

/// Aba "I. RELATÓRIO": etapa 1 extrai a árvore do processo (com resumos
/// pelo Agente de IA); etapa 2 redige o relatório no editor.
class RelatorioView extends StatefulWidget {
  const RelatorioView({required this.service, super.key});

  final ParecerService service;

  @override
  State<RelatorioView> createState() => _RelatorioViewState();
}

class _RelatorioViewState extends State<RelatorioView> {
  int _etapa = 0;

  @override
  void initState() {
    super.initState();
    if (widget.service.parecer.relatorio.trim().isNotEmpty) _etapa = 1;
  }

  Future<void> _enviarAoRelatorio() async {
    final docs = widget.service.arvore.documentos;
    if (docs.isEmpty) return;
    final semResumo = docs.where((d) => d.resumo.trim().isEmpty).length;
    var porPastas = docs.length > 20;
    final intro = TextEditingController(
      text:
          'O Processo trata de … sendo composto por ${docs.length} '
          'documentos descritos a seguir:',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Enviar documentos ao relatório'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${docs.length} documento(s) serão inseridos na posição do '
                  'cursor do editor, no formato "1. Ofício 12 (link SEI) – de '
                  '03 de março de 2025, resumo;".',
                ),
                if (semResumo > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '$semResumo documento(s) ainda sem resumo.',
                    style: TextStyle(color: AppTheme.warning),
                  ),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: intro,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Parágrafo de introdução (opcional)',
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: porPastas,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Separar por pastas (Pasta I, II… a cada 20)'),
                  onChanged: (v) => setLocal(() => porPastas = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text('Inserir no relatório'),
            ),
          ],
        ),
      ),
    );
    final introducao = intro.text;
    intro.dispose();
    if (ok != true || !mounted) return;
    final html = widget.service.inventarioHtml(
      porPastas: porPastas,
      introducao: introducao,
    );
    setState(() => _etapa = 1);
    // O editor precisa estar visível para receber a inserção no cursor.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    widget.service.inserirNoEditor(ParecerSecao.relatorio, html);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 14, 28, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ParecerBarra(
          service: widget.service,
          titulo: ParecerSecao.relatorio.titulo,
          extra: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: 0,
                icon: Icon(Icons.account_tree_rounded, size: 17),
                label: Text('1 · Extrair árvore'),
              ),
              ButtonSegment(
                value: 1,
                icon: Icon(Icons.edit_note_rounded, size: 18),
                label: Text('2 · Redigir relatório'),
              ),
            ],
            selected: {_etapa},
            onSelectionChanged: (s) => setState(() => _etapa = s.first),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: IndexedStack(
            index: _etapa,
            children: [
              ExtrairArvoreView(
                service: widget.service.arvore,
                onEnviarAoRelatorio: _enviarAoRelatorio,
                compacto: true,
              ),
              ParecerEditor(
                secao: ParecerSecao.relatorio,
                service: widget.service,
                dica: _dica(ParecerSecao.relatorio),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Barra comum às abas do parecer: título da seção, dados do parecer
/// (assunto, ementa, vocativo…) e "Inserir no SEI".
class ParecerBarra extends StatelessWidget {
  const ParecerBarra({
    required this.service,
    required this.titulo,
    this.extra,
    super.key,
  });

  final ParecerService service;
  final String titulo;
  final Widget? extra;

  Future<void> _inserir(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final p = service.parecer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inserir o parecer no SEI?'),
        content: SizedBox(
          width: 520,
          child: Text(
            'No Edge aberto pelo app (aba I. RELATÓRIO › Extrair árvore):\n\n'
            '• se houver um editor de Parecer aberto, ele será preenchido;\n'
            '• senão, será gerado um documento "Parecer" (público) no '
            'processo aberto.\n\n'
            'Assunto, ementa, vocativo, abertura, as três seções, o fecho e o '
            'signatário vão para os seus campos no modelo do SEI. O documento '
            'é salvo sem assinatura.'
            '${p.assunto.trim().isEmpty ? '\n\nAtenção: o assunto está vazio (Dados do parecer).' : ''}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('Inserir no SEI'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final avisos = await service.inserirNoSei();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            avisos.isEmpty
                ? 'Parecer inserido e salvo no SEI. Revise e assine no SEI.'
                : 'Parecer inserido no SEI. Avisos: ${avisos.join(' ')}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.danger,
          duration: const Duration(seconds: 10),
          content: Text(e is CommandException ? e.message : '$e'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          titulo,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        ?extra,
        const SizedBox(width: 4),
        OutlinedButton.icon(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => DadosParecerDialog(service: service),
          ),
          icon: const Icon(Icons.badge_outlined, size: 18),
          label: Text(
            service.parecer.assunto.trim().isEmpty
                ? 'Dados do parecer'
                : 'Dados do parecer ✓',
          ),
        ),
        FilledButton.icon(
          onPressed: service.inserindo ? null : () => _inserir(context),
          icon: service.inserindo
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload_file_rounded, size: 18),
          label: Text(service.inserindo ? 'Inserindo…' : 'Inserir no SEI'),
          style: FilledButton.styleFrom(
            backgroundColor: _laranja,
            foregroundColor: const Color(0xFF241606),
          ),
        ),
      ],
    ),
  );
}

/// Campos do modelo "Parecer" do SEI fora das três seções.
class DadosParecerDialog extends StatefulWidget {
  const DadosParecerDialog({required this.service, super.key});

  final ParecerService service;

  @override
  State<DadosParecerDialog> createState() => _DadosParecerDialogState();
}

class _DadosParecerDialogState extends State<DadosParecerDialog> {
  late final Parecer _p = widget.service.parecer;
  late final _assunto = TextEditingController(text: _p.assunto);
  late final _ementa = TextEditingController(text: _p.ementa);
  late final _vocativo = TextEditingController(text: _p.vocativo);
  late final _abertura = TextEditingController(text: _p.abertura);
  late final _fecho = TextEditingController(text: _p.fecho);
  late final _nome = TextEditingController(text: _p.nomeSignatario);
  late final _cargo = TextEditingController(text: _p.cargoSignatario);
  late final _descricao = TextEditingController(text: _p.descricaoSei);

  @override
  void dispose() {
    for (final c in [
      _assunto,
      _ementa,
      _vocativo,
      _abertura,
      _fecho,
      _nome,
      _cargo,
      _descricao,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _salvar() {
    widget.service.atualizar(
      widget.service.parecer.copyWith(
        assunto: _assunto.text.trim(),
        ementa: _ementa.text.trim(),
        vocativo: _vocativo.text.trim(),
        abertura: _abertura.text.trim(),
        fecho: _fecho.text.trim(),
        nomeSignatario: _nome.text.trim(),
        cargoSignatario: _cargo.text.trim(),
        descricaoSei: _descricao.text.trim(),
      ),
    );
    Navigator.pop(context);
  }

  Widget _campo(
    TextEditingController c,
    String rotulo, {
    String? ajuda,
    int linhas = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      minLines: linhas,
      maxLines: linhas == 1 ? 1 : linhas + 4,
      decoration: InputDecoration(labelText: rotulo, helperText: ajuda),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Dados do parecer'),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'PARECER Nº, PROCESSO Nº e INTERESSADO(S) são preenchidos pelo '
              'próprio SEI.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            _campo(_assunto, 'Assunto', linhas: 2),
            _campo(
              _ementa,
              'Ementa',
              ajuda: 'Texto à direita, abaixo do assunto.',
              linhas: 3,
            ),
            _campo(
              _vocativo,
              'Vocativo',
              ajuda: 'Uma linha por vocativo (ex.: "Senhor Presidente,").',
              linhas: 2,
            ),
            _campo(
              _abertura,
              'Abertura (antes de I. RELATÓRIO)',
              ajuda:
                  'Ex.: "Em cumprimento ao Despacho… que designa esta relatora…". '
                  'Uma linha por parágrafo.',
              linhas: 3,
            ),
            _campo(_fecho, 'Fecho'),
            Row(
              children: [
                Expanded(child: _campo(_nome, 'Nome do servidor')),
                const SizedBox(width: 12),
                Expanded(child: _campo(_cargo, 'Cargo/função')),
              ],
            ),
            _campo(
              _descricao,
              'Descrição no SEI (opcional)',
              ajuda: 'Metadado ao gerar o documento; vazio = usa o assunto.',
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
      FilledButton(onPressed: _salvar, child: const Text('Salvar')),
    ],
  );
}
