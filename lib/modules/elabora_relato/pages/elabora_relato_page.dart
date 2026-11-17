import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/parecer_secao_view.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';

/// Uma aba do módulo Parecer / Relato.
class _Funcionalidade {
  const _Funcionalidade(this.titulo, this.icone, this.builder);

  final String titulo;
  final IconData icone;
  final WidgetBuilder builder;
}

/// Tela do módulo Parecer / Relato: uma aba por seção do parecer (modelo
/// "Parecer" do SEI). A extração da árvore do processo é a etapa 1 da aba
/// I. RELATÓRIO.
class ElaboraRelatoPage extends StatefulWidget {
  const ElaboraRelatoPage({required this.parecer, super.key});

  final ParecerService parecer;

  @override
  State<ElaboraRelatoPage> createState() => _ElaboraRelatoPageState();
}

class _ElaboraRelatoPageState extends State<ElaboraRelatoPage> {
  @override
  void initState() {
    super.initState();
    widget.parecer.carregar();
  }

  ParecerService get parecer => widget.parecer;

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

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final itens = _funcionalidades;
    return DefaultTabController(
      length: itens.length,
      child: ModuleScaffold(
        moduleId: 'elabora-relato',
        subtitle: 'Pareceres e relatos de processos do SEI',
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
