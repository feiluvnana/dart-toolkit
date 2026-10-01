part of '../../../formats.dart';

/// A JSON value with JSONPath, indexing, typed reads and serialization.
///
/// {@category Formats}
class JsonDocument {
  /// The underlying value: a Map, List, or primitive.
  final Object? raw;

  // The parent and the key, index or JSONPath result that reached this, for the path an error
  // names (`$.a[0]`); joined only on error, as building it on every `[]` dominated large reads.
  final JsonDocument? _parent;
  final Object? _step;

  /// Wraps [raw].
  const JsonDocument(this.raw) : _parent = null, _step = null;

  const JsonDocument._at(this.raw, JsonDocument this._parent, this._step);

  /// Parses [text] as JSON.
  factory JsonDocument.parse(String text) => JsonDocument(jsonDecode(text));

  /// The document in the file at [path], parsed by extension: `.json`, `.yaml`/`.yml`, `.toml`,
  /// `.ini`/`.cfg`/`.conf`; any other is a [FormatException]. A YAML stream reads as its first.
  static Future<JsonDocument> read(String path) async {
    final ext = _extensionOf(path);
    final JsonDocument Function(String) parse = switch (ext) {
      'json' => JsonDocument.parse,
      'yaml' || 'yml' => (t) => t.yaml,
      'toml' => (t) => t.toml,
      'ini' || 'cfg' || 'conf' => (t) => t.ini,
      _ => throw _unknownExtension(path, ext, 'read', 'json, yaml, yml, toml, ini, cfg and conf can be read'),
    };
    return parse(await File(path).readAsString());
  }

  /// Writes this document to [path], creating parent directories: `.json` indented two spaces,
  /// `.yaml`/`.yml` as [toYaml]; any other extension is a [FormatException].
  Future<File> save(String path) async {
    final ext = _extensionOf(path);
    final text = switch (ext) {
      'json' => '${_encode(raw, indent: '  ')}\n',
      'yaml' || 'yml' => toYaml(),
      _ => throw _unknownExtension(path, ext, 'write', 'json, yaml and yml can be written'),
    };
    final file = File(path);
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot == -1 || path.indexOf('/', dot) != -1 ? '' : path.substring(dot + 1).toLowerCase();
  }

  static FormatException _unknownExtension(String path, String ext, String verb, String known) =>
      FormatException('$path: cannot $verb ${ext.isEmpty ? 'a file with no extension' : '".$ext"'}; $known');

  /// Every value JSONPath [expression] selects: `$.store.book[*].author`, `$..id`,
  /// `$.items[0,2]`, `$.items[-2:]`, `$['a','b']`. No filters: `.where` on the result is shorter.
  List<JsonDocument> $(String expression) => [
    for (final (i, v) in _JsonPath.of(expression).read(raw).indexed) JsonDocument._at(v, this, (expression, i)),
  ];

  /// The child at a map key ([String]) or list index ([int], negative from the end); a missing
  /// one is the null document, and any other key type an [ArgumentError].
  JsonDocument operator [](Object keyOrIndex) {
    final raw = this.raw;
    switch (keyOrIndex) {
      case final String k:
        return JsonDocument._at(raw is Map ? raw[k] : null, this, k);
      case final int i:
        final l = raw is List ? raw : const <Object?>[];
        final at = i < 0 ? l.length + i : i;
        return JsonDocument._at(at >= 0 && at < l.length ? l[at] : null, this, i);
      default:
        throw ArgumentError.value(keyOrIndex, 'keyOrIndex', 'Must be a String key or an int index');
    }
  }

