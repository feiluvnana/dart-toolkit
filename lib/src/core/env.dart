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

  /// The variable [key], or `null`: `Env.get('PORT') ?? '8080'`.
  static String? get(String key) => _custom[key] ?? Platform.environment[key];

  /// Sets or overrides a custom environment variable in-memory.
  static void set(String key, String value) => _custom[key] = value;

  /// Removes an in-memory custom environment variable.
  static void remove(String key) => _custom.remove(key);

  /// Whether any override has been set, loaded or parsed.
  static bool get hasOverrides => _custom.isNotEmpty;

  /// Drops every override; the process environment is untouched.
  static void reset() => _custom.clear();

  /// Checks if an environment variable [key] is defined and non-empty.
  static bool has(String key) => get(key)?.isNotEmpty ?? false;

  /// Retrieves a required environment variable [key]. Throws a [StateError] if missing or empty.
  static String require(String key) {
    final val = get(key);
    if (val == null || val.isEmpty) {
      throw StateError('Missing required environment variable: $key');
    }
    return val;
  }

  /// Whether the current script is running in a Continuous Integration (CI) environment.
  ///
  /// Checks common CI environment variables (`CI`, `GITHUB_ACTIONS`, `GITLAB_CI`, `TRAVIS`, `CIRCLECI`, `BITBUCKET_BUILD_NUMBER`, `TF_BUILD`).
  static bool get isCI =>
      const {'true', '1'}.contains(get('CI')) ||
      const [
        'GITHUB_ACTIONS',
        'GITLAB_CI',
        'TRAVIS',
        'CIRCLECI',
        'BITBUCKET_BUILD_NUMBER',
        'TF_BUILD',
      ].any((key) => get(key) != null);

  /// Parses a `.env` format [source] string and loads key-value pairs into custom environment.
  ///
  /// If [override] is `false` (default), a variable already defined — in `Platform.environment`
  /// or by an earlier [parse], [load] or [set] — is preserved. Supports `#` comments, `export`,
  /// single and double quotes — a quoted value may span lines, which is how a PEM key is
  /// written — and `\n`, `\"` and `\\` inside double quotes; not `${VAR}` expansion. A line
  /// with no key (`=value`) is skipped.
  static Map<String, String> parse(String source, {bool override = false}) {
    final parsed = <String, String>{};
    final lines = source.split(_envLineBreakRegex);

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
        var raw = value;
        var closed = _quoted(raw);
        var end = n;
        while (closed == null && end + 1 < lines.length) {
          raw = '$raw\n${lines[++end]}';
          closed = _quoted(raw);
        }
        if (closed != null) {
          value = closed;
          n = end;
        }
      } else {
        // A comment starts at a `#` after whitespace, as in a shell: `URL=http://x/#frag` and
        // `PASS=a#b` are values, `PORT=80 # web` is `80`.
        final comment = value.startsWith('#') ? 0 : value.indexOf(_envCommentRegex);
        if (comment != -1) value = value.substring(0, comment).trim();
      }

      parsed[key] = value;
      if (override || (!Platform.environment.containsKey(key) && !_custom.containsKey(key))) {
        _custom[key] = value;
      }
    }

    return parsed;
  }

  /// The value of a quoted [raw] up to its closing quote — with `\"`, `\\` and `\n`
  /// unescaped inside double quotes, and nothing inside single ones — or `null` when it
  /// never closes.
  static String? _quoted(String raw) {
    if (raw.startsWith("'")) {
      final close = raw.indexOf("'", 1);
      return close == -1 ? null : raw.substring(1, close);
    }
    final out = StringBuffer();
    for (var i = 1; i < raw.length; i++) {
      final char = raw[i];
      if (char == '"') return out.toString();
      if (char == r'\' && i + 1 < raw.length) {
        final next = raw[++i];
        out.write(switch (next) {
          'n' => '\n',
          '"' || r'\' => next,
          _ => '\\$next',
        });
      } else {
        out.write(char);
      }
    }
    return null;
  }

  /// Loads environment variables from the `.env` file at [path].
  ///
  /// Pass [parse] the file's contents instead when the source is not a file.
  static Map<String, String> load({String path = '.env', bool override = false}) {
    final file = File(path);
    return file.existsSync() ? parse(file.readAsStringSync(), override: override) : const {};
  }
}
