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

The core operations offer a simple matrix: `{read, stream, write} × {headers: true|false}`.

| Method | With `headers: true` (default for `read`) | With `headers: false` (default for `stream`) |
| :--- | :--- | :--- |
| `io.csv.read(path, {headers})` | `Future<List<Map<String, String>>>` | `Future<List<List<String>>>` (raw grid) |
| `io.csv.stream(path, {headers})` | `Stream<Map<String, String>>` | `Stream<List<String>>` (raw rows) |

```dart
// In-memory reads:
final records = await io.csv.read('people.csv');                  // List<Map<String, String>>
final grid    = await io.csv.read('people.csv', headers: false);  // List<List<String>>

// Streaming reads (memory-efficient for large files):
await for (final map in io.csv.stream('big.csv', headers: true)) {
  print(map['id']);
}
```

Both return an empty collection when the file does not exist. Blank lines are skipped, and short rows are padded with empty strings when reading maps.

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

