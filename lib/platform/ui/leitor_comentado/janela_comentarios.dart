import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gestor_ufu/core/theme/app_theme.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/comentario_documento.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado.dart';
import 'package:gestor_ufu/platform/ui/leitor_comentado/leitor_comentado_controller.dart';

/// A própria superfície de comentários do editor em uma janela nativa.
/// Não há lista alternativa: busca, cartões expansíveis e navegação usam
/// [LeitorComentado], igual ao painel acoplado.
class JanelaComentariosApp extends StatefulWidget {
  const JanelaComentariosApp({
    required this.channelName,
    required this.comentarios,
    required this.selecionado,
    required this.isLight,
    super.key,
  });

  final String channelName;
  final List<Map<String, dynamic>> comentarios;
  final String? selecionado;
  final bool isLight;

  @override
  State<JanelaComentariosApp> createState() => _JanelaComentariosAppState();
}

class _JanelaComentariosAppState extends State<JanelaComentariosApp> {
  late final WindowMethodChannel _canal;
  final _leitor = LeitorComentadoController();
  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _canal = WindowMethodChannel(
      widget.channelName,
      mode: ChannelMode.bidirectional,
    );
    _leitor
      ..navegar = _navegar
      ..definirComentarios(_converter(widget.comentarios));
    unawaited(_canal.setMethodCallHandler(_receber));
    if (widget.selecionado != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _sincronizarSelecao(widget.selecionado),
      );
    }
  }

  List<ComentarioDocumento> _converter(List<Map<String, dynamic>> dados) => [
    for (final d in dados)
      ComentarioDocumento(
        id: '${d['id']}',
        titulo: '${d['titulo'] ?? ''}',
        cor: Color((d['cor'] as num?)?.toInt() ?? 0xFFD18A00),
        local: '${d['local'] ?? ''}',
        ancorado: d['ancorado'] != false,
        trechoMarcado: '${d['trechoMarcado'] ?? ''}',
        etiquetas: (d['etiquetas'] as List? ?? const [])
            .map((x) => '$x')
            .toList(),
        secoes: [
          for (final item in (d['secoes'] as List? ?? const []))
            if (item is Map)
              SecaoComentario(
                '${item['rotulo'] ?? ''}',
                '${item['texto'] ?? ''}',
              ),
        ],
      ),
  ];

  Future<bool> _navegar(ComentarioDocumento comentario, bool _) async {
    if (_sincronizando) return true;
    return await _canal.invokeMethod<bool>('selecionar', comentario.id) ??
        false;
  }

  Future<dynamic> _receber(MethodCall call) async {
    if (call.method == 'atualizar') {
      final dados = Map<String, dynamic>.from(call.arguments as Map);
      _leitor.definirComentarios(
        _converter(
          (dados['comentarios'] as List)
              .map((x) => Map<String, dynamic>.from(x as Map))
              .toList(),
        ),
      );
      await _sincronizarSelecao(dados['selecionado'] as String?);
      return true;
    }
    throw MissingPluginException('Método não reconhecido: ${call.method}');
  }

  Future<void> _sincronizarSelecao(String? id) async {
    if (id == _leitor.selecionado) return;
    _sincronizando = true;
    try {
      if (id == null) {
        _leitor.limparSelecao();
      } else {
        await _leitor.selecionar(id, rolar: false);
      }
    } finally {
      _sincronizando = false;
    }
  }

  Future<void> _selecionou(String? _) async {
    if (_sincronizando || _leitor.selecionado == null) return;
    await _canal.invokeMethod<bool>('selecionar', _leitor.selecionado);
  }

  Future<void> _acao(String acao) =>
      _canal.invokeMethod<bool>('acaoPainel', acao);

  Future<void> _acoplar() async {
    try {
      await _canal.invokeMethod<bool>('acoplar');
    } finally {
      await (await WindowController.fromCurrentEngine()).hide();
    }
  }

  @override
  void dispose() {
    unawaited(_canal.setMethodCallHandler(null));
    _leitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: widget.isLight ? ThemeMode.light : ThemeMode.dark,
    home: Scaffold(
      body: SafeArea(
        child: LeitorComentado(
          somentePainel: true,
          controller: _leitor,
          comentarios: _leitor.todos,
          documento: const SizedBox.shrink(),
          onSelectionChanged: _selecionou,
          acoesPainel: [
            IconButton(
              tooltip: 'Acoplar ao editor',
              onPressed: _acoplar,
              icon: const Icon(Icons.vertical_align_center_rounded),
            ),
            IconButton(
              tooltip: 'Consultar a IA sobre a seleção ou o cursor',
              onPressed: () => _acao('consultarIa'),
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            PopupMenuButton<String>(
              tooltip: 'Mais ações',
              icon: const Icon(Icons.more_vert),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'comentar',
                  child: Text('Comentar a seleção'),
                ),
                PopupMenuItem(
                  value: 'analisar',
                  child: Text('Analisar a seção com a base'),
                ),
                PopupMenuItem(
                  value: 'base',
                  child: Text('Base de documentos…'),
                ),
              ],
              onSelected: _acao,
            ),
          ],
        ),
      ),
    ),
  );
}
