import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';

/// Modelos de arquivo aceitos pelas importações do Gestor UFU. O agente usa a
/// ferramenta `create_template` para entregar ao usuário um arquivo no
/// formato exato que cada tela importa — com exemplos ou já com os dados que
/// ele montou a partir do que o usuário colou/anexou.
class AgentTemplates {
  /// Todos os modelos, declarados pelos módulos instalados.
  static Map<String, String> get all => {
    for (final module in ModuleRegistry.instance.modules)
      for (final t in module.templates) t.id: t.description,
  };

  static ModuleTemplate? _fromModules(String id) {
    for (final module in ModuleRegistry.instance.modules) {
      for (final t in module.templates) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  /// Gera o modelo [id] e devolve o caminho do arquivo criado.
  ///
  /// [rows]: linhas de dados (lista de listas) no lugar dos exemplos; para
  /// `diario_json` e `plano_ensino_json`, [data] substitui o conteúdo.
  static Future<Map<String, Object?>> create(
    String id, {
    List<List<Object?>>? rows,
    Object? data,
    String? folder,
    String? fileName,
    Map<String, dynamic> options = const {},
  }) async {
    final template = _fromModules(id);
    if (template == null) {
      throw StateError(
        'Modelo desconhecido "$id". Use um destes: ${all.keys.join(', ')}.',
      );
    }
    final (name, bytes, howTo) = template.build(
      rows: rows,
      data: data,
      options: options,
    );
    final dir = Directory(
      folder?.trim().isNotEmpty == true ? folder!.trim() : _defaultFolder(),
    );
    await dir.create(recursive: true);
    var target = p.join(
      dir.path,
      fileName?.trim().isNotEmpty == true ? fileName!.trim() : name,
    );
    if (p.extension(target).isEmpty) target += p.extension(name);
    await File(target).writeAsBytes(bytes);
    return {'ok': true, 'path': target, 'template': id, 'como_importar': howTo};
  }

  static String _defaultFolder() {
    final home =
        Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return p.join(home, 'Documents', 'GestorUFU Agente', 'modelos');
  }
}
