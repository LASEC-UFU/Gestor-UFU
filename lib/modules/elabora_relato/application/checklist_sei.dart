import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';

/// Artigo citado no texto do parecer ("art. 41 da Resolução nº 46/2022").
class ArtigoCitado {
  const ArtigoCitado({
    required this.numero,
    required this.secao,
    required this.contexto,
    this.normaNumero = '',
    this.normaAno = '',
  });

  /// Número do artigo ("41", "5-A").
  final String numero;
  final ParecerSecao secao;

  /// Trecho do parecer em volta da citação.
  final String contexto;

  /// Número da norma citada logo depois do artigo ('' = não identificada).
  final String normaNumero;
  final String normaAno;

  String get rotulo {
    final norma = normaNumero.isEmpty
        ? ''
        : ' da norma nº $normaNumero${normaAno.isEmpty ? '' : '/$normaAno'}';
    return 'Art. $numero$norma';
  }
}

enum GravidadeItem { aviso, info }

class ItemChecklist {
  const ItemChecklist(this.titulo, this.detalhes, this.gravidade);

  final String titulo;
  final List<String> detalhes;
  final GravidadeItem gravidade;
}

/// Verificação do parecer antes de inserir no SEI: comentários "para
/// revisão" pendentes, artigos citados que não estão na base de
/// documentos e campos essenciais vazios. Não bloqueia: só informa.
class ChecklistSei {
  const ChecklistSei(this.itens);

  final List<ItemChecklist> itens;

  bool get temAvisos => itens.any((i) => i.gravidade == GravidadeItem.aviso);

  static final _citacao = RegExp(
    r'\bart(?:igo)?s?\.?\s*(\d+)\s*[º°o]?(?:\s*-\s*([A-Z])\b)?',
    caseSensitive: false,
  );
  static final _normaApos = RegExp(
    r'^[^.;]{0,90}?\b(?:resolu[çc][ãa]o|portaria|lei|decreto|instru[çc][ãa]o'
    r'\s+normativa|regimento|estatuto|norma)\b[^.;\d]{0,40}?n?[º°o.]?\s*'
    r'(\d+(?:\.\d+)?)(?:\s*[/,]\s*(?:de\s+)?(?:\d{1,2}\s+de\s+\w+\s+de\s+)?(\d{4}))?',
    caseSensitive: false,
  );

  /// Artigos citados num texto (sem tags HTML), com a norma, se houver.
  static List<ArtigoCitado> artigosCitados(String texto, ParecerSecao secao) {
    final out = <ArtigoCitado>[];
    final vistos = <String>{};
    for (final m in _citacao.allMatches(texto)) {
      final numero =
          '${m.group(1)}${m.group(2) == null ? '' : '-${m.group(2)!.toUpperCase()}'}';
      final depois = texto.substring(
        m.end,
        (m.end + 140).clamp(0, texto.length),
      );
      final n = _normaApos.firstMatch(depois);
      final normaNumero = (n?.group(1) ?? '').replaceAll('.', '');
      final normaAno = n?.group(2) ?? '';
      if (!vistos.add('$numero|$normaNumero|$normaAno')) continue;
      final ini = (m.start - 60).clamp(0, texto.length);
      final fim = (m.end + 80).clamp(0, texto.length);
      out.add(
        ArtigoCitado(
          numero: numero,
          secao: secao,
          contexto: texto
              .substring(ini, fim)
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
          normaNumero: normaNumero,
          normaAno: normaAno,
        ),
      );
    }
    return out;
  }

  /// O artigo está na base? Com a norma identificada, exige um documento
  /// cuja norma/título/nome cite o mesmo número (e ano, se houver).
  static bool artigoNaBase(ArtigoCitado a, BaseDocumentos base) {
    final rotulo = 'Art. ${a.numero}';
    for (final d in base.documentos) {
      if (!d.artigos.contains(rotulo)) continue;
      if (a.normaNumero.isEmpty) return true;
      final ident = TextoBusca.semAcentos(
        '${d.norma} ${d.titulo} ${d.arquivo}',
      );
      final numeros = RegExp(
        r'\d+',
      ).allMatches(ident.replaceAll('.', '')).map((x) => x.group(0)!).toSet();
      if (!numeros.contains(a.normaNumero)) continue;
      // O ano só desqualifica se o documento trouxer outro ano.
      final anos = numeros.where((n) => RegExp(r'^(19|20)\d\d$').hasMatch(n));
      if (a.normaAno.isNotEmpty &&
          anos.isNotEmpty &&
          !anos.contains(a.normaAno)) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// Monta a verificação. [textoDe] devolve o texto visível de uma seção.
  static ChecklistSei verificar({
    required Parecer parecer,
    required String Function(ParecerSecao) textoDe,
    BaseDocumentos? base,
    bool baseConfigurada = false,
  }) {
    final itens = <ItemChecklist>[];

    final vazias = [
      if (parecer.assunto.trim().isEmpty) 'assunto (Dados do parecer)',
      for (final s in ParecerSecao.values)
        if (textoDe(s).trim().isEmpty) s.titulo,
    ];
    if (vazias.isNotEmpty) {
      itens.add(ItemChecklist('Campos vazios', vazias, GravidadeItem.aviso));
    }

    final pendentes = [
      for (final c in parecer.comentarios)
        if ('${c['status'] ?? ''}' == 'revisar') c,
    ];
    if (pendentes.isNotEmpty) {
      itens.add(
        ItemChecklist(
          '${pendentes.length} comentário(s) "para revisão" pendente(s)',
          [
            for (final c in pendentes.take(12))
              '${_nomeSecao('${c['secao']}')}: ${_curto('${c['texto'] ?? c['trecho'] ?? ''}')}',
            if (pendentes.length > 12) '… e mais ${pendentes.length - 12}.',
          ],
          GravidadeItem.aviso,
        ),
      );
    }

    final citados = [
      for (final s in ParecerSecao.values) ...artigosCitados(textoDe(s), s),
    ];
    if (citados.isNotEmpty) {
      if (base == null) {
        itens.add(
          ItemChecklist(
            '${citados.length} artigo(s) citado(s) não conferido(s)',
            [
              baseConfigurada
                  ? 'A base de documentos ainda não foi preparada.'
                  : 'Nenhuma pasta de documentos escolhida (Base de '
                        'documentos…).',
            ],
            GravidadeItem.info,
          ),
        );
      } else {
        final faltam = [
          for (final a in citados)
            if (!artigoNaBase(a, base)) a,
        ];
        if (faltam.isNotEmpty) {
          itens.add(
            ItemChecklist(
              '${faltam.length} de ${citados.length} artigo(s) citado(s) '
              'não encontrado(s) na base',
              [
                for (final a in faltam.take(12))
                  '${a.rotulo} (${a.secao.titulo}): "…${a.contexto}…"',
                if (faltam.length > 12) '… e mais ${faltam.length - 12}.',
              ],
              GravidadeItem.aviso,
            ),
          );
        } else {
          itens.add(
            ItemChecklist(
              'Os ${citados.length} artigo(s) citado(s) estão na base',
              const [],
              GravidadeItem.info,
            ),
          );
        }
      }
    }
    return ChecklistSei(itens);
  }

  static String _nomeSecao(String id) =>
      ParecerSecao.values.where((s) => s.id == id).firstOrNull?.titulo ?? id;

  static String _curto(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 110 ? t : '${t.substring(0, 109)}…';
  }

  /// Texto visível de um HTML de seção (sem tags e entidades comuns).
  static String textoDeHtml(String html) => html
      .replaceAll(RegExp(r'</(p|div|li|h\d|tr)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .trim();
}
