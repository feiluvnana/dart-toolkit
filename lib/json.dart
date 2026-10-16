/// Minimal JSON values. Thin facade over `dart:convert`.
///
/// ```dart
/// final port = await Fs.file('conf.json').json().$('server.port').or(8080);
/// await Fs.file('names.json').write(Json.encode(names, pretty: true));
/// ```
///
/// Public surface is exactly: [Json], [ReaderJson].
/// - `Json.parse()` parses text, `Json.encode()` renders it, `Json.of()`
///   wraps a value you already hold.
/// - `reader.json()` reads one document (`or:` for a missing source),
///   `reader.ndjson()` streams one [Json] per line, `reader.events()` the
///   data of each server-sent event.
/// - [Json] supports `$` (dotted path, `a|b.c` alternatives) `[]` (index the
///   iteration) `value` (typed scalar read; `DateTime` from ISO or Unix time)
///   `or` (read with a default) `text` (any scalar as a string) `texts`
///   (every item's) `max` (the largest item) `asList`/`asMap` (flat
///   collections).
/// - `toJson` lets `jsonEncode` read a nested [Json]; `toString` is the
///   JSON text; `==` compares values deeply.
/// Everything else is private.
library;

import 'dart:convert';

import 'core.dart';
export 'core.dart';

import 'src/missing.dart';
import 'src/names.dart' as names;

/// A JSON value: an object, array, scalar, or null.
final class Json extends Iterable<Json> {
  // A Json held inside another (`Json.of([Json.parse(a), …])`) reads as its value.
  Json._(Object? v, [this._hits = false]) : _v = v is Json ? v._v : v;

  final Object? _v;

  // A `*`/`**` result: scalar reads take the first hit that reads.
  final bool _hits;
  List<dynamic>? _valuesCache;

  /// Parse [json]. Throws [ContentException] on invalid JSON, and on a
  /// document nested deeper than 1,000 levels (`toString` would overflow).
  static Json parse(String json) {
    final Object? v;
    try {
      v = jsonDecode(json);
    } on FormatException catch (e) {
      throw ContentException('invalid JSON: ${e.message}', e.source, e.offset, e);
    }
    if (_tooDeep(json)) throw const ContentException('invalid JSON: nested deeper than $_maxDepth levels');
    return Json._(v);
  }

  /// Wrap a value you already hold (e.g. a decoded `run` result):
  /// no `jsonEncode` → parse round trip. Lets `page.run` skip
  /// re-encoding and lets scripts wrap values without copying them.
  static Json of(Object? decoded) => Json._(decoded);

  /// Render [value] as JSON text. Accepts what `dart:convert` accepts (string
  /// keys) and throws what it throws, plus any [Iterable] (a `Set`, a
  /// `map(...)`) as a list. A [Json] anywhere inside is read as its raw value.
  static String encode(Object? value, {bool pretty = false}) {
    final encoder = pretty ? const JsonEncoder.withIndent('  ', _encodable) : const JsonEncoder(_encodable);
    return encoder.convert(value);
  }

  static Object? _encodable(Object? o) => switch (o) {
    final Json j => j._v,
    final Iterable<Object?> i => i.toList(),
    // What dart:convert's default does: an object's own toJson().
    // ignore: avoid_dynamic_calls
    _ => (o as dynamic).toJson(),
  };

  /// What `jsonEncode` calls: a [Json] inside any encoded value is its raw value.
  Object? toJson() => _v;

