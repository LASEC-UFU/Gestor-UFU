import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/consulta_trecho.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';

const _resolucao = '''
UNIVERSIDADE FEDERAL DE UBERLÂNDIA
RESOLUÇÃO CONGRAD Nº 46, DE 2022

CAPÍTULO I
DAS DISPOSIÇÕES GERAIS

Art. 1º Esta Resolução dispõe sobre o estágio curricular dos cursos de
graduação.
Art. 2º O estágio obrigatório terá carga horária mínima de 300 horas,
conforme o projeto pedagógico do curso.
Parágrafo único. A carga horária poderá ser distribuída em semestres.

CAPÍTULO II
DA AVALIAÇÃO

Art. 41. A avaliação do estagiário será feita pelo supervisor e pelo
orientador, em formulário próprio.
§ 1º O relatório final deverá ser entregue em até 30 dias.
''';

List<int> _docx(List<(String, String)> paragrafos) {
  final body = paragrafos
      .map(
        (x) =>
            '<w:p><w:pPr><w:pStyle w:val="${x.$1}"/></w:pPr>'
            '<w:r><w:t>${x.$2}</w:t></w:r></w:p>',
      )
      .join();
  final xml =
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body</w:body></w:document>';
  final bytes = utf8.encode(xml);
  final archive = Archive()
    ..addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
  return ZipEncoder().encode(archive)!;
}

