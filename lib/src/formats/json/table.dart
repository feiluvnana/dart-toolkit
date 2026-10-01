part of '../../../formats.dart';

// Here, not in `collection`: importing `formats` there costs a `Table`-only program ~280 ms.

/// JSON objects as a [Table]; `JsonDocument.table` is the one-document form.
///
/// {@category Collections}
extension JsonDocumentsTableExtensions on Iterable<JsonDocument> {
  /// The rows of these documents, each an object; a non-object is skipped.
  Table get table => Table.rows([
    for (final item in this)
      if (item.raw case final Map<Object?, Object?> m) {for (final MapEntry(:key, :value) in m.entries) '$key': value},
  ]);
}
