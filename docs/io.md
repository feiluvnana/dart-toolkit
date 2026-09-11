# File System & Paths (`io.*`)

The `io` domain provides atomic file writes, zero-dependency path manipulation, streaming downloads, recursive searches, filesystem watching and inter-process locking.

Paths are plain strings throughout. Given a `File`, pass its `.path`.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final dest = io.join('output', 'report.txt');

  if (!io.has(dest)) {
    io.write(dest, 'Generated at ${util.time.iso()}');
  }

  system.console.logger.ok('${io.base(dest)} is ${util.size.format(io.stat(dest).size)}');
}
```

---

## 0. Blocking and Non-Blocking

`io.*` is synchronous. `io.async.*` carries the identical set of names as
futures. One isolate runs every task in a crawl or a `Pool`, so a blocking read
inside a handler stalls every request in flight — reach for `io.async` there.

```dart
final blocking = io.read('notes.txt');            // blocks
final async = await io.async.read('notes.txt');   // does not
```

---

## 1. Atomic Writes

Every write stages into a `.part` sibling and renames it into place only after a successful flush, so an interrupted run never leaves a truncated file. The staging file is registered for cleanup on Ctrl-C.

`io.*` blocks; `io.async.*` is the same call without stalling the event loop.

| Method | Writes |
| :--- | :--- |
| `io.write(path, String content)` / `io.async.write(...)` | Text |
| `io.save(path, List<int> content)` / `io.async.save(...)` | Raw bytes |
| `io.dump(path, Object? data, {pretty = true})` / `io.async.dump(...)` | JSON |
| `io.async.download(url, path)` | A streamed HTTP response |

```dart
io.write('out/notes.txt', 'hello');
io.save('out/blob.bin', [1, 2, 3]);
io.dump('out/data.json', {'count': 42});                // indented
io.dump('out/data.json', {'count': 42}, pretty: false); // compact

// Inside a crawl handler or a pool worker, use the non-blocking mirror:
await io.async.write('out/notes.txt', 'hello');
```

`download` is network-bound, so it exists only on `io.async`.

---

## 2. Reading

| Method | Returns |
| :--- | :--- |
| `io.read(path)` | `String` (sync) |
| `io.async.read(path)` | `Future<String>` (async) |
| `io.bytes(path)` | `List<int>` (sync) |
| `io.async.bytes(path)` | `Future<List<int>>` (async) |
| `io.lines(path)` | `Stream<String>`, without loading the file |

```dart
await for (final line in io.lines('big.log')) {
  if (line.contains('ERROR')) print(line);
}
```

Reading a JSON *document* is [`format.json.read`](json.md), beside `format.yaml` and
`format.toml`: a format is knowledge from outside Dart, so all three live in one
family rather than one of them here.

```dart
io.dump('out/data.json', {'count': 42, 'hosts': ['a', 'b']});

final doc = await format.json.read('out/data.json');
doc.number('count');                    // 42
doc.at('hosts').texts();                // Sequence<String>
doc.jsonpath(r'$.hosts[*]');            // Sequence<Json>
```

`io.dump` stays here, because staging a write through a `.part` file is this
domain's job rather than the format's.

---

## 3. Existence

```dart
io.has(path);                 // exists AND holds at least one byte
io.has(path, match: true);    // also accepts a loosely-named sibling
io.similar(path);             // just the loose check
```

A zero-length file counts as **absent**, since an interrupted write can leave one behind.

> `io.similar` is deliberately fuzzy: it treats `cover.jpg` as present when `thumb_cover.jpg` exists, because either name is the other suffixed after an underscore. That can skip work you wanted done, so every caller defaults to *not* using it.

---

## 4. Paths

```dart
final p = io.join('parent', 'sub', 'file.mp3'); // platform separator
io.base(p);  // 'file.mp3'
io.name(p);  // 'file'
io.ext(p);   // '.mp3'
io.dir(p);   // 'parent/sub'
io.abs(p);   // absolute against the current directory
io.rel(p);   // relative to the current directory
io.rel(p, from: '/srv');
```

The facts about where a script is running, and the `~` nothing in `dart:io`
resolves:

```dart
io.cwd;                                  // the current working directory
io.home;                                 // $HOME, %USERPROFILE% on Windows
io.expand('~/.config/mytool/cfg.json');  // ~ only at the start, as a shell does
io.expand(r'$XDG_CACHE_HOME/mytool');    // $VAR and ${VAR}; unset expands to ''
```

These are one line of `package:path` or `Platform` each, which is the point:
they were absent, not hard, and their absence is what sent a script back to
`dart:io` for the least interesting reason available. The rest of the machine
is [`system.os`](system.md).

`io.sanitize` strips characters that are illegal in filenames:

```dart
io.sanitize('Key: "Box" / 20th?');             // 'Key_ _Box_ _ 20th_'
io.sanitize('Key: "Box" / 20th?', full: true); // 'Key：”Box” ／ 20th？'
```

`full: true` swaps in full-width look-alikes, which keeps titles readable.

---

## 5. Directories, Files & Metadata

```dart
io.mkdir('out/nested');       // creates parents
io.parent('out/nested/file.txt');   // creates the parent directory only

