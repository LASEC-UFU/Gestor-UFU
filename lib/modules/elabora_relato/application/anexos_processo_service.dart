import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_paths.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Documentos do processo anexados para leitura e marcação (PDF com texto,
/// DOCX, TXT/MD, HTML). O Gestor guarda uma cópia de cada arquivo (pelo
/// SHA-1, sem duplicar) e o texto extraído em cache na pasta de anexos; as
/// marcações e comentários ficam no banco, por processo
/// (`parecer_anexos.<id>`).
class AnexosProcessoService extends ChangeNotifier {
  AnexosProcessoService({
    KeyValueStore? store,
    Future<String> Function()? pasta,
  }) : _store = store ?? KeyValueStore(),
       _pastaFn =
           pasta ?? (() => GestorPaths.outputDir('elabora_relato/anexos'));

  static const anexosKey = 'parecer_anexos';
  static const _limiteBytes = 150 * 1024 * 1024;

  final KeyValueStore _store;
  final Future<String> Function() _pastaFn;
  String _processoId = '';
  bool _carregado = false;
  final List<AnexoProcesso> _anexos = [];
  final Map<String, List<ParagrafoFonte>> _cache = {};

  List<AnexoProcesso> get anexos => List.unmodifiable(_anexos);

  String get _key =>
      _processoId.isEmpty ? anexosKey : '$anexosKey.$_processoId';

  Future<void> usarProcesso(String id) async {
    _processoId = id;
    _anexos.clear();
    _carregado = false;
    await carregar();
  }

  Future<void> carregar() async {
    if (_carregado) return;
    _carregado = true;
    final raw = await _store.readJson(_key);
    _anexos
      ..clear()
      ..addAll([
        for (final a in raw is List ? raw : const [])
          if (a is Map) AnexoProcesso.fromJson(Map<String, dynamic>.from(a)),
      ]);
    notifyListeners();
  }

  Future<void> _gravar() async {
    await _store.writeJson(_key, [for (final a in _anexos) a.toJson()]);
    notifyListeners();
  }

  AnexoProcesso exigir(String id) {
    final a = _anexos.where((x) => x.id == id).firstOrNull;
    if (a == null) {
      throw CommandException(
        'anexo_inexistente',
        'Documento não encontrado neste processo: $id.',
      );
    }
    return a;
  }

  /// Caminho da cópia guardada do anexo.
  Future<String> caminho(AnexoProcesso a) async =>
      p.join(await _pastaFn(), a.arquivoGuardado);

  /// Anexa o arquivo [origem] ao processo: copia para a pasta de anexos,
  /// extrai o texto e o guarda em cache. O original não é alterado.
  Future<AnexoProcesso> anexar(String origem) async {
    await carregar();
    final file = File(origem);
    if (!await file.exists()) {
      throw CommandException(
        'arquivo_nao_encontrado',
        'Arquivo não encontrado: $origem',
      );
    }
    final ext = p.extension(origem).toLowerCase();
    if (!BaseDocumentosIndexer.extensoesSuportadas.contains(ext)) {
      throw CommandException(
        'formato_nao_suportado',
        'Formato não suportado ($ext). Anexe PDF, DOCX, TXT, MD ou HTML '
            '(um .doc antigo precisa ser salvo como .docx).',
      );
    }
    if (await file.length() > _limiteBytes) {
      throw const CommandException(
        'arquivo_grande',
        'Arquivo maior que 150 MB.',
      );
    }
    final bytes = await file.readAsBytes();
    final hash = sha1.convert(bytes).toString();
    final pasta = await _pastaFn();
    await Directory(pasta).create(recursive: true);
    final guardado = File(p.join(pasta, '$hash$ext'));
    if (!await guardado.exists()) await guardado.writeAsBytes(bytes);

    final ({List<ParagrafoFonte> paragrafos, int paginas, List<int> semTexto})
    lido;
    try {
      lido = await BaseDocumentosIndexer.extrairParagrafos(guardado.path);
    } on StateError catch (e) {
      throw CommandException('leitura_falhou', e.message);
    }
    await _gravarCache(hash, lido.paragrafos);
    final aviso = lido.paragrafos.isEmpty
        ? (ext == '.pdf'
              ? 'PDF sem camada de texto (digitalizado como imagem): não dá '
                    'para marcar nem consultar a IA sem OCR, que o Gestor não '
                    'faz. Use "Abrir original" para ler.'
              : 'Nenhum texto encontrado no arquivo.')
        : lido.semTexto.isNotEmpty
        ? '${lido.semTexto.length} página(s) sem texto extraível '
              '(${lido.semTexto.take(8).join(', ')}'
              '${lido.semTexto.length > 8 ? '…' : ''}): provavelmente imagens '
              'digitalizadas, que não aparecem aqui.'
        : '';
    final anexo = AnexoProcesso(
      id: const Uuid().v4(),
      nome: p.basename(origem),
      hash: hash,
      extensao: ext,
      origem: origem,
      paginas: lido.paginas,
      paragrafos: lido.paragrafos.length,
      aviso: aviso,
      anexadoEm: DateTime.now(),
    );
    _anexos.add(anexo);
    await _gravar();
    return anexo;
  }

  Future<void> _gravarCache(String hash, List<ParagrafoFonte> pars) async {
    _cache[hash] = pars;
    final f = File(p.join(await _pastaFn(), '$hash.texto.json'));
    await f.writeAsString(
      jsonEncode([
        for (final x in pars)
          {'t': x.texto, if (x.pagina > 0) 'p': x.pagina, if (x.titulo) 'h': 1},
      ]),
      encoding: utf8,
    );
  }

  /// Parágrafos do texto do anexo (do cache; reextrai da cópia se faltar).
  Future<List<ParagrafoFonte>> paragrafos(AnexoProcesso a) async {
    final emMemoria = _cache[a.hash];
    if (emMemoria != null) return emMemoria;
    final pasta = await _pastaFn();
    final cache = File(p.join(pasta, '${a.hash}.texto.json'));
    if (await cache.exists()) {
      try {
        final lista = jsonDecode(await cache.readAsString());
        if (lista is List) {
          final pars = [
            for (final x in lista.whereType<Map>())
              (
                texto: '${x['t'] ?? ''}',
                pagina: (x['p'] as num?)?.toInt() ?? 0,
                titulo: x['h'] == 1,
              ),
          ];
          return _cache[a.hash] = pars;
        }
      } catch (_) {
        // Cache corrompido: reextrai abaixo.
      }
    }
    final guardado = File(p.join(pasta, a.arquivoGuardado));
    if (!await guardado.exists()) {
      throw CommandException(
        'arquivo_ausente',
        'A cópia de "${a.nome}" não está neste computador (os anexos ficam '
            'na pasta Documentos\\GestorUFU Agente\\elabora_relato\\anexos '
            'de quem anexou). Anexe o arquivo de novo aqui.',
      );
    }
    try {
      final lido = await BaseDocumentosIndexer.extrairParagrafos(guardado.path);
      await _gravarCache(a.hash, lido.paragrafos);
      return lido.paragrafos;
    } on StateError catch (e) {
      throw CommandException('leitura_falhou', e.message);
    }
  }

  Future<void> renomear(String id, String nome) async {
    final a = exigir(id);
    if (nome.trim().isEmpty) return;
    _substituir(a.copyWith(nome: nome.trim()));
    await _gravar();
  }

  /// Retira o anexo do processo (com as marcações). A cópia guardada fica
  /// na pasta de anexos (pode ser usada por outro processo ou cópia).
  Future<void> remover(String id) async {
    exigir(id);
    _anexos.removeWhere((a) => a.id == id);
    await _gravar();
  }

  void _substituir(AnexoProcesso a) {
    final i = _anexos.indexWhere((x) => x.id == a.id);
    if (i >= 0) _anexos[i] = a;
  }

  /// Cria ou atualiza uma marcação.
  Future<void> salvarMarcacao(String anexoId, MarcacaoAnexo m) async {
    final a = exigir(anexoId);
    final lista = [...a.marcacoes];
    final i = lista.indexWhere((x) => x.id == m.id);
    if (i < 0) {
      lista.add(m);
    } else {
      lista[i] = m;
    }
    lista.sort(
      (x, y) => x.paragrafo != y.paragrafo
          ? x.paragrafo.compareTo(y.paragrafo)
          : x.inicio.compareTo(y.inicio),
    );
    _substituir(a.copyWith(marcacoes: lista));
    await _gravar();
  }

  Future<void> excluirMarcacao(String anexoId, String marcacaoId) async {
    final a = exigir(anexoId);
    _substituir(
      a.copyWith(
        marcacoes: a.marcacoes.where((m) => m.id != marcacaoId).toList(),
      ),
    );
    await _gravar();
  }

  /// Nova marcação de [inicio]..[fim] do parágrafo [paragrafo].
  static MarcacaoAnexo novaMarcacao({
    required int paragrafo,
    required String textoParagrafo,
    required int inicio,
    required int fim,
    String cor = 'amarelo',
    String comentario = '',
  }) {
    final a = inicio.clamp(0, textoParagrafo.length);
    final b = fim.clamp(a, textoParagrafo.length);
    final agora = DateTime.now();
    return MarcacaoAnexo(
      id: const Uuid().v4(),
      paragrafo: paragrafo,
      inicio: a,
      fim: b,
      texto: textoParagrafo.substring(a, b),
      cor: cor,
      comentario: comentario,
      criadoEm: agora,
      atualizadoEm: agora,
    );
  }

  /// Localização legível de um parágrafo ("p. 3, parágrafo 12").
  static String local(List<ParagrafoFonte> pars, int i) {
    if (i < 0 || i >= pars.length) return 'parágrafo ${i + 1}';
    final pag = pars[i].pagina;
    return pag > 0 ? 'p. $pag, parágrafo ${i + 1}' : 'parágrafo ${i + 1}';
  }

  /// Texto dos parágrafos vizinhos de [i] (contexto para a IA).
  static ({String antes, String depois}) contexto(
    List<ParagrafoFonte> pars,
    int i, {
    int raio = 3,
  }) {
    String juntar(Iterable<ParagrafoFonte> xs) =>
        xs.map((x) => x.texto).join('\n');
    final ini = (i - raio).clamp(0, pars.length);
    final fim = (i + 1 + raio).clamp(0, pars.length);
    return (
      antes: juntar(pars.sublist(ini, i.clamp(0, pars.length))),
      depois: juntar(pars.sublist((i + 1).clamp(0, pars.length), fim)),
    );
  }
}
