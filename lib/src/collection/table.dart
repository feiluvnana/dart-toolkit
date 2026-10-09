part of '../../collection.dart';

/// The text formats a [Table] reads and writes. A file's extension names its format: `.json`
/// (an array of objects), `.ndjson`/`.jsonl`, `.tsv`, `.md`/`.markdown`, and CSV for any other.
///
/// {@category Collections}
enum TableFormat {
  csv('CSV'),
  tsv('TSV'),
  json('JSON'),
  ndjson('NDJSON'),
  markdown('Markdown');

  final String _label;

  const TableFormat(this._label);

  static TableFormat _of(String path) => switch (FileBridge.extension(path)) {
    'json' => json,
    'ndjson' || 'jsonl' => ndjson,
    'tsv' => tsv,
    'md' || 'markdown' => markdown,
    _ => csv,
  };

  /// [separator] for this format: CSV's own (`null` to sniff, or `,` when written), TSV's tab;
  /// a separator for any other format is an [ArgumentError].
  String? _separator(String? separator) {
    if (separator == null) return this == tsv ? '\t' : null;
    if (this != csv) throw ArgumentError.value(separator, 'separator', 'Invalid separator: only CSV takes one');
    Table._oneChar(separator);
    return separator;
  }
}

/// What a table's rows share: the columns, where each one is, and where the rows came from.
final class _Schema {
  final List<String> columns;
  final Map<String, int> index;

  /// The file the rows were read from, for a failure.
  final String? source;

  /// The format they were read as, for a failure.
  final TableFormat? format;

  /// The decimal mark of their text.
  final String decimal;

  _Schema(List<String> columns, {this.source, this.format, this.decimal = '.'})
    : columns = List.unmodifiable(columns),
      index = {for (var i = 0; i < columns.length; i++) columns[i]: i};

  /// The same rows' origin over [columns].
  _Schema over(List<String> columns) => _Schema(columns, source: source, format: format, decimal: decimal);

  /// [name], or `Missing column "x" in sales.csv`.
  String has(String name) => index.containsKey(name) ? name : throw MissingException('column "$name"', where: source);

  /// `Invalid CSV in sales.csv, line 4` — `Invalid CSV, line 4` with no file, `Invalid value` with
  /// no format either — for a failure about a cell at [place].
  String invalid(String? place) {
    final label = format?._label ?? 'value';
    final head = source == null ? 'Invalid $label' : 'Invalid $label in $source';
    return place == null ? head : '$head, $place';
  }
}

/// A row that knows its table's [_Schema], so a misspelled column is a [MissingException] and a
/// bad cell names its file and line.
abstract class _SchemaRow extends UnmodifiableMapBase<String, Object?> {
  _Schema get schema;

  /// Where the row is in its file: `line 4`; `null` when nobody knows.
  String? get place;
}

/// A table row: its cells by column name, read typed with [get].
///
/// {@category Collections}
extension type const Row(Map<String, Object?> _map) implements Map<String, Object?> {
  /// The cell in [column] as [T], read as `Env.get` and `Doc.to` read a value: `int`, `double`,
  /// `num` (`'1,200'`, a size `'1.5 GB'`), `bool` (`yes`, `1`), `Duration`, `DateTime` (ISO 8601,
  /// RFC 1123, or [format] such as `'dd/MM/yyyy'`), `Uri`, `Path` or `String`. [decimal] is the
  /// mark of the table's text unless given (`','` for `'1.234,5'`).
  ///
  /// A blank cell is absence: [or], `null` for a nullable [T], else a [MissingException]. A cell
  /// that is there but is not a [T] is a [FormatException] naming the file and line, which [or]
  /// does not answer. A column the row's table does not have is `Missing column "x" in
  /// sales.csv`.
  T get<T>(String column, {T? or, String? format, String? decimal}) {
    final row = _map is _SchemaRow ? _map : null;
    row?.schema.has(column);
    final cell = _map[column];
    if (_blank(cell)) {
      if (or != null) return or;
      if (null is T) return null as T;
      final place = row?.place;
      throw MissingException('"$column"${place == null ? '' : ' on $place'}', where: row?.schema.source);
    }
    if (cell case final T value) return value;
    final mark = decimal ?? row?.schema.decimal ?? '.';
    if (CoerceBridge.coerce<T>(cell, format: format, decimal: mark) case final value?) return value;
    // A European number read with the default mark names the fix.
    final comma = mark == '.' && cell is String ? CoerceBridge.coerce<num>(cell, decimal: ',') : null;
    final hint = comma == null ? '' : "; with decimal: ',' it reads $comma";
    final head = row == null ? 'Invalid value' : row.schema.invalid(row.place);
    throw FormatException('$head: ${_describe(cell)} in "$column", not ${article('$T')}$hint');
  }
}

/// Whether [text]'s first visible character can start a number: a digit, a sign or a mark.
bool _mayBeNumber(String text) {
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) continue;
    return (c >= 0x30 && c <= 0x39) || c == 0x2b || c == 0x2d || c == 0x2e || c == 0x2c;
  }
  return false;
}

/// A cell with nothing in it: absent or blank, so `or` may answer for it.
bool _blank(Object? cell) => cell == null || (cell is String && cell.trim().isEmpty);

/// A cell's own text for an error: quoted when it is text.
String _describe(Object? cell) => cell is String ? '"$cell"' : '$cell';

/// A row the library built, frozen by a view rather than a copy.
final class _TableRow extends _SchemaRow {
  @override
  final _Schema schema;

  final Map<String, Object?> _map;

  _TableRow(this.schema, this._map);

  @override
  String? get place => null;

  @override
  Object? operator [](Object? key) => _map[key];

  @override
  bool containsKey(Object? key) => _map.containsKey(key);

  @override
  int get length => _map.length;

  @override
  Iterable<String> get keys => _map.keys;
}

/// How a group is folded into one value: a column's [sum], [average], [min], [max], [first],
/// [last] or [list], the group's [count], or [Agg.of] a fold of your own. Each is named by its key
/// in `agg`, so one column can be folded twice:
/// `groupBy(['disc']).agg({'size': Agg.sum('bytes'), 'tracks': Agg.count})`.
///
/// `sum`, `average`, `min` and `max` are numbers (`num?`), read with the table's decimal mark; a
/// blank cell is skipped, and a group with no number gives `null` for each.
///
/// {@category Collections}
final class Agg {
  final Object? Function(String column, List<Row> rows) _fold;
  final String _column;
  final String _name;

  const Agg._(this._name, this._column, this._fold);

  /// The group's row count.
  static const count = Agg._('count', '', _count);

  /// [column]'s numbers added up.
  const Agg.sum(String column) : this._('sum', column, _total);

  /// [column]'s numbers' mean.
  const Agg.average(String column) : this._('average', column, _mean);

  /// [column]'s lowest number.
  const Agg.min(String column) : this._('min', column, _lowest);

  /// [column]'s highest number.
  const Agg.max(String column) : this._('max', column, _highest);

  /// [column]'s cell in the group's first row.
  const Agg.first(String column) : this._('first', column, _firstOf);

  /// [column]'s cell in the group's last row.
  const Agg.last(String column) : this._('last', column, _lastOf);

  /// [column]'s cell in every row of the group, in order.
  const Agg.list(String column) : this._('list', column, _listOf);

  /// A fold of your own over the group's rows.
  Agg.of(Object? Function(List<Row> rows) fold) : _name = 'of', _column = '', _fold = ((_, rows) => fold(rows));

