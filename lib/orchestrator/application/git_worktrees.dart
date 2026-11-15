import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/orchestrator/domain/orq_models.dart';

/// Falha do Git com a mensagem para o usuário.
class GitException implements Exception {
  const GitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Worktree criada (ou reaproveitada) para uma tarefa.
class OrqWorktree {
  const OrqWorktree({
    required this.path,
    required this.branch,
    required this.projectRoot,
    this.base = 'HEAD',
    this.reused = false,
    this.includedFiles = const [],
  });

  final String path;
  final String branch;
  final String projectRoot;
  final String base;
  final bool reused;
  final List<String> includedFiles;
}

/// Revisão das alterações de uma tarefa.
class OrqChanges {
  const OrqChanges({
    required this.files,
    required this.diff,
    this.truncated = false,
    this.untracked = false,
  });

  final List<OrqChangedFile> files;
  final String diff;
  final bool truncated;
  final bool untracked;
  bool get clean => files.isEmpty;
}

/// Git para o Orquestrador (port de `gitWorktrees.js`, `diffReview.js` e
/// `upstreamSyncInvocation.js`): worktree isolada por tarefa, arquivos
/// ignorados escolhidos em `.worktreeinclude`, arquivos alterados, diff
/// limitado, comentário por linha e sincronização fast-forward de upstreams.
/// Nunca altera a configuração Git do usuário.
class GitWorktrees {
  GitWorktrees(this.storageRoot);

  /// Pasta onde as worktrees são criadas (fora do projeto).
  final String storageRoot;

  static const maxIncludedFiles = 250;
  static const maxIncludedFileBytes = 64 * 1024 * 1024;
  static const maxIncludedTotalBytes = 256 * 1024 * 1024;
  static const maxDiffChars = 60000;

