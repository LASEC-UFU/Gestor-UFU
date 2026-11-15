import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/moodle/controllers/auth_controller.dart';

/// Login no Moodle (tela do módulo Config Moodle, usada também pelo contrato
/// MoodlePlanning). Devolve se há sessão ao fechar.
Future<bool> showMoodleLoginDialog(
  BuildContext context,
  AuthController authController,
) async {
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return false;
  await authController.init();
  if (!context.mounted) return false;
  final savedCredential = authController.credential;
  final savedUrl =
      prefs.getString('last_moodle_url') ??
      savedCredential?.moodleUrl ??
      'https://';
  final urlCtrl = TextEditingController(text: savedUrl);
  final userCtrl = TextEditingController(text: savedCredential?.username ?? '');
  final passCtrl = TextEditingController(text: savedCredential?.password ?? '');

  await showDialog(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: authController,
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final auth = ctx.watch<AuthController>();
          return AlertDialog(
            title: const Text('Login Moodle'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: urlCtrl,
                    keyboardType: TextInputType.url,
                    onChanged: (value) =>
                        prefs.setString('last_moodle_url', value.trim()),
                    decoration: const InputDecoration(
                      labelText: 'URL do Moodle',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: userCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Usuário',
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Senha',
                      prefixIcon: Icon(Icons.lock),
                    ),
                  ),
                  if (auth.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      auth.error!,
                      style: const TextStyle(color: AppTheme.danger),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: auth.loading
                    ? null
                    : () async {
                        final url = urlCtrl.text.trim();
                        final ok = await auth.login(
                          url,
                          userCtrl.text.trim(),
                          passCtrl.text,
                        );
                        if (ok) {
                          prefs.setString('last_moodle_url', url);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                child: auth.loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Entrar'),
              ),
            ],
          );
        },
      ),
    ),
  );
  urlCtrl.dispose();
  userCtrl.dispose();
  passCtrl.dispose();
  return authController.isLoggedIn;
}
