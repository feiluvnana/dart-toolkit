part of '../../../formats.dart';

// These live in `formats`, which already imports `collection`, and not the other way round:
// `collection` importing `formats` for them put every parser in the package into a program
// that only wanted a `Table`, about 280 ms of `dart run` compile.

/// A JSON array of objects as a [Table].
///
/// {@category Collections}
extension JsonTableExtensions on JsonDocument {
  /// The rows of this array of objects; a non-object element is skipped.
  Table get table => list.table;
}

/// {@category Collections}
extension JsonDocumentsTableExtensions on Iterable<JsonDocument> {
  /// The rows of these documents, each an object; a non-object is skipped.
  Table get table => Table.rows([
    for (final item in this)
      if (item.raw case final Map<Object?, Object?> m) {for (final MapEntry(:key, :value) in m.entries) '$key': value},
  ]);
}