  @override
  String toString() => _column.isEmpty ? 'Agg.$_name' : "Agg.$_name('$_column')";
}

int _count(String column, List<Row> rows) => rows.length;
num? _total(String column, List<Row> rows) => _numbers(column, rows)?.$1;
num? _mean(String column, List<Row> rows) => switch (_numbers(column, rows)) {
  (final total, final n) => total / n,
  null => null,
};
num? _lowest(String column, List<Row> rows) => _extreme(column, rows, max: false);
num? _highest(String column, List<Row> rows) => _extreme(column, rows, max: true);
Object? _firstOf(String column, List<Row> rows) => rows.firstOrNull?[column];
Object? _lastOf(String column, List<Row> rows) => rows.lastOrNull?[column];
Object? _listOf(String column, List<Row> rows) => [for (final r in rows) r[column]];

/// The numbers of [column] over [rows], each read as `get<num>` reads it; blank cells skipped.
/// [row]'s [column] as a number, or `null` when blank: a number as it is, text read as every
/// typed reading reads it (a bad one a [FormatException] naming the cell).
num? _numberIn(Row row, String column) {
  final cell = row[column];
  if (cell is num) return cell;
  if (_blank(cell)) return null;
  // Plain decimal text, the common cell, is read here; anything else the general way.
  if (cell is String && !cell.contains('x') && !cell.contains('X')) {
    final decimal = switch (row._map) {
      final _SchemaRow r => r.schema.decimal,
      _ => '.',
    };
    if (decimal == '.') {
      if (num.tryParse(cell) case final n? when n.isFinite) return n;
    }
  }
  return row.get<num>(column);
}

/// [column]'s total and count over [rows], or `null` when no cell holds a number.
(num, int)? _numbers(String column, List<Row> rows) {
  num total = 0;
  var n = 0;
  for (final r in rows) {
    if (_numberIn(r, column) case final x?) {
      total += x;
      n++;
    }
  }
  return n == 0 ? null : (total, n);
}

num? _extreme(String column, List<Row> rows, {required bool max}) {
  num? best;
  for (final r in rows) {
    final x = _numberIn(r, column);
    if (x != null && (best == null || (max ? x > best : x < best))) best = x;
  }
  return best;
}

/// Rows of named columns: a CSV, a JSON array of objects, an HTML `<table>`, a scraped listing.
/// Immutable: every query returns a new table.
///
/// ```dart
/// final t = await Table.read('sales.csv');
/// t.where((r) => r.get<num>('price') > 10).orderBy('price', descending: true).take(10).show();
/// t.groupBy(['region']).agg({'total': Agg.sum('price')});
/// ```
///
/// {@category Collections}
final class Table implements Saveable {
  final _Schema _schema;

  /// Column names, in display order.
  List<String> get columns => _schema.columns;

  /// The rows; a column a row lacks reads `null`.
  List<Row> get rows => _rows ??= _sort(_unsorted!, _order);

  /// `null` until an [orderBy] table is read, so `orderBy(…).take(10)` can select without sorting.
  List<Row>? _rows;

  /// The rows [_order] has not been applied to yet, while [_rows] is `null`.
  final List<Row>? _unsorted;

  final List<(String, bool)> _order;

  Table._(this._schema, List<Row> rows, this._order) : _rows = rows, _unsorted = null;

  /// [rows] in [order], sorted when first read.
  Table._ordered(this._schema, List<Row> rows, this._order) : _unsorted = rows;

  /// A table over [columns] and [rows]; a row missing a column reads `null` there. The rows are
  /// copied, so a later change to them cannot reach the table.
  factory Table(List<String> columns, Iterable<Map<String, Object?>> rows) {
    final schema = _Schema(columns);
    return Table._(schema, [
      for (final r in rows) Row(_TableRow(schema, Map<String, Object?>.unmodifiable(r))),
    ], const []);
  }

  /// A table from maps; the columns are every key seen, in first-seen order.
  factory Table.rows(Iterable<Map<String, Object?>> rows) {
    final list = rows.toList();
    return Table(_columnsOf(list), list);
  }

  /// A table over rows this library just built and nobody else holds: frozen by a view.
  static Table _fresh(_Schema schema, Iterable<Map<String, Object?>> rows) =>
      Table._(schema, [for (final r in rows) Row(_TableRow(schema, r))], const []);

  /// Every key in [rows], in first-seen order.
  static List<String> _columnsOf(List<Map<String, Object?>> rows) => <String>{for (final r in rows) ...r.keys}.toList();

  /// A table from [headers] and positional [rows]; a short row is padded, a long one cut, and a
  /// repeated header becomes `name_2`. A blank header is an [ArgumentError]: a column is read by
  /// its name.
  ///
  /// ```dart
  /// Table.cells(['setting', 'value'], [['workers', 8], ['dry run', false]]).show();
  /// ```
  factory Table.cells(List<String> headers, Iterable<List<Object?>> rows) {
    for (final (i, name) in headers.indexed) {
      if (name.trim().isEmpty) throw ArgumentError('Invalid header at $i: "$name", expected a column name');
    }
    final schema = _Schema(_names(headers));
    final cols = schema.columns;
    return _fresh(schema, [
      for (final row in rows) {for (var i = 0; i < cols.length; i++) cols[i]: i < row.length ? row[i] : null},
    ]);
  }

  /// The table in the file at [path], in the format its extension names (see [TableFormat]):
  /// CSV's [separator] sniffed unless given, [decimal] the mark of its numbers. A file that does
  /// not parse is a [FormatException] naming it and the line; a CSV or TSV that is not UTF-8
  /// reads as Windows-1252, as Excel saves one.
  static Future<Table> read(String path, {String? separator, String decimal = '.'}) {
    final format = TableFormat._of(path);
    final sep = format._separator(separator);
    _decimal(decimal);
    return File(path).readAsBytes().then((bytes) {
      final ansi = format == TableFormat.csv || format == TableFormat.tsv;
      final text = decodeText(bytes, format._label, path, ansi: ansi);
      return parsedText(format._label, path, text, (t) => _parse(t, format, sep, decimal, path));
    });
  }

  /// [text] read as [format]; one that does not parse is a [FormatException] with the line.
  static Table parse(String text, TableFormat format, {String? separator, String decimal = '.'}) {
    final sep = format._separator(separator);
    _decimal(decimal);
    return parsedText(format._label, null, text, (t) => _parse(t, format, sep, decimal, null));
  }

  static void _decimal(String decimal) {
    if (decimal != '.' && decimal != ',') {
      throw ArgumentError.value(decimal, 'decimal', "Invalid decimal mark: '.' or ','");
    }
  }

