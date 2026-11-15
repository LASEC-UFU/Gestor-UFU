import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart';

/// Controle do computador pelo Agente de IA (como o "computer use" do VS
/// Code): ver a tela, mover o mouse, clicar, arrastar, rolar, digitar e
/// usar atalhos de teclado. Roda na janela principal (Windows).
///
/// Coordenadas: sempre no espaço da imagem de `computer_screenshot` (a tela
/// inteira, reduzida para no máximo [maxWidth]×[maxHeight]); a conversão
/// para pixels reais é feita aqui.
///
/// Parada de emergência: o usuário leva o mouse ao canto superior esquerdo
/// da tela e a próxima ação do agente é recusada.
class AgentComputer {
  AgentComputer._();

  static final instance = AgentComputer._();

  static const maxWidth = 1366;
  static const _wheelDelta = 120;
  static const maxHeight = 900;

  /// Ferramentas que agem no computador (as demais só observam).
  static const actions = {
    'computer_click',
    'computer_move',
    'computer_drag',
    'computer_scroll',
    'computer_type',
    'computer_key',
    'computer_focus_window',
  };

  Future<Map<String, Object?>> run(
    String name,
    Map<String, dynamic> input,
  ) async {
    if (!Platform.isWindows) {
      throw StateError('O controle do computador só funciona no Windows.');
    }
    // Pixels reais em todos os monitores (o app já é PerMonitorV2; garante
    // o mesmo nesta thread).
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (actions.contains(name)) _checkEmergencyStop();
    final result = switch (name) {
      'computer_screenshot' => await screenshot(input['monitor']),
      'computer_cursor' => _cursor(),
      'computer_windows' => _windows(),
      'computer_click' => await _click(input),
      'computer_move' => _move(input),
      'computer_drag' => await _drag(input),
      'computer_scroll' => _scroll(input),
      'computer_type' => _type(input),
      'computer_key' => _key(input),
      'computer_focus_window' => _focusWindow(input),
      _ => throw StateError('Ferramenta desconhecida: $name.'),
    };
    if (actions.contains(name) && input['screenshot'] != false) {
      // Mostra o resultado da ação (o agente "vê" o que aconteceu).
      await Future<void>.delayed(const Duration(milliseconds: 450));
      return {...result, ...await screenshot()};
    }
    return result;
  }

  // ------------------------------------------------------------ Geometria

  /// Área da última captura (pixels reais): as coordenadas das ações valem
  /// para ela. Antes da primeira captura, o monitor principal.
  _Rect? _region;

