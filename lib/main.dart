import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/core/router/app_router.dart';
import 'package:gestor_ufu/data/datasources/local_datasource.dart';
import 'package:gestor_ufu/data/datasources/moodle_datasource.dart';
import 'package:gestor_ufu/data/repositories/config_repository_impl.dart';
import 'package:gestor_ufu/data/repositories/moodle_repository_impl.dart';
import 'package:gestor_ufu/presentation/controllers/auth_controller.dart';
import 'package:gestor_ufu/presentation/controllers/config_controller.dart';
import 'package:gestor_ufu/presentation/controllers/sync_controller.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/data/services/ajusta_horarios_store.dart';
import 'package:gestor_ufu/data/services/shared_preferences_sync_service.dart';
import 'package:gestor_ufu/data/services/windows_update_service.dart';
import 'package:gestor_ufu/domain/entities/ajusta_horarios.dart';
import 'package:gestor_ufu/presentation/pages/ajusta_horarios_page.dart';
import 'package:window_manager/window_manager.dart';

String _appVersion = 'desconhecida';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final packageInfo = await PackageInfo.fromPlatform();
  _appVersion = packageInfo.version;
  final appTitle = 'Gestor UFU v${packageInfo.version}';
  if (Platform.isWindows) {
    final window = await WindowController.fromCurrentEngine();
    if (window.arguments.isNotEmpty) {
      final payload = jsonDecode(window.arguments) as Map<String, dynamic>;
      if (payload['type'] == 'scheduleEditor') {
        final isLight = payload['isLight'] as bool? ?? false;
        AppTheme.isLight = isLight;
        final entries = (payload['entries'] as List)
            .map(
              (item) => HorarioDisciplina.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
        final teachers = (payload['teachers'] as List).cast<String>();
        final programs = (payload['programs'] as Map).map(
          (key, value) => MapEntry(int.parse(key as String), value as String),
        );
        await windowManager.ensureInitialized();
        unawaited(
          windowManager.waitUntilReadyToShow(
            WindowOptions(
              size: Size(1100, 780),
              minimumSize: Size(1000, 760),
              center: true,
              title: 'Editar disciplinas - $appTitle',
            ),
            () async {
              await windowManager.show();
              await windowManager.focus();
            },
          ),
        );
        runApp(
          HorarioEditorWindowApp(
            entries: entries,
            teachers: teachers,
            programs: programs,
            selectedProgram: payload['selectedProgram'] as int,
            selectedPeriod: payload['selectedPeriod'] as int,
            channelName: payload['channel'] as String,
            initialEntryId: payload['initialEntryId'] as String?,
            isLight: isLight,
          ),
        );
        return;
      }
      if (payload['type'] == 'teacherEditor') {
        final isLight = payload['isLight'] as bool? ?? false;
        AppTheme.isLight = isLight;
        final entries = (payload['entries'] as List)
            .map(
              (item) => HorarioDisciplina.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
        final teachers = (payload['teachers'] as List).cast<String>();
        final programs = (payload['programs'] as Map).map(
          (key, value) => MapEntry(int.parse(key as String), value as String),
        );
        await windowManager.ensureInitialized();
        unawaited(
          windowManager.waitUntilReadyToShow(
            WindowOptions(
              size: Size(1120, 820),
              minimumSize: Size(900, 650),
              center: true,
              title: 'Editar docentes - $appTitle',
            ),
            () async {
              await windowManager.show();
              await windowManager.focus();
            },
          ),
        );
        runApp(
          TeacherRosterWindowApp(
            teachers: teachers,
            entries: entries,
            programs: programs,
            channelName: payload['channel'] as String,
            initialTeacher: payload['initialTeacher'] as String?,
            isLight: isLight,
          ),
        );
        return;
      }
      if (payload['type'] == 'roomEditor') {
        final isLight = payload['isLight'] as bool? ?? false;
        AppTheme.isLight = isLight;
        final entries = (payload['entries'] as List)
            .map(
              (item) => HorarioDisciplina.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
        final rooms = (payload['rooms'] as List).cast<String>();
        final programs = (payload['programs'] as Map).map(
          (key, value) => MapEntry(int.parse(key as String), value as String),
        );
        await windowManager.ensureInitialized();
        unawaited(
          windowManager.waitUntilReadyToShow(
            WindowOptions(
              size: Size(1120, 820),
              minimumSize: Size(900, 650),
              center: true,
              title: 'Editar salas - $appTitle',
            ),
            () async {
              await windowManager.show();
              await windowManager.focus();
            },
          ),
        );
        runApp(
          RoomRosterWindowApp(
            rooms: rooms,
            entries: entries,
            programs: programs,
            channelName: payload['channel'] as String,
            initialRoom: payload['initialRoom'] as String?,
            isLight: isLight,
          ),
        );
        return;
      }
    }
    await windowManager.ensureInitialized();
    await windowManager.setTitle(appTitle);
  }
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
      title: 'Gestor UFU v$_appVersion',
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
      await widget.updateService.installAfterApplicationCloses(
        installer,
        expectedVersion: widget.release.version,
      );
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
