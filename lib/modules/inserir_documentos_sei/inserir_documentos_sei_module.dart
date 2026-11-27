import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gestor_ufu/platform/module/gestor_module.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';
import 'package:gestor_ufu/platform/services/gestor_services.dart';
import 'package:gestor_ufu/platform/services/key_value_store.dart';
import 'package:gestor_ufu/platform/templates/sheet_template.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_service.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/application/web_process_commands.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/pages/web_process_page.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/web_process_skill.dart';

/// Mantém o ID e a chave do cartão anterior, agora com automações configuráveis.
class InserirDocumentosSeiModule extends GestorModule {
  InserirDocumentosSeiModule();
  WebProcessService _service = WebProcessService(KeyValueStore());

  @override
  Future<void> activate(GestorServices services) async {
    _service = WebProcessService(services.store);
    await _service.load();
  }

  @override
  Future<void> onExternalDataChanged() => _service.load();

  @override
  String get id => 'inserir-documentos-sei';

  @override
  String get title => 'Criar Ações na Web';

  @override
  String get description =>
      'Crie processos com ações em sites: componentes HTML, valores e sequência, pela interface ou pela IA.';

  @override
  IconData get icon => Icons.touch_app_rounded;

  @override
  Color get accent => const Color(0xFFFFB454);

  @override
  String get category => 'PROCESSOS E DOCUMENTOS';

  @override
  String get route => '/acoes-na-web';

  @override
  String get dashboardKey => 'module:Inserir Documentos no SEI';

  @override
  List<RouteBase> get routes => [
    GoRoute(
      path: route,
      builder: (context, state) => WebProcessPage(service: _service),
    ),
  ];

  @override
  ModuleSkill get skill => webProcessSkill;

  @override
  List<ModuleCommand> get commands => webProcessCommands(_service);

  @override
  List<ModuleTemplate> get templates => [
    ModuleTemplate(
      id: 'acoes_web_dados',
      description: 'Criar Ações na Web → Dados do lote → Importar JSON.',
      build: ({rows, data, options = const {}}) => (
        'dados.json',
        SheetTemplate.json(
          data ??
              [
                {
                  'nome_completo': 'Pessoa de exemplo',
                  'whatsapp': '34999990000',
                  'email': 'pessoa@example.com',
                  'pais': 'Brasil',
                  'cidade': 'Cidade de exemplo',
                  'estado': 'Estado de exemplo',
                  'endereco_completo': 'Endereço de exemplo',
                },
              ],
        ),
        'Importe este arquivo em Dados do lote. Os nomes dos campos são livres; use {{campo}} no valor da etapa.',
      ),
    ),
  ];
}
