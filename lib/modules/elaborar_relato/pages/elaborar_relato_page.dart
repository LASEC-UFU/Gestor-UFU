import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elaborar_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elaborar_relato/pages/extrair_arvore_view.dart';
import 'package:gestor_ufu/platform/shell/module_scaffold.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';

/// Uma funcionalidade do Elaborar Relato (uma aba da tela).
class _Funcionalidade {
  const _Funcionalidade(this.titulo, this.icone, this.builder);

  final String titulo;
  final IconData icone;
  final WidgetBuilder builder;
}

/// Tela do módulo Elaborar Relato. Cada funcionalidade é uma aba; para
/// acrescentar uma nova, crie a vista em `pages/` e inclua-a em
/// [_funcionalidades].
class ElaborarRelatoPage extends StatelessWidget {
  const ElaborarRelatoPage({required this.arvore, super.key});

  final SeiArvoreService arvore;

  List<_Funcionalidade> get _funcionalidades => [
    _Funcionalidade(
      'Extrair árvore de processo',
      Icons.account_tree_rounded,
      (_) => ExtrairArvoreView(service: arvore),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    final itens = _funcionalidades;
    return DefaultTabController(
      length: itens.length,
      child: ModuleScaffold(
        moduleId: 'elaborar-relato',
        subtitle: 'Relatos de processos do SEI',
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
