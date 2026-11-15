import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/presentation/widgets/common_widgets.dart';

/// Camada obrigatória de toda tela de módulo (docs/arquitetura/decisoes.md,
/// D3). A primeira linha é sempre:
///
/// Voltar · ícone + título do módulo · [actions] · Agente de IA + Tema
///
/// O título, o ícone e a cor vêm do registro do módulo ([moduleId]); um
/// módulo novo já nasce com os botões do Gestor. Para telas internas (editor,
/// prévia) use [title]/[icon] para sobrescrever e [onBack] para voltar a
/// outra rota.
class ModuleScaffold extends StatelessWidget {
  const ModuleScaffold({
    required this.moduleId,
    required this.body,
    this.title,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.floatingActionButton,
    this.onBack,
    this.maxWidth = 1800,
    super.key,
  });

  final String moduleId;
  final Widget body;
  final String? title;
  final String? subtitle;
  final IconData? icon;

  /// Botões do módulo na primeira linha (antes dos botões do Gestor).
  final List<Widget> actions;
  final Widget? floatingActionButton;

  /// Padrão: volta ao painel.
  final VoidCallback? onBack;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final module = ModuleRegistry.instance.byId(moduleId);
    final accent = module?.accent ?? AppTheme.primary;
    return Scaffold(
      floatingActionButton: floatingActionButton,
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                children: [
                  ModuleHeader(
                    title: title ?? module?.title ?? moduleId,
                    subtitle: subtitle,
                    icon: icon ?? module?.icon ?? Icons.extension_rounded,
                    accent: accent,
                    actions: actions,
                    onBack: onBack ?? () => context.go('/'),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Primeira linha padrão das telas de módulo (usada pelo [ModuleScaffold] e
/// por telas que montam o próprio Scaffold, como editores densos).
class ModuleHeader extends StatelessWidget {
  const ModuleHeader({
    required this.title,
    required this.icon,
    required this.accent,
    required this.onBack,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color accent;
  final List<Widget> actions;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Voltar',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
            color: AppTheme.textSecondary,
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: accent.withAlpha(40),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 24),
          ),
          const SizedBox(width: 12),
          // Título e ações dividem o espaço: em janelas estreitas o título
          // encolhe (reticências) e as ações quebram linha — nunca estoura.
          Flexible(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 3,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ),
          const SizedBox(width: 12),
          // Botões do Gestor: sempre na primeira linha, no canto direito.
          const ThemeSelector(compact: true),
        ],
      ),
    );
  }
}
