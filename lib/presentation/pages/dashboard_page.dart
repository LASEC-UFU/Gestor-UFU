import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/data/services/preferences_backup_service.dart';
import 'package:config_moodle/presentation/controllers/theme_controller.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  static const _modules = <_ModuleInfo>[
    _ModuleInfo(
      title: 'Config Moodle',
      description:
          'Planeje disciplinas, organize atividades e sincronize cursos.',
      icon: Icons.settings_suggest_rounded,
      accent: AppTheme.primary,
      enabled: true,
      route: '/moodle',
      category: 'PLANEJAMENTO DE DISCIPLINAS',
    ),
    _ModuleInfo(
      title: 'Preenche Diários',
      description:
          'Prepare lançamentos de aula usando planilhas ou dados do Moodle.',
      icon: Icons.edit_calendar_rounded,
      accent: AppTheme.accent,
      enabled: true,
      route: '/diario',
      category: 'ROTINA ACADÊMICA',
    ),
    _ModuleInfo(
      title: 'Extrair \u00c1rvore de Processo',
      description:
          'Consulte os documentos de um processo e gere um inventário revisável.',
      icon: Icons.account_tree_rounded,
      accent: Color(0xFFFFB454),
      enabled: true,
      route: '/sei',
      category: 'PROCESSOS E DOCUMENTOS',
    ),

    _ModuleInfo(
      title: 'Planos de Ensino',
      description:
          'Cadastre planos, organize cronogramas e prepare documentos para o SEI.',
      icon: Icons.menu_book_rounded,
      accent: Color(0xFF5DD39E),
      enabled: true,
      route: '/planos-ensino',
      category: 'ENSINO',
    ),
    _ModuleInfo(
      title: 'Planos de Trabalho',
      description:
          'Organize atividades, preencha planilhas e prepare PDFs para o SEI.',
      icon: Icons.assignment_turned_in_rounded,
      accent: Color(0xFFFF7B8B),
      enabled: true,
      route: '/planos-trabalho',
      category: 'GESTÃO DO TRABALHO',
    ),
    _ModuleInfo(
      title: 'Ajusta Horários',
      description: 'Monte grades semanais por curso, período e docente.',
      icon: Icons.schedule_rounded,
      accent: AppTheme.primary,
      enabled: true,
      route: '/ajusta-horarios',
      category: 'PLANEJAMENTO DE DISCIPLINAS',
    ),
    _ModuleInfo(
      title: 'Inserir Documentos no SEI',
      description:
          'Insira fichas de componentes curriculares no processo do SEI.',
      icon: Icons.topic_rounded,
      accent: Color(0xFFFFB454),
      category: 'PROCESSOS E DOCUMENTOS',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    context.watch<ThemeController>();
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: AppTheme.bgGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final horizontalPadding = compact ? 20.0 : 48.0;

              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: _DashboardHeader(compact: compact)),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      compact ? 24 : 36,
                      horizontalPadding,
                      28,
                    ),
                    sliver: SliverLayoutBuilder(
                      builder: (context, sliverConstraints) {
                        final width = sliverConstraints.crossAxisExtent;
                        final columns = width >= 1000
                            ? 3
                            : width >= 620
                            ? 2
                            : 1;
                        return SliverGrid.builder(
                          itemCount: _modules.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisSpacing: 18,
                                crossAxisSpacing: 18,
                                mainAxisExtent: compact ? 232 : 250,
                              ),
                          itemBuilder: (context, index) =>
                              _ModuleCard(module: _modules[index]),
                        );
                      },
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1240),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding,
                            0,
                            horizontalPadding,
                            30,
                          ),
                          child: const _DashboardFooter(),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 20 : 36, 22, compact ? 20 : 36, 0),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: AppTheme.primaryGradient,
              borderRadius: BorderRadius.circular(15),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withAlpha(65),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white),
          ),
          SizedBox(width: 13),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Gestor UFU',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              Text(
                'CENTRAL DE UTILIDADES',
                style: TextStyle(
                  color: AppTheme.textSecondary.withAlpha(210),
                  fontSize: 9,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const Spacer(),
          PopupMenuButton<bool>(
            tooltip: 'Selecionar tema',
            initialValue: theme.isLight,
            onSelected: (isLight) => theme.setLight(isLight),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: false,
                checked: !theme.isLight,
                child: const Row(
                  children: [
                    Icon(Icons.dark_mode_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Escuro'),
                  ],
                ),
              ),
              CheckedPopupMenuItem(
                value: true,
                checked: theme.isLight,
                child: const Row(
                  children: [
                    Icon(Icons.light_mode_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Claro'),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: AppTheme.glassDecoration(opacity: 0.06),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    theme.isLight
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                    size: 16,
                    color: AppTheme.textSecondary,
                  ),
                  SizedBox(width: 8),
                  Text(
                    theme.isLight ? 'Tema claro' : 'Tema escuro',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: AppTheme.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatefulWidget {
  const _ModuleCard({required this.module});

  final _ModuleInfo module;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final module = widget.module;
    final enabled = module.enabled;
    final accent = module.accent;

    return MouseRegion(
      onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: enabled ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 180),
        transform: Matrix4.translationValues(0, _hovered ? -4 : 0, 0),
        decoration: BoxDecoration(
          gradient: enabled ? AppTheme.cardGradient : null,
          color: enabled ? null : AppTheme.bgCard.withAlpha(150),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: enabled
                ? accent.withAlpha(_hovered ? 150 : 75)
                : AppTheme.divider.withAlpha(170),
          ),
          boxShadow: enabled && _hovered
              ? [
                  BoxShadow(
                    color: accent.withAlpha(22),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? () => context.go(module.route!) : null,
            borderRadius: BorderRadius.circular(22),
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: accent.withAlpha(enabled ? 36 : 22),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          module.icon,
                          color: enabled ? accent : accent.withAlpha(150),
                          size: 24,
                        ),
                      ),
                      const Spacer(),
                      _ModuleStatus(enabled: enabled),
                    ],
                  ),
                  Spacer(),
                  Text(
                    module.category,
                    style: TextStyle(
                      color: enabled ? accent : AppTheme.textSecondary,
                      fontSize: 9,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 7),
                  Text(
                    module.title,
                    style: TextStyle(
                      color: enabled
                          ? AppTheme.textPrimary
                          : AppTheme.textPrimary.withAlpha(205),
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 7),
                  Text(
                    module.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary.withAlpha(
                        enabled ? 255 : 190,
                      ),
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                  SizedBox(height: 15),
                  Row(
                    children: [
                      Text(
                        enabled ? 'Acessar módulo' : 'Disponível em breve',
                        style: TextStyle(
                          color: enabled ? accent : AppTheme.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Spacer(),
                      Icon(
                        enabled
                            ? Icons.arrow_forward_rounded
                            : Icons.lock_outline_rounded,
                        size: 17,
                        color: enabled ? accent : AppTheme.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModuleStatus extends StatelessWidget {
  const _ModuleStatus({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppTheme.accentGreen : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(enabled ? 24 : 18),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withAlpha(enabled ? 75 : 40)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            enabled ? Icons.check_circle_rounded : Icons.schedule_rounded,
            color: color,
            size: 12,
          ),
          const SizedBox(width: 5),
          Text(
            enabled ? 'Disponível' : 'Em breve',
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardFooter extends StatelessWidget {
  const _DashboardFooter();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 12,
      children: [
        SizedBox(
          width: 620,
          child: Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppTheme.accentGreen,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Seus dados ficam armazenados localmente neste computador.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton.icon(
              onPressed: () => _export(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Exportar dados'),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: () => _import(context),
              icon: const Icon(Icons.upload_file_rounded, size: 18),
              label: const Text('Importar backup'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _export(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exportar todos os dados?'),
        content: const Text(
          'O backup inclui configurações, históricos, dados dos diários e credenciais Moodle salvas. Guarde o arquivo em local seguro.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final path = await PreferencesBackupService().exportBackup();
      if (path == null || !context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backup exportado: $path')));
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao exportar backup: $error')),
        );
    }
  }

  Future<void> _import(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Importar backup completo?'),
        content: const Text(
          'A importação substitui todos os dados locais atuais pelos dados do arquivo, inclusive configurações, histórico, diários e credenciais Moodle. Exporte um backup atual antes de continuar, se precisar preservá-lo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Selecionar arquivo'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final result = await PreferencesBackupService().importBackup();
      if (result == null || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Backup ${result.fileName} restaurado. Reinicie o Gestor UFU para recarregar ${result.importedCount} itens.',
          ),
        ),
      );
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao importar backup: $error')),
        );
    }
  }
}

class _ModuleInfo {
  const _ModuleInfo({
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
    required this.category,
    this.enabled = false,
    this.route,
  });

  final String title;
  final String description;
  final IconData icon;
  final Color accent;
  final String category;
  final bool enabled;
  final String? route;
}
