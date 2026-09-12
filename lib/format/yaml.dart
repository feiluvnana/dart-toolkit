/// # YAML (`format.yaml.*`)
///
/// Reading and writing the format everything else a script coordinates with is
/// configured in — `pubspec.yaml` first, then CI, then Docker Compose, then
/// Kubernetes. `io.dump` covers the format this library *writes*; this is the
/// one everything else *reads*, and it is spelled member for member like
/// [JsonAccessor].
///
/// A format is a subject in the sense Rule 1 means it: knowing what a YAML
/// file looks like is knowledge Dart does not have. That is the same argument
/// that admitted `format.zip`, with a different noun — and the reason
/// `format.json` sits beside this rather than in `util`.
library;

import 'dart:convert';

import 'package:yaml/yaml.dart' as yaml;

import '../src/codec.dart';
import '../src/json.dart';
import 'format.dart';

// ============================================================================
// YAML (format.yaml.*)
// ============================================================================

/// Entry point for YAML, reachable as `format.yaml`.
///
/// Three members, spelled exactly like [JsonAccessor] and [TomlAccessor], so
/// the format namespaces are learnable from each other:
///
/// ```dart
/// final pubspec = Formats.yaml('version: 8.0.0\ndependencies: {}');
/// pubspec.text('version');                            // '8.0.0'
/// pubspec.at('dependencies').count;
/// await Files.writeText('out.yaml', Formats.toYaml({'name': 'x'}));
/// ```
///
/// Reading gives a [Json] cursor rather than a type of its own: YAML and JSON
/// decode to the same maps, lists and scalars, so a second cursor would be two
/// spellings of one operation.
class YamlAccessor with FileCodec<Json, Object?> implements Codec<Json> {
  /// Creates the accessor. Prefer the shared `format.yaml` instance.
  const YamlAccessor();

  /// Parses YAML [text] into a [Json] cursor.
  ///
  /// Text that is not YAML gives the empty cursor rather than throwing,
  /// matching how a missing path reads.
  @override
  Json parse(String text) {
    try {
      return Json(plain(yaml.loadYaml(text)));
    } on yaml.YamlException {
      return Json.none;
    } on FormatException {
      return Json.none;
    }
  }

  /// Renders [value] as YAML text, nesting by [indent] spaces.
  ///
  /// Block style throughout — the shape the files in the wild are written in.
  /// Maps, lists, strings, numbers, booleans and `null` are what a document
  /// can hold; anything else is rendered as its `toString`.
  @override
  String format(Object? value, {int indent = 2}) {
    final buffer = StringBuffer();
    _write(buffer, value, 0, indent <= 0 ? 2 : indent);
    return buffer.toString();
  }

  /// [node] with every YAML view replaced by a plain map, list or scalar.
  ///
  /// `package:yaml` hands back `YamlMap` and `YamlList`, which are views that
  /// `jsonEncode` refuses; converting on the way in means the cursor holds
  /// exactly what a JSON one does.
  static Object? plain(Object? node) => switch (node) {
    Map<Object?, Object?> map => <String, Object?>{
      for (final entry in map.entries) '${entry.key}': plain(entry.value),
    },
    List<Object?> list => <Object?>[for (final item in list) plain(item)],
    _ => node,
  };

  static void _write(StringBuffer out, Object? value, int depth, int step) {
    final pad = ' ' * (depth * step);
    switch (value) {
      case Map<Object?, Object?> map when map.isEmpty:
        out.writeln('$pad{}');
      case Map<Object?, Object?> map:
        for (final entry in map.entries) {
          final key = _scalar('${entry.key}');
          if (_nested(entry.value)) {
            out.writeln('$pad$key:');
            _write(out, entry.value, depth + 1, step);
          } else {
            out.writeln('$pad$key: ${_inline(entry.value)}');
          }
        }
      case List<Object?> list when list.isEmpty:
        out.writeln('$pad[]');
      case List<Object?> list:
        for (final item in list) {
          if (_nested(item)) {
            out.writeln('$pad-');
            _write(out, item, depth + 1, step);
          } else {
            out.writeln('$pad- ${_inline(item)}');
          }
        }
      default:
        out.writeln('$pad${_inline(value)}');
    }
  }

  static bool _nested(Object? value) =>
      (value is Map && value.isNotEmpty) || (value is List && value.isNotEmpty);

  static String _inline(Object? value) => switch (value) {
    null => 'null',
    bool flag => '$flag',
    num number => '$number',
    Map<Object?, Object?> _ => '{}',
    List<Object?> _ => '[]',
    _ => _scalar('$value'),
  };

  // A plain scalar that could be read back as a number, a boolean, a null or a
  // structure has to be quoted, or the document says something else than it
  // was handed.
  static final _bare = RegExp(r'^[A-Za-z_][A-Za-z0-9_. /-]*$');
  static const _reserved = {
    'true',
    'false',
    'yes',
    'no',
    'on',
    'off',
    'null',
    '~',
  };

  /// [text] as a scalar that reads back as exactly [text].
  ///
  /// Anything not spellable bare is emitted as a JSON string literal. YAML is
  /// a superset of JSON, so a double-quoted literal with JSON's escapes is
  /// valid YAML and round-trips exactly — where the single quotes this used to
  /// write could not escape a newline at all. `{'multi': 'line1\nline2'}`
  /// was written as a single-quoted scalar broken across two lines, which YAML
  /// folds back to one: the newline was silently lost, and so was a trailing
  /// space.
  static String _scalar(String text) {
    if (text.isEmpty) return "''";
    if (_reserved.contains(text.toLowerCase())) return jsonEncode(text);
    if (num.tryParse(text) != null) return jsonEncode(text);
    if (!_bare.hasMatch(text)) return jsonEncode(text);
    // A bare scalar cannot end in a space: YAML strips it on the way back.
    if (text != text.trimRight()) return jsonEncode(text);
    return text;
  }
}
