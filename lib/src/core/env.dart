part of '../core.dart';

final _envLineBreakRegex = RegExp(r'\r?\n');
final _envCommentRegex = RegExp(r'\s#');

/// A `$VAR` or `${VAR}`, or the `$` a `\$` escapes.
final _envReference = RegExp(r'\\\$|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)');

final class _CaseInsensitiveMap<V> extends MapBase<String, V> {
  final Map<String, (String, V)> _map = {};

  _CaseInsensitiveMap([Map<String, V>? initial]) {
    if (initial != null) addAll(initial);
  }

  @override
  V? operator [](Object? key) => key is String ? _map[key.toLowerCase()]?.$2 : null;

  @override
  void operator []=(String key, V value) => _map[key.toLowerCase()] = (key, value);

  @override
  bool containsKey(Object? key) => key is String && _map.containsKey(key.toLowerCase());

  @override
  int get length => _map.length;

  @override
  V? remove(Object? key) => key is String ? _map.remove(key.toLowerCase())?.$2 : null;

  @override
  void clear() => _map.clear();

  @override
  Iterable<String> get keys => _map.values.map((e) => e.$1);
}

const _envKey = #dartToolkitEnv;

/// Variables set and unset in one [Env.scope] (or outside any): `null` is unset.
final class _EnvLayer {
  final Map<String, String?> values = Platform.isWindows ? _CaseInsensitiveMap<String?>() : <String, String?>{};
  final _EnvLayer? parent;

  _EnvLayer(this.parent);
}

/// Environment variables: the process's, with what [set] and [unset] changed on top, and `.env`
/// files.
///
/// ```dart
/// final port = Env.get<int>('PORT', or: 8080);
/// final dir  = Env.get<Path?>('BOOKS_DIR');
/// await Env.load('.env');
/// await Env.scope(() async { Env.set('MODE', 'test'); … });   // undone when it ends
/// ```
///
/// {@category System}
abstract final class Env {
  static final _global = _EnvLayer(null);

  static _EnvLayer get _layer => Zone.current[_envKey] as _EnvLayer? ?? _global;

  /// Every variable, the process's with every change on top: what a child process gets.
  static Map<String, String> get all {
    final out = Platform.isWindows ? _CaseInsensitiveMap<String>(Platform.environment) : {...Platform.environment};
    final chain = <_EnvLayer>[for (_EnvLayer? l = _layer; l != null; l = l.parent) l];
    for (final layer in chain.reversed) {
      for (final MapEntry(:key, :value) in layer.values.entries) {
        value == null ? out.remove(key) : out[key] = value;
      }
    }
    return out;
  }

  /// The variable [key] as [T]: `String`, `int`, `double`, `num`, `bool` (`true`/`1`/`yes`),
  /// `Duration` (`90s`, `1h 30m`), `DateTime`, `Uri`, `Path` or `Secret`, read as every typed
  /// reading reads text.
  ///
  /// A blank value is absence: [or], `null` for a nullable [T], else a [MissingException]. A
  /// value that is there but does not read as [T] is a [FormatException], which [or] does not
  /// answer: `Env.get<int>('PORT', or: 0)` covers an unset variable, never a mistyped one.
  static T get<T extends Object?>(String key, {T? or}) => _readText(_raw(key), or, variable: key);

  static String? _raw(String key) {
    for (_EnvLayer? layer = _layer; layer != null; layer = layer.parent) {
      if (layer.values.containsKey(key)) {
        final value = layer.values[key];
        return value == null || value.isEmpty ? null : value;
      }
    }
    return switch (Platform.environment[key]) {
      final value? when value.isNotEmpty => value,
      _ => null,
    };
  }

  /// Sets [key] for this process and the children it starts; inside an [scope], until the scope
  /// ends.
  static void set(String key, String value) => _layer.values[key] = value;

  /// Unsets [key], as [set] sets it.
  static void unset(String key) => _layer.values[key] = null;

  /// Whether [key] holds a value that is not blank.
  static bool has(String key) => _raw(key) != null;

  /// Runs [body], then undoes every [set] and [unset] made inside it. The scope holds until
  /// [body]'s result (a future, a task, a batch) has finished.
  static Future<T> scope<T>(FutureOr<T> Function() body) async =>
      await runZoned(() async => await body(), zoneValues: {_envKey: _EnvLayer(_layer)});