  static Table _parse(String text, TableFormat format, String? separator, String decimal, String? source) {
    final t = text.startsWith('﻿') ? text.substring(1) : text;
    _Schema schema(List<String> columns) => _Schema(columns, source: source, format: format, decimal: decimal);
    switch (format) {
      case TableFormat.csv || TableFormat.tsv:
        // Cells are kept as offsets into the text and read as they are asked for: a CSV held
        // whole costs its text and a few bytes a cell, not an object per cell.
        final data = _CsvCells.scan(
          t,
          _oneChar(separator ?? _sniffSeparator(t)),
          format._label,
          quotes: format == TableFormat.csv,
        );
        if (data.length == 0) return Table._(schema(const []), const [], const []);
        final header = schema(_names(_RecordCells(data, 0), trailing: true));
        return Table._(header, _CsvRows(data, header), const []);
      case TableFormat.json:
        final items = jsonDecode(t);
        if (items is! List<Object?>) throw FormatException('JSON: ${_kind(items)}, not an array of objects');
        final rows = [
          for (final (i, item) in items.indexed)
            _object(item) ?? (throw FormatException('JSON: element $i is ${_kind(item)}, not an object')),
        ];
        return _fresh(schema(_columnsOf(rows)), rows);
      case TableFormat.ndjson:
        final rows = <Map<String, Object?>>[];
        var line = 0;
        for (final text in t.split('\n')) {
          line++;
          if (_ndjsonRow(text, line) case final row?) rows.add(row);
        }
        return _fresh(schema(_columnsOf(rows)), rows);
      case TableFormat.markdown:
        final (columns, rows) = _markdownRows(t);
        final s = schema(_names(columns));
        return _fresh(s, [
          for (final r in rows) {for (var i = 0; i < s.columns.length; i++) s.columns[i]: i < r.length ? r[i] : null},
        ]);
    }
  }

  /// The rows of the CSV, TSV or NDJSON file at [path], streamed as [read] reads them: for a file
  /// larger than memory, or to stop early. Strict UTF-8; JSON and Markdown, which are not read a
  /// row at a time, are an [ArgumentError].
  static Stream<Row> lines(String path, {String? separator, String decimal = '.'}) {
    final format = TableFormat._of(path);
    if (format == TableFormat.json || format == TableFormat.markdown) {
      throw ArgumentError.value(path, 'path', 'Invalid path: ${format._label} is not read a row at a time');
    }
    final sep = format._separator(separator);
    _decimal(decimal);
    return _lines(path, format, sep, decimal);
  }

  static Stream<Row> _lines(String path, TableFormat format, String? separator, String decimal) async* {
    final reader = _RowReader(path, format, separator, decimal);
    try {
      await for (final piece in File(path).openRead().transform(utf8.decoder)) {
        for (final row in reader.add(piece)) {
          yield row;
        }
      }
    } on FormatException catch (e) {
      if (e.message.startsWith('Invalid ')) rethrow;
      throw FormatException('Invalid ${format._label} in $path: ${e.message}');
    }
    for (final row in reader.close()) {
      yield row;
    }
  }

  /// Where rows streamed into it are written as a file in the format [path]'s extension names,
  /// atomically: the file changes only when the stream is done and [StreamConsumer.close]d, and a
  /// failure leaves the old one. A CSV takes its columns from the first row; a later row with
  /// another key is an [ArgumentError].
  ///
  /// ```dart
  /// await Table.lines('big.csv').where((r) => r.get<num>('price') > 10).pipe(Table.writer('out.csv'));
  /// ```
  static StreamConsumer<Row> writer(String path, {String? separator}) {
    final format = TableFormat._of(path);
    return _TableWriter(path, format, format._separator(separator) ?? ',');
  }

  /// A decoded JSON object as a row, or `null` for anything else.
  static Map<String, Object?>? _object(Object? item) => switch (item) {
    final Map<String, Object?> m => m,
    final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': e.value},
    _ => null,
  };

  /// One NDJSON line's object; `null` for a blank line; anything else names [line].
  static Map<String, Object?>? _ndjsonRow(String text, int line) {
    if (text.trim().isEmpty) return null;
    final Object? item;
    try {
      item = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('NDJSON line $line: ${e.message}');
    }
    return _object(item) ?? (throw FormatException('NDJSON line $line: ${_kind(item)}, not an object'));
  }

  static String _kind(Object? v) => switch (v) {
    null => 'null',
    String() => 'a string',
    num() => 'a number',
    bool() => 'a bool',
    List() => 'an array',
    _ => 'an object',
  };

  /// Sniffs the separator from CSV text, trying `,`, `;`, `\t`, `|`.
  static String _sniffSeparator(String text) {
    // Five lines are enough, so they are found one break at a time rather than splitting the text.
    final lines = <String>[];
    for (var at = 0; at < text.length && lines.length < 5;) {
      var end = text.indexOf('\n', at);
      if (end < 0) end = text.length;
      final line = text.substring(at, end).trim();
      if (line.isNotEmpty) lines.add(line);
      at = end + 1;
    }
    if (lines.isEmpty) return ',';
    const candidates = [',', ';', '\t', '|'];
    String? best;
    var most = 0;
    for (final cand in candidates) {
      final counts = [for (final l in lines) cand.allMatches(l).length];
      if (counts.first > most && counts.every((c) => c == counts.first)) (best, most) = (cand, counts.first);
    }
    if (best != null) return best;
    for (final cand in candidates) {
      final c = cand.allMatches(lines.first).length;
      if (c > most) (best, most) = (cand, c);
    }
    return best ?? ',';
  }

  /// The separator's code unit; a longer one would silently match on its first character.
  static int _oneChar(String separator) => separator.length == 1
      ? separator.codeUnitAt(0)
      : throw ArgumentError.value(separator, 'separator', 'Invalid separator: exactly one character');

  int get length => _sourceRows.length;
  bool get isEmpty => _sourceRows.isEmpty;
  bool get isNotEmpty => _sourceRows.isNotEmpty;

  /// Every cell of [column] as [T], top to bottom, read as [Row.get] reads it: `values<num>('price')`;
  /// `values<num?>` for a column with blanks.
  List<T> values<T>(String column, {String? format}) {
    final c = _schema.has(column);
    return [for (final r in rows) r.get<T>(c, format: format)];
  }

  // ---- queries

  /// Only the rows that pass [test].
  Table where(bool Function(Row row) test) {
    if (_unsorted case final unsorted?) return Table._ordered(_schema, unsorted.where(test).toList(), _order);
    return Table._(_schema, rows.where(test).toList(), _order);
  }

  /// The first [count] rows. Straight after [orderBy], only those [count] are sorted.
  Table take(int count) => Table._(_schema, _top(count), _order);

  /// The first [count] rows in order, selected rather than sorted when not sorted yet.
  List<Row> _top(int count) {
    RangeError.checkNotNegative(count, 'count');
    final unsorted = _unsorted;
    if (_rows != null || unsorted == null || count >= unsorted.length ~/ 8) return rows.take(count).toList();
    if (count == 0) return const [];
    final keys = _keys(unsorted, _order, _schema.decimal);
    return [for (final i in _smallest(unsorted.length, count, (x, y) => _compareAt(keys, _order, x, y))) unsorted[i]];
  }

  /// All but the first [count] rows.
  Table skip(int count) {
    RangeError.checkNotNegative(count, 'count');
    return Table._(_schema, rows.skip(count).toList(), _order);
  }

  /// Sorted by [column], largest first when [descending]: numbers (read with the table's decimal
  /// mark) as numbers, text in natural order (`Track 2` before `Track 10`), blank cells last. The
  /// sort runs when the rows are first read, so `orderBy(…).take(n)` sorts only `n`.
  Table orderBy(String column, {bool descending = false}) =>
      Table._ordered(_schema, _sourceRows, [(_schema.has(column), descending)]);

  /// The next sort key, where [orderBy]'s tie.
  Table thenBy(String column, {bool descending = false}) =>
      Table._ordered(_schema, _sourceRows, [..._order, (_schema.has(column), descending)]);

  /// The rows a new order applies to: unsorted when this table's order has not run (it is replaced).
  List<Row> get _sourceRows => _unsorted ?? rows;

  /// Each sort column pulled and coerced once per row, not once per comparison.
  static List<List<_Cell>> _keys(List<Row> rows, List<(String, bool)> order, String decimal) => [
    for (final (col, _) in order) [for (final r in rows) _cell(r[col], decimal)],
  ];

