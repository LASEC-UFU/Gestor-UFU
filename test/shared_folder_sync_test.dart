import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import 'package:gestor_ufu/data/services/shared_folder/folder_sync_engine.dart';
import 'package:gestor_ufu/data/services/shared_folder/shared_files_mirror.dart';
import 'package:gestor_ufu/data/services/shared_preferences_sync_service.dart';
import 'package:gestor_ufu/orchestrator/application/ai_memory.dart';
import 'package:gestor_ufu/orchestrator/application/ai_memory_share.dart';
import 'package:gestor_ufu/data/services/shared_folder/shared_folder_crypto.dart';

/// Banco local de um "computador" simulado.
class MemoryPrefs implements PrefsBackend {
  final values = <String, Object?>{};

  @override
  Future<Map<String, Object?>> readAll() async => Map.of(values);

  @override
  Future<void> apply(Map<String, Object?> set, Set<String> remove) async {
    values.addAll(set);
    for (final key in remove) {
      values.remove(key);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String shared;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pasta');
    shared = p.join(root.path, 'GoogleDrive', 'GestorUFU-banco');
  });

  tearDown(() => root.delete(recursive: true));

  Future<(FolderSyncEngine, MemoryPrefs)> machine(
    String name, {
    bool create = false,
  }) async {
    final crypto = await SharedFolderCrypto.open(
      shared,
      'senha-forte-123',
      create: create,
    );
    final prefs = MemoryPrefs();
    return (
      FolderSyncEngine(
        crypto: crypto,
        backend: prefs,
        stateDir: p.join(root.path, 'local-$name'),
        machine: name,
      ),
      prefs,
    );
  }

  Future<void> touch() =>
      Future<void>.delayed(const Duration(milliseconds: 1100));

  test('grupos por módulo, conversa e rodada', () {
    expect(syncGroupFor('ajusta_horarios_cursos'), 'ajusta-horarios');
    expect(syncGroupFor('ajusta_horarios_periodo_letivo'), 'geral');
    expect(syncGroupFor('config_moodle_data'), 'moodle');
    expect(syncGroupFor('preenche_diarios_entries_v1'), 'diario');
    expect(syncGroupFor('student_equivalencies.blocks.v1'), 'equivalencia');
    expect(syncGroupFor('inserir_documentos_sei.projects.v1'), 'acoes-na-web');
    expect(
      syncGroupFor('gestor_ufu_agente_conversa_v1_abc-1'),
      'agente-conversa-abc-1',
    );
    expect(syncGroupFor('orquestrador.run.r1'), 'orquestrador-rodada-r1');
    expect(syncGroupFor('orquestrador.events.r1'), 'orquestrador-rodada-r1');
    expect(syncGroupFor('orquestrador.config.v1'), 'orquestrador');
    expect(syncGroupFor('qualquer_outra'), 'geral');
  });

  test('senha errada é recusada e os dados ficam cifrados', () async {
    final (a, prefsA) = await machine('A', create: true);
    prefsA.values['progressao_docente.v1'] = 'segredo do professor';
    await a.publishAll();
    expect(
      () => SharedFolderCrypto.open(shared, 'outra-senha'),
      throwsA(isA<SharedFolderException>()),
    );
    final file = File(p.join(shared, 'dados', 'progressao.gdb'));
    expect(file.readAsStringSync(), isNot(contains('segredo')));
  });

  test('alteração de um computador chega ao outro, por grupo', () async {
    final (a, prefsA) = await machine('A', create: true);
    prefsA.values
      ..['ajusta_horarios_cursos'] = '{"1":"CA"}'
      ..['config_moodle_data'] = 'moodle'
      ..['gestor_ufu_theme_light'] = true;
    await a.publishAll();

    final (b, prefsB) = await machine('B');
    await b.adoptAll();
    expect(prefsB.values, prefsA.values);

    // B muda só o Moodle: só o arquivo do Moodle é reenviado.
    await touch();
    prefsB.values['config_moodle_data'] = 'moodle 2';
    final sent = await b.sync();
    expect(sent.uploaded, {'moodle'});

    final received = await a.sync();
    expect(received.changedKeys, {'config_moodle_data'});
    expect(prefsA.values['config_moodle_data'], 'moodle 2');

    // Nada mudou: nenhuma leitura nem envio.
    final idle = await a.sync();
    expect(idle.uploaded, isEmpty);
    expect(idle.changedKeys, isEmpty);
  });

  test('módulos diferentes nos dois lados: sem conflito', () async {
    final (a, prefsA) = await machine('A', create: true);
    prefsA.values
      ..['ajusta_horarios_cursos'] = 'v1'
      ..['config_moodle_data'] = 'v1';
    await a.publishAll();
    final (b, prefsB) = await machine('B');
    await b.adoptAll();
    await touch();
    prefsA.values['ajusta_horarios_cursos'] = 'A mudou';
    prefsB.values['config_moodle_data'] = 'B mudou';
    await a.sync();
    await touch();
    await b.sync();
    await a.sync();
    expect(prefsA.values['config_moodle_data'], 'B mudou');
    expect(prefsB.values['ajusta_horarios_cursos'], 'A mudou');
  });

