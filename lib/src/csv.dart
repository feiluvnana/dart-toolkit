/// CSV per RFC 4180 (exported by `utils` as [CsvUtils], [ReaderCsv] and
/// [ReaderFutureCsv]): quoted fields, `""` escapes, CRLF or LF, embedded
/// newlines, a leading BOM. Pure Dart.
library;

import 'dart:convert';

import '../core.dart';
import 'decoders.dart';
import 'missing.dart';

/// Entry point: parse and encode.
abstract final class CsvUtils {
  /// The rows of [text]. A field is quoted when it holds [sep], a quote or
  /// a newline; a blank line is no row. Throws [ContentException] on an
  /// unterminated quote.
  static List<List<String>> parse(String text, {String sep = ','}) {
    final rows = <List<String>>[];
    (_Rows(sep, rows.add)..feed(text)).end();
    return rows;
  }

  /// [rows] as CSV text with CRLF line ends. A null cell is empty; a field
  /// holding [sep], a quote, a newline or edge spaces is quoted, and so is
  /// a row's only cell when empty (a bare blank line is no row).
  static String encode(List<List<Object?>> rows, {String sep = ','}) {
    final out = StringBuffer();
    for (final row in rows) {
      for (final (k, cell) in row.indexed) {
        if (k > 0) out.write(sep);
        final f = '${cell ?? ''}';
        final quote =
            (f.isEmpty && row.length == 1) ||
            f.contains(sep) ||
            f.contains('"') ||
            f.contains('\n') ||
            f.contains('\r') ||
            f.startsWith(' ') ||
            f.endsWith(' ');
        out.write(quote ? '"${f.replaceAll('"', '""')}"' : f);
      }
      out.write('\r\n');
    }
    return out.toString();
  }

  /// Encodes a list of maps into CSV format, extracting headers from [maps] keys or explicit [columns].
  static String encodeMaps(List<Map<String, Object?>> maps, {List<String>? columns, String sep = ','}) {
    if (maps.isEmpty) return '';
    final cols = columns ?? {for (final m in maps) ...m.keys}.toList();
    final rows = <List<Object?>>[
      cols,
      for (final m in maps) [for (final col in cols) m[col]],
    ];
    return encode(rows, sep: sep);
  }
}

/// `reader.csv()`: the rows of any [Reader] (`Fs.file`, an http response);
/// `reader.rows()` streams them as they arrive, in constant memory.
extension ReaderCsv on Reader {
  /// Every row, split on [sep] (quotes and CRLF handled); [or] when the
  /// source is missing (a missing file, an HTTP 404 or 410).
  Future<List<List<String>>> csv({String sep = ',', List<List<String>>? or}) =>
      orMissing(this, or, (r) async => CsvUtils.parse(await r.text(), sep: sep));

  /// The CSV rows one at a time as the bytes arrive: a multi-gigabyte
  /// export reads in constant memory. Same rules as [CsvUtils.parse]; decoded
  /// like [text] (a response's charset).
  Stream<List<String>> rows({String sep = ','}) async* {
    final ready = <List<String>>[];
    final rows = _Rows(sep, ready.add);
    final decode = decoders[this];
    final text = decode != null ? decode(stream()) : stream().transform(const Utf8Decoder(allowMalformed: true));
    await for (final chunk in text) {
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
  Future<List<List<String>>> csv({String sep = ',', List<List<String>>? or}) =>
      orMissing(this, or, (r) => r.csv(sep: sep));
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