  /// Rows [x] and [y] by [order]. The position is the last tie-break, so the order is stable.
  static int _compareAt(List<List<_Cell>> keys, List<(String, bool)> order, int x, int y) {
    for (var k = 0; k < order.length; k++) {
      final a = keys[k][x], b = keys[k][y];
      // An empty cell is missing data: last in either direction.
      if (a.$2 == null || b.$2 == null) {
        if (a.$2 == null && b.$2 == null) continue;
        return a.$2 == null ? 1 : -1;
      }
      final c = _compare(a, b);
      if (c != 0) return order[k].$2 ? -c : c;
    }
    return x.compareTo(y);
  }

  List<Row> _sort(List<Row> rows, List<(String, bool)> order) {
    if (order.isEmpty) return rows;
    final keys = _keys(rows, order, _schema.decimal);
    final positions = [for (var i = 0; i < rows.length; i++) i]..sort((x, y) => _compareAt(keys, order, x, y));
    return List.unmodifiable([for (final i in positions) rows[i]]);
  }

  /// Only [names], in that order.
  Table select(List<String> names) {
    names.forEach(_schema.has);
    final schema = _schema.over(names);
    return Table._(schema, [
      for (final r in rows) Row(_TableRow(schema, {for (final n in names) n: r[n]})),
    ], _orderWhile(names.contains));
  }

  /// Every column but [names]; an unknown name is a [MissingException], as in [select].
  Table drop(List<String> names) {
    names.forEach(_schema.has);
    final dropped = names.toSet();
    return select([
      for (final c in columns)
        if (!dropped.contains(c)) c,
    ]);
  }

  /// Columns renamed by [names], old to new. A rename that leaves two columns one name is an
  /// [ArgumentError].
  Table rename(Map<String, String> names) {
    names.keys.forEach(_schema.has);
    final renamed = [for (final c in columns) names[c] ?? c];
    if (renamed.toSet().length != renamed.length) {
      throw ArgumentError.value(names, 'names', 'Invalid rename: it leaves two columns named alike in $renamed');
    }
    final schema = _schema.over(renamed);
    return Table._(
      schema,
      [
        for (final r in rows)
          Row(_TableRow(schema, {for (final MapEntry(:key, :value) in r.entries) names[key] ?? key: value})),
      ],
      [for (final (col, desc) in _order) (names[col] ?? col, desc)],
    );
  }

  /// A new column [name] computed from each row, last; an existing [name] is replaced in place,
  /// so `t.derive('size', (r) => r.get<int>('size').humanBytes)` formats a column.
  Table derive(String name, Object? Function(Row row) value) {
    final schema = columns.contains(name) ? _schema : _schema.over([...columns, name]);
    return Table._(schema, [
      for (final r in rows) Row(_TableRow(schema, {...r, name: value(r)})),
    ], _orderWhile((c) => c != name));
  }

  /// [_order] up to its first key not [kept]: a later key only breaks that one's ties, and a
  /// stale key would re-sort rows that are already in order.
  List<(String, bool)> _orderWhile(bool Function(String column) kept) => [..._order.takeWhile((o) => kept(o.$1))];

  /// One row per distinct combination of [by] (every column when omitted); the first wins. Cells
  /// compare by value: `'1'` and `1` are one.
  Table distinct([List<String>? by]) {
    final keys = by?.map(_schema.has).toList() ?? columns;
    final seen = <_Key>{};
    return Table._(_schema, [
      for (final r in rows)
        if (seen.add(_keyOf(r, keys))) r,
    ], _order);
  }

  /// The rows matched by [on] in both tables, each with [other]'s columns beside its own; a
  /// column both have, other than [on], arrives from [other] as `name_2`. Keys compare by value:
  /// `'1'` matches `1`; a blank key matches nothing. For keys named apart, rename one first:
  /// `orders.join(users.rename({'id': 'user_id'}), on: 'user_id')`.
  Table join(Table other, {required String on}) => _join(other, on, left: false);

  /// [join], keeping every row here: [other]'s columns are `null` where nothing matched.
  Table leftJoin(Table other, {required String on}) => _join(other, on, left: true);

  Table _join(Table other, String on, {required bool left}) {
    _schema.has(on);
    other._schema.has(on);
    final index = <_Key, List<Row>>{};
    for (final r in other.rows) {
      final k = _keyOf(r, [on]);
      if (k.parts.first != null) (index[k] ??= []).add(r);
    }
    final seen = {...columns};
    final rightColumns = <String, String>{
      for (final c in other.columns)
        if (c != on) c: seen.add(c) ? c : _unused(c, seen),
    };
    final schema = _schema.over([...columns, ...rightColumns.values]);
    final out = <Row>[];
    for (final r in rows) {
      final k = _keyOf(r, [on]);
      final matches = k.parts.first == null ? null : index[k];
      if (matches == null) {
        if (left) out.add(Row(_TableRow(schema, {...r, for (final c in rightColumns.values) c: null})));
        continue;
      }
      for (final m in matches) {
        out.add(
          Row(_TableRow(schema, {...r, for (final MapEntry(:key, :value) in rightColumns.entries) value: m[key]})),
        );
      }
    }
    return Table._(schema, out, const []);
  }

  /// Rows grouped by the cells of [columns], compared by value, ready for [TableGroups.agg].
  TableGroups groupBy(List<String> columns) {
    if (columns.isEmpty) throw ArgumentError.value(columns, 'columns', 'Invalid grouping: no column');
    return TableGroups._(this, [for (final c in columns) _schema.has(c)]);
  }

  /// A crosstab: one row per [rows] cell, one column per [column] cell (a blank one is
  /// `(blank)`), each cell its rows folded by [value]:
  /// `pivot(rows: 'artist', column: 'year', value: Agg.sum('plays'))`. Cells compare by value.
  Table pivot({required String rows, required String column, required Agg value}) {
    [rows, column, if (value._column.isNotEmpty) value._column].forEach(_schema.has);
    // A value named like the [rows] column gets `name_2`, so it does not overwrite the key.
    final seen = {rows};
    final names = <_Key, String>{};
    final groups = <_Key, (Object?, Map<_Key, List<Row>>)>{};
    for (final r in this.rows) {
      final c = _keyOf(r, [column]);
      names.putIfAbsent(c, () {
        final cell = r[column];
        final name = _blank(cell) ? '(blank)' : _written(cell);
        return seen.add(name) ? name : _unused(name, seen);
      });
      final group = groups.putIfAbsent(_keyOf(r, [rows]), () => (r[rows], {}));
      (group.$2[c] ??= []).add(r);
    }
    final schema = _schema.over([rows, ...names.values]);
    return Table._(schema, [
      for (final (key, byColumn) in groups.values)
        Row(
          _TableRow(schema, {
            rows: key,
            for (final MapEntry(key: c, value: name) in names.entries)
              name: value._fold(value._column, byColumn[c] ?? const <Row>[]),
          }),
        ),
    ], const []);
  }

  /// The key of [r] over [columns], each cell compared by value.
  _Key _keyOf(Row r, List<String> columns) => _Key([for (final c in columns) _valueOf(r[c], _schema.decimal)]);

  // ---- writing

  /// This table as [format]'s text: CSV and TSV with a header row (CSV's [separator] `,` unless
  /// given), JSON an indented array of objects, NDJSON one object a line, Markdown with numbers
  /// right-aligned. A [DateTime] is written in ISO 8601. TSV has no quoting, so a tab or line
  /// break in a cell is a [FormatException] naming it.
  String encode(TableFormat format, {String? separator}) => _pieces(format, format._separator(separator) ?? ',').join();

