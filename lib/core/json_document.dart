import 'dart:convert';

import 'src/jsonpath.dart';

/// A parsed JSON document with JSONPath selector and serialization support.
class JsonDocument {
  /// The underlying raw JSON value (Map, List, or primitive).
  final Object? raw;

  /// Creates a [JsonDocument] wrapping a [raw] JSON value.
  const JsonDocument(this.raw);

  /// Parses [text] as JSON.
  factory JsonDocument.parse(String text) => JsonDocument(jsonDecode(text));

  /// Evaluates a JSONPath query and returns matching nodes wrapped in [JsonDocument].
  List<JsonDocument> $jsonpath(String expression) => JsonPath.of(expression).read(raw).map(JsonDocument.new).toList();

  /// Converts this document to a JSON encoded string.
  @override
  String toString() => jsonEncode(raw);
}
