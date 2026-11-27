import 'dart:math' as math;
import 'dart:ui';

/// Mantém a janela e sua barra de título dentro da área útil do monitor.
Rect moduleWindowBounds(Size requested, Rect workArea) {
  final size = Size(
    math.min(requested.width, math.max(1, workArea.width - 32)),
    math.min(requested.height, math.max(1, workArea.height - 32)),
  );
  return Rect.fromCenter(
    center: workArea.center,
    width: size.width,
    height: size.height,
  );
}

Size moduleWindowMinimumSize(Size requested, Size available) => Size(
  math.min(requested.width, available.width),
  math.min(requested.height, available.height),
);
