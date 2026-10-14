/// Minimal JSON values. Thin facade over `dart:convert`.
///
/// ```dart
/// final port = await Fs.file('conf.json').json().$('server.port').value<int>() ?? 8080;
/// await Fs.file('names.json').write(Json.encode(names, pretty: true));
/// ```
///
/// Public surface is exactly: [Json].
/// - `Json.parse()` parses text, `Json.encode()` renders it, `Json.of()`
///   wraps a value you already hold.
/// - [Json] supports `$` (dotted path) `[]` (index the iteration) `value`
///   (typed scalar read) `listOf`/`mapOf` (flat collections).
/// Everything else is private.
library;

import 'dart:convert';

import 'core.dart';
export 'core.dart';

/// A JSON value: an object, array, scalar, or null.
final class Json extends Iterable<Json> {
  Json._(this._v);

  final Object? _v;
  List<dynamic>? _valuesCache;

  /// Parse [json]. Throws [FormatException] on invalid JSON.
  static Json parse(String json) {
    try {
      return Json._(jsonDecode(json));
    } on FormatException catch (e) {
      throw FormatException('invalid JSON: ${e.message}', e.source, e.offset);
    }
  }

  /// Wrap a value you already hold (e.g. a decoded `evaluate` result):
  /// no `jsonEncode` → parse round trip. Lets `chrome.evaluate` skip
  /// re-encoding and lets scripts wrap values without copying them.
  static Json of(Object? decoded) => Json._(decoded);

  /// Render [value] as JSON text. Accepts what `dart:convert` accepts (string
  /// keys) and throws what it throws. A [Json] anywhere inside is read as its
  /// raw value.
  static String encode(Object? value, {bool pretty = false}) {
    Object? unwrap(Object? v) => v is Json ? v._v : v;
    final encoder = pretty
        ? JsonEncoder.withIndent('  ', unwrap)
        : JsonEncoder(unwrap);
    return encoder.convert(value);
  }

  /// Dotted path (`users.0.name`); a numeric segment indexes an array. A `*`
  /// segment maps over every item: `$('data.users.*.name')` is a [Json] of
  /// the list of names. `*` over an object maps over its values in iteration
  /// order. A missing path (or a missing key inside `*`) gives a [Json]
  /// holding null, never a throw. Use `\` to escape ( `\.` for a literal dot,
  /// `\*` for a literal star, `\\` for a backslash).
  Json $(String path) {
    if (path.isEmpty) return Json._(_v);
    return Json._(_walk(_v, _splitPath(path)));
  }

  /// Index the iteration (array items or object values), O(1) per item
  /// after the first (object values are cached).
  /// Throws [RangeError] when out of range or on a scalar.
  Json operator [](int index) {
    final v = _v;
    if (v is List) return Json._(v[index]);
    if (v is Map) {
      var cache = _valuesCache;
      if (cache == null) {
        cache = v.values.toList();
        _valuesCache = cache;
      }
      return Json._(cache[index]);
    }
    throw RangeError('index $index into a scalar JSON value');
  }

  /// The value when it is a `T`, else null, so `??` gives the default.
  /// Scalars: integral numbers read as both `int` and `double`, so `3`,
  /// `3.0`, `value<int>()` and `value<double>()` all agree (a non-integral
  /// `double` is not an `int`). Use `num` for numbers that may be either,
  /// `Object` for the raw value. Flat collections read with [listOf]/[mapOf]
  /// (the element type is the parameter); nested data reads by iterating
  /// (see below), which is also where records come from:
  ///
  /// ```dart
  /// final port = cfg.$('server.port').value<int>() ?? 8080;
  /// final users = [
  ///   for (final u in doc.$('users'))
  ///     (name: u.$('name').value<String>() ?? '', age: u.$('age').value<int>() ?? 0),
  /// ];
  /// ```
  T? value<T>() {
    final v = _v;
    if (v is T) return v;
    if (v is num) {
      if (v is int) {
        final d = v.toDouble();
        if (d is T) return d as T;
      } else if (v.isFinite &&
          v == v.truncateToDouble() &&
          v >= -9223372036854775808.0 &&
          v <= 9223372036854775807.0) {
        final i = v.toInt();
        if (i is T) return i as T;
      }
      return null;
    }
    return null;
  }

  /// The value as a `List<T>`, or null unless it is a list and every element
  /// converts to `T` (with the same integral-number coercion as [value]).
  /// One pass, O(n): a mismatch returns null after a single scan, not
  /// O(33·n) across a table of shapes. Flat cases only; nested data reads
  /// by iterating:
  ///
  /// ```dart
  /// final names = doc.$('data.users.*.name').listOf<String>() ?? [];
  /// ```
  List<T>? listOf<T>() {
    final v = _v;
    if (v is! List) return null;
    final out = <T>[];
    for (final e in v) {
      final c = _scalar<T>(e);
      if (identical(c, _mismatch)) return null;
      out.add(c as T);
    }
    return out;
  }

  /// The value as a `Map<String, T>`, or null unless it is an object with
  /// string keys and every value converts to `T`. One pass, O(n).
  ///
  /// ```dart
  /// final counts = doc.$('stats').mapOf<int>() ?? {};
  /// ```
  Map<String, T>? mapOf<T>() {
    final v = _v;
    if (v is! Map) return null;
    final out = <String, T>{};
    for (final entry in v.entries) {
      final k = entry.key;
      if (k is! String) return null;
      final c = _scalar<T>(entry.value);
      if (identical(c, _mismatch)) return null;
      out[k] = c as T;
    }
    return out;
  }

