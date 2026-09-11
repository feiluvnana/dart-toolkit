/// # CSV Files (`io.csv.*`)
///
/// The CSV operations that are about a **file larger than memory**: reading
/// one a row at a time, and writing one a row at a time.
///
/// Parsing and formatting CSV *text* is `format.csv`, beside the other five
/// formats. The split is not arbitrary — it is the same one `format.zip.pack`
/// and `io.write` already make. A codec turns bytes into a document; these
/// exist because the document does not fit.
///
/// ```dart no-compile
/// io.csv.records('huge.csv').collect(.foreach(use));        // blocking
/// await io.async.csv.records('huge.csv').collect(.foreach(use));
///
/// io.csv.write('out.csv', rows);                               // blocking
/// await io.async.csv.write('out.csv', rows.flow);              // streaming
///
/// final sheet = await format.csv.read('small.csv');            // whole file
/// ```
///
/// ## Both accessors, and the mirror rule
///
/// `io.csv` was the one corner where the prefix did not tell you what you
/// got: its members returned a [Flow] and a `Future` from `io`, whose doc
/// promises that everything there blocks, and the mirror rule needed a
/// carve-out saying so. It does not any more. The same three names sit on
/// both accessors, differing in the one way the rule specifies — a
/// [Sequence] on `io`, a [Flow] on `io.async`:
///
/// | | `io.csv` | `io.async.csv` |
/// | :--- | :--- | :--- |
/// | [CsvFileAccessor.rows] | `Sequence<List<String>>` | `Flow<List<String>>` |
/// | [CsvFileAccessor.records] | `Sequence<Map<String, String>>` | `Flow<Map<String, String>>` |
/// | [CsvFileAccessor.write] | takes a `Sequence` | takes a `Flow` |
///
/// `io.csv.pipe` is gone with it. It was a second name for [write] — Rule 5
/// allows a shorthand *defined as* the general form in one line, and that was
/// forty lines of its own implementation — and it was the weaker name.
library;

import 'dart:convert';
import 'dart:io';

import '../src/csvtext.dart';
import '../src/fs.dart';
import '../collection/flow.dart';
import '../collection/sequence.dart';
import 'entry.dart';

// ============================================================================
// CSV FILES (io.csv.*)
// ============================================================================

/// Entry point for streaming CSV file access, reachable as `io.csv`.
///
/// Reads come in two shapes, chosen by the method rather than a type
/// argument: [records] treats the first line as a header and yields one map
/// per row, while [rows] yields every line as a list of cells. Both hand back
/// a [Sequence], so the whole [Transformer] and [Collector] vocabulary
/// reaches a file too large to hold — lazily, a row at a time.
///
/// ```dart
/// io.csv.records('people.csv')
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
  Sequence<List<String>> rows(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => Sequence(_rows(path, delimiter: delimiter, encoding: encoding));

  Iterable<List<String>> _rows(
    String path, {
    required String delimiter,
    required Encoding encoding,
  }) sync* {
    final file = File(path);
    if (!file.existsSync()) return;

    final pending = <List<String>>[];
    final scanner = CsvScanner(pending.add, delimiter: delimiter);
    // Decoded in chunks rather than per read, so a multi-byte character that
    // straddles two reads is still one character.
    final decoder = encoding.decoder.startChunkedConversion(_Feed(scanner.add));
    for (final chunk in Fs.chunksSync(path)) {
      decoder.add(chunk);
      yield* pending;
      pending.clear();
    }
    decoder.close();
    scanner.close();
    yield* pending;
  }

  /// Reads [path] as records keyed by the header line.
  ///
  /// Where `format.csv.read(path)` then `.maps` reads the whole file, this
  /// yields a record at a time. Blank lines are skipped and short rows are
  /// padded with empty strings.
  Sequence<Map<String, String>> records(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => Sequence(_records(path, delimiter: delimiter, encoding: encoding));

  Iterable<Map<String, String>> _records(
    String path, {
    required String delimiter,
    required Encoding encoding,
  }) sync* {
    List<String>? headers;
    for (final row in _rows(path, delimiter: delimiter, encoding: encoding)) {
      if (headers == null) {
        headers = row;
        continue;
      }
      if (!CsvText.blank(row)) yield _record(headers, row);
    }
  }

  /// Writes [rows] to [path] atomically, one record per line.
  ///
  /// [newline] ends every line, as in `format.csv.format`. For a grid of
  /// cells, render it with `format.csv.cells` and write it with `io.write`.
  ///
  /// [V] is the cell type, so a `Sequence<Map<String, String>>` and a
  /// `Sequence<Map<String, Object?>>` both fit without either being widened
  /// at the call — every cell is rendered by its `toString` either way.
  FileSystemEntry write<V>(
    String path,
    Sequence<Map<String, V>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
    String part = '.part',
  }) => Fs.entryFor(
    Fs.writeSync(
      path,
      CsvText.records(
        rows.collect(.list()),
        headers: headers,
        delimiter: delimiter,
        newline: newline,
      ),
      part: part,
    ).path,
  );
}

