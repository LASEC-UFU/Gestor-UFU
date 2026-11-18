import 'dart:convert';

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';

/// Trecho do parecer sobre o qual o usuário consulta a IA: o texto
/// selecionado (vazio quando há só o cursor) e o contexto em volta.
class TrechoConsultado {
  const TrechoConsultado({
    required this.secao,
    required this.texto,
    this.anterior = '',
    this.posterior = '',
  });

  final String secao;
  final String texto;
  final String anterior;
  final String posterior;

  bool get soCursor => texto.trim().isEmpty;
}

/// Avaliação da IA sobre o trecho/alteração consultados.
enum Avaliacao {
  fundamentado('Há fundamento nas fontes'),
  contradiz('As fontes contradizem'),
  parcial('Fundamento parcial'),
  semInformacao('Informação insuficiente nas fontes'),
  indefinido('Resposta não estruturada');

  const Avaliacao(this.rotulo);
  final String rotulo;

  static Avaliacao de(String s) => switch (TextoBusca.semAcentos(s.trim())) {
    'fundamentado' || 'apoia' || 'plausivel' => fundamentado,
    'contradiz' || 'contradicao' || 'contraditorio' => contradiz,
    'parcial' => parcial,
    'sem_informacao' || 'insuficiente' || 'nao_encontrado' => semInformacao,
    _ => indefinido,
  };
}

/// Evidência citada pela IA, conferida contra a fonte entregue.
class Evidencia {
  const Evidencia({
    required this.fonte,
    required this.citacao,
    required this.citacaoConfirmada,
    this.relacao = '',
    this.comentario = '',
  });

  final FonteConsulta fonte;

  /// Citação devolvida pela IA (exibida só se [citacaoConfirmada]).
  final String citacao;

  /// A citação existe literalmente no texto da fonte.
  final bool citacaoConfirmada;
  final String relacao;
  final String comentario;
}

class RespostaConsulta {
  const RespostaConsulta({
    required this.avaliacao,
    required this.resposta,
    this.evidencias = const [],
    this.descartadas = 0,
  });

  final Avaliacao avaliacao;
  final String resposta;
  final List<Evidencia> evidencias;

  /// Referências da IA a fontes que não foram entregues (ignoradas).
  final int descartadas;
}

class PropostaTexto {
  const PropostaTexto({
    required this.texto,
    this.justificativa = '',
    this.alertas = const [],
    this.fontes = const [],
  });

  final String texto;
  final String justificativa;
  final List<String> alertas;
  final List<FonteConsulta> fontes;
}

/// Prompts e leitura das respostas da IA para a consulta sobre um trecho.
/// A IA só recebe as fontes numeradas ([FonteConsulta.id]); referências a
/// outras fontes são descartadas e citações não encontradas literalmente
/// na fonte são marcadas como não confirmadas.
class ConsultaTrecho {
  const ConsultaTrecho._();

  static const _limiteFontes = 26000;

  static String fontesTexto(List<FonteConsulta> fontes) {
    if (fontes.isEmpty) return '(nenhuma fonte encontrada na base)';
    final b = StringBuffer();
    var total = 0;
    for (final f in fontes) {
      var texto = f.texto;
      if (total + texto.length > _limiteFontes) {
        final resta = _limiteFontes - total;
        if (resta < 300) break;
        texto = '${texto.substring(0, resta)}…';
      }
      total += texto.length;
      b
        ..writeln('[${f.id}] ${f.referencia}')
        ..writeln(texto)
        ..writeln();
    }
    return b.toString();
  }

  static String _trecho(TrechoConsultado t) => t.soCursor
      ? 'O usuário posicionou o cursor (sem seleção) no ponto marcado '
            'com [CURSOR]:\n…${_fim(t.anterior)}[CURSOR]${_ini(t.posterior)}…'
      : 'TRECHO SELECIONADO:\n«${t.texto}»\nContexto: '
            '…${_fim(t.anterior)}«TRECHO»${_ini(t.posterior)}…';

  static String _fim(String s) =>
      s.length <= 300 ? s : s.substring(s.length - 300);
  static String _ini(String s) => s.length <= 300 ? s : s.substring(0, 300);