  /// Where this sits in the document it came from: `$`, `$.a[0]`, `$['x.y']`.
  String get _path {
    final parent = _parent;
    if (parent == null) return r'$';
    return switch (_step) {
      final int i => '${parent._path}[$i]',
      (final String expression, final int i) => '${parent._parent == null ? '' : parent._path}($expression)[$i]',
      final k => _key(parent._path, '$k'),
    };
  }

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  static String _key(String path, String k) =>
      _identifier.hasMatch(k) ? '$path.$k' : "$path['${k.replaceAll("'", r"\'")}']";

  /// Whether [raw] is null.
  bool get isNull => raw == null;

  /// [raw]'s elements, or empty when it is not a list.
  List<JsonDocument> get list => switch (raw) {
    final List<Object?> l => [for (var i = 0; i < l.length; i++) JsonDocument._at(l[i], this, i)],
    _ => const [],
  };

  /// [raw]'s entries, or empty when it is not a map.
  Map<String, JsonDocument> get map => switch (raw) {
    final Map<Object?, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries)
        if (key is String ? key : '$key' case final k) k: JsonDocument._at(value, this, k),
    },
    _ => const {},
  };

  /// The rows of this array of objects; a non-object element is skipped.
  Table get table => list.table;

  /// This value as [T], or a [StateError] naming where it is and what it was.
  ///
  /// Text converts to a number, boolean or ISO 8601 [DateTime] (`"42"`, `"true"`); `String`
  /// takes anything, a map or list as JSON; an integral double is an `int`, but `1.7` is not.
  /// `List<E>` and `Map<String, E>` convert each element for `E` of `String`, `int`, `double`,
  /// `num` or `bool`. A nullable [T] accepts null.
  T to<T>() {
    final raw = this.raw;
    if (raw is T) return raw;
    final v = _as<T>(raw, this, strict: true);
    if (v is T && !identical(v, _miss)) return v;
    final what = raw == null ? 'null' : '${_describe(raw)} (${raw.runtimeType})';
    throw StateError('$_path is $what, expected $T');
  }

  /// [to] for the caller who expects absence: `null` when this is null or is not a [T].
  T? toOrNull<T>() {
    final raw = this.raw;
    if (raw is T) return raw;
    final v = _as<T>(raw, this, strict: false);
    return v is T && !identical(v, _miss) ? v : null;
  }

  /// [toOrNull] with a default, [T] being the default's type: `ini['debug'].or(false)`.
  T or<T extends Object>(T fallback) => toOrNull<T>() ?? fallback;

  /// This document as block-style YAML, quoted only where a plain scalar would misread;
  /// `.yaml` reads it back as it was.
  String toYaml() {
    final sb = StringBuffer();
    _emitYaml(raw, sb, 0, inList: false);
    return sb.toString();
  }

  /// This document as JSON; NaN and infinities (which YAML has) are written as `null`, as
  /// JavaScript does.
  @override
  String toString() => _encode(raw);
}

/// Stands for "no conversion" where `null` is a valid answer.
const _miss = Object();

Type _typeOf<X>() => X;

/// [v], the value of [doc], as [T], or [_miss]. With [strict], a list or map element that does
/// not convert throws a [StateError] naming it.
Object? _as<T>(Object? v, JsonDocument doc, {required bool strict}) {
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
  if (same<DateTime>()) return v is String ? DateTime.tryParse(v.trim()) ?? _miss : _miss;
  if (v is List) {
    if (same<List<String>>()) return _eachOf<String>(v, doc, strict);
    if (same<List<int>>()) return _eachOf<int>(v, doc, strict);
    if (same<List<double>>()) return _eachOf<double>(v, doc, strict);
    if (same<List<num>>()) return _eachOf<num>(v, doc, strict);
    if (same<List<bool>>()) return _eachOf<bool>(v, doc, strict);
  }
  if (v is Map) {
    if (same<Map<String, String>>()) return _eachOf<String>(v, doc, strict);
    if (same<Map<String, int>>()) return _eachOf<int>(v, doc, strict);
    if (same<Map<String, double>>()) return _eachOf<double>(v, doc, strict);
    if (same<Map<String, num>>()) return _eachOf<num>(v, doc, strict);
    if (same<Map<String, bool>>()) return _eachOf<bool>(v, doc, strict);
  }
  return _miss;
}

/// The list or map [v] with every element as [E], or [_miss] when one does not convert.
Object _eachOf<E>(Object v, JsonDocument doc, bool strict) {
  Object? one(Object? x, Object at) {
    final e = _as<E>(x, doc, strict: strict);
    if (e is E && !identical(e, _miss)) return e;
    if (!strict) return _miss;
    final where = at is int ? '${doc._path}[$at]' : '${doc._path}.$at';
    throw StateError('$where is ${x == null ? 'null' : _describe(x)}, expected $E');
  }

  if (v is List) {
    final out = <E>[];
    for (var i = 0; i < v.length; i++) {
      final e = one(v[i], i);
      if (identical(e, _miss)) return _miss;
      out.add(e as E);
    }
    return out;
  }
  final out = <String, E>{};
  for (final MapEntry(:key, value: x) in (v as Map).entries) {
    final e = one(x, '$key');
    if (identical(e, _miss)) return _miss;
    out['$key'] = e as E;
  }
  return out;
}

String _describe(Object? v) => v is String ? '"$v"' : '$v';

/// [v] as JSON. Only a value that fails pays for a second walk, which writes a non-finite
/// number as `null` and anything else unencodable as its `toString()`.

String _encode(Object? v, {String? indent}) {
  try {
    return indent == null ? jsonEncode(v) : JsonEncoder.withIndent(indent).convert(v);
  } on JsonUnsupportedObjectError {
    Object? finite(Object? v) => switch (v) {
      final double d when !d.isFinite => null,
      final Map<Object?, Object?> m => {for (final MapEntry(:key, :value) in m.entries) '$key': finite(value)},
      final List<Object?> l => [for (final x in l) finite(x)],
      _ => v,
    };
    return JsonEncoder.withIndent(indent, (o) => '$o').convert(finite(v));
  }
}
