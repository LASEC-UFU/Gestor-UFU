import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/modules/progressao/application/progressao_commands.dart';
import 'package:gestor_ufu/modules/progressao/application/progressao_service.dart';
import 'package:gestor_ufu/modules/progressao/data/progressao_store.dart';
import 'package:gestor_ufu/platform/command/module_command.dart';

void main() {
  late Directory dir;
  late ProgressaoService service;
  late Map<String, ModuleCommand> commands;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('progressao_cmd');
    service = ProgressaoService(ProgressaoStore());
    commands = {for (final c in progressaoCommands(service)) c.id: c};
  });

  tearDown(() => dir.delete(recursive: true));

  Future<CommandResult> run(String id, Map<String, dynamic> input) =>
      commands[id]!.run(input, CommandOrigin.test);

  test('cria processo, lança item com comprovante e lista', () async {
    final created = await run('progressao.criar', {
      'pastaComprovantes': dir.path,
      'docente': 'Maria',
    });
    final id = created.data['processoId'] as String;
    final comprovante = File('${dir.path}/certificado.pdf')
      ..writeAsStringSync('%PDF-1.4');
    final lancado = await run('progressao.lancar', {
      'processoId': id,
      'item': 1,
      'quantidade': 60,
      'periodo': '2024/01',
      'descricao': 'Disciplina X',
      'comprovante': comprovante.path,
    });
    expect(lancado.ok, isTrue);
    final listed = await run('progressao.listar', {'processoId': id});
    final itens = (listed.data['itens'] as List).cast<Map>();
    expect(itens.single['item'], 1);
    expect('${itens.single['comprovante']}', contains('A1.1'));
    // O comprovante foi copiado para a pasta do processo.
    expect(
      Directory(dir.path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('A1.1')),
      isNotEmpty,
    );
  });

  test('rejeita item inexistente do Anexo 1 com código estável', () async {
    final created = await run('progressao.criar', {
      'pastaComprovantes': dir.path,
    });
    expect(
      () => run('progressao.lancar', {
        'processoId': created.data['processoId'],
        'item': 999,
      }),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'code', 'item_invalido'),
      ),
    );
  });

  test('busca itens do Anexo 1 por texto e tabela', () async {
    final result = await run('progressao.itensAnexo1', {'tabela': 'A1.1'});
    final itens = (result.data['itens'] as List).cast<Map>();
    expect(itens, isNotEmpty);
    expect(itens.every((i) => i['tabela'] == 'A1.1'), isTrue);
  });

  test(
    'montagem do SEI fica disponível ao agente com aprovação obrigatória',
    () {
      final command = commands['progressao.montarProcessoSei']!;
      expect(command.approval, CommandApproval.required);
      expect(command.mutates, isTrue);
      expect(command.inputSchema['required'], contains('processoId'));
    },
  );

  test('gera o PDF, duplica e excluir exige aprovação', () async {
    final created = await run('progressao.criar', {
      'pastaComprovantes': dir.path,
      'docente': 'João',
    });
    final id = created.data['processoId'] as String;
    final pdf = await run('progressao.gerarPdf', {
      'processoId': id,
      'path': '${dir.path}/relatorio',
    });
    expect(File(pdf.data['path'] as String).existsSync(), isTrue);
    final copy = await run('progressao.duplicar', {'processoId': id});
    expect(copy.data['processoId'], isNot(id));
    expect(commands['progressao.excluir']!.approval, CommandApproval.required);
    await run('progressao.excluir', {'processoId': id});
    final listed = await run('progressao.listar', {});
    expect((listed.data['processos'] as List), hasLength(1));
  });

  test('enviar ao SEI sem o Edge aberto falha com código legível', () async {
    final created = await run('progressao.criar', {
      'pastaComprovantes': dir.path,
    });
    final id = created.data['processoId'] as String;
    final comprovante = File('${dir.path}/c.pdf')..writeAsStringSync('%PDF');
    await run('progressao.lancar', {
      'processoId': id,
      'item': 1,
      'comprovante': comprovante.path,
    });
    expect(
      () => run('progressao.enviarComprovantesSei', {'processoId': id}),
      throwsA(
        isA<CommandException>().having((e) => e.code, 'code', 'sei_fechado'),
      ),
    );
  });
}
