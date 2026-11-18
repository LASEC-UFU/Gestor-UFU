import 'package:gestor_ufu/modules/ajusta_horarios/ajusta_horarios_module.dart';
import 'package:gestor_ufu/modules/audita_banco/audita_banco_module.dart';
import 'package:gestor_ufu/modules/integracoes_pessoais/integracoes_pessoais_module.dart';
import 'package:gestor_ufu/modules/diario/diario_module.dart';
import 'package:gestor_ufu/modules/equivalencia/equivalencia_module.dart';
import 'package:gestor_ufu/modules/inserir_documentos_sei/inserir_documentos_sei_module.dart';
import 'package:gestor_ufu/modules/moodle/moodle_module.dart';
import 'package:gestor_ufu/modules/planos_ensino/planos_ensino_module.dart';
import 'package:gestor_ufu/modules/planos_trabalho/planos_trabalho_module.dart';
import 'package:gestor_ufu/modules/progressao/progressao_module.dart';
import 'package:gestor_ufu/modules/elabora_relato/elabora_relato_module.dart';
import 'package:gestor_ufu/platform/module/module_registry.dart';

/// Módulos instalados no Gestor UFU — a única lista que conhece todos.
/// Para criar um módulo novo: implemente `GestorModule` em
/// `lib/modules/<id>/` e adicione uma linha aqui (veja
/// docs/criando-um-modulo.md). A ordem é a padrão do painel.
void installModules([ModuleRegistry? target]) {
  final registry = target ?? ModuleRegistry.instance;
  if (registry.modules.isNotEmpty) return;
  registry
    ..register(AuditaBancoModule())
    ..register(const IntegracoesPessoaisModule())
    ..register(MoodleModule())
    ..register(DiarioModule())
    ..register(ElaboraRelatoModule())
    ..register(PlanosEnsinoModule())
    ..register(PlanosTrabalhoModule())
    ..register(AjustaHorariosModule())
    ..register(EquivalenciaModule())
    ..register(ProgressaoModule())
    ..register(const InserirDocumentosSeiModule());
}
