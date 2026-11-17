import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';

/// Abre a janela da base de documentos de consulta.
Future<void> mostrarBaseDocumentos(
  BuildContext context,
  BaseDocumentosService base,
) => showDialog<void>(
  context: context,
  builder: (_) => _BaseDocumentosDialog(base: base),
);

class _BaseDocumentosDialog extends StatefulWidget {
  const _BaseDocumentosDialog({required this.base});

  final BaseDocumentosService base;

  @override
  State<_BaseDocumentosDialog> createState() => _BaseDocumentosDialogState();
}

class _BaseDocumentosDialogState extends State<_BaseDocumentosDialog> {
  String? _erro;

  BaseDocumentosService get base => widget.base;

  @override
  void initState() {
    super.initState();
    base.carregar();
  }

  Future<void> _executar(Future<void> Function() acao) async {
    setState(() => _erro = null);
    try {
      await acao();
    } catch (e) {
      if (mounted) {
        setState(() => _erro = e is StateError ? e.message : '$e');
      }
    }
  }

  Future<void> _escolherPasta() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Pasta com os documentos de consulta (normas, anexos)',
      initialDirectory: base.pasta.isEmpty ? null : base.pasta,
    );
    if (dir == null) return;
    await _executar(() => base.definirPasta(dir));
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return ListenableBuilder(
      listenable: base,
      builder: (context, _) {
        final b = base.base;
        final r = base.ultimoResumo;
        return AlertDialog(
          title: const Text('Base de documentos de consulta'),
          content: SizedBox(
            width: 680,
            height: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Todos os arquivos da pasta servem de fonte para a IA. O '
                  'Gestor extrai o texto de PDF (com camada de texto), DOCX, '
                  'TXT/MD e HTML e grava a base em '
                  '"${BaseDocumentosIndexer.nomeArquivo}" na própria pasta. '
                  'Os originais não são alterados; só arquivos novos ou '
                  'modificados são reprocessados.',
                  style: tema.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(
                        base.pasta.isEmpty
                            ? '(nenhuma pasta escolhida)'
                            : base.pasta,
                      ),
                    ),
                    TextButton(
                      onPressed: base.preparando ? null : _escolherPasta,
                      child: const Text('Escolher pasta…'),
                    ),
                  ],
                ),
                if (base.preparando) ...[
                  LinearProgressIndicator(
                    value: base.total == 0 ? null : base.progresso / base.total,
                  ),
                  Text(
                    '${base.progresso}/${base.total} ${base.etapa}',
                    style: tema.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (_erro != null || base.ultimoErro != null)
                  Text(
                    _erro ?? base.ultimoErro!,
                    style: TextStyle(color: tema.colorScheme.error),
                  ),
                if (r != null && !base.preparando)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Última atualização: ${r.descricao}.',
                      style: tema.textTheme.bodySmall,
                    ),
                  ),
                if (base.configurada)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(
                          base.vigiando
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 15,
                          color: tema.hintColor,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            base.vigiando
                                ? 'Pasta vigiada: a base se atualiza sozinha '
                                      'quando arquivos mudam'
                                      '${base.atualizadaAutomaticamente == null ? '' : ' (última vez às ${_data(base.atualizadaAutomaticamente!).split(' ').last})'}.'
                                : 'Esta pasta não pode ser vigiada; a base é '
                                      'conferida antes de cada consulta.',
                            style: tema.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                if (b != null)
                  Text(
                    '${b.documentos.length} arquivo(s), ${b.totalTrechos} '
                    'trechos · preparada em ${_data(b.geradoEm)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                const SizedBox(height: 4),
                Expanded(
                  child: b == null
                      ? const Center(child: Text('Base ainda não preparada.'))
                      : ListView(
                          children: [
                            for (final d in b.documentos) _documento(tema, d),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            if (b != null)
              TextButton(
                onPressed: base.preparando
                    ? null
                    : () => Process.start('explorer.exe', [base.pasta]),
                child: const Text('Abrir pasta'),
              ),
            TextButton(
              onPressed: base.preparando || !base.configurada
                  ? null
                  : () => _executar(() => base.preparar(forcar: true)),
              child: const Text('Reprocessar tudo'),
            ),
            FilledButton(
              onPressed: base.preparando || !base.configurada
                  ? null
                  : () => _executar(() => base.preparar()),
              child: const Text('Atualizar base'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar'),
            ),
          ],
        );
      },
    );
  }

  Widget _documento(ThemeData tema, DocumentoBase d) {
    final ok = d.status == StatusDocumento.ok;
    final detalhes = [
      if (d.norma.isNotEmpty) d.norma,
      if (ok) '${d.trechos.length} trechos',
      if (d.artigos.isNotEmpty) '${d.artigos.length} artigos',
      if (d.paginas > 0) '${d.paginas} p.',
      if (!ok) d.status.descricao,
      if (d.mensagem.isNotEmpty) d.mensagem,
    ].join(' · ');
    return ListTile(
      dense: true,
      leading: Icon(
        ok
            ? (d.paginasSemTexto.isEmpty
                  ? Icons.check_circle_outline
                  : Icons.error_outline)
            : Icons.block,
        color: ok
            ? (d.paginasSemTexto.isEmpty
                  ? Colors.green.shade700
                  : Colors.orange.shade800)
            : tema.colorScheme.error,
        size: 18,
      ),
      title: Text(d.arquivo),
      subtitle: Text(detalhes, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
  }

  static String _data(DateTime d) {
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)}/${d.year} ${dois(d.hour)}:${dois(d.minute)}';
  }
}
