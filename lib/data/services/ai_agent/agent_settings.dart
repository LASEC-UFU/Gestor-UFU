import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AgentProvider { claude, chatgpt, gemini }

enum AgentAuthMode { cli, apiKey }

extension AgentProviderLabel on AgentProvider {
  String get label => switch (this) {
    AgentProvider.claude => 'Claude',
    AgentProvider.chatgpt => 'ChatGPT',
    AgentProvider.gemini => 'Gemini',
  };

  /// Nome do executável do CLI oficial que usa a assinatura do usuário.
  String get cliName => switch (this) {
    AgentProvider.claude => 'claude',
    AgentProvider.chatgpt => 'codex',
    AgentProvider.gemini => 'gemini',
  };

  String get cliProductName => switch (this) {
    AgentProvider.claude => 'Claude Code',
    AgentProvider.chatgpt => 'Codex',
    AgentProvider.gemini => 'Gemini CLI',
  };

  String get npmPackage => switch (this) {
    AgentProvider.claude => '@anthropic-ai/claude-code',
    AgentProvider.chatgpt => '@openai/codex',
    AgentProvider.gemini => '@google/gemini-cli',
  };

  /// Argumentos que abrem o fluxo de login do CLI num terminal.
  List<String> get loginArgs => switch (this) {
    AgentProvider.claude => const ['auth', 'login', '--claudeai'],
    AgentProvider.chatgpt => const ['login'],
    AgentProvider.gemini => const [],
  };

  String get loginHint => switch (this) {
    AgentProvider.claude =>
      'Um terminal foi aberto com o Claude Code. Digite /login, entre com '
          'sua conta Claude (Pro/Max) e feche o terminal ao terminar.',
    AgentProvider.chatgpt =>
      'Um terminal foi aberto com "codex login". Entre com sua conta '
          'ChatGPT e feche o terminal ao terminar.',
    AgentProvider.gemini =>
      'Um terminal foi aberto com o Gemini CLI. Escolha "Login with Google", '
          'entre com sua conta Google e feche o terminal ao terminar.',
  };

  String get apiKeyHint => switch (this) {
    AgentProvider.claude => 'Crie em console.anthropic.com',
    AgentProvider.chatgpt => 'Crie em platform.openai.com',
    AgentProvider.gemini => 'Crie em aistudio.google.com',
  };

  String get defaultApiModel => switch (this) {
    AgentProvider.claude => 'claude-opus-5-5',
    AgentProvider.chatgpt => 'gpt-5',
    AgentProvider.gemini => 'gemini-2.5-pro',
  };
}

/// Preferências do agente guardadas no cofre do Windows (Credential Manager),
/// fora do SharedPreferences: assim não vão para o banco compartilhado e as
/// chaves de API são lembradas entre aberturas do Gestor.
class AgentSettings {
  AgentSettings({
    this.provider = AgentProvider.claude,
    Map<String, String>? modes,
    Map<String, String>? models,
    Map<String, String>? cliPaths,
    Set<String>? signedOut,
  }) : modes = modes ?? {},
       models = models ?? {},
       cliPaths = cliPaths ?? {},
       signedOut = signedOut ?? {};

  AgentProvider provider;

  /// Modo de autenticação escolhido para cada provedor.
  final Map<String, String> modes;
  final Map<String, String> models;
  final Map<String, String> cliPaths;

  /// Provedores que o usuário desconectou manualmente: não reconectam
  /// sozinhos até um novo login.
  final Set<String> signedOut;

  AgentAuthMode modeFor(AgentProvider p) => AgentAuthMode.values.firstWhere(
    (m) => m.name == modes[p.name],
    orElse: () => AgentAuthMode.cli,
  );

  AgentAuthMode get mode => modeFor(provider);
  set mode(AgentAuthMode value) => modes[provider.name] = value.name;

  /// Conecta sozinho ao abrir (como a extensão do VS Code), exceto se o
  /// usuário desconectou este provedor.
  bool get autoConnect => !signedOut.contains(provider.name);
  set autoConnect(bool value) =>
      value ? signedOut.remove(provider.name) : signedOut.add(provider.name);

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
        modes: {
          ...Map<String, String>.from(json['modes'] as Map? ?? {}),
          // Versões anteriores guardavam um único modo para todos.
          if (json['modes'] == null && json['mode'] is String)
            json['provider'] as String? ?? 'claude': json['mode'] as String,
        },
        models: Map<String, String>.from(json['models'] as Map? ?? {}),
        cliPaths: Map<String, String>.from(json['cliPaths'] as Map? ?? {}),
        signedOut: {
          ...((json['signedOut'] as List?) ?? const []).map((e) => '$e'),
        },
      );
    } catch (_) {
      return AgentSettings();
    }
  }

  Future<void> save() => _storage.write(
    key: _settingsKey,
    value: jsonEncode({
      'provider': provider.name,
      'modes': modes,
      'models': models,
      'cliPaths': cliPaths,
      'signedOut': signedOut.toList(),
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
