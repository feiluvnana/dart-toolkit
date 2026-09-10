# Key-Value Storage (`io.store.*`)

A JSON-backed map for the state scripts need between runs: cursors, cached tokens, "last seen" markers.

Keys are `Slot`s, not strings. A slot names the key *and* its type, so writing is checked and reading needs no cast.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

const lastId = Slot<int>('lastId');
const lastRun = Slot<String>('lastRun');

void main() async {
  final db = io.store.open('.cache/state.json');

  db.set(lastId, (db.get(lastId) ?? 0) + 1);
  db.set(lastRun, util.time.iso());

  await db.save();
}
```

---

## 1. Slots

A `Slot<T>` is a typed key. Declare it `const`, once, beside the code that uses it:

```dart
const token = Slot<String>('token');
const visits = Slot<int>('visits');
const tags = Slot<List<Object?>>('tags');
```

Both ends are then checked. `db.set(visits, 'many')` does not compile, and `db.get(visits)` is an `int?` without a cast in sight. Two parts of a script can no longer disagree about how a key is spelled, because they share the one declaration.

`T` must be something `jsonEncode` accepts: a string, number, bool, list or map. For anything else, `Slot.coded` says how it converts:

```dart
const since = Slot<DateTime>.coded('since', read: _readTime, write: _writeTime);

DateTime? _readTime(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;
Object? _writeTime(DateTime value) => value.toIso8601String();
```

`read` and `write` have to be top-level or static functions for the slot to stay `const`.

The same `Slot` type is what a crawl's `meta` uses — see [crawl.md](crawl.md#5-carrying-context-between-stages).

---

## 2. Independent Stores (`io.store.open`)

`open(path)` returns a `Store` loaded from that file, if it exists.

```dart
final db = io.store.open('cache.json');

db.get(token);                     // String?, null when absent
db.get(visits) ?? 0;               // the fallback goes at the call site
db.set(token, 'abc');
db.has(token);
db.delete(token);
db.clear();

db.length;
db.isEmpty;
db.all();                          // unmodifiable view of the raw map
db.path;                           // the backing file, or null

await db.save();                   // atomic write
db.load();                         // discard changes, reload from disk
```

A read whose stored value is not the shape the slot names comes back `null` rather than throwing. That is what keeps a schema change from taking down the next run:

```dart
db.set(token, 'dark');
db.get(const Slot<int>('token'));   // null
```

---

## 3. The Shared Store (`io.store`)

The accessor forwards to one process-wide `Store`, which is convenient for values several parts of a script touch:

```dart
const runId = Slot<String>('runId');

io.store.set(const Slot<String>('runId'), util.time.stamp());
io.store.get(runId);
```

That shared store is **in-memory only** until you give it a file. `attach` does that, and returns the `Store` itself:

```dart
io.store.attach('.cache/shared.json');
io.store.set(const Slot<String>('runId'), util.time.stamp());
await io.store.save();
```

Calling `io.store.save()` without attaching throws `StateError`, rather than silently discarding the data.

---

## 4. Resuming Work

Combined with a crawl, a store makes an interrupted run resumable:

```dart
const done = Slot<List<Object?>>('done');

final db = io.store.open('.cache/crawl.json');
final seen = (db.get(done) ?? const []).cast<String>().toSet();

await net.crawl<String>('https://example.com/index'.url)
    .run((res) {
      for (final link in res.parse(format.html).find('a').attrs('href').list) {
        if (seen.contains(link)) continue;
        res.follow(link);
      }
      seen.add(res.url.toString());
    });

db.set(done, seen.toList());
await db.save();
```

For a crawl that has to survive being interrupted mid-run rather than between runs, `net.crawl(...).resume(path)` carries the frontier as well as the visited set — see [crawl.md](crawl.md).
