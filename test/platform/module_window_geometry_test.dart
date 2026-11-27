import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gestor_ufu/platform/shell/module_window_geometry.dart';

void main() {
  test('histórico cabe na área útil de uma tela com escala de 125%', () {
    const workArea = Rect.fromLTWH(0, 0, 1536, 816);
    final bounds = moduleWindowBounds(const Size(1580, 920), workArea);
    expect(bounds, const Rect.fromLTWH(16, 16, 1504, 784));
  });

  test('preserva o tamanho em telas grandes e respeita outro monitor', () {
    const workArea = Rect.fromLTWH(-2560, 40, 2560, 1400);
    final bounds = moduleWindowBounds(const Size(1580, 920), workArea);
    expect(bounds.size, const Size(1580, 920));
    expect(bounds.center, workArea.center);
  });

  test('tamanho mínimo não força a janela para fora de uma tela pequena', () {
    final bounds = moduleWindowBounds(
      const Size(1580, 920),
      const Rect.fromLTWH(0, 0, 960, 600),
    );
    expect(
      moduleWindowMinimumSize(const Size(980, 650), bounds.size),
      bounds.size,
    );
  });
}
