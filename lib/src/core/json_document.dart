import 'dart:convert';

import 'jsonpath.dart';

/// A parsed JSON document with JSONPath selector, indexing, and serialization support.
///
/// {@category Formats}
class JsonDocument {
  /// The underlying raw JSON value (Map, List, or primitive).
  final Object? raw;

  /// Creates a [JsonDocument] wrapping a [raw] JSON value.
  const JsonDocument(this.raw);

  /// Parses [text] as JSON.
  factory JsonDocument.parse(String text) => JsonDocument(jsonDecode(text));

  /// Finds all nodes matching JSONPath [expression].
  List<JsonDocument> $(String expression) => JsonPath.of(expression).read(raw).map(JsonDocument.new).toList();

  /// Accesses a child node by map key ([String]) or list index ([int]).
  ///
  /// A negative index counts from the end, as `$[-1]` does. A missing key or an
  /// out-of-range index yields the null document; any other key type throws
  /// [ArgumentError].
  JsonDocument operator [](Object keyOrIndex) {
    switch (keyOrIndex) {
      case String():
        return raw is Map ? JsonDocument((raw as Map)[keyOrIndex]) : const JsonDocument(null);
      case int():
        if (raw is List) {
          final list = raw as List;
          final i = keyOrIndex < 0 ? list.length + keyOrIndex : keyOrIndex;
          if (i >= 0 && i < list.length) return JsonDocument(list[i]);
        }
        return const JsonDocument(null);
      default:
        throw ArgumentError.value(keyOrIndex, 'keyOrIndex', 'Must be a String key or an int index');
    }
  }

  /// Whether this JSON document represents null.
  bool get isNull => raw == null;

  /// Whether this JSON document represents a non-null value.
  bool get isNotNull => !isNull;

  /// Returns [raw] as a list of [JsonDocument]s, or empty list.
  List<JsonDocument> get list => raw is List ? (raw as List).map(JsonDocument.new).toList() : const [];

  /// Returns [raw] as a map of String to [JsonDocument]s, or empty map.
  Map<String, JsonDocument> get map =>
      raw is Map ? (raw as Map).map((k, v) => MapEntry('$k', JsonDocument(v))) : const {};

  /// Converts or casts [raw] to type [T], or returns `null`.
  ///
  /// Numbers and booleans are parsed from strings; a `Map` or `List` asked for as
  /// `String` comes back JSON encoded. Nullable type arguments are accepted.
  T? to<T>() {
    final val = raw;
    if (val == null) return null;
    if (val is T) return val as T;
    if (const <String>[] is List<T>) return (val is Map || val is List ? jsonEncode(val) : val.toString()) as T;
    // `num` before `int` and `double`: `const <int>[] is List<num>` is true.
    if (const <num>[] is List<T>) return num.tryParse('$val') as T?;
    if (const <int>[] is List<T>) return (val is num ? val.toInt() : int.tryParse('$val')) as T?;
    if (const <double>[] is List<T>) return (val is num ? val.toDouble() : double.tryParse('$val')) as T?;
    if (const <bool>[] is List<T>) {
      if (val == 'true' || val == 1) return true as T;
      if (val == 'false' || val == 0) return false as T;
    }
    return null;
  }

  /// Converts this document to a JSON encoded string.
  @override
  String toString() => jsonEncode(raw);
}
