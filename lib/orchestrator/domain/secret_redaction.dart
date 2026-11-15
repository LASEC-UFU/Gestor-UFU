/// Remove credenciais de textos antes de guardá-los no diário ou mostrá-los
/// (port de `secretRedaction.js` do Orchestrator-AI).
String redactSensitiveText(Object? value, {int max = 12000}) {
  var text = '${value ?? ''}';
  text = text.replaceAll(_privateKey, '[REDACTED PRIVATE KEY]');
  text = text.replaceAllMapped(_bearer, (m) => '${m.group(1)} [REDACTED]');
  text = text.replaceAllMapped(
    _secretAssignment,
    (m) => '${m.group(1)}"[REDACTED]"',
  );
  text = text.replaceAllMapped(
    _tokenAssignment,
    (m) => '${m.group(1)}"[REDACTED]"',
  );
  text = text.replaceAll(_credential, '[REDACTED CREDENTIAL]');
  return text.length <= max ? text : text.substring(0, max < 0 ? 0 : max);
}

final _privateKey = RegExp(
  r'-----BEGIN (?:(?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----[\s\S]*?-----END (?:(?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----',
  caseSensitive: false,
);
final _bearer = RegExp(
  r'''\b(Bearer|Basic)\s+[^\s"'`,;]+''',
  caseSensitive: false,
);
final _secretAssignment = RegExp(
  r'''((?:^|[\s,{;])["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?|password|passwd|senha|aws[_-]?secret[_-]?access[_-]?key|aws[_-]?access[_-]?key[_-]?id|account[_-]?key|private[_-]?key|connection[_-]?string|secret|client[_-]?secret)["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]]+)''',
  caseSensitive: false,
  multiLine: true,
);
final _tokenAssignment = RegExp(
  r'''((?:^|\n|[{,;])[ \t]*["']?token["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}\]]+)''',
  caseSensitive: false,
  multiLine: true,
);
final _credential = RegExp(
  r'\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|npm_[A-Za-z0-9]{30,}|hf_[A-Za-z0-9]{30,}|AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]{20,})\b',
  caseSensitive: false,
);
