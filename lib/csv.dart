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
/// - `reader.csv()` parses any [Reader].
/// Everything else is private.
library;

import 'core.dart';
export 'core.dart';

/// Entry point: parse and encode.
abstract final class Csv {
  /// The rows of [text]. A field is quoted when it holds [sep], a quote or
  /// a newline; a lone trailing newline adds no empty row. Throws
  /// [ContentException] on an unterminated quote.
  static List<List<String>> parse(String text, {String sep = ','}) {
    if (sep.length != 1 || sep == '"' || sep == '\n' || sep == '\r') {
      throw ArgumentError.value(sep, 'sep', 'must be one character other than a quote or a newline');
    }
    final s = sep.codeUnitAt(0);
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var i = text.startsWith('﻿') ? 1 : 0;
    var quoted = false, any = false;
    void endField() {
      row.add(field.toString());
      field.clear();
      any = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    while (i < text.length) {
      final c = text.codeUnitAt(i);
      if (quoted) {
        if (c == 0x22) {
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
            field.writeCharCode(0x22);
            i += 2;
            continue;
          }
          quoted = false;
        } else {
          field.writeCharCode(c);
        }
        i++;
        continue;
      }
      if (c == 0x22 && field.isEmpty && !any) {
        quoted = any = true;
      } else if (c == s) {
        endField();
      } else if (c == 0x0D || c == 0x0A) {
        if (c == 0x0D && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) i++;
        endRow();
      } else {
        field.writeCharCode(c);
        any = true;
      }
      i++;
    }
    if (quoted) throw ContentException('unterminated quoted CSV field', text, i);
    if (field.isNotEmpty || any || row.isNotEmpty) endRow();
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

/// `reader.csv()`: the rows of any [Reader] (`Fs.file`, an http response).
extension ReaderCsv on Reader {
  Future<List<List<String>>> csv({String sep = ','}) async => Csv.parse(await text(), sep: sep);
}

/// The Future mirror (rule 4).
extension ReaderFutureCsv on Future<Reader> {
  Future<List<List<String>>> csv({String sep = ','}) async => (await this).csv(sep: sep);
}
