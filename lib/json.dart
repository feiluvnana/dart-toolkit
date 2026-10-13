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
  List<dynamic>? _valuesCache;

  /// Parse [json]. Throws [FormatException] on invalid JSON.
  static Json parse(String json) {
    try {
      return Json._(jsonDecode(json));
    } on FormatException catch (e) {
      throw FormatException('invalid JSON: ${e.message}', e.source, e.offset);
    }
  }

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
  /// Integral numbers read as both `int` and `double`, so `3`, `3.0`,
  /// `value<int>()` and `value<double>()` all agree (a non-integral `double`
  /// is not an `int`). `value<List<T>>()` and `value<Map<String, T>>()` check
  /// each element: the whole read is null unless every element converts (for
  /// example `p.$('tags').value<List<int>>()`). Use `num` for numbers that
  /// may be either, `Object` for the raw value.
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
    if (v is List) return _valueList<T>(v);
    if (v is Map) return _valueMap<T>(v);
    return null;
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
        final i = int.parse(seg);
        if (i < 0 || i >= c.length) return null;
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

/// Mismatch marker for the element converters below. It never escapes: every
/// use checks `identical(c, _mismatch)` before the value can leave.
final Object _mismatch = Object();

/// Convert [e] to [E]: a match, an integral-number coercion, or [_mismatch].
/// `null` converts only when [E] admits it (`Null`, `E?`, `dynamic`…).
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

/// An element converter for lists of [S], built from a value converter.
Object? Function(Object?) _listOf<S>(Object? Function(Object?) convert) {
  return (Object? e) {
    if (e is! List) return _mismatch;
    final out = <S>[];
    for (final x in e) {
      final c = convert(x);
      if (identical(c, _mismatch)) return _mismatch;
      out.add(c as S);
    }
    return out;
  };
}

/// An element converter for maps with string keys and [V] values.
Object? Function(Object?) _mapOf<V>(Object? Function(Object?) convert) {
  return (Object? e) {
    if (e is! Map) return _mismatch;
    final out = <String, V>{};
    for (final entry in e.entries) {
      final k = entry.key;
      if (k is! String) return _mismatch;
      final c = convert(entry.value);
      if (identical(c, _mismatch)) return _mismatch;
      out[k] = c as V;
    }
    return out;
  };
}

/// Read list [v] as [T]: null unless [T] is a list shape and every element
/// converts. Each `attempt` builds one static element type and keeps it only
/// when it `is T`, so the returned list is genuinely typed.
T? _valueList<T>(List<dynamic> v) {
  if (<Never>[] is! T) return null;
  T? attempt<E>(Object? Function(Object? element) convert) {
    final out = <E>[];
    for (final e in v) {
      final c = convert(e);
      if (identical(c, _mismatch)) return null;
      out.add(c as E);
    }
    if (out is T) return out as T;
    return null;
  }

  return attempt<int>(_scalar<int>) ??
      attempt<double>(_scalar<double>) ??
      attempt<num>(_scalar<num>) ??
      attempt<String>(_scalar<String>) ??
      attempt<bool>(_scalar<bool>) ??
      attempt<int?>(_scalar<int?>) ??
      attempt<double?>(_scalar<double?>) ??
      attempt<num?>(_scalar<num?>) ??
      attempt<String?>(_scalar<String?>) ??
      attempt<bool?>(_scalar<bool?>) ??
      attempt<Null>(_scalar<Null>) ??
      attempt<List<int>>(_listOf<int>(_scalar<int>)) ??
      attempt<List<double>>(_listOf<double>(_scalar<double>)) ??
      attempt<List<num>>(_listOf<num>(_scalar<num>)) ??
      attempt<List<String>>(_listOf<String>(_scalar<String>)) ??
      attempt<List<bool>>(_listOf<bool>(_scalar<bool>)) ??
      attempt<List<int?>>(_listOf<int?>(_scalar<int?>)) ??
      attempt<List<String?>>(_listOf<String?>(_scalar<String?>)) ??
      attempt<List<double?>>(_listOf<double?>(_scalar<double?>)) ??
      attempt<List<bool?>>(_listOf<bool?>(_scalar<bool?>)) ??
      attempt<List<List<int>>>(_listOf<List<int>>(_listOf<int>(_scalar<int>))) ??
      attempt<List<List<String>>>(
        _listOf<List<String>>(_listOf<String>(_scalar<String>)),
      ) ??
      attempt<List<List<bool>>>(
        _listOf<List<bool>>(_listOf<bool>(_scalar<bool>)),
      ) ??
      attempt<Map<String, int>>(_mapOf<int>(_scalar<int>)) ??
      attempt<Map<String, String>>(_mapOf<String>(_scalar<String>)) ??
      attempt<Map<String, double>>(_mapOf<double>(_scalar<double>)) ??
      attempt<Map<String, bool>>(_mapOf<bool>(_scalar<bool>)) ??
      attempt<Map<String, num>>(_mapOf<num>(_scalar<num>)) ??
      attempt<Map<String, List<bool>>>(
        _mapOf<List<bool>>(_listOf<bool>(_scalar<bool>)),
      ) ??
      attempt<Object>(_scalar<Object>) ??
      attempt<Object?>(_scalar<Object?>) ??
      attempt<dynamic>(_scalar<dynamic>);
}

