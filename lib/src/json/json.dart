import 'dart:collection';
import 'dart:convert';

import '../core/errors.dart';
import '../core/pipe.dart';
import '../core/traits.dart';

export '../core/errors.dart';
export '../core/pipe.dart';
export '../core/traits.dart';

/// An immutable JSON value. `Json.parse` reads text; `Json(value)` wraps a Map/List/scalar.
final class Json {
  /// Wraps [value] (a Map, List or scalar), deep-copied into unmodifiable
  /// collections, so the [Json] never changes under its readers.
  Json(Object? value) : value = _frozen(value);

  /// Parses JSON [text] into an immutable value.
  static Json parse(String text) => Json._(_frozenDecoded(jsonDecode(text)));

  Json._(this.value);

  /// The plain value: an unmodifiable `Map<String, Object?>`, `List<Object?>`, or a scalar.
  final Object? value;

  /// The value at a dotted [path] (`'server.ports.0'`; `''` is the root; `\\.` is a dot inside
  /// a key) typed as [T].
  ///
  /// A missing value answers [or], or `null` when [T] is nullable, else throws a
  /// [MissingException] naming the path. A number converts between `int` and `double` (a
  /// fraction never becomes an `int`); any other type is a [FormatException] naming the path
  /// and both types.
  T get<T>(String path, {T? or}) {
    Object? current = value;
    for (final part in _segments(path)) {
      if (current is Map) {
        if (!current.containsKey(part)) return _miss<T>(path, or);
        current = current[part];
      } else if (current is List) {
        final idx = int.tryParse(part);
        if (idx == null || idx < 0 || idx >= current.length) return _miss<T>(path, or);
        current = current[idx];
      } else {
        return _miss<T>(path, or);
      }
    }
    if (current is T) return current;
    if (current is num) {
      if (T == double || T == _type<double?>()) return current.toDouble() as T;
      if ((T == int || T == _type<int?>()) && current == current.truncate()) return current.toInt() as T;
    }
    if (current == null) return _miss<T>(path, or);
    throw FormatException('${path.isEmpty ? 'The root' : path} is ${_kind(current)}, not $T');
  }

  /// One step: a key on an object, an index on an array, as a Json.
  Json operator [](Object key) {
    final v = value;
    if (key is String && v is Map) {
      if (!v.containsKey(key)) throw MissingException(key, where: 'JSON');
      return Json._(v[key]);
    }
    if (key is int && v is List) {
      if (key < 0 || key >= v.length) throw MissingException('$key', where: 'JSON');
      return Json._(v[key]);
    }
    throw ArgumentError.value(key, 'key', 'A String on an object, an int on an array');
  }

  /// Encodes this value as JSON; [pretty] indents with two spaces.
  String encode({bool pretty = false}) =>
      pretty ? const JsonEncoder.withIndent('  ').convert(value) : jsonEncode(value);

  /// Saves the encoding to [to] (atomically for a file).
  Future<void> save(Target to, {bool pretty = false}) => utf8.encode(encode(pretty: pretty)).pipe(to);

  @override
  String toString() => encode();

  @override
  bool operator ==(Object other) => other is Json && _deepEquals(other.value, value);

  @override
  int get hashCode => _deepHash(value);
}

Type _type<X>() => X;

/// The path's keys: split at dots, except a `\\.` inside a key; `''` is the root.
List<String> _segments(String path) {
  if (path.isEmpty) return const [];
  if (!path.contains(r'\')) return path.split('.');
  final parts = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < path.length; i++) {
    final c = path[i];
    if (c == r'\' && i + 1 < path.length && path[i + 1] == '.') {
      current.write('.');
      i++;
    } else if (c == '.') {
      parts.add(current.toString());
      current.clear();
    } else {
      current.write(c);
    }
  }
  parts.add(current.toString());
  return parts;
}

/// A missing value: [or], else `null` when [T] admits it, else a [MissingException].
T _miss<T>(String path, T? or) {
  if (or != null) return or;
  if (null is T) return null as T;
  throw MissingException(path.isEmpty ? 'value' : path, where: 'JSON');
}

/// [value]'s JSON kind, for messages.
String _kind(Object? value) => switch (value) {
  null => 'null',
  String() => 'a string',
  num() => 'a number',
  bool() => 'a boolean',
  Map() => 'an object',
  List() => 'an array',
  _ => 'a ${value.runtimeType}',
};

/// [value] deep-copied into unmodifiable collections (object keys are strings,
/// as JSON requires).
Object? _frozen(Object? value) {
  if (value is Map) {
    final out = <String, Object?>{};
    for (final e in value.entries) {
      final key = e.key;
      if (key is! String) throw ArgumentError.value(key, 'key', 'A JSON object key must be a String');
      out[key] = _frozen(e.value);
    }
    return Map<String, Object?>.unmodifiable(out);
  }
  if (value is List) {
    return List<Object?>.unmodifiable([for (final e in value) _frozen(e)]);
  }
  if (value == null || value is bool || value is String) return value;
  if (value is num) {
    if (!value.isFinite) throw ArgumentError.value(value, 'value', 'JSON has no NaN or infinity');
    return value;
  }
  throw ArgumentError.value(value, 'value', 'Not a JSON value (null, bool, num, String, List or Map)');
}

/// Freshly decoded JSON frozen lazily: the root is wrapped, and every nested
/// map or list is wrapped when first read — never copied, never walked up
/// front. `parse` costs the decode plus one wrapper, whatever the size.
Object? _frozenDecoded(Object? value) {
  if (value is Map<String, dynamic>) return _LazyJsonMap(value);
  if (value is List) return _LazyJsonList(value);
  return value;
}

/// A decoded value wrapped on first read.
Object? _freezeOnRead(Object? value) {
  if (value is Map<String, dynamic>) return _LazyJsonMap(value);
  if (value is List) return _LazyJsonList(value);
  return value;
}

/// An unmodifiable view over a decoded object: children wrap on read.
final class _LazyJsonMap with MapMixin<String, Object?> {
  final Map<String, dynamic> _inner;

  _LazyJsonMap(this._inner);

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  int get length => _inner.length;

  @override
  bool containsKey(Object? key) => _inner.containsKey(key);

  @override
  Object? operator [](Object? key) => _freezeOnRead(_inner[key]);

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('A Json value is immutable');

  @override
  Object? remove(Object? key) => throw UnsupportedError('A Json value is immutable');

  @override
  void clear() => throw UnsupportedError('A Json value is immutable');
}

/// An unmodifiable view over a decoded array: children wrap on read.
final class _LazyJsonList with ListMixin<Object?> {
  final List<dynamic> _inner;

  _LazyJsonList(this._inner);

  @override
  int get length => _inner.length;

  @override
  set length(int length) => throw UnsupportedError('A Json value is immutable');

  @override
  Object? operator [](int index) => _freezeOnRead(_inner[index]);

  @override
  void operator []=(int index, Object? value) => throw UnsupportedError('A Json value is immutable');
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

int _deepHash(Object? value) {
  if (value is Map) {
    // Unordered: equal maps hash equal whatever their key order.
    return Object.hashAllUnordered([for (final e in value.entries) Object.hash(e.key, _deepHash(e.value))]);
  }
  if (value is List) {
    return Object.hashAll([for (final e in value) _deepHash(e)]);
  }
  return value.hashCode;
}

/// `File('a.json').json()`, `Http.get(u).json()`.
extension SourceJson on Source {
  /// The body parsed as JSON.
  Future<Json> json() async => Json.parse(await text());
}
