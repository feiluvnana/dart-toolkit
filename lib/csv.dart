/// CSV per RFC 4180: quoted fields, `""` escapes, CRLF or LF, embedded
/// newlines, a leading BOM. Pure Dart.
///
/// ```dart
/// final rows = await Fs.file('sales.csv').csv();
/// final people = Csv.records(await Fs.file('people.csv').text());   // header row → keys
/// await Fs.file('out.csv').write(Csv.encode([['name', 'n'], ['a', 1]]));
/// ```
///
/// Public surface is exactly: [Csv], [ReaderCsv].
/// - `Csv.parse()` reads rows, `Csv.records()` maps them by the header row,
///   `Csv.encode()` writes rows.
/// - `reader.csv()` parses any [Reader]; `reader.rows()` streams its rows.
/// Everything else is private.
library;

import 'dart:convert';
import 'dart:io' show PathNotFoundException;

import 'core.dart';
export 'core.dart';

/// Entry point: parse and encode.
abstract final class Csv {
  /// The rows of [text]. A field is quoted when it holds [sep], a quote or
  /// a newline; a blank line is no row. Throws [ContentException] on an
  /// unterminated quote.
  static List<List<String>> parse(String text, {String sep = ','}) {
    final rows = <List<String>>[];
    (_Rows(sep, rows.add)..feed(text)).end();
    return rows;
  }

  /// The rows of [text] after the first, as maps keyed by the first row. A
  /// short row leaves its missing keys out; extra cells are dropped.
  static List<Map<String, String>> records(String text, {String sep = ','}) {
    final rows = parse(text, sep: sep);
    if (rows.isEmpty) return [];
    final keys = rows.first;
    return [
      for (final row in rows.skip(1)) {for (var k = 0; k < row.length && k < keys.length; k++) keys[k]: row[k]},
    ];
  }

  /// [rows] as CSV text with CRLF line ends. A null cell is empty; a field
  /// holding [sep], a quote, a newline or edge spaces is quoted.
  static String encode(List<List<Object?>> rows, {String sep = ','}) {
    final out = StringBuffer();
    for (final row in rows) {
      for (final (k, cell) in row.indexed) {
        if (k > 0) out.write(sep);
        final f = '${cell ?? ''}';
        final quote =
            f.contains(sep) ||
            f.contains('"') ||
            f.contains('\n') ||
            f.contains('\r') ||
            (f.isNotEmpty && (f.startsWith(' ') || f.endsWith(' ')));
        out.write(quote ? '"${f.replaceAll('"', '""')}"' : f);
      }
      out.write('\r\n');
    }
    return out.toString();
  }
}

/// `reader.csv()`: the rows of any [Reader] (`Fs.file`, an http response);
/// `reader.rows()` streams them as they arrive, in constant memory.
extension ReaderCsv on Reader {
  /// Every row, split on [sep] (quotes and CRLF handled); [or] when the
  /// source does not exist.
  Future<List<List<String>>> csv({String sep = ',', List<List<String>>? or}) async {
    final String body;
    try {
      body = await text();
    } on PathNotFoundException {
      if (or != null) return or;
      rethrow;
    }
    return Csv.parse(body, sep: sep);
  }

  /// The CSV rows one at a time as the bytes arrive: a multi-gigabyte
  /// export reads in constant memory. Same rules as [Csv.parse].
  Stream<List<String>> rows({String sep = ','}) async* {
    final ready = <List<String>>[];
    final rows = _Rows(sep, ready.add);
    await for (final chunk in stream().transform(const Utf8Decoder(allowMalformed: true))) {
      rows.feed(chunk);
      for (final row in ready) {
        yield row;
      }
      ready.clear();
    }
    rows.end();
    for (final row in ready) {
      yield row;
    }
  }
}

/// The Future mirror (rule 4).
extension ReaderFutureCsv on Future<Reader> {
  Future<List<List<String>>> csv({String sep = ',', List<List<String>>? or}) async =>
      (await this).csv(sep: sep, or: or);
  Stream<List<String>> rows({String sep = ','}) => Stream.fromFuture(this).asyncExpand((r) => r.rows(sep: sep));
}

/// The RFC 4180 state machine, fed text in pieces (a whole string or
/// decoded chunks), emitting each row as it completes.
final class _Rows {
  _Rows(String sep, this._emit) : _sep = _check(sep);

  static int _check(String sep) {
    if (sep.length != 1 || sep == '"' || sep == '\n' || sep == '\r') {
      throw ArgumentError.value(sep, 'sep', 'must be one character other than a quote or a newline');
    }
    return sep.codeUnitAt(0);
  }

  final int _sep;
  final void Function(List<String> row) _emit;
  var _row = <String>[];
  final _field = StringBuffer();
  var _quoted = false, _any = false, _start = true, _cr = false, _endQuote = false;
  var _offset = 0;

  void _endField() {
    _row.add(_field.toString());
    _field.clear();
    _any = false;
  }

  void _endRow() {
    // A blank line (one empty, unquoted field) is no record.
    if (_row.isEmpty && _field.isEmpty && !_any) return;
    _endField();
    _emit(_row);
    _row = <String>[];
  }

  void feed(String text) {
    var i = 0;
    if (_start) {
      _start = false;
      if (text.startsWith('\uFEFF')) i = 1;
    }
    final n = text.length;
    while (i < n) {
      final c = text.codeUnitAt(i++);
      if (_cr) {
        _cr = false;
        if (c == 0x0A) continue; // the LF of a CRLF split across chunks
      }
      if (_endQuote) {
        // The quote before this may close the field or start a `""`.
        _endQuote = false;
        if (c == 0x22) {
          _field.writeCharCode(0x22);
          _quoted = true;
          continue;
        }
      }
      if (_quoted) {
        if (c == 0x22) {
          _quoted = false;
          _endQuote = true;
        } else {
          _field.writeCharCode(c);
        }
        continue;
      }
      if (c == 0x22 && _field.isEmpty && !_any) {
        _quoted = _any = true;
      } else if (c == _sep) {
        _endField();
      } else if (c == 0x0D || c == 0x0A) {
        _cr = c == 0x0D;
        _endRow();
      } else {
        _field.writeCharCode(c);
        _any = true;
      }
    }
    _offset += n;
  }

  void end() {
    if (_quoted) throw ContentException('unterminated quoted CSV field', null, _offset);
    if (_field.isNotEmpty || _any || _row.isNotEmpty) _endRow();
  }
}
