# File System & Paths (`io.*`)

The `io` domain provides atomic file writes, zero-dependency path manipulation, streaming downloads and recursive searches.

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
final text = io.read('notes.txt');              // blocks
final text = await io.async.read('notes.txt');  // does not
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
| `io.json<T>(path, [parse])` | `T`, decoded from JSON (sync) |
| `io.async.json<T>(path, [parse])` | `Future<T>`, decoded from JSON (async) |
| `io.lines(path)` | `Stream<String>`, without loading the file |

```dart
final data = io.json<Map<String, Object?>>('out/data.json');
final asyncData = await io.async.json<Map<String, Object?>>('out/data.json');

// Pass a parser to build a real type, rather than casting the decoded maps
// and lists at every read. Without one, the decoded value is cast to T —
// which throws when the document is not the shape the call site claimed.
final config = io.json('config.json', Config.fromJson);

await for (final line in io.lines('big.log')) {
  if (line.contains('ERROR')) print(line);
}
```

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
```

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
io.delete('out', pattern: RegExp(r'\.part$')); // returns the count deleted

// Hashes (sync and async):
io.hash(path);                      // sha256 hex digest (sync)
io.hash(path, Algo.md5);          // md5 (sync)
await io.async.hash(path);           // sha256 (async)

// File metadata (sync and async):
io.stat(path).size;
await io.async.stat(path);
```

---

## See Also

- [`io.csv.*`](csv.md) — CSV tables
- [`io.store.*`](store.md) — JSON key-value storage
- [`util.size.*`](util.md) — human-readable byte sizes
