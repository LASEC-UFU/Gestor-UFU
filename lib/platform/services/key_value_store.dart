import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Banco do Gestor UFU (SharedPreferences, sincronizado entre computadores
/// pelo SharedPreferencesSyncService). Os módulos usam esta classe em vez de
/// chamar `SharedPreferences.getInstance()` diretamente.
///
/// As chaves existentes NÃO mudam de nome (compatibilidade com dados e
/// backups já sincronizados) — docs/arquitetura/decisoes.md, D4.
class KeyValueStore {
  KeyValueStore([Future<SharedPreferences> Function()? open])
    : _open = open ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _open;

  /// Atualiza o cache desta janela antes de ler dados alterados por outro
  /// engine Flutter (por exemplo, a janela do Agente de IA).
  Future<void> reload() async => (await _open()).reload();

  /// Lê um texto JSON e decodifica; `null` se ausente ou inválido.
  Future<Object?> readJson(String key) async {
    final raw = (await _open()).getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeJson(String key, Object? value) async =>
      (await _open()).setString(key, jsonEncode(value));

  Future<String?> readString(String key) async =>
      (await _open()).getString(key);

  Future<void> writeString(String key, String value) async =>
      (await _open()).setString(key, value);

  Future<List<String>?> readStringList(String key) async =>
      (await _open()).getStringList(key);

  Future<void> writeStringList(String key, List<String> value) async =>
      (await _open()).setStringList(key, value);

  Future<bool> contains(String key) async => (await _open()).containsKey(key);

  Future<void> remove(String key) async => (await _open()).remove(key);

  /// Chaves que começam com [prefix] (evita "índices" compartilhados: cada
  /// item numa chave própria não conflita entre computadores).
  Future<List<String>> keys([String prefix = '']) async => [
    for (final key in (await _open()).getKeys())
      if (key.startsWith(prefix)) key,
  ];

  /// Chave de um dado que depende do período letivo: `prefixo + token`,
  /// onde o token é o período em base64url sem "=" (formato já usado pelos
  /// módulos; não alterar).
  static String termScoped(String prefix, String term) {
    final token = base64Url
        .encode(utf8.encode(term.trim()))
        .replaceAll('=', '');
    return '$prefix$token';
  }
}
