/// # CSV Tables (`io.csv.*`)
///
/// An RFC 4180-style reader and writer with no external dependency: quoted
/// fields, escaped quotes, and `\r\n` or `\n` line endings.
library;

import 'dart:convert';
import 'dart:io';

import '../src/fs.dart';
import '../util/sequence.dart';

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

  /// Renders [rows] as CSV text, one record per line.
  ///
  /// Columns come from [headers], or from the union of every row's keys in the
  /// order they are first seen — so a field only later records carry still
  /// gets a column instead of being silently dropped.
  ///
  /// [newline] ends every line. The default is `\n`; pass `\r\n` for the line
  /// ending Excel and RFC 4180 expect.
  ///
  /// ```dart
  /// io.csv.format([
  ///   {'name': 'Ada', 'born': 1815},
  ///   {'name': 'Alan', 'born': 1912},
  /// ]);
  /// ```
  ///
  /// For rows that are already lists of cells, see [cells].
  String format(
    Iterable<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) {
    final list = rows.toList();
    final keys =
        headers ?? <String>{for (final row in list) ...row.keys}.toList();
    if (list.isEmpty && keys.isEmpty) return '';

    final buffer =
        StringBuffer()
          ..write(keys.map((k) => _escape(k, delimiter)).join(delimiter))
          ..write(newline);
    for (final row in list) {
      buffer
        ..write(
          keys
              .map((k) => _escape(row[k]?.toString() ?? '', delimiter))
              .join(delimiter),
        )
        ..write(newline);
    }
    return buffer.toString();
  }

  /// Renders [rows] of cells as CSV text, one row per line.
  ///
  /// The twin of [format] for data that is already a grid — what [matrix]
  /// reads back. [headers] is written as a first line when given.
  ///
  /// ```dart
  /// io.write('out.csv', io.csv.cells([
  ///   ['Ada', 1815],
  ///   ['Alan', 1912],
  /// ], headers: ['name', 'born']));
  /// ```
  ///
  /// Writing it goes through [io.write] rather than a second name here. The
  /// two used to be one method taking `Iterable<dynamic>` and deciding at
  /// runtime which shape it had been handed.
  String cells(
    Iterable<List<Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) {
    final buffer = StringBuffer();
    if (headers != null && headers.isNotEmpty) {
      buffer
        ..write(headers.map((h) => _escape(h, delimiter)).join(delimiter))
        ..write(newline);
    }
    for (final row in rows) {
      buffer
        ..write(
          row
              .map((cell) => _escape(cell?.toString() ?? '', delimiter))
              .join(delimiter),
        )
        ..write(newline);
    }
    return buffer.toString();
  }

  /// Reads [path] as records keyed by the header line.
  ///
  /// Empty when the file does not exist. Blank lines are skipped, and short
  /// rows are padded with empty strings. A [Sequence], so the report is the
  /// next call:
  ///
  /// ```dart
  /// final rows = await io.csv.maps('sales.csv');
  /// rows.tally((r) => r['region']!).seq.each(print);
  /// ```
  Future<Sequence<Map<String, String>>> maps(
    String path, {
    String delimiter = ',',
  }) async {
    final rows = await _all(path, delimiter);
    if (rows.isEmpty) return const Sequence([]);
    final keys = rows.first;
    return Sequence([
      for (final row in rows.skip(1))
        if (!_blank(row))
          {
            for (var i = 0; i < keys.length; i++)
              keys[i]: i < row.length ? row[i] : '',
          },
    ]);
  }

  /// Reads [path] as raw rows of cells, header line included.
  ///
  /// Empty when the file does not exist.
  Future<Sequence<List<String>>> matrix(
    String path, {
    String delimiter = ',',
  }) async => Sequence(await _all(path, delimiter));

  /// Streams [path] as raw rows of cells, header line included.
  ///
  /// Where [matrix] reads the whole file, this yields a row at a time, so a
  /// file larger than memory can still be walked. Yields nothing when the file
  /// does not exist.
  Stream<List<String>> rows(
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
  /// Where [maps] reads the whole file, this yields a record at a time. Blank
  /// lines are skipped and short rows are padded with empty strings, as in
  /// [maps].
  Stream<Map<String, String>> records(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) async* {
    List<String>? headers;
    await for (final row in rows(
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

  /// Writes [rows] to [path] atomically, one record per line.
  ///
  /// [newline] ends every line, as in [format]. For a grid of cells, render it
  /// with [cells] and write it with `io.write`.
  Future<File> write(
    String path,
    Iterable<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
  }) => Fs.write(
    path,
    format(rows, headers: headers, delimiter: delimiter, newline: newline),
    part: part,
  );

  /// Writes [rows] to [path] as they arrive, atomically.
  ///
  /// The streaming twin of [write]: where that one takes a collection already
  /// in memory, this takes a [Stream] and never holds more than one row. That
  /// is what turns a crawl of any size into a spreadsheet in one line —
  /// [write] would need every result collected first:
  ///
  /// ```dart
  /// await io.csv.pipe(
  ///   'products.csv',
  ///   net.crawl<Map<String, Object?>>(seed).stream(handler),
  ///   headers: ['name', 'price', 'url'],
  /// );
  /// ```
  ///
  /// A stream cannot be read twice, so the columns have to be settled before
  /// the first row is written:
  /// [headers] names them, and without it they are taken from the first row's
  /// keys. A later key the header line does not carry is dropped — pass
  /// [headers] when the rows are not all the same shape.
  ///
  /// The file appears complete or not at all: rows are written to a `.part`
  /// staging file that is renamed into place once the stream closes, and
  /// discarded if it fails.
  Future<File> pipe(
    String path,
    Stream<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
    Encoding encoding = utf8,
  }) => Fs.atomic(path, (staging) async {
    final sink = staging.openWrite(encoding: encoding);
    var columns = headers;
    var headed = false;

    void line(Iterable<String> cells) => sink.write(
      '${cells.map((cell) => _escape(cell, delimiter)).join(delimiter)}'
      '$newline',
    );

    void header() {
      final names = columns;
      if (headed || names == null) return;
      line(names);
      headed = true;
    }

    try {
      await for (final row in rows) {
        columns ??= row.keys.toList();
        header();
        line([for (final key in columns) row[key]?.toString() ?? '']);
      }
      // A stream that closed without yielding still writes the header it was
      // given, so an empty result reads as an empty table, not an empty file.
      header();
      await sink.flush();
    } finally {
      await sink.close();
    }
  }, part: part);

  Future<List<List<String>>> _all(String path, String delimiter) async {
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
