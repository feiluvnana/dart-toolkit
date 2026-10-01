part of '../../core.dart';

final _envLineBreakRegex = RegExp(r'\r?\n');
final _envCommentRegex = RegExp(r'\s#');

/// Environment variables: the process's, in-memory overrides, and `.env` parsing.
///
/// {@category System}
class Env {
  static final Map<String, String> _custom = {};

  /// Returns the current merged environment map (custom loaded vars taking precedence over system vars).
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

  /// Sets or overrides a custom environment variable in-memory.
  static void set(String key, String value) => _custom[key] = value;

  /// Whether the variable [key] is set and non-empty.
  static bool has(String key) => getOrNull(key) != null;

  /// Whether the current script is running in a Continuous Integration (CI) environment.
  ///
  /// Checks common CI environment variables (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `TRAVIS`, `CIRCLECI`, `BITBUCKET_BUILD_NUMBER`, `TF_BUILD`).
  static bool get isCI =>
      const {'true', '1'}.contains(getOrNull('CI')) ||
      const ['GITHUB_ACTIONS', 'GITLAB_CI', 'TRAVIS', 'CIRCLECI', 'BITBUCKET_BUILD_NUMBER', 'TF_BUILD'].any(has);

  /// Parses a `.env` format [source] string and loads key-value pairs into custom environment.
  ///
  /// If [override] is `false` (default), a variable already defined — non-empty, in
  /// `Platform.environment` or by an earlier [parse], [load] or [set] — is preserved. Supports `#` comments, `export`,
  /// single and double quotes — a quoted value may span lines, which is how a PEM key is
  /// written — and `\n`, `\"` and `\\` inside double quotes; not `${VAR}` expansion. A line
  /// with no key (`=value`) is skipped.
  static Map<String, String> parse(String source, {bool override = false}) {
    final parsed = <String, String>{};
    final lines = source.split(_envLineBreakRegex);
    // What is defined before this parse, so a key repeated within it is still the parse's
    // own; an empty variable is unset here as it is for [get].
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
        // A quote that does not close on its line closes on a later one; one that never
        // closes is the line's own text, and takes no line after it.
        if (_parseQuoted(lines, n, value) case final res?) {
          value = res.value;
          n = res.endLine;
        }
      } else {
        // A comment starts at a `#` after whitespace, as in a shell: `URL=http://x/#frag` and
        // `PASS=a#b` are values, `PORT=80 # web` is `80`.
        final comment = value.startsWith('#') ? 0 : value.indexOf(_envCommentRegex);
        if (comment != -1) value = value.substring(0, comment).trim();
      }

      parsed[key] = value;
      if (override || !defined.contains(key)) {
        _custom[key] = value;
      }
    }

    return parsed;
  }

  /// Parses a quoted value spanning lines starting at [startLine].
  /// Returns the unescaped value and the line index where the quote closed, or `null` if unclosed.
  static ({String value, int endLine})? _parseQuoted(List<String> lines, int startLine, String value) {
    if (value.startsWith("'")) {
      final close = value.indexOf("'", 1);
      if (close != -1) return (value: value.substring(1, close), endLine: startLine);
      for (var l = startLine + 1; l < lines.length; l++) {
        final c = lines[l].indexOf("'");
        if (c != -1) {
          final parts = [
            value.substring(1),
            for (var i = startLine + 1; i < l; i++) lines[i],
            lines[l].substring(0, c),
          ];
          return (value: parts.join('\n'), endLine: l);
        }
      }
      return null;
    }

    var foundClose = false;
    var closeLine = -1;
    var closeCol = -1;
    var escaped = false;
    for (var i = 1; i < value.length; i++) {
      if (escaped) {
        escaped = false;
      } else if (value[i] == r'\') {
        escaped = true;
      } else if (value[i] == '"') {
        foundClose = true;
        closeLine = startLine;
        closeCol = i;
        break;
      }
    }
    if (!foundClose) {
      for (var l = startLine + 1; l < lines.length; l++) {
        final text = lines[l];
        for (var i = 0; i < text.length; i++) {
          if (escaped) {
            escaped = false;
          } else if (text[i] == r'\') {
            escaped = true;
          } else if (text[i] == '"') {
            foundClose = true;
            closeLine = l;
            closeCol = i;
            break;
          }
        }
        if (foundClose) break;
      }
    }
    if (!foundClose) return null;

    final out = StringBuffer();
    var esc = false;
    for (var l = startLine; l <= closeLine; l++) {
      final text = l == startLine ? value.substring(1) : lines[l];
      final limit = l == closeLine ? (l == startLine ? closeCol - 1 : closeCol) : text.length;
      if (l > startLine) out.write('\n');
      for (var i = 0; i < limit; i++) {
        if (esc) {
          esc = false;
          final next = text[i];
          out.write(switch (next) {
            'n' => '\n',
            '"' || r'\' => next,
            _ => '\\$next',
          });
        } else if (text[i] == r'\') {
          esc = true;
        } else {
          out.write(text[i]);
        }
      }
    }
    return (value: out.toString(), endLine: closeLine);
  }

  /// Loads environment variables from the `.env` file at [path].
  ///
  /// Pass [parse] the file's contents instead when the source is not a file.
  static Map<String, String> load({String path = '.env', bool override = false}) {
    final file = File(path);
    return file.existsSync() ? parse(file.readAsStringSync(), override: override) : const {};
  }
}
