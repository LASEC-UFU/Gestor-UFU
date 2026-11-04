import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:gestor_ufu/domain/entities/plano_trabalho.dart';

/// Dados do módulo permanecem no mesmo armazenamento local do Gestor UFU.
class PlanosTrabalhoStore {
  static const _key = 'gestor_ufu_planos_trabalho_v1';
  static const _uuid = Uuid();

  Future<List<PlanoTrabalho>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map(
            (item) => PlanoTrabalho.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList()
        ..sort((a, b) => a.nome.toLowerCase().compareTo(b.nome.toLowerCase()));
    } on FormatException {
      throw const FormatException(
        'Os dados dos Planos de Trabalho estão inválidos. Exporte um backup antes de tentar recuperá-los.',
      );
    }
  }

  Future<PlanoTrabalho> save({
    String? id,
    required String nome,
    required String numero,
    required String nomeArvore,
    required String interessado,
    required String pdfPath,
  }) async {
    final cleanName = nome.trim();
    final cleanNumber = numero.trim();
    final cleanTree = nomeArvore.trim();
    if (cleanName.isEmpty) throw StateError('Informe um nome para o plano.');
    if (cleanNumber.isEmpty && cleanTree.isEmpty) {
      throw StateError(
        'Informe o número ou o nome do documento na árvore do SEI.',
      );
    }
    if (cleanNumber.length > 50 || cleanTree.length > 50) {
      throw StateError('Número e nome na árvore devem ter até 50 caracteres.');
    }
    final path = pdfPath.trim();
    if (path.isNotEmpty) {
      final file = File(path);
      if (p.extension(path).toLowerCase() != '.pdf' || !await file.exists()) {
        throw StateError('Selecione um arquivo PDF existente.');
      }
      final handle = await file.open();
      try {
        final header = await handle.read(1024);
        if (!String.fromCharCodes(header).contains('%PDF-')) {
          throw StateError(
            'O arquivo selecionado não parece ser um PDF válido.',
          );
        }
      } finally {
        await handle.close();
      }
    }
    final plans = await list();
    final previous = id == null
        ? null
        : plans.where((item) => item.id == id).firstOrNull;
    final plan = PlanoTrabalho(
      id: id ?? _uuid.v4(),
      nome: cleanName,
      numero: cleanNumber,
      nomeArvore: cleanTree,
      interessado: interessado.trim(),
      pdfPath: path,
      spreadsheetData: previous?.spreadsheetData,
    );
    plans.removeWhere((item) => item.id == plan.id);
    plans.add(plan);
    await _write(plans);
    return plan;
  }

  Future<void> delete(String id) async {
    final plans = await list();
    plans.removeWhere((item) => item.id == id);
    await _write(plans);
  }

  Future<void> saveSpreadsheetData(String id, Map<String, dynamic> data) async {
    final plans = await list();
    final index = plans.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('Plano de Trabalho não encontrado.');
    plans[index] = plans[index].copyWith(spreadsheetData: data);
    await _write(plans);
  }

  Future<void> _write(List<PlanoTrabalho> plans) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(plans.map((plan) => plan.toJson()).toList()),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
