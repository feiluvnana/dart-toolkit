# CSV Tables (`io.csv.*`)

An RFC 4180-compliant reader, writer and streaming parser with zero external dependencies: quoted fields, escaped quotes, and CRLF or LF line endings.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // Read records keyed by the header line:
  final rows = await io.csv.maps('people.csv'); // List<Map<String, String>>
  for (final row in rows) {
    print('${row['name']} — ${row['role']}');
  }

  // Write records atomically:
  await io.csv.write('out/people.csv', rows);
}
```

---

## 1. Reading & Streaming

Four readers, one per corner of *keyed or raw* × *all at once or a row at a time*. Each one's return type says which it is, so there is nothing to cast:

| | Keyed by the header line | Raw cells |
| :--- | :--- | :--- |
| **All at once** | `io.csv.maps(path)` → `Future<List<Map<String, String>>>` | `io.csv.matrix(path)` → `Future<List<List<String>>>` |
| **A row at a time** | `io.csv.records(path)` → `Stream<Map<String, String>>` | `io.csv.rows(path)` → `Stream<List<String>>` |

```dart
final records = await io.csv.maps('people.csv');     // List<Map<String, String>>
final grid    = await io.csv.matrix('people.csv');   // List<List<String>>

// Streaming, for a file larger than memory:
await for (final map in io.csv.records('big.csv')) {
  print(map['id']);
}
```

All four return nothing when the file does not exist. Blank lines are skipped, and short rows are padded with empty strings when reading maps.

---

## 2. Writing

`io.csv.write` accepts both maps and rows of cells, writing to disk atomically through a `.part` staging file:

```dart
// Write maps (keys determine headers):
await io.csv.write('out/people.csv', [
  {'name': 'Alice', 'role': 'admin'},
  {'name': 'Bob', 'role': 'user'},
]);

// Write rows of cells with explicit headers:
await io.csv.write('out/grid.csv', [
  [1, 'a'],
  [2, 'b'],
], headers: ['n', 'letter']);
```

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

`format` and `write` end every line with `newline`, which defaults to `\n`. Pass `\r\n` for the ending Excel and RFC 4180 expect:

```dart
await io.csv.write('out/for-excel.csv', rows, newline: '\r\n');
```

Reading handles either, so a file written one way reads back the same.

