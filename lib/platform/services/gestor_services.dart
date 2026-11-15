import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Recursos que a plataforma oferece aos módulos. Criado uma vez em
/// `main.dart` e entregue a cada módulo na ativação.
///
/// Contratos entre módulos (ex.: "planejamento do Config Moodle", lido pelos
/// Diários e pelos Planos de Ensino) são registrados pela composição
/// (`app/`) e obtidos com [contract]; a dependência é sempre opcional.
class GestorServices {
  GestorServices({KeyValueStore? store}) : store = store ?? KeyValueStore();

  final KeyValueStore store;

  final _contracts = <Type, Object>{};

  void registerContract<T extends Object>(T implementation) =>
      _contracts[T] = implementation;

  /// Implementação do contrato [T], se algum módulo instalado a oferece.
  T? contract<T extends Object>() => _contracts[T] as T?;
}