  static const sistemaPergunta = '''
Você apoia o relator de um conselho da Universidade Federal de Uberlândia
na análise de pareceres. Responda em português, de forma objetiva.
Regras obrigatórias:
- Baseie-se SOMENTE nas fontes numeradas [F1], [F2]… fornecidas. Não use
  conhecimento externo para afirmar o que uma norma diz.
- Nunca invente documentos, números de normas, artigos ou citações.
- "citacao" deve ser copiada LITERALMENTE do texto da fonte indicada.
- Diga se as fontes dão fundamento à afirmação/alteração, se a
  contradizem, se apoiam só em parte ou se não trazem informação
  suficiente. Se não houver base, diga isso claramente.
- Diferencie regra geral (norma) de fato do processo.
Responda SOMENTE com JSON:
{"avaliacao": "fundamentado|contradiz|parcial|sem_informacao",
 "resposta": "explicação curta para o relator",
 "evidencias": [{"fonte": "F1", "citacao": "texto literal",
   "relacao": "apoia|contradiz|contexto", "comentario": "por que importa"}]}''';

  static String promptPergunta(
    TrechoConsultado t,
    String pergunta,
    List<FonteConsulta> fontes,
  ) =>
      'SEÇÃO DO PARECER: ${t.secao}\n${_trecho(t)}\n\n'
      'PERGUNTA DO RELATOR: ${pergunta.trim().isEmpty ? 'O trecho está correto e fundamentado?' : pergunta.trim()}\n\n'
      'FONTES:\n${fontesTexto(fontes)}';

  static const sistemaProposta = '''
Você ajuda o relator de um conselho da Universidade Federal de Uberlândia a
redigir pareceres, em português formal e claro, no estilo de pareceres
administrativos.
Regras obrigatórias:
- Siga a instrução do relator. Preserve fatos, números, datas, nomes,
  documentos e referências do texto original, salvo se a instrução pedir
  explicitamente outra coisa.
- Não acrescente fundamentos, normas ou artigos que não estejam no texto
  original ou nas fontes numeradas fornecidas.
- Se a instrução pedir algo que as fontes contradizem ou que não tem
  base, faça a proposta mesmo assim só se for redação, e registre o
  problema em "alertas".
- "texto" é somente o texto que entrará no parecer (sem aspas, sem
  comentários). Parágrafos separados por linha em branco.
Responda SOMENTE com JSON:
{"texto": "...", "justificativa": "o que mudou e por quê",
 "fontes": ["F1"], "alertas": ["..."]}''';

  static String promptProposta(
    TrechoConsultado t,
    String instrucao,
    List<FonteConsulta> fontes,
  ) {
    final alvo = t.soCursor
        ? 'Escreva o texto a ser INSERIDO no ponto [CURSOR], encaixado no '
              'contexto.'
        : 'Reescreva o TRECHO SELECIONADO; a proposta substituirá apenas '
              'esse trecho, então mantenha a continuidade com o contexto.';
    return 'SEÇÃO DO PARECER: ${t.secao}\n${_trecho(t)}\n\n$alvo\n'
        'INSTRUÇÃO DO RELATOR: ${instrucao.trim().isEmpty ? 'Aprimore a redação.' : instrucao.trim()}\n\n'
        'FONTES:\n${fontesTexto(fontes)}';
  }

  /// Primeiro objeto JSON da resposta (tolera ```json e texto em volta).
  static Map<String, dynamic>? _json(String raw) {
    final a = raw.indexOf('{');
    final b = raw.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final v = jsonDecode(raw.substring(a, b + 1));
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }

  static bool citacaoNaFonte(String citacao, String fonte) {
    final c = TextoBusca.comparavel(
      citacao,
    ).replaceAll(RegExp(r'^["\s.…]+|["\s.…]+$'), '');
    if (c.length < 8) return false;
    return TextoBusca.comparavel(fonte).contains(c);
  }

