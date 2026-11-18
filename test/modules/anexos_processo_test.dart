import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/elabora_relato/application/anexos_processo_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/base_documentos_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/consulta_trecho.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/elabora_relato_commands.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/processos_parecer_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/application/sei_arvore_service.dart';
import 'package:gestor_ufu/modules/elabora_relato/domain/anexo_processo.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

const _oficio = '''
OFÍCIO Nº 12/2026/PROGRAD

Senhor Presidente,

Encaminhamos a proposta de alteração do PPC do curso de Engenharia
Mecânica, que inclui 10% da carga horária em atividades de extensão.

A proposta foi aprovada pelo Colegiado em 3 de março de 2026.
''';

List<int> _docx(List<String> paragrafos) {
  final body = paragrafos
      .map((t) => '<w:p><w:r><w:t>$t</w:t></w:r></w:p>')
      .join();
  final bytes = utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:body>$body</w:body></w:document>',
  );
  final archive = Archive()
    ..addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
  return ZipEncoder().encode(archive)!;
}

void main() {
  late Directory dir;
  late Directory guardados;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('anexos');
    guardados = Directory(p.join(dir.path, 'guardados'));
  });
  tearDown(() => dir.delete(recursive: true));

  ProcessosParecerService novo() => ProcessosParecerService(
    parecer: ParecerService(
      arvore: SeiArvoreService(),
      base: BaseDocumentosService(),
      anexos: AnexosProcessoService(pasta: () async => guardados.path),
    ),
  );

  test('anexa, lê em parágrafos e guarda marcações por processo', () async {
    final s = novo();
    final proc = await s.criar(nome: 'PPC');
    await s.abrir(proc.id);
    final anexos = s.parecer.anexos;

    final origem = File(p.join(dir.path, 'oficio.txt'))
      ..writeAsStringSync(_oficio);
    final a = await anexos.anexar(origem.path);
    expect(a.nome, 'oficio.txt');
    expect(a.aviso, isEmpty);
    // O original não muda; a cópia fica na pasta de anexos.
    expect(origem.readAsStringSync(), _oficio);
    expect(File(await anexos.caminho(a)).existsSync(), isTrue);

    final pars = await anexos.paragrafos(a);
    final i = pars.indexWhere((x) => x.texto.contains('extensão'));
    expect(pars[i].texto, contains('Engenharia Mecânica, que inclui'));
    final ini = pars[i].texto.indexOf('10%');
    final m = AnexosProcessoService.novaMarcacao(
      paragrafo: i,
      textoParagrafo: pars[i].texto,
      inicio: ini,
      fim: ini + '10% da carga horária'.length,
      cor: 'verde',
      comentario: 'Conferir a Resolução de extensão.',
    );
    await anexos.salvarMarcacao(a.id, m);
    expect(anexos.anexos.single.marcacoes.single.texto, '10% da carga horária');

    // Outro processo não vê os anexos; voltar recupera tudo.
    final outro = await s.criar(nome: 'Outro');
    await s.abrir(outro.id);
    expect(anexos.anexos, isEmpty);
    await s.abrir(proc.id);
    expect(anexos.anexos.single.marcacoes.single.cor, 'verde');

    // Sem o cache em memória, relê do cache em disco.
    final novoServico = AnexosProcessoService(
      pasta: () async => guardados.path,
    );
    await novoServico.usarProcesso(proc.id);
    expect(
      (await novoServico.paragrafos(novoServico.anexos.single))[i].texto,
      pars[i].texto,
    );

    // Copiar o processo leva os anexos e as marcações.
    final copia = await s.duplicar(proc.id);
    await s.abrir(copia.id);
    expect(anexos.anexos.single.marcacoes, hasLength(1));
    await anexos.excluirMarcacao(anexos.anexos.single.id, m.id);
    await s.abrir(proc.id);
    expect(anexos.anexos.single.marcacoes, hasLength(1));

    await anexos.remover(a.id);
    expect(anexos.anexos, isEmpty);
  });

  test('DOCX e formato não suportado', () async {
    final anexos = AnexosProcessoService(pasta: () async => guardados.path);
    await anexos.usarProcesso('x');
    final docx = File(p.join(dir.path, 'parecer.docx'))
      ..writeAsBytesSync(_docx(['Primeiro parágrafo.', 'Segundo parágrafo.']));
    final a = await anexos.anexar(docx.path);
    expect((await anexos.paragrafos(a)).map((x) => x.texto), [
      'Primeiro parágrafo.',
      'Segundo parágrafo.',
    ]);
    final doc = File(p.join(dir.path, 'antigo.doc'))..writeAsStringSync('x');
    expect(
      () => anexos.anexar(doc.path),
      throwsA(
        isA<CommandException>().having(
          (e) => e.code,
          'code',
          'formato_nao_suportado',
        ),
      ),
    );
  });

  test('PDF: páginas no texto e aviso sem texto', () async {
    try {
      await Process.run('pdftotext', ['-v']);
    } on ProcessException {
      return; // Poppler ausente.
    }
    final anexos = AnexosProcessoService(pasta: () async => guardados.path);
    await anexos.usarProcesso('x');
    final pdf = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Text('First page text here.')))
      ..addPage(pw.Page(build: (_) => pw.Text('Second page text here.')));
    final f = File(p.join(dir.path, 'doc.pdf'))
      ..writeAsBytesSync(await pdf.save());
    final a = await anexos.anexar(f.path);
    expect(a.paginas, 2);
    final pars = await anexos.paragrafos(a);
    expect(pars.last.pagina, 2);
    expect(
      AnexosProcessoService.local(pars, pars.length - 1),
      startsWith('p. 2'),
    );

    final vazio = File(p.join(dir.path, 'vazio.pdf'))
      ..writeAsBytesSync(
        await (pw.Document()..addPage(pw.Page(build: (_) => pw.SizedBox())))
            .save(),
      );
    final b = await anexos.anexar(vazio.path);
    expect(b.aviso, contains('OCR'));
  });

  test('destaques: segmentos do parágrafo pelas marcações', () {
    MarcacaoAnexo m(String id, int a, int b) =>
        MarcacaoAnexo(id: id, paragrafo: 0, inicio: a, fim: b, texto: '');
    final segs = segmentarParagrafo('abcdefghij', [m('1', 2, 5), m('2', 4, 7)]);
    expect(segs.map((s) => s.texto), ['ab', 'cd', 'efg', 'hij']);
    expect(segs.map((s) => s.marcacao?.id), [null, '1', '2', null]);
    expect(segmentarParagrafo('abc', const []).single.texto, 'abc');
  });

  test('explicação da IA: termos, pontos e fontes conferidas', () {
    const fontes = [
      FonteConsulta(
        id: 'F1',
        arquivo: 'res_extensao.pdf',
        localizacao: 'Art. 4',
        texto:
            'Art. 4º As atividades de extensão comporão, no mínimo, 10% '
            'da carga horária total do curso.',
      ),
    ];
    final e = ConsultaTrecho.lerExplicacao(
      '''
{"resposta": "O PPC reserva 10% da carga horária para extensão.",
 "pontos_atencao": ["Conferir se é no mínimo 10%"],
 "termos": [{"termo": "PPC", "significado": "Projeto Pedagógico do Curso"}],
 "evidencias": [
   {"fonte": "F1", "citacao": "no mínimo, 10% da carga horária total do curso", "relacao": "apoia"},
   {"fonte": "F5", "citacao": "inventada"}
 ],
 "comentario": "O ofício cumpre o mínimo de 10% de extensão (Art. 4)."}''',
      fontes,
    );
    expect(e.termos.single.termo, 'PPC');
    expect(e.evidencias.single.citacaoConfirmada, isTrue);
    expect(e.descartadas, 1);
    expect(e.comentario, contains('10%'));
    expect(e.resumo, contains('Pontos de atenção'));
    expect(ConsultaTrecho.lerComentario('"Texto da nota."'), 'Texto da nota.');
  });

  test('comandos do agente: listar, ler e marcar', () async {
    final s = novo();
    final parecer = s.parecer;
    final cmds = {
      for (final c in elaboraRelatoCommands(parecer.arvore, parecer, s))
        c.id: c,
    };
    Future<CommandResult> run(String id, Map<String, dynamic> input) =>
        cmds[id]!.run(input, CommandOrigin.test);

    await s.garantirAtivo();
    final origem = File(p.join(dir.path, 'oficio.txt'))
      ..writeAsStringSync(_oficio);
    final a = await parecer.anexos.anexar(origem.path);

    final lista = await run('parecer.anexos.listar', {});
    expect((lista.data['anexos'] as List).single['id'], a.id);
    final lido = await run('parecer.anexos.ler', {'anexo': a.id});
    final pars = lido.data['paragrafos'] as List;
    final alvo =
        pars.firstWhere((x) => '${(x as Map)['texto']}'.contains('Colegiado'))
            as Map;
    await run('parecer.anexos.marcar', {
      'anexo': a.id,
      'paragrafo': alvo['indice'],
      'trecho': 'aprovada pelo Colegiado',
      'comentario': 'Ver a ata.',
    });
    expect(
      parecer.anexos.anexos.single.marcacoes.single.comentario,
      'Ver a ata.',
    );
    expect(
      () => run('parecer.anexos.marcar', {
        'anexo': a.id,
        'paragrafo': alvo['indice'],
        'trecho': 'não existe',
      }),
      throwsA(isA<CommandException>()),
    );
  });
}
