part of '../../../json.dart';

/// The text formats a [Doc] reads and writes. A file's extension names its format:
/// `.json`; `.yaml`, `.yml`; `.toml`; `.ini`, `.cfg`, `.conf`, `.properties`.
///
/// {@category Formats}
enum DocFormat {
  json('JSON'),
  yaml('YAML'),
  toml('TOML'),
  ini('INI');

  final String _label;

  const DocFormat(this._label);

  /// The format [path]'s extension names; any other is an [ArgumentError].
  static DocFormat _of(String path) => switch (FileBridge.extension(path)) {
    'json' => json,
    'yaml' || 'yml' => yaml,
    'toml' => toml,
    'ini' || 'cfg' || 'conf' || 'properties' => ini,
    final ext => throw ArgumentError.value(
      path,
      'path',
      'Invalid document path: ${ext.isEmpty ? 'no extension' : '".$ext"'} names no format '
          '(json, yaml, yml, toml, ini, cfg, conf, properties)',
    ),
  };
}

/// Where a document came from: its format, the file or URL a failure names, and every document
/// of a YAML stream.
final class _Origin {
  final DocFormat format;
  final String? source;
  final List<Object?>? stream;

  const _Origin(this.format, this.source, this.stream);
}

/// A document: JSON, YAML, TOML or INI read into one model of maps, lists and values, read by
/// key and typed, queried with JSONPath, edited, and written in any of the four formats.
///
/// ```dart
/// final cfg = await Doc.read('config.yaml');
/// cfg['server']['port'].to<int>();          // MissingException naming $.server.port
/// cfg['server']['port'].to(or: 8080);       // blank and absent both take the default
/// cfg.$('items[*].id').to<List<int>>();     // JSONPath; the root's `$` may go unwritten
/// await cfg.save('config.toml');
/// ```
///
/// {@category Formats}
final class Doc implements Saveable {
  /// The value: a `Map`, a `List`, a `String`, a number, a `bool` or `null`.
  final Object? raw;

  // The parent and the key, index or query that reached this, for the path a failure names
  // (`$.a[0]`), joined only on failure; a root's step is its [_Origin].
  final Doc? _parent;
  final Object? _step;

  /// A document over [raw], a decoded value: `Doc(jsonDecode(text))`, `Doc({'a': 1})`.
  const Doc(this.raw) : _parent = null, _step = null;

  const Doc._root(this.raw, _Origin this._step) : _parent = null;

  const Doc._at(this.raw, Doc this._parent, this._step);

  /// The document in the file at [path], in the format its extension names (see [DocFormat]).
  /// A file that does not parse is a [FormatException] naming it and the line. An INI file that
  /// is not UTF-8 reads as Windows-1252, as Windows programs write one.
  static Future<Doc> read(String path) {
    final format = DocFormat._of(path);
    return File(path).readAsBytes().then(
      (bytes) => _parse(decodeText(bytes, format._label, path, ansi: format == DocFormat.ini), format, path),
    );
  }

  /// [text] read as [format]; one that does not parse is a [FormatException] with the line. A
  /// YAML stream reads as its first document and saves whole; [parseAll] reads each.
  static Doc parse(String text, DocFormat format) => _parse(text, format, null);

  /// Every document in [text]: each of a YAML stream's, in order (none for empty input); the one
  /// document of the other formats.
  static List<Doc> parseAll(String text, DocFormat format) => [
    for (final value in _values(text, format, null)) Doc._root(value, _Origin(format, null, null)),
  ];

  /// [text] as [format], from [where] (a file or a URL) when there is one.
  static Doc _parse(String text, DocFormat format, String? where) {
    final values = _values(text, format, where);
    return Doc._root(values.firstOrNull, _Origin(format, where, values.length > 1 ? values : null));
  }