  /// Dotted path (`users.0.name`); a numeric segment indexes an array, and a
  /// negative one counts from the end (`items.-1` is the last). A `*`
  /// segment maps over every item: `$('data.users.*.name')` is a [Json] of
  /// the list of names. `*` over an object maps over its values in iteration
  /// order. A `**` segment searches every depth: `$('**.pk')` is a [Json]
  /// list of each `pk` anywhere in the document (document order, nulls and
  /// misses dropped). A wildcard followed by another flattens: `x.*.a.*.b`
  /// is one list of every `b`. A missing path (or a missing key inside `*`)
  /// gives a [Json] holding null, never a throw. `|` separates whole paths
  /// tried in order (`code|shortcode`, `rest_id|legacy.id_str`): the first
  /// that leads to a value wins (a wildcard path that matches nothing is a
  /// miss: `**.a|**.b` reads `b`s when there is no `a`). Use `\` to escape (`\.` for a literal dot,
  /// `\*` a literal star, `\|` a literal bar, `\\` a backslash).
  Json $(String path) {
    if (path.isEmpty) return Json._(_v);
    // One plain key (`name`, `0`): no split, no segment list.
    if (!path.contains('.') && !path.contains(r'\') && !path.contains('|') && path != '*' && path != '**') {
      return Json._(_step(_v, path));
    }
    Object? none; // a wildcard alternative that matched nothing: [] unless a later one hits
    for (final alt in _splitPath(path)) {
      final hit = _walk(_v, alt, 0);
      final wild = alt.any((s) => s is _Wild);
      if (hit is List && hit.isEmpty && wild) {
        none = hit;
      } else if (hit != null) {
        return Json._(hit, wild);
      }
    }
    return Json._(none, none != null);
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
  /// non-null `int`. See [value] for the coercions. A `String` fallback
  /// reads any scalar as [text]: `$('id').or('')` is `'787132'` for the
  /// number 787132.
  T or<T>(T fallback) {
    final v = value<T>();
    if (v != null) return v;
    if (fallback is String) return (text() ?? fallback) as T;
    return fallback;
  }

  /// Any scalar as a `String` (`787132` → `'787132'`, `true` → `'true'`);
  /// null for null, a missing path or a collection. On a `*`/`**` result,
  /// the first hit that is a scalar (`$('**.id').text()`), as `Elements`
  /// read their first match. Not [toString], which renders JSON.
  String? text() {
    final v = _v;
    if (_hits && v is List) {
      for (final i in v) {
        if (Json._(i).text() case final t?) return t;
      }
      return null;
    }
    return switch (v) {
      final String s => s,
      final num n => '$n',
      final bool b => '$b',
      _ => null,
    };
  }

  /// Every item's [text], misses dropped, as `Elements.texts()` gives every
  /// match's: `data.$('**.uri').texts()` is each `uri` found as a string. A
  /// scalar gives itself, null gives none.
  List<String> texts() => switch (_v) {
    final List<Object?> items => [for (final i in items) ?Json._(i).text()],
    final Map<Object?, Object?> items => [for (final i in items.values) ?Json._(i).text()],
    _ => [?text()],
  };

  /// The item (array item or object value) with the largest [by], or a null
  /// [Json] when there are none; the first wins a tie. The smallest is
  /// `max((i) => -by(i))`.
  Json max(num Function(Json item) by) {
    Json? best;
    num? score;
    for (final item in this) {
      final s = by(item);
      if (score == null || s > score) {
        best = item;
        score = s;
      }
    }
    return best ?? Json._(null);
  }

  /// The value when it is a `T`, else null; on a `*`/`**` result, the first
  /// hit that is a `T` (`$('**.publish_time').value<DateTime>()`).
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
  /// read as they are. A `DateTime` reads an ISO 8601 string or a Unix
  /// time in s, ms, µs or ns (a number or a string of digits), as
  /// APIs and embedded page data write it.
  T? value<T>() {
    final v = _v;
    if (v is T) return v;
    if (_hits && v is List) {
      // A `*`/`**` result reads its first hit that is a `T`.
      for (final i in v) {
        if (Json._(i).value<T>() case final r?) return r;
      }
      return null;
    }
    if (<T>[] is List<DateTime?>) return _date(v) as T?;
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
  /// `asList<Json>()` wraps every item, whatever its shape.
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
  /// `asMap<Json>()` wraps every value, so nested data reads on:
  /// `doc.$('posts').asMap<Json>()['p1']?.$('id')`.
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
  /// When a wildcard is followed by another, each item's hits (a list) are
  /// spread into one list instead of nesting.
  static Object? _walk(Object? cur, List<Object> segments, int from) {
    Object? c = cur;
    for (var k = from; k < segments.length; k++) {
      if (c is Json) c = c._v;
      final seg = segments[k];
      if (seg is _Wild) {
        var flat = false;
        for (var j = k + 1; j < segments.length && !flat; j++) {
          flat = segments[j] is _Wild;
        }
        final out = <Object?>[];
        void hit(Object? h) {
          if (!flat) {
            out.add(h);
          } else if (h is List) {
            out.addAll(h);
          }
        }

        if (seg == _Wild.deep) {
          // An explicit stack in document order: a parsed document may nest
          // deeper than the call stack.
          final stack = <Object?>[c];
          while (stack.isNotEmpty) {
            var node = stack.removeLast();
            if (node is Json) node = node._v;
            final h = k + 1 == segments.length ? node : _walk(node, segments, k + 1);
            if (h != null) hit(h);
            final kids = node is Map ? node.values.toList() : (node is List ? node : const <Object?>[]);
            for (var i = kids.length - 1; i >= 0; i--) {
              stack.add(kids[i]);
            }
          }
          return out;
        }
        final Iterable<Object?> items;
        if (c is List) {
          items = c;
        } else if (c is Map) {
          items = c.values;
        } else {
          return null;
        }
        for (final item in items) {
          hit(_walk(item, segments, k + 1));
        }
        return out;
      }
      c = _step(c, seg as String);
      if (c == null) return null;
    }
    return c;
  }

  /// One key or index into [c]; null when it is not there. A negative
  /// index counts from the end.
  static Object? _step(Object? c, String seg) {
    if (c is Json) c = c._v;
    if (c is Map) return c[seg];
    if (c is List) {
      final neg = seg.startsWith('-');
      final digits = neg ? seg.substring(1) : seg;
      if (!_isIndex(digits) || (neg && digits == '0')) return null;
      final n = int.tryParse(digits);
      if (n == null) return null;
      final i = neg ? c.length - n : n;
      return i < 0 || i >= c.length ? null : c[i];
    }
    return null;
  }
}

/// Deep equality without recursion: a parsed document may nest deeper
/// than the call stack.
bool _deepEquals(Object? a, Object? b) {
  final todo = <(Object?, Object?)>[(a, b)];
  while (todo.isNotEmpty) {
    var (x, y) = todo.removeLast();
    if (x is Json) x = x._v;
    if (y is Json) y = y._v;
    if (identical(x, y)) continue;
    if (x is Map) {
      if (y is! Map || x.length != y.length) return false;
      for (final MapEntry(:key, :value) in x.entries) {
        if (!y.containsKey(key)) return false;
        todo.add((value, y[key]));
      }
    } else if (x is List) {
      if (y is! List || x.length != y.length) return false;
      for (var i = 0; i < x.length; i++) {
        todo.add((x[i], y[i]));
      }
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

/// Hashes the top 32 levels: deeper ones only refine it, and equality
/// still decides, so a document deeper than the call stack hashes too.
int _deepHash(Object? v, [int depth = 0]) {
  if (v is Json) v = v._v;
  if (depth > 32) return v is Map || v is List ? 1 : v.hashCode;
  if (v is Map) {
    // Order-free: equal objects with different key order hash the same.
    var h = 0;
    for (final MapEntry(:key, :value) in v.entries) {
      h = (h + Object.hash(key, _deepHash(value, depth + 1))) & 0x3FFFFFFF;
    }
    return Object.hash(Map, h);
  }
  if (v is List) return Object.hashAll([for (final e in v) _deepHash(e, depth + 1)]);
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

/// Split a path into its `|` alternatives, each a list of dotted segments,
/// honouring `\` escapes (`\.`, `\*`, `\|`, `\\`).
List<List<Object>> _splitPath(String path) {
  final alts = <List<Object>>[];
  var out = <Object>[];
  final buf = StringBuffer();
  var escaped = false;
  void end() {
    final seg = buf.toString();
    out.add(escaped ? seg : (seg == '*' ? _Wild.any : (seg == '**' ? _Wild.deep : seg)));
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
    if (c == 0x2E || c == 0x7C) {
      end();
      if (c == 0x7C) {
        alts.add(out);
        out = <Object>[];
      }
      i++;
      continue;
    }
    buf.writeCharCode(c);
    i++;
  }
  end();
  alts.add(out);
  return alts;
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

/// [v] as a time: ISO 8601 text, or a Unix epoch in seconds, milliseconds,
/// microseconds or nanoseconds (a number, or digits as text), told apart by
/// size: below 10^11 seconds (until the year 5138), then ms below 10^14, µs
/// below 10^17 and ns below 10^19.
DateTime? _date(Object? v) {
  final n = switch (v) {
    final num n => n,
    final String s => num.tryParse(s.trim()),
    _ => null,
  };
  if (n == null) return v is String ? DateTime.tryParse(v.trim()) : null;
  final size = n.abs();
  final ms = size < 1e11
      ? n * 1000
      : size < 1e14
      ? n
      : size < 1e17
      ? n / 1000
      : size < 1e19
      ? n / 1e6
      : double.infinity;
  // DateTime holds ±8.64e15 ms: past that (a snowflake id) it is not a time.
  if (!ms.isFinite || ms.abs() > 8.64e15) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms.round());
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
  if (<E>[] is List<Json?> && <Json>[] is List<E>) return Json._(e); // E is Json or Json?
  if (e is E) return e;
  if (<E>[] is List<DateTime?>) return _date(e) ?? _mismatch;
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
/// [or] is returned when the source is missing (a missing file, an HTTP
/// 404 or 410); every other failure still throws.
extension ReaderJson on Reader {
  /// The body decoded as JSON; [or] when the source is missing.
  Future<Json> json({Json? or}) => orMissing(this, or, _json);

  /// NDJSON (JSON Lines): one [Json] per non-blank line, as the lines
  /// arrive, so a large log reads in constant memory. A bad line is a
  /// [ContentException] naming the source and the line number.
  Stream<Json> ndjson() async* {
    var n = 0;
    await for (final line in lines()) {
      n++;
      if (line.trim().isEmpty) continue;
      final Object? v;
      try {
        v = jsonDecode(line);
      } on FormatException catch (e) {
        throw ContentException('invalid JSON${_from(origin())} at line $n: ${e.message}', e.source, e.offset, e);
      }
      if (_tooDeep(line)) {
        throw ContentException('invalid JSON${_from(origin())} at line $n: nested deeper than $_maxDepth levels');
      }
      yield Json._(v);
    }
  }

  /// Server-sent events (`text/event-stream`): each event's data as it
  /// arrives, its `data:` lines joined by `\n` (`reader.events().map(Json.parse)`
  /// for LLM streaming APIs). Comments, `event:`, `id:` and `retry:` are
  /// skipped, one space after the colon is dropped, and an event the source
  /// ends before its blank line is not given, as the SSE standard says.
  Stream<String> events() async* {
    final data = StringBuffer();
    var any = false, first = true;
    await for (var line in lines()) {
      if (first) {
        first = false;
        if (line.startsWith('\uFEFF')) line = line.substring(1);
      }
      if (line.isEmpty) {
        if (any) yield '$data';
        data.clear();
        any = false;
        continue;
      }
      final colon = line.indexOf(':');
      if (colon == 0) continue;
      if ((colon < 0 ? line : line.substring(0, colon)) != 'data') continue;
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (any) data.write('\n');
      data.write(value);
      any = true;
    }
  }
}

/// How deep a parsed document may nest: `toString` and `encode` recurse,
/// and overflow the stack a few thousand levels down.
const _maxDepth = 1000;

/// Whether the JSON text [s] nests deeper than [_maxDepth] (brackets in
/// strings skipped); a linear scan, a tenth of the decode.
bool _tooDeep(String s) {
  if (s.length <= 2 * _maxDepth) return false;
  var depth = 0;
  final n = s.length;
  for (var i = 0; i < n; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x22) {
      for (i++; i < n; i++) {
        final d = s.codeUnitAt(i);
        if (d == 0x5C) {
          i++;
        } else if (d == 0x22) {
          break;
        }
      }
    } else if (c == 0x5B || c == 0x7B) {
      if (++depth > _maxDepth) return true;
    } else if (c == 0x5D || c == 0x7D) {
      depth--;
    }
  }
  return false;
}

/// [_tooDeep] over UTF-8 [b] (no ASCII byte occurs inside a multibyte one).
bool _tooDeepBytes(List<int> b) {
  if (b.length <= 2 * _maxDepth) return false;
  var depth = 0;
  final n = b.length;
  for (var i = 0; i < n; i++) {
    final c = b[i];
    if (c == 0x22) {
      for (i++; i < n; i++) {
        final d = b[i];
        if (d == 0x5C) {
          i++;
        } else if (d == 0x22) {
          break;
        }
      }
    } else if (c == 0x5B || c == 0x7B) {
      if (++depth > _maxDepth) return true;
    } else if (c == 0x5D || c == 0x7D) {
      depth--;
    }
  }
  return false;
}

/// UTF-8 straight into JSON: faster than `text()` + `jsonDecode` (no
/// intermediate string), malformed bytes replaced like `text()`.
final _utf8Json = const Utf8Decoder(allowMalformed: true).fuse(const JsonDecoder());

/// ` from <url|path> (HTTP <status>)` for an error message (URL
/// credentials redacted), or `''` when the reader names no source.
String _from(Origin o) {
  final url = o.url(), path = o.path(), status = o.status();
  final from = url != null ? ' from ${names.redact(url)}' : (path != null ? ' from $path' : '');
  return status == null ? from : '$from (HTTP $status)';
}

Future<Json> _json(Reader r) async {
  final bytes = await r.bytes();
  final Object? v;
  try {
    // Decodes the bytes directly, without a String in between.
    v = _utf8Json.convert(bytes);
  } on FormatException catch (e) {
    throw ContentException('invalid JSON${_from(r.origin())}: ${e.message}', e.source, e.offset, e);
  }
  if (_tooDeepBytes(bytes)) throw ContentException('invalid JSON${_from(r.origin())}: nested deeper than $_maxDepth levels');
  return Json._(v);
}

/// Same, from an async reader.
extension ReaderFutureJson on Future<Reader> {
  Future<Json> json({Json? or}) => orMissing(this, or, (r) => r.json());
  Stream<Json> ndjson() => Stream.fromFuture(this).asyncExpand((r) => r.ndjson());
  Stream<String> events() => Stream.fromFuture(this).asyncExpand((r) => r.events());
}

/// The Future mirror (rule 4). The extension name is import-only; never reference it.
extension JsonFuture on Future<Json> {
  Future<Json> $(String path) async => (await this).$(path);
  Future<Json> operator [](int index) async => (await this)[index];
  Future<T?> value<T>() async => (await this).value<T>();
  Future<T> or<T>(T fallback) async => (await this).or(fallback);
  Future<String?> text() async => (await this).text();
  Future<List<String>> texts() async => (await this).texts();
  Future<Json> max(num Function(Json item) by) async => (await this).max(by);
  Future<List<T>> asList<T>() async => (await this).asList<T>();
  Future<Map<String, T>> asMap<T>() async => (await this).asMap<T>();
}
