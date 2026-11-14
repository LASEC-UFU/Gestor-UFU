import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gestor_ufu/data/services/ai_agent/agent_data_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final host = AgentDataHost.instance;

  Future<Map<String, dynamic>> run(String name, Map<String, dynamic> input) async =>
      Map<String, dynamic>.from(jsonDecode(await host.runTool(name, input)) as Map);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'diario': jsonEncode({
        'draftEntries': {'05/03/2026 -T': 'Aula 1'},
        'savedDiaries': [],
      }),
      'moodle_credential': 'segredo',
    });
    while (host.undoCount > 0) {
      await host.undoLast();
    }
  });

  test('patch_json altera trechos e desfazer restaura o valor', () async {
    final result = await run('patch_json', {
      'key': 'diario',
      'operations': [
        {
          'op': 'set',
          'path': ['draftEntries', '12/03/2026 -T'],
          'value': 'Aula 2',
        },
        {
          'op': 'append',
          'path': ['savedDiaries'],
          'value': {'id': 'x', 'name': 'Turma A', 'entries': {}},
        },
      ],
    });
    expect(result['ok'], isTrue);

    final read = await run('read_key', {
      'key': 'diario',
      'path': ['draftEntries'],
    });
    expect(jsonDecode(read['content'] as String), {
      '05/03/2026 -T': 'Aula 1',
      '12/03/2026 -T': 'Aula 2',
    });

    await host.undoLast();
    final prefs = await SharedPreferences.getInstance();
    final restored = jsonDecode(prefs.getString('diario')!) as Map;
    expect((restored['draftEntries'] as Map).length, 1);
    expect(restored['savedDiaries'], isEmpty);
  });

  test('credenciais ficam inacessíveis', () async {
    final read = await run('read_key', {'key': 'moodle_credential'});
    expect(read['error'], contains('protegida'));
    final keys = await host.runTool('list_keys', {});
    expect(keys, isNot(contains('moodle_credential')));
  });

  test('term_storage_key segue o formato usado pelas páginas', () async {
    final result = await run('term_storage_key', {
      'prefix': 'preenche_diarios_period_data_v1_',
      'term': '2º semestre de 2026',
    });
    final token = base64Url
        .encode(utf8.encode('2º semestre de 2026'))
        .replaceAll('=', '');
    expect(result['key'], 'preenche_diarios_period_data_v1_$token');
  });

  test('write_key cria chave nova e desfazer a remove', () async {
    await run('write_key', {
      'key': 'nova',
      'value': [1, 2],
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('nova'), '[1,2]');
    await host.undoLast();
    expect(prefs.containsKey('nova'), isFalse);
  });
}