  static List<Object?> _values(String text, DocFormat format, String? where) {
    final List<Object?> Function(String) parse = switch (format) {
      DocFormat.json => (t) => [jsonDecode(t)],
      DocFormat.yaml => (t) => _YamlParser(t).parse(),
      DocFormat.toml => (t) => [_TomlParser(t).parse()],
      DocFormat.ini => (t) => [_parseIni(t)],
    };
    return parsedText(format._label, where, text.startsWith('\u{FEFF}') ? text.substring(1) : text, parse);
  }

  /// The root's origin: its format, source and stream.
  _Origin get _origin {
    var d = this;
    for (var p = d._parent; p != null; p = p._parent) {
      d = p;
    }
    return d._step as _Origin? ?? const _Origin(DocFormat.json, null, null);
  }

  // ---- reading

  /// The value at map key [key] (a `String`) or list index (an `int`, negative from the end).
  /// Nothing there is a document that reads as absent; below a value that is not a map or a
  /// list it is a [FormatException] saying what is there: `Invalid JSON at $.a: a String, not a
  /// map`. Any other key is an [ArgumentError].
  Doc operator [](Object key) => switch ((raw, key)) {
    (final Map<Object?, Object?> m, final String k) => Doc._at(m[k], this, k),
    (final List<Object?> l, final int i) => Doc._at(
      switch (_index(l, i)) {
        final at? => l[at],
        null => null,
      },
      this,
      i,
    ),
    (null, String() || int()) => Doc._at(null, this, key),
    (_, String()) => throw _shape('a map'),
    (_, int()) => throw _shape('a list'),
    _ => throw _badKey(key),
  };

  /// The values JSONPath [expression] selects: `store.book[*].author`, `..id`, `items[0,2]`,
  /// `items[-2:]`, `['a','b']`, with or without the root's `$`; no filters (`.where` on the
  /// selection is shorter).
  DocSelection $(String expression) => DocSelection._(this, expression, _JsonPath.of(expression).read(raw));

  /// This value as [T]: `int`, `double`, `num`, `bool`, `String`, `Duration`, `DateTime`, `Uri`,
  /// `Path`, or `List<E>` / `Map<String, E>` of those. Text reads as `Row.get` and `Env.get`
  /// read it (`"42"`, `"1,200"`, `"yes"`, `"90s"`; [format] and [decimal] as there).
  ///
  /// Nothing here — absent, `null`, or blank text — is [or], `null` for a nullable [T], else a
  /// [MissingException] naming the path: `Missing $.server.port in config.yaml`. A value that is
  /// there but is not a [T] is a [FormatException], which [or] does not answer; `to<String>()`
  /// refuses a list or a map.
  T to<T>({T? or, String? format, String? decimal}) {
    final raw = this.raw;
    if (raw == null || raw is String && raw.trim().isEmpty) {
      if (or != null) return or;
      if (null is T) return null as T;
      throw _missing();
    }
    if (raw case final T value) return value;
    final v = _as<T>(raw, this, (format: format, decimal: decimal ?? '.'));
    if (v is T && !identical(v, _miss)) return v;
    throw _invalid(raw, '$T');
  }

  /// The elements of this list, each a document. Absent is a [MissingException], anything but a
  /// list a [FormatException], so a misspelled key is never an empty loop.
  List<Doc> get list => switch (raw) {
    final List<Object?> l => [for (var i = 0; i < l.length; i++) Doc._at(l[i], this, i)],
    null => throw _missing(),
    _ => throw _shape('a list'),
  };

