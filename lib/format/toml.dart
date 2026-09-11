/// # TOML (`format.toml.*`)
///
/// The same three members `format.yaml` has, over the same [Json] cursor, for
/// the other configuration format a script meets — Rust's `Cargo.toml`,
/// Python's `pyproject.toml`, and anything else that picked TOML over YAML.
library;

import 'package:toml/toml.dart' as toml;

import '../src/codec.dart';
import '../src/json.dart';
import 'format.dart';

// ============================================================================
// TOML (format.toml.*)
// ============================================================================

/// Entry point for TOML, reachable as `format.toml`.
///
/// ```dart
/// final cargo = await format.toml.read('Cargo.toml');
/// cargo.text('package.version');
/// ```
///
/// Spelled member for member like [JsonAccessor] and [YamlAccessor], because
/// the format namespaces should be learnable from each other.
class TomlAccessor with FileCodec<Json, Object?> implements Codec<Json> {
  /// Creates the accessor. Prefer the shared `format.toml` instance.
  const TomlAccessor();

  /// Parses TOML [text] into a [Json] cursor.
  ///
  /// Text that is not TOML gives the empty cursor rather than throwing.
  @override
  Json parse(String text) {
    try {
      return Json(YamlAccessor.plain(toml.TomlDocument.parse(text).toMap()));
    } on Exception {
      return Json.none;
    }
  }

  /// Renders [value] as TOML text.
  ///
  /// [value] has to be a map — TOML has no way to write a bare list or scalar
  /// as a whole document — and throws [ArgumentError] naming what it was
  /// handed when it cannot carry it.
  ///
  /// Through 4.0.0 both cases returned an empty string, so
  /// `io.write(path, format.toml.format(rows))` wrote an empty file and
  /// reported success. Reading never throws and gives the empty cursor;
  /// writing never returns text that is wrong or absent. A caller can check
  /// for a throw and cannot check for a file that is silently blank.
  @override
  String format(Object? value) {
    if (value is! Map) {
      throw ArgumentError.value(
        value,
        'value',
        'TOML has no representation for a bare '
            '${value == null ? 'null' : value.runtimeType} document; '
            'a whole TOML document is a map',
      );
    }
    try {
      return toml.TomlDocument.fromMap(value).toString();
    } on Exception catch (error) {
      throw ArgumentError.value(value, 'value', 'not writable as TOML: $error');
    }
  }
}