  static RespostaConsulta lerPergunta(String raw, List<FonteConsulta> fontes) {
    final json = _json(raw);
    if (json == null) {
      return RespostaConsulta(
        avaliacao: Avaliacao.indefinido,
        resposta: raw.trim(),
      );
    }
    final porId = {for (final f in fontes) f.id.toUpperCase(): f};
    final evidencias = <Evidencia>[];
    var descartadas = 0;
    for (final e in (json['evidencias'] as List? ?? const [])) {
      if (e is! Map) continue;
      final id = '${e['fonte'] ?? ''}'
          .replaceAll(RegExp(r'[\[\]\s]'), '')
          .toUpperCase();
      final fonte = porId[id];
      if (fonte == null) {
        descartadas++;
        continue;
      }
      final citacao = '${e['citacao'] ?? ''}'.trim();
      evidencias.add(
        Evidencia(
          fonte: fonte,
          citacao: citacao,
          citacaoConfirmada: citacaoNaFonte(citacao, fonte.texto),
          relacao: '${e['relacao'] ?? ''}'.trim(),
          comentario: '${e['comentario'] ?? ''}'.trim(),
        ),
      );
    }
    var avaliacao = Avaliacao.de('${json['avaliacao'] ?? ''}');
    // Sem nenhuma evidência válida, não há fundamento demonstrado.
    if (evidencias.isEmpty &&
        (avaliacao == Avaliacao.fundamentado ||
            avaliacao == Avaliacao.contradiz ||
            avaliacao == Avaliacao.parcial)) {
      avaliacao = Avaliacao.semInformacao;
    }
    return RespostaConsulta(
      avaliacao: avaliacao,
      resposta: '${json['resposta'] ?? ''}'.trim(),
      evidencias: evidencias,
      descartadas: descartadas,
    );
  }

  static PropostaTexto? lerProposta(String raw, List<FonteConsulta> fontes) {
    final json = _json(raw);
    if (json == null) {
      final texto = raw.trim();
      return texto.isEmpty ? null : PropostaTexto(texto: texto);
    }
    final texto = '${json['texto'] ?? ''}'.trim();
    if (texto.isEmpty) return null;
    final porId = {for (final f in fontes) f.id.toUpperCase(): f};
    return PropostaTexto(
      texto: texto,
      justificativa: '${json['justificativa'] ?? ''}'.trim(),
      alertas: [
        for (final a in (json['alertas'] as List? ?? const []))
          if ('$a'.trim().isNotEmpty) '$a'.trim(),
      ],
      fontes: [
        for (final id in (json['fontes'] as List? ?? const []))
          ?porId['$id'.replaceAll(RegExp(r'[\[\]\s]'), '').toUpperCase()],
      ],
    );
  }

  // ------------------------------------------- documentos anexados (leitura)

  static const sistemaExplicacao = '''
Você ajuda o relator de um conselho da Universidade Federal de Uberlândia a
ENTENDER documentos de um processo (ofícios, pareceres, PPCs, atas,
normas). Responda em português claro, para quem não é especialista.
Regras obrigatórias:
- Explique o que o TRECHO diz, usando o contexto do mesmo documento.
- Não invente fatos, datas, números nem normas. Se o trecho não permitir
  concluir algo, diga isso.
- Normas e documentos externos só podem ser citados se estiverem nas
  fontes numeradas [F1]… fornecidas; "citacao" deve ser copiada
  literalmente da fonte.
- "comentario" é uma anotação objetiva para o relator guardar junto ao
  trecho: o que o trecho diz, por que importa para o parecer e o que
  conferir (até 120 palavras).
Responda SOMENTE com JSON:
{"resposta": "explicação em linguagem simples (responde à pergunta)",
 "pontos_atencao": ["..."],
 "termos": [{"termo": "...", "significado": "..."}],
 "evidencias": [{"fonte": "F1", "citacao": "...",
   "relacao": "apoia|contradiz|contexto", "comentario": "..."}],
 "comentario": "..."}''';

  static String promptExplicacao({
    required String documento,
    required String local,
    required String trecho,
    required String antes,
    required String depois,
    required String pergunta,
    required List<FonteConsulta> fontes,
  }) =>
      'DOCUMENTO DO PROCESSO: $documento ($local)\n'
      'CONTEXTO ANTERIOR:\n${_fim(antes)}\n\n'
      'TRECHO MARCADO:\n«$trecho»\n\n'
      'CONTEXTO POSTERIOR:\n${_ini(depois)}\n\n'
      'PERGUNTA DO RELATOR: ${pergunta.trim().isEmpty ? 'Explique em linguagem simples o que este trecho diz e o que ele implica para o parecer.' : pergunta.trim()}\n\n'
      'FONTES (normas e documentos da base):\n${fontesTexto(fontes)}';