  static Future<String> git(
    List<String> args,
    String cwd, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final result = await Process.run(
      'git',
      ['-c', 'core.longpaths=true', ...args],
      workingDirectory: cwd,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
    if (result.exitCode != 0) {
      final message = '${result.stderr}'.trim().isNotEmpty
          ? '${result.stderr}'.trim()
          : '${result.stdout}'.trim();
      throw GitException(message.isEmpty ? 'O comando git falhou.' : message);
    }
    final out = '${result.stdout}';
    return args.contains('-z') ? out : out.trim();
  }

  /// Raiz do repositório Git que contém [path] (ou null se não for Git).
  static Future<String?> repositoryRoot(String path) async {
    if (path.trim().isEmpty || !await Directory(path).exists()) return null;
    try {
      return p.normalize(await git(['rev-parse', '--show-toplevel'], path));
    } on Object {
      return null;
    }
  }

  static Future<List<String>> localBranches(String root) async {
    try {
      final out = await git([
        'for-each-ref',
        '--format=%(refname:short)',
        'refs/heads',
      ], root);
      return out.split(RegExp(r'\r?\n')).where((b) => b.isNotEmpty).toList();
    } on Object {
      return const [];
    }
  }

  static String safePart(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final cut = cleaned.length > 50 ? cleaned.substring(0, 50) : cleaned;
    return cut.isEmpty ? 'task' : cut;
  }

  static List<Map<String, String>> _parseWorktrees(String output) => [
    for (final block in output.split(RegExp(r'\r?\n\r?\n')))
      if (block.trim().isNotEmpty)
        {
          for (final line in block.split(RegExp(r'\r?\n')))
            if (line.isNotEmpty)
              line.contains(' ')
                  ? line.substring(0, line.indexOf(' '))
                  : line: line.contains(' ')
                  ? line.substring(line.indexOf(' ') + 1)
                  : 'true',
        },
  ];

  /// Cria a worktree da tarefa (branch nova a partir de [base] ou HEAD) ou
  /// reaproveita [existingPath] se ela ainda for uma worktree do repositório.
  Future<OrqWorktree> open(
    String projectPath, {
    required String runId,
    required String taskId,
    int attempt = 1,
    String requestedBranch = '',
    String base = '',
    String existingPath = '',
  }) async {
    final root = await repositoryRoot(projectPath);
    if (root == null) {
      throw GitException(
        'A pasta do projeto não é um repositório Git: $projectPath',
      );
    }
    final entries = _parseWorktrees(
      await git(['worktree', 'list', '--porcelain'], root),
    );
    if (existingPath.isNotEmpty && await Directory(existingPath).exists()) {
      final target = p.canonicalize(existingPath);
      final match = entries.where(
        (e) =>
            e['worktree'] != null && p.canonicalize(e['worktree']!) == target,
      );
      if (match.isEmpty) {
        throw GitException(
          'O checkout salvo não aparece na lista de worktrees do Git.',
        );
      }
      return OrqWorktree(
        path: existingPath,
        branch: (match.first['branch'] ?? '').replaceFirst('refs/heads/', ''),
        projectRoot: root,
        reused: true,
      );
    }
    final branch = requestedBranch.isNotEmpty
        ? requestedBranch
              .replaceAll(RegExp(r'[^A-Za-z0-9._/-]+'), '-')
              .replaceAll(RegExp(r'^/+|/+$'), '')
        : 'orquestrador/${safePart(runId)}-${safePart(taskId)}-${attempt < 1 ? 1 : attempt}';
    if (branch.isEmpty ||
        branch.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const GitException('Nome de branch inválido para a worktree.');
    }
    final taken = entries.where(
      (e) =>
          (e['branch'] ?? '').replaceFirst('refs/heads/', '').toLowerCase() ==
          branch.toLowerCase(),
    );
    if (taken.isNotEmpty) {
      throw GitException(
        'A branch $branch já está associada à worktree ${taken.first['worktree']}.',
      );
    }
    try {
      await git([
        'show-ref',
        '--verify',
        '--quiet',
        'refs/heads/$branch',
      ], root);
      throw GitException(
        'A branch $branch já existe; escolha outro nome para não reaproveitar '
        'trabalho sem confirmação.',
      );
    } on GitException catch (error) {
      if (error.message.startsWith('A branch')) rethrow;
    }
    var baseRef = 'HEAD';
    if (base.isNotEmpty) {
      if (base.length > 200 ||
          base.startsWith('-') ||
          base.contains('..') ||
          base.contains('//') ||
          base.endsWith('/') ||
          base.endsWith('.')) {
        throw GitException('Nome de branch base inválido: $base');
      }
      try {
        baseRef = await git([
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/$base^{commit}',
        ], root);
      } on GitException {
        throw GitException(
          'A branch base local $base não existe ou não aponta para um commit.',
        );
      }
    }
    final repoKey = sha256
        .convert(utf8.encode(p.canonicalize(root).toLowerCase()))
        .toString()
        .substring(0, 20);
    final target = p.join(
      storageRoot,
      'worktrees',
      repoKey,
      '${safePart(runId)}-${safePart(taskId)}-${attempt < 1 ? 1 : attempt}',
    );
    if (await Directory(target).exists()) {
      throw GitException('O caminho da worktree já existe: $target');
    }
    await Directory(p.dirname(target)).create(recursive: true);
    await git(
      ['worktree', 'add', '-b', branch, target, baseRef],
      root,
      timeout: const Duration(minutes: 2),
    );
    final included = await copyIncludedIgnoredFiles(root, target);
    return OrqWorktree(
      path: target,
      branch: branch,
      projectRoot: root,
      base: base.isEmpty ? 'HEAD' : base,
      includedFiles: included,
    );
  }

  /// Copia para a worktree os arquivos ignorados pelo Git que o projeto
  /// escolheu em `.worktreeinclude` (ex.: `.env.local`), com limites.
  static Future<List<String>> copyIncludedIgnoredFiles(
    String projectRoot,
    String worktreePath,
  ) async {
    final includeFile = File(p.join(projectRoot, '.worktreeinclude'));
    if (!await includeFile.exists()) return const [];
    final patterns = [
      for (final line in (await includeFile.readAsString()).split(
        RegExp(r'\r?\n'),
      ))
        if (line.trim().isNotEmpty && !line.trim().startsWith('#')) line.trim(),
    ];
    if (patterns.isEmpty) return const [];
    final ignored = await git([
      'ls-files',
      '--others',
      '--ignored',
      '--exclude-standard',
      '-z',
    ], projectRoot);
    final candidates = [
      for (final rel in ignored.split('\u0000'))
        if (rel.isNotEmpty && matchesInclude(rel, patterns)) rel,
    ];
    if (candidates.length > maxIncludedFiles) {
      throw const GitException(
        'Os arquivos escolhidos em .worktreeinclude passam do limite de '
        '$maxIncludedFiles arquivos.',
      );
    }
    final copied = <String>[];
    var total = 0;
    for (final rel in candidates) {
      final segments = rel.split(RegExp(r'[\\/]+'));
      if (p.isAbsolute(rel) ||
          segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
        continue;
      }
      final source = File(p.joinAll([projectRoot, ...segments]));
      final target = File(p.joinAll([worktreePath, ...segments]));
      if (await FileSystemEntity.isLink(source.path) ||
          !await source.exists()) {
        continue;
      }
      final size = await source.length();
      if (size > maxIncludedFileBytes || total + size > maxIncludedTotalBytes) {
        throw const GitException(
          'Os arquivos de .worktreeinclude passam do limite de tamanho.',
        );
      }
      if (await target.exists()) continue;
      await target.parent.create(recursive: true);
      await source.copy(target.path);
      total += size;
      copied.add(segments.join('/'));
    }
    return copied;
  }

  /// O caminho combina com algum padrão estilo .gitignore (`*`, `**`, `?`,
  /// `/` inicial = raiz, `/` final = pasta, sem `/` = qualquer nível).
  static bool matchesInclude(String relativePath, List<String> patterns) {
    final path = relativePath
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^\./'), '');
    for (final raw in patterns) {
      var pattern = raw.trim();
      if (pattern.isEmpty ||
          pattern.startsWith('#') ||
          pattern.startsWith('!')) {
        continue;
      }
      final dirOnly = pattern.endsWith('/');
      if (dirOnly) pattern = pattern.substring(0, pattern.length - 1);
      final anchored = pattern.startsWith('/') || pattern.contains('/');
      if (pattern.startsWith('/')) pattern = pattern.substring(1);
      final regex = _globToRegex(pattern);
      final parts = path.split('/');
      // Testa o caminho e cada pasta-mãe (um padrão de pasta inclui tudo
      // dentro dela).
      for (var i = parts.length; i >= 1; i--) {
        if (dirOnly && i == parts.length) continue;
        final candidate = parts.take(i).join('/');
        if (anchored) {
          if (regex.hasMatch(candidate)) return true;
        } else if (regex.hasMatch(parts[i - 1])) {
          return true;
        }
      }
    }
    return false;
  }

  static RegExp _globToRegex(String glob) {
    final buffer = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          buffer.write('.*');
          i++;
          if (i + 1 < glob.length && glob[i + 1] == '/') i++;
        } else {
          buffer.write('[^/]*');
        }
      } else if (c == '?') {
        buffer.write('[^/]');
      } else {
        buffer.write(RegExp.escape(c));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }

