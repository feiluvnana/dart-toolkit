/// # Environment & `.env` Files (`system.env.*`)
///
/// Reads process environment variables with an overlay of values loaded from
/// a `.env` file or set at runtime.
///
/// [EnvAccessor.parse] is the one parser in this domain, and it is documented
/// as a deliberate exception rather than left to look like an oversight — see
/// its own doc.
library;

import 'dart:core';
import 'dart:core' as core;
import 'dart:io';

import '../src/shared.dart';

// ============================================================================
// ENVIRONMENT & .ENV SUBSYSTEM (system.env.*)
// ============================================================================

/// Entry point for environment variables, reachable as `system.env`.
///
/// Values set here or loaded from a file overlay [Platform.environment]
/// without mutating the real process environment.
///
/// ```dart
/// Env.load();
/// final port = Env.get<int>('PORT', 8080);
/// ```
class EnvAccessor {
  final Map<String, String> _overrides = {};

  /// Creates the accessor. Prefer the shared `system.env` instance.
  EnvAccessor();

  /// Reads [key] from the environment (overrides first, then process), or `null`.
  String? operator [](String key) => _overrides[key] ?? Platform.environment[key];

  /// Sets an override for [key].
  void operator []=(String key, String value) => set(key, value);

  /// Loads `KEY=value` pairs from the file at [path].
  ///
  /// Returns `false` when the file does not exist. Existing process variables
  /// win unless [overwrite] is set. Supports `export` prefixes, `#` comments,
  /// and single- or double-quoted values.
  core.bool load([String path = '.env', core.bool overwrite = false]) {
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
  /// Env.get('HOST', 'localhost'); // String
  /// Env.get('PORT', 8080);        // int
  /// Env.get('DEBUG', false);      // bool
  /// ```
  T get<T>(String key, T fallback) {
    final raw = _overrides[key] ?? Platform.environment[key];
    if (raw == null || raw.isEmpty) return fallback;

    return switch (T) {
      const (String) => raw as T,
      const (core.int) => (core.int.tryParse(raw) ?? fallback) as T,
      const (double) => (double.tryParse(raw) ?? fallback) as T,
      const (core.bool) => (_flag(raw) ?? fallback) as T,
      _ => throw ArgumentError(
        'system.env.get does not support $T; use String, int, double or bool.',
      ),
    };
  }

  /// Reads [key] as an integer, returning [defaultValue] if absent or unparseable.
  core.int int(String key, {core.int defaultValue = 0}) {
    final raw = _overrides[key] ?? Platform.environment[key];
    if (raw == null || raw.isEmpty) return defaultValue;
    return core.int.tryParse(raw) ?? defaultValue;
  }

  /// Reads [key] as an integer. Alias for [int].
  core.int getInt(String key, {core.int defaultValue = 0}) =>
      int(key, defaultValue: defaultValue);

  /// Reads [key] as a boolean, returning [defaultValue] if absent or unparseable.
  core.bool bool(String key, {core.bool defaultValue = false}) {
    final raw = _overrides[key] ?? Platform.environment[key];
    if (raw == null || raw.isEmpty) return defaultValue;
    return _flag(raw) ?? defaultValue;
  }

  /// Reads [key] as a boolean. Alias for [bool].
  core.bool getBool(String key, {core.bool defaultValue = false}) =>
      bool(key, defaultValue: defaultValue);

  /// Returns the value for [key], throwing [StateError] if missing or empty.
  String require(String key) {
    final raw = _overrides[key] ?? Platform.environment[key];
    if (raw == null || raw.isEmpty) {
      throw StateError('Missing required environment variable: $key');
    }
    return raw;
  }

  static core.bool? _flag(String raw) => switch (raw.trim().toLowerCase()) {
    'true' || '1' || 'yes' || 'on' => true,
    'false' || '0' || 'no' || 'off' => false,
    _ => null,
  };

  /// Whether [key] resolves to a non-empty value.
  core.bool has(String key) =>
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

/// Static helper hub for environment variables and `.env` loading.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// Env.load();
/// final port = Env.get('PORT', 8080);
/// final key = Env.read('API_KEY');
/// ```
abstract final class Env {
  Env._();

  /// Reads [key] from the environment, or `null`.
  static String? read(String key) => sharedEnv[key];

  /// Reads [key] as [T], returning [fallback] when absent or unparseable.
  static T get<T>(String key, T fallback) => sharedEnv.get<T>(key, fallback);

  /// Reads [key] as an integer, returning [defaultValue] if absent or unparseable.
  static core.int int(String key, {core.int defaultValue = 0}) =>
      sharedEnv.int(key, defaultValue: defaultValue);

  /// Reads [key] as an integer. Alias for [int].
  static core.int getInt(String key, {core.int defaultValue = 0}) =>
      sharedEnv.getInt(key, defaultValue: defaultValue);

  /// Reads [key] as a boolean, returning [defaultValue] if absent or unparseable.
  static core.bool bool(String key, {core.bool defaultValue = false}) =>
      sharedEnv.bool(key, defaultValue: defaultValue);

  /// Reads [key] as a boolean. Alias for [bool].
  static core.bool getBool(String key, {core.bool defaultValue = false}) =>
      sharedEnv.getBool(key, defaultValue: defaultValue);

  /// Returns the value for [key], throwing [StateError] if missing or empty.
  static String require(String key) => sharedEnv.require(key);

  /// Whether [key] resolves to a non-empty value.
  static core.bool has(String key) => sharedEnv.has(key);

  /// Loads `KEY=value` pairs from the file at [path].
  static core.bool load([String path = '.env', core.bool overwrite = false]) =>
      sharedEnv.load(path, overwrite);

  /// Parses `.env`-style [content] into a map, without applying it.
  static Map<String, String> parse(String content) => sharedEnv.parse(content);

  /// Sets an override for [key].
  static void set(String key, String value) => sharedEnv.set(key, value);

  /// Removes the override for [key], exposing the process value again.
  static void delete(String key) => sharedEnv.delete(key);

  /// Removes every override.
  static void clear() => sharedEnv.clear();

  /// The process environment with overrides applied.
  static Map<String, String> map() => sharedEnv.map();
}
