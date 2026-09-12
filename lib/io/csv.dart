/// # CSV Files
///
/// Streaming and atomic reading and writing of CSV files.
library;

import 'dart:convert';
import 'dart:io';

import '../src/csvtext.dart';
import '../src/fs.dart';
import 'entry.dart';

// ============================================================================
// CSV FILES - Streaming & Atomic File Access
// ============================================================================

/// Reads [path] as raw rows of cells synchronously.
Iterable<List<String>> readCsvRowsSync(
  String path, {
  String delimiter = ',',
  Encoding encoding = utf8,
}) => _rowsSync(path, delimiter: delimiter, encoding: encoding);

Iterable<List<String>> _rowsSync(
  String path, {
  required String delimiter,
  required Encoding encoding,
}) sync* {
  final file = File(path);
  if (!file.existsSync()) return;

  final pending = <List<String>>[];
  final scanner = CsvScanner(pending.add, delimiter: delimiter);
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

/// Reads [path] as raw rows of cells asynchronously.
Stream<List<String>> readCsvRows(
  String path, {
  String delimiter = ',',
  Encoding encoding = utf8,
}) => _rowsAsync(path, delimiter: delimiter, encoding: encoding);

Stream<List<String>> _rowsAsync(
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

/// Reads [path] as records keyed by the header line synchronously.
Iterable<Map<String, String>> readCsvRecordsSync(
  String path, {
  String delimiter = ',',
  Encoding encoding = utf8,
}) => _recordsSync(path, delimiter: delimiter, encoding: encoding);

Iterable<Map<String, String>> _recordsSync(
  String path, {
  required String delimiter,
  required Encoding encoding,
}) sync* {
  List<String>? headers;
  for (final row in _rowsSync(path, delimiter: delimiter, encoding: encoding)) {
    if (headers == null) {
      headers = row;
      continue;
    }
    if (!CsvText.blank(row)) yield _record(headers, row);
  }
}

/// Reads [path] as records keyed by the header line asynchronously.
Stream<Map<String, String>> readCsvRecords(
  String path, {
  String delimiter = ',',
  Encoding encoding = utf8,
}) => _recordsAsync(path, delimiter: delimiter, encoding: encoding);

Stream<Map<String, String>> _recordsAsync(
  String path, {
  required String delimiter,
  required Encoding encoding,
}) async* {
  List<String>? headers;
  await for (final row in _rowsAsync(
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

/// Writes [rows] to [path] atomically and synchronously.
FileSystemEntry writeCsvSync<V>(
  String path,
  Iterable<Map<String, V>> rows, {
  List<String>? headers,
  String delimiter = ',',
  String newline = '\n',
  String part = '.part',
}) => Fs.entryFor(
  Fs.writeSync(
    path,
    CsvText.records(
      rows.toList(),
      headers: headers,
      delimiter: delimiter,
      newline: newline,
    ),
    part: part,
  ).path,
);

/// Writes [rows] to [path] as they arrive, atomically.
Future<FileSystemEntry> writeCsv<V>(
  String path,
  Stream<Map<String, V>> rows, {
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
      await for (final row in rows) {
        columns ??= row.keys.toList();
        header();
        line([for (final key in columns) row[key]?.toString() ?? '']);
      }
      header();
      await sink.flush();
    } finally {
      await sink.close();
    }
  }, part: part)).path,
);

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
