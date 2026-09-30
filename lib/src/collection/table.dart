part of '../../collection.dart';

/// One row of a [Table]: column name to value.
typedef Row = Map<String, Object?>;

/// Typed reads on a row; a value scraped as text still counts as a number.
///
/// `number` and `get` throw a [StateError] naming the column and the row when the value is
/// missing or does not convert, so a typo or a bad cell fails where it happens; the `OrNull`
/// forms answer `null` instead.
///
/// {@category Collections}
extension RowExtensions on Map<String, Object?> {
  /// The value of [column] as [T], coercing text to numbers and booleans.
  T get<T>(String column) {
    final value = _coerce<T>(this[column]);
    if (value == null) throw StateError('Column "$column" is not a $T in row $this');
    return value;
  }

  /// The value of [column] as [T], or `null` when missing or not convertible.
  T? getOrNull<T>(String column) => _coerce<T>(this[column]);

  /// The value of [column] as text, `''` for null.
  String text(String column) => switch (this[column]) {
    null => '',
    final v => '$v',
  };

  /// The value of [column] as a number; `'1,200'` counts.
  num number(String column) => get<num>(column);

  /// The value of [column] as a number, or `null`.
  num? numberOrNull(String column) => _coerce<num>(this[column]);
}

/// How a grouped column is folded.
///
/// {@category Collections}
enum Agg { count, sum, avg, min, max, first, last, list }

/// Rows of named columns: what a scraped listing, a CSV, a JSON array of objects and an HTML
/// `<table>` all are. Eager, immutable; every operation returns a new table.
///
/// ```dart
/// final t = doc.$('table#songs').table;
/// t.where((r) => r.number('size')! > 1e6).orderBy('disc').thenBy('n').select(['title', 'size']).show();
/// ```
///
/// {@category Collections}
final class Table {
  /// Column names, in display order.
  final List<String> columns;

  /// The rows; each has every column, `null` where a value is missing.
  List<Row> get rows => _rows ??= _sort(_unsorted!, _order);

  /// The rows, once they are in order. `null` only for a table [orderBy] made that nothing
  /// has read yet: `orderBy(…).take(10)` then picks the ten without sorting the rest.
  List<Row>? _rows;

  /// The rows [_order] has not been applied to yet, while [_rows] is `null`.
  final List<Row>? _unsorted;

  final List<(String, bool)> _order;

  /// [columns] as a set, built on the first lookup. A table is immutable, so it cannot go
  /// stale, and every operation that names a column asks [_has] rather than scanning.
  Set<String>? _names;

  Table._(this.columns, List<Row> rows, this._order) : _rows = rows, _unsorted = null;

  /// [rows] in [order], sorted when first read.
  Table._ordered(this.columns, List<Row> rows, this._order) : _unsorted = rows;

  /// A table over [columns] and [rows]; a row missing a column reads `null` there.
  Table(List<String> columns, Iterable<Map<String, Object?>> rows)
    : this._(List.unmodifiable(columns), List.unmodifiable(rows.map(_copy)), const []);

  /// A table from maps; the columns are every key seen, in first-seen order.
  factory Table.rows(Iterable<Map<String, Object?>> rows) {
    final list = rows.toList();
    final columns = <String>{for (final r in list) ...r.keys}.toList();
    return Table(columns, list);
  }

  /// A table from [headers] and positional [rows] — the shape a program already has when
  /// it is about to print something. A short row is padded, a long one cut.
  ///
  /// ```dart
  /// Table.cells(['setting', 'value'], [['workers', 8], ['dry run', false]]).show();
  /// ```
  factory Table.cells(List<String> headers, Iterable<List<Object?>> rows) => Table(headers, [
    for (final row in rows) {for (var i = 0; i < headers.length; i++) headers[i]: i < row.length ? row[i] : null},
  ]);

  /// A table from CSV text (RFC 4180: quoted fields, doubled quotes, newlines inside quotes).
  /// The first record names the columns; every value is a [String]. A leading byte-order
  /// mark is dropped, and a quote that does not open a field is only a character.
  ///
  /// A blank line is not a record, before the header or after it; `""` on a line of its own
  /// is a row with one empty cell. A header that repeats a name reads the second as
  /// `name_2`, as [join] names a clash, so no column is lost. A quote that is never closed
  /// is a [FormatException], never the rest of the file swallowed into one cell.
  factory Table.csv(String text, {String separator = ','}) {
    final (records, _) = _scanCsv(text, _oneChar(separator), 0, done: true);
    if (records.isEmpty) return Table(const [], const []);
    final header = _header(records.first);
    return Table._(header.columns, List.unmodifiable([for (final r in records.skip(1)) header.row(r)]), const []);
  }

