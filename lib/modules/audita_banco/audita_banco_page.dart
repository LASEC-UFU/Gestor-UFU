import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_files.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/pages/anexos_view.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';
import 'package:gestor_ufu/modules/audita_banco/audita_pdf_exporter.dart';

/// Academic review workspace reuses Parecer/Relato's real PDF text selection,
/// quote anchors, comment editor and annotation storage.
class AuditaBancoPage extends StatefulWidget {
  const AuditaBancoPage({required this.ai, required this.service, super.key});
  final AiTextService? ai;
  final ParecerService? service;
  @override
  State<AuditaBancoPage> createState() => _AuditaBancoPageState();
}

class _AuditaBancoPageState extends State<AuditaBancoPage> {
  final _criteria = TextEditingController();
  final _findings = <_Finding>[];
  AnexoProcesso? _document;
  String? _error;
  bool _busy = false;
  String _progress = '';
  @override
  void dispose() {
    _criteria.dispose();
    for (final f in _findings) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (result == null || result.files.single.path == null) return;
    final service = widget.service;
    if (service == null) {
      setState(() => _error = 'Serviço de documentos não está disponível.');
      return;
    }
    setState(() {
      for (final finding in _findings) {
        finding.dispose();
      }
      _findings.clear();
      _document = null;
      _busy = true;
      _error = null;
    });
    try {
      final file = await service.anexos.anexar(result.files.single.path!);
      if (mounted) setState(() => _document = file);
      if (file.aviso.isNotEmpty && mounted) setState(() => _error = file.aviso);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _analyze() async {
    final doc = _document, service = widget.service, ai = widget.ai;
    if (doc == null || service == null) return;
    if (ai == null) {
      setState(() => _error = 'Agente de IA não está configurado.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Lendo documento…';
    });
    try {
      final pars = await service.anexos.paragrafos(doc);
      if (pars.every((p) => p.texto.trim().isEmpty))
        throw StateError(
          'O PDF não tem camada de texto pesquisável. OCR não está disponível.',
        );
      final pages = await AgentFiles.pdfPages(
        await service.anexos.caminho(doc),
      );
      final chunks = _chunks(pars);
      final created = <_Finding>[];
      var notAnchored = 0;
      var totalFindings = 0;
      for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
        if (mounted)
          setState(
            () => _progress =
                'Analisando bloco ${chunkIndex + 1} de ${chunks.length}…',
          );
        final chunk = chunks[chunkIndex];
        final answer = await ai.gerar(
          sistema:
              'Você é um revisor acadêmico didático de TCCs, dissertações e teses. Use somente os critérios recebidos; não invente normas. Retorne SOMENTE um JSON array com até 8 objetos. Cada objeto deve ter: trecho (citação literal curta, até 220 caracteres), categoria (Editorial, Metodológica ou Norma a confirmar), problema, importancia, melhoria. O trecho precisa existir literalmente no documento para ancoragem. Se não encontrar problemas justificáveis, retorne [].',
          prompt:
              'Critérios/rubrica/normas fornecidos pelo usuário:\n${_criteria.text.trim().isEmpty ? '(nenhum; limite-se a recomendações editoriais gerais)' : _criteria.text.trim()}\n\nParte ${chunkIndex + 1}/${chunks.length} do documento:\n${chunk.map((p) => '[p. ${p.pagina}] ${p.texto}').join('\n')}',
        );
        final decoded = _decode(answer);
        totalFindings += decoded.length;
        if (totalFindings > 400)
          throw StateError(
            'Limite de segurança de 400 observações atingido; refine os critérios para reduzir os resultados.',
          );
        final previousMarkers = service.anexos.exigir(doc.id).marcacoes;
        for (final item in decoded) {
          final quote = '${item['trecho'] ?? ''}'.trim();
          if (quote.isEmpty) continue;
          MarcacaoAnexo? marker;
          for (var i = 0; i < pages.length; i++) {
            final range = localizarTrecho(quote, pages[i]);
            if (range != null) {
              marker = AnexosProcessoService.novaMarcacaoPdf(
                pagina: i + 1,
                textoPagina: pages[i],
                inicio: range.inicio,
                fim: range.fim,
                pars: pars,
              );
              break;
            }
          }
          marker ??= AnexosProcessoService.ancorarNoTexto(
            AnexosProcessoService.novaMarcacao(
              paragrafo: 0,
              textoParagrafo: quote,
              inicio: 0,
              fim: quote.length,
              comentario: '',
            ),
            pars,
          );
          if (marker.pdfPagina == 0 && marker.paragrafo < 0) notAnchored++;
          final old = previousMarkers
              .where(
                (m) =>
                    m.pergunta == 'audita_banco' &&
                    m.texto.toLowerCase() == marker!.texto.toLowerCase() &&
                    m.pdfPagina == marker.pdfPagina,
              )
              .firstOrNull;
          if (old != null) marker = old;
          final comment =
              '${item['categoria'] ?? 'Editorial'}\nProblema: ${item['problema'] ?? ''}\nPor que importa: ${item['importancia'] ?? ''}\nSugestão: ${item['melhoria'] ?? ''}';
          marker = marker.copyWith(
            comentario: comment,
            explicacaoIa: comment,
            pergunta: 'audita_banco',
            revisao: 'pendente',
          );
          await service.anexos.salvarMarcacao(doc.id, marker);
          final oldView = [
            ..._findings,
            ...created,
          ].where((f) => f.marker.id == marker!.id).firstOrNull;
          if (oldView != null) {
            oldView.marker = marker;
            oldView.controller.text = comment;
          } else {
            created.add(_Finding(marker, TextEditingController(text: comment)));
          }
        }
      }
      if (mounted) setState(() => _findings.addAll(created));
      if (notAnchored > 0 && mounted)
        setState(
          () => _error =
              '$notAnchored observação(ões) não puderam ser ancoradas ao trecho; reveja na lista de marcações.',
        );
      if (totalFindings == 0 && mounted)
        setState(
          () => _error =
              'A análise não encontrou observações que atendam aos critérios informados.',
        );
    } catch (e) {
      if (mounted) setState(() => _error = 'Falha na análise: $e');
    }
    if (mounted) setState(() => _busy = false);
    if (mounted) setState(() => _progress = '');
  }

  List<List<ParagrafoFonte>> _chunks(List<ParagrafoFonte> paragraphs) {
    const limit = 9000;
    final output = <List<ParagrafoFonte>>[];
    var current = <ParagrafoFonte>[];
    var length = 0;
    for (final paragraph in paragraphs) {
      if (current.isNotEmpty && length + paragraph.texto.length > limit) {
        output.add(current);
        current = [];
        length = 0;
      }
      current.add(paragraph);
      length += paragraph.texto.length;
    }
    if (current.isNotEmpty) output.add(current);
    return output;
  }

  List<Map<String, dynamic>> _decode(String text) {
    var normalized = text
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '');
    final start = normalized.indexOf('['), end = normalized.lastIndexOf(']');
    if (start < 0 || end < start)
      throw const FormatException(
        'A resposta do modelo não veio no formato JSON esperado.',
      );
    final value = jsonDecode(normalized.substring(start, end + 1));
    if (value is! List)
      throw const FormatException(
        'A resposta da análise não é uma lista de observações.',
      );
    return [
      for (final x in value)
        if (x is Map) Map<String, dynamic>.from(x),
    ];
  }

