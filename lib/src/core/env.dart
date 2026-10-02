part of '../../core.dart';

final _envLineBreakRegex = RegExp(r'\r?\n');
final _envCommentRegex = RegExp(r'\s#');

/// Environment variables: the process's, in-memory overrides, and `.env` parsing.
///
/// {@category System}
abstract final class Env {
  static final _custom = <String, String>{};

  /// The process environment with in-memory overrides on top.
  static Map<String, String> all() => {...Platform.environment, ..._custom};

  /// The variable [key], or [or] when it is unset or empty; with no [or], a [StateError]
  /// naming the key: `Env.get('API_TOKEN')`, `Env.get('PORT', or: '8080')`.
  static String get(String key, {String? or}) =>
      getOrNull(key) ?? or ?? (throw StateError('Missing required environment variable: $key'));

  /// The variable [key], or `null` when it is unset or empty.
  static String? getOrNull(String key) => switch (_custom[key] ?? Platform.environment[key]) {
    final value? when value.isNotEmpty => value,
    _ => null,
  };

  /// Overrides [key] in memory.
  static void set(String key, String value) => _custom[key] = value;

  /// Whether the variable [key] is set and non-empty.
  static bool has(String key) => getOrNull(key) != null;

  /// Whether this runs under CI (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, … is set).
  static bool get isCI =>
      const {'true', '1'}.contains(getOrNull('CI')) ||
      const ['GITHUB_ACTIONS', 'GITLAB_CI', 'TRAVIS', 'CIRCLECI', 'BITBUCKET_BUILD_NUMBER', 'TF_BUILD'].any(has);

  /// Parses `.env` [source] into the in-memory environment and returns what it parsed.
  ///
  /// Without [override], a variable already defined (non-empty) is kept. Supports `#` comments,
  /// `export`, single and double quotes (a quoted value may span lines, as a PEM key does) and
  /// `\n`, `\"`, `\\` inside double quotes; not `${VAR}` expansion.
  static Map<String, String> parse(String source, {bool override = false}) {
    final parsed = <String, String>{};
    final lines = source.split(_envLineBreakRegex);
    // Taken before parsing, so a key repeated within this source is still its own.
    final defined = {
      for (final MapEntry(:key, :value) in all().entries)
        if (value.isNotEmpty) key,
    };

    for (var n = 0; n < lines.length; n++) {
      var line = lines[n].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ') || line.startsWith('export\t')) line = line.substring(7).trim();
      final eqIdx = line.indexOf('=');
      if (eqIdx == -1) continue;
      final key = line.substring(0, eqIdx).trim();
      var value = line.substring(eqIdx + 1).trim();
      if (key.isEmpty) continue;
      if (value.startsWith('"') || value.startsWith("'")) {
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

      parsed[key] = value;
      if (override || !defined.contains(key)) _custom[key] = value;
    }
    return parsed;
  }

  /// The unescaped quoted [value] opened on [startLine] and the line it closes on, or `null`.
  ///
  /// As in dotenv, a value spans lines only when its closing quote ends a line (a comment may
  /// follow), so a stray quote further down does not swallow the lines between.
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

  /// [parse]s the `.env` file at [path], if it exists.
  static Map<String, String> load({String path = '.env', bool override = false}) {
    final file = File(path);
    return file.existsSync() ? parse(file.readAsStringSync(), override: override) : const {};
  }
}