  /// The table in the file at [path], by its extension: `.json` (an array of objects),
  /// `.ndjson` or `.jsonl`, `.tsv`, and CSV for anything else. [save] is the way back.
  static Future<Table> read(String path, {String? separator}) async {
    final text = await File(path).readAsString();
    return switch (_extension(path)) {
      'json' => switch (jsonDecode(text)) {
        final List<Object?> items => Table.rows([for (final item in items) ?_object(item)]),
        _ => throw FormatException('$path is not a JSON array of objects'),
      },
      'ndjson' || 'jsonl' => Table.ndjson(text),
      final ext => Table.csv(text, separator: separator ?? (ext == 'tsv' ? '\t' : ',')),
    };
  }

  /// A decoded JSON object as a row, or `null` for anything else.
  static Row? _object(Object? item) => switch (item) {
    final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': e.value},
    _ => null,
  };

  /// The rows of the CSV, TSV or NDJSON file at [path], as they are read: for a file larger
  /// than memory, or to stop early. The same rows [read] would give, one at a time.
  static Stream<Row> readRows(String path, {String? separator}) async* {
    final ext = _extension(path);
    final text = File(path).openRead().transform(utf8.decoder);
    if (ext == 'ndjson' || ext == 'jsonl') {
      await for (final line in text.transform(const LineSplitter())) {
        if (_ndjsonRow(line) case final row?) yield row;
      }
      return;
    }
    final sep = _oneChar(separator ?? (ext == 'tsv' ? '\t' : ','));
    _Header? header;
    var pending = '';
    var first = true;
    // The record a chunk ends inside is carried into the next one, and read again from its
    // start — but only once what has arrived since is as long as what is carried. Rescanning
    // on every chunk made one record the size of the file cost the file's size squared.
    final arrived = <String>[];
    var waiting = 0;
    await for (final piece in text) {
      arrived.add(piece);
      waiting += piece.length;
      if (waiting < pending.length) continue;
      final chunk = pending + arrived.join();
      arrived.clear();
      waiting = 0;
      final (records, rest) = _scanCsv(chunk, sep, 0, done: false, bom: first);
      first = false;
      pending = chunk.substring(rest);
      for (final r in records) {
        if (header != null) yield header.row(r);
        header ??= _header(r);
      }
    }
    for (final r in _scanCsv(pending + arrived.join(), sep, 0, done: true, bom: first).$1) {
      if (header != null) yield header.row(r);
      header ??= _header(r);
    }
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  /// A table from newline-delimited JSON: one object per line, blank lines skipped.
  factory Table.ndjson(String text) => Table.rows([for (final line in text.split('\n')) ?_ndjsonRow(line)]);

  /// One NDJSON line's object; `null` for a blank line or one that holds something else.
  static Row? _ndjsonRow(String line) => line.trim().isEmpty
      ? null
      : switch (jsonDecode(line)) {
          final Map<Object?, Object?> m => {for (final e in m.entries) '${e.key}': e.value},
          _ => null,
        };

  /// The separator's code unit. The scanner reads one at a time, so a longer separator would
  /// silently match on its first character alone.
  static int _oneChar(String separator) => separator.length == 1
      ? separator.codeUnitAt(0)
      : throw ArgumentError.value(separator, 'separator', 'must be exactly one character');

  /// Rows are frozen on the way in, so the documented immutability is real: a write
  /// through `table.rows` would otherwise change this table and every table derived from it.
  /// A CSV row is frozen already.
  static Row _copy(Map<String, Object?> r) => r is _CsvRow ? r : Map<String, Object?>.unmodifiable(r);

  /// The rows as a query.
  Sequence<Row> get sequence => rows.sequence;

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;

  // The column is checked once, not once per row: `_has` scans the column list, so leaving
  // it inside the comprehension made reading one column cost rows × columns comparisons.

  /// Every value of [column], top to bottom: `t['title']`. Rows are `t.rows[i]`.
  List<Object?> operator [](String column) {
    final c = _has(column);
    return [for (final r in rows) r[c]];
  }

  /// Every value of [column] as a number; a cell that is not one throws. Text reads as a
  /// decimal number only: `0x10`, `NaN` and `Infinity` are not numbers in a table.
  List<num> numbers(String column) {
    final c = _has(column);
    return [for (final r in rows) r.number(c)];
  }

  /// Every value of [column] as text.
  List<String> texts(String column) {
    final c = _has(column);
    return [for (final r in rows) r.text(c)];
  }

  /// [name], or an [ArgumentError] that lists the columns there are.
  String _has(String name) => (_names ??= columns.toSet()).contains(name)
      ? name
      : throw ArgumentError('No column "$name"; columns are ${columns.join(', ')}');

  /// Only the rows that pass [test].
  Table where(bool Function(Row row) test) => Table._(columns, rows.where(test).toList(), const []);

  /// The first [count] rows. Straight after [orderBy], only those [count] are sorted.
  Table take(int count) => Table._(columns, _top(count), _order);

  /// The first [count] rows in order: from a table that is not sorted yet, a selection of
  /// the [count] smallest rather than a sort of every row.
  List<Row> _top(int count) {
    final unsorted = _unsorted;
    if (_rows != null || unsorted == null || count >= unsorted.length ~/ 8) return rows.take(count).toList();
    if (count <= 0) return const [];
    final keys = _keys(unsorted, _order);
    return [for (final i in _smallest(unsorted.length, count, (x, y) => _compareAt(keys, _order, x, y))) unsorted[i]];
  }

  /// All but the first [count] rows.
  Table skip(int count) => Table._(columns, rows.skip(count).toList(), _order);

  /// Sorted by [column], largest first when [descending]; numbers compare as numbers, `null` last.
  ///
  /// The sort runs when the rows are first read, so `orderBy(…).take(n)` sorts only `n`.
  Table orderBy(String column, {bool descending = false}) =>
      Table._ordered(columns, _sourceRows, [(_has(column), descending)]);

  /// The next sort key, where [orderBy]'s tie.
  Table thenBy(String column, {bool descending = false}) =>
      Table._ordered(columns, _sourceRows, [..._order, (_has(column), descending)]);

  /// The rows an order applies to: the unsorted ones when this table's own order has not
  /// run yet, since the new order replaces it anyway.
  List<Row> get _sourceRows => _unsorted ?? rows;

  /// Each sort column pulled and coerced once per row rather than once per comparison; see
  /// [_Cell].
  static List<List<_Cell>> _keys(List<Row> rows, List<(String, bool)> order) => [
    for (final (col, _) in order) [for (final r in rows) _cell(r[col])],
  ];

  /// Rows [x] and [y] by [order]. The position is the last tie-break, so the order is stable.
  static int _compareAt(List<List<_Cell>> keys, List<(String, bool)> order, int x, int y) {
    for (var k = 0; k < order.length; k++) {
      final a = keys[k][x];
      final b = keys[k][y];
      // An empty cell is missing data, not a small value, so it sorts last whichever
      // way the column is sorted — which is what `orderBy` has always documented, and
      // what negating the whole comparison quietly undid for a descending sort.
      if (a.$2 == null || b.$2 == null) {
        if (a.$2 == null && b.$2 == null) continue;
        return a.$2 == null ? 1 : -1;
      }
      final c = _compare(a, b);
      if (c != 0) return order[k].$2 ? -c : c;
    }
    return x.compareTo(y);
  }

  static List<Row> _sort(List<Row> rows, List<(String, bool)> order) {
    final keys = _keys(rows, order);
    final positions = [for (var i = 0; i < rows.length; i++) i]..sort((x, y) => _compareAt(keys, order, x, y));
    return List.unmodifiable([for (final i in positions) rows[i]]);
  }

  /// Only [names], in that order. A name that is not a column throws, as it does
  /// everywhere else a column is named.
  Table select(List<String> names) {
    names.forEach(_has);
    return Table._(List.unmodifiable(names), [
      for (final r in rows) _copy({for (final n in names) n: r[n]}),
    ], const []);
  }

  /// Every column but [names].
  Table drop(List<String> names) {
    final dropped = names.toSet();
    return select([
      for (final c in columns)
        if (!dropped.contains(c)) c,
    ]);
  }

  /// Columns renamed by [names], old to new.
  Table rename(Map<String, String> names) => Table._(List.unmodifiable([for (final c in columns) names[c] ?? c]), [
    for (final r in rows) _copy({for (final MapEntry(:key, :value) in r.entries) names[key] ?? key: value}),
  ], const []);

  /// A new column [name] computed from each row.
  Table derive(String name, Object? Function(Row row) value) =>
      Table._(List.unmodifiable([...columns.where((c) => c != name), name]), [
        for (final r in rows) _copy({...r, name: value(r)}),
      ], const []);

  /// One row per distinct combination of [by] (every column when omitted); the first wins.
  Table distinct([List<String>? by]) {
    final keys = by?.map(_has).toList() ?? columns;
    final seen = <_Key>{};
    return Table._(columns, [
      for (final r in rows)
        if (seen.add(_Key([for (final k in keys) r[k]]))) r,
    ], const []);
  }

  /// Inner join on [on] here and [to] (default [on]) on [other]. A column both tables have,
  /// other than the key, arrives from [other] as `name_2`.
  Table join(Table other, {required String on, String? to}) => _join(other, on, to ?? on, left: false);

  /// Left join: every row here, with [other]'s columns `null` where nothing matched.
  Table leftJoin(Table other, {required String on, String? to}) => _join(other, on, to ?? on, left: true);

  Table _join(Table other, String on, String to, {required bool left}) {
    _has(on);
    other._has(to);
    final index = other.rows.sequence.groupBy((r) => _Key([r[to]])).toMap();
    final mine = _names ??= columns.toSet();
    final rightColumns = {
      for (final c in other.columns)
        if (c != to) c: mine.contains(c) ? '${c}_2' : c,
    };
    final out = <Row>[];
    for (final r in rows) {
      final matches = index[_Key([r[on]])];
      if (matches == null) {
        if (left) out.add(_copy({...r, for (final c in rightColumns.values) c: null}));
        continue;
      }
      for (final m in matches) {
        out.add(_copy({...r, for (final MapEntry(:key, :value) in rightColumns.entries) value: m[key]}));
      }
    }
    return Table._(List.unmodifiable([...columns, ...rightColumns.values]), out, const []);
  }

  /// Rows grouped by [column] (and [more]), ready for [TableGroups.count], `sum`, `agg`.
  TableGroups groupBy(String column, [List<String> more = const []]) =>
      TableGroups._(this, [_has(column), ...more.map(_has)]);

  /// A crosstab: one row per [rows] value, one column per [column] value, [value] folded by [agg].
  Table pivot({required String rows, required String column, required String value, Agg agg = Agg.sum}) {
    _has(rows);
    _has(column);
    _has(value);
    final columnValues = <String>{for (final r in this.rows) r.text(column)}.toList();
    final out = <Row>[];
    for (final group in this.rows.sequence.groupBy((r) => _Key([r[rows]]))) {
      final row = <String, Object?>{rows: group.key.parts.first};
      final byColumn = group.groupBy((r) => r.text(column)).toMap();
      for (final c in columnValues) {
        row[c] = _foldCells(agg, [for (final r in byColumn[c] ?? const <Row>[]) r[value]]);
      }
      out.add(_copy(row));
    }
    return Table._(List.unmodifiable([rows, ...columnValues]), out, const []);
  }

  /// CSV text with a header row; fields are quoted when they need it.
  ///
  /// A row of one empty cell is written `""`: an empty line is a blank line, which a reader
  /// skips, so the row would not come back.
  String toCsv({String separator = ','}) {
    _oneChar(separator);

    String cell(Object? v) {
      final s = v == null ? '' : '$v';
      final needsQuote = s.contains(separator) || s.contains('"') || s.contains('\n') || s.contains('\r');
      return needsQuote ? '"${s.replaceAll('"', '""')}"' : s;
    }

    String line(Iterable<Object?> cells) {
      final text = cells.map(cell).join(separator);
      return text.isEmpty ? '""' : text;
    }

    final sb = StringBuffer()..writeln(line(columns));
    for (final r in rows) {
      sb.writeln(line(columns.map((c) => r[c])));
    }
    return sb.toString();
  }

  /// Newline-delimited JSON: one object per row.
  String toNdjson() => rows.map(jsonEncode).join('\n') + (rows.isEmpty ? '' : '\n');

  /// A Markdown table, numbers right-aligned.
  String toMarkdown() {
    final numeric = [
      for (final c in columns) rows.isNotEmpty && rows.every((r) => r[c] == null || _coerce<num>(r[c]) != null),
    ];
    String cell(Object? v) => (v == null ? '' : '$v').replaceAll('|', r'\|').replaceAll('\n', ' ');
    final sb = StringBuffer()
      ..writeln('| ${columns.join(' | ')} |')
      ..writeln('| ${[for (final n in numeric) n ? '---:' : '---'].join(' | ')} |');
    for (final r in rows) {
      sb.writeln('| ${columns.map((c) => cell(r[c])).join(' | ')} |');
    }
    return sb.toString();
  }

  /// Writes this table to [path] in the format its extension names — `.json`, `.ndjson` or
  /// `.jsonl`, `.md`, `.tsv`, and CSV for anything else — creating parent directories. The
  /// way back is [read], which reads the same extensions.
  Future<File> save(String path, {String? separator}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final ext = _extension(path);
    return file.writeAsString(switch (ext) {
      'json' => jsonEncode(rows),
      'ndjson' || 'jsonl' => toNdjson(),
      'md' || 'markdown' => toMarkdown(),
      _ => toCsv(separator: separator ?? (ext == 'tsv' ? '\t' : ',')),
    });
  }

  /// Prints this table with borders to `Io.out`; a short row is padded, a long one cut.
  ///
  /// This is the package's only table renderer: anything with rows and columns to print
  /// becomes a [Table] first, `Table.cells` being the shortest way in.
  void show() {
    // A missing cell is blank, as `toCsv` and `toMarkdown` write it, not the word `null`.
    final grid = [
      for (final r in rows) [for (final c in columns) r[c] == null ? '' : '${r[c]}'],
    ];
    final widths = [for (final h in columns) Io.width(h)];
    for (final row in grid) {
      for (var i = 0; i < columns.length; i++) {
        widths[i] = max(widths[i], Io.width(row[i]));
      }
    }

    String divider(String left, String mid, String right, String cross) =>
        '$left${widths.map((w) => mid * (w + 2)).join(cross)}$right';
    String line(List<String> row) =>
        '│${[for (var i = 0; i < columns.length; i++) ' ${row[i]}${' ' * (widths[i] - Io.width(row[i]))} '].join('│')}│';

    Io.out.writeln(divider('┌', '─', '┐', '┬'));
    if (columns.isNotEmpty) {
      Io.out.writeln(line(columns));
      Io.out.writeln(divider('├', '─', '┤', '┼'));
    }
    for (final row in grid) {
      Io.out.writeln(line(row));
    }
    Io.out.writeln(divider('└', '─', '┘', '┴'));
  }

  /// The rows, as `jsonEncode` wants them: `jsonEncode(table)` is a JSON array of objects.
  List<Row> toJson() => rows;

  @override
  String toString() => 'Table(${columns.length} columns, ${rows.length} rows)';
}

/// The groups of a [Table.groupBy]; each fold returns a table of the keys plus the result.
///
/// {@category Collections}
final class TableGroups {
  final List<String> _keys;
  final Map<_Key, List<Row>> _groups;

