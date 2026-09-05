# CSV Serialization & Parsing Subsystem (`io.csv.*`)

The `io.csv` sub-namespace in **Dart Script Toolkit** provides RFC-4180 compliant CSV parsing, formatting, file reading, and atomic file writing.

All methods strictly adhere to the **1-word method naming convention**.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Read CSV directly into a list of maps using the header row
  final records = await io.csv.read('data/users.csv') as List<Map<String, String>>;
  for (final user in records) {
    print('${user['name']} <${user['email']}>');
  }

  // 2. Atomically write maps to a CSV file (uses .part staging)
  final data = [
    {'id': '1', 'name': 'Dart', 'active': 'true'},
    {'id': '2', 'name': 'Flutter', 'active': 'true'},
  ];
  await io.csv.write('output/results.csv', data);
  util.console.logger.ok('Saved CSV data successfully.');
}
```

---

## 1. Parsing & Formatting Strings

### `io.csv.parse(text, {String delimiter = ','})`
Parses raw CSV string into a 2D matrix (`List<List<String>>`), correctly handling:
- Escaped double quotes (`""` &rarr; `"`)
- Commas, quotes, and newlines embedded within quoted fields
- Both CRLF (`\r\n`) and LF (`\n`) row delimiters

```dart
const raw = 'name,role\n"Doe, Jane",admin\n"Smith, Bob",user';
final matrix = io.csv.parse(raw);
// [
//   ['name', 'role'],
//   ['Doe, Jane', 'admin'],
//   ['Smith, Bob', 'user']
// ]
```

### `io.csv.format(data, {List<String>? headers, String delimiter = ','})`
Converts structured data into an RFC-4180 compliant CSV string:
- **From Maps**: Pass a `List<Map<String, Object?>>` and the keys from the first map (or custom `headers`) will form the header row.
- **From Matrix**: Pass a `List<List<Object?>>` or `Iterable<Iterable<Object?>>` of rows.
- Automatically escapes fields that contain delimiters, quotes, or newlines.

```dart
final text = io.csv.format([
  {'title': 'Book 1', 'price': 19.99},
  {'title': 'Book 2', 'price': 29.99},
]);
```

---

## 2. Reading & Writing CSV Files

### `io.csv.read(filePath, {bool header = true, String delimiter = ','})`
Reads a local CSV file:
- `header: true` (default): Returns `Future<List<Map<String, String>>>` where map keys correspond to column names in the first row.
- `header: false`: Returns `Future<List<List<String>>>` containing the raw matrix including the first row.

```dart
// As List<Map<String, String>>
final items = await io.csv.read('items.csv');

// As List<List<String>>
final rawRows = await io.csv.read('items.csv', header: false);
```

### `io.csv.write(filePath, data, {List<String>? headers, String delimiter = ',', String part = '.part'})`
Atomically writes data (maps or matrix) to `filePath` with `.part` staging:
- Creates parent directories automatically.
- Writes to a temporary `.part` file first, then atomically renames upon completion.
- Guarantees that interrupted scripts won't leave corrupt or truncated CSV files on disk.

```dart
final rows = [
  ['ID', 'City', 'Country'],
  ['1', 'Tokyo', 'Japan'],
  ['2', 'Paris', 'France'],
];

await io.csv.write('cities.csv', rows);
```
