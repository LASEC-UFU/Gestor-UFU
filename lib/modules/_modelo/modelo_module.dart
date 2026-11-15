import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/modules/_modelo/application/modelo_commands.dart';
import 'package:gestor_ufu/modules/_modelo/application/modelo_service.dart';
import 'package:gestor_ufu/modules/_modelo/modelo_skill.dart';
import 'package:gestor_ufu/modules/_modelo/pages/modelo_page.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/platform/templates/sheet_template.dart';

/// Módulo-modelo (não instalado). Copie a pasta `_modelo`, troque nomes e
/// registre o módulo em `app/installed_modules.dart`.
/// Guia: docs/criando-um-modulo.md.
class ModeloModule extends GestorModule {
  ModeloModule();

  // Criado com o banco padrão e recriado em activate() com o banco da
  // plataforma: a rota e os comandos sempre leem o serviço atual.
  ModeloService _service = ModeloService(KeyValueStore());

  @override
  Future<void> activate(GestorServices services) async {
    _service = ModeloService(services.store);
  }

  @override
  Future<void> onExternalDataChanged() async => _service.recarregar();

  // ---------------------------------------------------------------- Painel
  @override
  String get id => 'modelo';

  @override
  String get title => 'Anotações';

  @override
  String get description => 'Exemplo mínimo de módulo do Gestor UFU.';

  @override
  IconData get icon => Icons.sticky_note_2_rounded;

  @override
  Color get accent => const Color(0xFF7CC4FF);

  @override
  String get category => 'EXEMPLOS';

  // ----------------------------------------------------------------- Rotas
  @override
  String get route => '/modelo';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => ModeloPage(service: _service),
    ),
  ];

  // ----------------------------------------------------------------- Agente
  @override
  ModuleSkill get skill => modeloSkill();

  @override
  List<ModuleCommand> get commands => modeloCommands(_service);

  @override
  List<ModuleTemplate> get templates => [
    ModuleTemplate(
      id: 'modelo_notas',
      description:
          'Anotações → planilha com uma nota por linha (coluna Texto).',
      build: ({rows, data, options = const {}}) => (
        'modelo_notas.xlsx',
        SheetTemplate.xlsx('Notas', [
          ['Texto'],
          ...?rows,
          if (rows == null) ['Primeira nota de exemplo'],
        ]),
        'Exemplo: a tela ou um comando importariam esta planilha.',
      ),
    ),
  ];
}
