part of '../../../json.dart';

/// A JSONPath, checked when made: what a `Doc`'s `$(…)` takes. It is a [String], so it goes
/// wherever a JSONPath's text does, and is compiled once.
///
/// ```dart
/// final ids = 'items[*].id'.jsonPath;     // the root's `$` may go unwritten
/// doc.$(ids).to<List<int>>();
/// ```
///
/// {@category Formats}
extension type const JsonPath._(String _text) implements String {
  /// [text] as a JSONPath, from the root whether or not it starts `$`; one that does not parse
  /// is a [FormatException] naming where.
  JsonPath(String text) : _text = text {
    _JsonPath.of(text);
  }
}

/// Text read as a [JsonPath].
///
/// {@category Formats}
extension StringJsonPathExtensions on String {
  /// This text as a [JsonPath]: `'items[*].id'.jsonPath`. One that does not parse is a
  /// [FormatException].
  JsonPath get jsonPath => JsonPath(this);
}