/// The non-blocking mirror of [CsvFileAccessor], reachable as `io.async.csv`.
///
/// The same three names, reading and writing as the rows arrive rather than
/// holding the file. See the library doc for the table.
class CsvFileAsyncAccessor {
  /// Creates the accessor. Prefer the shared `io.async.csv` instance.
  const CsvFileAsyncAccessor();

  /// Reads [path] as raw rows of cells. See [CsvFileAccessor.rows].
  Flow<List<String>> rows(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => Flow.of(() => _rows(path, delimiter: delimiter, encoding: encoding));

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
  /// See [CsvFileAccessor.records].
  Flow<Map<String, String>> records(
    String path, {
    String delimiter = ',',
    Encoding encoding = utf8,
  }) => Flow.of(() => _records(path, delimiter: delimiter, encoding: encoding));

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
      if (!CsvText.blank(row)) yield _record(headers, row);
    }
  }

  /// Writes [rows] to [path] as they arrive, atomically.
  ///
  /// The streaming twin of [CsvFileAccessor.write]: where that one takes a
  /// collection already in memory, this takes a [Flow] and never holds more
  /// than one row. That is what turns a crawl of any size into a spreadsheet
  /// in one line:
  ///
  /// ```dart
  /// await io.async.csv.write(
  ///   'products.csv',
  ///   net.crawl([Fetch(seed)]).flow.transform(
  ///     .map((res) => <String, Object?>{'name': res.url.path}),
  ///   ),
  ///   headers: ['name', 'price', 'url'],
  /// );
  /// ```
  ///
  /// A flow is consumed once, so the columns have to be settled before the
  /// first row is written: [headers] names them, and without it they are
  /// taken from the first row's keys. A later key the header line does not
  /// carry is dropped — pass [headers] when the rows are not all the same
  /// shape.
  ///
  /// The file appears complete or not at all: rows are written to a staging
  /// file that is renamed into place once the flow ends, and discarded if it
  /// fails.
  ///
  /// This was `io.csv.pipe` through 5.4.0 — a second name, and a second
  /// implementation, for the operation [CsvFileAccessor.write] already was.
  Future<FileSystemEntry> write<V>(
    String path,
    Flow<Map<String, V>> rows, {
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

/// One row keyed by [headers], short rows padded with empty strings.
Map<String, String> _record(List<String> headers, List<String> row) => {
  for (var i = 0; i < headers.length; i++)
    headers[i]: i < row.length ? row[i] : '',
};

/// A [Sink] that hands each decoded piece of text straight to a callback.
class _Feed implements Sink<String> {
  _Feed(this._each);

  final void Function(String text) _each;

  @override
  void add(String data) => _each(data);

  @override
  void close() {}
}
