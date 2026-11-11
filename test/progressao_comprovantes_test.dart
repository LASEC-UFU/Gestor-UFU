import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/data/services/progressao_comprovantes_service.dart';
import 'package:gestor_ufu/domain/entities/progressao.dart';
import 'package:gestor_ufu/domain/progressao/comprovantes.dart';
import 'package:path/path.dart' as p;

void main() {
  const service = ProgressaoComprovantesService();

  test('nome do comprovante é ASCII, curto e identifica tabela/item/linha', () {
    const l = LancamentoProgressao(
      id: 'a',
      item: 1,
      periodo: '2023/01',
      descricao: 'Instrumentação Industrial I – turma de prática',
    );
    final nome = nomeBaseComprovante(l, 2);
    expect(
      nome,
      startsWith('A1.1_It001-02_2023-1_Instrumentacao_Industrial_I'),
    );
    expect(nome.length, lessThanOrEqualTo(limiteNomeArvoreSei));
    expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(nome), isTrue);
    expect(caminhoRelativoComprovante(l, 2, '.PDF'), 'A1.1_Ensino/$nome.pdf');
    expect(nomeBaseComprovante(l, 2, sufixo: 3), endsWith('_3'));
    expect(
      nomeBaseComprovante(l, 2, sufixo: 3).length,
      lessThanOrEqualTo(limiteNomeArvoreSei),
    );
  });

  test('sem descrição usa a descrição do item do Anexo 1', () {
    const l = LancamentoProgressao(id: 'a', item: 137);
    expect(nomeBaseComprovante(l, 1), startsWith('A1.6_It137-01_'));
    expect(
      nomeBaseComprovante(l, 1).length,
      greaterThan('A1.6_It137-01_'.length),
    );
  });

  test('rótulo do comprovante: arquivo copiado x texto antigo', () {
    const copiado = LancamentoProgressao(
      id: 'a',
      item: 1,
      comprovante: 'A1.1_Ensino/A1.1_It001-01_X.pdf',
    );
    expect(copiado.comprovanteArquivado, isTrue);
    expect(copiado.rotuloComprovante, 'A1.1_It001-01_X');
    const antigo = LancamentoProgressao(id: 'b', item: 1, comprovante: 'x.pdf');
    expect(antigo.comprovanteArquivado, isFalse);
    expect(antigo.rotuloComprovante, 'x.pdf');
  });

  group('cópia para a pasta do processo', () {
    late Directory tmp;
    late String origem;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('comprovantes_');
      origem = p.join(tmp.path, 'certificado qualquer.pdf');
      await File(origem).writeAsString('%PDF-1.4 teste');
    });

    tearDown(() => tmp.delete(recursive: true));

    test(
      'importa, substitui, reorganiza e descarta sem perder arquivos',
      () async {
        final pasta = p.join(tmp.path, 'processo');
        var processo = ProgressaoDocente(
          id: 'x',
          pastaComprovantes: pasta,
          lancamentos: const [
            LancamentoProgressao(
              id: '1',
              item: 1,
              periodo: '2023/01',
              descricao: 'Aula A',
            ),
            LancamentoProgressao(
              id: '2',
              item: 1,
              periodo: '2023/02',
              descricao: 'Aula B',
            ),
            LancamentoProgressao(id: '3', item: 76, descricao: 'Bancas de TCC'),
          ],
        );
        ProgressaoDocente troca(LancamentoProgressao l) => processo.copyWith(
          lancamentos: [
            for (final e in processo.lancamentos) e.id == l.id ? l : e,
          ],
        );

        for (final l in processo.lancamentos) {
          processo = troca(
            await service.importar(
              processo: processo,
              lancamento: l,
              origem: origem,
            ),
          );
        }
        final rel = processo.lancamentos.map((l) => l.comprovante).toList();
        expect(rel[0], 'A1.1_Ensino/A1.1_It001-01_2023-1_Aula_A.pdf');
        expect(rel[1], 'A1.1_Ensino/A1.1_It001-02_2023-2_Aula_B.pdf');
        expect(rel[2], 'A1.3_Producao/A1.3_It076-01_Bancas_de_TCC.pdf');
        for (final l in processo.lancamentos) {
          expect(service.existe(processo, l), isTrue);
        }
        expect(
          File(origem).existsSync(),
          isTrue,
          reason: 'original preservado',
        );

        // Ordem invertida no item 1: reorganizar troca os nomes sem colisão.
        processo = processo.copyWith(
          lancamentos: [
            processo.lancamentos[1],
            processo.lancamentos[0],
            processo.lancamentos[2],
          ],
        );
        final (reorganizado, renomeados) = await service.reorganizar(processo);
        processo = reorganizado;
        expect(renomeados, 2);
        expect(
          processo.lancamentos[0].comprovante,
          endsWith('It001-01_2023-2_Aula_B.pdf'),
        );
        expect(
          processo.lancamentos[1].comprovante,
          endsWith('It001-02_2023-1_Aula_A.pdf'),
        );
        expect(lancamentosComComprovante(processo).map((l) => l.id), [
          '2',
          '1',
          '3',
        ]);

        // Remoção move a cópia para os descartados.
        final antes = service.caminhoAbsoluto(
          processo,
          processo.lancamentos[2],
        )!;
        processo = troca(
          await service.remover(processo, processo.lancamentos[2]),
        );
        expect(processo.lancamentos[2].comprovante, isEmpty);
        expect(File(antes).existsSync(), isFalse);
        expect(
          File(
            p.join(
              pasta,
              ProgressaoComprovantesService.subpastaDescartados,
              p.basename(antes),
            ),
          ).existsSync(),
          isTrue,
        );
      },
    );

    test('recusa formato não aceito', () async {
      final txt = p.join(tmp.path, 'nota.txt');
      await File(txt).writeAsString('x');
      final processo = ProgressaoDocente(id: 'x', pastaComprovantes: tmp.path);
      expect(
        () => service.importar(
          processo: processo,
          lancamento: const LancamentoProgressao(id: '1', item: 1),
          origem: txt,
        ),
        throwsStateError,
      );
    });
  });
}
