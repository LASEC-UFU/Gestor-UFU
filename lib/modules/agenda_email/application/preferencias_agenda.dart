import 'dart:convert';

import 'package:gestor_ufu/platform/services/key_value_store.dart';

/// Preferências das agendas no banco do Gestor: o calendário padrão das
/// atividades pessoais e profissionais e a classificação de cada
/// calendário (chave "provedor:id" → "Pessoal"/"Profissional").
class PreferenciasAgenda {
  PreferenciasAgenda([KeyValueStore? store])
    : _store = store ?? KeyValueStore();

  static const pessoalKey = 'agenda_email.calendario_pessoal.v1';
  static const profissionalKey = 'agenda_email.calendario_profissional.v1';
  static const classificacaoKey = 'agenda_email.classificacao.v1';

  // Chaves da primeira versão do módulo (migradas na leitura).
  static const _antigas = {
    pessoalKey: 'calendar.default.personal',
    profissionalKey: 'calendar.default.professional',
    classificacaoKey: 'calendar.classification',
  };

  final KeyValueStore _store;

  Future<String?> _ler(String chave) async {
    final v = await _store.readString(chave);
    if (v != null) return v;
    final antiga = await _store.readString(_antigas[chave]!);
    if (antiga != null) await _store.writeString(chave, antiga);
    return antiga;
  }

  Future<String> calendarioPessoal() async => await _ler(pessoalKey) ?? '';

  Future<String> calendarioProfissional() async =>
      await _ler(profissionalKey) ?? '';

  /// Calendário padrão da [categoria] ("Pessoal" ou "Profissional").
  Future<String> calendarioPadrao(String categoria) =>
      categoria.toLowerCase().startsWith('pro')
      ? calendarioProfissional()
      : calendarioPessoal();

  Future<Map<String, String>> classificacao() async {
    final raw = await _ler(classificacaoKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> salvar({
    required String pessoal,
    required String profissional,
    required Map<String, String> classificacao,
  }) async {
    await _store.writeString(pessoalKey, pessoal);
    await _store.writeString(profissionalKey, profissional);
    await _store.writeString(classificacaoKey, jsonEncode(classificacao));
  }
}
