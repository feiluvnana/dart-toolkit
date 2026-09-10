/// # TOML (`format.toml.*`)
///
/// The same three members `format.yaml` has, over the same [Json] cursor, for
/// the other configuration format a script meets — Rust's `Cargo.toml`,
/// Python's `pyproject.toml`, and anything else that picked TOML over YAML.
library;

import 'package:toml/toml.dart' as toml;

import '../util/codec.dart';
import '../util/json.dart';
import 'format.dart';

// ============================================================================
// TOML (tool.toml.*)
// ============================================================================

/// Entry point for TOML, reachable as `tool.toml`.
///
/// ```dart
/// final cargo = await format.toml.read('Cargo.toml');
/// cargo.text('package.version');
/// ```
///
/// Spelled member for member like [JsonAccessor] and [YamlAccessor], because
/// the format namespaces should be learnable from each other.
class TomlAccessor with FileCodec<Json> implements Codec<Json> {
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
  /// as a whole document — and anything TOML cannot carry gives an empty
  /// string rather than throwing.
  String format(Object? value) {
    if (value is! Map) return '';
    try {
      return toml.TomlDocument.fromMap(value).toString();
    } on Exception {
      return '';
    }
  }
}