await io.async.mkdir('out/nested');
await io.async.parent('out/nested/file.txt');
final temp = io.temp('job_');       // a fresh temporary directory

// Copy and move work on both files and directories:
await io.copy(src, dest);
await io.move(src, dest);

// Single file deletion:
io.remove('out/temp.txt');

io.find('out', pattern: RegExp(r'\.mp3$'));   // List<File>
io.remove('out/report.pdf');                    // one file or directory
io.sweep('out', pattern: RegExp(r'\.part$'));   // every match; returns the count

// Hashes (sync and async):
io.hash(path);                      // sha256 hex digest (sync)
io.hash(path, Algo.md5);          // md5 (sync)
await io.async.hash(path);           // sha256 (async)

// File metadata (sync and async):
io.stat(path).size;
await io.async.stat(path);
```

`io.find` hands back a [`Sequence`](collection.md), so
filtering and grouping the result is the next call:

```dart
final logs = io.find('var/log', pattern: RegExp(r'\.log$'));
logs.collect(.count());
logs.collect(.max.by((f) => io.stat(f.path).size))?.path;      // the biggest one
logs.collect(.group.by((f) => io.ext(f.path)));
```

---

## 6. Watching (`io.watch`)

Rebuild-on-change, re-run-on-save, reload-the-config. Returns the function that
stops it — hold onto it, because a live watcher keeps the process alive:

```dart
final stop = io.watch(
  'lib',
  (changed) => system.console.logger.info('changed: $changed'),
  pattern: RegExp(r'\.dart$'),
  settle: 200.ms,
);

// ... later
await stop();
```

`settle` coalesces a burst of events for one path into a single call, which is
the part everyone hand-rolls wrong: an editor writes a file two or three times
per save, so the naive version fires three builds. Pass `Duration.zero` for
every raw event.

Only files are reported, filtered by `pattern` when one is given. A directory
created later is picked up either way — Linux watches one directory at a time,
so a recursive watch there is a subscription per directory, and hiding that
asymmetry is most of why this member exists.

Called `io.observe` through 4.0.0, because `system.watch()` meant *watch for
Ctrl-C* and two `watch`es meaning two unrelated things is exactly what Rule 5
is for. NAMESPACE.md recorded the compromise in as many words — *`observe` is
free, honest, and slightly less good than `watch`*. 5.0.0 moved signal watching
to `system.on.signals()`, where Rule 3 says it belongs, and took the better
name back.

---

## 7. Locking (`io.lock`)

The moment a script is good enough to put on a schedule, two copies of it
eventually run at once — a slow run overlapping the next tick, or a human
running it by hand while cron does. Atomic writes make the *file* safe; they do
not stop the *result* from being whichever process finished last.

```dart
await io.lock('.crawl.lock', () async {
  // exactly one process in here
  await net.crawl<Row>(seed).save('out.csv');
});
```

| Call | Behaviour |
| :--- | :--- |
| `io.lock(path, action)` | throws `LockedError` straight away if it is held |
| `io.lock(path, action, wait: 30.s)` | waits up to that long for its turn |
| `io.locked(path)` | whether a live process holds it — for a status line only |

The lock is released on a normal return, on a throw, **and on Ctrl-C**: a lock
file that outlives an interrupt is worse than no lock at all, because the next
run refuses to start. It rides the same registry that removes a half-written
`.part` file.

The file holds the pid and a timestamp, so a stale lock is diagnosable — and a
lock whose recorded process is gone is taken rather than obeyed. There is
deliberately no age cut-off: "older than an hour is stale" breaks the one run
that legitimately took ninety minutes.

`io.locked` is for reporting, not for deciding: between the check and the take,
another process can win. `io.lock` is the answer that cannot race.

---

## See Also

- [`io.csv.*`](csv.md) — CSV tables
- [`Sequence` and `Dictionary`](collection.md) — the collections, and `dump`/`io.dictionary`
- [`util.size.*`](util.md) — human-readable byte sizes
