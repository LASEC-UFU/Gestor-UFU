import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/domain/entities/progressao.dart';
import 'package:gestor_ufu/domain/progressao/comprovantes.dart';

/// Copia os comprovantes para a pasta do processo, em subpastas por tabela do
/// Anexo 1 e com nomes padronizados, prontos para o envio ao SEI.
///
/// Os arquivos originais nunca são alterados. Cópias substituídas ou
/// desvinculadas vão para a subpasta [subpastaDescartados] em vez de apagadas.
class ProgressaoComprovantesService {
  const ProgressaoComprovantesService();

  static const subpastaDescartados = '_descartados';

  /// Caminho absoluto do comprovante, ou `null` se não for um arquivo da pasta.
  String? caminhoAbsoluto(ProgressaoDocente processo, LancamentoProgressao l) {
    if (!l.comprovanteArquivado || processo.pastaComprovantes.isEmpty) {
      return null;
    }
    return p.normalize(
      p.join(processo.pastaComprovantes, p.joinAll(_partes(l.comprovante))),
    );
  }

  bool existe(ProgressaoDocente processo, LancamentoProgressao l) {
    final caminho = caminhoAbsoluto(processo, l);
    return caminho != null && File(caminho).existsSync();
  }

  /// Copia [origem] para a pasta do processo e retorna o lançamento com o novo
  /// caminho relativo. Um comprovante anterior é movido para os descartados.
  Future<LancamentoProgressao> importar({
    required ProgressaoDocente processo,
    required LancamentoProgressao lancamento,
    required String origem,
  }) async {
    final pasta = processo.pastaComprovantes;
    if (pasta.isEmpty) {
      throw StateError('Escolha a pasta de comprovantes do processo.');
    }
    final arquivo = File(origem);
    if (!await arquivo.exists()) {
      throw StateError('O arquivo selecionado não existe: $origem');
    }
    final ext = p.extension(origem).replaceFirst('.', '').toLowerCase();
    if (!extensoesComprovante.contains(ext)) {
      throw StateError(
        'Formato não aceito ($ext). Use ${extensoesComprovante.join(', ')}.',
      );
    }
    final anterior = caminhoAbsoluto(processo, lancamento);
    if (anterior != null && p.equals(anterior, origem)) return lancamento;

    final ordem = ordemNoItem(processo, lancamento);
    final relativo = _relativoLivre(pasta, lancamento, ordem, ext);
    final destino = p.join(pasta, p.joinAll(_partes(relativo)));
    await Directory(p.dirname(destino)).create(recursive: true);
    await arquivo.copy(destino);
    if (anterior != null) await descartar(processo, anterior);
    return lancamento.copyWith(comprovante: relativo);
  }

  /// Desvincula o comprovante do lançamento, movendo a cópia para os
  /// descartados.
  Future<LancamentoProgressao> remover(
    ProgressaoDocente processo,
    LancamentoProgressao lancamento,
  ) async {
    final caminho = caminhoAbsoluto(processo, lancamento);
    if (caminho != null) await descartar(processo, caminho);
    return lancamento.copyWith(comprovante: '');
  }

  /// Move um arquivo da pasta do processo para a subpasta de descartados.
  Future<void> descartar(ProgressaoDocente processo, String caminho) async {
    final pasta = processo.pastaComprovantes;
    final arquivo = File(caminho);
    if (pasta.isEmpty ||
        !p.isWithin(pasta, caminho) ||
        !await arquivo.exists()) {
      return;
    }
    final destinoDir = p.join(pasta, subpastaDescartados);
    await Directory(destinoDir).create(recursive: true);
    var destino = p.join(destinoDir, p.basename(caminho));
    var n = 2;
    while (await File(destino).exists()) {
      destino = p.join(
        destinoDir,
        '${p.basenameWithoutExtension(caminho)}_$n${p.extension(caminho)}',
      );
      n++;
    }
    await _mover(arquivo, destino);
  }

  /// Renomeia todos os comprovantes conforme os dados atuais (período,
  /// descrição e posição de cada linha). Retorna o processo atualizado e a
  /// quantidade de arquivos renomeados.
  Future<(ProgressaoDocente, int)> reorganizar(
    ProgressaoDocente processo,
  ) async {
    final pasta = processo.pastaComprovantes;
    if (pasta.isEmpty) return (processo, 0);
    // Primeiro passo: nomes temporários, para permitir trocas de posição
    // entre linhas (A vira B e B vira A) sem colisão.
    final temporarios = <String, String>{};
    for (final l in processo.lancamentos) {
      final atual = caminhoAbsoluto(processo, l);
      if (atual == null || !await File(atual).exists()) continue;
      final esperado = caminhoRelativoComprovante(
        l,
        ordemNoItem(processo, l),
        p.extension(atual),
      );
      if (esperado == l.comprovante) continue;
      final tmp = '$atual.reorganizando';
      await _mover(File(atual), tmp);
      temporarios[l.id] = tmp;
    }
    var renomeados = 0;
    final lancamentos = <LancamentoProgressao>[];
    for (final l in processo.lancamentos) {
      final tmp = temporarios[l.id];
      if (tmp == null) {
        lancamentos.add(l);
        continue;
      }
      final ext = p.extension(tmp.replaceAll('.reorganizando', ''));
      final relativo = _relativoLivre(
        pasta,
        l,
        ordemNoItem(processo, l),
        ext.replaceFirst('.', ''),
      );
      final destino = p.join(pasta, p.joinAll(_partes(relativo)));
      await Directory(p.dirname(destino)).create(recursive: true);
      await _mover(File(tmp), destino);
      lancamentos.add(l.copyWith(comprovante: relativo));
      renomeados++;
    }
    return (processo.copyWith(lancamentos: lancamentos), renomeados);
  }

  /// Copia os comprovantes do processo para [novaPasta], mantendo as
  /// subpastas. Os arquivos da pasta antiga permanecem onde estavam.
  Future<int> copiarParaPasta(
    ProgressaoDocente processo,
    String novaPasta,
  ) async {
    var copiados = 0;
    for (final l in processo.lancamentos) {
      final origem = caminhoAbsoluto(processo, l);
      if (origem == null || !await File(origem).exists()) continue;
      final destino = p.join(novaPasta, p.joinAll(_partes(l.comprovante)));
      if (p.equals(origem, destino)) continue;
      await Directory(p.dirname(destino)).create(recursive: true);
      await File(origem).copy(destino);
      copiados++;
    }
    return copiados;
  }

  String _relativoLivre(
    String pasta,
    LancamentoProgressao l,
    int ordem,
    String ext,
  ) {
    for (var sufixo = 1; ; sufixo++) {
      final relativo = caminhoRelativoComprovante(
        l,
        ordem,
        ext,
        sufixo: sufixo,
      );
      final destino = p.join(pasta, p.joinAll(_partes(relativo)));
      if (!File(destino).existsSync()) return relativo;
    }
  }

  static List<String> _partes(String relativo) =>
      relativo.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty).toList();

  static Future<void> _mover(File arquivo, String destino) async {
    try {
      await arquivo.rename(destino);
    } on FileSystemException {
      // rename falha entre unidades diferentes; copia e remove.
      await arquivo.copy(destino);
      await arquivo.delete();
    }
  }
}