  /// [format]'s text in pieces of about 1 MiB: what [encode] joins and [save] writes as it goes.
  Iterable<String> _pieces(TableFormat format, String separator) sync* {
    final sb = StringBuffer();
    switch (format) {
      case TableFormat.csv || TableFormat.tsv:
        final tsv = format == TableFormat.tsv;
        _csvLine(sb, columns, separator, tsv: tsv ? (i) => 'the header' : null);
        for (final (n, r) in rows.indexed) {
          _csvLine(
            sb,
            [for (final c in columns) _written(r[c])],
            separator,
            tsv: tsv ? (i) => 'row ${n + 1}, column "${columns[i]}"' : null,
          );
          if (sb.length >= 1 << 20) {
            yield sb.toString();
            sb.clear();
          }
        }
      case TableFormat.ndjson:
        for (final o in _objects) {
          sb
            ..write(_json(o))
            ..write('\n');
          if (sb.length >= 1 << 20) {
            yield sb.toString();
            sb.clear();
          }
        }
      case TableFormat.json:
        sb
          ..write(_json(toJson(), indent: '  '))
          ..write('\n');
      case TableFormat.markdown:
        sb.write(_markdown());
    }
    yield sb.toString();
  }

  /// Writes this table to [to] in the format its extension names (see [TableFormat]),
  /// atomically, into a folder that exists; a file there is replaced unless [conflict] says
  /// otherwise.
  @override
  Task<Path> save(String to, {Conflict conflict = Conflict.overwrite, String? separator}) {
    final format = TableFormat._of(to);
    final sep = format._separator(separator) ?? ',';
    return FileBridge.save(to, conflict, 'Table', () => _pieces(format, sep).map(utf8.encode));
  }

  /// The rows as JSON-ready maps over [columns] (a [DateTime] as ISO 8601), so `jsonEncode(table)`
  /// writes it.
  List<Map<String, Object?>> toJson() => [
    for (final o in _objects)
      {for (final MapEntry(:key, :value) in o.entries) key: value is DateTime ? value.toIso8601String() : value},
  ];

  /// Each row keyed by exactly [columns], so a written file reads back as this table.
  Iterable<Map<String, Object?>> get _objects => rows.map((r) => {for (final c in columns) c: r[c]});

  /// Whether every value of [column] is a number or blank, in a table with rows.
  bool _numeric(String column) {
    if (rows.isEmpty) return false;
    final decimal = _schema.decimal;
    return rows.every((r) => _blank(r[column]) || CoerceBridge.coerce<num>(r[column], decimal: decimal) != null);
  }

  String _markdown() {
    String cell(Object? v) => _written(v).replaceAll('|', r'\|').replaceAll('\n', '⏎').replaceAll('\r', '');
    final sb = StringBuffer()
      ..writeln('| ${columns.map(cell).join(' | ')} |')
      ..writeln('| ${[for (final c in columns) _numeric(c) ? '---:' : '---'].join(' | ')} |');
    for (final r in rows) {
      sb.writeln('| ${columns.map((c) => cell(r[c])).join(' | ')} |');
    }
    return sb.toString();
  }

  /// This table drawn as text, one line a row, under a header and inside [border] (the console
  /// theme's unless given; [Border.none] draws only aligned columns). [align] places a column by
  /// name; one it leaves out is right-aligned when every cell in it is a number. [cell] writes a
  /// cell's text (default: the value, a blank one empty); a line break in a cell is `⏎`. Given a
  /// [width], the widest columns shrink to fit it, their cells cut with `…`.
  String render({
    int? width,
    Border? border,
    Map<String, Align> align = const {},
    String Function(Row row, String column)? cell,
  }) {
    final b = border ?? IoBridge.border?.call() ?? const Border();
    align.keys.forEach(_schema.has);
    final grid = [
      for (final r in rows)
        [for (final c in columns) (cell?.call(r, c) ?? _written(r[c])).replaceAll('\n', '⏎').replaceAll('\r', '⏎')],
    ];
    final widths = [for (final h in columns) TextBridge.width(h)];
    for (final row in grid) {
      for (var i = 0; i < columns.length; i++) {
        widths[i] = max(widths[i], TextBridge.width(row[i]));
      }
    }
    // A cell takes its width and a space each side; the borders between and around take one.
    if (width != null) {
      var over = widths.fold(0, (a, w) => a + w + 3) + 1 - width;
      while (over > 0) {
        var widest = 0;
        for (var i = 1; i < widths.length; i++) {
          if (widths[i] > widths[widest]) widest = i;
        }
        if (widths[widest] <= 3) break;
        widths[widest]--;
        over--;
      }
    }
    final aligns = [for (final c in columns) align[c] ?? (_numeric(c) ? Align.right : Align.left)];
    String padded(String text, int i) =>
        TextBridge.pad(TextBridge.truncate(text, widths[i]), widths[i], align: aligns[i]);

    final out = StringBuffer();
    void divider(String left, String cross, String right) {
      if (b.top.isNotEmpty && '$left$cross$right'.trim().isNotEmpty) {
        out.writeln('$left${widths.map((w) => b.top * (w + 2)).join(cross)}$right');
      }
    }

    void line(List<String> row) {
      final side = b.side.isEmpty ? ' ' : b.side;
      final text = '$side${[for (var i = 0; i < columns.length; i++) ' ${padded(row[i], i)} '].join(side)}$side';
      out.writeln(side == ' ' ? text.trimRight() : text);
    }

    divider(b.topLeft, b.topTee, b.topRight);
    if (columns.isNotEmpty) {
      line(columns);
      divider(b.leftTee, b.cross, b.rightTee);
    }
    grid.forEach(line);
    divider(b.bottomLeft, b.bottomTee, b.bottomRight);
    return out.toString();
  }

  /// Prints [render] on `Io.stdout`, fitted to the terminal's width (piped, written whole), above
  /// a live display when one is drawing.
  Future<void> show({
    Border? border,
    Map<String, Align> align = const {},
    String Function(Row row, String column)? cell,
  }) async {
    final text = render(width: Io.columns, border: border, align: align, cell: cell);
    void write() => Io.stdout.write(text);
    if (IoBridge.above case final above?) {
      above(write);
    } else {
      write();
    }
  }

  @override
  String toString() => 'Table(${columns.length} columns, $length rows)';
}

/// The groups of a [Table.groupBy]; [agg] folds each into one row.
///
/// {@category Collections}
final class TableGroups {
  final Table _table;
  final List<String> _keys;

  /// Each group's first cells (its key as written) and its rows.
  final Map<_Key, (List<Object?>, List<Row>)> _groups = {};

  TableGroups._(this._table, this._keys) {
    for (final r in _table.rows) {
      _groups.putIfAbsent(_table._keyOf(r, _keys), () => ([for (final k in _keys) r[k]], [])).$2.add(r);
    }
  }

  /// The keys and one column per entry of [aggregates], named by its key and folded by its [Agg]:
  /// `groupBy(['disc']).agg({'size': Agg.sum('bytes'), 'tracks': Agg.count})`.
  Table agg(Map<String, Agg> aggregates) {
    for (final how in aggregates.values) {
      if (how._column.isNotEmpty) _table._schema.has(how._column);
    }
    final schema = _table._schema.over([..._keys, ...aggregates.keys]);
    return Table._(schema, [
      for (final (key, rows) in _groups.values)
        Row(
          _TableRow(schema, {
            for (var i = 0; i < _keys.length; i++) _keys[i]: key[i],
            for (final MapEntry(key: name, value: how) in aggregates.entries) name: how._fold(how._column, rows),
          }),
        ),
    ], const []);
  }
}

