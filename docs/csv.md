# CSV Tables (`io.csv.*`)

An RFC 4180-compliant reader, writer and streaming parser with zero external dependencies: quoted fields, escaped quotes, and CRLF or LF line endings.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // Read records keyed by the header line:
  final rows = await io.csv.maps('people.csv'); // Sequence<Map<String, String>>
  rows.each((row) => print('${row['name']} — ${row['role']}'));

  // Shaping is the next call, not an import:
  print(rows.tally((row) => row['role'] ?? ''));

  // Write records atomically:
  await io.csv.write('out/people.csv', rows.list);
}
```

---

## 1. Reading & Streaming

Four readers, one per corner of *keyed or raw* × *all at once or a row at a time*. Each one's return type says which it is, so there is nothing to cast:

| | Keyed by the header line | Raw cells |
| :--- | :--- | :--- |
| **All at once** | `io.csv.maps(path)` → `Future<Sequence<Map<String, String>>>` | `io.csv.matrix(path)` → `Future<Sequence<List<String>>>` |
| **A row at a time** | `io.csv.records(path)` → `Stream<Map<String, String>>` | `io.csv.rows(path)` → `Stream<List<String>>` |

```dart
final records = await io.csv.maps('people.csv');     // Sequence<Map<String, String>>
final grid    = await io.csv.matrix('people.csv');   // Sequence<List<String>>

// Streaming, for a file larger than memory:
await for (final map in io.csv.records('big.csv')) {
  print(map['id']);
}
```

All four return nothing when the file does not exist. Blank lines are skipped, and short rows are padded with empty strings when reading maps.

The two eager readers hand back a [`Sequence`](util.md#sequence), so the report a script came for is the next call rather than an import:

```dart
final rows = await io.csv.maps('sales.csv');

rows.group((r) => r['region']!)
    .seq.to((e) => (region: e.$1, total: e.$2.sum((r) => util.text.number(r['amount']!) ?? 0)))
    .sort((e) => e.region)
    .each((e) => print('${e.region}  ${e.total}'));
```

---

## 2. Writing

`io.csv.write` takes records and writes them atomically through a `.part` staging file. Columns come from `headers`, or from the union of every row's keys in first-seen order:

```dart
await io.csv.write('out/people.csv', [
  {'name': 'Alice', 'role': 'admin'},
  {'name': 'Bob', 'role': 'user'},
]);
```

For data that is already a grid, `cells` renders it and `io.write` puts it on disk — also atomically:

```dart
io.write('out/grid.csv', io.csv.cells([
  [1, 'a'],
  [2, 'b'],
], headers: ['n', 'letter']));
```

The two used to be one method taking `Iterable<dynamic>`, which decided at runtime which shape it had been handed. Reading has always split the same way: `maps` for records, `matrix` for cells.

---

## 3. In-Memory Parsing & Formatting

```dart
final matrix = io.csv.parse('id,name\n1,"Alice, Chief"');
// [['id', 'name'], ['1', 'Alice, Chief']]

final csvText = io.csv.format([
  {'id': 1, 'name': 'Alice'},
  {'id': 2, 'name': 'Bob'},
]);
```

Quoting is applied automatically to any cell containing the delimiter, a quote, or a newline. Custom delimiters (e.g. `\t` for TSV) are supported via `delimiter: '\t'`.

### Line endings

`format`, `cells` and `write` end every line with `newline`, which defaults to `\n`. Pass `\r\n` for the ending Excel and RFC 4180 expect:

```dart
await io.csv.write('out/for-excel.csv', records.list, newline: '\r\n');
```

Reading handles either, so a file written one way reads back the same.

### Streaming out

`write` takes a collection already in memory. `pipe` takes a `Stream` of records and never holds more than one row, which is what turns a crawl of any size into a spreadsheet in one call:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  await io.csv.pipe(
    'products.csv',
    net.crawl<Map<String, Object?>>('https://shop.example.com/products'.url)
        .stream((res) {
          for (final row in res.parse(format.html).extract({
            'items': ['.product', {'name': '.name', 'price': '.price'}],
          })['items']! as List<Map<String, Object?>>) {
            res.emit(row);
          }
        }),
    headers: ['name', 'price'],
  );
}
```

A stream cannot be read twice, so the columns are settled before the first row is written: `headers` names them, and without it they are taken from the first row's keys. A later key the header line does not carry is dropped — pass `headers` when the rows are not all the same shape.

The file appears complete or not at all. Rows go to a `.part` staging file that is renamed into place when the stream closes, and discarded if it fails, so a crawl that dies halfway leaves no truncated CSV behind.