  /// The entries of this map, each a document; absent or not a map throws, as [list] does.
  Map<String, Doc> get map => switch (raw) {
    final Map<Object?, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries) '$key': Doc._at(value, this, '$key'),
    },
    null => throw _missing(),
    _ => throw _shape('a map'),
  };

  /// This list of maps as a [Table]: a [FormatException] for anything but a list, or for an
  /// element that is not a map, naming it.
  // Here, not in `collection`: a Table-only program does not compile the document parsers.
  Table get table => Table.rows([
    for (final item in list)
      switch (item.raw) {
        final Map<String, Object?> m => m,
        final Map<Object?, Object?> m => {for (final MapEntry(:key, :value) in m.entries) '$key': value},
        _ => throw item._shape('a map'),
      },
  ]);

  // ---- editing

  /// Sets map key [key] (a `String`) or list index (an `int`, negative from the end) to [value];
  /// a [Doc] is stored as its [raw]. Setting a key below a value that is not a map, or an index
  /// below one that is not a list, is a [FormatException]; below nothing, a
  /// [MissingException]; an index past the end, a [RangeError].
  void operator []=(Object key, Object? value) {
    final v = value is Doc ? value.raw : value;
    switch ((raw, key)) {
      case (final Map<Object?, Object?> m, final String k):
        m[k] = v;
      case (final List<Object?> l, final int i):
        l[_index(l, i) ?? (throw RangeError.index(i, l, 'index'))] = v;
      case (null, String() || int()):
        throw _missing();
      case (_, String()):
        throw _shape('a map');
      case (_, int()):
        throw _shape('a list');
      default:
        throw _badKey(key);
    }
  }

  /// Appends [value] (a [Doc] as its [raw]) to this list: `cfg['users'].add({'name': n})`.
  void add(Object? value) => switch (raw) {
    final List<Object?> l => l.add(value is Doc ? value.raw : value),
    null => throw _missing(),
    _ => throw _shape('a list'),
  };

  /// Removes map key [key] (a `String`) or list index (an `int`, negative from the end), and
  /// answers what it held: a document that reads as absent when nothing was there.
  Doc remove(Object key) => switch ((raw, key)) {
    (final Map<Object?, Object?> m, final String k) => Doc._at(m.remove(k), this, k),
    (final List<Object?> l, final int i) => Doc._at(
      switch (_index(l, i)) {
        final at? => l.removeAt(at),
        null => null,
      },
      this,
      i,
    ),
    (null, String() || int()) => throw _missing(),
    (_, String()) => throw _shape('a map'),
    (_, int()) => throw _shape('a list'),
    _ => throw _badKey(key),
  };

  /// This document with [other] laid over it, as layered config reads: maps merge key by key all
  /// the way down, and anything else in [other] (a list, a value) replaces what is here. An
  /// absent or empty [other] (an empty `local.yaml`) changes nothing. Neither is changed: the
  /// result is a copy, in this document's format.
  ///
  /// ```dart
  /// final config = defaults.merge(await Doc.read('config.yaml')).merge(await Doc.read('local.toml'));
  /// ```
  Doc merge(Doc other) {
    final over = other.raw;
    final origin = _Origin(_origin.format, null, null);
    if (over == null) return Doc._root(_copy(raw), origin);
    if (raw is! Map<Object?, Object?> || over is! Map<Object?, Object?>) return Doc._root(_copy(over), origin);
    final merged = _copy(raw) as Map<Object?, Object?>;
    // On a stack, as every walk over decoded data is: a deep document does not overflow.
    final pending = [(merged, over)];
    while (pending.isNotEmpty) {
      final (into, from) = pending.removeLast();
      for (final MapEntry(:value, key: k) in from.entries) {
        // YAML's `1:` laid over JSON's `"1":` is the same key.
        final key = into is Map<String, Object?> ? '$k' : k;
        if (into[key] case final Map<Object?, Object?> here when value is Map<Object?, Object?>) {
          pending.add((here, value));
        } else {
          into[key] = _copy(value);
        }
      }
    }
    return Doc._root(merged, origin);
  }

  // ---- writing

  /// This document as [format]'s text, indented: JSON two spaces a level; YAML block style,
  /// every document of a stream; TOML tables under headers; INI sections. What [format] cannot
  /// hold (a `null` in TOML, a list in INI, a stream as JSON) is a [FormatException] naming
  /// where it is.
  String encode(DocFormat format) {
    final stream = _parent == null ? _origin.stream : null;
    if (stream != null && format != DocFormat.yaml) {
      throw FormatException(
        'Invalid ${format._label}: a YAML stream of ${stream.length} documents is one file only as YAML',
      );
    }
    return switch (format) {
      DocFormat.json => '${_jsonText(raw, indent: '  ')}\n',
      DocFormat.yaml => stream == null ? _yaml(raw) : stream.map(_yaml).join('---\n'),
      DocFormat.toml => _toml(this),
      DocFormat.ini => _ini(this),
    };
  }

  /// Writes this document to [to] in the format its extension names (see [DocFormat]),
  /// atomically, into a folder that exists; a file there is replaced unless [conflict] says
  /// otherwise.
  /// A YAML stream saves every document.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite}) {
    final format = DocFormat._of(to);
    return saveBytes(to, conflict, 'Doc', () => utf8.encode(encode(format)));
  }

  /// [raw], so `jsonEncode` writes a document, or one nested in a map, as its value.
  Object? toJson() => raw;

  /// A short view for a debugger or a log line; [encode] writes the document.
  @override
  String toString() {
    final text = _jsonText(raw);
    return 'Doc(${text.length > 60 ? '${text.substring(0, 59)}…' : text})';
  }

  // ---- failures

  /// Where this sits in the document it came from: `$`, `$.a[0]`, `$['x.y']`.
  String get _path {
    final parent = _parent;
    if (parent == null) return r'$';
    return switch (_step) {
      final int i => '${parent._path}[$i]',
      _Query(:final expression) => '${parent._parent == null ? '' : parent._path}\$($expression)',
      final k => _key(parent._path, '$k'),
    };
  }

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  static String _key(String path, String k) =>
      _identifier.hasMatch(k) ? '$path.$k' : "$path['${k.replaceAll("'", r"\'")}']";

  /// `Invalid YAML in config.yaml at $.a`: the start of every failure about a value here, with
  /// [at] an index below this.
  String _where({int? at}) {
    final o = _origin;
    return 'Invalid ${o.format._label}${o.source == null ? '' : ' in ${o.source}'} at $_path${at == null ? '' : '[$at]'}';
  }

  MissingException _missing() => MissingException(_path, where: _origin.source);

  /// This value is not [expected]: `Invalid JSON at $.a: a String, not a map`.
  FormatException _shape(String expected, {int? at}) =>
      FormatException('${_where(at: at)}: ${_kind(raw)}, not $expected');

  /// [value] does not read as [type]: `Invalid JSON at $.port: "eighty", not an int`.
  FormatException _invalid(Object? value, String type, {Object? at}) {
    final where = at == null ? _where() : (at is int ? _where(at: at) : _keyWhere('$at'));
    return FormatException('$where: ${value is String ? '"$value"' : _kind(value)}, not ${article(type)}');
  }

  String _keyWhere(String key) {
    final o = _origin;
    return 'Invalid ${o.format._label}${o.source == null ? '' : ' in ${o.source}'} at ${_key(_path, key)}';
  }

  static ArgumentError _badKey(Object key) =>
      ArgumentError.value(key, 'key', 'Invalid key: a String names a map entry, an int a list element');

  /// [i] in [l], negative from the end, or `null` past either end.
  static int? _index(List<Object?> l, int i) {
    final at = i < 0 ? l.length + i : i;
    return at >= 0 && at < l.length ? at : null;
  }
}

