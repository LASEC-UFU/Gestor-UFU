import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/core/router/app_router.dart';
import 'package:gestor_ufu/presentation/controllers/theme_controller.dart';
import 'package:gestor_ufu/data/services/shared_folder/shared_files_mirror.dart';
import 'package:gestor_ufu/data/services/shared_preferences_sync_service.dart';
import 'package:gestor_ufu/data/services/windows_update_service.dart';
import 'package:gestor_ufu/modules/diario/data/diary_automation_service.dart';
import 'package:gestor_ufu/core/utils/debug_options.dart';
import 'package:gestor_ufu/app/installed_modules.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';
import 'package:gestor_ufu/platform/services/academic_term_service.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/navigation_service.dart';
import 'package:gestor_ufu/presentation/pages/ai_agent_window.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/janela_comentarios.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_data_host.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_text_service.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/remote/remote_access_server.dart';
import 'package:window_manager/window_manager.dart';

String _appVersion = 'desconhecida';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Módulos instalados (painel, rotas, agente e janelas leem do registro).
  installModules();
  final packageInfo = await PackageInfo.fromPlatform();
  _appVersion = packageInfo.version;
  final appTitle = 'Gestor UFU v${packageInfo.version}';
  if (Platform.isWindows) {
    final window = await WindowController.fromCurrentEngine();
    if (window.arguments.isNotEmpty) {
      final payload = jsonDecode(window.arguments) as Map<String, dynamic>;
      if (payload['type'] == 'aiAgent') {
        final isLight = payload['isLight'] as bool? ?? false;
        AppTheme.isLight = isLight;
        await windowManager.ensureInitialized();
        unawaited(
          windowManager.waitUntilReadyToShow(
            WindowOptions(
              size: const Size(980, 760),
              minimumSize: const Size(640, 480),
              center: true,
              title: 'Agente de IA - $appTitle',
            ),
            () async {
              await windowManager.show();
              await windowManager.focus();
            },
          ),
        );
        runApp(
          AiAgentWindowApp(
            initialSkill: payload['skill'] as String? ?? 'geral',
            isLight: isLight,
          ),
        );
        return;
      }
      if (payload['type'] == 'commentsPanel') {
        final isLight = payload['isLight'] as bool? ?? false;
        AppTheme.isLight = isLight;
        await windowManager.ensureInitialized();
        unawaited(
          windowManager.waitUntilReadyToShow(
            WindowOptions(
              size: const Size(460, 720),
              minimumSize: const Size(320, 420),
              center: true,
              title: 'Comentários - $appTitle',
            ),
            () async {
              await windowManager.show();
              await windowManager.focus();
            },
          ),
        );
        runApp(
          JanelaComentariosApp(
            channelName: '${payload['channel']}',
            comentarios: (payload['comentarios'] as List)
                .map((x) => Map<String, dynamic>.from(x as Map))
                .toList(),
            selecionado: payload['selecionado'] as String?,
            isLight: isLight,
          ),
        );
        return;
      }
      // Janelas secundárias declaradas pelos módulos (ex.: editores do
      // Ajusta Horários).
      final moduleWindow = ModuleRegistry.instance.windowFor(
        '${payload['type']}',
      );
      if (moduleWindow != null) {
        AppTheme.isLight = payload['isLight'] as bool? ?? false;
        final window = moduleWindow(payload);
        await windowManager.ensureInitialized();
        unawaited(
          windowManager.waitUntilReadyToShow(
            WindowOptions(
              size: window.size,
              minimumSize: window.minimumSize,
              center: true,
              title: '${window.title} - $appTitle',
            ),
            () async {
              await windowManager.show();
              await windowManager.focus();
            },
          ),
        );
        runApp(window.app);
        return;
      }
    }
    await windowManager.ensureInitialized();
    await windowManager.setTitle(appTitle);
  }
  final preferences = await SharedPreferences.getInstance();
  final sharedDatabase = SharedPreferencesSyncService();
  await sharedDatabase.initialize();
  // Ativa os módulos DEPOIS de trazer o banco compartilhado: as migrações e
  // os dados iniciais dos módulos não podem sobrescrever o que veio de lá.
  final services = GestorServices();
  // Períodos letivos da janela principal: o seletor do cabeçalho de todos os
  // módulos usa esta instância; trocar o período vale para todas as telas.
  await services.terms.load();
  AcademicTermService.shared = services.terms;
  // Ponte com o Agente de IA para os módulos (ex.: resumos de documentos).
  services.registerContract<AiTextService>(const AgentTextService());
  await ModuleRegistry.instance.activateAll(services);
  final themeCtrl = ThemeController(
    isLight: preferences.getBool(ThemeController.storageKey) ?? false,
  );

  // Ferramentas do Agente de IA executadas nesta janela (banco + desfazer).
  final agentHost = AgentDataHost.instance
    ..currentRoute = (() => NavigationService.currentRoute)
    // Dados alterados pelo agente: cada módulo descarta caches e recarrega.
    ..onDataChanged = () async {
      await services.terms.load();
      for (final module in ModuleRegistry.instance.modules) {
        await module.onExternalDataChanged();
      }
    };
  if (Platform.isWindows) await agentHost.start();
  // Dados vindos de outro computador pela pasta compartilhada: mesma
  // recarga das alterações feitas pelo agente.
  sharedDatabase.onRemoteChanged = (_) async {
    await services.terms.load();
    for (final module in ModuleRegistry.instance.modules) {
      await module.onExternalDataChanged();
    }
  };
  // Arquivos gerados (relatórios, PDFs, planilhas) na pasta compartilhada.
  final filesMirror = SharedFilesMirror(sharedDatabase);
  filesMirror.start();

  final remoteAccess = RemoteAccessServer.instance
    ..onDataChanged = () async {
      await services.terms.load();
      for (final module in ModuleRegistry.instance.modules) {
        await module.onExternalDataChanged();
      }
    };
  if (Platform.isWindows) {
    final remoteError = await remoteAccess.startIfConfigured();
    if (remoteError != null) debugPrint('[Acesso remoto] $remoteError');
  }

  if (kDebugMode && diaryAutomationDebugEnabled) {
    unawaited(() async {
      try {
        await DiaryAutomationService.instance.openBrowser(
          'https://www.portaldocente.ufu.br/diarioEletronico',
          log: (message) => debugPrint('[Diário debug] $message'),
        );
      } catch (error) {
        debugPrint('[Diário debug] Falha ao abrir o Edge: $error');
      }
    }());
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: themeCtrl),
        ChangeNotifierProvider.value(value: sharedDatabase),
        // Providers que cada módulo publica para as próprias telas.
        for (final module in ModuleRegistry.instance.modules)
          ...module.providers,
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
                  'nas preferências locais e permanecem configurados.',
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
      // Quando o Agente de IA grava no banco, a árvore de páginas é recriada
      // para que cada tela recarregue os dados atualizados.
      builder: (context, child) => ValueListenableBuilder<int>(
        valueListenable: AgentDataHost.instance.revision,
        builder: (context, revision, _) =>
            KeyedSubtree(key: ValueKey(revision), child: child!),
      ),
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
