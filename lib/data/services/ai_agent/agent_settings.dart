import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AgentProvider { claude, chatgpt }

enum AgentAuthMode { cli, apiKey }

extension AgentProviderLabel on AgentProvider {
  String get label => switch (this) {
    AgentProvider.claude => 'Claude',
    AgentProvider.chatgpt => 'ChatGPT',
  };

  String get cliName => switch (this) {
    AgentProvider.claude => 'claude',
    AgentProvider.chatgpt => 'codex',
  };

  String get defaultApiModel => switch (this) {
    AgentProvider.claude => 'claude-opus-5-5',
    AgentProvider.chatgpt => 'gpt-5',
  };
}

/// Preferências do agente guardadas no cofre do Windows (Credential Manager),
/// fora do SharedPreferences: assim não vão para o banco compartilhado e as
/// chaves de API são lembradas entre aberturas do Gestor.
class AgentSettings {
  AgentSettings({
    this.provider = AgentProvider.claude,
    this.mode = AgentAuthMode.cli,
    Map<String, String>? models,
    Map<String, String>? cliPaths,
    this.autoConnect = false,
  }) : models = models ?? {},
       cliPaths = cliPaths ?? {};

  AgentProvider provider;
  AgentAuthMode mode;
  final Map<String, String> models;
  final Map<String, String> cliPaths;

  /// Conecta sozinho ao abrir a janela (true depois do primeiro login).
  bool autoConnect;

  String _slot(AgentProvider p, AgentAuthMode m) => '${p.name}.${m.name}';

  String modelFor(AgentProvider p, AgentAuthMode m) {
    final saved = models[_slot(p, m)]?.trim() ?? '';
    if (saved.isNotEmpty) return saved;
    return m == AgentAuthMode.apiKey ? p.defaultApiModel : '';
  }

  void setModel(AgentProvider p, AgentAuthMode m, String value) =>
      models[_slot(p, m)] = value.trim();

  String cliPathFor(AgentProvider p) => cliPaths[p.name]?.trim() ?? '';

  static const _storage = FlutterSecureStorage();
  static const _settingsKey = 'gestor_ufu_ai_agent_settings_v1';
  static String _apiKeyKey(AgentProvider p) =>
      'gestor_ufu_ai_agent_api_key_${p.name}';

  static Future<AgentSettings> load() async {
    try {
      final raw = await _storage.read(key: _settingsKey);
      if (raw == null) return AgentSettings();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AgentSettings(
        provider: AgentProvider.values.firstWhere(
          (p) => p.name == json['provider'],
          orElse: () => AgentProvider.claude,
        ),
        mode: AgentAuthMode.values.firstWhere(
          (m) => m.name == json['mode'],
          orElse: () => AgentAuthMode.cli,
        ),
        models: Map<String, String>.from(json['models'] as Map? ?? {}),
        cliPaths: Map<String, String>.from(json['cliPaths'] as Map? ?? {}),
        autoConnect: json['autoConnect'] == true,
      );
    } catch (_) {
      return AgentSettings();
    }
  }

  Future<void> save() => _storage.write(
    key: _settingsKey,
    value: jsonEncode({
      'provider': provider.name,
      'mode': mode.name,
      'models': models,
      'cliPaths': cliPaths,
      'autoConnect': autoConnect,
    }),
  );

  static Future<String?> readApiKey(AgentProvider p) async {
    try {
      final value = await _storage.read(key: _apiKeyKey(p));
      return value == null || value.trim().isEmpty ? null : value.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeApiKey(AgentProvider p, String? value) async {
    if (value == null || value.trim().isEmpty) {
      await _storage.delete(key: _apiKeyKey(p));
    } else {
      await _storage.write(key: _apiKeyKey(p), value: value.trim());
    }
  }
}
