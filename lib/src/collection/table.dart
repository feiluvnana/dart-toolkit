part of '../../collection.dart';

/// One row of a [Table]: column name to value.
typedef Row = Map<String, Object?>;

/// Typed reads on a row; a value scraped as text still counts as a number.
///
/// {@category Collections}
extension RowExtensions on Map<String, Object?> {
  /// The value of [column] as [T], coercing text to numbers and booleans; `null` when it cannot.
  T? get<T>(String column) => _coerce<T>(this[column]);

  /// The value of [column] as text, `''` for null.
  String text(String column) => switch (this[column]) {
    null => '',
    final v => '$v',
  };

  /// The value of [column] as a number, or `null`.
  num? number(String column) => _coerce<num>(this[column]);
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
  final List<Row> rows;

  final List<(String, bool)> _order;

  Table._(this.columns, this.rows, this._order);

  /// A table over [columns] and [rows]; a row missing a column reads `null` there.
  Table(List<String> columns, Iterable<Map<String, Object?>> rows)
    : this._(List.unmodifiable(columns), List.unmodifiable(rows.map(_copy)), const []);

  /// A table from maps; the columns are every key seen, in first-seen order.
  factory Table.rows(Iterable<Map<String, Object?>> rows) {
    final list = rows.toList();
    final columns = <String>{for (final r in list) ...r.keys}.toList();
    return Table(columns, list);
  }

  /// A table from [items] through [toRow].
  static Table records<T>(Iterable<T> items, Map<String, Object?> Function(T item) toRow) =>
      Table.rows(items.map(toRow));

  /// A table from CSV text (RFC 4180: quoted fields, doubled quotes, newlines inside quotes).
  /// The first record names the columns; every value is a [String].
  factory Table.csv(String text, {String separator = ','}) {
    final records = _parseCsv(text, separator);
    if (records.isEmpty) return Table(const [], const []);
    final header = records.first;
    return Table(header, [
      for (final r in records.skip(1))
        if (r.length > 1 || (r.length == 1 && r.first.isNotEmpty))
          {for (var i = 0; i < header.length; i++) header[i]: i < r.length ? r[i] : null},
    ]);
  }

  static Row _copy(Map<String, Object?> r) => Map<String, Object?>.of(r);

  /// The rows as a query.
  Seq<Row> get seq => rows.seq;

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;

  /// Row [index].
  Row operator [](int index) => rows[index];

  /// Every value of [column], top to bottom.
  List<Object?> column(String name) => [for (final r in rows) r[name]];

  /// Only the rows that pass [test].
  Table where(bool Function(Row row) test) => Table._(columns, rows.where(test).toList(), const []);

  /// The first [count] rows.
  Table take(int count) => Table._(columns, rows.take(count).toList(), _order);

  /// All but the first [count] rows.
  Table skip(int count) => Table._(columns, rows.skip(count).toList(), _order);

  /// Sorted by [column], largest first when [descending]; numbers compare as numbers, `null` last.
  Table orderBy(String column, {bool descending = false}) => _sorted([(column, descending)]);

  /// The next sort key, where [orderBy]'s tie.
  Table thenBy(String column, {bool descending = false}) => _sorted([..._order, (column, descending)]);

  Table _sorted(List<(String, bool)> order) {
    final sorted = rows.indexed.toList()
      ..sort((a, b) {
        for (final (col, desc) in order) {
          final c = _compareCells(a.$2[col], b.$2[col]);
          if (c != 0) return desc ? -c : c;
        }
        return a.$1.compareTo(b.$1);
      });
    return Table._(columns, [for (final s in sorted) s.$2], order);
  }

  /// Only [names], in that order.
  Table select(List<String> names) => Table._(List.unmodifiable(names), [
    for (final r in rows) {for (final n in names) n: r[n]},
  ], const []);

  /// Every column but [names].
  Table drop(List<String> names) => select([
    for (final c in columns)
      if (!names.contains(c)) c,
  ]);

  /// Columns renamed by [names], old to new.
  Table rename(Map<String, String> names) => Table._(List.unmodifiable([for (final c in columns) names[c] ?? c]), [
    for (final r in rows) {for (final MapEntry(:key, :value) in r.entries) names[key] ?? key: value},
  ], const []);

  /// A new column [name] computed from each row.
  Table derive(String name, Object? Function(Row row) value) =>
      Table._(List.unmodifiable([...columns.where((c) => c != name), name]), [
        for (final r in rows) {...r, name: value(r)},
      ], const []);

  /// One row per distinct combination of [by] (every column when omitted); the first wins.
  Table distinct([List<String>? by]) {
    final keys = by ?? columns;
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
    final index = other.rows.seq.groupBy((r) => _Key([r[to]])).toMap();
    final rightColumns = {
      for (final c in other.columns)
        if (c != to) c: columns.contains(c) ? '${c}_2' : c,
    };
    final out = <Row>[];
    for (final r in rows) {
      final matches = index[_Key([r[on]])];
      if (matches == null) {
        if (left) out.add({...r, for (final c in rightColumns.values) c: null});
        continue;
      }
      for (final m in matches) {
        out.add({...r, for (final MapEntry(:key, :value) in rightColumns.entries) value: m[key]});
      }
    }
    return Table._(List.unmodifiable([...columns, ...rightColumns.values]), out, const []);
  }

