/// Minimal JSON values. Thin facade over `dart:convert`.
///
/// ```dart
/// final port = await Fs.file('conf.json').json().$('server.port').value<int>() ?? 8080;
/// await Fs.file('names.json').write(Json.encode(names, pretty: true));
/// ```
///
/// Public surface is exactly: [Json].
/// - `Json.parse()` parses text, `Json.encode()` renders it.
/// - [Json] supports `$` (dotted path) `[]` (index the iteration) `value` (typed read).
/// Everything else is private.
library;

import 'dart:convert';

import 'core.dart';
export 'core.dart';

/// A JSON value: an object, array, scalar, or null.
final class Json extends Iterable<Json> {
  Json._(this._v);

  final Object? _v;

  /// Parse [json]. Throws [FormatException] on invalid JSON.
  static Json parse(String json) {
    try {
      return Json._(jsonDecode(json));
    } on FormatException catch (e) {
      throw FormatException('invalid JSON: ${e.message}', e.source, e.offset);
    }
  }

  /// Render [value] as JSON text. Accepts what `dart:convert` does.
  static String encode(Object? value, {bool pretty = false}) {
    final raw = _unwrap(value);
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(raw);
    }
    return jsonEncode(raw);
  }

  /// Dotted path (`users.0.name`); a numeric segment indexes an array.
  /// A missing path gives a [Json] holding null, never a throw.
  Json $(String path) {
    Object? cur = _v;
    if (path.isEmpty) return Json._(cur);
    for (final seg in path.split('.')) {
      if (cur is Map) {
        if (!cur.containsKey(seg)) return Json._(null);
        cur = cur[seg];
      } else if (cur is List) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= cur.length) return Json._(null);
        cur = cur[i];
      } else {
        return Json._(null);
      }
    }
    return Json._(cur);
  }

  /// Index the iteration (array items or object values). Throws [RangeError].
  Json operator [](int index) {
    final items = _items();
    return items[index];
  }

  /// The value when it is a `T`, else null, so `??` gives the default.
  /// Use `num` for numbers that may be integers, `Object` for the raw value.
  T? value<T>() {
    final v = _v;
    if (v is T) return v;
    return null;
  }

  List<Json> _items() {
    final v = _v;
    if (v is List) return [for (final e in v) Json._(e)];
    if (v is Map) return [for (final e in v.values) Json._(e)];
    return const [];
  }

  @override
  Iterator<Json> get iterator => _items().iterator;

  static Object? _unwrap(Object? value) {
    if (value is Json) return value._v;
    if (value is List) return [for (final e in value) _unwrap(e)];
    if (value is Map) {
      return {
        for (final e in value.entries) '${e.key}': _unwrap(e.value),
      };
    }
    return value;
  }
}

/// Bytes → a value. Throws [FormatException] on invalid JSON.
extension ReaderJson on Reader {
  Future<Json> json() async => Json.parse(await text());
}

/// Same, from an async reader.
extension ReaderFutureJson on Future<Reader> {
  Future<Json> json() async => (await this).json();
}

/// The Future mirror (rule 6). The extension name is import-only; never reference it.
extension JsonFuture on Future<Json> {
  Future<Json> $(String path) async => (await this).$(path);
  Future<Json> operator [](int index) async => (await this)[index];
  Future<T?> value<T>() async => (await this).value<T>();
}
