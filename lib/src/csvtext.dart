/// # CSV Text (internal)
///
/// One RFC 4180 state machine, driven two ways: `format.csv.parse` pushes a
/// whole string through it, `io.csv.rows` pushes a chunk at a time. Plus the
/// two renderers behind `format.csv.format` and `format.csv.cells`.
///
/// There were **two** independent parsers through 5.1.0 — a fast code-unit one
/// for whole files and a character-at-a-time one for streams — which 5.0.0
/// proved agreed on all fifteen awkward inputs it tested. Agreeing was the
/// precondition for merging them, not a substitute for it: two parsers that
/// agree today are two parsers that drift at the next bug fix.
///
/// Not exported: reach these through `format.csv.*` and `io.csv.*`.
library;

// ============================================================================
// CSV TEXT (CsvScanner, CsvText)
// ============================================================================

/// A push parser: feed it text, it hands back complete rows.
///
/// Chunk boundaries are the whole difficulty, and there are three of them. A
/// multi-character delimiter can straddle one. A `"` at the very end of a
/// chunk is ambiguous — the close of a quoted field, or the first half of an
/// escaped `""`. And a `\r` can be separated from its `\n`. Each is handled by
/// holding the undecidable tail back in [_carry] until the next chunk settles
/// it, which is why a single state machine can serve both drivers at all.
class CsvScanner {
  /// Creates a scanner that calls [onRow] with each complete row.
  CsvScanner(this.onRow, {String delimiter = ','})
    : _sep = delimiter.isEmpty ? ',' : delimiter;

  /// Called once per complete row, in order.
  final void Function(List<String> row) onRow;

  final String _sep;
  final StringBuffer _field = StringBuffer();
  final List<String> _row = <String>[];
  String _carry = '';
  bool _quoted = false;
  bool _started = false;

  static const int _quote = 0x22; // "
  static const int _cr = 0x0D;
  static const int _lf = 0x0A;

  /// Feeds the next [chunk] of text.
  void add(String chunk) => _run(_carry + chunk, false);

  /// Feeds the last of the text and flushes the final row.
  void close() {
    _run(_carry, true);
    if (_field.isNotEmpty || _row.isNotEmpty) _endRow();
  }

  void _endField() {
    _row.add(_field.toString());
    _field.clear();
  }

  void _endRow() {
    // A line with nothing on it at all is separation, not an empty record —
    // so a trailing newline does not add a row.
    if (_field.isEmpty && _row.isEmpty) return;
    _endField();
    onRow(List<String>.of(_row));
    _row.clear();
  }

  void _run(String text, bool eof) {
    if (!_started) {
      // Excel writes a UTF-8 BOM. Left in place it glues itself to the first
      // header, where it makes `row['name']` answer null for a file that
      // plainly has a `name` column.
      if (text.startsWith('﻿')) text = text.substring(1);
      if (text.isNotEmpty || eof) _started = true;
    }

    final sep = _sep;
    final sepFirst = sep.codeUnitAt(0);
    final simple = sep.length == 1;
    final length = text.length;
    // Everything from here on could be the first half of a delimiter.
    final limit = eof ? length : length - (sep.length - 1);

    // Code units, not `text[i]`: indexing a String allocates a one-character
    // String per character, which on a 20,000-row export is a million
    // throwaway objects. The plain runs between separators are copied in bulk
    // with `substring` for the same reason.
    var run = 0;
    var i = 0;

    void take(int end) {
      if (end > run) _field.write(text.substring(run, end));
    }

    for (; i < length; i++) {
      final unit = text.codeUnitAt(i);

      if (_quoted) {
        if (unit != _quote) continue;
        if (i + 1 >= length && !eof) {
          // Cannot yet tell a closing quote from the first of an escaped `""`.
          take(i);
          break;
        }
        take(i);
        if (i + 1 < length && text.codeUnitAt(i + 1) == _quote) {
          _field.write('"');
          i++;
        } else {
          _quoted = false;
        }
        run = i + 1;
        continue;
      }

      if (i >= limit) {
        take(i);
        break;
      }

      if (unit == _quote) {
        take(i);
        _quoted = true;
        run = i + 1;
        continue;
      }

      if (unit == _cr || unit == _lf) {
        take(i);
        run = i + 1;
        if (unit == _cr && i + 1 < length && text.codeUnitAt(i + 1) == _lf) {
          i++;
          run = i + 1;
        }
        // A `\r` that ends a chunk emits here, and the `\n` opening the next
        // chunk then hits an empty field and an empty row, which `_endRow`
        // reads as separation and drops. So CRLF needs no held-back tail.
        _endRow();
        continue;
      }

      if (unit == sepFirst && (simple || text.startsWith(sep, i))) {
        take(i);
        i += sep.length - 1;
        run = i + 1;
        _endField();
      }
    }

    if (i >= length) {
      take(length);
      _carry = '';
    } else {
      _carry = text.substring(i);
    }
  }
}

/// Whole-string parsing and rendering, over [CsvScanner].
class CsvText {
  const CsvText._();

  /// Parses [text] into rows of cells, header line included.
  static List<List<String>> parse(String text, {String delimiter = ','}) {
    final rows = <List<String>>[];
    CsvScanner(rows.add, delimiter: delimiter)
      ..add(text)
      ..close();
    return rows;
  }

  /// Renders [rows] of records as CSV text, one record per line.
  ///
  /// Columns come from [headers], or from the union of every row's keys in the
  /// order they are first seen — so a field only later records carry still
  /// gets a column instead of being silently dropped.
  static String records(
    Iterable<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) {
    final list = rows.toList();
    final keys =
        headers ?? <String>{for (final row in list) ...row.keys}.toList();
    if (list.isEmpty && keys.isEmpty) return '';

    final buffer = StringBuffer()
      ..write(keys.map((k) => escape(k, delimiter)).join(delimiter))
      ..write(newline);
    for (final row in list) {
      buffer
        ..write(
          keys
              .map((k) => escape(row[k]?.toString() ?? '', delimiter))
              .join(delimiter),
        )
        ..write(newline);
    }
    return buffer.toString();
  }

  /// Renders [rows] of cells as CSV text, one row per line.
  static String cells(
    Iterable<List<Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) {
    final buffer = StringBuffer();
    if (headers != null && headers.isNotEmpty) {
      buffer
        ..write(headers.map((h) => escape(h, delimiter)).join(delimiter))
        ..write(newline);
    }
    for (final row in rows) {
      buffer
        ..write(
          row
              .map((cell) => escape(cell?.toString() ?? '', delimiter))
              .join(delimiter),
        )
        ..write(newline);
    }
    return buffer.toString();
  }

  /// Whether [row] carries nothing worth keying by a header.
  static bool blank(List<String> row) =>
      row.isEmpty || (row.length == 1 && row.first.trim().isEmpty);

  /// Quotes [field] when it holds a delimiter, a quote or a line break.
  static String escape(String field, String delimiter) =>
      field.contains(delimiter) ||
          field.contains('"') ||
          field.contains('\n') ||
          field.contains('\r')
      ? '"${field.replaceAll('"', '""')}"'
      : field;
}
