import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/processos_parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/processo_parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/parecer_secao_view.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';

/// Uma aba do módulo Parecer / Relato.
class _Funcionalidade {
  const _Funcionalidade(this.titulo, this.icone, this.builder);

  final String titulo;
  final IconData icone;
  final WidgetBuilder builder;
}

/// Tela do módulo Parecer / Relato: primeiro a lista de processos (criar,
/// abrir, renomear, duplicar, excluir); aberto um processo, uma aba por
/// seção do parecer (modelo "Parecer" do SEI). A extração da árvore do
/// processo é a etapa 1 da aba I. RELATÓRIO.
class ElaboraRelatoPage extends StatefulWidget {
  const ElaboraRelatoPage({required this.processos, super.key});

  final ProcessosParecerService processos;

  @override
  State<ElaboraRelatoPage> createState() => _ElaboraRelatoPageState();
}

class _ElaboraRelatoPageState extends State<ElaboraRelatoPage> {
  bool _carregando = true;
  bool _abrindo = false;
  String _filtro = '';

  ProcessosParecerService get processos => widget.processos;
  ParecerService get parecer => processos.parecer;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  @override
  void dispose() {
    // Grava o rascunho do processo aberto ao sair do módulo.
    parecer.salvarAgora();
    super.dispose();
  }

  Future<void> _carregar() async {
    try {
      await processos.carregar(forcar: true);
    } catch (e) {
      _mensagem('Não foi possível ler os processos: $e');
    }
    if (mounted) setState(() => _carregando = false);
  }

