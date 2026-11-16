import 'dart:async';

import 'package:gestor_ufu/data/services/ai_agent/agent_backends.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_mcp_server.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';
import 'package:gestor_ufu/platform/contracts/ai_text.dart';

/// Implementação de [AiTextService] com o provedor configurado na janela do
/// Agente de IA. Cada pedido usa um back-end novo, sem ferramentas e sem
/// histórico (pedido avulso), descartado ao final.
class AgentTextService implements AiTextService {
  const AgentTextService();

  @override
  Future<String> descricao() async {
    final settings = await AgentSettings.load();
    final provider = settings.provider;
    final mode = settings.modeFor(provider);
    return '${provider.label} '
        '(${mode == AgentAuthMode.apiKey ? 'chave de API' : 'assinatura'})';
  }

  @override
  Future<String> gerar({
    required String sistema,
    required String prompt,
  }) async {
    final settings = await AgentSettings.load();
    final provider = settings.provider;
    final mode = settings.modeFor(provider);
    final model = settings.modelFor(provider, mode);
    Future<String> semFerramentas(String name, Map<String, dynamic> input) async =>
        'Ferramenta indisponível neste pedido.';

    AgentMcpServer? mcp;
    late AgentBackend backend;
    if (mode == AgentAuthMode.apiKey) {
      final key = await AgentSettings.readApiKey(provider);
      if (key == null) {
        throw AgentException(
          'Informe a chave de API do ${provider.label} na janela do Agente '
          'de IA.',
        );
      }
      backend = switch (provider) {
        AgentProvider.claude => ClaudeApiBackend(
          apiKey: key,
          model: model,
          callTool: semFerramentas,
        ),
        AgentProvider.chatgpt => OpenAiApiBackend(
          apiKey: key,
          model: model,
          callTool: semFerramentas,
        ),
        AgentProvider.gemini => GeminiApiBackend(
          apiKey: key,
          model: model,
          callTool: semFerramentas,
        ),
        AgentProvider.copilot => throw AgentException(
          'O GitHub Copilot funciona só com a assinatura (login GitHub).',
        ),
      };
    } else {
      mcp = AgentMcpServer(semFerramentas, toolFilter: const {});
      await mcp.start();
      final path = settings.cliPathFor(provider);
      backend = switch (provider) {
        AgentProvider.claude => ClaudeCliBackend(
          mcp: mcp,
          configuredPath: path,
          model: model,
        ),
        AgentProvider.chatgpt => CodexCliBackend(
          mcp: mcp,
          configuredPath: path,
          model: model,
        ),
        AgentProvider.gemini => GeminiCliBackend(
          mcp: mcp,
          configuredPath: path,
          model: model,
        ),
        AgentProvider.copilot => CopilotCliBackend(
          mcp: mcp,
          configuredPath: path,
          model: model,
        ),
      };
    }
    backend
      ..access = AgentAccess.gestor
      ..toolFilter = const {}
      ..systemPrompt = sistema;

    final blocos = <StringBuffer>[StringBuffer()];
    try {
      await backend.send(prompt, const [], (event) {
        switch (event) {
          case AgentTextEvent(:final text):
            blocos
              ..add(StringBuffer(text))
              ..add(StringBuffer());
          case AgentTextDeltaEvent(:final text):
            blocos.last.write(text);
          case AgentTextBreakEvent():
            if (blocos.last.isNotEmpty) blocos.add(StringBuffer());
          default:
            break;
        }
      });
    } finally {
      await backend.dispose();
      await mcp?.stop();
    }
    final textos = [
      for (final b in blocos)
        if (b.toString().trim().isNotEmpty) b.toString().trim(),
    ];
    if (textos.isEmpty) {
      throw AgentException('O agente não devolveu texto.');
    }
    return textos.join('\n\n');
  }
}