  /// Monitores (pixels reais), o principal primeiro.
  List<({_Rect rect, bool primary})> get _monitors {
    final found = <({_Rect rect, bool primary})>[];
    final callback = NativeCallable<MONITORENUMPROC>.isolateLocal((
      int monitor,
      int _,
      Pointer _,
      int _,
    ) {
      final info = calloc<MONITORINFO>()..ref.cbSize = sizeOf<MONITORINFO>();
      try {
        if (GetMonitorInfo(monitor, info) != 0) {
          final r = info.ref.rcMonitor;
          found.add((
            rect: _Rect(r.left, r.top, r.right - r.left, r.bottom - r.top),
            primary: info.ref.dwFlags & MONITORINFOF_PRIMARY != 0,
          ));
        }
      } finally {
        calloc.free(info);
      }
      return 1;
    }, exceptionalReturn: 0);
    try {
      EnumDisplayMonitors(NULL, nullptr, callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    found.sort((a, b) => a.primary == b.primary ? 0 : (a.primary ? -1 : 1));
    if (found.isEmpty) {
      found.add((
        rect: _Rect(
          0,
          0,
          GetSystemMetrics(SM_CXSCREEN),
          GetSystemMetrics(SM_CYSCREEN),
        ),
        primary: true,
      ));
    }
    return found;
  }

  /// Tela virtual (todos os monitores).
  _Rect get _virtual => _Rect(
    GetSystemMetrics(SM_XVIRTUALSCREEN),
    GetSystemMetrics(SM_YVIRTUALSCREEN),
    GetSystemMetrics(SM_CXVIRTUALSCREEN),
    GetSystemMetrics(SM_CYVIRTUALSCREEN),
  );

  _Rect get _current => _region ?? _monitors.first.rect;

  static double _scaleFor(_Rect r) =>
      math.min(1.0, math.min(maxWidth / r.width, maxHeight / r.height));

  /// Ponto da imagem → pixel real da tela.
  (int, int) _toScreen(Object? x, Object? y) {
    if (x is! num || y is! num) {
      throw StateError('Informe x e y (coordenadas da captura de tela).');
    }
    final r = _current;
    final scale = _scaleFor(r);
    final sx = r.left + (x / scale).round();
    final sy = r.top + (y / scale).round();
    if (x < 0 || y < 0 || sx >= r.left + r.width || sy >= r.top + r.height) {
      throw StateError(
        'Ponto ($x, $y) fora da última captura de tela. Tire uma nova com '
        'computer_screenshot.',
      );
    }
    return (sx, sy);
  }

  /// Pixel real → ponto da imagem (null se fora da última captura).
  Map<String, int>? _toImage(int x, int y) {
    final r = _current;
    if (x < r.left ||
        y < r.top ||
        x > r.left + r.width ||
        y > r.top + r.height) {
      return null;
    }
    final scale = _scaleFor(r);
    return {
      'x': ((x - r.left) * scale).round(),
      'y': ((y - r.top) * scale).round(),
    };
  }

  (int, int) get _cursorPos {
    final point = calloc<POINT>();
    try {
      GetCursorPos(point);
      return (point.ref.x, point.ref.y);
    } finally {
      calloc.free(point);
    }
  }

  void _checkEmergencyStop() {
    final (x, y) = _cursorPos;
    for (final m in _monitors) {
      if ((x - m.rect.left).abs() <= 1 && (y - m.rect.top).abs() <= 1) {
        throw StateError(
          'Parada de emergência: o usuário levou o mouse ao canto superior '
          'esquerdo da tela. Não continue controlando o computador; pergunte '
          'ao usuário como prosseguir.',
        );
      }
    }
  }

  // ------------------------------------------------------------ Captura

  /// Captura um monitor (padrão: o da última captura, senão o principal)
  /// ou todos (`monitor: "todos"`), reduzida, em JPEG.
  Future<Map<String, Object?>> screenshot([Object? monitor]) async {
    final monitors = _monitors;
    if (monitor == 'todos' || monitor == 'all') {
      _region = _virtual;
    } else if (monitor is num) {
      final index = monitor.toInt();
      if (index < 0 || index >= monitors.length) {
        throw StateError(
          'Monitor $index não existe (há ${monitors.length}: 0 = principal).',
        );
      }
      _region = monitors[index].rect;
    } else {
      _region ??= monitors.first.rect;
    }
    final r = _region!;
    final pixels = _grab(r.left, r.top, r.width, r.height);
    final scale = _scaleFor(r);
    final targetW = (r.width * scale).round();
    final targetH = (r.height * scale).round();
    final jpeg = await Isolate.run(
      () => _encode(pixels, r.width, r.height, targetW, targetH),
    );
    final (cx, cy) = _cursorPos;
    return {
      'image_base64': base64Encode(jpeg),
      'image_mime': 'image/jpeg',
      'largura': targetW,
      'altura': targetH,
      'mouse': _toImage(cx, cy) ?? 'em outro monitor',
      'monitores': [
        for (var i = 0; i < monitors.length; i++)
          {
            'monitor': i,
            if (monitors[i].primary) 'principal': true,
            'resolucao': '${monitors[i].rect.width}x${monitors[i].rect.height}',
            if (monitors[i].rect == r) 'nesta_captura': true,
          },
      ],
      'coordenadas':
          'Use x/y desta imagem (0,0 = canto superior esquerdo) nas ações '
          'computer_*; para outro monitor, capture com monitor: <número>.',
    };
  }

  /// Pixels BGRA da área (GDI: inclui as janelas do Gestor e dos demais
  /// programas como aparecem na tela).
  Uint8List _grab(int left, int top, int width, int height) {
    final screenDc = GetDC(NULL);
    final memDc = CreateCompatibleDC(screenDc);
    final bitmap = CreateCompatibleBitmap(screenDc, width, height);
    final old = SelectObject(memDc, bitmap);
    final info = calloc<BITMAPINFO>();
    final buffer = calloc<Uint8>(width * height * 4);
    try {
      BitBlt(
        memDc,
        0,
        0,
        width,
        height,
        screenDc,
        left,
        top,
        SRCCOPY | CAPTUREBLT,
      );
      info.ref.bmiHeader
        ..biSize = sizeOf<BITMAPINFOHEADER>()
        ..biWidth = width
        ..biHeight = -height
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = BI_RGB;
      GetDIBits(memDc, bitmap, 0, height, buffer, info, DIB_RGB_COLORS);
      return Uint8List.fromList(buffer.asTypedList(width * height * 4));
    } finally {
      SelectObject(memDc, old);
      DeleteObject(bitmap);
      DeleteDC(memDc);
      ReleaseDC(NULL, screenDc);
      calloc.free(info);
      calloc.free(buffer);
    }
  }

  static Uint8List _encode(
    Uint8List bgra,
    int width,
    int height,
    int targetW,
    int targetH,
  ) {
    var image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bgra.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    if (targetW != width || targetH != height) {
      image = img.copyResize(
        image,
        width: targetW,
        height: targetH,
        interpolation: img.Interpolation.average,
      );
    }
    return img.encodeJpg(image, quality: 72);
  }

  Map<String, Object?> _cursor() {
    final (x, y) = _cursorPos;
    return {'mouse': _toImage(x, y)};
  }

  // ------------------------------------------------------------ Janelas

  Map<String, Object?> _windows() {
    final found = <Map<String, Object?>>[];
    final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
      int hwnd,
      int _,
    ) {
      if (IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0) return 1;
      final title = _title(hwnd);
      if (title.trim().isEmpty) return 1;
      final rect = calloc<RECT>();
      try {
        GetWindowRect(hwnd, rect);
        final r = rect.ref;
        if (r.right - r.left < 50 || r.bottom - r.top < 50) return 1;
        final region = _current;
        final scale = _scaleFor(region);
        final cx = (r.left + r.right) ~/ 2, cy = (r.top + r.bottom) ~/ 2;
        final monitor = _monitors.indexWhere(
          (m) =>
              cx >= m.rect.left &&
              cx < m.rect.left + m.rect.width &&
              cy >= m.rect.top &&
              cy < m.rect.top + m.rect.height,
        );
        found.add({
          'titulo': title,
          'monitor': monitor,
          if (_toImage(cx, cy) != null) ...{
            'x': ((r.left - region.left) * scale).round(),
            'y': ((r.top - region.top) * scale).round(),
            'largura': ((r.right - r.left) * scale).round(),
            'altura': ((r.bottom - r.top) * scale).round(),
          },
        });
      } finally {
        calloc.free(rect);
      }
      return 1;
    }, exceptionalReturn: 0);
    try {
      EnumWindows(callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    final foreground = GetForegroundWindow();
    return {
      'janela_ativa': foreground == 0 ? '' : _title(foreground),
      'janelas': found,
    };
  }

  String _title(int hwnd) {
    final length = GetWindowTextLength(hwnd);
    if (length == 0) return '';
    final buffer = wsalloc(length + 1);
    try {
      GetWindowText(hwnd, buffer, length + 1);
      return buffer.toDartString();
    } finally {
      free(buffer);
    }
  }

  Map<String, Object?> _focusWindow(Map<String, dynamic> input) {
    final wanted = '${input['title'] ?? ''}'.trim().toLowerCase();
    if (wanted.isEmpty) throw StateError('Informe o título (ou parte dele).');
    var target = 0;
    final callback = NativeCallable<WNDENUMPROC>.isolateLocal((
      int hwnd,
      int _,
    ) {
      if (IsWindowVisible(hwnd) == 0) return 1;
      if (_title(hwnd).toLowerCase().contains(wanted)) {
        target = hwnd;
        return 0;
      }
      return 1;
    }, exceptionalReturn: 0);
    try {
      EnumWindows(callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    if (target == 0) {
      throw StateError('Nenhuma janela com "${input['title']}" no título.');
    }
    if (IsIconic(target) != 0) ShowWindow(target, SW_RESTORE);
    // O Windows só deixa trocar o foco depois de uma tecla "neutra".
    _sendKeys([(VK_MENU, true), (VK_MENU, false)]);
    SetForegroundWindow(target);
    return {'ok': true, 'janela': _title(target)};
  }

  // ------------------------------------------------------------ Mouse

  Map<String, Object?> _move(Map<String, dynamic> input) {
    final (x, y) = _toScreen(input['x'], input['y']);
    SetCursorPos(x, y);
    return {'ok': true};
  }

  Future<Map<String, Object?>> _click(Map<String, dynamic> input) async {
    final (x, y) = _toScreen(input['x'], input['y']);
    final button = '${input['button'] ?? 'left'}';
    final (down, up) = switch (button) {
      'right' => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
      'middle' => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
      _ => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
    };
    final clicks = ((input['clicks'] as num?)?.toInt() ?? 1).clamp(1, 3);
    final modifiers = _parseModifiers(input['modifiers']);
    SetCursorPos(x, y);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    _sendKeys([for (final m in modifiers) (m, true)]);
    for (var i = 0; i < clicks; i++) {
      _sendMouse([down, up]);
      if (i < clicks - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    _sendKeys([for (final m in modifiers.reversed) (m, false)]);
    return {'ok': true, 'clique': button, 'vezes': clicks};
  }

  Future<Map<String, Object?>> _drag(Map<String, dynamic> input) async {
    final (x1, y1) = _toScreen(input['x'], input['y']);
    final (x2, y2) = _toScreen(input['to_x'], input['to_y']);
    SetCursorPos(x1, y1);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    _sendMouse([MOUSEEVENTF_LEFTDOWN]);
    const steps = 12;
    for (var i = 1; i <= steps; i++) {
      SetCursorPos(
        x1 + ((x2 - x1) * i / steps).round(),
        y1 + ((y2 - y1) * i / steps).round(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _sendMouse([MOUSEEVENTF_LEFTUP]);
    return {'ok': true};
  }

  Map<String, Object?> _scroll(Map<String, dynamic> input) {
    if (input['x'] != null && input['y'] != null) {
      final (x, y) = _toScreen(input['x'], input['y']);
      SetCursorPos(x, y);
    }
    final amount = (input['amount'] as num?)?.toInt() ?? 3;
    final horizontal =
        input['direction'] == 'left' || input['direction'] == 'right';
    final sign = input['direction'] == 'up' || input['direction'] == 'left'
        ? 1
        : -1;
    final inputs = calloc<INPUT>();
    try {
      inputs.ref.type = INPUT_MOUSE;
      inputs.ref.mi
        ..dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL
        ..mouseData = sign * (horizontal ? -1 : 1) * amount * _wheelDelta;
      SendInput(1, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
    return {'ok': true};
  }

  void _sendMouse(List<int> flags) {
    final inputs = calloc<INPUT>(flags.length);
    try {
      for (var i = 0; i < flags.length; i++) {
        inputs[i].type = INPUT_MOUSE;
        inputs[i].mi.dwFlags = flags[i];
      }
      SendInput(flags.length, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }

  // ------------------------------------------------------------ Teclado

  Map<String, Object?> _type(Map<String, dynamic> input) {
    final text = '${input['text'] ?? ''}';
    if (text.isEmpty) throw StateError('Informe o texto.');
    final units = text.replaceAll('\r\n', '\n').codeUnits;
    final inputs = calloc<INPUT>(units.length * 2);
    try {
      var n = 0;
      for (final unit in units) {
        if (unit == 0x0A) {
          // Enter de verdade (campos multilinha e formulários).
          inputs[n].type = INPUT_KEYBOARD;
          inputs[n++].ki.wVk = VK_RETURN;
          inputs[n].type = INPUT_KEYBOARD;
          inputs[n].ki.wVk = VK_RETURN;
          inputs[n++].ki.dwFlags = KEYEVENTF_KEYUP;
          continue;
        }
        for (final up in [false, true]) {
          inputs[n].type = INPUT_KEYBOARD;
          inputs[n].ki
            ..wScan = unit
            ..dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
          n++;
        }
      }
      SendInput(n, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
    return {'ok': true, 'caracteres': text.length};
  }

  static const _keyNames = <String, int>{
    'enter': VK_RETURN, 'return': VK_RETURN, 'tab': VK_TAB, //
    'esc': VK_ESCAPE, 'escape': VK_ESCAPE, 'space': VK_SPACE,
    'backspace': VK_BACK, 'delete': VK_DELETE, 'del': VK_DELETE,
    'insert': VK_INSERT, 'home': VK_HOME, 'end': VK_END,
    'pageup': VK_PRIOR, 'pagedown': VK_NEXT,
    'up': VK_UP, 'down': VK_DOWN, 'left': VK_LEFT, 'right': VK_RIGHT,
    'ctrl': VK_CONTROL, 'control': VK_CONTROL, 'shift': VK_SHIFT,
    'alt': VK_MENU, 'win': VK_LWIN, 'windows': VK_LWIN, 'meta': VK_LWIN,
    'capslock': VK_CAPITAL, 'printscreen': VK_SNAPSHOT,
  };

  static int _vk(String name) {
    final key = name.trim().toLowerCase();
    final known = _keyNames[key];
    if (known != null) return known;
    final f = RegExp(r'^f([1-9]|1[0-2])$').firstMatch(key);
    if (f != null) return VK_F1 + int.parse(f.group(1)!) - 1;
    if (key.length == 1) {
      final code = key.toUpperCase().codeUnitAt(0);
      if ((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A)) {
        return code;
      }
    }
    throw StateError('Tecla desconhecida: "$name".');
  }

  static List<int> _parseModifiers(Object? raw) {
    if (raw == null) return const [];
    final names = raw is List ? raw.map((e) => '$e') : '$raw'.split('+');
    return [
      for (final n in names)
        if (n.trim().isNotEmpty) _vk(n),
    ];
  }

  /// "ctrl+s", "alt+tab", "enter"; várias separadas por espaço:
  /// "ctrl+a ctrl+c".
  Map<String, Object?> _key(Map<String, dynamic> input) {
    final combos = '${input['keys'] ?? ''}'.trim();
    if (combos.isEmpty) throw StateError('Informe as teclas (ex.: ctrl+s).');
    for (final combo in combos.split(RegExp(r'\s+'))) {
      final keys = [for (final k in combo.split('+')) _vk(k)];
      _sendKeys([
        for (final k in keys) (k, true),
        for (final k in keys.reversed) (k, false),
      ]);
    }
    return {'ok': true, 'teclas': combos};
  }

  void _sendKeys(List<(int, bool)> keys) {
    if (keys.isEmpty) return;
    final inputs = calloc<INPUT>(keys.length);
    try {
      for (var i = 0; i < keys.length; i++) {
        final (vk, down) = keys[i];
        inputs[i].type = INPUT_KEYBOARD;
        inputs[i].ki
          ..wVk = vk
          ..dwFlags =
              (down ? 0 : KEYEVENTF_KEYUP) |
              (_extended.contains(vk) ? KEYEVENTF_EXTENDEDKEY : 0);
      }
      SendInput(keys.length, inputs, sizeOf<INPUT>());
    } finally {
      calloc.free(inputs);
    }
  }

  static const _extended = {
    VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT, VK_HOME, VK_END, VK_PRIOR, //
    VK_NEXT, VK_INSERT, VK_DELETE,
  };
}

class _Rect {
  const _Rect(this.left, this.top, this.width, this.height);

  final int left;
  final int top;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is _Rect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}
