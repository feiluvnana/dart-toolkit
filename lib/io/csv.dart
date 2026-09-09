/// # CSV Tables (`io.csv.*`)
///
/// An RFC 4180-style reader and writer with no external dependency: quoted
/// fields, escaped quotes, and `\r\n` or `\n` line endings.
library;

import 'dart:convert';
import 'dart:io';

import '../src/fs.dart';

// ============================================================================
// CSV SERIALIZATION & PARSING (io.csv.*)
// ============================================================================

/// Entry point for CSV parsing and formatting, reachable as `io.csv`.
///
/// Reads come in two shapes, chosen by the method rather than a type argument:
/// [maps] treats the first line as a header and yields one map per row, while
/// [matrix] yields every line as a list of cells.
///
/// ```dart
/// final rows = await io.csv.maps('people.csv');
/// await io.csv.write('out.csv', rows);
/// ```
class CsvAccessor {
  /// Creates the accessor. Prefer the shared `io.csv` instance.
  const CsvAccessor();

  /// Parses CSV [text] into rows of cells.
  ///
  /// Handles quoted fields containing [delimiter], newlines, and `""` escaped
  /// quotes. [delimiter] may be more than one character. Blank lines produce
  /// no row, so a trailing newline does not add an empty one.
  List<List<String>> parse(String text, {String delimiter = ','}) {
    final rows = <List<String>>[];
    final field = StringBuffer();
    final row = <String>[];
    final sep = delimiter.isEmpty ? ',' : delimiter;
    var quoted = false;

    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      // A line with nothing on it at all is separation, not an empty record.
      if (field.isEmpty && row.isEmpty) return;
      endField();
      rows.add(List<String>.of(row));
      row.clear();
    }

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char != '"') {
          field.write(char);
        } else if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
        continue;
      }
      if (char == '"') {
        quoted = true;
        continue;
      }
      if (char == '\r') {
        if (i + 1 < text.length && text[i + 1] == '\n') i++;
        endRow();
        continue;
      }
      if (char == '\n') {
        endRow();
        continue;
      }
      if (text.startsWith(sep, i)) {
        endField();
        i += sep.length - 1;
        continue;
      }
      field.write(char);
    }
    if (field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }

  /// Renders [rows] (maps or rows of cells) as CSV text.
  ///
  /// When [rows] contains maps, columns come from [headers], or from the union
  /// of every row's keys in the order they are first seen.
  /// When [rows] contains cell lists, rows are prefixed with [headers] if supplied.
  String format(
    Iterable<dynamic> rows, {
    List<String>? headers,
    String delimiter = ',',
  }) {
    if (rows.isEmpty) {
      if (headers != null && headers.isNotEmpty) {
        return '${headers.map((h) => _escape(h, delimiter)).join(delimiter)}\n';
      }
      return '';
    }

    final first = rows.first;
    if (first is Map) {
      final list = rows.cast<Map<dynamic, dynamic>>().toList();
      // Every key any row carries becomes a column, in first-seen order.
      // Taking them from the first row alone would silently drop a field that
      // only later records have.
      final keys =
          headers ??
          <String>{
            for (final row in list) ...row.keys.map((k) => k.toString()),
          }.toList();
      final buffer =
          StringBuffer()
            ..writeln(keys.map((k) => _escape(k, delimiter)).join(delimiter));
      for (final row in list) {
        buffer.writeln(
          keys
              .map((k) => _escape(row[k]?.toString() ?? '', delimiter))
              .join(delimiter),
        );
      }
      return buffer.toString();
    }

    // Rows of cells
    final buffer = StringBuffer();
    if (headers != null && headers.isNotEmpty) {
      buffer.writeln(headers.map((h) => _escape(h, delimiter)).join(delimiter));
    }
    for (final row in rows) {
      if (row is Iterable) {
        buffer.writeln(
          row
              .map((cell) => _escape(cell?.toString() ?? '', delimiter))
              .join(delimiter),
        );
      }
    }
    return buffer.toString();
  }

  /// Renders [rows] of cells as CSV, optionally prefixed by [headers].
  ///
  /// Deprecated: prefer [format].
  String table(
    Iterable<Iterable<Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
  }) => format(rows, headers: headers, delimiter: delimiter);

  /// Reads [path] as CSV records.
  ///
  /// If [headers] is `true` (default), returns `List<Map<String, String>>`.
  /// If [headers] is `false`, returns raw `List<List<String>>` rows.
  Future<dynamic> read(
    String path, {
    bool headers = true,
    String delimiter = ',',
  }) async {
    if (headers) {
      return maps(path, delimiter: delimiter);
    } else {
      return matrix(path, delimiter: delimiter);
    }
  }

  /// Reads [path] as records keyed by the header line.
  ///
  /// Returns an empty list when the file does not exist. Blank lines are
  /// skipped, and short rows are padded with empty strings.
  Future<List<Map<String, String>>> maps(
    String path, {
    String delimiter = ',',
  }) async {
    final rows = await _rows(path, delimiter);
    if (rows.isEmpty) return [];
    final keys = rows.first;
    return [
      for (final row in rows.skip(1))
        if (!_blank(row))
          {
            for (var i = 0; i < keys.length; i++)
              keys[i]: i < row.length ? row[i] : '',
          },
    ];
  }

  /// Reads [path] as raw rows of cells, header line included.
  ///
  /// Returns an empty list when the file does not exist.
  Future<List<List<String>>> matrix(String path, {String delimiter = ','}) =>
      _rows(path, delimiter);

  /// Streams [path] as CSV records.
  ///
  /// When [headers] is `true`, yields `Map<String, String>` keyed by the first
  /// row. When [headers] is `false` (default), yields raw `List<String>` rows.
  /// Unlike [read], does not load the entire file into memory at once.
  Stream<dynamic> stream(
    String path, {
    bool headers = false,
    String delimiter = ',',
    Encoding encoding = utf8,
  }) {
    if (headers) {
      return records(path, delimiter: delimiter, encoding: encoding);
    }
    return _streamRows(path, delimiter: delimiter, encoding: encoding);
  }

  Stream<List<String>> _streamRows(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) async* {
    final file = File(path);
    if (!await file.exists()) return;

    final field = StringBuffer();
    final row = <String>[];
    final sep = delimiter.isEmpty ? ',' : delimiter;
    var quoted = false;
    var pendingQuote = false;
    var carry = '';

    void endField() {
      row.add(field.toString());
      field.clear();
    }

    await for (final raw in file.openRead().transform(encoding.decoder)) {
      // A multi-character delimiter can straddle a chunk boundary, so hold
      // back the tail that might be the start of one.
      final chunk = carry + raw;
      final safe =
          sep.length > 1 ? chunk.length - (sep.length - 1) : chunk.length;
      var i = 0;
      for (; i < chunk.length; i++) {
        if (i >= safe && !pendingQuote && !quoted) break;
        final char = chunk[i];

        if (pendingQuote) {
          pendingQuote = false;
          if (char == '"') {
            field.write('"');
            continue;
          }
          quoted = false;
        }

        if (quoted) {
          if (char == '"') {
            pendingQuote = true;
          } else {
            field.write(char);
          }
          continue;
        }

        if (char == '"') {
          quoted = true;
          continue;
        }
        if (char == '\r') {
          if (i + 1 < chunk.length && chunk[i + 1] == '\n') i++;
          if (field.isNotEmpty || row.isNotEmpty) {
            endField();
            yield List<String>.of(row);
            row.clear();
          }
          continue;
        }
        if (char == '\n') {
          if (field.isNotEmpty || row.isNotEmpty) {
            endField();
            yield List<String>.of(row);
            row.clear();
          }
          continue;
        }
        if (chunk.startsWith(sep, i)) {
          endField();
          i += sep.length - 1;
          continue;
        }
        field.write(char);
      }
      carry = chunk.substring(i);
    }
    for (var i = 0; i < carry.length; i++) {
      final char = carry[i];
      if (char == '\r' || char == '\n') continue;
      if (carry.startsWith(sep, i)) {
        endField();
        i += sep.length - 1;
        continue;
      }
      field.write(char);
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      endField();
      yield List<String>.of(row);
    }
  }

  /// Streams [path] as records keyed by the header line.
  ///
  /// Deprecated: prefer `stream(path, headers: true)`.
  @Deprecated('Use stream(path, headers: true) instead')
  Stream<Map<String, String>> records(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) async* {
    List<String>? headers;
    await for (final row in _streamRows(
      path,
      delimiter: delimiter,
      encoding: encoding,
    )) {
      if (headers == null) {
        headers = row;
        continue;
      }
      if (!_blank(row)) {
        yield {
          for (var i = 0; i < headers.length; i++)
            headers[i]: i < row.length ? row[i] : '',
        };
      }
    }
  }

  /// Writes [rows] (maps or rows of cells) to [path] atomically.
  Future<File> write(
    String path,
    Iterable<dynamic> rows, {
    List<String>? headers,
    String delimiter = ',',
    String part = '.part',
  }) => Fs.write(
    path,
    format(rows, headers: headers, delimiter: delimiter),
    part: part,
  );

  Future<List<List<String>>> _rows(String path, String delimiter) async {
    final file = File(path);
    if (!file.existsSync()) return [];
    return parse(await file.readAsString(), delimiter: delimiter);
  }

  static bool _blank(List<String> row) =>
      row.isEmpty || (row.length == 1 && row.first.trim().isEmpty);

  static String _escape(String field, String delimiter) =>
      field.contains(delimiter) ||
              field.contains('"') ||
              field.contains('\n') ||
              field.contains('\r')
          ? '"${field.replaceAll('"', '""')}"'
          : field;
}
