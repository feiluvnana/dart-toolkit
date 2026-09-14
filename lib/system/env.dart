/// # Environment & `.env` files
///
/// Reads process environment variables with an overlay of values loaded from
/// a `.env` file or set at runtime. The one instance is the top-level [env];
/// [loadEnv] fills it from a file.
///
/// ```dart
/// loadEnv();
/// final key  = env['API_KEY'];
/// final port = env.get<int>('PORT', 8080);
/// ```
///
/// [Environment.parse] is the one parser outside the `format` library, and it
/// is documented as a deliberate exception rather than left to look like an
/// oversight — see its own doc.
library;

import 'dart:io';

/// The process environment with an overlay of runtime overrides.
///
/// Values set here or loaded from a file overlay [Platform.environment]
/// without mutating the real process environment. Use the shared [env]
/// instance rather than constructing one.
///
/// ```dart
/// loadEnv();
/// final port = env.get<int>('PORT', 8080);
/// ```
class Environment {
  final Map<String, String> _overrides = {};

  /// Creates an independent environment overlay. Prefer the shared [env].
  Environment();

  /// Reads [key] from the environment (overrides first, then process), or `null`.
  String? operator [](String key) =>
      _overrides[key] ?? Platform.environment[key];

  /// Sets an override for [key].
  void operator []=(String key, String value) => set(key, value);

  /// Loads `KEY=value` pairs from the file at [path].
  ///
  /// Returns `false` when the file does not exist. Existing process variables
  /// win unless [overwrite] is set. Supports `export` prefixes, `#` comments,
  /// and single- or double-quoted values.
  bool load([String path = '.env', bool overwrite = false]) {
    final file = File(path);
    if (!file.existsSync()) return false;
    for (final entry in parse(file.readAsStringSync()).entries) {
      final known =
          Platform.environment.containsKey(entry.key) ||
          _overrides.containsKey(entry.key);
      if (overwrite || !known) _overrides[entry.key] = entry.value;
    }
    return true;
  }

  /// Parses `.env`-style [content] into a map, without applying it.
  ///
  /// **The documented seam of this accessor**, and a deliberate exception: it
  /// is a pure text parser, and so belongs in
  /// `format`. It stays because [load] cannot move — it mutates this
  /// process's view of the environment, which is a touch — and moving `parse`
  /// alone would make an `env` format library of one function, which
  /// forbids. So it is here, named as the seam, rather than in a family of
  /// one next door.
  Map<String, String> parse(String content) {
    final result = <String, String>{};
    for (var line in content.split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ')) line = line.substring(7).trim();

      final split = line.indexOf('=');
      if (split == -1) continue;
      final key = line.substring(0, split).trim();
      var value = line.substring(split + 1).trim();

      if (value.startsWith('"') || value.startsWith("'")) {
        final quote = value[0];
        final close = value.indexOf(quote, 1);
        if (close != -1) value = value.substring(1, close);
        value = value.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');
      } else {
        // An unquoted value ends at a trailing ` #` comment.
        final comment = value.indexOf(' #');
        if (comment != -1) value = value.substring(0, comment).trim();
      }
      result[key] = value;
    }
    return result;
  }

  /// Reads [key] as [T], returning [fallback] when absent or unparseable.
  ///
  /// [T] may be `String`, `int`, `double` or `bool`, and is inferred from
  /// [fallback] — which is required so the result is never null and never
  /// needs an explicit type argument. Booleans accept `true/1/yes/on` and
  /// `false/0/no/off`, case-insensitively.
  ///
  /// ```dart
  /// env.get('HOST', 'localhost'); // String
  /// env.get('PORT', 8080);        // int
  /// env.get('DEBUG', false);      // bool
  /// ```
  T get<T>(String key, T fallback) {
    final raw = _overrides[key] ?? Platform.environment[key];
    if (raw == null || raw.isEmpty) return fallback;

    return switch (T) {
      const (String) => raw as T,
      const (int) => (int.tryParse(raw) ?? fallback) as T,
      const (double) => (double.tryParse(raw) ?? fallback) as T,
      const (bool) => (_flag(raw) ?? fallback) as T,
      _ => throw ArgumentError(
        'env.get does not support $T; use String, int, double or bool.',
      ),
    };
  }

  /// Returns the value for [key], throwing [StateError] if missing or empty.
  String require(String key) {
    final raw = _overrides[key] ?? Platform.environment[key];
    if (raw == null || raw.isEmpty) {
      throw StateError('Missing required environment variable: $key');
    }
    return raw;
  }

  static bool? _flag(String raw) => switch (raw.trim().toLowerCase()) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => null,
  };

  /// Whether [key] resolves to a non-empty value.
  bool has(String key) =>
      (_overrides[key] ?? Platform.environment[key] ?? '').isNotEmpty;

  /// Sets an override for [key].
  void set(String key, String value) => _overrides[key] = value;

  /// Removes the override for [key], exposing the process value again.
  void delete(String key) => _overrides.remove(key);

  /// Removes every override.
  void clear() => _overrides.clear();

  /// The process environment with overrides applied.
  Map<String, String> map() => {...Platform.environment, ..._overrides};
}

// ============================================================================
// STATIC HELPER HUB: Env
// ============================================================================
