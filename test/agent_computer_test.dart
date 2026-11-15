@TestOn('windows')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:gestor_ufu/data/services/ai_agent/agent_computer.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_tools.dart';

/// Só observa (não move o mouse nem digita): captura, cursor, janelas e
/// validações das ações.
void main() {
  final computer = AgentComputer.instance;

  test('captura a tela reduzida em JPEG com tamanho e mouse', () async {
    final shot = await computer.run('computer_screenshot', {});
    final bytes = base64Decode(shot['image_base64']! as String);
    final image = img.decodeJpg(bytes)!;
    expect(image.width, shot['largura']);
    expect(image.height, shot['altura']);
    expect(image.width, lessThanOrEqualTo(AgentComputer.maxWidth));
    expect(image.height, lessThanOrEqualTo(AgentComputer.maxHeight));
    final mouse = shot['mouse'];
    if (mouse is Map) {
      expect(mouse['x'], inInclusiveRange(0, image.width));
      expect(mouse['y'], inInclusiveRange(0, image.height));
    } else {
      expect(mouse, 'em outro monitor');
    }
    expect((shot['monitores']! as List).first, containsPair('principal', true));
  });

  test('lista as janelas visíveis', () async {
    final result = await computer.run('computer_windows', {});
    expect(result['janelas'], isA<List>());
  });

  test('ações inválidas são recusadas antes de agir', () async {
    expect(
      () => computer.run('computer_key', {'keys': 'teclaInexistente'}),
      throwsA(isA<StateError>()),
    );
    expect(
      () => computer.run('computer_click', {'x': -50, 'y': -50}),
      throwsA(isA<StateError>()),
    );
    expect(
      () => computer.run('computer_type', {'text': ''}),
      throwsA(isA<StateError>()),
    );
  });

  test('toda ação de controle tem especificação para o agente', () {
    final names = {for (final t in agentTools) t.name};
    expect(names, containsAll(AgentComputer.actions));
    expect(names, contains('computer_screenshot'));
  });
}
