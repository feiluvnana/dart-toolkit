/// # CSV Files (`io.csv.*`)
///
/// The two CSV operations that are about a **file larger than memory**:
/// reading one a row at a time, and writing one a row at a time.
///
/// Parsing and formatting CSV *text* is `format.csv`, beside the other five
/// formats. The split is not arbitrary — it is the same one `format.zip.pack`
/// and `io.write` already make. A codec turns bytes into a document; these
/// four exist because the document does not fit.
///
/// ```dart no-compile
/// await io.csv.records('huge.csv').collect(.foreach(use));    // read
/// await io.csv.pipe('out.csv', rows);                         // write
///
/// final sheet = await format.csv.read('small.csv');           // whole file
/// ```
library;

import 'dart:convert';
import 'dart:io';

import '../src/csvtext.dart';
import '../src/fs.dart';
import '../collection/flow.dart';
import 'entry.dart';

// ============================================================================
// CSV FILES (io.csv.*)
// ============================================================================

/// Entry point for streaming CSV file access, reachable as `io.csv`.
///
/// Reads come in two shapes, chosen by the method rather than a type
/// argument: [records] treats the first line as a header and yields one map
/// per row, while [rows] yields every line as a list of cells. Both hand back
/// a [Flow], so the whole [Transformer] and [Collector] vocabulary reaches a
/// file too large to hold.
///
/// ```dart
/// await io.csv.records('people.csv')
///     .collect(.foreach((person) => print(person['name'])));
/// ```
class CsvFileAccessor {
  /// Creates the accessor. Prefer the shared `io.csv` instance.
  const CsvFileAccessor();

  /// Reads [path] as raw rows of cells, header line included.
  ///
  /// Where `format.csv.read` reads the whole file, this yields a row at a
  /// time, so a file larger than memory can still be walked. Yields nothing
  /// when the file does not exist.
  Flow<List<String>> rows(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => Flow(_rows(path, delimiter: delimiter, encoding: encoding));

  Stream<List<String>> _rows(
    String path, {
    required String delimiter,
    required Encoding encoding,
  }) async* {
    final file = File(path);
    if (!await file.exists()) return;

    final pending = <List<String>>[];
    final scanner = CsvScanner(pending.add, delimiter: delimiter);
    await for (final chunk in file.openRead().transform(encoding.decoder)) {
      scanner.add(chunk);
      for (final row in pending) {
        yield row;
      }
      pending.clear();
    }
    scanner.close();
    for (final row in pending) {
      yield row;
    }
  }

  /// Reads [path] as records keyed by the header line.
  ///
  /// Where `format.csv.read(path)` then `.maps` reads the whole file, this
  /// yields a record at a time. Blank lines are skipped and short rows are
  /// padded with empty strings.
  Flow<Map<String, String>> records(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => Flow(_records(path, delimiter: delimiter, encoding: encoding));

  Stream<Map<String, String>> _records(
    String path, {
    required String delimiter,
    required Encoding encoding,
  }) async* {
    List<String>? headers;
    await for (final row in _rows(
      path,
      delimiter: delimiter,
      encoding: encoding,
    )) {
      if (headers == null) {
        headers = row;
        continue;
      }
      if (!CsvText.blank(row)) {
        yield {
          for (var i = 0; i < headers.length; i++)
            headers[i]: i < row.length ? row[i] : '',
        };
      }
    }
  }

  /// Writes [rows] to [path] atomically, one record per line.
  ///
  /// [newline] ends every line, as in `format.csv.format`. For a grid of
  /// cells, render it with `format.csv.cells` and write it with `io.write`.
  Future<FileSystemEntry> write(
    String path,
    Iterable<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
  }) async => Fs.entryFor(
    (await Fs.write(
      path,
      CsvText.records(
        rows,
        headers: headers,
        delimiter: delimiter,
        newline: newline,
      ),
      part: part,
    )).path,
  );

  /// Writes [rows] to [path] as they arrive, atomically.
  ///
  /// The streaming twin of [write]: where that one takes a collection already
  /// in memory, this takes a [Flow] and never holds more than one row. That
  /// is what turns a crawl of any size into a spreadsheet in one line —
  /// [write] would need every result collected first:
  ///
  /// ```dart
  /// await io.csv.pipe(
  ///   'products.csv',
  ///   net.crawl<Map<String, Object?>>(seed).flow(),
  ///   headers: ['name', 'price', 'url'],
  /// );
  /// ```
  ///
  /// A flow is consumed once, so the columns have to be settled before
  /// the first row is written:
  /// [headers] names them, and without it they are taken from the first row's
  /// keys. A later key the header line does not carry is dropped — pass
  /// [headers] when the rows are not all the same shape.
  ///
  /// The file appears complete or not at all: rows are written to a `.part`
  /// staging file that is renamed into place once the stream closes, and
  /// discarded if it fails.
  Future<FileSystemEntry> pipe(
    String path,
    Flow<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
    Encoding encoding = utf8,
  }) async => Fs.entryFor(
    (await Fs.atomic(path, (staging) async {
      final sink = staging.openWrite(encoding: encoding);
      var columns = headers;
      var headed = false;

      void line(Iterable<String> cells) => sink.write(
        '${cells.map((cell) => CsvText.escape(cell, delimiter)).join(delimiter)}'
        '$newline',
      );

      void header() {
        final names = columns;
        if (headed || names == null) return;
        line(names);
        headed = true;
      }

      try {
        await for (final row in rows.stream) {
          columns ??= row.keys.toList();
          header();
          line([for (final key in columns) row[key]?.toString() ?? '']);
        }
        // A flow that ended without yielding still writes the header it was
        // given, so an empty result reads as an empty table, not an empty file.
        header();
        await sink.flush();
      } finally {
        await sink.close();
      }
    }, part: part)).path,
  );
}
