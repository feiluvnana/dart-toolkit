/// Minimal JSON values. Thin facade over `dart:convert`.
///
/// ```dart
/// final port = await Fs.file('conf.json').json().$('server.port').or(8080);
/// await Fs.file('names.json').write(Json.encode(names, pretty: true));
/// ```
///
/// Public surface is exactly: [Json].
/// - `Json.parse()` parses text, `Json.encode()` renders it, `Json.of()`
///   wraps a value you already hold.
/// - [Json] supports `$` (dotted path, `a|b` alternatives) `[]` (index the
///   iteration) `value` (typed scalar read) `or` (read with a default) `text`
///   (any scalar as a string) `max`/`min` (the extreme item) `asList`/`asMap`
///   (flat collections).
/// - `toJson` lets `jsonEncode` read a nested [Json]; `toString` is the
///   JSON text; `==` compares values deeply.
/// Everything else is private.
library;

import 'dart:convert';
import 'dart:io' show PathNotFoundException;

import 'core.dart';
export 'core.dart';

import 'src/names.dart' as names;

/// A JSON value: an object, array, scalar, or null.
final class Json extends Iterable<Json> {
  // A Json held inside another (`Json.of([Json.parse(a), …])`) reads as its value.
  Json._(Object? v) : _v = v is Json ? v._v : v;

  final Object? _v;
  List<dynamic>? _valuesCache;

  /// Parse [json]. Throws [ContentException] on invalid JSON.
  static Json parse(String json) {
    try {
      return Json._(jsonDecode(json));
    } on FormatException catch (e) {
      throw ContentException('invalid JSON: ${e.message}', e.source, e.offset, e);
    }
  }

  /// Wrap a value you already hold (e.g. a decoded `run` result):
  /// no `jsonEncode` → parse round trip. Lets `page.run` skip
  /// re-encoding and lets scripts wrap values without copying them.
  static Json of(Object? decoded) => Json._(decoded);

  /// Render [value] as JSON text. Accepts what `dart:convert` accepts (string
  /// keys) and throws what it throws. A [Json] anywhere inside is read as its
  /// raw value.
  static String encode(Object? value, {bool pretty = false}) {
    final encoder = pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(value);
  }

  /// What `jsonEncode` calls: a [Json] inside any encoded value is its raw value.
  Object? toJson() => _v;