  test('mesma chave alterada nos dois: conflito só daquele grupo', () async {
    final (a, prefsA) = await machine('A', create: true);
    prefsA.values
      ..['progressao_docente.v1'] = 'v1'
      ..['progressao_outra'] = 'x'
      ..['config_moodle_data'] = 'v1';
    await a.publishAll();
    final (b, prefsB) = await machine('B');
    await b.adoptAll();
    await touch();
    prefsA.values['progressao_docente.v1'] = 'de A';
    prefsB.values['progressao_docente.v1'] = 'de B';
    prefsB.values['config_moodle_data'] = 'B mudou';
    await a.sync();
    await touch();
    final result = await b.sync();
    expect(result.conflicts, {'progressao'});
    // O Moodle seguiu normalmente.
    await a.sync();
    expect(prefsA.values['config_moodle_data'], 'B mudou');
    // Resolver: B fica com a versão da pasta.
    await b.resolve('progressao', useShared: true);
    expect(prefsB.values['progressao_docente.v1'], 'de A');
    expect(b.conflicts, isEmpty);
  });

  test('mesmo grupo, chaves diferentes: junção por chave', () async {
    final (a, prefsA) = await machine('A', create: true);
    prefsA.values
      ..['ajusta_horarios_cursos'] = 'c1'
      ..['ajusta_horarios_salas_cadastradas'] = ['s1'];
    await a.publishAll();
    final (b, prefsB) = await machine('B');
    await b.adoptAll();
    await touch();
    prefsA.values['ajusta_horarios_cursos'] = 'c2';
    prefsB.values['ajusta_horarios_salas_cadastradas'] = ['s1', 's2'];
    await a.sync();
    await touch();
    final merged = await b.sync();
    expect(merged.conflicts, isEmpty);
    expect(prefsB.values['ajusta_horarios_cursos'], 'c2');
    await a.sync();
    expect(prefsA.values['ajusta_horarios_salas_cadastradas'], ['s1', 's2']);
  });

  test(
    'cópia de conflito do Drive é ignorada; arquivo apagado volta',
    () async {
      final (a, prefsA) = await machine('A', create: true);
      prefsA.values['config_moodle_data'] = 'v1';
      await a.publishAll();
      final original = File(p.join(shared, 'dados', 'moodle.gdb'));
      original.copySync(p.join(shared, 'dados', 'moodle (1).gdb'));
      final (b, prefsB) = await machine('B');
      await b.adoptAll();
      expect(prefsB.values['config_moodle_data'], 'v1');
      original.deleteSync();
      final result = await a.sync();
      expect(result.uploaded, {'moodle'});
      expect(original.existsSync(), isTrue);
    },
  );

  test('migração: base do banco antigo evita perder edições', () async {
    // A migrou com o retrato S; depois B (ainda no arquivo único) editou.
    final snapshot = <String, Object?>{
      'config_moodle_data': 'v1',
      'ajusta_horarios_cursos': 'c1',
    };
    final (a, prefsA) = await machine('A', create: true);
    prefsA.values.addAll(snapshot);
    await a.publishAll();
    await touch();
    prefsA.values['config_moodle_data'] = 'A depois';
    await a.sync();

    final (b, prefsB) = await machine('B');
    prefsB.values
      ..addAll(snapshot)
      ..['ajusta_horarios_cursos'] = 'B depois';
    await b.seedBaseline(snapshot);
    final result = await b.sync();
    expect(result.conflicts, isEmpty);
    expect(prefsB.values['config_moodle_data'], 'A depois');
    expect(prefsB.values['ajusta_horarios_cursos'], 'B depois');
    await a.sync();
    expect(prefsA.values['ajusta_horarios_cursos'], 'B depois');
  });

  test('bytes cifrados (arquivos e backups) com cabeçalho legível', () async {
    final crypto = await SharedFolderCrypto.open(
      shared,
      'senha-forte-123',
      create: true,
    );
    final data = utf8.encode('conteúdo do relatório');
    final box = await crypto.encryptBytes(data, header: {'nome': 'r.pdf'});
    expect(SharedFolderCrypto.readHeader(box)['nome'], 'r.pdf');
    expect(
      utf8.decode(await crypto.decryptBytes(box)),
      'conteúdo do relatório',
    );
  });

