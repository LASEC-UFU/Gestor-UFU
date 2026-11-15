import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Repositório de origem sincronizado antes do build (fast-forward apenas).
class OrqUpstream {
  const OrqUpstream({
    required this.path,
    this.remote = 'origin',
    this.branch = '',
  });

  /// Pasta do repositório, relativa ao projeto.
  final String path;
  final String remote;
  final String branch;

  Map<String, dynamic> toJson() => {
    'path': path,
    'remote': remote,
    'branch': branch,
  };

  factory OrqUpstream.fromJson(Map<String, dynamic> json) => OrqUpstream(
    path: '${json['path'] ?? ''}',
    remote: '${json['remote'] ?? 'origin'}',
    branch: '${json['branch'] ?? ''}',
  );
}

/// Perfil de conta de um agente CLI (port de `workerProfiles.js`): outra
/// conta do Claude Code (`CLAUDE_CONFIG_DIR`) ou do Codex (`CODEX_HOME` com
/// credenciais em arquivo na pasta do perfil). O login é feito pelo CLI
/// oficial; o Gestor não lê credenciais.
class OrqProfile {
  const OrqProfile({
    required this.id,
    required this.provider,
    required this.name,
    this.maxParallel = 1,
  });

  final String id;

  /// `claude` ou `chatgpt` (Codex).
  final String provider;
  final String name;
  final int maxParallel;

  static const supported = {'claude', 'chatgpt'};

  /// Pasta do perfil (fica só neste computador).
  String get directory => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'GestorUFU',
    'orquestrador',
    'perfis',
    id,
  );

  /// Variáveis que fazem o CLI usar a conta deste perfil.
  Map<String, String> get environment => provider == 'claude'
      ? {'CLAUDE_CONFIG_DIR': directory}
      : {'CODEX_HOME': directory};

  /// Cria a pasta; no Codex, guarda as credenciais em arquivo na pasta do
  /// perfil (opção documentada), separadas das demais contas.
  Future<void> prepare() async {
    await Directory(directory).create(recursive: true);
    if (provider == 'chatgpt') {
      final config = File(p.join(directory, 'config.toml'));
      if (!await config.exists()) {
        await config.writeAsString('cli_auth_credentials_store = "file"\n');
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': provider,
    'name': name,
    'maxParallel': maxParallel,
  };

  factory OrqProfile.fromJson(Map<String, dynamic> json) => OrqProfile(
    id: '${json['id']}',
    provider: '${json['provider'] ?? 'claude'}',
    name: '${json['name'] ?? ''}',
    maxParallel: ((json['maxParallel'] as num?)?.toInt() ?? 1).clamp(1, 6),
  );
}

/// Configurações do Orquestrador. Ficam no banco compartilhado (iguais em
/// todos os computadores), exceto a pasta do projeto, guardada por
/// computador (`projectPaths[nome do computador]`).
class OrqSettings {
  OrqSettings({
    this.coordinator = AgentProvider.claude,
    Set<AgentProvider>? workers,
    this.defaultWorker = AgentProvider.claude,
    this.maxParallel = 2,
    this.maxAttempts = 3,
    this.workerAccess = AgentAccess.acceptEdits,
    Map<String, String>? projectPaths,
    this.buildCommand = '',
    this.buildArgs = '',
    this.buildDir = '',
    this.buildTimeoutMinutes = 20,
    List<OrqUpstream>? upstreams,
    this.aiMemory = true,
    List<OrqProfile>? profiles,
  }) : workers = workers ?? AgentProvider.values.toSet(),
       projectPaths = projectPaths ?? {},
       upstreams = upstreams ?? [],
       profiles = profiles ?? [];

  static const key = 'orquestrador.config.v1';

  AgentProvider coordinator;

  /// Agentes que podem receber tarefas.
  Set<AgentProvider> workers;

  /// Usado quando o plano diz `auto`.
  AgentProvider defaultWorker;
  int maxParallel;
  int maxAttempts;

  /// Permissão dos trabalhadores (padrão: editar sem perguntar, dentro da
  /// worktree da tarefa).
  AgentAccess workerAccess;
  final Map<String, String> projectPaths;
  String buildCommand;
  String buildArgs;
  String buildDir;
  int buildTimeoutMinutes;
  List<OrqUpstream> upstreams;
  bool aiMemory;

  /// Contas extras dos agentes CLI.
  List<OrqProfile> profiles;

  OrqProfile? profile(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  static String get machine => Platform.localHostname;

  /// Pasta do projeto neste computador.
  String get projectPath => projectPaths[machine] ?? '';
  set projectPath(String value) => projectPaths[machine] = value.trim();

  static Future<OrqSettings> load([KeyValueStore? store]) async {
    final raw = await (store ?? KeyValueStore()).readJson(key);
    if (raw is! Map) return OrqSettings();
    AgentProvider provider(Object? value, AgentProvider fallback) =>
        AgentProvider.values.firstWhere(
          (p) => p.name == value,
          orElse: () => fallback,
        );
    final workers = <AgentProvider>{
      for (final w in raw['workers'] as List? ?? const [])
        ...AgentProvider.values.where((p) => p.name == w),
    };
    return OrqSettings(
      coordinator: provider(raw['coordinator'], AgentProvider.claude),
      workers: workers.isEmpty ? null : workers,
      defaultWorker: provider(raw['defaultWorker'], AgentProvider.claude),
      maxParallel: ((raw['maxParallel'] as num?)?.toInt() ?? 2).clamp(1, 8),
      maxAttempts: ((raw['maxAttempts'] as num?)?.toInt() ?? 3).clamp(1, 10),
      workerAccess: AgentAccess.values.firstWhere(
        (a) => a.name == raw['workerAccess'],
        orElse: () => AgentAccess.acceptEdits,
      ),
      projectPaths: {
        for (final e in (raw['projectPaths'] as Map? ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
      buildCommand: '${raw['buildCommand'] ?? ''}',
      buildArgs: '${raw['buildArgs'] ?? ''}',
      buildDir: '${raw['buildDir'] ?? ''}',
      buildTimeoutMinutes: ((raw['buildTimeoutMinutes'] as num?)?.toInt() ?? 20)
          .clamp(1, 240),
      upstreams: [
        for (final u in raw['upstreams'] as List? ?? const [])
          if (u is Map) OrqUpstream.fromJson(Map<String, dynamic>.from(u)),
      ],
      aiMemory: raw['aiMemory'] != false,
      profiles: [
        for (final item in raw['profiles'] as List? ?? const [])
          if (item is Map) OrqProfile.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }

  Future<void> save([KeyValueStore? store]) =>
      (store ?? KeyValueStore()).writeJson(key, {
        'coordinator': coordinator.name,
        'workers': [for (final w in workers) w.name],
        'defaultWorker': defaultWorker.name,
        'maxParallel': maxParallel,
        'maxAttempts': maxAttempts,
        'workerAccess': workerAccess.name,
        'projectPaths': projectPaths,
        'buildCommand': buildCommand,
        'buildArgs': buildArgs,
        'buildDir': buildDir,
        'buildTimeoutMinutes': buildTimeoutMinutes,
        'upstreams': [for (final u in upstreams) u.toJson()],
        'aiMemory': aiMemory,
        'profiles': [for (final profile in profiles) profile.toJson()],
      });
}