  /// The variables of a `.env` text, as a map: `KEY=value`, `export KEY=value`, `#` comments,
  /// single quotes taken as they are, double quotes with `\n` escapes, both across lines.
  /// [expand] replaces `$NAME` and `${NAME}` with what is set by then. Pure: it changes nothing.
  static Map<String, String> parse(String text, {bool expand = false}) {
    final parsed = <String, String>{};
    final lines = text.split(_envLineBreakRegex);
    for (var n = 0; n < lines.length; n++) {
      var line = lines[n].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ') || line.startsWith('export\t')) line = line.substring(7).trim();
      final eqIdx = line.indexOf('=');
      if (eqIdx == -1) continue;
      final key = line.substring(0, eqIdx).trim();
      var value = line.substring(eqIdx + 1).trim();
      if (key.isEmpty) continue;
      final literal = value.startsWith("'");
      if (value.startsWith('"') || literal) {
        // A quote that never closes is the line's own text. The raw tail keeps the trailing
        // whitespace a multi-line value's first line has.
        final raw = lines[n].substring(lines[n].indexOf('=') + 1).trimLeft();
        if (_parseQuoted(lines, n, raw) case final res?) {
          value = res.value;
          n = res.endLine;
        }
      } else {
        // As in a shell, a comment is a `#` after whitespace: `PASS=a#b` is a value.
        final comment = value.startsWith('#') ? 0 : value.indexOf(_envCommentRegex);
        if (comment != -1) value = value.substring(0, comment).trim();
      }
      if (expand && !literal) {
        value = value.replaceAllMapped(
          _envReference,
          (m) => switch (m[1] ?? m[2]) {
            final name? => parsed[name] ?? _raw(name) ?? '',
            null => r'$',
          },
        );
      }
      parsed[key] = value;
    }
    return parsed;
  }

  /// The variables of the `.env` file at [path] (else beside the running script), [set] unless
  /// already set, or every one with [override]; returns what the file holds. No file is an empty
  /// map.
  static Future<Map<String, String>> load(String path, {bool override = false, bool expand = false}) async {
    final script = FileBridge.script();
    final cut = max(script.lastIndexOf('/'), Platform.isWindows ? script.lastIndexOf(r'\') : -1);
    for (final candidate in [path, if (!File(path).isAbsolute && cut >= 0) '${script.substring(0, cut + 1)}$path']) {
      final file = File(candidate);
      if (!await file.exists()) continue;
      final values = parse(await file.readAsString(), expand: expand);
      for (final MapEntry(:key, :value) in values.entries) {
        if (override || !has(key)) set(key, value);
      }
      return values;
    }
    return const {};
  }

  static ({String value, int endLine})? _parseQuoted(List<String> lines, int startLine, String value) {
    if (value.startsWith("'")) {
      for (var l = startLine; l < lines.length; l++) {
        final c = l == startLine ? value.indexOf("'", 1) : lines[l].indexOf("'");
        if (c == -1) continue;
        if (l == startLine) return (value: value.substring(1, c), endLine: l);
        if (!_endsLine(lines[l].substring(c + 1))) return null;
        final body = [value.substring(1), ...lines.getRange(startLine + 1, l), lines[l].substring(0, c)];
        return (value: body.join('\n'), endLine: l);
      }
      return null;
    }
    final out = StringBuffer();
    var escaped = false;
    for (var l = startLine; l < lines.length; l++) {
      final text = l == startLine ? value : lines[l];
      if (l > startLine) out.write('\n');
      for (var i = l == startLine ? 1 : 0; i < text.length; i++) {
        final c = text[i];
        if (escaped) {
          escaped = false;
          out.write(switch (c) {
            'n' => '\n',
            '"' || r'\' => c,
            _ => '\\$c',
          });
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          if (l > startLine && !_endsLine(text.substring(i + 1))) return null;
          return (value: out.toString(), endLine: l);
        } else {
          out.write(c);
        }
      }
    }
    return null;
  }

  /// Whether [rest], after a closing quote, is only whitespace or a comment.
  static bool _endsLine(String rest) {
    final tail = rest.trim();
    return tail.isEmpty || tail.startsWith('#');
  }

  /// Whether anything was set or unset, so a child needs an environment of its own.
  static bool get _isOverridden {
    for (_EnvLayer? layer = _layer; layer != null; layer = layer.parent) {
      if (layer.values.isNotEmpty) return true;
    }
    return false;
  }
}

typedef _Unknown = Object?;
