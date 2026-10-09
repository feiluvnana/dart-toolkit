# Module Proposal 10: Collections & Data Tables (`lib/collection.dart`)

## 1. Overview & Vision

The Collection module provides terminal data tables, CSV/Markdown export formats, and functional data manipulation extensions for `Iterable` and `Map` collections.

### Core Problems in the Existing API
1. **Manual List-of-Lists Transposition**: Rendering a `Table` requires manually extracting fields from objects and formatting them into `List<List<String>>`.
2. **Missing Export Formats**: No built-in way to export a `Table` to standard Markdown tables or CSV files.
3. **Missing Collection Operators**: Standard grouping (`groupBy`), windowing (`chunked`, `sliding`), and aggregation (`distinctBy`, `sumBy`) require custom boilerplate.

---

## 2. Detailed Before vs After Comparison

### 2.1 Declarative Object Tables

#### Before:
```dart
final users = [
  User(id: 1, name: 'Alice', role: 'Admin', score: 98.5),
  User(id: 2, name: 'Bob', role: 'Editor', score: 84.0),
];

// Manual transposition
final headers = ['ID', 'Name', 'Role', 'Score'];
final rows = users.map((u) => [
  u.id.toString(),
  u.name,
  u.role,
  '${u.score}%',
]).toList();

Table.cells(headers, rows).show();
```

#### After (Proposed):
```dart
// 1. Declarative typed projection from objects
Table.from(users, columns: {
  'ID':    (u) => u.id,
  'Name':  (u) => u.name.bold,
  'Role':  (u) => u.role == 'Admin' ? u.role.green : u.role.dim,
  'Score': (u) => '${u.score}%',
}).show();

// 2. Declarative table from Map<String, dynamic> records
Table.fromMaps([
  {'Package': 'http', 'Version': '1.2.0', 'Status': 'OK'},
  {'Package': 'cli', 'Version': '2.0.1', 'Status': 'Deprecated'},
]).show();
```

##### Visual Look (Terminal Render):
```text
┌────┬─────────┬────────┬────────┐
│ ID │ Name    │ Role   │ Score  │
├────┼─────────┼────────┼────────┤
│ 1  │ Alice   │ Admin  │ 98.5%  │
│ 2  │ Bob     │ Editor │ 84.0%  │
└────┴─────────┴────────┴────────┘
```

---

### 2.2 Table Export Formats (Markdown & CSV)

#### Before:
```dart
// No built-in export helpers
```

#### After (Proposed):
```dart
final table = Table.from(users, columns: {
  'ID':   (u) => u.id,
  'Name': (u) => u.name,
  'Role': (u) => u.role,
});

// 1. Export as GitHub-flavored Markdown
final markdown = table.toMarkdown();
await Path('report.md').writeText(markdown);

// 2. Export as CSV
final csv = table.toCsv();
await Path('report.csv').writeText(csv);
```

---

### 2.3 Rich Collection Extensions

#### Before:
```dart
// Grouping items manually
final grouped = <String, List<Item>>{};
for (final item in items) {
  grouped.putIfAbsent(item.category, () => []).add(item);
}
```

#### After (Proposed):
```dart
// Standard functional extensions on Iterable
final grouped   = items.groupBy((x) => x.category);          // Map<K, List<V>>
final batches   = items.chunked(25);                         // List<List<T>>
final windows   = items.sliding(3);                          // Sliding window of size 3
final unique    = items.distinctBy((x) => x.email);          // De-duplicated list
final totalCost = items.sumBy((x) => x.price * x.quantity);  // Total sum
final countByTag = items.countBy((x) => x.tag);              // Map<Tag, int>
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Table Construction** | Manual list-of-lists mapping | `Table.from(items, columns: {...})` | Type-safe, declarative |
| **Export Formats** | Terminal output only | `.toMarkdown()`, `.toCsv()` | Automated reporting |
| **Collection Helpers** | Manual loops & maps | `groupBy`, `chunked`, `distinctBy`, `sumBy` | Standard functional toolkit |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- `Table.from(...)` evaluates column getters per item. For massive datasets (>100,000 items), `Table.cells` with pre-computed string buffers remains available for maximum raw throughput.

### Backward Compatibility:
- 100% backward compatible. `Table.cells`, `Table.rows`, and all existing table formatting methods continue to work.
