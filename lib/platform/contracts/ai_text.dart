/// Ponte simples com o Agente de IA para os módulos: pede um texto ao
/// provedor configurado na janela do agente (mesma conta, modelo e modo —
/// assinatura/CLI ou chave de API), sem abrir a janela e sem ferramentas.
///
/// Registrada na composição (`main.dart`); quem usa trata a ausência
/// (dependência opcional), como os demais contratos.
abstract interface class AiTextService {
  /// Nome do provedor/modo em uso (ex.: "Claude (assinatura)").
  Future<String> descricao();

  /// Envia [prompt] com as instruções [sistema] e devolve o texto da
  /// resposta. Lança exceção com mensagem legível se o agente não estiver
  /// configurado ou falhar.
  Future<String> gerar({required String sistema, required String prompt});
}
