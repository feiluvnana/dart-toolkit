import 'dart:io';

import 'file.dart';

// ============================================================================
// CSV SERIALIZATION & PARSING SUBSYSTEM (csv.* / Csv)
// ============================================================================

/// Top-level CSV serialization and parsing accessor.
///
/// Provides strictly 1-word methods for reading, writing, parsing, and formatting CSV data:
/// ```dart
/// // Read file as a list of maps using header keys
/// final records = await csv.read('data/users.csv');
///
/// // Atomically write maps to a CSV file
/// await csv.write('output/results.csv', [
///   {'id': 1, 'name': 'Dart', 'active': true},
///   {'id': 2, 'name': 'Flutter', 'active': true},
/// ]);
/// CSV manager providing RFC-4180 compliant parsing and formatting.
class CsvAccessor {
  /// Creates a [CsvAccessor].
  const CsvAccessor();

  /// Parses raw CSV text into a matrix of rows and columns (1-word).
  List<List<String>> parse(String text, {String delimiter = ','}) {
    final rows = <List<String>>[];
    final currentField = StringBuffer();
    final currentRow = <String>[];
    var inQuotes = false;
    final len = text.length;

    for (var i = 0; i < len; i++) {
      final char = text[i];

      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < len && text[i + 1] == '"') {
            currentField.write('"');
            i++; // Skip escaped quote
          } else {
            inQuotes = false;
          }
        } else {
          currentField.write(char);
        }
      } else {
        if (char == '"') {
          inQuotes = true;
        } else if (char == delimiter) {
          currentRow.add(currentField.toString());
          currentField.clear();
        } else if (char == '\r') {
          if (i + 1 < len && text[i + 1] == '\n') {
            i++;
          }
          currentRow.add(currentField.toString());
          currentField.clear();
          rows.add(List<String>.from(currentRow));
          currentRow.clear();
        } else if (char == '\n') {
          currentRow.add(currentField.toString());
          currentField.clear();
          rows.add(List<String>.from(currentRow));
          currentRow.clear();
        } else {
          currentField.write(char);
        }
      }
    }

    if (currentField.isNotEmpty || currentRow.isNotEmpty) {
      currentRow.add(currentField.toString());
      rows.add(currentRow);
    }

    return rows;
  }

  /// Formats matrix data or maps into an RFC-4180 compliant CSV string (1-word).
  String format(Object? data, {List<String>? headers, String delimiter = ','}) {
    final buffer = StringBuffer();

    if (data is List && data.isNotEmpty && data.first is Map) {
      final mapList = data.cast<Map<Object?, Object?>>();
      final keys =
          headers ?? mapList.first.keys.map((k) => k.toString()).toList();

      // Write header row
      buffer.writeln(keys.map((k) => _escape(k, delimiter)).join(delimiter));

      // Write data rows
      for (final map in mapList) {
        final row = keys
            .map((k) => _escape(map[k]?.toString() ?? '', delimiter))
            .join(delimiter);
        buffer.writeln(row);
      }
    } else if (data is Iterable) {
      if (headers != null && headers.isNotEmpty) {
        buffer.writeln(
          headers.map((h) => _escape(h, delimiter)).join(delimiter),
        );
      }
      for (final row in data) {
        if (row is Iterable) {
          buffer.writeln(
            row
                .map((cell) => _escape(cell?.toString() ?? '', delimiter))
                .join(delimiter),
          );
        } else {
          buffer.writeln(_escape(row?.toString() ?? '', delimiter));
        }
      }
    }

    return buffer.toString();
  }

  /// Reads a CSV file from [filePath] (1-word).
  ///
  /// If [header] is `true`, returns `List<Map<String, String>>`.
  /// If [header] is `false`, returns `List<List<String>>`.
  Future<List<T>> read<T>(
    Object filePath, {
    bool header = true,
    String delimiter = ',',
  }) async {
    final file = filePath is File ? filePath : File(filePath.toString());
    if (!file.existsSync()) {
      return <T>[];
    }

    final content = await file.readAsString();
    final matrix = parse(content, delimiter: delimiter);

    if (!header || matrix.isEmpty) return matrix as List<T>;

    final headerKeys = matrix.first;
    final records = <Map<String, String>>[];

    for (var i = 1; i < matrix.length; i++) {
      final row = matrix[i];
      if (row.isEmpty || (row.length == 1 && row.first.trim().isEmpty)) {
        continue;
      }

      final map = <String, String>{};
      for (var j = 0; j < headerKeys.length; j++) {
        map[headerKeys[j]] = j < row.length ? row[j] : '';
      }
      records.add(map);
    }

    return records as List<T>;
  }

  /// Reads a CSV file as a list of header-keyed maps (1-word).
  Future<List<Map<String, String>>> maps(
    Object filePath, {
    String delimiter = ',',
  }) => read<Map<String, String>>(filePath, header: true, delimiter: delimiter);

  /// Reads a CSV file as a raw matrix of rows and column values (1-word).
  Future<List<List<String>>> matrix(
    Object filePath, {
    String delimiter = ',',
  }) => read<List<String>>(filePath, header: false, delimiter: delimiter);

  /// Atomically writes [data] (maps or matrix) to a CSV file (1-word).
  Future<File> write(
    Object filePath,
    Object? data, {
    List<String>? headers,
    String delimiter = ',',
    String part = '.part',
  }) {
    final formatted = format(data, headers: headers, delimiter: delimiter);
    return Fs.write(filePath, formatted, part: part);
  }

  String _escape(String field, String delimiter) {
    if (field.contains(delimiter) ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }
}
