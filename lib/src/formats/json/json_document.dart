part of '../../../formats.dart';

/// A parsed JSON document with JSONPath selector, indexing, and serialization support.
///
/// {@category Formats}
class JsonDocument {
  /// The underlying raw JSON value (Map, List, or primitive).
  final Object? raw;

  /// Where this sits in the document it came from, for the error [to] throws: `$.a[0]`.
  final String _path;

  /// Creates a [JsonDocument] wrapping a [raw] JSON value.
  const JsonDocument(this.raw) : _path = r'$';

  const JsonDocument._at(this.raw, this._path);

  /// Parses [text] as JSON.
  factory JsonDocument.parse(String text) => JsonDocument(jsonDecode(text));

  /// The document in the file at [path], read as its extension says: `.json`, `.yaml` or
  /// `.yml`, `.toml`, and `.ini`, `.cfg` or `.conf`. Any other extension is a
  /// [FormatException] naming the ones it knows. A YAML stream reads as its first document.
  static Future<JsonDocument> read(String path) async {
    final dot = path.lastIndexOf('.');
    final ext = dot == -1 || path.indexOf('/', dot) != -1 ? '' : path.substring(dot + 1).toLowerCase();
    final JsonDocument Function(String) parse = switch (ext) {
      'json' => JsonDocument.parse,
      'yaml' || 'yml' => (t) => t.yaml,
      'toml' => (t) => t.toml,
      'ini' || 'cfg' || 'conf' => (t) => t.ini,
      _ => throw FormatException(
        '$path: cannot read ${ext.isEmpty ? 'a file with no extension' : '".$ext"'}; '
        'json, yaml, yml, toml, ini, cfg and conf can be read',
      ),
    };
    return parse(await File(path).readAsString());
  }

  /// Every value JSONPath [expression] selects: `$.store.book[*].author`, `$..id`,
  /// `$.items[0,2]`, `$.items[-2:]`, `$['a','b']`. Filters are not supported — `.where` on
  /// the result is shorter.
  List<JsonDocument> $(String expression) {
    final at = _path == r'$' ? '' : _path;
    return [
      for (final (i, v) in _JsonPath.of(expression).read(raw).indexed) JsonDocument._at(v, '$at($expression)[$i]'),
    ];
  }

  /// Accesses a child node by map key ([String]) or list index ([int]).
  ///
  /// A negative index counts from the end, as `$[-1]` does. A missing key or an
  /// out-of-range index yields the null document; any other key type throws
  /// [ArgumentError].
  JsonDocument operator [](Object keyOrIndex) {
    switch (keyOrIndex) {
      case final String k:
        return JsonDocument._at(raw is Map ? (raw as Map)[k] : null, _key(k));
      case final int i:
        final l = raw is List ? raw as List : const <Object?>[];
        final at = i < 0 ? l.length + i : i;
        return JsonDocument._at(at >= 0 && at < l.length ? l[at] : null, '$_path[$i]');
      default:
        throw ArgumentError.value(keyOrIndex, 'keyOrIndex', 'Must be a String key or an int index');
    }
  }

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  String _key(String k) => _identifier.hasMatch(k) ? '$_path.$k' : "$_path['${k.replaceAll("'", r"\'")}']";

  /// Whether this JSON document represents null.
  bool get isNull => raw == null;

  /// Returns [raw] as a list of [JsonDocument]s, or empty list.
  List<JsonDocument> get list => switch (raw) {
    final List<Object?> l => [for (final (i, v) in l.indexed) JsonDocument._at(v, '$_path[$i]')],
    _ => const [],
  };

  /// Returns [raw] as a map of String to [JsonDocument]s, or empty map.
  Map<String, JsonDocument> get map => switch (raw) {
    final Map<Object?, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries)
        if (key is String ? key : '$key' case final k) k: JsonDocument._at(value, _key(k)),
    },
    _ => const {},
  };

  /// This value as [T], or a [StateError] naming where it is and what it was.
  ///
  /// A number or boolean written as text reads as one (`"42"`, `"true"`); anything asked
  /// for as `String` is text, a map or list as JSON; an integral double is an `int`, and a
  /// fraction is not — `1.7` does not quietly become `1`. `List<E>` and `Map<String, E>`
  /// convert every element, for `E` of `String`, `int`, `double`, `num` or `bool`. A nullable
  /// [T] accepts null.
  T to<T>() {
    final v = _as<T>(raw, _path, strict: true);
    if (v is T && !identical(v, _miss)) return v;
    final what = raw == null ? 'null' : '${_describe(raw)} (${raw.runtimeType})';
    throw StateError('$_path is $what, expected $T');
  }

  /// [to] for the caller who expects absence: `null` when this is null or is not a [T].
  T? toOrNull<T>() {
    final v = _as<T>(raw, _path, strict: false);
    return v is T && !identical(v, _miss) ? v : null;
  }

  /// Converts this document to a JSON encoded string. A NaN or an infinity — which YAML
  /// has and JSON does not — is written as `null`, as JavaScript writes it.
  @override
  String toString() => _encode(raw);
}

