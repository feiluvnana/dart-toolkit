import 'dart:io';

/// Utilities for accessing system environment variables, `.env` file parsing, and platform checks.
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

  /// Whether the current operating system is macOS.
  static bool get isMac => Platform.isMacOS;

  /// Shorthand alias for [isMac].
  static bool get isMacOS => Platform.isMacOS;

  /// Whether the current operating system is Windows.
  static bool get isWin => Platform.isWindows;

  /// Shorthand alias for [isWin].
  static bool get isWindows => Platform.isWindows;

  /// Whether the current operating system is Linux.
  static bool get isLinux => Platform.isLinux;

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
  /// Returns the map of parsed key-value pairs.
  static Map<String, String> load(String source, [bool override = false]) {
    final result = <String, String>{};
    final lines = source.split(RegExp(r'\r?\n'));

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('export ')) {
        line = line.substring(7).trim();
      }

      final eqIndex = line.indexOf('=');
      if (eqIndex == -1) continue;

      final key = line.substring(0, eqIndex).trim();
      if (key.isEmpty) continue;

      var value = line.substring(eqIndex + 1).trim();

      // Handle quoted values
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
        if (value.contains(r'\n')) {
          value = value.replaceAll(r'\n', '\n');
        }
      } else {
        // Strip trailing comment if not quoted
        final commentIndex = value.indexOf(' #');
        if (commentIndex != -1) {
          value = value.substring(0, commentIndex).trim();
        }
      }

      result[key] = value;
      if (override || (!_custom.containsKey(key) && !Platform.environment.containsKey(key))) {
        _custom[key] = value;
      }
    }

    return result;
  }

  /// Clears in-memory custom environment overrides.
  static void clearOverrides() {
    _custom.clear();
  }
}
