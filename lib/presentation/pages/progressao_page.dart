import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/data/services/progressao_pdf_service.dart';
import 'package:gestor_ufu/data/services/progressao_store.dart';
import 'package:gestor_ufu/domain/entities/progressao.dart';
import 'package:gestor_ufu/domain/progressao/resolucao_condir_03_2017.dart';

const _uuid = Uuid();

String _fmtData(DateTime? d) => d == null ? '' : ProgressaoPdfService.data(d);

double _parseNumero(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.')) ?? 0;

/// Progressão / Promoção docente — Resolução 03/2017 CONDIR (com alterações
/// da Resolução SEI 05/2018).
class ProgressaoPage extends StatefulWidget {
  const ProgressaoPage({super.key});

  @override
  State<ProgressaoPage> createState() => _ProgressaoPageState();
}

class _ProgressaoPageState extends State<ProgressaoPage> {
  final _store = ProgressaoStore();
  List<ProgressaoDocente> _items = [];
  String? _abertoId;
  bool _busy = true;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      _store.saveAll(_items);
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _items = await _store.list();
    } on Object catch (error) {
      _message('Não foi possível ler os processos salvos: $error');
    }
    if (mounted) setState(() => _busy = false);
  }

  void _update(ProgressaoDocente p) {
    final updated = p.copyWith(atualizadoEm: DateTime.now());
    setState(() {
      final i = _items.indexWhere((e) => e.id == p.id);
      if (i >= 0) {
        _items[i] = updated;
      } else {
        _items.insert(0, updated);
      }
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 500),
      () => _store.saveAll(_items),
    );
  }

  void _novo() {
    final p = ProgressaoDocente(id: _uuid.v4(), dataDocumento: DateTime.now());
    _update(p);
    setState(() => _abertoId = p.id);
  }

  void _duplicar(ProgressaoDocente origem) {
    final json = origem.toJson()
      ..['id'] = _uuid.v4()
      ..['atualizadoEm'] = null;
    _update(ProgressaoDocente.fromJson(json));
  }

  Future<void> _excluir(ProgressaoDocente p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir processo'),
        content: Text(
          'Excluir o processo de ${p.docente.isEmpty ? 'docente sem nome' : p.docente} '
          '(${_movimento(p)})? Esta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _items.removeWhere((e) => e.id == p.id));
    await _store.saveAll(_items);
  }

  Future<void> _gerarPdf(ProgressaoDocente p) async {
    try {
      final nome = p.docente.trim().isEmpty
          ? 'docente'
          : p.docente.trim().replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
      final alvo = p.alvo.denominacao(p.titulacao).replaceAll(' ', '');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Salvar requerimento e relatório em PDF',
        fileName:
            'Progressao_${alvo}_${nome.replaceAll(RegExp(r'\s+'), '')}.pdf',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (path == null) return;
      final bytes = await ProgressaoPdfService().gerar(p);
      final file = File(
        path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      _message('PDF gerado: ${file.path}');
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', file.path]);
      }
    } on Object catch (error) {
      _message('Não foi possível gerar o PDF: $error');
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  static String _movimento(ProgressaoDocente p) {
    final atual = p.atual;
    final alvo = p.alvo.denominacao(p.titulacao);
    return atual == null ? alvo : '${atual.denominacao(p.titulacao)} → $alvo';
  }

  @override
  Widget build(BuildContext context) {
    final aberto = _items.where((e) => e.id == _abertoId).firstOrNull;
    if (aberto != null) {
      return _Editor(
        key: ValueKey(aberto.id),
        processo: aberto,
        onChanged: _update,
        onClose: () => setState(() => _abertoId = null),
        onPdf: () => _gerarPdf(aberto),
      );
    }
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1440),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          onPressed: () => context.go('/'),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        const Icon(
                          Icons.trending_up_rounded,
                          color: AppTheme.accent,
                          size: 30,
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 560,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Progressão / Promoção Docente',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                'Relatório de atividades conforme a Resolução 03/2017 CONDIR '
                                '(com alterações da Res. SEI 05/2018)',
                                style: TextStyle(color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        IntrinsicWidth(
                          child: FilledButton.icon(
                            onPressed: _novo,
                            icon: const Icon(Icons.add),
                            label: const Text('Novo processo'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _busy
                          ? const Center(child: CircularProgressIndicator())
                          : _items.isEmpty
                          ? _vazio()
                          : ListView.separated(
                              itemCount: _items.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, i) => _tile(_items[i]),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(ProgressaoDocente p) {
    final ref = p.referencia;
    final cor = ref == null
        ? AppTheme.warning
        : p.atingeReferencia
        ? AppTheme.green
        : AppTheme.danger;
    return Container(
      decoration: BoxDecoration(
        gradient: AppTheme.cardGradient,
        border: Border.all(color: AppTheme.divider),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: cor.withAlpha(35),
          child: Icon(Icons.trending_up_rounded, color: cor),
        ),
        title: Text(
          '${p.docente.isEmpty ? 'Docente sem nome' : p.docente} · ${_movimento(p)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${p.carreira.rotulo} · ${p.regime.rotulo} · Interstício ${_fmtData(p.intersticioInicio)} a ${_fmtData(p.intersticioFim)}\n'
          '${ProgressaoPdfService.pontos(p.total)} de ${ref ?? '—'} pontos · ${p.lancamentos.length} lançamento(s)',
        ),
        isThreeLine: true,
        onTap: () => setState(() => _abertoId = p.id),
        trailing: Wrap(
          spacing: 2,
          children: [
            IconButton(
              tooltip: 'Gerar PDF',
              onPressed: () => _gerarPdf(p),
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
            IconButton(
              tooltip: 'Duplicar',
              onPressed: () => _duplicar(p),
              icon: const Icon(Icons.copy_outlined),
            ),
            IconButton(
              tooltip: 'Excluir',
              onPressed: () => _excluir(p),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vazio() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.trending_up_rounded,
          size: 54,
          color: AppTheme.textSecondary,
        ),
        const SizedBox(height: 12),
        Text(
          'Nenhum processo cadastrado',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          'Crie um processo, lance as atividades por item do Anexo 1 e gere o requerimento com o relatório em PDF.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      ],
    ),
  );
}

// ===========================================================================
// Editor
// ===========================================================================

class _Editor extends StatelessWidget {
  const _Editor({
    super.key,
    required this.processo,
    required this.onChanged,
    required this.onClose,
    required this.onPdf,
  });

  final ProgressaoDocente processo;
  final ValueChanged<ProgressaoDocente> onChanged;
  final VoidCallback onClose;
  final VoidCallback onPdf;

  static const _abas = {
    TabelaAnexo1.ensino: 'A1.1 Ensino',
    TabelaAnexo1.orientacao: 'A1.2 Orientação',
    TabelaAnexo1.producao: 'A1.3 Produção',
    TabelaAnexo1.semRemuneracao: 'A1.4 Sem remuneração',
    TabelaAnexo1.comRemuneracao: 'A1.5 Com remuneração',
    TabelaAnexo1.gestao: 'A1.6 Gestão',
    TabelaAnexo1.licencas: 'A1.7 Licenças',
  };

  @override
  Widget build(BuildContext context) {
    final p = processo;
    final ref = p.referencia;
    final cor = ref == null
        ? AppTheme.warning
        : p.atingeReferencia
        ? AppTheme.green
        : AppTheme.danger;
    return DefaultTabController(
      length: 3 + _abas.length,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: AppTheme.bgGradient),
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 24, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Voltar à lista',
                        onPressed: onClose,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.docente.isEmpty ? 'Novo processo' : p.docente,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${p.tipoMovimento[0].toUpperCase()}${p.tipoMovimento.substring(1)}: '
                              '${_ProgressaoPageState._movimento(p)} · ${artigoAvaliacao(p.alvo)} da Res. 03/2017',
                              style: TextStyle(color: AppTheme.textSecondary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: cor.withAlpha(30),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cor),
                        ),
                        child: Text(
                          '${ProgressaoPdfService.pontos(p.total)} / ${ref ?? '—'} pontos',
                          style: TextStyle(
                            color: cor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: onPdf,
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Gerar PDF'),
                      ),
                    ],
                  ),
                ),
                TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    const Tab(text: 'Dados'),
                    const Tab(text: 'Textos'),
                    for (final entry in _abas.entries)
                      Tab(
                        text:
                            '${entry.value} (${ProgressaoPdfService.pontos(p.totalTabela(entry.key))})',
                      ),
                    const Tab(text: 'Resumo'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _DadosTab(processo: p, onChanged: onChanged),
                      _TextosTab(processo: p, onChanged: onChanged),
                      for (final t in _abas.keys)
                        _TabelaTab(
                          processo: p,
                          tabela: t,
                          onChanged: onChanged,
                        ),
                      _ResumoTab(processo: p),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _cartao({required Widget child, EdgeInsets? padding}) => Container(
  padding: padding ?? const EdgeInsets.all(18),
  decoration: BoxDecoration(
    gradient: AppTheme.cardGradient,
    border: Border.all(color: AppTheme.divider),
    borderRadius: BorderRadius.circular(16),
  ),
  child: child,
);

Widget _secao(String titulo, List<Widget> campos) => _cartao(
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        titulo,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 14, runSpacing: 14, children: campos),
    ],
  ),
);

/// Campo de texto que mantém o próprio controller (evita saltos de cursor).
class _Campo extends StatefulWidget {
  const _Campo({
    required this.label,
    required this.value,
    required this.onChanged,
    this.width = 320,
    this.maxLines = 1,
    this.hint,
    this.numero = false,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final double? width;
  final int maxLines;
  final String? hint;
  final bool numero;

  @override
  State<_Campo> createState() => _CampoState();
}

class _CampoState extends State<_Campo> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _Campo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Atualiza apenas quando o valor mudou por fora (ex.: cálculo por datas).
    final atual = widget.numero
        ? _parseNumero(_controller.text) != _parseNumero(widget.value)
        : _controller.text != widget.value;
    if (atual && oldWidget.value != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _controller,
      maxLines: widget.maxLines,
      minLines: 1,
      keyboardType: widget.numero
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
      ),
      onChanged: widget.onChanged,
    );
    return widget.width == null
        ? field
        : SizedBox(width: widget.width, child: field);
  }
}

class _CampoData extends StatelessWidget {
  const _CampoData({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    child: InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(1990),
          lastDate: DateTime(2100),
          helpText: label,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          suffixIcon: const Icon(Icons.calendar_month_outlined, size: 18),
        ),
        child: Text(value == null ? 'dd/mm/aaaa' : _fmtData(value)),
      ),
    ),
  );
}

Widget _drop<T>({
  Key? key,
  required String label,
  required T value,
  required List<T> values,
  required String Function(T) text,
  required ValueChanged<T> onChanged,
  double width = 320,
}) => SizedBox(
  width: width,
  child: DropdownButtonFormField<T>(
    key: key ?? ValueKey('$label|$value'),
    isExpanded: true,
    initialValue: value,
    decoration: InputDecoration(labelText: label, isDense: true),
    items: [
      for (final v in values)
        DropdownMenuItem(
          value: v,
          child: Text(text(v), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  ),
);

// ------------------------------------------------------------------- Dados
class _DadosTab extends StatelessWidget {
  const _DadosTab({required this.processo, required this.onChanged});

  final ProgressaoDocente processo;
  final ValueChanged<ProgressaoDocente> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = processo;
    final alvos = posicoesAlvo(p.carreira);
    final alvoAtual = alvos.firstWhere(
      (a) => a.id == p.alvoId,
      orElse: () => alvos.first,
    );
    String rotuloAlvo(PosicaoCarreira a) {
      final anterior = posicaoAnterior(a);
      final ref = pontuacaoReferencia(
        alvo: a,
        regime: p.regime,
        titulacao: p.titulacao,
      );
      return '${anterior?.denominacao(p.titulacao) ?? ''} → ${a.denominacao(p.titulacao)}'
          '  (${ref == null ? 'sem referência' : '$ref pts'})';
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _secao('Docente', [
          _Campo(
            label: 'Nome do docente',
            value: p.docente,
            onChanged: (v) => onChanged(p.copyWith(docente: v)),
            width: 420,
          ),
          _Campo(
            label: 'Matrícula SIAPE',
            value: p.siape,
            onChanged: (v) => onChanged(p.copyWith(siape: v)),
            width: 180,
          ),
          _Campo(
            label: 'Lotação (Unidade)',
            value: p.lotacao,
            hint: 'Faculdade de Engenharia Elétrica',
            onChanged: (v) => onChanged(p.copyWith(lotacao: v)),
            width: 420,
          ),
          _drop<Regime>(
            label: 'Regime de trabalho',
            value: p.regime,
            values: Regime.values,
            text: (r) => r.rotulo,
            onChanged: (v) => onChanged(p.copyWith(regime: v)),
            width: 220,
          ),
          _drop<Titulacao>(
            label: 'Titulação',
            value: p.titulacao,
            values: Titulacao.values,
            text: (t) => '${t.sigla} — ${t.rotulo}',
            onChanged: (v) => onChanged(p.copyWith(titulacao: v)),
            width: 320,
          ),
        ]),
        const SizedBox(height: 14),
        _secao('Carreira e movimentação', [
          _drop<Carreira>(
            label: 'Carreira',
            value: p.carreira,
            values: Carreira.values,
            text: (c) => c.rotulo,
            onChanged: (v) => onChanged(
              p.copyWith(carreira: v, alvoId: posicoesAlvo(v).first.id),
            ),
            width: 360,
          ),
          _drop<PosicaoCarreira>(
            key: ValueKey(
              'alvo-${p.carreira.name}-${p.regime.name}-${p.titulacao.name}',
            ),
            label: 'Movimentação (atual → pretendida)',
            value: alvoAtual,
            values: alvos,
            text: rotuloAlvo,
            onChanged: (v) => onChanged(p.copyWith(alvoId: v.id)),
            width: 520,
          ),
          SizedBox(
            width: 900,
            child: Text(
              p.referencia == null
                  ? 'Não há pontuação de referência nos Anexos 2/3 para esta classe, nível e titulação. '
                        'Verifique a titulação (as classes D/Associado e E/Titular exigem doutorado).'
                  : '${p.tipoMovimento[0].toUpperCase()}${p.tipoMovimento.substring(1)} — '
                        'pontuação mínima de ${p.referencia} pontos (${tabelaReferencia(p.carreira, p.regime)}); '
                        'avaliação pelo ${artigoAvaliacao(p.alvo)} da Resolução 03/2017.'
                        '${p.alvo.titular ? ' A promoção a Titular exige ainda Memorial ou Tese aprovado por Comissão Especial.' : ''}'
                        '${p.carreira == Carreira.ebtt && p.regime == Regime.h40 ? ' O Anexo 3 não traz tabela de 40h; foi usada a tabela de DE.' : ''}',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        _secao('Interstício e período do relatório', [
          _CampoData(
            label: 'Início do interstício',
            value: p.intersticioInicio,
            onChanged: (d) => onChanged(p.copyWith(intersticioInicio: d)),
          ),
          _CampoData(
            label: 'Fim do interstício',
            value: p.intersticioFim,
            onChanged: (d) => onChanged(p.copyWith(intersticioFim: d)),
          ),
          if (p.intersticioInicio != null)
            OutlinedButton.icon(
              onPressed: () {
                final i = p.intersticioInicio!;
                onChanged(
                  p.copyWith(
                    intersticioFim: DateTime(
                      i.year + 2,
                      i.month,
                      i.day,
                    ).subtract(const Duration(days: 1)),
                  ),
                );
              },
              icon: const Icon(Icons.event_repeat, size: 18),
              label: const Text('Fim = início + 24 meses'),
            ),
          _CampoData(
            label: 'Início do relatório',
            value: p.relatorioInicio,
            onChanged: (d) => onChanged(p.copyWith(relatorioInicio: d)),
          ),
          _CampoData(
            label: 'Fim do relatório',
            value: p.relatorioFim,
            onChanged: (d) => onChanged(p.copyWith(relatorioFim: d)),
          ),
          _Campo(
            label: 'Semestres considerados',
            value: p.semestres,
            hint: '2022/01 parcial; 2022/02; 2023/01; 2023/02; 2024/01',
            onChanged: (v) => onChanged(p.copyWith(semestres: v)),
            width: 520,
          ),
          SizedBox(
            width: 900,
            child: Text(
              'O protocolo pode ocorrer até 90 dias antes ou a qualquer tempo após o fim do interstício '
              '(§ 4º do art. 3º, redação da Res. SEI 05/2018). Pedidos autuados após 30 dias do fim do '
              'interstício alteram a data de referência e o efeito financeiro (§ 2º do art. 13).',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        _secao('Requerimento', [
          _Campo(
            label: 'Destinatário (após "Ao")',
            value: p.destinatario,
            hint:
                'Diretor da Faculdade de Engenharia Elétrica Prof. Dr. Fulano de Tal',
            onChanged: (v) => onChanged(p.copyWith(destinatario: v)),
            width: 640,
          ),
          _Campo(
            label: 'Cidade',
            value: p.cidade,
            onChanged: (v) => onChanged(p.copyWith(cidade: v)),
            width: 200,
          ),
          _CampoData(
            label: 'Data do requerimento',
            value: p.dataDocumento,
            onChanged: (d) => onChanged(p.copyWith(dataDocumento: d)),
          ),
          SizedBox(
            width: 640,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    p.logoPath.isEmpty
                        ? 'Sem logotipo no cabeçalho do PDF'
                        : 'Logotipo: ${p.logoPath}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: const ['png', 'jpg', 'jpeg'],
                    );
                    final path = result?.files.single.path;
                    if (path != null) onChanged(p.copyWith(logoPath: path));
                  },
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Escolher logotipo'),
                ),
                if (p.logoPath.isNotEmpty)
                  IconButton(
                    tooltip: 'Remover logotipo',
                    onPressed: () => onChanged(p.copyWith(logoPath: '')),
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          ),
        ]),
      ],
    );
  }
}

// ------------------------------------------------------------------ Textos
class _TextosTab extends StatelessWidget {
  const _TextosTab({required this.processo, required this.onChanged});

  final ProgressaoDocente processo;
  final ValueChanged<ProgressaoDocente> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = processo;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _cartao(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Assiduidade, responsabilidade e qualidade do trabalho',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                'O PDF inicia a seção citando o inciso correspondente da resolução; '
                'este texto vem em seguida.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 10),
              _Campo(
                label: 'Texto',
                value: p.textoAssiduidade,
                maxLines: 6,
                width: null,
                onChanged: (v) => onChanged(p.copyWith(textoAssiduidade: v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _cartao(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Avaliação didática (com participação discente)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 10),
              _Campo(
                label: 'Texto antes da lista',
                value: p.textoAvaliacaoDidatica,
                maxLines: 6,
                width: null,
                onChanged: (v) =>
                    onChanged(p.copyWith(textoAvaliacaoDidatica: v)),
              ),
              const SizedBox(height: 12),
              _Campo(
                label: 'Disciplinas avaliadas (uma por linha)',
                hint:
                    '2023/01 – FEELT32602 – Instrumentação Industrial II (2023-1_FEELT32602_Avaliacao1.pdf)',
                value: p.avaliacoesDidaticas.join('\n'),
                maxLines: 8,
                width: null,
                onChanged: (v) => onChanged(
                  p.copyWith(
                    avaliacoesDidaticas: v
                        .split('\n')
                        .map((e) => e.trimRight())
                        .toList(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _Campo(
                label: 'Texto após a lista',
                value: p.textoAvaliacaoConclusao,
                maxLines: 6,
                width: null,
                onChanged: (v) =>
                    onChanged(p.copyWith(textoAvaliacaoConclusao: v)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------- Tabelas do Anexo 1
class _TabelaTab extends StatelessWidget {
  const _TabelaTab({
    required this.processo,
    required this.tabela,
    required this.onChanged,
  });

  final ProgressaoDocente processo;
  final TabelaAnexo1 tabela;
  final ValueChanged<ProgressaoDocente> onChanged;

  void _setLancamentos(List<LancamentoProgressao> lista) =>
      onChanged(processo.copyWith(lancamentos: lista));

  void _adicionar(int item) {
    final lista = List.of(processo.lancamentos);
    // Insere após o último lançamento do mesmo item, mantendo a ordem visual.
    final ultimo = lista.lastIndexWhere((l) => l.item == item);
    final novo = LancamentoProgressao(id: _uuid.v4(), item: item);
    if (ultimo >= 0) {
      lista.insert(ultimo + 1, novo);
    } else {
      lista.add(novo);
    }
    _setLancamentos(lista);
  }

  Future<void> _escolherItem(BuildContext context) async {
    final itens = anexo1.where((i) => i.tabela == tabela).toList();
    final escolhido = await showDialog<int>(
      context: context,
      builder: (_) => _ItemPicker(itens: itens),
    );
    if (escolhido != null) _adicionar(escolhido);
  }

  @override
  Widget build(BuildContext context) {
    final usados = processo.itensUsados(tabela);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Tabela ${tabela.codigo} — ${tabela.titulo} (${tabela.faixa})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            Text(
              'Total: ${ProgressaoPdfService.pontos(processo.totalTabela(tabela))} pontos',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _escolherItem(context),
              icon: const Icon(Icons.add),
              label: const Text('Adicionar item'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (usados.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                'Nenhuma atividade lançada nesta tabela. Use "Adicionar item" para escolher um item do Anexo 1.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          ),
        for (final numero in usados) ...[
          _ItemCard(
            processo: processo,
            item: itemAnexo1(numero)!,
            onAdicionar: () => _adicionar(numero),
            onAlterar: (l) => _setLancamentos([
              for (final e in processo.lancamentos) e.id == l.id ? l : e,
            ]),
            onRemover: (l) => _setLancamentos(
              processo.lancamentos.where((e) => e.id != l.id).toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ItemPicker extends StatefulWidget {
  const _ItemPicker({required this.itens});

  final List<ItemAnexo1> itens;

  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  String _busca = '';

  @override
  Widget build(BuildContext context) {
    final q = _busca.toLowerCase().trim();
    final lista = widget.itens
        .where(
          (i) =>
              q.isEmpty ||
              '${i.numero} ${i.descricao}'.toLowerCase().contains(q),
        )
        .toList();
    return AlertDialog(
      title: const Text('Escolher item do Anexo 1'),
      content: SizedBox(
        width: 760,
        height: 520,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar por número ou descrição',
              ),
              onChanged: (v) => setState(() => _busca = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: lista.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final item = lista[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      child: Text(
                        '${item.numero}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    title: Text(item.descricao),
                    subtitle: Text(
                      item.alteradoPor.isEmpty
                          ? item.regra
                          : '${item.regra} · ${item.alteradoPor}',
                    ),
                    onTap: () => Navigator.pop(context, item.numero),
                  );
                },
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
      ],
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.processo,
    required this.item,
    required this.onAdicionar,
    required this.onAlterar,
    required this.onRemover,
  });

  final ProgressaoDocente processo;
  final ItemAnexo1 item;
  final VoidCallback onAdicionar;
  final ValueChanged<LancamentoProgressao> onAlterar;
  final ValueChanged<LancamentoProgressao> onRemover;

  @override
  Widget build(BuildContext context) {
    final lancs = processo.lancamentosDoItem(item.numero);
    final bruto = processo.pontosBrutosItem(item.numero);
    final pontos = processo.pontosItem(item.numero);
    final limitado = pontos < bruto;
    final regra = item.tipo == TipoPontuacao.fracaoReferenciaPorDia
        ? '${item.regra} = ${ProgressaoPdfService.pontos(item.valorUnitario((processo.referencia ?? 0).toDouble()))} por dia'
        : item.regra;
    final header = TextStyle(
      color: AppTheme.textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    return _cartao(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: AppTheme.accent.withAlpha(40),
                child: Text(
                  '${item.numero}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.descricao,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.alteradoPor.isEmpty
                          ? regra
                          : '$regra · redação da ${item.alteradoPor}',
                      style: TextStyle(color: AppTheme.accent, fontSize: 12),
                    ),
                    if (item.nota.isNotEmpty)
                      Text(
                        item.nota,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${ProgressaoPdfService.pontos(pontos)} pts',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  if (limitado)
                    Text(
                      'limitado (bruto ${ProgressaoPdfService.pontos(bruto)})',
                      style: TextStyle(color: AppTheme.warning, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(width: 100, child: Text('Período', style: header)),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Text('Atividade / descrição', style: header),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: Text('Comprovante', style: header)),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: Text(
                  'Qtd. (${item.unidade})',
                  style: header,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.periodo != PeriodoItem.nenhum) const SizedBox(width: 40),
              SizedBox(
                width: 80,
                child: Text(
                  'Pontos',
                  style: header,
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 40),
            ],
          ),
          for (final l in lancs)
            _LinhaLancamento(
              key: ValueKey(l.id),
              lancamento: l,
              item: item,
              pontos: processo.pontosLancamento(l),
              onChanged: onAlterar,
              onRemove: () => onRemover(l),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAdicionar,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Linha'),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinhaLancamento extends StatelessWidget {
  const _LinhaLancamento({
    super.key,
    required this.lancamento,
    required this.item,
    required this.pontos,
    required this.onChanged,
    required this.onRemove,
  });

  final LancamentoProgressao lancamento;
  final ItemAnexo1 item;
  final double pontos;
  final ValueChanged<LancamentoProgressao> onChanged;
  final VoidCallback onRemove;

  Future<void> _datas(BuildContext context) async {
    final l = lancamento;
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1990),
      lastDate: DateTime(2100),
      initialDateRange: l.inicio != null && l.fim != null
          ? DateTimeRange(start: l.inicio!, end: l.fim!)
          : null,
      helpText: item.periodo == PeriodoItem.meses
          ? 'Período (calcula meses completos)'
          : 'Período (calcula dias)',
    );
    if (range == null) return;
    final qtd = item.periodo == PeriodoItem.meses
        ? mesesCompletos(range.start, range.end)
        : diasEntre(range.start, range.end);
    onChanged(
      l.copyWith(
        inicio: range.start,
        fim: range.end,
        quantidade: qtd.toDouble(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = lancamento;
    final datas = l.inicio != null && l.fim != null
        ? '${_fmtData(l.inicio)} a ${_fmtData(l.fim)}'
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Campo(
            label: '',
            hint: '2023/01',
            value: l.periodo,
            width: 100,
            onChanged: (v) => onChanged(l.copyWith(periodo: v)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Campo(
                  label: '',
                  value: l.descricao,
                  width: null,
                  maxLines: 3,
                  onChanged: (v) => onChanged(l.copyWith(descricao: v)),
                ),
                if (datas != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      datas,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _Campo(
              label: '',
              hint: 'arquivo.pdf',
              value: l.comprovante,
              width: null,
              onChanged: (v) => onChanged(l.copyWith(comprovante: v)),
            ),
          ),
          const SizedBox(width: 8),
          _Campo(
            label: '',
            value: l.quantidade == 0 ? '' : formatarNumero(l.quantidade),
            numero: true,
            width: 110,
            onChanged: (v) =>
                onChanged(l.copyWith(quantidade: _parseNumero(v))),
          ),
          if (item.periodo != PeriodoItem.nenhum)
            IconButton(
              tooltip: item.periodo == PeriodoItem.meses
                  ? 'Calcular meses completos por datas'
                  : 'Calcular dias por datas',
              onPressed: () => _datas(context),
              icon: const Icon(Icons.date_range_outlined, size: 20),
            ),
          SizedBox(
            width: 80,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                ProgressaoPdfService.pontos(pontos),
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Remover linha',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Resumo
class _ResumoTab extends StatelessWidget {
  const _ResumoTab({required this.processo});

  final ProgressaoDocente processo;

  @override
  Widget build(BuildContext context) {
    final p = processo;
    final avisos = <String>[
      if (p.docente.trim().isEmpty) 'Informe o nome do docente.',
      if (p.referencia == null)
        'Sem pontuação de referência para a classe/nível/titulação escolhidos.',
      if (p.intersticioInicio == null || p.intersticioFim == null)
        'Informe as datas do interstício.',
      if (p.relatorioInicio == null || p.relatorioFim == null)
        'Informe as datas do período do relatório.',
      if (p.intersticioInicio != null &&
          p.intersticioFim != null &&
          mesesCompletos(p.intersticioInicio!, p.intersticioFim!) < 24)
        'O interstício informado tem menos de 24 meses.',
      if (p.relatorioInicio != null &&
          p.intersticioInicio != null &&
          p.relatorioInicio!.isBefore(p.intersticioInicio!))
        'O relatório começa antes do interstício: justifique o uso de período superior a 24 meses (§ 6º do art. 3º).',
      if (p.avaliacoesDidaticas.every((a) => a.trim().isEmpty))
        'Nenhuma avaliação didática discente listada (exigida pelo § 3º do art. 9º).',
      if (p.referencia != null && !p.atingeReferencia)
        'A pontuação ainda não atinge a referência (${p.referencia} pontos).',
    ];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _cartao(
          child: Table(
            columnWidths: const {
              0: FixedColumnWidth(70),
              1: FlexColumnWidth(),
              2: FixedColumnWidth(110),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              const TableRow(
                children: [
                  _CelulaResumo('Anexo', negrito: true),
                  _CelulaResumo('Descrição', negrito: true),
                  _CelulaResumo('Pontuação', negrito: true, direita: true),
                ],
              ),
              for (final t in TabelaAnexo1.values)
                TableRow(
                  children: [
                    _CelulaResumo(t.codigo),
                    _CelulaResumo('${t.titulo} (${t.faixa})'),
                    _CelulaResumo(
                      ProgressaoPdfService.pontos(p.totalTabela(t)),
                      direita: true,
                    ),
                  ],
                ),
              TableRow(
                children: [
                  const _CelulaResumo(''),
                  const _CelulaResumo('Total de Pontos', negrito: true),
                  _CelulaResumo(
                    ProgressaoPdfService.pontos(p.total),
                    negrito: true,
                    direita: true,
                  ),
                ],
              ),
              TableRow(
                children: [
                  const _CelulaResumo(''),
                  _CelulaResumo(
                    'Pontuação de referência (${tabelaReferencia(p.carreira, p.regime)})',
                  ),
                  _CelulaResumo('${p.referencia ?? '—'}', direita: true),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _cartao(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Conferência',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              if (avisos.isEmpty)
                Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: AppTheme.green),
                    const SizedBox(width: 8),
                    const Text('Tudo pronto para gerar o PDF.'),
                  ],
                ),
              for (final a in avisos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: AppTheme.warning,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(a)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CelulaResumo extends StatelessWidget {
  const _CelulaResumo(this.texto, {this.negrito = false, this.direita = false});

  final String texto;
  final bool negrito;
  final bool direita;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
    child: Text(
      texto,
      textAlign: direita ? TextAlign.right : TextAlign.left,
      style: TextStyle(fontWeight: negrito ? FontWeight.bold : null),
    ),
  );
}
