import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/core/router/app_router.dart';
import 'package:config_moodle/data/datasources/local_datasource.dart';
import 'package:config_moodle/data/datasources/moodle_datasource.dart';
import 'package:config_moodle/data/repositories/config_repository_impl.dart';
import 'package:config_moodle/data/repositories/moodle_repository_impl.dart';
import 'package:config_moodle/presentation/controllers/auth_controller.dart';
import 'package:config_moodle/presentation/controllers/config_controller.dart';
import 'package:config_moodle/presentation/controllers/sync_controller.dart';
import 'package:config_moodle/presentation/controllers/theme_controller.dart';
import 'package:config_moodle/data/services/ajusta_horarios_store.dart';
import 'package:config_moodle/data/services/shared_preferences_sync_service.dart';
import 'package:config_moodle/data/services/windows_update_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final sharedDatabase = SharedPreferencesSyncService();
  await sharedDatabase.initialize();
  // Importa a grade 2026/2 de Controle e Automacao na primeira abertura.
  await AjustaHorariosStore().load();
  final themeCtrl = ThemeController(
    isLight: preferences.getBool(ThemeController.storageKey) ?? false,
  );

  final localDs = LocalDatasource();
  await localDs.migrateLegacyTextEncoding();
  final moodleDs = MoodleDatasource();
  final configRepo = ConfigRepositoryImpl(localDs);
  final moodleRepo = MoodleRepositoryImpl(moodleDs);
  final authCtrl = AuthController(moodleRepo)..init();
  final configCtrl = ConfigController(configRepo);
  final syncCtrl = SyncController(moodleRepo);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authCtrl),
        ChangeNotifierProvider.value(value: configCtrl),
        ChangeNotifierProvider.value(value: syncCtrl),
        ChangeNotifierProvider.value(value: themeCtrl),
        ChangeNotifierProvider.value(value: sharedDatabase),
      ],
      child: const GestorUfuApp(),
    ),
  );
}

class GestorUfuApp extends StatefulWidget {
  const GestorUfuApp({super.key});

  @override
  State<GestorUfuApp> createState() => _GestorUfuAppState();
}

class _GestorUfuAppState extends State<GestorUfuApp> {
  final _updateService = WindowsUpdateService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForUpdates());
    });
  }

  Future<void> _checkForUpdates() async {
    final release = await _updateService.findUpdate();
    if (!mounted || release == null) return;
    final dialogContext = AppRouter.rootNavigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final accepted = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded, size: 34),
        title: Text('Nova versão ${release.version} disponível'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'A versão instalada pode ser atualizada. O Gestor UFU será '
                  'fechado durante a instalação e reaberto ao final.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Seus dados e o caminho do banco compartilhado são mantidos '
                  'nas prefer?ncias locais e permanecem configurados.',
                ),
                if (release.notes.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Novidades',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(release.notes),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Agora não'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.download_rounded),
            label: const Text('Atualizar'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final currentContext = AppRouter.rootNavigatorKey.currentContext;
    if (currentContext == null || !currentContext.mounted) return;
    await showDialog<void>(
      context: currentContext,
      barrierDismissible: false,
      builder: (_) =>
          _UpdateInstallDialog(release: release, updateService: _updateService),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeController = context.watch<ThemeController>();
    return MaterialApp.router(
      title: 'Gestor UFU',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeController.themeMode,
      routerConfig: AppRouter.router,
    );
  }
}

class _UpdateInstallDialog extends StatefulWidget {
  const _UpdateInstallDialog({
    required this.release,
    required this.updateService,
  });

  final WindowsUpdateRelease release;
  final WindowsUpdateService updateService;

  @override
  State<_UpdateInstallDialog> createState() => _UpdateInstallDialogState();
}

class _UpdateInstallDialogState extends State<_UpdateInstallDialog> {
  int _received = 0;
  int _total = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_downloadAndInstall());
    });
  }

  Future<void> _downloadAndInstall() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _received = 0;
      _total = 0;
    });
    try {
      final installer = await widget.updateService.downloadInstaller(
        widget.release,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      await widget.updateService.installAfterApplicationCloses(installer);
      exit(0);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Não foi possível instalar a atualização: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final megabytes = (_received / (1024 * 1024)).toStringAsFixed(1);
    return AlertDialog(
      icon: Icon(
        _error == null ? Icons.downloading_rounded : Icons.error_outline,
        size: 34,
      ),
      title: Text(
        _error == null
            ? 'Baixando versão ${widget.release.version}'
            : 'Falha na atualização',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error ??
                  'Depois do download, o Windows Installer substituirá a '
                      'versão atual e abrirá o Gestor UFU novamente.',
            ),
            const SizedBox(height: 18),
            if (_error == null) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                _total > 0
                    ? '$megabytes MB de '
                          '${(_total / (1024 * 1024)).toStringAsFixed(1)} MB'
                    : '$megabytes MB baixados',
              ),
            ],
          ],
        ),
      ),
      actions: _error == null
          ? null
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fechar'),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _downloadAndInstall,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Tentar novamente'),
              ),
            ],
    );
  }
}