/// [v] as a key compares it: a number by value (`'1'`, `1` and `1.0` are one, read with
/// [decimal]), blank as `null`, anything else as itself.
Object? _valueOf(Object? v, String decimal) {
  if (v == null || v is String && v.trim().isEmpty) return null;
  // Text that cannot start a number ('Cat0') is a key as it is, without the full reading.
  if (v is String && !_mayBeNumber(v)) return v;
  final n = v is num ? v : (v is String ? CoerceBridge.coerce<num>(v, decimal: decimal) : null);
  if (n == null) return v;
  return n is double && n.isFinite && n == n.truncateToDouble() && n.abs() < 9007199254740992 ? n.toInt() : n;
}

/// A group key: a list of cell values compared by value.
final class _Key {
  final List<Object?> parts;
  _Key(this.parts);

  @override
  bool operator ==(Object other) {
    if (other is! _Key || other.parts.length != parts.length) return false;
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] != other.parts[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(parts);
}

/// A cell prepared for comparison: the number it coerces to, if any, and the cell. Coercion is
/// the expensive half, so a sort does it once per row up front.
typedef _Cell = (num? number, Object? value);

/// [value] as it sorts: a number (read with [decimal]), else text as its natural key, else itself.
_Cell _cell(Object? value, String decimal) {
  if (value is String) {
    if (value.trim().isEmpty) return (null, null);
    final n = CoerceBridge.coerce<num>(value, decimal: decimal);
    return (n, n ?? CoerceBridge.naturalKey(value));
  }
  return (value is num ? value : null, value);
}

/// Cells in sort order: numbers as numbers, then like-typed comparables (text in natural order),
/// then as text. `null` sorts last.
int _compare(_Cell a, _Cell b) {
  final (na, va) = a;
  final (nb, vb) = b;
  if (va == null) return vb == null ? 0 : 1;
  if (vb == null) return -1;
  if (na != null || nb != null) {
    return na == null
        ? 1
        : nb == null
        ? -1
        : na.compareTo(nb);
  }
  if (va is Comparable && vb is Comparable && va.runtimeType == vb.runtimeType) return va.compareTo(vb);
  return '$va'.compareTo('$vb');
}

/// Column names from a header: trimmed, a blank one `c<n>` by its place, a repeated one
/// `name_2`; with [trailing], a blank last one (a trailing separator) is dropped.
List<String> _names(List<String> headers, {bool trailing = false}) {
  var trimmed = [for (final name in headers) name.trim()];
  if (trailing && trimmed.length > 1 && trimmed.last.isEmpty) trimmed = trimmed.sublist(0, trimmed.length - 1);
  final seen = <String>{};
  return [
    for (final (i, name) in trimmed.indexed)
      if (name.isEmpty ? 'c${i + 1}' : name case final n) seen.add(n) ? n : _unused(n, seen),
  ];
}

/// `name_2`, or the first `name_n` that [seen] does not have yet, added to it.
String _unused(String name, Set<String> seen) {
  for (var n = 2; ; n++) {
    if (seen.add('${name}_$n')) return '${name}_$n';
  }
}

/// A CSV row: the header's index over the record's cells, read from the table's [_CsvCells]
/// as asked for, or a streamed row's own [_cells]. A short record reads `null` past its end; a
/// long one is cut at the header.
final class _CsvRow extends _SchemaRow {
  @override
  final _Schema schema;

  /// A streamed row's cells; `null` for a row of a table read whole.
  final List<String>? _cells;

  /// The cells of the table read whole, which also give the line a failure names.
  final _CsvCells? _data;

  /// The record's place: its index in [_data], or the data row's number when streamed.
  final int _record;

  _CsvRow.read(this.schema, _CsvCells this._data, this._record) : _cells = null;

  _CsvRow.streamed(this.schema, List<String> this._cells, this._record) : _data = null;

  @override
  String get place => switch (_data) {
    final data? => 'line ${data.lineOf(_record)}',
    null => 'row $_record',
  };

  @override
  Object? operator [](Object? key) {
    final i = schema.index[key];
    if (i == null) return null;
    if (_data case final data?) return i < data.count(_record) ? data.cell(_record, i) : null;
    final cells = _cells!;
    return i < cells.length ? cells[i] : null;
  }

  @override
  bool containsKey(Object? key) => schema.index.containsKey(key);

  @override
  int get length => schema.columns.length;

  @override
  Iterable<String> get keys => schema.columns;
}

/// The cells of a CSV or TSV text, held as offsets: two per cell (its start and end in [text]),
/// where each record's cells begin, and where in [text] it starts. A cell that had to be rebuilt —
/// a doubled quote, text after a closing quote — is in [_rebuilt], its start `-1 - its index`.
final class _CsvCells {
  final String text;
  final Int32List _cells;
  final Int32List _records;
  final Int32List _starts;
  final List<String> _rebuilt;

  /// Where the text not yet read starts: [text]'s length unless the scan was not `done`.
  final int end;

  _CsvCells._(this.text, this._cells, this._records, this._starts, this._rebuilt, this.end);

  /// Records in all, the header included.
  int get length => _records.length - 1;

  /// Cells in record [r].
  int count(int r) => _records[r + 1] - _records[r];

  /// Cell [c] of record [r].
  String cell(int r, int c) {
    final k = (_records[r] + c) * 2;
    final start = _cells[k];
    return start < 0 ? _rebuilt[-1 - start] : text.substring(start, _cells[k + 1]);
  }

  /// The line of [text] record [r] starts on, from 1: counted only when a failure asks.
  int lineOf(int r) => _lineAt(text, _starts[r]);

