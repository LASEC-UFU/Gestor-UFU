import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/checklist_sei.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/data/base_documentos_indexer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/base_documentos.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';

BaseDocumentos _base(String arquivo, String texto) => BaseDocumentos(
  pasta: '',
  documentos: [
    DocumentoBase(
      arquivo: arquivo,
      tamanho: 1,
      modificado: DateTime(2026),
      hash: 'h',
      status: StatusDocumento.ok,
      norma: BaseDocumentosIndexer.norma(texto),
      trechos: BaseDocumentosIndexer.segmentar(
        'h',
        arquivo,
        BaseDocumentosIndexer.paragrafosDeTexto(texto),
      ),
    ),
  ],
);

void main() {
  group('checklist antes do SEI', () {
    test('artigos citados com e sem norma', () {
      final a = ChecklistSei.artigosCitados(
        'Conforme o art. 41 da Resolução CONGRAD nº 46/2022, e o artigo 3º, '
        'o prazo é de 30 dias.',
        ParecerSecao.fundamentacao,
      );
      expect(a.map((x) => x.numero), ['41', '3']);
      expect(a.first.normaNumero, '46');
      expect(a.first.normaAno, '2022');
    });

    test('aponta artigo fora da base, pendências e campos vazios', () {
      final base = _base(
        'res46.pdf',
        'RESOLUÇÃO CONGRAD Nº 46, DE 2022\nArt. 41. A avaliação será feita '
            'pelo supervisor.',
      );
      final parecer = const Parecer().copyWith(
        assunto: 'Estágio',
        fundamentacao:
            '<p>Nos termos do art. 41 da Resolução nº 46/2022 e do art. 99 '
            'da mesma Resolução nº 46/2022.</p>',
        comentarios: [
          {
            'id': '1',
            'secao': 'fundamentacao',
            'texto': 'Ver',
            'status': 'revisar',
          },
          {
            'id': '2',
            'secao': 'fundamentacao',
            'texto': 'Ok',
            'status': 'confirmado',
          },
        ],
      );
      final c = ChecklistSei.verificar(
        parecer: parecer,
        textoDe: (s) => ChecklistSei.textoDeHtml(parecer.secao(s)),
        base: base,
        baseConfigurada: true,
      );
      final titulos = c.itens.map((i) => i.titulo).join(' | ');
      expect(c.temAvisos, isTrue);
      expect(titulos, contains('1 comentário(s) "para revisão"'));
      expect(titulos, contains('1 de 2 artigo(s) citado(s) não encontrado(s)'));
      final faltam = c.itens.firstWhere(
        (i) => i.titulo.contains('não encontrado'),
      );
      expect(faltam.detalhes.single, startsWith('Art. 99'));
      // Relatório e conclusão vazios.
      expect(titulos, contains('Campos vazios'));
    });

    test('norma diferente não conta como encontrada', () {
      final base = _base('res46.pdf', 'RESOLUÇÃO Nº 46/2022\nArt. 41. Texto.');
      final a = ChecklistSei.artigosCitados(
        'art. 41 da Resolução nº 12/2020',
        ParecerSecao.conclusao,
      ).single;
      expect(ChecklistSei.artigoNaBase(a, base), isFalse);
    });

    test('sem base: só informa que não conferiu', () {
      const parecer = Parecer(
        conclusao: '<p>Art. 5º da Lei nº 11.788/2008.</p>',
      );
      final c = ChecklistSei.verificar(
        parecer: parecer,
        textoDe: (s) => ChecklistSei.textoDeHtml(parecer.secao(s)),
      );
      final item = c.itens.firstWhere(
        (i) => i.titulo.contains('não conferido'),
      );
      expect(item.gravidade, GravidadeItem.info);
    });
  });

  group('simulado de arguição', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('lista perguntas e registra o treino', () async {
      final service = ParecerService(arvore: SeiArvoreService());
      await service.carregar();
      await service.salvarComentario({
        'id': 'a',
        'secao': 'relatorio',
        'pergunta_arguicao': 'Qual o prazo?',
        'resposta_oral': '30 dias.',
      });
      // Comentário antigo da análise: pergunta em "pergunta".
      await service.salvarComentario({
        'id': 'b',
        'secao': 'relatorio',
        'categoria': 'analise_normativa',
        'pergunta': 'Quem avalia?',
      });
      // Em consulta à IA, "pergunta" é do relator: fica de fora.
      await service.salvarComentario({
        'id': 'c',
        'secao': 'relatorio',
        'categoria': 'consulta_ia',
        'pergunta': 'Isto está certo?',
      });
      await service.salvarComentario({
        'id': 'd',
        'secao': 'relatorio',
        'pergunta_arguicao': 'Descartada',
        'status': 'nao_aplica',
      });
      expect(service.perguntasArguicao().map((c) => c['id']), ['a', 'b']);

      await service.registrarTreino('a', acertou: false);
      await service.registrarTreino('a', acertou: true);
      final treino =
          service.parecer.comentarios.firstWhere(
                (c) => c['id'] == 'a',
              )['treino']
              as Map;
      expect(treino['acertos'], 1);
      expect(treino['rever'], 1);
      expect(treino['ultimo'], 'acertou');
      // O treino é salvo no rascunho.
      final relido = ParecerService(arvore: SeiArvoreService());
      await relido.carregar();
      expect(
        (relido.parecer.comentarios.firstWhere((c) => c['id'] == 'a')['treino']
            as Map)['acertos'],
        1,
      );
    });
  });

  group('vigia da pasta', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('vigia');
    });
    tearDown(() => dir.delete(recursive: true));

    test('ignora o próprio JSON e temporários', () {
      expect(
        BaseDocumentosIndexer.ignorado(BaseDocumentosIndexer.nomeArquivo),
        isTrue,
      );
      expect(BaseDocumentosIndexer.ignorado('sub/~\$norma.docx'), isTrue);
      expect(BaseDocumentosIndexer.ignorado('.git/x.txt'), isTrue);
      expect(BaseDocumentosIndexer.ignorado('sub\\norma.docx'), isFalse);
    });

    test('arquivo novo atualiza a base sozinho', () async {
      File(p.join(dir.path, 'a.txt')).writeAsStringSync('Art. 1º Primeiro.');
      final base = BaseDocumentosService(
        espera: const Duration(milliseconds: 300),
      );
      await base.definirPasta(dir.path);
      expect(base.vigiando, isTrue);
      expect(base.base!.documentos, hasLength(1));

      File(p.join(dir.path, 'b.txt')).writeAsStringSync('Art. 2º Segundo.');
      final limite = DateTime.now().add(const Duration(seconds: 10));
      while ((base.base?.documentos.length ?? 0) < 2 &&
          DateTime.now().isBefore(limite)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(base.base!.documentos.map((d) => d.arquivo), ['a.txt', 'b.txt']);
      expect(base.atualizadaAutomaticamente, isNotNull);
      base.dispose();
    });
  });
}