  /// Dotted path (`users.0.name`); a numeric segment indexes an array. A `*`
  /// segment maps over every item: `$('data.users.*.name')` is a [Json] of
  /// the list of names. `*` over an object maps over its values in iteration
  /// order. A `**` segment searches every depth: `$('**.pk')` is a [Json]
  /// list of each `pk` anywhere in the document (document order, nulls and
  /// misses dropped). A missing path (or a missing key inside `*`) gives a
  /// [Json] holding null, never a throw. A `|` in a segment tries
  /// alternatives in order (`code|shortcode`, `pk|id`): the first that
  /// leads to a value with the rest of the path wins. Use `\` to escape
  /// (`\.` for a literal dot, `\*` a literal star, `\|` a literal bar, `\\`
  /// a backslash).
  Json $(String path) {
    if (path.isEmpty) return Json._(_v);
    // One plain key (`name`, `0`): no split, no segment list.
    if (!path.contains('.') && !path.contains(r'\') && !path.contains('|') && path != '*' && path != '**') {
      return Json._(_step(_v, path));
    }
    return Json._(_walk(_v, _splitPath(path)));
  }

  /// Index the iteration (array items or object values), O(1) per item
  /// after the first (object values are cached).
  /// Throws [RangeError] when out of range or on a scalar, like a [List]
  /// index; the never-throwing read is the path: `$('items.0')`.
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

  /// The value when it is a `T`, else [fallback]: `$('port').or(8080)` is a
  /// non-null `int`. See [value] for the coercions.
  T or<T>(T fallback) => value<T>() ?? fallback;

  /// Any scalar as a `String` (`787132` → `'787132'`, `true` → `'true'`);
  /// null for null, a missing path or a collection. Not [toString], which
  /// renders JSON.
  String? text() => switch (_v) {
    final String s => s,
    final num n => '$n',
    final bool b => '$b',
    _ => null,
  };

  /// The item (array item or object value) with the largest [by], or a null
  /// [Json] when there are none; the first wins a tie.
  Json max(num Function(Json item) by) => _extreme(by, 1);

  /// The item with the smallest [by], or a null [Json] when there are none.
  Json min(num Function(Json item) by) => _extreme(by, -1);

  Json _extreme(num Function(Json item) by, int sign) {
    Json? best;
    num? score;
    for (final item in this) {
      final s = by(item);
      if (score == null || (s - score) * sign > 0) {
        best = item;
        score = s;
      }
    }
    return best ?? Json._(null);
  }

  /// The value when it is a `T`, else null.
  /// Scalars: integral numbers read as both `int` and `double`, so `3`,
  /// `3.0`, `value<int>()` and `value<double>()` all agree (a non-integral
  /// `double` is not an `int`). Use `num` for numbers that may be either,
  /// `Object` for the raw value. Flat collections read with [asList]/[asMap]
  /// (the element type is the parameter); nested data reads by iterating
  /// (see below), which is also where records come from:
  ///
  /// ```dart
  /// final port = cfg.$('server.port').or(8080);
  /// final users = [
  ///   for (final u in doc.$('users'))
  ///     (name: u.$('name').or(''), age: u.$('age').or(0)),
  /// ];
  /// ```
  ///
  /// A typed collection that the value is not (`value<List<int>>()` on a
  /// JSON array) is an [ArgumentError] in every build mode: that read is
  /// [asList]/[asMap]. The raw shapes (`value<List>()`, `value<Map>()`)
  /// read as they are.
  T? value<T>() {
    final v = _v;
    if (v is T) return v;
    if ((v is List || v is Map) && (<T>[] is List<List<Object?>?> || <T>[] is List<Map<Object?, Object?>?>)) {
      throw ArgumentError('value<$T>() reads scalars and raw shapes; use asList/asMap');
    }
    if (v is num) {
      if (v is int) {
        final d = v.toDouble();
        if (d is T) return d as T;
      } else if (v.isFinite && v == v.truncateToDouble() && v >= -9223372036854775808.0 && v < 9223372036854775808.0) {
        // 2^63 itself does not fit
        final i = v.toInt();
        if (i is T) return i as T;
      }
      return null;
    }
    return null;
  }

  /// The value as a `List<T>`; empty unless it is a list and every element
  /// converts to `T` (with the same integral-number coercion as [value]).
  /// One pass, O(n). Flat cases only; nested data reads
  /// by iterating:
  ///
  /// ```dart
  /// final names = doc.$('data.users.*.name').asList<String>();
  /// ```
  List<T> asList<T>() {
    final v = _v;
    if (v is! List) return <T>[];
    final out = <T>[];
    for (final e in v) {
      final c = _scalar<T>(e);
      if (identical(c, _mismatch)) return <T>[];
      out.add(c as T);
    }
    return out;
  }

  /// The value as a `Map<String, T>`; empty unless it is an object with
  /// string keys and every value converts to `T`. One pass, O(n).
  ///
  /// ```dart
  /// final counts = doc.$('stats').asMap<int>();
  /// ```
  Map<String, T> asMap<T>() {
    final v = _v;
    if (v is! Map) return <String, T>{};
    final out = <String, T>{};
    for (final entry in v.entries) {
      final k = entry.key;
      if (k is! String) return <String, T>{};
      final c = _scalar<T>(entry.value);
      if (identical(c, _mismatch)) return <String, T>{};
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

  /// The JSON text (`{"a":1}`); a value `dart:convert` cannot encode
  /// prints as Dart would.
  @override
  String toString() {
    try {
      return jsonEncode(_v);
    } on JsonUnsupportedObjectError {
      return '$_v';
    }
  }

  /// Deep equality: the same JSON value (object key order does not matter;
  /// `1` and `1.0` are equal, as in Dart).
  @override
  bool operator ==(Object other) => other is Json && _deepEquals(_v, other._v);

  @override
  int get hashCode => _deepHash(_v);

  /// An array's items or an object's values, wrapped lazily (O(1) per item).
  @override
  Iterator<Json> get iterator {
    final v = _v;
    if (v is List) return _ListJsonIterator(v);
    if (v is Map) return _MapJsonIterator(v.values.iterator);
    return const <Json>[].iterator;
  }

  /// Walk [segments] from [cur]; a `*` maps over items and collects a list,
  /// a `**` collects the rest's matches at every depth.
  static Object? _walk(Object? cur, List<Object> segments) {
    Object? c = cur;
    for (var k = 0; k < segments.length; k++) {
      if (c is Json) c = c._v;
      final seg = segments[k];
      if (seg == _Wild.deep) {
        final rest = segments.sublist(k + 1);
        final out = <Object?>[];
        void visit(Object? node) {
          if (node is Json) node = node._v;
          final hit = rest.isEmpty ? node : _walk(node, rest);
          if (hit != null) out.add(hit);
          if (node is Map) {
            node.values.forEach(visit);
          } else if (node is List) {
            node.forEach(visit);
          }
        }

        visit(c);
        return out;
      }
      if (seg == _Wild.any) {
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
      if (seg is _Alt) {
        final rest = segments.sublist(k + 1);
        for (final key in seg.keys) {
          final hit = _walk(_step(c, key), rest);
          if (hit != null) return hit;
        }
        return null;
      }
      if (seg is! String) return null;
      c = _step(c, seg);
      if (c == null) return null;
    }
    return c;
  }

  /// One key or index into [c]; null when it is not there.
  static Object? _step(Object? c, String seg) {
    if (c is Json) c = c._v;
    if (c is Map) return c[seg];
    if (c is List) {
      if (!_isIndex(seg)) return null;
      final i = int.tryParse(seg);
      return i == null || i >= c.length ? null : c[i];
    }
    return null;
  }
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Json) a = a._v;
  if (b is Json) b = b._v;
  if (identical(a, b)) return true;
  if (a is Map) {
    if (b is! Map || a.length != b.length) return false;
    for (final MapEntry(:key, :value) in a.entries) {
      if (!b.containsKey(key) || !_deepEquals(value, b[key])) return false;
    }
    return true;
  }
  if (a is List) {
    if (b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _deepHash(Object? v) {
  if (v is Json) v = v._v;
  if (v is Map) {
    // Order-free: equal objects with different key order hash the same.
    var h = 0;
    for (final MapEntry(:key, :value) in v.entries) {
      h = (h + Object.hash(key, _deepHash(value))) & 0x3FFFFFFF;
    }
    return Object.hash(Map, h);
  }
  if (v is List) return Object.hashAll(v.map(_deepHash));
  return v.hashCode;
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

/// A path segment that matches more than one key: `*` (one level) or `**`
/// (every depth). Escaped stars (`\*`) stay literal keys.
enum _Wild { any, deep }

/// A segment with `|` alternatives: the first key that leads somewhere wins.
final class _Alt {
  _Alt(this.keys);

  final List<String> keys;
}

/// Split a dotted path, honouring `\` escapes (`\.`, `\*`, `\|`, `\\`).
List<Object> _splitPath(String path) {
  final out = <Object>[];
  final buf = StringBuffer();
  final alts = <String>[];
  var escaped = false;
  void end() {
    final seg = buf.toString();
    if (alts.isNotEmpty) {
      out.add(_Alt([...alts, seg]));
      alts.clear();
    } else {
      out.add(escaped ? seg : (seg == '*' ? _Wild.any : (seg == '**' ? _Wild.deep : seg)));
    }
    buf.clear();
    escaped = false;
  }

  var i = 0;
  while (i < path.length) {
    final c = path.codeUnitAt(i);
    if (c == 0x5C && i + 1 < path.length) {
      final n = path.codeUnitAt(i + 1);
      if (n == 0x2E || n == 0x2A || n == 0x5C || n == 0x7C) {
        buf.writeCharCode(n);
        escaped = true;
        i += 2;
        continue;
      }
      buf.writeCharCode(c);
      i++;
      continue;
    }
    if (c == 0x2E) {
      end();
      i++;
      continue;
    }
    if (c == 0x7C) {
      alts.add(buf.toString());
      buf.clear();
      i++;
      continue;
    }
    buf.writeCharCode(c);
    i++;
  }
  end();
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
/// admits it (e.g. `Map<String, Object?>`), so `asList<Map<String, Object?>>`
/// and `asMap` read the common REST shapes in one pass.
Object? _scalar<E>(Object? e) {
  if (e is E) return e;
  if (e is int) {
    final d = e.toDouble();
    if (d is E) return d;
  } else if (e is double &&
      e.isFinite &&
      e == e.truncateToDouble() &&
      e >= -9223372036854775808.0 &&
      e < 9223372036854775808.0) {
    // 2^63 itself does not fit
    final i = e.toInt();
    if (i is E) return i;
  }
  return _mismatch;
}

/// Bytes → a value. Throws one [ContentException] on invalid JSON, naming
/// where the bytes came from: `invalid JSON from https://x/api (HTTP 503):
/// Unexpected character` (URL credentials redacted; a file names its path).
///
/// [or] is returned when the source does not exist (a missing file:
/// `PathNotFoundException`); every other failure still throws.
extension ReaderJson on Reader {
  Future<Json> json({Json? or}) async {
    final String text;
    try {
      text = await this.text();
    } on PathNotFoundException {
      if (or != null) return or;
      rethrow;
    }
    try {
      return Json._(jsonDecode(text));
    } on FormatException catch (e) {
      // Typed via [Origin]; no `dynamic` probe.
      final o = origin();
      final url = o.url(), path = o.path(), status = o.status();
      final from = url != null ? ' from ${names.redact(url)}' : (path != null ? ' from $path' : '');
      final http = status == null ? '' : ' (HTTP $status)';
      throw ContentException('invalid JSON$from$http: ${e.message}', e.source, e.offset, e);
    }
  }
}

/// Same, from an async reader.
extension ReaderFutureJson on Future<Reader> {
  Future<Json> json({Json? or}) async => (await this).json(or: or);
}

/// The Future mirror (rule 4). The extension name is import-only; never reference it.
extension JsonFuture on Future<Json> {
  Future<Json> $(String path) async => (await this).$(path);
  Future<Json> operator [](int index) async => (await this)[index];
  Future<T?> value<T>() async => (await this).value<T>();
  Future<T> or<T>(T fallback) async => (await this).or(fallback);
  Future<String?> text() async => (await this).text();
  Future<Json> max(num Function(Json item) by) async => (await this).max(by);
  Future<Json> min(num Function(Json item) by) async => (await this).min(by);
  Future<List<T>> asList<T>() async => (await this).asList<T>();
  Future<Map<String, T>> asMap<T>() async => (await this).asMap<T>();
}
