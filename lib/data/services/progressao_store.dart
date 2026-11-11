import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/domain/entities/progressao.dart';

/// Persiste os processos de progressão/promoção no SharedPreferences, que já
/// participa do backup e da sincronização do Gestor UFU.
class ProgressaoStore {
  static const key = 'progressao_docente.v1';

  Future<List<ProgressaoDocente>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => ProgressaoDocente.fromJson(Map<String, dynamic>.from(e)))
        .toList()
      ..sort(
        (a, b) => (b.atualizadoEm ?? DateTime(0)).compareTo(
          a.atualizadoEm ?? DateTime(0),
        ),
      );
  }

  Future<void> saveAll(List<ProgressaoDocente> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }
}
