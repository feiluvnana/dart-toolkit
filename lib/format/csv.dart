/// # CSV
///
/// An RFC 4180 reader and writer with no external dependency: quoted fields,
/// escaped quotes, `\r\n` or `\n` line endings, and a delimiter of any length.
///
/// It is a codec, spelled exactly like [JsonFormat], [YamlFormat] and
/// [TomlFormat] — `parse` and `format` — and it sat under `io` through
/// 5.1.0 for a historical reason. It is clear that a
/// file format is a *subject*, which is the sentence that admitted
/// archives, then JSON, YAML, TOML and HTML. CSV was the one left outside.
///
/// 4.0.0 and 5.0.0 both deferred the move with the same worry — that splitting
/// A second CSV home would create two spellings for *read a CSV file*. The [DocumentFormat] seam
/// 4.0.0 built is what answers it: [read] is inherited from [DocumentFormat]
/// exactly as the other five inherit it, so there is one spelling, and the
/// streaming members stay in `io/csv.dart` because they are about a file larger
/// than memory rather than about CSV.
///
/// ```dart
/// final parsed = 'a,b\n1,2\n'.parse(.csv);    // Csv
/// final sheet = await Path('a.csv').read(.csv);    // free, from FileFormat
/// Path('out.csv').sync.writeText(const CsvFormat().format(sheet.maps));
///
/// final fetched = res.parse(.csv);          // and this now works
/// ```
///
/// That last line is the unlock. A crawl that fetches a CSV export had no way
/// to read it through the seam every other format goes through; it is now the
/// same call as `res.parse(format.json)`.
/// {@category Formats}
library;

import '../src/csvtext.dart';
import '../src/format.dart';
import '../src/csv.dart';
import 'format.dart';

// ============================================================================
// CSV (format.csv.*)
// ============================================================================

/// The CSV codec. Reach it as `String.parse` or [DocumentFormat.csv].
///
/// Reading a file too large to hold is `Path.csvRows` and `Path.csvRecords`,
/// and writing one a row at a time is `Path.writeCsv`. Those are about
/// files, and they stayed where files live.
class CsvFormat implements DocumentFormat<Csv, Iterable<Map<String, Object?>>> {
  /// Creates the codec. Prefer the shared [DocumentFormat.csv] instance.
  const CsvFormat();

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
  /// const CsvFormat().format([
  ///   {'name': 'Ada', 'born': 1815},
  ///   {'name': 'Alan', 'born': 1912},
  /// ]);
  /// ```
  ///
  /// A native `Iterable`, so what [Csv.maps] and `readCsvRecords` read comes
  /// straight back here.
  ///
  /// For rows that are already lists of cells, see [cells]. They are two
  /// methods and not one taking `Iterable<dynamic>`, because deciding which
  /// shape you were handed at runtime is how a typo becomes an empty file.
  @override
  String format(
    Iterable<Map<String, Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) => CsvText.records(
    rows is List<Map<String, Object?>>
        ? rows
        : rows.cast<Map<String, Object?>>().toList(),
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
  /// Path('out.csv').sync.writeText(const CsvFormat().cells([
  ///   ['Ada', 1815],
  ///   ['Alan', 1912],
  /// ], headers: ['name', 'born']));
  /// ```
  ///
  /// Writing it goes through `Path.writeText` rather than a second name here.
  String cells(
    Iterable<List<Object?>> rows, {
    List<String>? headers,
    String delimiter = ',',
    String newline = '\n',
  }) => CsvText.cells(
    rows is List<List<Object?>> ? rows : rows.cast<List<Object?>>().toList(),
    headers: headers,
    delimiter: delimiter,
    newline: newline,
  );
}
