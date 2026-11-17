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
}
