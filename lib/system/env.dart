import 'dart:core' as core;
import 'dart:core';
import 'dart:io';

// ============================================================================
// ENVIRONMENT & .ENV SUBSYSTEM (env.* / Env)
// ============================================================================

/// Top-level environment and `.env` loader accessor.
///
/// Provides strictly 1-word methods for reading, casting, and mutating environment variables:
/// ```dart
/// // Load .env file
/// env.load('.env');
///
/// // Type-casted reads with fallbacks
/// final port = env.int('PORT', 8080);
/// final debug = env.bool('DEBUG', false);
/// final key = env.get('API_KEY');
/// Environment manager providing `.env` parsing, type-safe casting, and session overrides.
class EnvAccessor {
  final Map<String, String> _overrides = {};

  /// Creates an [EnvAccessor].
  EnvAccessor();

  /// Loads variables from a `.env` file into the active session (1-word).
  ///
  /// If [path] is omitted, defaults to `.env` in the current working directory.
  /// If [overwrite] is `true`, overwrites existing system environment variables.
  core.bool load([Object path = '.env', core.bool overwrite = false]) {
    final file = path is File ? path : File(path.toString());
    if (!file.existsSync()) return false;

    final content = file.readAsStringSync();
    final parsed = parse(content);

    for (final entry in parsed.entries) {
      if (overwrite ||
          (!Platform.environment.containsKey(entry.key) &&
              !_overrides.containsKey(entry.key))) {
        _overrides[entry.key] = entry.value;
      }
    }
    return true;
  }

  /// Parses raw `.env` string content into a key-value map (1-word).
  Map<String, String> parse(String content) {
    final result = <String, String>{};
    final lines = content.split(RegExp(r'\r?\n'));

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('export ')) {
        line = line.substring(7).trim();
      }

      final eqIdx = line.indexOf('=');
      if (eqIdx == -1) continue;

      final key = line.substring(0, eqIdx).trim();
      var val = line.substring(eqIdx + 1).trim();

      if (val.startsWith('"')) {
        final closeIdx = val.indexOf('"', 1);
        if (closeIdx != -1) {
          val = val.substring(1, closeIdx);
        }
        val = val.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');
      } else if (val.startsWith("'")) {
        final closeIdx = val.indexOf("'", 1);
        if (closeIdx != -1) {
          val = val.substring(1, closeIdx);
        }
        val = val.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');
      } else {
        // Strip trailing inline comments if not quoted
        final hashIdx = val.indexOf(' #');
        if (hashIdx != -1) {
          val = val.substring(0, hashIdx).trim();
        }
      }

      result[key] = val;
    }
    return result;
  }

  /// Retrieves an environment variable as a string with an optional [fallback] (1-word).
  String get(String key, [String fallback = '']) {
    return _overrides[key] ?? Platform.environment[key] ?? fallback;
  }

  /// Retrieves an environment variable parsed as an [int] with an optional [fallback] (1-word).
  core.int int(String key, [core.int fallback = 0]) {
    final val = get(key);
    if (val.isEmpty) return fallback;
    return core.int.tryParse(val) ?? fallback;
  }

  /// Retrieves an environment variable parsed as a [double] with an optional [fallback] (1-word).
  core.double double(String key, [core.double fallback = 0.0]) {
    final val = get(key);
    if (val.isEmpty) return fallback;
    return core.double.tryParse(val) ?? fallback;
  }

  /// Retrieves an environment variable parsed as a [bool] with an optional [fallback] (1-word).
  ///
  /// Evaluates `'true'`, `'1'`, `'yes'`, and `'on'` (case-insensitive) as `true`.
  core.bool bool(String key, [core.bool fallback = false]) {
    final val = get(key).trim().toLowerCase();
    if (val.isEmpty) return fallback;
    if (val == 'true' || val == '1' || val == 'yes' || val == 'on') return true;
    if (val == 'false' || val == '0' || val == 'no' || val == 'off') {
      return false;
    }
    return fallback;
  }

  /// Checks whether an environment variable exists and is non-empty (1-word).
  core.bool has(String key) => get(key).isNotEmpty;

  /// Sets a session environment variable override (1-word).
  void set(String key, Object value) {
    _overrides[key] = value.toString();
  }

  /// Removes a session environment variable override (1-word).
  void delete(String key) {
    _overrides.remove(key);
  }

  /// Clears all session environment overrides (1-word).
  void clear() {
    _overrides.clear();
  }

  /// Returns a snapshot map of all system and session environment variables (1-word).
  Map<String, String> map() {
    final merged = Map<String, String>.from(Platform.environment);
    merged.addAll(_overrides);
    return merged;
  }
}
