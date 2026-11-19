import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';

/// Leva o documento até o trecho do comentário e o destaca como
/// selecionado; [rolar] = false só destaca (o clique veio do próprio
/// documento). Devolve false se o trecho não foi encontrado.
typedef NavegarParaComentario =
    Future<bool> Function(ComentarioDocumento comentario, bool rolar);

/// Estado da camada de comentários: comentário selecionado, cartões
/// expandidos, busca e painel aberto/fechado com sua largura. A tela que
/// mostra o documento informa a lista ([definirComentarios]) e como navegar
/// ([navegar]/[aoLimpar]); o resto é comum a todos os módulos.
class LeitorComentadoController extends ChangeNotifier {
  LeitorComentadoController({this.painelAberto = true});

  List<ComentarioDocumento> _todos = const [];
  String? _selecionado;
  final Set<String> _expandidos = {};
  final Map<String, String> _avisos = {};
  String _busca = '';

  /// Painel lateral (desktop) ou folha (tela estreita) aberto.
  bool painelAberto;

  /// Em tela estreita, a folha mostra só o comentário ativo.
  bool folhaCompacta = false;

  /// Largura do painel no desktop (null = padrão).
  double? largura;

  NavegarParaComentario? navegar;
  VoidCallback? aoLimpar;

  List<ComentarioDocumento> get todos => _todos;
  String? get selecionado => _selecionado;
  String get busca => _busca;
  bool expandido(String id) => _expandidos.contains(id);

  /// Mensagem de quando a navegação até o trecho falhou.
  String? aviso(String id) => _avisos[id];

  ComentarioDocumento? get comentarioSelecionado =>
      _todos.where((c) => c.id == _selecionado).firstOrNull;

  /// Comentários que passam na busca, na ordem do documento.
  List<ComentarioDocumento> get visiveis {
    final termo = normalizarBusca(_busca);
    if (termo.isEmpty) return _todos;
    return [
      for (final c in _todos)
        if (normalizarBusca(c.textoBusca).contains(termo)) c,
    ];
  }

  /// Atualiza a lista (na ordem do documento). Seleção de um comentário que
  /// sumiu é desfeita.
  void definirComentarios(List<ComentarioDocumento> lista) {
    _todos = lista;
    final ids = {for (final c in lista) c.id};
    _expandidos.retainAll(ids);
    final expandidoSelecionado =
        _selecionado != null && _expandidos.contains(_selecionado);
    _expandidos.clear();
    if (expandidoSelecionado) _expandidos.add(_selecionado!);
    _avisos.removeWhere((k, _) => !ids.contains(k));
    if (_selecionado != null && !ids.contains(_selecionado)) {
      _selecionado = null;
      aoLimpar?.call();
    }
  }

  void definirBusca(String termo) {
    if (termo == _busca) return;
    _busca = termo;
    notifyListeners();
  }

  /// Seleciona, expande e leva o documento ao trecho do comentário.
  Future<void> selecionar(
    String id, {
    bool rolar = true,
    bool expandir = true,
  }) async {
    final c = _todos.where((x) => x.id == id).firstOrNull;
    if (c == null) return;
    // Ao clicar numa marca do documento, transfere a expansão atual para o
    // novo destaque. Se o comentário anterior estava recolhido, mantém esse
    // estado; sem seleção anterior, o primeiro destaque abre por padrão.
    final manterExpandido = rolar
        ? expandir
        : _selecionado == null || _expandidos.contains(_selecionado);
    _selecionado = id;
    _expandidos.clear();
    if (manterExpandido) _expandidos.add(id);
    _avisos.remove(id);
    if (!painelAberto) painelAberto = true;
    notifyListeners();
    final ir = navegar;
    if (!c.ancorado) {
      aoLimpar?.call();
      _avisos[id] =
          'Este comentário não tem um trecho correspondente no documento '
          '(o texto pode ter sido alterado).';
      notifyListeners();
      return;
    }
    if (ir == null) return;
    final ok = await ir(c, rolar);
    if (_selecionado != id) return;
    if (!ok) {
      _avisos[id] =
          'Não foi possível localizar o trecho deste comentário no documento.';
    }
    notifyListeners();
  }

  /// Clique no cartão: seleciona e expande; no selecionado expandido,
  /// recolhe e desfaz a seleção; no selecionado recolhido, expande.
  Future<void> alternar(String id) async {
    if (_selecionado != id) {
      await selecionar(id);
      return;
    }
    if (_expandidos.contains(id)) {
      _expandidos.remove(id);
      limparSelecao();
    } else {
      _expandidos.add(id);
      notifyListeners();
    }
  }

  /// Recolhe/expande sem mudar a seleção (botão de seta do cartão).
  Future<void> alternarExpansao(String id) async {
    if (_expandidos.remove(id)) {
      notifyListeners();
      return;
    }
    await selecionar(id);
  }

  void limparSelecao() {
    if (_selecionado == null) return;
    _selecionado = null;
    _expandidos.clear();
    aoLimpar?.call();
    notifyListeners();
  }

  int get indiceSelecionado => visiveis.indexWhere((c) => c.id == _selecionado);

  bool get temProximo {
    final v = visiveis;
    return v.isNotEmpty && indiceSelecionado < v.length - 1;
  }

  bool get temAnterior => indiceSelecionado > 0;

  Future<void> proximo() async {
    final v = visiveis;
    if (v.isEmpty) return;
    final i = indiceSelecionado;
    if (i >= v.length - 1) return;
    final alvo = v[i + 1];
    _expandidos.remove(_selecionado);
    await selecionar(alvo.id);
  }

  Future<void> anterior() async {
    final v = visiveis;
    if (v.isEmpty) return;
    final i = indiceSelecionado;
    if (i <= 0) return;
    final alvo = v[i - 1];
    _expandidos.remove(_selecionado);
    await selecionar(alvo.id);
  }

  void abrirPainel() {
    painelAberto = true;
    folhaCompacta = false;
    notifyListeners();
  }

  void fecharPainel() {
    painelAberto = false;
    notifyListeners();
  }

  void alternarPainel() => painelAberto ? fecharPainel() : abrirPainel();

  void definirFolhaCompacta(bool v) {
    if (folhaCompacta == v) return;
    folhaCompacta = v;
    notifyListeners();
  }

  void definirLargura(double v) {
    largura = v;
    notifyListeners();
  }
}
