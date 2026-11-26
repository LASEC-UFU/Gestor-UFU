import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Ferramentas Poppler (`pdftotext`, `pdftoppm`) usadas para ler e
/// renderizar PDFs.
///
/// O instalador do Gestor traz o Poppler em `<pasta do app>\poppler\bin`,
/// que é procurado primeiro. Fora dele (desenvolvimento), no Windows é comum
/// haver mais de um `pdftotext` no PATH: o do Git (xpdf 4.x, sem `-bbox` nem
/// `pdftoppm`) costuma vir antes do Poppler do MiKTeX ou de uma instalação
/// própria; o localizador escolhe um que seja de fato Poppler.
class Poppler {
  const Poppler._();

  static Future<Poppler?>? _encontrado;
  static Future<String?>? _qualquer;

  /// Pasta com o Poppler (null = não encontrado).
  static Future<String?> pasta() =>
      (_encontrado ??= _procurar()).then((_) => _pastaPoppler);

  static String? _pastaPoppler;

  static String get _exe => Platform.isWindows ? '.exe' : '';

  /// `pdftotext` do Poppler; senão, o primeiro `pdftotext` do PATH (que
  /// ainda serve para extrair texto simples); null se não houver nenhum.
  static Future<String?> pdftotext() async {
    final pasta = await Poppler.pasta();
    if (pasta != null) return p.join(pasta, 'pdftotext$_exe');
    return _qualquer ??= _primeiroNoPath('pdftotext$_exe');
  }

  /// `pdftotext` com suporte a `-bbox` (só Poppler), ou null.
  static Future<String?> pdftotextComCaixas() async {
    final pasta = await Poppler.pasta();
    return pasta == null ? null : p.join(pasta, 'pdftotext$_exe');
  }

  /// `pdftoppm` do Poppler, ou null.
  static Future<String?> pdftoppm() async {
    final pasta = await Poppler.pasta();
    if (pasta == null) return null;
    final f = File(p.join(pasta, 'pdftoppm$_exe'));
    return await f.exists() ? f.path : null;
  }

  /// Texto de cada página de um PDF (camada de texto, em ordem de leitura).
  /// Páginas digitalizadas como imagem voltam vazias (precisariam de OCR).
  static Future<List<String>> paginasDeTexto(String pdf) async {
    final ProcessResult r;
    try {
      r = await Process.run(
        // Prefere o Poppler a um xpdf que venha antes no PATH.
        await pdftotext() ?? 'pdftotext',
        ['-enc', 'UTF-8', '-eol', 'unix', pdf, '-'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException {
      throw StateError(
        'Não foi possível encontrar o pdftotext (Poppler), que vem com o '
        'instalador do Gestor. Reinstale o Gestor para ler PDFs.',
      );
    }
    if (r.exitCode != 0) {
      final erro = '${r.stderr}'.trim();
      throw StateError(
        erro.isEmpty ? 'pdftotext encerrou com código ${r.exitCode}.' : erro,
      );
    }
    final paginas = '${r.stdout}'.split('\f');
    // O pdftotext termina cada página com form feed.
    if (paginas.length > 1 && paginas.last.trim().isEmpty) {
      paginas.removeLast();
    }
    return [for (final p in paginas) p.trim()];
  }

  /// Só para testes: esquece o que foi encontrado.
  static void reiniciar() {
    _encontrado = null;
    _qualquer = null;
    _pastaPoppler = null;
  }

  static List<String> candidatas() {
    final env = Platform.environment;
    final path = env['PATH'] ?? env['Path'] ?? '';
    final pastas = <String>[
      // O instalador do Gestor traz o Poppler em <pasta do app>\poppler\bin.
      p.join(p.dirname(Platform.resolvedExecutable), 'poppler', 'bin'),
      ...path.split(Platform.isWindows ? ';' : ':').where((x) => x.isNotEmpty),
    ];
    if (Platform.isWindows) {
      for (final base in [
        env['ProgramFiles'],
        env['ProgramFiles(x86)'],
        env['LOCALAPPDATA'],
      ]) {
        if (base == null) continue;
        pastas
          ..add(p.join(base, 'MiKTeX', 'miktex', 'bin', 'x64'))
          ..add(p.join(base, 'Programs', 'MiKTeX', 'miktex', 'bin', 'x64'))
          ..add(p.join(base, 'poppler', 'Library', 'bin'))
          ..add(p.join(base, 'poppler', 'bin'));
        // Pastas "poppler-24.08.0\Library\bin" etc.
        try {
          for (final d in Directory(base).listSync().whereType<Directory>()) {
            if (p.basename(d.path).toLowerCase().startsWith('poppler')) {
              pastas
                ..add(p.join(d.path, 'Library', 'bin'))
                ..add(p.join(d.path, 'bin'));
            }
          }
        } catch (_) {}
      }
    }
    return pastas;
  }

  static Future<Poppler?> _procurar() async {
    final vistas = <String>{};
    for (final pasta in candidatas()) {
      final chave = p.normalize(pasta).toLowerCase();
      if (!vistas.add(chave)) continue;
      final exe = File(p.join(pasta, 'pdftotext$_exe'));
      if (!await exe.exists()) continue;
      if (await ehPoppler(exe.path)) {
        _pastaPoppler = pasta;
        return const Poppler._();
      }
    }
    return null;
  }

  /// O executável é Poppler (e não xpdf)? Poppler informa "Poppler" ou uma
  /// versão no formato ano.mês (ex.: 23.13.0); o xpdf 4.x, não.
  static Future<bool> ehPoppler(String executavel) async {
    try {
      final r = await Process.run(executavel, ['-v']);
      final saida = '${r.stdout}\n${r.stderr}';
      // O Poppler também credita a Glyph & Cog (xpdf); por isso o nome e a
      // versão (ano.mês, ou 0.x antigas) vêm antes.
      if (saida.toLowerCase().contains('poppler')) return true;
      return RegExp(r'version (\d{2}|0)\.\d+').hasMatch(saida);
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _primeiroNoPath(String nome) async {
    for (final pasta in candidatas()) {
      final f = File(p.join(pasta, nome));
      if (await f.exists()) return f.path;
    }
    return null;
  }
}
