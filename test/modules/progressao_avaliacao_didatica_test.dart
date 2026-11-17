import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_comprovantes_service.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_pdf_service.dart';
import 'package:gestor_ufu/modules/progressao/domain/progressao.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory pasta;

  setUp(() async {
    pasta = await Directory.systemTemp.createTemp('progressao_aval_');
    final dir = Directory(p.join(pasta.path, 'Avaliacao_Didatica'));
    await dir.create();
    for (final s in ['2024-2', '2025-1']) {
      await File(
        p.join(dir.path, 'Avaliacao_Didatica_$s.pdf'),
      ).writeAsString('%PDF-1.4 teste');
    }
  });

  tearDown(() => pasta.delete(recursive: true));

  ProgressaoDocente processo() => ProgressaoDocente(
    id: 't',
    docente: 'Docente Teste',
    pastaComprovantes: pasta.path,
    avaliacoesDidaticas: const [
      '2024/2 – FEELT32503 Instrumentação Industrial I – sem registro',
      '2025/1 – FEELT32602 Instrumentação Industrial II – sem registro',
      '2025/2 – sem consulta arquivada',
      'Linha sem semestre',
    ],
  );

  test('associa cada semestre à consulta arquivada', () {
    const service = ProgressaoComprovantesService();
    final p0 = processo();
    expect(
      ProgressaoComprovantesService.semestreAvaliacao('2024/2 – x'),
      '2024/2',
    );
    expect(
      service.rotuloAvaliacaoDidatica(p0, p0.avaliacoesDidaticas[0]),
      'Avaliacao_Didatica_2024-2',
    );
    expect(service.rotuloAvaliacaoDidatica(p0, p0.avaliacoesDidaticas[2]), isNull);
    expect(service.rotuloAvaliacaoDidatica(p0, p0.avaliacoesDidaticas[3]), isNull);
    expect(service.avaliacoesDidaticas(p0).map((a) => a.rotulo), [
      'Avaliacao_Didatica_2024-2',
      'Avaliacao_Didatica_2025-1',
    ]);
  });

  test('o relatório em PDF é gerado com as citações', () async {
    final bytes = await ProgressaoPdfService().gerarRelatorio(processo());
    expect(bytes.length, greaterThan(1000));
  });
}
