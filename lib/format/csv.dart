/// # CSV (`format.csv.*`)
///
/// An RFC 4180 reader and writer with no external dependency: quoted fields,
/// escaped quotes, `\r\n` or `\n` line endings, and a delimiter of any length.
///
/// It is a codec, spelled exactly like [JsonAccessor], [YamlAccessor] and
/// [TomlAccessor] — `parse`, `read`, `format` — and it sat under `io` through
/// 5.1.0 for a historical reason rather than a rule. Rule 1 is explicit that a
/// file format is a *subject*, which is the sentence that admitted
/// `format.zip`, then `format.json`, `yaml`, `toml` and `html`. CSV was the
/// one left outside.
///
/// 4.0.0 and 5.0.0 both deferred the move with the same worry — that splitting
/// `io.csv` would create two spellings for *read a CSV file*. The [Codec] seam
/// 4.0.0 built is what answers it: [read] is inherited from [FileCodec]
/// exactly as the other five inherit it, so there is one spelling, and the
/// streaming members stay in `io.csv` because they are about a file larger
/// than memory rather than about CSV.
///
/// ```dart
/// final parsed = format.csv.parse('a,b\n1,2\n');    // Csv
/// final sheet = await format.csv.read('a.csv');    // free, from FileCodec
/// io.write('out.csv', format.csv.format(sheet.maps.iterable));
///
/// final fetched = res.parse(format.csv);          // and this now works
/// ```
///
/// That last line is the unlock. A crawl that fetches a CSV export had no way
/// to read it through the seam every other format goes through; it is now the
/// same call as `res.parse(format.json)`.
library;

import '../src/csvtext.dart';
import '../util/codec.dart';
import '../util/csv.dart';
import 'format.dart';

// ============================================================================
// CSV (format.csv.*)
// ============================================================================

/// Entry point for CSV, reachable as `format.csv`.
///
/// Reading a file too large to hold is `io.csv.rows` and `io.csv.records`;
/// writing one a row at a time is `io.csv.pipe`. Those are about files, and
/// they stayed where files live.
class CsvAccessor with FileCodec<Csv> implements Codec<Csv> {
  /// Creates the accessor. Prefer the shared `format.csv` instance.
  const CsvAccessor();

  /// Decodes [text] into a [Csv] cursor, the first line naming the columns.
  ///
  /// Handles quoted fields containing [delimiter], newlines and `""` escaped
  /// quotes, and strips the UTF-8 BOM that Excel writes. [delimiter] may be
  /// more than one character. Blank lines produce no row, so a trailing
  /// newline does not add an empty one.
  ///
  /// Text that is not CSV gives the empty cursor rather than throwing, which
  /// is the contract every reader in this library keeps.
  @override
  Csv parse(String text, {String delimiter = ','}) =>
      Csv(text, delimiter: delimiter);

  /// Renders [rows] of records as CSV text, one record per line.
  ///
  /// Columns come from [headers], or from the union of every row's keys in the
  /// order they are first seen — so a field only later records carry still
  /// gets a column instead of being silently dropped.
  ///
  /// [newline] ends every line. The default is `\n`; pass `\r\n` for the line
  /// ending Excel and RFC 4180 expect.
  ///
  /// ```dart
  /// format.csv.format([
  ///   {'name': 'Ada', 'born': 1815},
  ///   {'name': 'Alan', 'born': 1912},
  /// ]);
  /// ```
  ///
  /// For rows that are already lists of cells, see [cells]. They are two
  /// methods and not one taking `Iterable<dynamic>`, because deciding which
  /// shape you were handed at runtime is how a typo becomes an empty file.
  String format(
    Iterable<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) => CsvText.records(
    rows,
    headers: headers,
    delimiter: delimiter,
    newline: newline,
  );

  /// Renders [rows] of cells as CSV text, one row per line.
  ///
  /// The twin of [format] for data that is already a grid — what [Csv.rows]
  /// reads back. [headers] is written as a first line when given.
  ///
  /// ```dart
  /// io.write('out.csv', format.csv.cells([
  ///   ['Ada', 1815],
  ///   ['Alan', 1912],
  /// ], headers: ['name', 'born']));
  /// ```
  ///
  /// Writing it goes through `io.write` rather than a second name here.
  String cells(
    Iterable<List<Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) => CsvText.cells(
    rows,
    headers: headers,
    delimiter: delimiter,
    newline: newline,
  );
}
