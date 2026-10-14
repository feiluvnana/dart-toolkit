/// One portable-file-name rule set, shared by `fs` (`Fs.sanitize`) and the
/// network file names in `src/origin.dart`. No imports.
library;

import 'dart:convert';

/// [name] as one segment safe to create on Linux, macOS and Windows:
/// separators and reserved characters (`<>:"|?*`, controls) become `_`,
/// trailing dots and spaces go, a reserved device name (`CON`, `NUL`, …)
/// or a leading `.`/`-` (a dotfile, an option) gets a `_` prefix, and the
/// result is at most 255 UTF-8 bytes. Empty when nothing usable is left.
String safeName(String name) {
  var s = name
      .replaceAll(RegExp(r'[\\/<>:"|?*\x00-\x1f\x7f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) return '';
  if (_reserved.hasMatch(s) || s.startsWith('.') || s.startsWith('-')) s = '_$s';
  if (utf8.encode(s).length > 255) {
    final out = StringBuffer();
    var bytes = 0;
    for (final r in s.runes) {
      final n = r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4;
      if (bytes + n > 255) break;
      bytes += n;
      out.writeCharCode(r);
    }
    s = out.toString().replaceAll(RegExp(r'[. ]+$'), '');
  }
  return s;
}

final _reserved = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$', caseSensitive: false);