  static ExplicacaoTrecho lerExplicacao(
    String raw,
    List<FonteConsulta> fontes,
  ) {
    final json = _json(raw);
    if (json == null) {
      return ExplicacaoTrecho(resposta: raw.trim(), estruturada: false);
    }
    final verificada = lerPergunta(
      jsonEncode({'evidencias': json['evidencias'] ?? const []}),
      fontes,
    );
    return ExplicacaoTrecho(
      resposta: '${json['resposta'] ?? ''}'.trim(),
      pontosAtencao: [
        for (final x in (json['pontos_atencao'] as List? ?? const []))
          if ('$x'.trim().isNotEmpty) '$x'.trim(),
      ],
      termos: [
        for (final t in (json['termos'] as List? ?? const []))
          if (t is Map && '${t['termo'] ?? ''}'.trim().isNotEmpty)
            (
              termo: '${t['termo']}'.trim(),
              significado: '${t['significado'] ?? ''}'.trim(),
            ),
      ],
      evidencias: verificada.evidencias,
      descartadas: verificada.descartadas,
      comentario: '${json['comentario'] ?? ''}'.trim(),
    );
  }

  static const sistemaComentario = '''
Você ajuda o relator de um conselho da Universidade Federal de Uberlândia
a escrever anotações sobre trechos de documentos de um processo.
Reescreva (ou complete) a anotação do relator para que fique clara,
objetiva e útil depois: o que o trecho diz, por que importa para o parecer
e o que conferir ou perguntar. Mantenha a opinião e as dúvidas do relator.
Não invente fatos, números nem normas: use só o trecho, o contexto, a
explicação dada e as fontes. Até 120 palavras, em português.
Responda SOMENTE com o texto da anotação (sem aspas, sem títulos).''';

  static String promptComentario({
    required String documento,
    required String local,
    required String trecho,
    required String antes,
    required String depois,
    required String anotacao,
    String explicacao = '',
    List<FonteConsulta> fontes = const [],
  }) =>
      'DOCUMENTO: $documento ($local)\n'
      'CONTEXTO: …${_fim(antes)}\n«$trecho»\n${_ini(depois)}…\n\n'
      '${explicacao.trim().isEmpty ? '' : 'EXPLICAÇÃO JÁ DADA:\n${explicacao.trim()}\n\n'}'
      'ANOTAÇÃO DO RELATOR (rascunho): '
      '${anotacao.trim().isEmpty ? '(vazia: escreva uma anotação a partir do trecho)' : anotacao.trim()}\n\n'
      '${fontes.isEmpty ? '' : 'FONTES:\n${fontesTexto(fontes)}'}';

  /// Limpa a resposta de texto puro (tira aspas e cercas de código).
  static String lerComentario(String raw) => raw
      .trim()
      .replaceAll(RegExp(r'^```\w*\s*|\s*```$'), '')
      .replaceAll(RegExp(r'^["“«]+|["”»]+$'), '')
      .trim();
}

/// Explicação da IA sobre um trecho de documento anexado.
class ExplicacaoTrecho {
  const ExplicacaoTrecho({
    required this.resposta,
    this.pontosAtencao = const [],
    this.termos = const [],
    this.evidencias = const [],
    this.descartadas = 0,
    this.comentario = '',
    this.estruturada = true,
  });

  final String resposta;
  final List<String> pontosAtencao;
  final List<({String termo, String significado})> termos;
  final List<Evidencia> evidencias;
  final int descartadas;

  /// Anotação sugerida para guardar com a marcação.
  final String comentario;

  /// A resposta veio no JSON pedido (senão, texto livre sem conferência).
  final bool estruturada;

  /// Texto para guardar junto da marcação.
  String get resumo => [
    resposta,
    if (pontosAtencao.isNotEmpty)
      'Pontos de atenção:\n${pontosAtencao.map((x) => '• $x').join('\n')}',
    if (termos.isNotEmpty)
      'Termos:\n${termos.map((t) => '• ${t.termo}: ${t.significado}').join('\n')}',
    if (evidencias.isNotEmpty)
      'Fontes: ${evidencias.map((e) => e.fonte.referencia).toSet().join('; ')}',
  ].where((x) => x.trim().isNotEmpty).join('\n\n');
}