/// Stands for "no conversion" where `null` is a valid answer.
const _miss = Object();

Type _typeOf<X>() => X;

/// [v] as [T], or [_miss]. With [strict], an element of a list or map that does not convert
/// throws a [StateError] naming it rather than failing the whole value anonymously.
Object? _as<T>(Object? v, String path, {required bool strict}) {
  if (v is T) return v;
  if (v == null) return _miss;
  bool same<X>() => T == X || T == _typeOf<X?>();
  if (same<String>()) return v is Map || v is List ? _encode(v) : '$v';
  if (same<num>()) return v is String ? num.tryParse(v.trim()) ?? _miss : _miss;
  if (same<int>()) {
    return switch (v) {
      final double d when d.isFinite && d == d.truncateToDouble() => d.toInt(),
      final String s => int.tryParse(s.trim()) ?? _miss,
      _ => _miss,
    };
  }
  if (same<double>()) {
    return switch (v) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s.trim()) ?? _miss,
      _ => _miss,
    };
  }
  if (same<bool>()) {
    return switch (v) {
      'true' || 1 => true,
      'false' || 0 => false,
      _ => _miss,
    };
  }
  if (v is List) {
    if (same<List<String>>()) return _eachOf<String>(v, path, strict);
    if (same<List<int>>()) return _eachOf<int>(v, path, strict);
    if (same<List<double>>()) return _eachOf<double>(v, path, strict);
    if (same<List<num>>()) return _eachOf<num>(v, path, strict);
    if (same<List<bool>>()) return _eachOf<bool>(v, path, strict);
  }
  if (v is Map) {
    if (same<Map<String, String>>()) return _eachOf<String>(v, path, strict);
    if (same<Map<String, int>>()) return _eachOf<int>(v, path, strict);
    if (same<Map<String, double>>()) return _eachOf<double>(v, path, strict);
    if (same<Map<String, num>>()) return _eachOf<num>(v, path, strict);
    if (same<Map<String, bool>>()) return _eachOf<bool>(v, path, strict);
  }
  return _miss;
}

/// Every element of the list or map [v] as [E], in a `List<E>` or `Map<String, E>`, or
/// [_miss] when one does not convert.
Object _eachOf<E>(Object v, String path, bool strict) {
  Object? one(Object? x, String at) {
    final e = _as<E>(x, at, strict: strict);
    if (e is E && !identical(e, _miss)) return e;
    return strict ? throw StateError('$at is ${x == null ? 'null' : _describe(x)}, expected $E') : _miss;
  }

  if (v is List) {
    final out = <E>[];
    for (final (i, x) in v.indexed) {
      final e = one(x, '$path[$i]');
      if (identical(e, _miss)) return _miss;
      out.add(e as E);
    }
    return out;
  }
  final out = <String, E>{};
  for (final MapEntry(:key, value: x) in (v as Map).entries) {
    final e = one(x, '$path.$key');
    if (identical(e, _miss)) return _miss;
    out['$key'] = e as E;
  }
  return out;
}

String _describe(Object? v) => v is String ? '"$v"' : '$v';

/// [v] as JSON. Only a value that fails pays for the second walk, which replaces what JSON
/// cannot hold: a non-finite number with `null`, anything else with its `toString()`.
String _encode(Object? v) {
  try {
    return jsonEncode(v);
  } on JsonUnsupportedObjectError {
    Object? finite(Object? v) => switch (v) {
      final double d when !d.isFinite => null,
      final Map<Object?, Object?> m => {for (final MapEntry(:key, :value) in m.entries) '$key': finite(value)},
      final List<Object?> l => [for (final x in l) finite(x)],
      _ => v,
    };
    return jsonEncode(finite(v), toEncodable: (o) => '$o');
  }
}

/// JSON decoding.
///
/// {@category Formats}
extension StringJsonExtensions on String {
  /// Parses this string as JSON.
  JsonDocument get json => JsonDocument.parse(this);
}