  TableGroups._(Table table, this._keys)
    : _groups = table.rows.sequence.groupBy((r) => _Key([for (final k in _keys) r[k]])).toMap();

  /// The keys and how many rows each has, in a column named [as].
  Table count({String as = 'count'}) => _fold({as: (rows) => rows.length});

  /// The keys and the sum of [column].
  Table sum(String column, {String? as}) => agg({column: Agg.sum}, as: as);

  /// The keys and the mean of [column].
  Table avg(String column, {String? as}) => agg({column: Agg.avg}, as: as);

  /// The keys and the smallest [column].
  Table min(String column, {String? as}) => agg({column: Agg.min}, as: as);

  /// The keys and the largest [column].
  Table max(String column, {String? as}) => agg({column: Agg.max}, as: as);

  /// The keys and each [aggregates] column folded by its [Agg], under the column's own name
  /// ([as] renames a single one).
  Table agg(Map<String, Agg> aggregates, {String? as}) => _fold({
    for (final MapEntry(key: column, value: how) in aggregates.entries)
      (aggregates.length == 1 ? as : null) ?? (how == Agg.count ? 'count' : column): (rows) =>
          _foldCells(how, [for (final r in rows) r[column]]),
  });

  /// The keys and each [folds] column computed from the group's rows.
  Table aggWith(Map<String, Object? Function(List<Row> rows)> folds) => _fold(folds);