/// What a JSONPath query selected: each match a [Doc], in document order, or all of them read
/// as one value with [to] (`.to<List<int>>()`).
///
/// {@category Formats}
final class DocSelection extends Iterable<Doc> {
  final Doc _doc;
  final String _expression;
  final List<Object?> _values;

  DocSelection._(this._doc, this._expression, this._values);

  @override
  Iterator<Doc> get iterator => _all.list.iterator;

  @override
  int get length => _values.length;

  @override
  bool get isEmpty => _values.isEmpty;

  @override
  bool get isNotEmpty => _values.isNotEmpty;

  /// The selection as one list document, for its path.
  Doc get _all => Doc._at(_values, _doc, _Query(_expression));

  /// The first match; a [MissingException] naming the query when nothing matched.
  @override
  Doc get first => _values.isEmpty ? throw _all._missing() : _all[0];

  /// The last match; a [MissingException] naming the query when nothing matched.
  @override
  Doc get last => _values.isEmpty ? throw _all._missing() : _all[-1];

  /// The one match; a [MissingException] when nothing matched, a [FormatException] when more
  /// than one did.
  @override
  Doc get single => switch (_values.length) {
    0 => throw _all._missing(),
    1 => _all[0],
    final n => throw FormatException('${_all._where()}: $n matches, not one'),
  };

