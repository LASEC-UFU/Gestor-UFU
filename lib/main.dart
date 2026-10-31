import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:config_moodle/core/theme/app_theme.dart';
import 'package:config_moodle/core/router/app_router.dart';
import 'package:config_moodle/data/datasources/local_datasource.dart';
import 'package:config_moodle/data/datasources/moodle_datasource.dart';
import 'package:config_moodle/data/repositories/config_repository_impl.dart';
import 'package:config_moodle/data/repositories/moodle_repository_impl.dart';
import 'package:config_moodle/presentation/controllers/auth_controller.dart';
import 'package:config_moodle/presentation/controllers/config_controller.dart';
import 'package:config_moodle/presentation/controllers/sync_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Datasources
  final localDs = LocalDatasource();
  final moodleDs = MoodleDatasource();

  // Repositories
  final configRepo = ConfigRepositoryImpl(localDs);
  final moodleRepo = MoodleRepositoryImpl(moodleDs);

  // Controllers
  final authCtrl = AuthController(moodleRepo)..init();
  final configCtrl = ConfigController(configRepo);
  final syncCtrl = SyncController(moodleRepo);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authCtrl),
        ChangeNotifierProvider.value(value: configCtrl),
        ChangeNotifierProvider.value(value: syncCtrl),
      ],
      child: const GestorUfuApp(),
    ),
  );
}

class GestorUfuApp extends StatelessWidget {
  const GestorUfuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Gestor UFU',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: AppRouter.router,
    );
  }
}