  void _mensagem(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _executar(Future<void> Function() acao) async {
    setState(() => _abrindo = true);
    try {
      await acao();
    } catch (e) {
      _mensagem(e is CommandException ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _abrindo = false);
    }
  }

  Future<void> _novo() async {
    final dados = await _formulario(titulo: 'Novo processo');
    if (dados == null) return;
    await _executar(() async {
      final p = await processos.criar(
        nome: dados.nome,
        numeroSei: dados.numeroSei,
      );
      await processos.abrir(p.id);
    });
  }

  Future<void> _renomear(ProcessoParecer p) async {
    final dados = await _formulario(
      titulo: 'Renomear processo',
      nome: p.nome,
      numeroSei: p.numeroSei,
    );
    if (dados == null) return;
    await _executar(
      () => processos.renomear(
        p.id,
        nome: dados.nome,
        numeroSei: dados.numeroSei,
      ),
    );
  }

  Future<void> _duplicar(ProcessoParecer p) async {
    final dados = await _formulario(
      titulo: 'Copiar processo',
      nome: 'Cópia de ${p.nome}',
      numeroSei: p.numeroSei,
      explicacao:
          'O novo processo começa com uma cópia de tudo do processo '
          '"${p.nome}": dados do parecer, as três seções, os comentários, o '
          'inventário da árvore do SEI e a pasta da base de documentos.',
      confirmar: 'Criar cópia',
    );
    if (dados == null) return;
    await _executar(() async {
      final copia = await processos.duplicar(p.id, nome: dados.nome);
      if (dados.numeroSei != p.numeroSei) {
        await processos.renomear(copia.id, numeroSei: dados.numeroSei);
      }
      _mensagem('Cópia "${copia.nome}" criada.');
    });
  }

  Future<void> _excluir(ProcessoParecer p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir processo'),
        content: SizedBox(
          width: 480,
          child: Text(
            'Excluir o processo "${p.nome}"? O rascunho do parecer, os '
            'comentários e o inventário da árvore serão apagados do Gestor. '
            'Os arquivos da pasta da base de documentos não são apagados.\n\n'
            'Esta ação não pode ser desfeita.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _executar(() => processos.excluir(p.id));
  }

  Future<({String nome, String numeroSei})?> _formulario({
    required String titulo,
    String nome = '',
    String numeroSei = '',
    String? explicacao,
    String confirmar = 'Salvar',
  }) async {
    final nomeCtrl = TextEditingController(text: nome);
    final seiCtrl = TextEditingController(text: numeroSei);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (explicacao != null) ...[
                Text(explicacao),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: nomeCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Nome do processo',
                  hintText: 'Ex.: Alteração do PPC de Engenharia Mecânica',
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: seiCtrl,
                decoration: const InputDecoration(
                  labelText: 'Número do processo no SEI (opcional)',
                  hintText: '23117.000000/2026-00',
                ),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmar),
          ),
        ],
      ),
    );
    final r = (nome: nomeCtrl.text.trim(), numeroSei: seiCtrl.text.trim());
    nomeCtrl.dispose();
    seiCtrl.dispose();
    return ok == true ? r : null;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    return ListenableBuilder(
      listenable: processos,
      builder: (context, _) {
        final aberto = processos.ativo;
        if (aberto != null) return _processo(aberto);
        return _lista();
      },
    );
  }

  // ---------------------------------------------------------------- lista

  Widget _lista() {
    final filtro = _filtro.trim().toLowerCase();
    final itens = [
      for (final p in processos.processos)
        if (filtro.isEmpty ||
            '${p.nome} ${p.numeroSei} ${processos.resumo(p.id).assunto}'
                .toLowerCase()
                .contains(filtro))
          p,
    ];
    return ModuleScaffold(
      moduleId: 'elabora-relato',
      subtitle: 'Pareceres e relatos de processos do SEI',
      actions: [
        FilledButton.icon(
          onPressed: _abrindo ? null : _novo,
          icon: const Icon(Icons.add),
          label: const Text('Novo processo'),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
        child: _carregando
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (processos.processos.length > 4)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Buscar por nome, número SEI ou assunto',
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _filtro = v),
                      ),
                    ),
                  if (_abrindo) const LinearProgressIndicator(),
                  Expanded(
                    child: processos.processos.isEmpty
                        ? _vazio()
                        : ListView.separated(
                            itemCount: itens.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (_, i) => _tile(itens[i]),
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _tile(ProcessoParecer p) {
    final r = processos.resumo(p.id);
    final cor = r.pendentes > 0
        ? AppTheme.warning
        : r.secoesComTexto == 3
        ? AppTheme.green
        : AppTheme.textSecondary;
    final linha1 = [
      if (p.numeroSei.isNotEmpty) 'SEI ${p.numeroSei}',
      if (r.assunto.isNotEmpty) r.assunto,
    ].join(' · ');
    final linha2 = [
      '${r.secoesComTexto}/3 seções redigidas',
      '${r.documentos} documento(s) na árvore',
      if (r.comentarios > 0)
        '${r.comentarios} comentário(s)'
            '${r.pendentes > 0 ? ' (${r.pendentes} para revisão)' : ''}',
      if (p.atualizadoEm != null) 'atualizado em ${_data(p.atualizadoEm!)}',
    ].join(' · ');
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
          child: Icon(Icons.history_edu_rounded, color: cor),
        ),
        title: Text(
          p.nome,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          linha1.isEmpty ? linha2 : '$linha1\n$linha2',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: linha1.isNotEmpty,
        onTap: _abrindo ? null : () => _executar(() => processos.abrir(p.id)),
        trailing: Wrap(
          spacing: 2,
          children: [
            IconButton(
              tooltip: 'Renomear',
              onPressed: _abrindo ? null : () => _renomear(p),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Copiar para um novo processo',
              onPressed: _abrindo ? null : () => _duplicar(p),
              icon: const Icon(Icons.copy_outlined),
            ),
            IconButton(
              tooltip: 'Excluir',
              onPressed: _abrindo ? null : () => _excluir(p),
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
          Icons.history_edu_rounded,
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
          'Crie um processo para extrair a árvore do SEI, redigir o parecer e '
          'inseri-lo no SEI.',
          style: TextStyle(color: AppTheme.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _novo,
          icon: const Icon(Icons.add),
          label: const Text('Novo processo'),
        ),
      ],
    ),
  );

  static String _data(DateTime d) {
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)}/${d.year} '
        '${dois(d.hour)}:${dois(d.minute)}';
  }

  // ------------------------------------------------------ processo aberto

  List<_Funcionalidade> get _funcionalidades => [
    _Funcionalidade(
      ParecerSecao.relatorio.titulo,
      Icons.list_alt_rounded,
      (_) => RelatorioView(service: parecer),
    ),
    _Funcionalidade(
      ParecerSecao.fundamentacao.titulo,
      Icons.gavel_rounded,
      (_) =>
          ParecerSecaoView(secao: ParecerSecao.fundamentacao, service: parecer),
    ),
    _Funcionalidade(
      ParecerSecao.conclusao.titulo,
      Icons.task_alt_rounded,
      (_) => ParecerSecaoView(secao: ParecerSecao.conclusao, service: parecer),
    ),
  ];

  Widget _processo(ProcessoParecer p) {
    final itens = _funcionalidades;
    return DefaultTabController(
      // Cada processo recria as abas (e os editores) com os dados dele.
      key: ValueKey('processo-${p.id}'),
      length: itens.length,
      child: ModuleScaffold(
        moduleId: 'elabora-relato',
        title: p.nome,
        subtitle: [
          if (p.numeroSei.isNotEmpty) 'SEI ${p.numeroSei}',
          'Parecer / Relato',
        ].join(' · '),
        onBack: () => _executar(processos.fechar),
        actions: [
          IconButton(
            tooltip: 'Renomear o processo',
            onPressed: () => _renomear(p),
            icon: const Icon(Icons.edit_outlined),
          ),
          InserirSeiBotao(service: parecer),
        ],
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: AppTheme.textPrimary,
                unselectedLabelColor: AppTheme.textSecondary,
                dividerColor: AppTheme.divider,
                tabs: [
                  for (final item in itens)
                    Tab(
                      height: 44,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(item.icone, size: 18),
                          const SizedBox(width: 8),
                          Text(item.titulo),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final item in itens) Builder(builder: item.builder),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