void main() {
  group('segmentação', () {
    test('artigos, seções e parágrafos com localização', () {
      final pars = BaseDocumentosIndexer.paragrafosDeTexto(
        _resolucao,
        pagina: 3,
      );
      // Linhas quebradas do PDF voltam a formar um parágrafo.
      expect(
        pars.map((x) => x.texto),
        contains(
          'Art. 1º Esta Resolução dispõe sobre o estágio curricular dos '
          'cursos de graduação.',
        ),
      );
      final trechos = BaseDocumentosIndexer.segmentar('abc', 'res.pdf', pars);
      final art2 = trechos.firstWhere((t) => t.artigo == 'Art. 2');
      expect(art2.texto, contains('Parágrafo único'));
      expect(art2.secao, 'CAPÍTULO I – DAS DISPOSIÇÕES GERAIS');
      expect(art2.pagina, 3);
      final art41 = trechos.firstWhere((t) => t.artigo == 'Art. 41');
      expect(art41.secao, 'CAPÍTULO II – DA AVALIAÇÃO');
      expect(art41.texto, contains('30 dias'));
      expect(art41.localizacao, contains('p. 3'));
      expect(art41.localizacao, contains('Art. 41'));
      expect(
        BaseDocumentosIndexer.norma(_resolucao),
        'RESOLUÇÃO CONGRAD Nº 46',
      );
    });

    test('"Art. 5º A pessoa" não vira "Art. 5-A"', () {
      final t = BaseDocumentosIndexer.segmentar(
        'x',
        'a.txt',
        BaseDocumentosIndexer.paragrafosDeTexto(
          'Art. 5º A pessoa interessada requer.\nArt. 6º-A Incluído.',
        ),
      );
      expect(t.map((x) => x.artigo), ['Art. 5', 'Art. 6-A']);
    });
  });

  group('busca', () {
    final base = BaseDocumentos(
      pasta: '',
      documentos: [
        DocumentoBase(
          arquivo: 'res.pdf',
          tamanho: 1,
          modificado: DateTime(2026),
          hash: 'h',
          status: StatusDocumento.ok,
          trechos: BaseDocumentosIndexer.segmentar(
            'h',
            'res.pdf',
            BaseDocumentosIndexer.paragrafosDeTexto(_resolucao, pagina: 1),
          ),
        ),
      ],
    );

    test('encontra por termos sem acento e plural', () {
      final r = base.buscar('carga horaria minima dos estagios');
      expect(r.first.trecho.artigo, 'Art. 2');
    });

    test('número do artigo reforça o trecho', () {
      final r = base.buscar('o que diz o art. 41?');
      expect(r.first.trecho.artigo, 'Art. 41');
    });

    test('nada encontrado devolve lista vazia', () {
      expect(base.buscar('xilofone'), isEmpty);
    });
  });

  group('atualização incremental', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('base'));
    tearDown(() => dir.delete(recursive: true));

    test('reaproveita, atualiza e remove sem tocar nos originais', () async {
      final txt = File(p.join(dir.path, 'resolucao.txt'))
        ..writeAsStringSync(_resolucao);
      final docx = File(p.join(dir.path, 'sub', 'norma.docx'));
      docx.parent.createSync();
      docx.writeAsBytesSync(
        _docx([
          ('Heading1', 'Normas de Estágio'),
          ('Normal', 'Art. 3º O supervisor acompanha o estagiário.'),
        ]),
      );
      File(p.join(dir.path, 'antigo.doc')).writeAsStringSync('x');
      final original = txt.readAsStringSync();

      var (base, r) = await BaseDocumentosIndexer.atualizar(dir.path);
      expect(r.novos, hasLength(3));
      expect(File(r.arquivoJson).existsSync(), isTrue);
      expect(p.basename(r.arquivoJson), BaseDocumentosIndexer.nomeArquivo);
      final docxBase = base.documentos.firstWhere(
        (d) => d.arquivo == 'sub/norma.docx',
      );
      expect(docxBase.trechos.single.artigo, 'Art. 3');
      expect(docxBase.trechos.single.secao, 'Normas de Estágio');
      expect(
        base.documentos.firstWhere((d) => d.arquivo == 'antigo.doc').status,
        StatusDocumento.naoSuportado,
      );
      expect(await BaseDocumentosIndexer.emDia(base), isTrue);

      // JSON relido do disco é equivalente.
      final relida = (await BaseDocumentosIndexer.carregar(dir.path))!;
      expect(relida.totalTrechos, base.totalTrechos);
      expect(
        relida.buscar('supervisor').first.trecho.arquivo,
        'sub/norma.docx',
      );

      // Sem mudanças: nada é reprocessado.
      (base, r) = await BaseDocumentosIndexer.atualizar(
        dir.path,
        anterior: relida,
      );
      expect(r.mudou, isFalse);
      expect(r.reaproveitados, hasLength(3));

      // Arquivo alterado e arquivo removido.
      txt.writeAsStringSync('$_resolucao\nArt. 50. Novo artigo de teste.');
      await txt.setLastModified(DateTime.now().add(const Duration(minutes: 1)));
      docx.deleteSync();
      expect(await BaseDocumentosIndexer.emDia(base), isFalse);
      (base, r) = await BaseDocumentosIndexer.atualizar(
        dir.path,
        anterior: base,
      );
      expect(r.atualizados, ['resolucao.txt']);
      expect(r.removidos, ['sub/norma.docx']);
      expect(base.buscar('art. 50').first.trecho.artigo, 'Art. 50');
      expect(txt.readAsStringSync(), startsWith(original));
    });

    test('PDF: página de cada trecho', () async {
      try {
        await Process.run('pdftotext', ['-v']);
      } on ProcessException {
        return; // Poppler ausente nesta máquina.
      }
      final pdf = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('Introduction page one')))
        ..addPage(
          pw.Page(build: (_) => pw.Text('Art. 7 The deadline is 30 days.')),
        );
      final file = File(p.join(dir.path, 'norma.pdf'))
        ..writeAsBytesSync(await pdf.save());
      final (base, _) = await BaseDocumentosIndexer.atualizar(dir.path);
      final doc = base.documentos.single;
      expect(doc.paginas, 2);
      final art = doc.trechos.firstWhere((t) => t.artigo == 'Art. 7');
      expect(art.pagina, 2);
      expect(file.existsSync(), isTrue);
    });
  });

  group('respostas da IA', () {
    const fontes = [
      FonteConsulta(
        id: 'F1',
        arquivo: 'res.pdf',
        localizacao: 'p. 2 · Art. 41',
        texto: 'Art. 41. O relatório final deverá ser entregue em até 30 dias.',
      ),
    ];

    test('confere citação e descarta fonte inexistente', () {
      final r = ConsultaTrecho.lerPergunta('''```json
{"avaliacao": "contradiz", "resposta": "O prazo é de 30 dias.",
 "evidencias": [
  {"fonte": "F1", "citacao": "O relatório final deverá ser entregue em até 30 dias", "relacao": "contradiz"},
  {"fonte": "[F1]", "citacao": "prazo de 60 dias", "relacao": "apoia"},
  {"fonte": "F9", "citacao": "inventada"}
 ]}
```''', fontes);
      expect(r.avaliacao, Avaliacao.contradiz);
      expect(r.evidencias, hasLength(2));
      expect(r.evidencias[0].citacaoConfirmada, isTrue);
      expect(r.evidencias[1].citacaoConfirmada, isFalse);
      expect(r.descartadas, 1);
    });

    test('sem evidência válida não há fundamento', () {
      final r = ConsultaTrecho.lerPergunta(
        '{"avaliacao": "fundamentado", "resposta": "Sim.", '
        '"evidencias": [{"fonte": "F7", "citacao": "x"}]}',
        fontes,
      );
      expect(r.avaliacao, Avaliacao.semInformacao);
    });

    test('resposta fora de JSON fica marcada como não estruturada', () {
      final r = ConsultaTrecho.lerPergunta('Acho que sim.', fontes);
      expect(r.avaliacao, Avaliacao.indefinido);
      expect(r.resposta, 'Acho que sim.');
    });

    test('proposta com fontes e alertas', () {
      final pr = ConsultaTrecho.lerProposta(
        '{"texto": "O relatório final será entregue em até 30 dias.", '
        '"justificativa": "Ajuste ao art. 41.", "fontes": ["F1", "F3"], '
        '"alertas": ["O pedido citava 60 dias."]}',
        fontes,
      )!;
      expect(pr.texto, startsWith('O relatório final'));
      expect(pr.fontes.single.id, 'F1');
      expect(pr.alertas, hasLength(1));
    });

    test('prompt identifica cursor sem seleção', () {
      final prompt = ConsultaTrecho.promptProposta(
        const TrechoConsultado(
          secao: 'II. FUNDAMENTAÇÃO',
          texto: '',
          anterior: 'Conforme a norma,',
          posterior: ' conclui-se.',
        ),
        'Cite o prazo.',
        fontes,
      );
      expect(prompt, contains('[CURSOR]'));
      expect(prompt, contains('[F1] res.pdf — p. 2 · Art. 41'));
    });
  });
}