  /// Every match as one value [T], as [Doc.to] reads it: `.to<List<String>>()`.
  T to<T>({T? or, String? format, String? decimal}) => _all.to<T>(or: or, format: format, decimal: decimal);

  @override
  String toString() => 'DocSelection($_expression, $length)';
}

/// The step to a JSONPath query's result: its expression, for the path a failure names.
final class _Query {
  final String expression;

  const _Query(this.expression);
}

/// [v] with every map and list in it new, walked on a stack; a map of `String` keys stays one.
Object? _copy(Object? v) {
  Object? fresh(Object? x) => switch (x) {
    Doc(:final raw) => fresh(raw),
    Map<String, Object?>() => <String, Object?>{},
    Map<Object?, Object?>() => <Object?, Object?>{},
    List<Object?>() => <Object?>[],
    _ => x,
  };
  final root = fresh(v);
  final pending = [(v is Doc ? v.raw : v, root)];
  while (pending.isNotEmpty) {
    switch (pending.removeLast()) {
      case (final Map<Object?, Object?> from, final Map<Object?, Object?> into):
        for (final MapEntry(:key, :value) in from.entries) {
          final x = value is Doc ? value.raw : value;
          final c = into[key] = fresh(x);
          if (!identical(c, x)) pending.add((x, c));
        }
      case (final List<Object?> from, final List<Object?> into):
        for (final value in from) {
          final x = value is Doc ? value.raw : value;
          final c = fresh(x);
          into.add(c);
          if (!identical(c, x)) pending.add((x, c));
        }
    }
  }
  return root;
}

/// Stands for "no conversion" where `null` is a valid answer.
const _miss = Object();

Type _typeOf<X>() => X;

bool _same<A, B>() => A == B || A == _typeOf<B?>();

/// How text reads: [Doc.to]'s `format:` and `decimal:`.
typedef _Reading = ({String? format, String decimal});

/// [v], the value of [doc], as [T], or [_miss]. A list or map element that does not convert
/// throws a [FormatException] naming it.
Object? _as<T>(Object? v, Doc doc, _Reading reading) {
  if (v is T) return v;
  if (v == null) return _miss;
  if (v is List || v is Map) {
    final list = v is List;
    Object? each<E>() => (list ? _same<T, List<E>>() : _same<T, Map<String, E>>()) ? _eachOf<E>(v, doc, reading) : null;
    return each<String>() ??
        each<int>() ??
        each<double>() ??
        each<num>() ??
        each<bool>() ??
        each<DateTime>() ??
        each<Duration>() ??
        each<Uri>() ??
        _miss;
  }
  return CoerceBridge.coerce<T>(v, format: reading.format, decimal: reading.decimal) ?? _miss;
}

/// The list or map [v] with every element as [E]; one that does not convert is a
/// [FormatException] naming it.
Object _eachOf<E>(Object v, Doc doc, _Reading reading) {
  E one(Object? x, Object at) {
    final e = _as<E>(x, doc, reading);
    if (e is E && !identical(e, _miss)) return e;
    throw doc._invalid(x, '$E', at: at);
  }

  if (v is List) return <E>[for (var i = 0; i < v.length; i++) one(v[i], i)];
  return <String, E>{for (final MapEntry(:key, value: x) in (v as Map).entries) '$key': one(x, '$key')};
}

