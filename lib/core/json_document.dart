import 'dart:convert';

import 'src/jsonpath.dart';

/// A parsed JSON document with JSONPath selector, indexing, and serialization support.
class JsonDocument {
  /// The underlying raw JSON value (Map, List, or primitive).
  final Object? raw;

  /// Creates a [JsonDocument] wrapping a [raw] JSON value.
  const JsonDocument(this.raw);

  /// Parses [text] as JSON.
  factory JsonDocument.parse(String text) => JsonDocument(jsonDecode(text));

  /// Evaluates a JSONPath query and returns matching nodes wrapped in [JsonDocument].
  List<JsonDocument> $jsonpath(String expression) =>
      JsonPath.of(expression).read(raw).map(JsonDocument.new).toList();

  /// Accesses a child node by map [key] or list [index].
  JsonDocument operator [](Object keyOrIndex) {
    if (raw is Map && keyOrIndex is String) {
      return JsonDocument((raw as Map)[keyOrIndex]);
    } else if (raw is List && keyOrIndex is int) {
      final list = raw as List;
      if (keyOrIndex >= 0 && keyOrIndex < list.length) {
        return JsonDocument(list[keyOrIndex]);
      }
    }
    return const JsonDocument(null);
  }

  /// Whether this JSON document represents null.
  bool get isNull => raw == null;

  /// Whether this JSON document represents a non-null value.
  bool get isNotNull => !isNull;

  /// Returns [raw] as a list of [JsonDocument]s, or empty list.
  List<JsonDocument> get list =>
      raw is List ? (raw as List).map(JsonDocument.new).toList() : const [];

  /// Returns [raw] as a map of String to [JsonDocument]s, or empty map.
  Map<String, JsonDocument> get map =>
      raw is Map ? (raw as Map).map((k, v) => MapEntry('$k', JsonDocument(v))) : const {};

  /// Converts or casts [raw] to type [T], or returns `null`.
  T? to<T>() {
    final val = raw;
    if (val == null) return null;
    if (val is T) return val as T;
    if (T == String) return val.toString() as T;
    if (T == int) {
      if (val is num) return val.toInt() as T;
      return int.tryParse('$val') as T?;
    }
    if (T == double) {
      if (val is num) return val.toDouble() as T;
      return double.tryParse('$val') as T?;
    }
    if (T == num) {
      return num.tryParse('$val') as T?;
    }
    if (T == bool) {
      if (val == 'true' || val == 1) return true as T;
      if (val == 'false' || val == 0) return false as T;
    }
    return null;
  }

  /// Converts this document to a JSON encoded string.
  @override
  String toString() => jsonEncode(raw);
}