  /// [text] scanned into records, cells kept as offsets: RFC 4180 with [quotes] (CSV), split at
  /// [sep] and line breaks alone without (TSV, which has no quoting). Unless [done], [text] is a
  /// prefix: a record that may continue is left unread, from [end]. A quote still open when
  /// [done] is a [FormatException] `<label> line n: …`.
  factory _CsvCells.scan(String text, int sep, String label, {bool quotes = true, bool done = true}) {
    var cells = Int32List(1024);
    var used = 0;
    final records = <int>[0];
    final starts = <int>[];
    final rebuilt = <String>[];
    var count = 0; // cells so far, over every record
    var i = 0;
    final n = text.length;
    void add(int start, int end) {
      if (used + 2 > cells.length) {
        // Grown to what the text read so far predicts for the whole, so the buffer kept is
        // little more than its cells, rather than up to twice them.
        final predicted = (used * (n / (i < 1 ? 1 : i)) * 1.05).ceil() + 64;
        cells = Int32List(max(predicted, cells.length * 3 ~/ 2))..setRange(0, used, cells);
      }
      cells[used++] = start;
      cells[used++] = end;
      count++;
    }

    _CsvCells result(int end) => _CsvCells._(
      text,
      Int32List.sublistView(cells, 0, used),
      Int32List.fromList(records),
      Int32List.fromList(starts),
      rebuilt,
      end,
    );

    bool stop(int c) => c == sep || c == 0x0a || c == 0x0d;
    while (i < n) {
      final first = count;
      final from = i;
      final kept = rebuilt.length;
      // The record may continue past what has arrived: forget its cells and resume at it.
      _CsvCells partial() {
        used = first * 2;
        count = first;
        rebuilt.length = kept;
        return result(from);
      }

      // Whether the record's first cell was quoted: `""` is a value, an empty line is not.
      final quoted = quotes && text.codeUnitAt(i) == 0x22;
      while (true) {
        if (quotes && i < n && text.codeUnitAt(i) == 0x22) {
          StringBuffer? cell;
          var s = i + 1;
          var q = s;
          while (true) {
            q = text.indexOf('"', s);
            // An open quote at the end, or one that may be the first of a doubled pair.
            if (!done && (q < 0 || q + 1 == n)) return partial();
            if (q < 0) throw FormatException('$label line ${_lineAt(text, i)}: the quote opened here is never closed');
            if (q + 1 < n && text.codeUnitAt(q + 1) == 0x22) {
              (cell ??= StringBuffer()).write(text.substring(s, q + 1));
              s = q + 2;
              continue;
            }
            i = q + 1;
            break;
          }
          // Anything between the closing quote and the separator is kept as it stands.
          final rest = i;
          while (i < n && !stop(text.codeUnitAt(i))) {
            i++;
          }
          if (cell == null && rest == i) {
            add(s, q);
          } else {
            rebuilt.add(
              ((cell ?? StringBuffer())
                    ..write(text.substring(s, q))
                    ..write(text.substring(rest, i)))
                  .toString(),
            );
            add(-rebuilt.length, 0);
          }
        } else {
          final s = i;
          while (i < n && !stop(text.codeUnitAt(i))) {
            i++;
          }
          add(s, i);
        }
        if (i >= n && !done) return partial();
        if (i < n) {
          final c = text.codeUnitAt(i++);
          if (c == sep) continue;
          if (c == 0x0d) {
            if (i < n && text.codeUnitAt(i) == 0x0a) {
              i++;
            } else if (i >= n && !done) {
              return partial(); // a CR whose LF has not arrived
            }
          }
        }
        // A blank line is no record: one empty cell, unquoted.
        final blank = !quoted && count - first == 1 && cells[used - 2] >= 0 && cells[used - 2] == cells[used - 1];
        if (blank) {
          used -= 2;
          count--;
        } else {
          records.add(count);
          starts.add(from);
        }
        break;
      }
    }
    return result(n);
  }
}

/// The line of [text] that offset [at] is on, from 1.
int _lineAt(String text, int at) {
  var line = 1;
  for (var i = text.indexOf('\n'); i != -1 && i < at; i = text.indexOf('\n', i + 1)) {
    line++;
  }
  return line;
}

/// A record's cells, read from [_CsvCells] as they are asked for.
final class _RecordCells extends ListBase<String> {
  final _CsvCells _data;
  final int _record;

  _RecordCells(this._data, this._record);

  @override
  int get length => _data.count(_record);

  @override
  String operator [](int index) => _data.cell(_record, index);

  @override
  set length(int _) => throw UnsupportedError('Cannot change a CSV record');

  @override
  void operator []=(int index, String value) => throw UnsupportedError('Cannot change a CSV record');
}

/// A CSV's data rows, each a view made when first read and then kept, so a row is one object.
final class _CsvRows extends ListBase<Row> {
  final _CsvCells _data;
  final _Schema _schema;
  final List<Row?> _made;

  _CsvRows(this._data, this._schema) : _made = List.filled(_data.length - 1, null);

  @override
  int get length => _made.length;

  @override
  Row operator [](int index) => _made[index] ??= Row(_CsvRow.read(_schema, _data, index + 1));

  @override
  set length(int _) => throw UnsupportedError("Cannot change a table's rows");

  @override
  void operator []=(int index, Row value) => throw UnsupportedError("Cannot change a table's rows");
}

/// The header and rows of a Markdown table: `| a | b |`, then `| --- | ---: |`, then a line a
/// row; the outer pipes are optional and `\|` is a pipe in a cell.
(List<String>, List<List<String>>) _markdownRows(String text) {
  final lines = <(int, String)>[
    for (final (i, line) in text.split('\n').indexed)
      if (line.trim().isNotEmpty) (i + 1, line.trim()),
  ];
  if (lines.isEmpty) return (const [], const []);
  List<String> cells(String line) {
    var s = line;
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
    final out = <String>[];
    final cell = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (s[i] == r'\' && i + 1 < s.length && s[i + 1] == '|') {
        cell.write('|');
        i++;
      } else if (s[i] == '|') {
        out.add(cell.toString().trim());
        cell.clear();
      } else {
        cell.write(s[i]);
      }
    }
    return out..add(cell.toString().trim());
  }

  if (lines.length < 2 || !cells(lines[1].$2).every((c) => RegExp(r'^:?-+:?$').hasMatch(c))) {
    throw FormatException(
      'Markdown line ${lines.length < 2 ? lines[0].$1 + 1 : lines[1].$1}: expected the | --- | row under the header',
    );
  }
  return (cells(lines[0].$2), [for (final (_, line) in lines.skip(2)) cells(line)]);
}