  test('arquivos gerados: chegam, voltam, conflito guarda as duas', () async {
    final crypto = await SharedFolderCrypto.open(
      shared,
      'senha-forte-123',
      create: true,
    );
    final sync = SharedPreferencesSyncService();
    final localA = Directory(p.join(root.path, 'docsA'))..createSync();
    final localB = Directory(p.join(root.path, 'docsB'))..createSync();
    final mirrorA = SharedFilesMirror(sync, localRoot: localA.path);
    final mirrorB = SharedFilesMirror(sync, localRoot: localB.path);
    Future<void> runA() => mirrorA.syncOnce(
      crypto: crypto,
      stateDir: p.join(root.path, 'estadoA'),
    );
    Future<void> runB() => mirrorB.syncOnce(
      crypto: crypto,
      stateDir: p.join(root.path, 'estadoB'),
    );

    final report = File(p.join(localA.path, 'sei', 'relatorio.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('versão A');
    await runA();
    final remote = File(p.join(shared, 'arquivos', 'sei', 'relatorio.txt.gfa'));
    expect(remote.readAsBytesSync(), isNot(contains(utf8.encode('versão A'))));
    await runB();
    final onB = File(p.join(localB.path, 'sei', 'relatorio.txt'));
    expect(onB.readAsStringSync(), 'versão A');

    // B altera; A recebe.
    await touch();
    onB.writeAsStringSync('versão B');
    await runB();
    await runA();
    expect(report.readAsStringSync(), 'versão B');

    // Os dois alteram: A fica com a sua e ganha a cópia de B.
    await touch();
    onB.writeAsStringSync('B de novo');
    report.writeAsStringSync('A de novo');
    await runB();
    await runA();
    expect(report.readAsStringSync(), 'A de novo');
    final copies = Directory(p.join(localA.path, 'sei'))
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.contains('(de '));
    expect(copies, hasLength(1));
    expect(
      File(p.join(localA.path, 'sei', copies.single)).readAsStringSync(),
      'B de novo',
    );

    // Apagar em A não apaga em B nem baixa de novo em A.
    await runB();
    report.deleteSync();
    await runA();
    expect(report.existsSync(), isFalse);
    await runB();
    expect(onB.existsSync(), isTrue);
  });

  test('serviço: arquivo antigo migra para a pasta; outro PC entra', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({
      'config_moodle_data': 'dados do moodle',
      'ajusta_horarios_cursos': '{"1":"CA"}',
    });
    final legacy = p.join(root.path, 'GoogleDrive', 'gestor_ufu_banco.json');
    final pcA = SharedPreferencesSyncService();
    await pcA.connectToFile(
      filePath: legacy,
      password: 'senha-forte-123',
      useSharedFile: false,
    );
    final folder = p.join(root.path, 'GoogleDrive', 'GestorUFU-banco');
    expect(pcA.isFolder, isTrue);
    expect(pcA.filePath, folder);
    expect(File(legacy).existsSync(), isTrue, reason: 'antigo fica de backup');
    expect(SharedFolderCrypto.hasManifest(folder), isTrue);
    expect(File(p.join(folder, 'dados', 'moodle.gdb')).existsSync(), isTrue);
    expect(
      File(p.join(folder, 'dados', 'ajusta-horarios.gdb')).existsSync(),
      isTrue,
    );
    expect(
      File(
        p.join(folder, SharedPreferencesSyncService.migrationBase),
      ).existsSync(),
      isTrue,
    );
    pcA.dispose();

    // Outro computador (banco local vazio) entra pela pasta.
    SharedPreferences.setMockInitialValues({});
    final pcB = SharedPreferencesSyncService();
    final received = <String>{};
    pcB.onRemoteChanged = (keys) async => received.addAll(keys);
    await pcB.connectToFolder(
      folder: folder,
      password: 'senha-forte-123',
      useShared: true,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('config_moodle_data'), 'dados do moodle');
    expect(
      received,
      containsAll(['config_moodle_data', 'ajusta_horarios_cursos']),
    );
    await expectLater(
      () => pcB.connectToFolder(
        folder: folder,
        password: 'senha-errada-123',
        useShared: true,
      ),
      throwsA(isA<SharedFolderException>()),
    );
    pcB.dispose();
  });

  test(
    'memória: posse recente bloqueia, posse abandonada é assumida',
    () async {
      final crypto = await SharedFolderCrypto.open(
        shared,
        'senha-forte-123',
        create: true,
      );
      final lease = File(p.join(shared, AiMemoryShare.dirName, 'posse.json'))
        ..createSync(recursive: true);
      void holder(Duration ago) => lease.writeAsStringSync(
        jsonEncode({
          'computador': 'OUTRO-PC',
          'batida': DateTime.now().toUtc().subtract(ago).toIso8601String(),
        }),
      );
      final runtime = AiMemoryRuntime(root: p.join(root.path, 'ai'));

      holder(const Duration(seconds: 30));
      final busy = AiMemoryShare(runtime, () async => crypto, machine: 'ESTE');
      await busy.beforeStart();
      expect(busy.owner, isFalse);
      expect(busy.status, contains('OUTRO-PC'));

      holder(const Duration(minutes: 5));
      final free = AiMemoryShare(runtime, () async => crypto, machine: 'ESTE');
      await free.beforeStart();
      expect(free.owner, isTrue);
      expect(jsonDecode(lease.readAsStringSync())['computador'], 'ESTE');
      await free.release();
      expect(lease.existsSync(), isFalse);

      final off = AiMemoryShare(runtime, () async => null, machine: 'ESTE');
      await off.beforeStart();
      expect(off.owner, isFalse);
    },
  );
}