/// What [v] is, for a failure: `a String`, `an int`, `a list`, `null`.
String _kind(Object? v) => switch (v) {
  null => 'null',
  String() => 'a String',
  int() => 'an int',
  double() => 'a double',
  bool() => 'a bool',
  List() => 'a list',
  Map() => 'a map',
  _ => article('${v.runtimeType}'),
};

/// [v] as JSON. Only a value that fails pays for a second walk, which writes a nested [Doc] as its
/// value, a non-finite number as `null` (as JavaScript does) and anything else as its text.
String _jsonText(Object? v, {String? indent}) {
  try {
    return indent == null ? jsonEncode(v) : JsonEncoder.withIndent(indent).convert(v);
  } on JsonUnsupportedObjectError {
    Object? finite(Object? v) => switch (v) {
      final Doc d => finite(d.raw),
      final double d when !d.isFinite => null,
      final DateTime d => d.toIso8601String(),
      final Map<Object?, Object?> m => {for (final MapEntry(:key, :value) in m.entries) '$key': finite(value)},
      final List<Object?> l => [for (final x in l) finite(x)],
      _ => v,
    };
    return JsonEncoder.withIndent(indent, (o) => '$o').convert(finite(v));
  }
}

final _responseDocs = Expando<Doc>();

/// A response's body read as a document.
///
/// {@category Formats}
extension DocResponse on Response {
  /// The body as JSON, whatever the status, so an API's error body still reads:
  /// `on StatusException catch (e) { e.response.json['error'] }`. A body that is not JSON is a
  /// [FormatException] naming the URL; an HTML page says so.
  Doc get json => _responseDocs[this] ??= _jsonOf(this);
}

Doc _jsonOf(Response res) {
  final where = '${res.url ?? 'the response'}';
  try {
    return Doc._parse(res.text, DocFormat.json, where);
  } on FormatException {
    final type = res.headers['content-type'];
    final html = type == null ? res.text.trimLeft().startsWith('<') : type.contains('html');
    if (!html) rethrow;
    throw FormatException('Invalid JSON in $where: the body is HTML (${type ?? 'markup'}), not JSON');
  }
}

/// A response on its way, read as a document.
///
/// {@category Formats}
extension DocResponseFuture on Future<Response> {
  /// The body as JSON, once the response is a 2xx; any other status is a [StatusException].
  Future<Doc> get json => then((res) => res.isOk ? res.json : throw StatusException(res));
}

/// Text read as a document, as [Doc.parse] reads it.
///
/// {@category Formats}
extension DocString on String {
  /// This text as JSON.
  Doc get json => Doc.parse(this, DocFormat.json);

  /// This YAML text, with anchors, aliases and `<<` merges; a duplicate key is an error. Dates
  /// and times stay text; `!!str` keeps a scalar text and other tags are ignored. A stream reads
  /// as its first document; `Doc.parseAll` reads each.
  Doc get yaml => Doc.parse(this, DocFormat.yaml);

  /// This TOML 1.0 text; dates and times stay text. Redefining a table, extending an inline
  /// table or static array, and `[[a]]` on a non-array-of-tables are errors.
  Doc get toml => Doc.parse(this, DocFormat.toml);

  /// This INI text: one map per `[section]`, keys before any section at the root, every value
  /// text (`to<bool>()` reads `yes`/`no`). `;`/`#` comments, `=` or `:`, quotes stripped,
  /// indented lines continue a value. Dots nest (`a.b = 1`, `[server.tls]`), except a key that
  /// cannot (Java properties' `log4j.appender.A1` beside `log4j.appender.A1.layout`), which
  /// stays whole; a quoted part of a section name is one name, and git's `[remote "origin"]`
  /// is `remote.origin`.
  Doc get ini => Doc.parse(this, DocFormat.ini);
}
