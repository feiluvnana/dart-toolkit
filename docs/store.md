# Lightweight Key-Value Storage Subsystem (`io.store.*`)

The `io.store` sub-namespace in **Dart Script Toolkit** provides persistent, file-backed JSON key-value storage for automation state, credentials, crawl cursors, and local caching.

All methods strictly adhere to the **1-word method naming convention**.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Open a persistent store file (auto-loads if exists)
  final db = io.store.open('.cache.json');

  // 2. Read, update, and write state
  final runs = db.get<int>('runs', 0)! + 1;
  db.set('runs', runs);
  db.set('last_run', util.time.iso());

  // 3. Atomically persist to disk (.part staging)
  await db.save();
  util.console.logger.ok('Run count incremented to $runs.');
}
```

---

## 1. Opening a Store (`io.store.open`)

### `final db = io.store.open(filePath)`
Creates an instance of `Store` bound to `filePath` (accepts `String` or `File`):
- If the file exists, automatically parses and loads its JSON contents.
- If the file does not exist, initializes an empty store.

```dart
final cache = io.store.open('.cache/pipeline.json');
```

---

## 2. Store Operations

Every `Store` instance provides simple 1-word methods:

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `db.get<T>(key, [fallback])` | `T?` | Retrieves value cast to `T`. Returns `fallback` if key is missing or not of type `T`. |
| `db.set(key, value)` | `void` | Associates `value` with `key` in memory. |
| `db.has(key)` | `bool` | Checks whether `key` exists in the store. |
| `db.delete(key)` | `void` | Removes `key` and its associated value. |
| `db.clear()` | `void` | Removes all keys and values from the store. |
| `db.save([filePath])` | `Future<File>` | Atomically writes formatted JSON to the file with `.part` staging. |
| `db.load([filePath])` | `void` | Reloads data from the backing JSON file. |
| `db.map()` | `Map<String, Object?>` | Returns an unmodifiable snapshot copy of the store. |

### Example
```dart
final db = io.store.open('settings.json');

db.set('theme', 'dark');
db.set('concurrency', 8);

if (db.has('theme')) {
  print('Theme: ${db.get<String>('theme')}');
}

// Save back to settings.json
await db.save();
```

---

## 3. Global Default Store

For simple scripts that only need in-memory temporary caching or quick shared access without managing explicit files, the `io.store.*` accessor acts as a default global store:

```dart
io.store.set('session_id', 'abc-123');
final id = io.store.get<String>('session_id');

if (io.store.has('session_id')) {
  io.store.delete('session_id');
}
```
