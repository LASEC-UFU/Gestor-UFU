import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/processos_parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/parecer.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/sei_documento.dart';

ProcessosParecerService _novo() => ProcessosParecerService(
  parecer: ParecerService(arvore: SeiArvoreService()),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('cada processo tem o seu rascunho, árvore e comentários', () async {
    final s = _novo();
    final a = await s.criar(nome: 'A', numeroSei: '23117.1/2026');
    final b = await s.criar(nome: 'B');

    await s.abrir(a.id);
    s.parecer.atualizar(s.parecer.parecer.copyWith(assunto: 'Assunto A'));
    await s.parecer.substituirSecao(ParecerSecao.relatorio, '<p>Relato A</p>');
    await s.parecer.salvarComentario({
      'id': 'c1',
      'secao': 'relatorio',
      'texto': 'Ver',
      'status': 'revisar',
    });
    s.parecer.arvore.definirDocumentos([
      SeiDocumento.fromTree(1, 'Ofício 1 (1234567)'),
    ]);

    await s.abrir(b.id);
    expect(s.parecer.parecer.assunto, '');
    expect(s.parecer.parecer.relatorio, isNot(contains('Relato A')));
    expect(s.parecer.parecer.comentarios, isEmpty);
    expect(s.parecer.arvore.documentos, isEmpty);

    await s.abrir(a.id);
    expect(s.parecer.parecer.assunto, 'Assunto A');
    expect(s.parecer.parecer.comentarios.single['id'], 'c1');

    await s.fechar();
    expect(s.ativo, isNull);
    final r = s.resumo(a.id);
    expect(r.assunto, 'Assunto A');
    expect(r.pendentes, 1);
    expect(r.secoesComTexto, greaterThanOrEqualTo(1));

    // Outra janela/instância relê a lista do banco.
    final outra = _novo();
    await outra.carregar();
    expect(outra.processos.map((p) => p.nome).toSet(), {'A', 'B'});
    expect(
      outra.processos.firstWhere((p) => p.nome == 'A').numeroSei,
      '23117.1/2026',
    );
  });

  test('copiar leva tudo; excluir apaga só o processo', () async {
    final s = _novo();
    final a = await s.criar(nome: 'Original');
    await s.abrir(a.id);
    await s.parecer.substituirSecao(
      ParecerSecao.conclusao,
      '<p>Voto favorável</p>',
    );
    await s.parecer.salvarComentario({'id': 'x', 'secao': 'conclusao'});

    final copia = await s.duplicar(a.id);
    expect(copia.nome, 'Cópia de Original');
    await s.abrir(copia.id);
    expect(s.parecer.parecer.conclusao, contains('Voto favorável'));
    expect(s.parecer.parecer.comentarios, hasLength(1));

    // A cópia é independente.
    await s.parecer.substituirSecao(ParecerSecao.conclusao, '<p>Outro</p>');
    await s.abrir(a.id);
    expect(s.parecer.parecer.conclusao, contains('Voto favorável'));

    await s.excluir(copia.id);
    expect(s.processos.map((p) => p.id), [a.id]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.contains(copia.id)), isEmpty);
    // Excluir o processo aberto volta à lista.
    await s.excluir(a.id);
    expect(s.ativo, isNull);
    expect(s.processos, isEmpty);
  });

  test('o rascunho único antigo vira um processo (uma vez)', () async {
    SharedPreferences.setMockInitialValues({
      ParecerService.draftKey:
          '{"assunto": "Parecer antigo", "relatorio": "<p>Texto</p>"}',
      SeiArvoreService.inventoryKey: '[{"ordem": 1, "nome_arvore": "Ofício"}]',
    });
    final s = _novo();
    await s.carregar();
    final p = s.processos.single;
    expect(p.id, ProcessosParecerService.idMigrado);
    expect(p.nome, 'Parecer antigo');
    expect(s.resumo(p.id).documentos, 1);
    await s.abrir(p.id);
    expect(s.parecer.parecer.relatorio, '<p>Texto</p>');
    expect(s.parecer.arvore.documentos.single.nomeArvore, 'Ofício');

    // Excluído, não volta a ser migrado.
    await s.excluir(p.id);
    final depois = _novo();
    await depois.carregar();
    expect(depois.processos, isEmpty);
  });

  test('comandos sem processo aberto abrem o mais recente', () async {
    final s = _novo();
    expect((await s.garantirAtivo()).nome, 'Novo processo');
    final outro = await s.criar(nome: 'Outro');
    expect((await s.garantirAtivo(outro.id)).id, outro.id);
  });
}
