import 'dart:io';

/// Utilities for accessing system environment variables, `.env` file parsing, and platform checks.
///
/// {@category System}
class Env {
  static final Map<String, String> _custom = {};

  /// Returns the current merged environment map (custom loaded vars taking precedence over system vars).
  static Map<String, String> all() => {...Platform.environment, ..._custom};

  /// Retrieves an environment variable by [key], with an optional [defaultTo] fallback.
  ///
  /// Example:
  /// ```dart
  /// final port = Env.get('PORT', '8080');
  /// ```
  static String? get(String key, [String? defaultTo]) => _custom[key] ?? Platform.environment[key] ?? defaultTo;

  /// Sets or overrides a custom environment variable in-memory.
  static void set(String key, String value) {
    _custom[key] = value;
  }

  /// Removes an in-memory custom environment variable.
  static void remove(String key) {
    _custom.remove(key);
  }

  /// Clears all custom environment variable overrides.
  static void clear() {
    _custom.clear();
  }

  /// Checks if an environment variable [key] is defined and non-empty.
  static bool has(String key) {
    final val = get(key);
    return val != null && val.isNotEmpty;
  }

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
  static bool get isCI {
    final env = all();
    return env['CI'] == 'true' ||
        env['CI'] == '1' ||
        env.containsKey('GITHUB_ACTIONS') ||
        env.containsKey('GITLAB_CI') ||
        env.containsKey('TRAVIS') ||
        env.containsKey('CIRCLECI') ||
        env.containsKey('BITBUCKET_BUILD_NUMBER') ||
        env.containsKey('TF_BUILD');
  }

  /// Parses a `.env` format [source] string and loads key-value pairs into custom environment.
  ///
  /// If [override] is `false` (default), variables already defined in `Platform.environment` or loaded previously are preserved.
  static Map<String, String> parse(String source, {bool override = false}) {
    final parsed = <String, String>{};
    final lines = source.split(RegExp(r'\r?\n'));

    for (final rawLine in lines) {
      var line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ')) {
        line = line.substring(7).trim();
      }

      final eqIdx = line.indexOf('=');
      if (eqIdx == -1) continue;

      final key = line.substring(0, eqIdx).trim();
      var value = line.substring(eqIdx + 1).trim();

      if (value.startsWith('"')) {
        final closeQuote = value.indexOf('"', 1);
        if (closeQuote != -1) {
          value = value.substring(1, closeQuote).replaceAll(r'\n', '\n');
        }
      } else if (value.startsWith("'")) {
        final closeQuote = value.indexOf("'", 1);
        if (closeQuote != -1) {
          value = value.substring(1, closeQuote);
        }
      } else {
        final commentIdx = value.indexOf('#');
        if (commentIdx != -1) {
          value = value.substring(0, commentIdx).trim();
        }
      }

      parsed[key] = value;
      if (override || !Platform.environment.containsKey(key)) {
        _custom[key] = value;
      }
    }

    return parsed;
  }

  /// Loads environment variables from the `.env` file at [path].
  ///
  /// Pass [parse] the file's contents instead when the source is not a file.
  static Map<String, String> load({String path = '.env', bool override = false}) {
    final file = File(path);
    if (!file.existsSync()) return const {};
    final content = file.readAsStringSync();
    return parse(content, override: override);
  }
}