  Future<void> _saveFinding(_Finding f) async {
    final doc = _document, service = widget.service;
    if (doc == null || service == null) return;
    final updated = f.marker.copyWith(
      comentario: f.controller.text.trim(),
      explicacaoIa: f.controller.text.trim(),
    );
    await service.anexos.salvarMarcacao(doc.id, updated);
    f.marker = updated;
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Comentário salvo.')));
  }

  Future<void> _status(_Finding f, String status) async {
    final doc = _document, service = widget.service;
    if (doc == null || service == null) return;
    final updated = f.marker.copyWith(
      revisao: status,
      comentario: f.controller.text.trim(),
    );
    await service.anexos.salvarMarcacao(doc.id, updated);
    if (mounted) setState(() => f.marker = updated);
  }

  Future<void> _remove(_Finding f) async {
    final doc = _document, service = widget.service;
    if (doc == null || service == null) return;
    await service.anexos.excluirMarcacao(doc.id, f.marker.id);
    if (mounted) setState(() => _findings.remove(f));
    f.dispose();
  }

  Future<void> _exportReport() async {
    final doc = _document, service = widget.service;
    if (doc == null || service == null) return;
    final destination = await _availablePath(
      '${doc.origem.substring(0, doc.origem.length - 4)}_audita_banco.txt',
    );
    final rows = service.anexos
        .exigir(doc.id)
        .marcacoes
        .where((m) => m.pergunta == 'audita_banco')
        .map(
          (m) =>
              '${m.revisao.toUpperCase()} • página ${m.pdfPagina}\nTrecho: ${m.texto}\n${m.comentario}',
        )
        .join('\n\n');
    await File(
      destination,
    ).writeAsString('Audita Banco — ${doc.nome}\n\n$rows');
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Relatório salvo em $destination. O PDF original foi preservado.',
          ),
        ),
      );
  }

  Future<void> _exportAnnotatedPdf() async {
    final doc = _document, service = widget.service;
    if (doc == null || service == null) return;
    final accepted = service.anexos
        .exigir(doc.id)
        .marcacoes
        .where((m) => m.pergunta == 'audita_banco' && m.revisao == 'aceito')
        .toList();
    if (accepted.isEmpty) {
      setState(
        () => _error =
            'Aceite pelo menos uma observação antes de exportar o PDF revisado.',
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exportar PDF anotado'),
        content: Text(
          '${accepted.length} comentário(s) aceito(s) serão destacados nas páginas e descritos em páginas de notas. O PDF original não será alterado. O arquivo anotado será rasterizado e não manterá seleção de texto.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exportar'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final output = await _availablePath(
      '${doc.origem.substring(0, doc.origem.length - 4)}_audita_banco.pdf',
    );
    setState(() {
      _busy = true;
      _progress = '';
      _error = null;
    });
    try {
      await AuditaPdfExporter.export(
        source: await service.anexos.caminho(doc),
        comments: accepted,
        target: output,
        onProgress: (s) {
          if (mounted) setState(() => _progress = s);
        },
      );
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('PDF anotado salvo em $output')));
    } catch (e) {
      if (mounted)
        setState(() => _error = 'Não foi possível exportar o PDF: $e');
    }
    if (mounted)
      setState(() {
        _busy = false;
        _progress = '';
      });
  }

  Future<String> _availablePath(String path) async {
    if (!await File(path).exists()) return path;
    final dot = path.lastIndexOf('.');
    final stem = dot > 0 ? path.substring(0, dot) : path;
    final extension = dot > 0 ? path.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final candidate = '$stem ($i)$extension';
      if (!await File(candidate).exists()) return candidate;
    }
    throw StateError('Não foi possível escolher um nome de saída disponível.');
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Audita Banco',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Text(
                'Revisão assistida de TCCs, dissertações e teses. O texto selecionado será enviado ao modelo de IA configurado quando você iniciar a análise.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Selecionar PDF'),
                  ),
                  Text(
                    _document?.nome ?? 'Nenhum PDF selecionado',
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_document != null)
                    TextButton.icon(
                      onPressed: _exportReport,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Exportar relatório'),
                    ),
                  if (_document != null)
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _exportAnnotatedPdf,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Exportar PDF anotado'),
                    ),
                ],
              ),
              if (_document != null)
                TextField(
                  controller: _criteria,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Critérios, rubrica ou normas (opcional)',
                    hintText:
                        'Cole orientações da banca ou critérios específicos',
                    border: OutlineInputBorder(),
                  ),
                ),
              if (_document != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _analyze,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.manage_search),
                      label: Text(_busy ? 'Analisando…' : 'Analisar documento'),
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_busy)
          Column(
            children: [
              const LinearProgressIndicator(),
              if (_progress.isNotEmpty) Text(_progress),
            ],
          ),
        if (service != null && _document != null)
          Expanded(
            child: AnexosView(
              key: ValueKey('audita-${_document!.id}'),
              service: service,
            ),
          )
        else
          const Expanded(
            child: Center(child: Text('Selecione um PDF para começar.')),
          ),
        if (_findings.isNotEmpty)
          SizedBox(
            height: 230,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final f in _findings)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'p. ${f.marker.pdfPagina} • ${f.marker.revisao} • “${f.marker.texto}”',
                          ),
                          TextField(
                            controller: f.controller,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: 'Problema, importância e melhoria',
                            ),
                          ),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () => _saveFinding(f),
                                child: const Text('Salvar'),
                              ),
                              TextButton(
                                onPressed: () => _status(f, 'aceito'),
                                child: const Text('Aceitar'),
                              ),
                              TextButton(
                                onPressed: () => _status(f, 'rejeitado'),
                                child: const Text('Rejeitar'),
                              ),
                              IconButton(
                                onPressed: () => _remove(f),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Finding {
  _Finding(this.marker, this.controller);
  MarcacaoAnexo marker;
  final TextEditingController controller;
  void dispose() => controller.dispose();
}