  /// Arquivos alterados (incluindo novos) e diff dos rastreados contra
  /// [base] (ou HEAD), limitado a [maxDiffChars].
  static Future<OrqChanges> changes(
    String worktreePath, {
    String base = '',
  }) async {
    final status = await git([
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=all',
    ], worktreePath);
    final files = <OrqChangedFile>[];
    final records = status.split('\u0000');
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.length < 4) continue;
      final code = record.substring(0, 2).trim();
      files.add(OrqChangedFile(code.isEmpty ? '?' : code, record.substring(3)));
      // Renomeação: o próximo registro é o caminho antigo.
      if (code.startsWith('R') || code.startsWith('C')) i++;
    }
    var diff = '';
    try {
      diff = await git([
        'diff',
        '--no-color',
        '--no-ext-diff',
        base.isEmpty ? 'HEAD' : base,
      ], worktreePath);
    } on GitException {
      diff = '';
    }
    final truncated = diff.length > maxDiffChars;
    return OrqChanges(
      files: files.take(300).toList(),
      diff: truncated ? diff.substring(0, maxDiffChars) : diff,
      truncated: truncated,
      untracked: files.any((f) => f.code == '??'),
    );
  }

  /// Verifica se [line] de [file] é uma linha adicionada no [diff] (para
  /// comentários por linha). Devolve o motivo se não for.
  static String? validateLineComment(String diff, String file, int line) {
    final normalized = file.replaceAll('\\', '/');
    String? current;
    var newLine = 0;
    for (final row in diff.split('\n')) {
      if (row.startsWith('+++ ')) {
        final target = row.substring(4).trim();
        current = target == '/dev/null'
            ? null
            : target.replaceFirst(RegExp(r'^b/'), '');
        continue;
      }
      final hunk = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)').firstMatch(row);
      if (hunk != null) {
        newLine = int.parse(hunk.group(1)!);
        continue;
      }
      if (current != normalized || newLine == 0) continue;
      if (row.startsWith('+')) {
        if (newLine == line) return null;
        newLine++;
      } else if (row.startsWith(' ')) {
        newLine++;
      }
    }
    return 'A linha $normalized:$line não é uma linha adicionada no diff atual '
        'da tarefa.';
  }

  /// Sincroniza um upstream: fetch + merge fast-forward. Para se houver
  /// mudanças locais, divergência ou remoto ausente.
  static Future<String> syncUpstream(
    String projectRoot,
    String relativePath, {
    String remote = 'origin',
    String branch = '',
  }) async {
    final dir = p.normalize(p.join(projectRoot, relativePath));
    final real = await Directory(dir).exists()
        ? await Directory(dir).resolveSymbolicLinks()
        : '';
    final rootReal = await Directory(projectRoot).resolveSymbolicLinks();
    if (real.isEmpty ||
        !(p.isWithin(rootReal, real) || p.equals(rootReal, real))) {
      throw GitException(
        'Upstream fora do projeto ou inexistente: $relativePath',
      );
    }
    if ((await git(['status', '--porcelain'], real)).isNotEmpty) {
      throw GitException(
        'O upstream $relativePath tem alterações locais; sincronização parada.',
      );
    }
    final target = branch.isNotEmpty
        ? branch
        : await git(['rev-parse', '--abbrev-ref', 'HEAD'], real);
    await git(
      ['fetch', remote, target],
      real,
      timeout: const Duration(minutes: 2),
    );
    await git(['merge', '--ff-only', '$remote/$target'], real);
    return 'Upstream $relativePath atualizado ($remote/$target).';
  }
}
