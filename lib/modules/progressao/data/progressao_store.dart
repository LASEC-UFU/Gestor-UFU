import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Persiste os processos de progressão/promoção no banco do Gestor, que já
/// participa do backup e da sincronização.
class ProgressaoStore {
  ProgressaoStore([KeyValueStore? store]) : _store = store ?? KeyValueStore();

  static const key = 'progressao_docente.v1';

  final KeyValueStore _store;

  Future<List<ProgressaoDocente>> list() async {
    final decoded = await _store.readJson(key);
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

  Future<void> saveAll(List<ProgressaoDocente> items) =>
      _store.writeJson(key, items.map((e) => e.toJson()).toList());
}
