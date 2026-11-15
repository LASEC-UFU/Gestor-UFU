import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/_modelo/domain/nota.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Serviço do módulo: toda a regra de negócio. A tela e os comandos chamam
/// este serviço — nunca o banco diretamente.
///
/// É um [ChangeNotifier]: a tela escuta e se redesenha quando um comando do
/// agente altera os dados.
class ModeloService extends ChangeNotifier {
  ModeloService(this._store);

  /// Chave no banco compartilhado. Use o prefixo do módulo e uma versão;
  /// depois de publicada, a chave nunca muda de nome (decisões, D4).
  static const key = 'modelo.notas.v1';

  final KeyValueStore _store;

  Future<List<Nota>> listar() async {
    final raw = await _store.readJson(key);
    if (raw is! List) return [];
    return [
      for (final item in raw.whereType<Map>())
        Nota.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<Nota> adicionar(String texto) async {
    final limpo = texto.trim();
    if (limpo.isEmpty) {
      // Erros esperados usam CommandException com código estável: a tela
      // mostra a mensagem e o agente recebe {ok: false, code, message}.
      throw const CommandException('texto_vazio', 'Escreva o texto da nota.');
    }
    final nota = Nota(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      texto: limpo,
      criadaEm: DateTime.now(),
    );
    await _salvar([...await listar(), nota]);
    return nota;
  }

  Future<Nota> remover(String id) async {
    final notas = await listar();
    final nota = notas.where((n) => n.id == id).firstOrNull;
    if (nota == null) {
      throw CommandException('nota_nao_encontrada', 'Nota "$id" não existe.');
    }
    await _salvar([...notas.where((n) => n.id != id)]);
    return nota;
  }

  Future<void> _salvar(List<Nota> notas) async {
    await _store.writeJson(key, [for (final n in notas) n.toJson()]);
    notifyListeners();
  }

  /// Chamado pelo módulo quando o banco muda por fora (outro computador).
  void recarregar() => notifyListeners();
}
