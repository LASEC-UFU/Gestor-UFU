import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';

/// Arquivos do editor (CKEditor 5 + estilos do SEI) copiados dos assets para
/// uma pasta local servida ao WebView2 por um host virtual.
class _EditorArquivos {
  static const _nomes = [
    'editor.html',
    'editor.js',
    'sei_estilos.css',
    'ckeditor5.css',
    'ckeditor5.umd.js',
    'pt-br.umd.js',
  ];

  static Future<String>? _pasta;
  static bool _ambiente = false;

  static Future<String> pasta() => _pasta ??= _copiar();

  static Future<String> _copiar() async {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final dir = Directory(p.join(base, 'GestorUFU', 'ParecerEditor', 'app'));
    await dir.create(recursive: true);
    for (final nome in _nomes) {
      final data = await rootBundle.load('assets/parecer_editor/$nome');
      await File(p.join(dir.path, nome)).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return dir.path;
  }

  /// O ambiente do WebView2 é único por processo e precisa vir antes do
  /// primeiro controlador.
  static Future<void> ambiente() async {
    if (_ambiente) return;
    _ambiente = true;
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    try {
      await WebviewController.initializeEnvironment(
        userDataPath: p.join(base, 'GestorUFU', 'ParecerEditor', 'perfil'),
      );
    } on PlatformException {
      // Já inicializado por outra tela.
    }
  }
}

/// Editor HTML de uma seção do parecer, com os recursos de edição do SEI
/// (CKEditor 5 dentro de um WebView2). O conteúdo é gravado no
/// [ParecerService] a cada alteração.
class ParecerEditor extends StatefulWidget {
  const ParecerEditor({
    required this.secao,
    required this.service,
    this.dica = '',
    super.key,
  });

  final ParecerSecao secao;
  final ParecerService service;
  final String dica;

  @override
  State<ParecerEditor> createState() => _ParecerEditorState();
}

class _ParecerEditorState extends State<ParecerEditor>
    with AutomaticKeepAliveClientMixin {
  final _web = WebviewController();
  final _subs = <StreamSubscription<dynamic>>[];
  bool _iniciado = false;
  bool _controladorCriado = false;
  bool _pronto = false;
  String? _erro;
  double _zoom = 1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.service.arvore.addListener(_atualizarLinks);
    _iniciar();
  }

  int _qtdLinks = -1;

  void _atualizarLinks() {
    final links = widget.service.linksSei();
    if (!_pronto || links.length == _qtdLinks) return;
    _qtdLinks = links.length;
    _js('window.parecer.definirLinks(${jsonEncode(links)})');
  }

  Future<void> _iniciar() async {
    try {
      final versao = await WebviewController.getWebViewVersion();
      if (versao == null) {
        throw StateError(
          'O Microsoft Edge WebView2 Runtime não está instalado. Instale-o '
          '(go.microsoft.com/fwlink/p/?LinkId=2124703) e reabra o Gestor.',
        );
      }
      final pasta = await _EditorArquivos.pasta();
      await _EditorArquivos.ambiente();
      await _web.initialize();
      _controladorCriado = true;
      _subs.add(_web.webMessage.listen(_mensagem));
      _subs.add(
        widget.service.insercoes
            .where((i) => i.secao == widget.secao)
            .listen((i) => _js('window.parecer.inserir(${jsonEncode(i.html)})')),
      );
      _subs.add(
        widget.service.substituicoes
            .where((s) => s == widget.secao)
            .listen(
              (_) => _js(
                'window.parecer.definir(${jsonEncode(widget.service.parecer.secao(widget.secao))})',
              ),
            ),
      );
      await _web.setBackgroundColor(const Color(0xFFE9EAEE));
      await _web.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _web.addVirtualHostNameMapping(
        'parecer.gestor',
        pasta,
        WebviewHostResourceAccessKind.allow,
      );
      await _web.loadUrl('https://parecer.gestor/editor.html');
      if (mounted) setState(() => _iniciado = true);
    } catch (e) {
      if (mounted) setState(() => _erro = '$e');
    }
  }

  void _mensagem(dynamic msg) {
    if (msg is! Map) return;
    switch (msg['tipo']) {
      case 'carregado':
        final opcoes = {
          'html': widget.service.parecer.secao(widget.secao),
          'css': widget.service.estilosCss,
          'estilos': widget.service.estilos,
          'dica': widget.dica,
          'linksSei': widget.service.linksSei(),
        };
        _js('window.parecer.iniciar(${jsonEncode(opcoes)})');
      case 'pronto':
        if (mounted) setState(() => _pronto = true);
      case 'mudou':
        widget.service.definirSecaoDoEditor(widget.secao, '${msg['html'] ?? ''}');
      case 'erro':
        if (mounted) setState(() => _erro = '${msg['mensagem']}');
    }
  }

  Future<void> _js(String script) async {
    try {
      await _web.executeScript(script);
    } catch (_) {}
  }

  Future<void> _definirZoom(double z) async {
    setState(() => _zoom = z);
    await _web.setZoomFactor(z);
  }

  /// Recarrega o editor (ex.: depois de capturar os estilos do SEI).
  Future<void> recarregar() async {
    setState(() => _pronto = false);
    await _web.reload();
  }

  @override
  void dispose() {
    widget.service.arvore.removeListener(_atualizarLinks);
    for (final s in _subs) {
      s.cancel();
    }
    // Garante que o último trecho digitado (antes do debounce) seja salvo.
    unawaited(widget.service.salvarAgora());
    if (_controladorCriado) _web.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_erro != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppTheme.danger),
              const SizedBox(height: 10),
              Text(
                _erro!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  setState(() => _erro = null);
                  recarregar();
                },
                child: const Text('Tentar de novo'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                if (_iniciado) Positioned.fill(child: Webview(_web)),
                if (!_pronto)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0xFFE9EAEE),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(Icons.zoom_in_rounded, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              DropdownButton<double>(
                value: _zoom,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [0.75, 0.9, 1.0, 1.1, 1.25, 1.5]
                    .map(
                      (z) => DropdownMenuItem(
                        value: z,
                        child: Text('${(z * 100).round()}%'),
                      ),
                    )
                    .toList(),
                onChanged: (z) => z == null ? null : _definirZoom(z),
              ),
              const Spacer(),
              Text(
                'Salvo automaticamente no Gestor',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
