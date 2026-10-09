/// Not API: what `collection`, `json` and the markup library share, and no topic import exports:
/// the one `save` task every value with a file form writes through, text read from a file's
/// bytes, and the bounded cache of compiled queries (CSS, XPath, JSONPath).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core.dart';

/// [bytes] written to [to] as `Saveable.save` writes a value: atomically, under [conflict], in a
/// task about `to` that ends `Done(fresh: false)` when [Conflict.skip] left a file there.
/// [subject] names the value in a `fail` conflict: `Cannot save Table: out.csv exists`.
Task<Path> saveBytes(String to, Conflict conflict, String subject, List<int> Function() bytes) =>
    FileBridge.save(to, conflict, subject, bytes);

/// How a status names the file at [path]: its folder and name.
String labelOf(String path) => FileBridge.label(path);

/// The text of a file read as [bytes]: a byte-order mark decides UTF-8 or UTF-16, else strict
/// UTF-8. Bytes that are not UTF-8 are a [FormatException] naming [format] and [path], or with
/// [ansi] (an INI or a CSV saved by a Windows program) read as Windows-1252.
String decodeText(Uint8List bytes, String format, String path, {bool ansi = false}) {
  if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
    return _utf8(Uint8List.sublistView(bytes, 3), format, path, ansi: ansi);
  }
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) return _utf16(bytes, Endian.little);
  if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) return _utf16(bytes, Endian.big);
  return _utf8(bytes, format, path, ansi: ansi);
}

String _utf8(Uint8List bytes, String format, String path, {required bool ansi}) {
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    if (ansi) return windows1252(bytes);
    Error.throwWithStackTrace(
      FormatException('Invalid $format in $path: not UTF-8 text', null, e.offset),
      StackTrace.current,
    );
  }
}

/// [bytes] after a two-byte mark, as UTF-16 code units in [endian] order.
String _utf16(Uint8List bytes, Endian endian) {
  final data = ByteData.sublistView(bytes, 2);
  final units = Uint16List(data.lengthInBytes ~/ 2);
  for (var i = 0; i < units.length; i++) {
    units[i] = data.getUint16(i * 2, endian);
  }
  return String.fromCharCodes(units);
}

/// [bytes] as Windows-1252: Latin-1, with curly quotes, dashes and `€` where Latin-1 has C1
/// controls.
String windows1252(List<int> bytes) {
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    units[i] = b >= 0x80 && b < 0xa0 ? _c1[b - 0x80] : b;
  }
  return String.fromCharCodes(units);
}

const _c1 = [
  0x20ac, 0x81, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d, //
  0x017d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a,
  0x0153, 0x9d, 0x017e, 0x0178,
];

/// [make]'s result for [key], cached among the last 256: the CSS, XPath and JSONPath caches,
/// bounded for programs that build queries from data.
V compiled<K, V>(Map<K, V> cache, K key, V Function() make) {
  final hit = cache[key];
  if (hit != null) return hit;
  if (cache.length >= 256) cache.remove(cache.keys.first);
  return cache[key] = make();
}

/// [parse] of [text], whose [FormatException] names [format], [where] (a file or a URL) when
/// there is one, and the line: `Invalid TOML in a.toml, line 2: …`, `Invalid TOML, line 2: …`.
/// It keeps the text and offset, so it prints the line and a caret.
T parsedText<T>(String format, String? where, String text, T Function(String text) parse) {
  try {
    return FileBridge.parsed(format, where ?? '', text, parse);
  } on FormatException catch (e) {
    final prefix = 'Invalid $format in ${where ?? ''}: ';
    if (!e.message.startsWith(prefix)) rethrow;
    final (source, offset) = (e.source, e.offset);
    final line = source is String && offset != null
        ? '\n'.allMatches(source.substring(0, min(offset, source.length))).length + 1
        : null;
    final head = 'Invalid $format${where == null ? '' : ' in $where'}${line == null ? '' : ', line $line'}';
    Error.throwWithStackTrace(
      FormatException('$head: ${e.message.substring(prefix.length)}', source, offset),
      StackTrace.current,
    );
  }
}
