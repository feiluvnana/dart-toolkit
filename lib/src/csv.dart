/// # The CSV Cursor (`Csv`)
///
/// What `format.csv.parse` and `format.csv.read` hand back: a table, with its
/// header line separated from its rows.
///
/// It lives in `lib/src/` for the reason [Json] and [Markup] do — it is a
/// pure value that both `format` and `net` hand back, through [Codec], and a
/// type `net` needs cannot live under `format`. It was under `lib/util/`
/// through 5.4.0 and was never reachable as `util.` anything.
///
/// ```dart
/// final sheet = await format.csv.read('sales.csv');
/// sheet.headers;                 // Sequence<String>
/// sheet.maps;                    // Sequence<Map<String, String>>
/// sheet.column('region');        // Sequence<String>
/// ```
///
/// `Table` was the obvious name and `system.console` has it, so this is named
/// for what it is over — exactly as `Json` and `Markup` are.
library;

import '../collection/sequence.dart';
import '../src/csvtext.dart';

// ============================================================================
// THE CSV CURSOR (Csv)
// ============================================================================

/// A parsed CSV table: one header line, then rows.
///
/// The two shapes `io.csv.maps` and `io.csv.matrix` used to be two methods
/// for are two getters here, [maps] and [rows], off one parse — so choosing
/// between them no longer means choosing which method to call before you have
/// seen the file.
///
/// **The first line is the header.** That is what CSV means by convention and
/// what every writer in this library emits; a file genuinely without one
/// gives up its first record to [headers]. For those, [Csv.raw] keeps every
/// line as a row.
final class Csv {
  /// Parses [text] as a table whose first line names the columns.
  factory Csv(String text, {String delimiter = ','}) {
    final parsed = CsvText.parse(text, delimiter: delimiter);
    if (parsed.isEmpty) return const Csv.empty();
    return Csv._(parsed.first, parsed.skip(1).toList());
  }

  /// A table with no header line: every line is a row.
  factory Csv.raw(String text, {String delimiter = ','}) =>
      Csv._(const [], CsvText.parse(text, delimiter: delimiter));

  const Csv._(this._headers, this._rows);

  /// The empty table, which is what text that is not CSV parses to.
  const Csv.empty() : _headers = const [], _rows = const [];

  final List<String> _headers;
  final List<List<String>> _rows;

  /// The column names, from the first line.
  Sequence<String> get headers => Sequence(_headers);

  /// The data rows, as raw cells, header line excluded.
  ///
  /// `io.csv.matrix` included the header line in what it returned; it is
  /// [headers] here, so [rows] and [maps] describe the same records.
  ///
  /// A row is a `List<String>`, not a nested [Sequence]: the cells of one
  /// record are a fixed tuple read by position, so `row[2]` is the question
  /// asked of them and `collect(.at(2))` was the only way to ask it through
  /// 6.2.0. It is also what `io.csv.rows` has always returned — the same
  /// grid, read from a file instead of a string, and the two doors now spell
  /// it the same way.
  Sequence<List<String>> get rows => Sequence(_rows);

  /// The data rows keyed by [headers].
  ///
  /// Blank lines are skipped and short rows are padded with empty strings, so
  /// every map carries every column.
  Sequence<Map<String, String>> get maps => Sequence(
    _rows
        .where((row) => !CsvText.blank(row))
        .map(
          (row) => {
            for (var i = 0; i < _headers.length; i++)
              _headers[i]: i < row.length ? row[i] : '',
          },
        ),
  );

  /// Every value in the column called [name], in row order.
  ///
  /// Empty when there is no such column — the contract every cursor in this
  /// library keeps, because the caller asked for a column and the honest
  /// answer is that there is not one.
  ///
  /// ```dart
  /// // setup: final sheet = format.csv.parse('price\n1.50\n');
  /// final total = sheet
  ///     .column('price')
  ///     .transform(.map((c) => double.tryParse(c) ?? 0))
  ///     .collect(.sum((p) => p));
  /// ```
  Sequence<String> column(String name) {
    final at = _headers.indexOf(name);
    if (at == -1) return const Sequence([]);
    return Sequence(
      _rows
          .where((row) => !CsvText.blank(row))
          .map((row) => at < row.length ? row[at] : ''),
    );
  }

  /// How many data rows there are, header line excluded.
  int get count => _rows.length;

  /// Whether there are no data rows.
  bool get empty => _rows.isEmpty;

  @override
  String toString() => 'Csv(${_headers.length} columns, $count rows)';
}
