import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Guia do módulo para o Agente de IA: para que serve, comandos, formatos.
ModuleSkill modeloSkill() => const ModuleSkill(
  title: 'Anotações (módulo-modelo)',
  summary: 'Exemplo mínimo de módulo do Gestor UFU.',
  body: '''
## Para que serve
Guarda notas curtas. Serve de exemplo para novos módulos.

## Comandos (run_command)
- `modelo.listar`: notas salvas.
- `modelo.adicionar` {texto}: cria uma nota.
- `modelo.remover` {id} (pede confirmação).

Códigos de erro: texto_vazio, nota_nao_encontrada.
''',
);