  @override
  int get length {
    final v = _v;
    if (v is List) return v.length;
    if (v is Map) return v.length;
    return 0;
  }

  /// An array's items or an object's values, wrapped lazily (O(1) per item).
  @override
  Iterator<Json> get iterator {
    final v = _v;
    if (v is List) return _ListJsonIterator(v);
    if (v is Map) return _MapJsonIterator(v.values.iterator);
    return const <Json>[].iterator;
  }

  /// Walk [segments] from [cur]; a `*` maps over items and collects a list.
  static Object? _walk(Object? cur, List<String> segments) {
    Object? c = cur;
    for (var k = 0; k < segments.length; k++) {
      final seg = segments[k];
      if (seg == '*') {
        final Iterable<Object?> items;
        if (c is List) {
          items = c;
        } else if (c is Map) {
          items = c.values;
        } else {
          return null;
        }
        final rest = segments.sublist(k + 1);
        return [for (final item in items) _walk(item, rest)];
      }
      if (c is Map) {
        if (!c.containsKey(seg)) return null;
        c = c[seg];
      } else if (c is List) {
        if (!_isIndex(seg)) return null;
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= c.length) return null;
        c = c[i];
      } else {
        return null;
      }
    }
    return c;
  }
}

/// True for canonical array indexes (`0`, `1`, …): no `+`, no leading
/// zeros, no whitespace.
bool _isIndex(String seg) {
  if (seg.isEmpty) return false;
  if (seg == '0') return true;
  if (seg.length > 1 && seg.codeUnitAt(0) == 0x30) return false;
  for (var i = 0; i < seg.length; i++) {
    final c = seg.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

/// Split a dotted path, honouring `\` escapes (`\.`, `\*`, `\\`).
List<String> _splitPath(String path) {
  final out = <String>[];
  final buf = StringBuffer();
  var i = 0;
  while (i < path.length) {
    final c = path.codeUnitAt(i);
    if (c == 0x5C && i + 1 < path.length) {
      final n = path.codeUnitAt(i + 1);
      if (n == 0x2E || n == 0x2A || n == 0x5C) {
        buf.writeCharCode(n);
        i += 2;
        continue;
      }
      buf.writeCharCode(c);
      i++;
      continue;
    }
    if (c == 0x2E) {
      out.add(buf.toString());
      buf.clear();
      i++;
      continue;
    }
    buf.writeCharCode(c);
    i++;
  }
  out.add(buf.toString());
  return out;
}

/// An array's items, wrapped one at a time.
final class _ListJsonIterator implements Iterator<Json> {
  _ListJsonIterator(this._items);

  final List<dynamic> _items;
  var _i = -1;

  @override
  bool moveNext() {
    _i++;
    return _i < _items.length;
  }

  @override
  Json get current {
    if (_i < 0 || _i >= _items.length) {
      throw StateError('no current element');
    }
    return Json._(_items[_i]);
  }
}

/// An object's values, wrapped one at a time.
final class _MapJsonIterator implements Iterator<Json> {
  _MapJsonIterator(this._inner);

  final Iterator<dynamic> _inner;
  Json? _current;

  @override
  bool moveNext() {
    if (!_inner.moveNext()) {
      _current = null;
      return false;
    }
    _current = Json._(_inner.current);
    return true;
  }

  @override
  Json get current => _current ?? (throw StateError('no current element'));
}

/// Mismatch marker for the element converter below. It never escapes: every
/// use checks `identical(c, _mismatch)` before the value can leave.
final Object _mismatch = Object();

/// Convert [e] to [E]: a match, an integral-number coercion, or [_mismatch].
/// `null` converts only when [E] admits it (`Null`, `E?`, `dynamic`…).
/// `Map<String, dynamic>` (the engine's object shape) is `E` whenever `E`
/// admits it (e.g. `Map<String, Object?>`), so `listOf<Map<String, Object?>>`
/// and `mapOf` read the common REST shapes in one pass.
Object? _scalar<E>(Object? e) {
  if (e is E) return e;
  if (e is int) {
    final d = e.toDouble();
    if (d is E) return d;
  } else if (e is double &&
      e.isFinite &&
      e == e.truncateToDouble() &&
      e >= -9223372036854775808.0 &&
      e <= 9223372036854775807.0) {
    final i = e.toInt();
    if (i is E) return i;
  }
  return _mismatch;
}

/// Bytes → a value. Throws [FormatException] on invalid JSON; a failure
/// on an error page names the HTTP status in the message.
extension ReaderJson on Reader {
  Future<Json> json() async {
    final text = await this.text();
    try {
      return Json.parse(text);
    } on FormatException catch (e) {
      throw _withStatus(this, e);
    }
  }
}

/// Annotate a content [FormatException] with the HTTP status when the
/// reader is an error page. Typed via [Origin]; no `dynamic` probe.
FormatException _withStatus(Reader reader, FormatException e) {
  final status = reader.origin().status;
  if (status == null) return e;
  // Only error pages are annotated; a 2xx body that isn't JSON is just
  // invalid content.
  if (status >= 200 && status < 300) return e;
  return FormatException('${e.message} (HTTP $status)', e.source, e.offset);
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
  Future<List<T>?> listOf<T>() async => (await this).listOf<T>();
  Future<Map<String, T>?> mapOf<T>() async => (await this).mapOf<T>();
}
