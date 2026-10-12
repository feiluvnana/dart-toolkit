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

  /// The value at a dotted [path] (`'server.ports.0'`) typed as [T]; [or] when it is
  /// missing or another type, else a MissingException naming the path.
  T get<T>(String path, {Object? or = _absent}) {
    Object? current = value;
    for (final part in path.split('.')) {
      if (current is Map) {
        if (!current.containsKey(part)) return _miss(path, or);
        current = current[part];
      } else if (current is List) {
        final idx = int.tryParse(part);
        if (idx == null || idx < 0 || idx >= current.length) return _miss(path, or);
        current = current[idx];
      } else {
        return _miss(path, or);
      }
    }
    if (current is T) return current;
    return _miss(path, or);
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

/// No `or:` was given to [Json.get].
const _absent = Object();

T _miss<T>(String path, Object? or) {
  if (!identical(or, _absent)) return or as T;
  throw MissingException(path, where: 'JSON');
}

/// [value] deep-copied into unmodifiable collections (object keys are strings,
/// as JSON requires).
Object? _frozen(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable({for (final e in value.entries) '${e.key}': _frozen(e.value)});
  }
  if (value is List) {
    return List<Object?>.unmodifiable([for (final e in value) _frozen(e)]);
  }
  return value;
}

/// Decoded JSON deep-copied into unmodifiable collections.
Object? _frozenDecoded(Object? value) {
  if (value is Map<String, dynamic>) {
    return Map<String, Object?>.unmodifiable({for (final e in value.entries) e.key: _frozenDecoded(e.value)});
  }
  if (value is List) {
    return List<Object?>.unmodifiable([for (final e in value) _frozenDecoded(e)]);
  }
  return value;
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
    return Object.hashAll([for (final e in value.entries) Object.hash(e.key, _deepHash(e.value))]);
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
