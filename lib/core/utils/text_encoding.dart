import 'dart:convert';

/// Repairs text that was decoded as Windows-1252/Latin-1 before UTF-8.
/// It only rewrites strings containing mojibake marker characters.
String repairMojibake(String value) {
  var repaired = value;
  for (var pass = 0; pass < 4; pass++) {
    final next = _decodeUtf8Segments(repaired);
    if (next == repaired) break;
    repaired = next;
  }
  return repaired;
}

String _decodeUtf8Segments(String value) {
  final output = StringBuffer();
  final segment = <int>[];
  final originalRunes = <int>[];

  void flush() {
    if (segment.isEmpty) return;
    final hasMarker = originalRunes.any(
      (rune) =>
          rune == 0x00c3 ||
          rune == 0x00c2 ||
          rune == 0x00c6 ||
          rune == 0xfffd ||
          (rune >= 0x0080 && rune <= 0x009f),
    );
    if (hasMarker) {
      try {
        output.write(utf8.decode(segment, allowMalformed: false));
      } on FormatException {
        output.write(String.fromCharCodes(originalRunes));
      }
    } else {
      output.write(String.fromCharCodes(originalRunes));
    }
    segment.clear();
    originalRunes.clear();
  }

  for (final rune in value.runes) {
    final byte = _windows1252Byte(rune);
    if (byte != null) {
      segment.add(byte);
      originalRunes.add(rune);
    } else {
      flush();
      output.writeCharCode(rune);
    }
  }
  flush();
  return output.toString();
}

int? _windows1252Byte(int rune) {
  if (rune <= 0xff) return rune;
  const special = <int, int>{
    0x20ac: 0x80,
    0x201a: 0x82,
    0x0192: 0x83,
    0x201e: 0x84,
    0x2026: 0x85,
    0x2020: 0x86,
    0x2021: 0x87,
    0x02c6: 0x88,
    0x2030: 0x89,
    0x0160: 0x8a,
    0x2039: 0x8b,
    0x0152: 0x8c,
    0x017d: 0x8e,
    0x2018: 0x91,
    0x2019: 0x92,
    0x201c: 0x93,
    0x201d: 0x94,
    0x2022: 0x95,
    0x2013: 0x96,
    0x2014: 0x97,
    0x02dc: 0x98,
    0x2122: 0x99,
    0x0161: 0x9a,
    0x203a: 0x9b,
    0x0153: 0x9c,
    0x017e: 0x9e,
    0x0178: 0x9f,
  };
  return special[rune];
}
