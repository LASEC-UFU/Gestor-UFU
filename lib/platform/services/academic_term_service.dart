import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/domain/entities/academic_term.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Períodos letivos compartilhados por todos os módulos (Config Moodle,
/// Preenche Diários, Ajusta Horários…). Antes cada tela lia e gravava estas
/// chaves do seu jeito; agora todas usam este serviço.
///
/// As chaves não mudam de nome (dados já sincronizados).
class AcademicTermService extends ChangeNotifier {
  AcademicTermService(this._store, {this.defaultTerm = defaultTermName});

  /// Período usado quando ainda não há nenhum cadastrado.
  static const defaultTermName = '2º semestre de 2026';

  /// Instância da janela principal, usada pelo seletor do cabeçalho padrão
  /// (definida em `main.dart`; nula em testes e janelas secundárias).
  static AcademicTermService? shared;

  static const termsKey = 'ajusta_horarios_periodos_letivos';
  static const activeKey = 'ajusta_horarios_periodo_letivo';

  final KeyValueStore _store;
  final String defaultTerm;

  List<String> _terms = [];
  String _active = '';

  /// Mais recentes primeiro.
  List<String> get terms => List.unmodifiable(_terms);
  String get active => _active;

  /// Corrige o "º"/"ª" gravado com codificação dupla por versões antigas.
  static String normalize(String value) =>
      value.trim().replaceAll('Âº', 'º').replaceAll('Âª', 'ª');

  /// Lê, normaliza e grava de volta (lista ordenada e período ativo válido).
  Future<void> load() async {
    final saved = await _store.readString(activeKey);
    final savedActive = saved == null ? null : normalize(saved);
    final terms = AcademicTerm.newestFirst(
      (await _store.readStringList(termsKey) ?? const <String>[])
          .map(normalize)
          .where((term) => term.isNotEmpty),
    );
    if (savedActive != null &&
        savedActive.isNotEmpty &&
        !terms.contains(savedActive)) {
      terms.add(savedActive);
    }
    if (terms.isEmpty) terms.add(defaultTerm);
    _terms = AcademicTerm.newestFirst(terms);
    _active = savedActive != null && _terms.contains(savedActive)
        ? savedActive
        : _terms.first;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    await _store.writeStringList(termsKey, _terms);
    await _store.writeString(activeKey, _active);
  }

  Future<void> setActive(String term) async {
    if (!_terms.contains(term) || term == _active) return;
    _active = term;
    await _store.writeString(activeKey, term);
    notifyListeners();
  }

  /// Cria (ou reaproveita um equivalente, ex.: "2026/2" = "2º semestre de
  /// 2026") e torna ativo. Devolve o nome usado.
  Future<String> create(String name) async {
    final requested = name.trim();
    if (requested.isEmpty) return _active;
    final canonical = AcademicTerm.parse(requested)?.key ?? requested;
    final existing =
        AcademicTerm.findEquivalent(_terms, canonical) ??
        _terms.cast<String?>().firstWhere(
          (item) => item?.toLowerCase() == canonical.toLowerCase(),
          orElse: () => null,
        );
    if (existing != null) {
      await setActive(existing);
      return existing;
    }
    _terms = AcademicTerm.newestFirst([..._terms, canonical]);
    _active = canonical;
    await _persist();
    notifyListeners();
    return canonical;
  }

  /// Substitui a lista (gerenciador de períodos das telas). Mantém o ativo
  /// se ainda existir.
  Future<void> replaceAll(List<String> terms, {String? active}) async {
    final cleaned = AcademicTerm.newestFirst(
      terms.map(normalize).where((t) => t.isNotEmpty).toSet(),
    );
    if (cleaned.isEmpty) return;
    _terms = cleaned;
    _active = active != null && cleaned.contains(active)
        ? active
        : (cleaned.contains(_active) ? _active : cleaned.first);
    await _persist();
    notifyListeners();
  }
}
