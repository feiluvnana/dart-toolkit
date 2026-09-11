/// # Environment & `.env` Files (`system.env.*`)
///
/// Reads process environment variables with an overlay of values loaded from
/// a `.env` file or set at runtime.
///
/// [EnvAccessor.parse] is the one parser in this domain, and it is documented
/// as a deliberate exception rather than left to look like an oversight — see
/// its own doc.
library;

import 'dart:io';

// ============================================================================
// ENVIRONMENT & .ENV SUBSYSTEM (system.env.*)
// ============================================================================

/// Entry point for environment variables, reachable as `system.env`.
///
/// Values set here or loaded from a file overlay [Platform.environment]
/// without mutating the real process environment.
///
/// ```dart
/// system.env.load();
/// final port = system.env.get<int>('PORT', 8080);
/// ```
class EnvAccessor {
  final Map<String, String> _overrides = {};

  /// Creates the accessor. Prefer the shared `system.env` instance.
  EnvAccessor();

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
  /// is a pure text parser, which by Rule 1 is a subject and belongs in
  /// `format`. It stays because [load] cannot move — it mutates this
  /// process's view of the environment, which is a touch — and moving `parse`
  /// alone would make `format.env` a domain of one function, which Rule 2
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
  /// system.env.get('HOST', 'localhost'); // String
  /// system.env.get('PORT', 8080);        // int
  /// system.env.get('DEBUG', false);      // bool
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
        'system.env.get does not support $T; use String, int, double or bool.',
      ),
    };
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
