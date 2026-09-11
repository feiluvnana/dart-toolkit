# CSV (`format.csv.*`, `io.csv.*`)

An RFC 4180-compliant reader, writer and streaming parser with zero external dependencies: quoted fields, escaped quotes, and CRLF or LF line endings.

CSV sits in **two places**, and the split is the same one `format.zip.pack` and `io.write` already make:

| | Where | Why |
| :--- | :--- | :--- |
| Parsing and formatting CSV text | `format.csv` | A file format is a *subject* by Rule 1 — the same sentence that admitted `format.json`, `yaml`, `toml`, `html` and `zip`. CSV was the last one filed under the axis that happened to read the bytes. |
| Reading and writing a file **larger than memory** | `io.csv` | Not about CSV at all. It is about a document that does not fit, which is `io`'s problem. |

It was all `io.csv` through 5.1.0. 4.0.0 and 5.0.0 both deferred the move with the same worry — that splitting it would create two spellings for *read a CSV file*. The [`Codec`](util.md) seam 4.0.0 built is what answers it: `read` is inherited from `FileCodec` exactly as the other five formats inherit it, so there is one spelling.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // Read a whole file as a cursor:
  final sheet = await format.csv.read('people.csv');   // Csv

  sheet.maps.collect(.foreach((row) => print('${row['name']} — ${row['role']}')));

  // Shaping is the next call, not an import:
  print(sheet.maps.collect(.count.by((row) => row['role'] ?? '')));

  // Write records atomically:
  await io.csv.write('out/people.csv', sheet.maps.collect(.list()));
}
```

---

## 1. The `Csv` cursor

`format.csv.parse` and `format.csv.read` both hand back a `Csv`: a table with its header line separated from its rows. It is a pure value in `util`, beside [`Json`](json.md) and `Markup`, for the reason those are — `net` hands it back too, through `Codec`, and a type `net` needs cannot live under `format`.

| Member | Gives | |
| :--- | :--- | :--- |
| `headers` | `Sequence<String>` | the first line |
| `rows` | `Sequence<Sequence<String>>` | the data rows, as raw cells |
| `maps` | `Sequence<Map<String, String>>` | the data rows, keyed by `headers` |
| `column(name)` | `Sequence<String>` | one column, in row order |
| `count` | `int` | how many data rows |
| `empty` | `bool` | whether there are none |

```dart
final sheet = await format.csv.read('sales.csv');

sheet.headers.collect(.list());              // ['region', 'amount']
sheet.count;                     // 2
sheet.column('region').collect(.list());     // ['north', 'south']
```

`io.csv.maps` and `io.csv.matrix` were two methods for these two shapes, so you had to choose which to call before you had seen the file. They are two getters off one parse now — and `matrix` included the header line in what it returned, where `rows` does not, because `headers` is where it went.

A file genuinely without a header line gives up its first record to `headers`. For those, `Csv.raw(text)` keeps every line as a row.

Shaping is the next call, since everything here is a [`Sequence`](collection.md):

```dart
final sheet = await format.csv.read('sales.csv');

sheet.maps
    .collect(.group.into(
      (r) => r['region']!,
      .sum((r) => util.text.number(r['amount']!) ?? 0),
    ))
    .pairs
    .collect(.sort.by((e) => e.$1))
    .collect(.foreach((e) => print('${e.$1}  ${e.$2}')));
```

### Through the codec seam

Because `format.csv` implements `Codec<Csv>`, a response parses through it like any other format — which a crawl fetching a CSV export had no way to do before:

```dart
final sheet = res.parse(format.csv);
final rows  = res.parse(format.json).at('data');
```

---

## 2. Streaming, for a file larger than memory

`io.csv` keeps exactly the four members that are about the file rather than the format:

| | Keyed by the header line | Raw cells |
| :--- | :--- | :--- |
| **Reading** | `io.csv.records(path)` → `Flow<Map<String, String>>` | `io.csv.rows(path)` → `Flow<List<String>>` |
| **Writing** | `io.csv.write(path, rows)` | `io.csv.pipe(path, flow)` |

```dart
await io.csv.records('big.csv').collect(.foreach((map) => print(map['id'])));
```

A `Flow`, not a `Stream`, so the whole `Transformer`/`Collector` vocabulary reaches a file too large to hold — see [collection.md](collection.md).

Both readers yield nothing when the file does not exist. Blank lines are skipped, and short rows are padded with empty strings when reading records.

There used to be **two independent parsers** behind these — a fast code-unit one for whole files and a character-at-a-time one for streams. 5.0.0 proved they agreed on all fifteen awkward inputs it tested, which was the precondition for merging them rather than a substitute for it: two parsers that agree today are two parsers that drift at the next bug fix. There is one state machine now, driven two ways.

---

## 3. Writing

`io.csv.write` takes records and writes them atomically through a `.part` staging file. Columns come from `headers`, or from the union of every row's keys in first-seen order:

```dart
await io.csv.write('out/people.csv', [
  {'name': 'Alice', 'role': 'admin'},
  {'name': 'Bob', 'role': 'user'},
]);
```

For data that is already a grid, `format.csv.cells` renders it and `io.write` puts it on disk — also atomically:

```dart
io.write('out/grid.csv', format.csv.cells([
  [1, 'a'],
  [2, 'b'],
], headers: ['n', 'letter']));
```

`format` and `cells` are two methods and not one taking `Iterable<dynamic>`, because deciding which shape you were handed at runtime is how a typo becomes an empty file.

---

## 4. In-Memory Parsing & Formatting

```dart
final sheet = format.csv.parse('id,name\n1,"Alice, Chief"');
sheet.headers.collect(.list());               // ['id', 'name']
sheet.maps.collect(.list());                  // [{'id': '1', 'name': 'Alice, Chief'}]

final csvText = format.csv.format([
  {'id': 1, 'name': 'Alice'},
  {'id': 2, 'name': 'Bob'},
]);
```

Quoting is applied automatically to any cell containing the delimiter, a quote, or a newline. Custom delimiters (e.g. `\t` for TSV) are supported via `delimiter: '\t'`, and a delimiter may be more than one character. The UTF-8 BOM Excel writes is stripped, because left in place it glues itself to the first header and makes `row['name']` answer null for a file that plainly has a `name` column.

Text that is not CSV parses to the empty cursor rather than throwing — the contract every reader in this library keeps.

### Line endings

`format`, `cells` and `write` end every line with `newline`, which defaults to `\n`. Pass `\r\n` for the ending Excel and RFC 4180 expect:

```dart
await io.csv.write('out/for-excel.csv', records.collect(.list()), newline: '\r\n');
```

Reading handles either, so a file written one way reads back the same.

### Streaming out

`write` takes a collection already in memory. `pipe` takes a `Flow` of records and never holds more than one row, which is what turns a crawl of any size into a spreadsheet in one call:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  await io.csv.pipe(
    'products.csv',
    net.crawl<Map<String, Object?>>('https://shop.example.com/products'.url)
        .flow((res) {
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
