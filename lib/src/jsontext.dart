/// # JSON Text (internal)
///
/// The two `dart:convert` calls the library's JSON support is built on, in one
/// place so that `format.json`, `net.serve` and the other `format` codecs all
/// decode and encode identically. Public through `format.json.parse` and
/// `format.json.format`; never a public name of its own.
library;

import 'dart:convert';

// ============================================================================
// JSON TEXT (internal)
// ============================================================================

/// Decoding and encoding JSON text.
class JsonText {
  JsonText._();

  /// [text] decoded, or `null` when it is not JSON.
  ///
  /// Non-throwing, because every public reader built on this keeps the
  /// contract that an absent or unreadable document is an empty value rather
  /// than an exception.
  static Object? decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// [value] encoded as JSON text, indented by [indent] spaces.
  ///
  /// `indent: 0` gives the compact single-line form.
  static String encode(Object? value, {int indent = 2}) => indent <= 0
      ? jsonEncode(value)
      : JsonEncoder.withIndent(' ' * indent).convert(value);

  /// [value] encoded, or its `toString` when it holds something JSON cannot
  /// carry.
  ///
  /// For a `toString`, where refusing to render is never the right answer.
  static String describe(Object? value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return '$value';
    }
  }
}
