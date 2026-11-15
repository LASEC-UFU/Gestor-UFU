import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

/// Leitura da árvore de processos do SEI: abre o Edge, lê os documentos do
/// processo aberto e monta o inventário. Usado pela tela e pelos comandos.
class SeiArvoreService extends ChangeNotifier {
  SeiArvoreService({KeyValueStore? store, SeiAutomationService? automation})
    : _store = store ?? KeyValueStore(),
      automation = automation ?? SeiAutomationService();

  static const addressKey = 'sei_tree_address_url';
  static const defaultAddress = 'https://sei.ufu.br';

  final KeyValueStore _store;
  final SeiAutomationService automation;

  final List<SeiDocumento> _documentos = [];
  final List<String> _logs = [];
  String _host = '';
  bool _extraindo = false;
  int progresso = 0;
  int total = 0;
  String etapa = '';

  List<SeiDocumento> get documentos => List.unmodifiable(_documentos);
  List<String> get logs => List.unmodifiable(_logs);
  bool get extraindo => _extraindo;
  bool get conectado => automation.isConnected;

  void log(String message) {
    if (message.trim().isEmpty) return;
    _logs.add(message.trim());
    if (_logs.length > 250) _logs.removeAt(0);
    notifyListeners();
  }

  Future<String> enderecoSalvo() async {
    final saved = await _store.readString(addressKey);
    return saved == null || saved.trim().isEmpty ? defaultAddress : saved;
  }

  /// Abre (ou reaproveita) o Edge do SEI no endereço informado.
  Future<String> abrir(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const CommandException(
        'endereco_invalido',
        'Informe um endereço iniciado por http:// ou https://.',
      );
    }
    await _store.writeString(addressKey, uri.toString());
    _host = uri.host;
    log('Abrindo o SEI no Edge. Faça login e navegue até o processo desejado.');
    final opened = await automation.openBrowser(uri.toString());
    log('Edge aberto em $opened.');
    notifyListeners();
    return opened;
  }

  /// Lê a árvore do processo aberto no Edge. Com [lerConteudo], busca o
  /// texto de cada documento para identificar data e resumo.
  Future<List<SeiDocumento>> extrair({bool lerConteudo = true}) async {
    if (_extraindo) {
      throw const CommandException(
        'em_andamento',
        'Uma leitura já está em andamento.',
      );
    }
    if (!automation.isConnected) {
      throw const CommandException(
        'sei_fechado',
        'Abra o SEI pelo app (relato.abrirSei), entre e abra o processo desejado.',
      );
    }
    final current = Uri.tryParse(automation.currentUrl ?? '')?.host ?? '';
    if (_host.isNotEmpty && current.toLowerCase() != _host.toLowerCase()) {
      throw const CommandException(
        'fora_do_sei',
        'O Edge não está no endereço do SEI. Volte ao SEI e abra o processo.',
      );
    }
    _extraindo = true;
    _documentos.clear();
    progresso = 0;
    total = 0;
    etapa = 'Lendo a árvore do processo…';
    notifyListeners();
    try {
      final nodes = await automation.treeDocuments();
      if (nodes.isEmpty) {
        throw const CommandException(
          'arvore_vazia',
          'Nenhum documento encontrado. Abra um processo no SEI (a árvore '
              'precisa estar visível).',
        );
      }
      total = nodes.length;
      log('${nodes.length} documento(s) na árvore.');
      for (var i = 0; i < nodes.length; i++) {
        final node = nodes[i];
        progresso = i + 1;
        etapa = node.text;
        notifyListeners();
        var texto = '';
        if (lerConteudo) {
          try {
            texto = await automation.documentText(node.href);
          } catch (error) {
            log('Sem texto de "${node.text}": $error');
          }
        }
        _documentos.add(SeiDocumento.fromTree(i + 1, node.text, texto: texto));
      }
      log('Inventário com ${_documentos.length} documento(s).');
      return documentos;
    } finally {
      _extraindo = false;
      etapa = '';
      notifyListeners();
    }
  }

  String relatorio() => SeiArvoreTexto.relatorio(_documentos);

  Future<void> salvarRelatorio(String path) async {
    await File(path).writeAsString(relatorio(), encoding: utf8);
    log('Inventário salvo em $path');
  }

  @visibleForTesting
  void definirDocumentos(List<SeiDocumento> docs) {
    _documentos
      ..clear()
      ..addAll(docs);
    notifyListeners();
  }
}
