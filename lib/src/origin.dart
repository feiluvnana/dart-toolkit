/// File-name rules shared by `http` and `chrome`.
///
/// One home for `content-disposition` parsing and URL-tail fallback, so
/// `Response.name()` and `chrome` upload staging strips paths the same way.
/// Facades never branch on the rules themselves; they call [fileName].
library;

import 'dart:convert';

import 'names.dart';

export 'names.dart' show redact;

/// A file name for a body: the `content-disposition` filename
/// (`filename*=` wins over `filename=`, paths stripped), else the final
/// URL's last segment, else `'download'`.
String fileName({required String url, String? contentDisposition}) {
  final fromHeader = dispositionName(contentDisposition);
  if (fromHeader != null) return fromHeader;
  final uri = Uri.tryParse(url);
  final segments = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
  if (segments.isNotEmpty) {
    final last = segments.last;
    String decoded;
    try {
      decoded = Uri.decodeComponent(last);
    } catch (_) {
      decoded = last;
    }
    final name = stripPath(decoded);
    if (name.isNotEmpty) return name;
  }
  return 'download';
}

/// The `content-disposition` filename, or null when absent or empty.
/// `filename*=` (RFC 6266/8187) wins over `filename=`; paths are stripped.
String? dispositionName(String? header) {
  if (header == null) return null;
  final star = _starName.firstMatch(header);
  if (star != null) {
    var value = star.group(1)!.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    String decoded;
    final first = value.indexOf("'");
    final second = first < 0 ? -1 : value.indexOf("'", first + 1);
    if (first > 0 && second > first) {
      // RFC 8187 names only UTF-8 and ISO-8859-1.
      final bytes = percentDecode(value.substring(second + 1));
      decoded = switch (value.substring(0, first).trim().toLowerCase()) {
        'iso-8859-1' || 'latin1' || 'iso8859-1' => latin1.decode(bytes),
        _ => utf8.decode(bytes, allowMalformed: true),
      };
    } else {
      decoded = percentDecodeString(value);
    }
    final name = stripPath(decoded.trim());
    if (name.isNotEmpty) return name;
  }
  final plain = _plainName.firstMatch(header);
  if (plain != null) {
    // `filename=` cannot match inside `filename*=` (the `*` breaks it).
    final name = stripPath((plain.group(1) ?? plain.group(2) ?? plain.group(3) ?? '').trim());
    if (name.isNotEmpty) return name;
  }
  return null;
}

final _starName = RegExp(r'''filename\*\s*=\s*([^;]+)''', caseSensitive: false);
final _plainName = RegExp(r'''filename\s*=\s*(?:"([^"]*)"|'([^']*)'|([^;\s]+))''', caseSensitive: false);

/// `%XX` escapes as bytes; any other character as its UTF-8 bytes (a
/// surrogate pair is one character, so astral text survives).
List<int> percentDecode(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final v = _hexByte(s, i + 1);
      if (v != null) {
        out.add(v);
        i += 2;
        continue;
      }
    }
    if (c < 0x80) {
      out.add(c);
    } else {
      final pair = c >= 0xD800 && c < 0xDC00 && i + 1 < s.length && (s.codeUnitAt(i + 1) & 0xFC00) == 0xDC00;
      final end = pair ? i + 2 : i + 1;
      out.addAll(utf8.encode(s.substring(i, end)));
      i = end - 1;
    }
  }
  return out;
}

/// The byte spelled by the two hex digits at [i], or null (`int.tryParse`
/// would also take `+1` and `-1`).
int? _hexByte(String s, int i) {
  int digit(int c) => switch (c) {
    >= 0x30 && <= 0x39 => c - 0x30,
    >= 0x41 && <= 0x46 => c - 0x37,
    >= 0x61 && <= 0x66 => c - 0x57,
    _ => -1,
  };
  final hi = digit(s.codeUnitAt(i)), lo = digit(s.codeUnitAt(i + 1));
  return hi < 0 || lo < 0 ? null : hi << 4 | lo;
}

String percentDecodeString(String s) {
  // A bare `filename=` is already text; only unescape percent runs so
  // `%20` reads as a space while other bytes stay as they are.
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final v = _hexByte(s, i + 1);
      if (v != null && v >= 0x20 && v < 0x7F) {
        out.writeCharCode(v);
        i += 2;
        continue;
      }
    }
    out.writeCharCode(c);
  }
  return out.toString();
}

/// True for a request header that carries credentials: the standard ones
/// and any custom one named like a secret (`X-Api-Key`, `Private-Token`).
/// Such headers never leave the origin they were meant for.
bool isSecretHeader(String name) {
  final k = name.toLowerCase();
  return k == 'authorization' || k == 'cookie' || k == 'proxy-authorization' || _secretHeader.hasMatch(k);
}

final _secretHeader = RegExp(r'token|key|secret|passw|auth|session|credential|signature');