/// [cells] as one CSV line in [sb]: a field is quoted when it holds the separator, a quote or a
/// line break, and a row of one empty cell is `""` so it reads back. With [tsv] (which names a
/// cell's place) it is a TSV line, which has no quoting: a tab or line break in a cell is a
/// [FormatException].
void _csvLine(StringBuffer sb, List<String> cells, String separator, {String Function(int cell)? tsv}) {
  final start = sb.length;
  for (var i = 0; i < cells.length; i++) {
    if (i > 0) sb.write(separator);
    final s = cells[i];
    if (tsv != null) {
      if (s.contains('\t') || s.contains('\n') || s.contains('\r')) {
        throw FormatException('Invalid TSV at ${tsv(i)}: a tab or line break has no TSV form');
      }
      sb.write(s);
      continue;
    }
    final quote = s.contains(separator) || s.contains('"') || s.contains('\n') || s.contains('\r');
    sb.write(quote ? '"${s.replaceAll('"', '""')}"' : s);
  }
  if (sb.length == start && tsv == null) sb.write('""');
  sb.write('\n');
}

/// The positions of the [count] smallest of `0 … n-1` by [compare], in order, via a max-heap of
/// the best so far: O(n log count).
List<int> _smallest(int n, int count, int Function(int x, int y) compare) {
  if (count <= 0) return const [];
  final heap = <int>[];
  void swap(int a, int b) {
    final t = heap[a];
    heap[a] = heap[b];
    heap[b] = t;
  }

  for (var i = 0; i < n; i++) {
    if (heap.length < count) {
      heap.add(i);
      for (var c = heap.length - 1; c > 0 && compare(heap[c], heap[(c - 1) ~/ 2]) > 0; c = (c - 1) ~/ 2) {
        swap(c, (c - 1) ~/ 2);
      }
    } else if (compare(i, heap[0]) < 0) {
      heap[0] = i;
      for (var at = 0; ;) {
        final l = 2 * at + 1, r = l + 1;
        var m = at;
        if (l < heap.length && compare(heap[l], heap[m]) > 0) m = l;
        if (r < heap.length && compare(heap[r], heap[m]) > 0) m = r;
        if (m == at) break;
        swap(at, m);
        at = m;
      }
    }
  }
  return heap..sort(compare);
}

/// A cell as written text: blank when missing, a [DateTime] in ISO 8601 as the readers take it.
String _written(Object? v) => switch (v) {
  null => '',
  final DateTime d => d.toIso8601String(),
  _ => '$v',
};

/// [value] as JSON, a [DateTime] in ISO 8601.
String _json(Object? value, {String? indent}) {
  Object? dates(Object? v) => v is DateTime ? v.toIso8601String() : v;
  return indent == null ? jsonEncode(value, toEncodable: dates) : JsonEncoder.withIndent(indent, dates).convert(value);
}

/// The rows of a CSV, TSV or NDJSON file, fed to it text piece by piece: what [Table.lines]
/// reads with.
final class _RowReader {
  final String _path;
  final TableFormat _format;
  final String _decimal;
  int? _sep;
  _Schema? _head;
  String _pending = '';
  bool _first = true;
  final _arrived = <String>[];
  int _waiting = 0;

  /// Data rows (or NDJSON lines) so far.
  int _row = 0;

  /// Line breaks in the CSV or TSV text read so far, for the line a failure names.
  int _lines = 0;

  _RowReader(this._path, this._format, String? separator, this._decimal)
    : _sep = separator == null ? null : Table._oneChar(separator);

  /// The rows [piece] completes. Pieces are scanned as they come, unless a record is held over:
  /// then once as much again has arrived, so one huge cell is scanned a doubling number of
  /// times, not once per piece.
  List<Row> add(String piece) {
    _arrived.add(piece);
    _waiting += piece.length;
    if (_waiting < _pending.length) return const [];
    return _scan(done: false);
  }

  /// The rows left once the text is all in; an unclosed quote is a [FormatException].
  List<Row> close() => _arrived.isEmpty && _pending.isEmpty ? const [] : _scan(done: true);

  List<Row> _scan({required bool done}) {
    var chunk = (StringBuffer(_pending)..writeAll(_arrived)).toString();
    _arrived.clear();
    _waiting = 0;
    if (_first && chunk.startsWith('﻿')) chunk = chunk.substring(1);
    _first = false;
    try {
      if (_format == TableFormat.ndjson) {
        final end = done ? chunk.length : chunk.lastIndexOf('\n') + 1;
        _pending = chunk.substring(end);
        final rows = <Row>[];
        final lines = end == 0 ? <String>[] : chunk.substring(0, end).split('\n');
        // The break that ends the last line starts no line of its own.
        if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
        for (final line in lines) {
          if (Table._ndjsonRow(line, ++_row) case final object?) {
            final schema = _Schema(object.keys.toList(), source: _path, format: _format, decimal: _decimal);
            rows.add(Row(_TableRow(schema, object)));
          }
        }
        return rows;
      }
      final sep = _sep ??= Table._oneChar(Table._sniffSeparator(chunk));
      final data = _CsvCells.scan(chunk, sep, _format._label, quotes: _format == TableFormat.csv, done: done);
      _pending = chunk.substring(data.end);
      final rows = <Row>[];
      for (var r = 0; r < data.length; r++) {
        final cells = _RecordCells(data, r);
        if (_head case final head?) {
          // Copied out, so a row kept from the stream holds its own cells, not the whole chunk.
          rows.add(Row(_CsvRow.streamed(head, List.of(cells, growable: false), ++_row)));
        } else {
          _head = _Schema(_names(cells, trailing: true), source: _path, format: _format, decimal: _decimal);
        }
      }
      _lines += _lineAt(chunk, data.end) - 1;
      return rows;
    } on FormatException catch (e) {
      // `CSV line 3: …` counts in this chunk; NDJSON's already counts in the file.
      final label = _format._label;
      final at = RegExp('^$label line (\\d+): ').firstMatch(e.message);
      final line = at == null ? null : int.parse(at[1]!) + (_format == TableFormat.ndjson ? 0 : _lines);
      final why = at == null ? e.message : e.message.substring(at.end);
      throw FormatException('Invalid $label in $_path${line == null ? '' : ', line $line'}: $why');
    }
  }
}

/// [Table.writer]: rows encoded as they arrive and handed to an atomic write, which renames the
/// file into place on [close].
final class _TableWriter implements StreamConsumer<Row> {
  final String _path;
  final TableFormat _format;
  final String _separator;

  StreamController<List<int>>? _out;
  Future<void>? _done;
  Completer<void>? _resumed;
  final _buffer = StringBuffer();
  List<String>? _columns;
  Set<String>? _known;
  int _rows = 0;
  (Object, StackTrace)? _failed;
  bool _closed = false;

  _TableWriter(this._path, this._format, this._separator);

  StreamController<List<int>> get _open => _out ??= () {
    final out = StreamController<List<int>>(
      onResume: () {
        _resumed?.complete();
        _resumed = null;
      },
    );
    _done = FileBridge.writeStream(_path, out.stream);
    return out;
  }();

  @override
  Future<void> addStream(Stream<Row> stream) async {
    if (_closed) throw StateError('Cannot add to a closed Table.writer for $_path');
    if (_failed case (final e, final s)) Error.throwWithStackTrace(e, s);
    final out = _open;
    try {
      await for (final row in stream) {
        _row(row);
        if (_buffer.length >= 64 << 10) {
          out.add(utf8.encode(_buffer.toString()));
          _buffer.clear();
          // The file is behind: wait until it takes more, so memory stays bounded.
          if (out.isPaused) await (_resumed ??= Completer()).future;
        }
      }
    } catch (e, s) {
      _failed = (e, s);
      // The write fails with it, deleting its temporary file and leaving the old one.
      out.addError(e, s);
      try {
        await _done;
      } catch (_) {} // the same error, rethrown below
      rethrow;
    }
  }

  void _row(Map<String, Object?> row) {
    switch (_format) {
      case TableFormat.ndjson:
        _buffer
          ..write(_json(row))
          ..write('\n');
      case TableFormat.json:
        _buffer
          ..write(_rows == 0 ? '[\n  ' : ',\n  ')
          ..write(_json(row));
      case TableFormat.csv || TableFormat.tsv || TableFormat.markdown:
        final columns = _columns ??= () {
          final columns = row.keys.toList();
          if (_format == TableFormat.markdown) {
            _buffer
              ..writeln('| ${columns.map(_mdCell).join(' | ')} |')
              ..writeln('| ${[for (final _ in columns) '---'].join(' | ')} |');
          } else {
            _csvLine(_buffer, columns, _separator, tsv: _format == TableFormat.tsv ? (i) => 'the header' : null);
          }
          return columns;
        }();
        final known = _known ??= columns.toSet();
        for (final key in row.keys) {
          if (!known.contains(key)) {
            throw ArgumentError.value(
              key,
              'row',
              'Invalid row for $_path: "$key" is not a column (${columns.join(', ')})',
            );
          }
        }
        final cells = [for (final c in columns) _written(row[c])];
        if (_format == TableFormat.markdown) {
          _buffer.writeln('| ${cells.map(_mdCell).join(' | ')} |');
        } else {
          final n = _rows + 1;
          _csvLine(
            _buffer,
            cells,
            _separator,
            tsv: _format == TableFormat.tsv ? (i) => 'row $n, column "${columns[i]}"' : null,
          );
        }
    }
    _rows++;
  }

  static String _mdCell(Object? v) => _written(v).replaceAll('|', r'\|').replaceAll('\n', '⏎').replaceAll('\r', '');

  @override
  Future<void> close() async {
    if (_closed) return _done;
    _closed = true;
    final out = _open;
    if (_failed == null) {
      if (_format == TableFormat.json) _buffer.write(_rows == 0 ? '[]\n' : '\n]\n');
      if (_buffer.isNotEmpty) out.add(utf8.encode(_buffer.toString()));
      _buffer.clear();
    }
    await out.close();
    await _done;
  }
}
