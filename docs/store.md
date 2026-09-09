# Key-Value Storage (`io.store.*`)

A JSON-backed map for the state scripts need between runs: cursors, cached tokens, "last seen" markers.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final db = io.store.open('.cache/state.json');

  final lastId = db.get<int>('lastId', 0)!;
  db.set('lastId', lastId + 1);
  db.set('lastRun', util.time.iso());

  await db.save();
}
```

---

## 1. Independent Stores (`io.store.open`)

`open(path)` returns a `Store` loaded from that file, if it exists.

```dart
final db = io.store.open('cache.json');

db.get<String>('token');           // String?, null when absent
db.get<int>('visits', 0);          // falls back to 0
db.set('token', 'abc');            // value must be JSON-encodable
db.has('token');
db.delete('token');
db.clear();

db.length;
db.isEmpty;
db.all();                          // unmodifiable view
db.path;                           // the backing file, or null

await db.save();                   // atomic write
db.load();                         // discard changes, reload from disk
```

A read whose stored value has the wrong type returns the fallback rather than throwing:

```dart
db.set('theme', 'dark');
db.get<int>('theme', -1);   // -1
```

---

## 2. The Shared Store (`io.store`)

The accessor forwards to one process-wide `Store`, which is convenient for values several parts of a script touch:

```dart
io.store.set('runId', util.time.stamp());
io.store.get<String>('runId');
```

That shared store is **in-memory only** until you give it a file. `attach` does that, and returns the `Store` itself:

```dart
io.store.attach('.cache/shared.json');
io.store.set('runId', util.time.stamp());
await io.store.save();
```

Calling `io.store.save()` without attaching throws `StateError`, rather than silently discarding the data.

---

## 3. Resuming Work

Combined with a crawl, a store makes an interrupted run resumable:

```dart
final db = io.store.open('.cache/crawl.json');
final done = (db.get<List<dynamic>>('done', const [])!).cast<String>().toSet();

await net.crawl<String>('https://example.com/index')
    .run((res) {
      for (final link in res.$('a').hrefs) {
        if (done.contains(link)) continue;
        res.follow(link);
      }
      done.add(res.url.toString());
    });

db.set('done', done.toList());
await db.save();
```