  Table _fold(Map<String, Object? Function(List<Row> rows)> folds) =>
      Table._(List.unmodifiable([..._keys, ...folds.keys]), [
        for (final MapEntry(key: k, value: rows) in _groups.entries)
          Table._copy({
            for (var i = 0; i < _keys.length; i++) _keys[i]: k.parts[i],
            for (final MapEntry(key: name, value: f) in folds.entries) name: f(rows),
          }),
      ], const []);
}

Object? _foldCells(Agg how, List<Object?> values) {
  final nums = [for (final v in values) ?_coerce<num>(v)];
  final present = [for (final v in values) ?v];
  return switch (how) {
    Agg.count => values.length,
    Agg.sum => nums.fold<num>(0, (a, b) => a + b),
    Agg.avg => nums.isEmpty ? null : nums.fold<num>(0, (a, b) => a + b) / nums.length,
    Agg.min => present.isEmpty ? null : present.reduce((a, b) => _compareCells(a, b) <= 0 ? a : b),
    Agg.max => present.isEmpty ? null : present.reduce((a, b) => _compareCells(a, b) >= 0 ? a : b),
    Agg.first => values.firstOrNull,
    Agg.last => values.lastOrNull,
    Agg.list => values,
  };
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

/// Cells compare as numbers when both are numbers or read as numbers, `null` last, text otherwise.
/// A cell prepared for comparison: the number it coerces to, when it does, and the cell.
///
/// The coercion is the expensive half — a text cell is trimmed, stripped of its thousands
/// separators and parsed — and a sort compares each cell about log n times, so [_sorted]
/// does it once per row up front.
typedef _Cell = (num? number, Object? value);

_Cell _cell(Object? value) => (_coerce<num>(value), value);

/// Cells in sort order: numbers as numbers, then like-typed comparables, then as text.
/// `null` sorts last.
int _compare(_Cell a, _Cell b) {
  final (na, va) = a;
  final (nb, vb) = b;
  if (va == null) return vb == null ? 0 : 1;
  if (vb == null) return -1;
  if (na != null && nb != null) return na.compareTo(nb);
  if (va is Comparable && vb is Comparable && va.runtimeType == vb.runtimeType) return va.compareTo(vb);
  return '$va'.compareTo('$vb');
}

/// Two raw cells by the same rule, for the comparisons that are not a sort.
int _compareCells(Object? a, Object? b) => _compare(_cell(a), _cell(b));

/// Digits grouped in threes by commas, the only commas a number may have: `1,200` is 1200,
/// and `1,5` — a decimal comma, or two values — is not a number at all.
final _thousands = RegExp(r'^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$');

/// A decimal number as a person writes one in a cell. `num.tryParse` also takes `0x10`,
/// `NaN` and `Infinity`, none of which a spreadsheet column means as a number.
final _decimal = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

/// `JsonDocument.to<T>`'s coercions, plus thousands separators in text: `'1,200'` reads as 1200.
T? _coerce<T>(Object? val) {
  if (val == null) return null;
  if (val is T) return val as T;
  if (T == String) return '$val' as T;
  var text = val is String ? val.trim() : '$val';
  if (text.contains(',') && _thousands.hasMatch(text)) text = text.replaceAll(',', '');
  final isNumeric = T == num || T == int || T == double;
  if (val is! num && isNumeric && !_decimal.hasMatch(text)) {
    return null;
  }
  if (T == num) return num.tryParse(text) as T?;
  if (T == int) {
    return (val is num ? val.toInt() : int.tryParse(text) ?? double.tryParse(text)?.toInt()) as T?;
  }
  if (T == double) return (val is num ? val.toDouble() : double.tryParse(text)) as T?;
  if (T == bool) {
    if (val == 'true' || val == 1) return true as T;
    if (val == 'false' || val == 0) return false as T;
  }
  return null;
}

/// The columns of a CSV and the index every row of it shares, so a row is its list of
/// cells and not a map of its own.
typedef _Header = ({List<String> columns, Map<String, int> index, _CsvRow Function(List<String>) row});

_Header _header(List<String> columns) {
  // A repeated name is the second `name_2`, the third `name_3`: keyed by name, the first
  // was silently lost, and a table written back repeated the survivor.
  final seen = <String>{};
  final cols = List<String>.unmodifiable([
    for (final name in columns)
      if (seen.add(name)) name else _unused(name, seen),
  ]);
  final index = {for (var i = 0; i < cols.length; i++) cols[i]: i};
  return (columns: cols, index: index, row: (cells) => _CsvRow(index, cells));
}

/// `name_2`, or the first `name_n` that [seen] does not have yet, added to it.
String _unused(String name, Set<String> seen) {
  for (var n = 2; ; n++) {
    if (seen.add('${name}_$n')) return '${name}_$n';
  }
}

/// A CSV row: the header's shared index over the record's cells. A short record reads
/// `null` past its end, a long one is cut at the header, as the map it replaces did.
final class _CsvRow extends UnmodifiableMapBase<String, Object?> {
  final Map<String, int> _index;
  final List<String> _cells;

  _CsvRow(this._index, this._cells);

  @override
  Object? operator [](Object? key) => switch (_index[key]) {
    final i? when i < _cells.length => _cells[i],
    _ => null,
  };

  @override
  bool containsKey(Object? key) => _index.containsKey(key);

  @override
  int get length => _index.length;

  @override
  Iterable<String> get keys => _index.keys;
}

/// RFC 4180 records of [text] from [start]: quoted fields, doubled quotes, newlines inside
/// quotes, CRLF or LF. Unquoted cells are sliced out rather than rebuilt a character at a
/// time, which is most of why this is four times the old scanner.
///
/// Unless [done], the text is a prefix of more to come, and the last record is left unread
/// when it may continue: the second value is where it starts, for the next call to resume.
///
/// A blank line is not a record; a line that is only `""` is one empty cell, and is. A
/// quote still open at the end of [text] when it is [done] is a [FormatException].
(List<List<String>>, int) _scanCsv(String text, int sep, int start, {required bool done, bool bom = true}) {
  if (bom && start == 0 && text.startsWith('\uFEFF')) start = 1;
  final records = <List<String>>[];
  final n = text.length;
  var i = start;
  bool end(int c) => c == sep || c == 0x0a || c == 0x0d;
  while (i < n) {
    final from = i;
    final record = <String>[];
    // Whether the record's first cell was quoted: `""` is a value, an empty line is not.
    final quoted = text.codeUnitAt(i) == 0x22;
    void finish() {
      if (quoted || record.length > 1 || record.first.isNotEmpty) records.add(record);
    }

    while (true) {
      if (i < n && text.codeUnitAt(i) == 0x22) {
        final cell = StringBuffer();
        var s = i + 1;
        while (true) {
          final q = text.indexOf('"', s);
          // An open quote at the end, or a quote that may be the first of a doubled pair.
          if (!done && (q < 0 || q + 1 == n)) return (records, from);
          if (q < 0) {
            final line = '\n'.allMatches(text.substring(0, i)).length + 1;
            throw FormatException('CSV: the quote opened on line $line is never closed', text, i);
          }
          if (q + 1 < n && text.codeUnitAt(q + 1) == 0x22) {
            cell.write(text.substring(s, q + 1));
            s = q + 2;
            continue;
          }
          cell.write(text.substring(s, q));
          i = q + 1;
          break;
        }
        // Anything between the closing quote and the separator is kept as it stands.
        final rest = i;
        while (i < n && !end(text.codeUnitAt(i))) {
          i++;
        }
        record.add((cell..write(text.substring(rest, i))).toString());
      } else {
        final s = i;
        while (i < n && !end(text.codeUnitAt(i))) {
          i++;
        }
        record.add(text.substring(s, i));
      }
      if (i >= n) {
        if (!done) return (records, from);
        finish();
        return (records, n);
      }
      final c = text.codeUnitAt(i++);
      if (c == sep) continue;
      if (c == 0x0d) {
        if (i < n) {
          if (text.codeUnitAt(i) == 0x0a) i++;
        } else if (!done) {
          return (records, from);
        }
      }
      finish();
      break;
    }
  }
  return (records, i);
}