/// Read map [v] as [T]: null unless [T] is a map shape, every key is a
/// string, and every value converts.
T? _valueMap<T>(Map<dynamic, dynamic> v) {
  if (<Never, Never>{} is! T) return null;
  T? attempt<V>(Object? Function(Object? value) convert) {
    final out = <String, V>{};
    for (final entry in v.entries) {
      final k = entry.key;
      if (k is! String) return null;
      final c = convert(entry.value);
      if (identical(c, _mismatch)) return null;
      out[k] = c as V;
    }
    if (out is T) return out as T;
    return null;
  }

  return attempt<int>(_scalar<int>) ??
      attempt<double>(_scalar<double>) ??
      attempt<num>(_scalar<num>) ??
      attempt<String>(_scalar<String>) ??
      attempt<bool>(_scalar<bool>) ??
      attempt<int?>(_scalar<int?>) ??
      attempt<double?>(_scalar<double?>) ??
      attempt<num?>(_scalar<num?>) ??
      attempt<String?>(_scalar<String?>) ??
      attempt<bool?>(_scalar<bool?>) ??
      attempt<Null>(_scalar<Null>) ??
      attempt<List<int>>(_listOf<int>(_scalar<int>)) ??
      attempt<List<String>>(_listOf<String>(_scalar<String>)) ??
      attempt<List<double>>(_listOf<double>(_scalar<double>)) ??
      attempt<List<bool>>(_listOf<bool>(_scalar<bool>)) ??
      attempt<List<num>>(_listOf<num>(_scalar<num>)) ??
      attempt<List<int?>>(_listOf<int?>(_scalar<int?>)) ??
      attempt<List<String?>>(_listOf<String?>(_scalar<String?>)) ??
      attempt<List<bool?>>(_listOf<bool?>(_scalar<bool?>)) ??
      attempt<Map<String, int>>(_mapOf<int>(_scalar<int>)) ??
      attempt<Map<String, String>>(_mapOf<String>(_scalar<String>)) ??
      attempt<Map<String, double>>(_mapOf<double>(_scalar<double>)) ??
      attempt<Map<String, bool>>(_mapOf<bool>(_scalar<bool>)) ??
      attempt<Map<String, num>>(_mapOf<num>(_scalar<num>)) ??
      attempt<List<bool>>(_listOf<bool>(_scalar<bool>)) ??
      attempt<Map<String, List<bool>>>(
        _mapOf<List<bool>>(_listOf<bool>(_scalar<bool>)),
      ) ??
      attempt<Map<String, Map<String, bool>>>(
        _mapOf<Map<String, bool>>(_mapOf<bool>(_scalar<bool>)),
      ) ??
      attempt<Object>(_scalar<Object>) ??
      attempt<Object?>(_scalar<Object?>) ??
      attempt<dynamic>(_scalar<dynamic>);
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

/// The status of a response-like reader, or null for anything else.
/// Dynamic so this module never imports http or fs.
int? _statusOf(Reader reader) {
  try {
    // ignore: avoid_dynamic_calls
    final s = (reader as dynamic).status() as int?;
    return s;
  } catch (_) {
    return null;
  }
}

/// Annotate a content [FormatException] with the HTTP status when the
/// reader is an error page.
FormatException _withStatus(Reader reader, FormatException e) {
  final status = _statusOf(reader);
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
}
