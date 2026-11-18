import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

/// WebView2 do módulo Parecer / Relato (editor do parecer e visualizador de
/// PDF): o ambiente é único por processo e precisa ser criado antes do
/// primeiro controlador.
class WebviewLocal {
  const WebviewLocal._();

  static Future<void>? _ambiente;
  static final Map<String, Future<void>> _copias = {};

  /// Cria (uma vez) o ambiente do WebView2 com o perfil do Gestor.
  static Future<void> ambiente() => _ambiente ??= _criarAmbiente();

  static Future<void> _criarAmbiente() async {
    final base =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    try {
      await WebviewController.initializeEnvironment(
        userDataPath: p.join(base, 'GestorUFU', 'ParecerEditor', 'perfil'),
      );
    } on PlatformException {
      // Já inicializado.
    }
  }

  /// Exige o WebView2 Runtime instalado.
  static Future<void> exigirRuntime() async {
    final versao = await WebviewController.getWebViewVersion();
    if (versao == null) {
      throw StateError(
        'O Microsoft Edge WebView2 Runtime não está instalado. Instale-o '
        '(go.microsoft.com/fwlink/p/?LinkId=2124703) e reabra o Gestor.',
      );
    }
  }

  /// Copia (uma vez por execução) os assets sob [prefixo] (ex.:
  /// "assets/pdf_viewer/") para [destino], mantendo as subpastas. Arquivos
  /// do mesmo tamanho não são regravados.
  static Future<void> copiarAssets(String prefixo, String destino) =>
      _copias['$prefixo|$destino'] ??= _copiar(prefixo, destino);

  static Future<void> _copiar(String prefixo, String destino) async {
    final manifesto = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final asset in manifesto.listAssets()) {
      if (!asset.startsWith(prefixo)) continue;
      final rel = asset.substring(prefixo.length);
      if (rel.isEmpty) continue;
      final alvo = File(p.joinAll([destino, ...rel.split('/')]));
      final data = await rootBundle.load(asset);
      if (await alvo.exists() && await alvo.length() == data.lengthInBytes) {
        continue;
      }
      await alvo.parent.create(recursive: true);
      await alvo.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
  }
}
