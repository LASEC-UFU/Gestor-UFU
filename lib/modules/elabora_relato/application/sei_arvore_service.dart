import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/platform/services/sei_automation_service.dart';

/// Leitura da árvore de processos do SEI: abre o Edge, lê os documentos do
/// processo aberto e monta o inventário. Usado pela tela e pelos comandos.
class SeiArvoreService extends ChangeNotifier {
  SeiArvoreService({
    KeyValueStore? store,
    SeiAutomationService? automation,
    this.ia,
  }) : _store = store ?? KeyValueStore(),
       automation = automation ?? SeiAutomationService();

  static const addressKey = 'sei_tree_address_url';
  static const inventoryKey = 'parecer_relato_inventario';
  static const defaultAddress = 'https://sei.ufu.br';

  final KeyValueStore _store;
  final SeiAutomationService automation;

  /// Ponte com o Agente de IA (resumos); null se não houver.
  final AiTextService? ia;

  bool _resumindo = false;
  bool _carregado = false;

  /// Resumos com IA em andamento.
  bool get resumindo => _resumindo;

  String _processoId = '';

  String get _inventoryKey =>
      _processoId.isEmpty ? inventoryKey : '$inventoryKey.$_processoId';

  /// Troca o inventário pelo do processo [id] (o Edge do SEI continua
  /// aberto). Não troca durante uma leitura ou resumo.
  Future<void> usarProcesso(String id) async {
    if (_extraindo || _resumindo) {
      throw const CommandException(
        'em_andamento',
        'Aguarde a leitura da árvore ou os resumos terminarem antes de '
            'trocar de processo.',
      );
    }
    _processoId = id;
    _documentos.clear();
    _logs.clear();
    _carregado = false;
    await carregarInventario();
    notifyListeners();
  }

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
  Future<List<SeiDocumento>> extrair({
    bool lerConteudo = true,
    CommandExecutionContext? context,
  }) async {
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
      context?.reportProgress('Documentos localizados', fraction: 0);
      log('${nodes.length} documento(s) na árvore.');
      for (var i = 0; i < nodes.length; i++) {
        context?.checkCancellation();
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
        _documentos.add(
          SeiDocumento.fromTree(
            i + 1,
            node.text,
            texto: texto,
            href: node.href,
          ),
        );
        context?.reportProgress(
          'Documento ${i + 1} de ${nodes.length}: ${node.text}',
          fraction: (i + 1) / nodes.length,
        );
      }
      log('Inventário com ${_documentos.length} documento(s).');
      await _salvarInventario();
      return documentos;
    } finally {
      _extraindo = false;
      etapa = '';
      notifyListeners();
    }
  }

  String relatorio() => SeiArvoreTexto.relatorio(_documentos);

  /// Recupera o último inventário salvo (sem o texto dos documentos).
  Future<void> carregarInventario() async {
    if (_carregado) return;
    _carregado = true;
    if (_documentos.isNotEmpty) return;
    final raw = await _store.readJson(_inventoryKey);
    if (raw is! List) return;
    _documentos.addAll([
      for (final item in raw.whereType<Map>())
        SeiDocumento.fromJson(Map<String, dynamic>.from(item)),
    ]);
    notifyListeners();
  }

  /// Relê o inventário alterado por fora (agente gravando direto na chave,
  /// outro computador). Mantém o texto lido dos documentos (só em memória)
  /// quando a árvore é a mesma. Não age durante leitura ou resumos.
  Future<bool> recarregarDoBanco() async {
    if (!_carregado || _extraindo || _resumindo) return false;
    final raw = await _store.readJson(_inventoryKey);
    if (raw is! List) return false;
    final novos = [
      for (final item in raw.whereType<Map>())
        SeiDocumento.fromJson(Map<String, dynamic>.from(item)),
    ];
    String assinatura(List<SeiDocumento> l) =>
        l.map((d) => d.toJson().toString()).join('|');
    if (assinatura(novos) == assinatura(_documentos)) return false;
    final mesmaArvore =
        novos.length == _documentos.length &&
        [
          for (var i = 0; i < novos.length; i++)
            novos[i].ordem == _documentos[i].ordem &&
                novos[i].codigoSei == _documentos[i].codigoSei,
        ].every((x) => x);
    final atualizados = mesmaArvore
        ? [
            for (var i = 0; i < novos.length; i++)
              _documentos[i].copyWith(
                data: novos[i].data,
                resumo: novos[i].resumo,
              ),
          ]
        : novos;
    _documentos
      ..clear()
      ..addAll(atualizados);
    notifyListeners();
    return true;
  }

  Future<void> _salvarInventario() => _store.writeJson(_inventoryKey, [
    for (final d in _documentos) d.toJson(),
  ]);

  /// Corrige data/resumo de um documento (revisão manual ou do agente).
  Future<void> atualizarDocumento(
    int ordem, {
    String? data,
    String? resumo,
  }) async {
    final i = _documentos.indexWhere((d) => d.ordem == ordem);
    if (i < 0) {
      throw CommandException(
        'documento_inexistente',
        'Não há documento de ordem $ordem no inventário.',
      );
    }
    _documentos[i] = _documentos[i].copyWith(
      data: data?.trim(),
      resumo: resumo?.trim(),
    );
    notifyListeners();
    await _salvarInventario();
  }

  /// Texto visível de um documento (vazio se não foi lido nesta sessão).
  String textoDe(int ordem) =>
      _documentos.where((d) => d.ordem == ordem).firstOrNull?.texto ?? '';

  /// Gera o resumo de cada documento com o Agente de IA, em lotes. Com
  /// [apenasVazios], mantém os resumos já preenchidos. Devolve quantos
  /// resumos foram atualizados.
  Future<int> resumirComIa({bool apenasVazios = false}) async {
    final ai = ia;
    if (ai == null) {
      throw const CommandException(
        'ia_indisponivel',
        'O Agente de IA não está disponível nesta janela.',
      );
    }
    if (_resumindo || _extraindo) {
      throw const CommandException(
        'em_andamento',
        'Aguarde a operação em andamento terminar.',
      );
    }
    final alvo = [
      for (final d in _documentos)
        if (!apenasVazios || d.resumo.trim().isEmpty) d,
    ];
    if (alvo.isEmpty) return 0;
    _resumindo = true;
    progresso = 0;
    total = alvo.length;
    etapa = 'Preparando os resumos com IA…';
    notifyListeners();
    var atualizados = 0;
    try {
      log('Resumos com IA: ${await ai.descricao()}.');
      const tamanhoLote = 8;
      for (var inicio = 0; inicio < alvo.length; inicio += tamanhoLote) {
        final lote = alvo.skip(inicio).take(tamanhoLote).toList();
        etapa =
            'Resumindo documentos ${lote.first.ordem} a ${lote.last.ordem}…';
        notifyListeners();
        final resposta = await ai.gerar(
          sistema: resumoSistema,
          prompt: resumoPrompt(lote),
        );
        final resumos = lerResumos(resposta);
        if (resumos.isEmpty) {
          log(
            'A IA não devolveu resumos legíveis para o lote '
            '${lote.first.ordem}–${lote.last.ordem}.',
          );
        }
        for (final d in lote) {
          final r = resumos[d.ordem];
          if (r == null || r.isEmpty) continue;
          final i = _documentos.indexWhere((x) => x.ordem == d.ordem);
          if (i >= 0) {
            _documentos[i] = _documentos[i].copyWith(resumo: r);
            atualizados++;
          }
        }
        progresso = (inicio + lote.length).clamp(0, alvo.length);
        notifyListeners();
      }
      await _salvarInventario();
      log('IA: $atualizados resumo(s) atualizados. Revise antes de usar.');
      return atualizados;
    } finally {
      _resumindo = false;
      etapa = '';
      notifyListeners();
    }
  }

  static const resumoSistema = '''
Você ajuda a redigir o RELATÓRIO de pareceres de conselhos da Universidade
Federal de Uberlândia. Para cada documento de um processo SEI, escreva um
resumo curto (uma frase, até 35 palavras) do que o documento é ou faz, no
estilo: "encaminhamento do processo pela PROGRAD à SEGER indicando
relatoria", "solicitação da Pró-Reitora de Graduação ao Presidente do
Conselho para inserção do tema na pauta", "parecer da relatora favorável à
alteração dos artigos 41 e 42 da Resolução nº 46/2022".
Regras: comece com letra minúscula; não repita o tipo, o número nem a data
do documento; sem ponto final; cite órgãos pelas siglas usadas no texto;
não invente fatos. Se o texto estiver vazio, deduza do nome apenas o que for
evidente ou devolva "".
Responda SOMENTE com JSON: [{"ordem": 1, "resumo": "..."}, ...]''';

  /// Pedido de resumo de um lote de documentos.
  static String resumoPrompt(List<SeiDocumento> lote) {
    final b = StringBuffer('Documentos:\n');
    for (final d in lote) {
      var texto = d.texto.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (texto.length > 2500) texto = '${texto.substring(0, 2500)}…';
      b
        ..writeln('---')
        ..writeln('ordem: ${d.ordem}')
        ..writeln('nome na árvore: ${d.nomeArvore}')
        ..writeln('data: ${d.data.isEmpty ? 'não identificada' : d.data}')
        ..writeln(
          'texto: ${texto.isEmpty ? '(sem texto: PDF ou anexo)' : texto}',
        );
    }
    return b.toString();
  }

  /// Lê a resposta da IA: lista JSON de {ordem, resumo} (tolera texto em
  /// volta e blocos ```json).
  static Map<int, String> lerResumos(String resposta) {
    final inicio = resposta.indexOf('[');
    final fim = resposta.lastIndexOf(']');
    if (inicio < 0 || fim <= inicio) return const {};
    try {
      final lista = jsonDecode(resposta.substring(inicio, fim + 1));
      if (lista is! List) return const {};
      return {
        for (final item in lista.whereType<Map>())
          if (item['ordem'] is num)
            (item['ordem'] as num).toInt(): '${item['resumo'] ?? ''}'
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim()
                .replaceAll(RegExp(r'[.;]+$'), ''),
      };
    } catch (_) {
      return const {};
    }
  }

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