  /// Rows grouped by [column] (and [more]), ready for [TableGroups.count], `sum`, `agg`.
  TableGroups groupBy(String column, [List<String> more = const []]) => TableGroups._(this, [column, ...more]);

  /// A crosstab: one row per [rows] value, one column per [column] value, [value] folded by [agg].
  Table pivot({required String rows, required String column, required String value, Agg agg = Agg.sum}) {
    final columnValues = <String>{for (final r in this.rows) r.text(column)}.toList();
    final out = <Row>[];
    for (final (k, group) in this.rows.seq.groupBy((r) => _Key([r[rows]]))) {
      final row = <String, Object?>{rows: k.parts.first};
      final byColumn = group.seq.groupBy((r) => r.text(column)).toMap();
      for (final c in columnValues) {
        row[c] = _foldCells(agg, [for (final r in byColumn[c] ?? const <Row>[]) r[value]]);
      }
      out.add(row);
    }
    return Table._(List.unmodifiable([rows, ...columnValues]), out, const []);
  }

  /// CSV text with a header row; fields are quoted when they need it.
  String toCsv({String separator = ','}) {
    String cell(Object? v) {
      final s = v == null ? '' : '$v';
      final needsQuote = s.contains(separator) || s.contains('"') || s.contains('\n') || s.contains('\r');
      return needsQuote ? '"${s.replaceAll('"', '""')}"' : s;
    }

    final sb = StringBuffer()..writeln(columns.map(cell).join(separator));
    for (final r in rows) {
      sb.writeln(columns.map((c) => cell(r[c])).join(separator));
    }
    return sb.toString();
  }

  /// Writes [toCsv] to [path], creating parent directories.
  Future<File> saveCsv(String path, {String separator = ','}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return file.writeAsString(toCsv(separator: separator));
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
    : _groups = table.rows.seq.groupBy((r) => _Key([for (final k in _keys) r[k]])).toMap();

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
          {
            for (var i = 0; i < _keys.length; i++) _keys[i]: k.parts[i],
            for (final MapEntry(key: name, value: f) in folds.entries) name: f(rows),
          },
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
  bool operator ==(Object other) =>
      other is _Key &&
      other.parts.length == parts.length &&
      [for (var i = 0; i < parts.length; i++) parts[i] == other.parts[i]].every((e) => e);

  @override
  int get hashCode => Object.hashAll(parts);
}

/// Cells compare as numbers when both are numbers or read as numbers, `null` last, text otherwise.
int _compareCells(Object? a, Object? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  final na = _coerce<num>(a), nb = _coerce<num>(b);
  if (na != null && nb != null) return na.compareTo(nb);
  if (a is Comparable && b is Comparable && a.runtimeType == b.runtimeType) return a.compareTo(b);
  return '$a'.compareTo('$b');
}

/// `JsonDocument.to<T>`'s coercions, plus thousands separators in text: `'1,200'` reads as 1200.
T? _coerce<T>(Object? val) {
  if (val == null) return null;
  if (val is T) return val as T;
  if (const <String>[] is List<T>) return '$val' as T;
  final text = val is String ? val.trim().replaceAll(',', '') : '$val';
  if (const <num>[] is List<T>) return num.tryParse(text) as T?;
  if (const <int>[] is List<T>) {
    return (val is num ? val.toInt() : int.tryParse(text) ?? double.tryParse(text)?.toInt()) as T?;
  }
  if (const <double>[] is List<T>) return (val is num ? val.toDouble() : double.tryParse(text)) as T?;
  if (const <bool>[] is List<T>) {
    if (val == 'true' || val == 1) return true as T;
    if (val == 'false' || val == 0) return false as T;
  }
  return null;
}

/// RFC 4180 records: quoted fields, doubled quotes, newlines inside quotes, CRLF or LF.
List<List<String>> _parseCsv(String text, String separator) {
  final records = <List<String>>[];
  var record = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = 0;
  final sep = separator.codeUnitAt(0);
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (quoted) {
      if (c == 0x22) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
          field.writeCharCode(0x22);
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.writeCharCode(c);
      }
    } else if (c == 0x22) {
      quoted = true;
    } else if (c == sep) {
      record.add(field.toString());
      field.clear();
    } else if (c == 0x0a || c == 0x0d) {
      if (c == 0x0d && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0a) i++;
      record.add(field.toString());
      field.clear();
      records.add(record);
      record = <String>[];
    } else {
      field.writeCharCode(c);
    }
    i++;
  }
  if (field.isNotEmpty || record.isNotEmpty) {
    record.add(field.toString());
    records.add(record);
  }
  return records;
}

/// A JSON array of objects as a [Table].
///
/// {@category Collections}
extension JsonTableExtensions on JsonDocument {
  /// The rows of this array of objects; a non-object element is skipped.
  Table get table => Table.rows([
    for (final item in list)
      if (item.raw case final Map<Object?, Object?> m) {for (final MapEntry(:key, :value) in m.entries) '$key': value},
  ]);
}

/// {@category Collections}
extension JsonDocumentsTableExtensions on Iterable<JsonDocument> {
  /// The rows of these documents, each an object; a non-object is skipped.
  Table get table => Table.rows([
    for (final item in this)
      if (item.raw case final Map<Object?, Object?> m) {for (final MapEntry(:key, :value) in m.entries) '$key': value},
  ]);
}
