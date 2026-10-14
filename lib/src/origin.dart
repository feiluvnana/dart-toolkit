/// File-name rules shared by `http`, `scrape` and `chrome`.
///
/// One home for `content-disposition` parsing and URL-tail fallback, so
/// `Response.fileName()` and `Visit.fileName()` agree (VISION: "as on
/// Response") and `chrome` upload staging strips paths the same way.
/// Facades never branch on the rules themselves; they call [fileName].
library;

import 'dart:convert';

import 'charset.dart' as charset;

/// A file name for a body: the `content-disposition` filename
/// (`filename*=` wins over `filename=`, paths stripped), else the final
/// URL's last segment, else `'download'`.
String fileName({required String url, String? contentDisposition}) {
  final fromHeader = dispositionName(contentDisposition);
  if (fromHeader != null) return fromHeader;
  final uri = Uri.tryParse(url);
  final segments =
      uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
  if (segments.isNotEmpty) {
    final last = segments.last;
    try {
      final decoded = Uri.decodeComponent(last);
      if (decoded.isNotEmpty) return stripPath(decoded);
    } catch (_) {
      if (last.isNotEmpty) return stripPath(last);
    }
  }
  return 'download';
}

/// The `content-disposition` filename, or null when absent or empty.
/// `filename*=` (RFC 6266/8187) wins over `filename=`; paths are stripped.
String? dispositionName(String? header) {
  if (header == null) return null;
  final star = RegExp(
    r'''filename\*\s*=\s*([^;]+)''',
    caseSensitive: false,
  ).firstMatch(header);
  if (star != null) {
    var value = star.group(1)!.trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    String decoded;
    final first = value.indexOf("'");
    final second = first < 0 ? -1 : value.indexOf("'", first + 1);
    if (first > 0 && second > first) {
      final encoding = charset.Charset.canonical(value.substring(0, first));
      final raw = value.substring(second + 1);
      final decoder = charset.IncrementalDecoder(encoding);
      decoded = decoder.add(percentDecode(raw)) + decoder.finish();
    } else {
      decoded = percentDecodeString(value);
    }
    final name = stripPath(decoded.trim());
    if (name.isNotEmpty) return name;
  }
  final plain = RegExp(
    r'''filename\s*=\s*(?:"([^"]*)"|'([^']*)'|([^;\s]+))''',
    caseSensitive: false,
  ).firstMatch(header);
  if (plain != null) {
    // `filename=` cannot match inside `filename*=` (the `*` breaks it).
    final name = stripPath(
      (plain.group(1) ?? plain.group(2) ?? plain.group(3) ?? '').trim(),
    );
    if (name.isNotEmpty) return name;
  }
  return null;
}

/// Last path segment: strips `a/b\c` to `c`. Used for header filenames and
/// upload staging alike.
String stripPath(String name) {
  final parts = name.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? name : parts.last;
}

List<int> percentDecode(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (v != null) {
        out.add(v);
        i += 2;
        continue;
      }
    }
    if (c < 0x80) {
      out.add(c);
    } else {
      out.addAll(utf8.encode(String.fromCharCode(c)));
    }
  }
  return out;
}

String percentDecodeString(String s) {
  // A bare `filename=` is already text; only unescape percent runs so
  // `%20` reads as a space while other bytes stay as they are.
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
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

/// Base URL for `html()` from a typed [Origin]-like pair: the final URL when
/// present, else the file path as a `file:` URI. Callers pass
/// `reader.origin().url` / `.path` so this module never imports `http`/`fs`.
String? baseUrlFor({String? url, String? path}) {
  if (url != null && url.isNotEmpty) return url;
  if (path != null) {
    try {
      return Uri.file(path).toString();
    } catch (_) {
      return null;
    }
  }
  return null;
}
