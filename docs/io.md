# File System (`io.*`, `io.path.*`, `io.dir.*`)

The `io` domain provides atomic file writes, zero-dependency path manipulation, directory listing and walking, filesystem watching and inter-process locking.

**`io` itself is about one file.** The two things that are not have namespaces of their own:

| | Holds | |
| :--- | :--- | :--- |
| `io.*` | asking what is at a path, reading it, writing it, moving it, removing it | one file at a time |
| `io.path.*` | `join`, `dirname`, `filename`, `stem`, `ext`, `parts`, `normalize`, `abs`, `rel`, `expand`, `sanitize` | touches no disk, so no `io.async.path` |
| `io.dir.*` | `make`, `makeparent`, `temp`, `list`, `walk`, `find`, `glob`, `sweep`, `cwd`, `home` | a vocabulary with its own nouns |

Creating a directory is not what `io` is mainly for, and neither is listing one. Rule 3 says a cohesive vocabulary with its own nouns gets its own name, and the split leaves `io` holding what it is actually about.

Paths are plain strings throughout. Given a `FileSystemEntry`, pass its `.path`.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final dest = io.path.join('output', 'report.txt');

  if (!io.has(dest)) {
    io.write(dest, 'Generated at ${util.time.iso()}');
  }

  system.console.logger.ok('${io.path.filename(dest)} is ${util.size.format(io.size(dest)!)}');
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
| `io.append(path, String content)` / `io.async.append(...)` | Text, onto the end |
| `io.touch(path)` / `io.async.touch(...)` | Nothing — creates it empty, or bumps its mtime |

```dart
io.write('out/notes.txt', 'hello');
io.save('out/blob.bin', [1, 2, 3]);
io.dump('out/data.json', {'count': 42});                // indented
io.dump('out/data.json', {'count': 42}, pretty: false); // compact

// Inside a crawl handler or a pool worker, use the non-blocking mirror:
await io.async.write('out/notes.txt', 'hello');
```

Every one of these returns a `FileSystemEntry` describing what was written.

**`append` is the one write here that is not atomic**, and it cannot be: appending adds to what is already on disk, so there is no staged copy to swap into place. An interrupted append can leave a partial line. When a file has to appear whole or not at all, build it and `write` it.

Downloading is [`net.http.download`](http.md), because a socket is `net`'s. `io.async.download` was a second spelling of it and went in 5.2.0.

---

## 2. Reading

| Method | Returns |
| :--- | :--- |
| `io.read(path)` | `String` (sync) |
| `io.async.read(path)` | `Future<String>` (async) |
| `io.bytes(path)` | `List<int>` (sync) |
| `io.async.bytes(path)` | `Future<List<int>>` (async) |
| `io.lines(path)` | `Sequence<String>` |
| `io.async.lines(path)` | `Stream<String>`, without loading the file |

```dart
io.lines('big.log')
    .transform(.where((line) => line.contains('ERROR')))
    .collect(.foreach(print));

await for (final line in io.async.lines('big.log')) {
  if (line.contains('ERROR')) print(line);
}
```

`io.lines` returned a `Stream` from **both** accessors through 5.1.0 — including from the one whose whole promise is that it blocks. One name, two shapes, each honest about which accessor it is on, is what the mirror was always supposed to mean.

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

## 3. Existence — one question per member

```dart
io.exists(path);    // anything at all: file, directory or link
io.isfile(path);    // ... and it is a regular file
io.isdir(path);
io.islink(path);
io.size(path);      // int?, null when there is nothing there
io.empty(path);     // exists and has nothing in it
io.stat(path);      // FileSystemEntry?, all of the above in one stat
```

Through 5.1.0 **the single most common filesystem question — does this path exist? — had no answer in the API.** `io.has` was the closest thing, and it is three questions fused into one:

```dart
io.has('a.txt');      // true   — a file with content
io.has('empty.txt');  // false  — a file that exists, with zero bytes
io.has('emptydir');   // false  — a directory that exists
io.has('nope.txt');   // false  — nothing there
```

Three of those `false`s mean different things and a caller could not tell them apart. A script writing `if (!io.has(dir)) io.dir.make(dir)` was correct by accident; one writing `if (io.has(out)) skip()` silently reprocessed every zero-byte file forever.

**`io.has` keeps its name and its meaning** — *a file exists and holds at least one byte* — because that composite is genuinely what a resumable script asks. What changed is that its three ingredients are now available on their own.

```dart
io.has(path);                 // exists AND holds at least one byte
io.has(path, match: true);    // also accepts a loosely-named sibling
io.similar(path);             // just the loose check
```

A zero-length file counts as **absent** to `io.has`, since an interrupted write can leave one behind.

The three kind questions are exclusive: a symlink is `islink`, never `isfile`, whatever it points at. And `io.empty` means *has nothing in it* — zero bytes for a file, no entries for a directory — so it is a different answer from `!io.exists(path)`, which is the distinction `io.has` could not make.

> `io.similar` is deliberately fuzzy: it treats `cover.jpg` as present when `thumb_cover.jpg` exists, because either name is the other suffixed after an underscore. That can skip work you wanted done, so every caller defaults to *not* using it.

---

## 4. Paths

```dart
final p = io.path.join('parent', 'sub', 'file.mp3'); // platform separator
io.path.filename(p);  // 'file.mp3'
io.path.stem(p);  // 'file'
io.path.ext(p);   // '.mp3'
io.path.dirname(p);   // 'parent/sub'
io.path.abs(p);   // absolute against the current directory
io.path.rel(p);   // relative to the current directory
io.path.rel(p, from: '/srv');
io.path.parts(p); // ['parent', 'sub', 'file.mp3']
io.path.normalize('out/./reports/../a.txt');   // 'out/a.txt'
```

Four of these are renames, and all four were named for the wrong half of what they did:

| Through 5.1.0 | Now | |
| :--- | :--- | :--- |
| `io.dir(path)` | `io.path.dirname(path)` | it returned the parent and read like it made one |
| `io.parent(path)` | `io.dir.makeparent(path)` | it *creates*; it read like it returns |
| `io.base(path)` | `io.path.filename(path)` | keeps the extension |
| `io.name(path)` | `io.path.stem(path)` | drops it |

`base` and `name` differed only in whether the extension survived, which neither word said. And the `dir`/`parent` swap was the sharp edge: renaming `parent` to mean *read* while `dir` meant *create* would have left every existing `io.parent(...)` call compiling — a call in statement position discards the result, so no test and no analyzer would have caught it quietly doing nothing. Both names moved to different namespaces instead, so every old call site fails to compile.

The facts about where a script is running, and the `~` nothing in `dart:io`
resolves:

```dart
io.dir.cwd;                                  // the current working directory
io.dir.home;                                 // $HOME, %USERPROFILE% on Windows
io.path.expand('~/.config/mytool/cfg.json');  // ~ only at the start, as a shell does
io.path.expand(r'$XDG_CACHE_HOME/mytool');    // $VAR and ${VAR}; unset expands to ''
```

These are one line of `package:path` or `Platform` each, which is the point:
they were absent, not hard, and their absence is what sent a script back to
`dart:io` for the least interesting reason available. The rest of the machine
is [`system.os`](system.md).

`io.path.sanitize` strips characters that are illegal in filenames:

```dart
io.path.sanitize('Key: "Box" / 20th?');             // 'Key_ _Box_ _ 20th_'
io.path.sanitize('Key: "Box" / 20th?', full: true); // 'Key：”Box” ／ 20th？'
```

`full: true` swaps in full-width look-alikes, which keeps titles readable.

---

## 5. Directories (`io.dir.*`)

```dart
io.dir.make('out/nested');                  // creates parents
io.dir.makeparent('out/nested/file.txt');   // creates the directory holding it
final temp = io.dir.temp('job_');           // a fresh temporary directory

await io.async.dir.make('out/nested');
await io.async.dir.makeparent('out/nested/file.txt');
```

Every `io` write already creates its own parent directory, so `makeparent` is for the write you are about to do with something that is not this library.

### Listing and walking

```dart
io.dir.list('out');                      // one level, everything
io.dir.list('out', only: .directory);
io.dir.walk('src');                      // the whole tree
io.dir.walk('src', match: '**/*.dart');  // a glob, not a RegExp
io.dir.walk('src', depth: 2);
io.dir.walk('src', follow: false);       // do not descend into symlinks
io.dir.glob('out/report-{2024,2025}.json');
```

`list` is one level and returns everything; `walk` is recursive. That is the split Python (`iterdir`/`walk`), Node (`readdir`/`readdir {recursive}`) and Go (`ReadDir`/`WalkDir`) all make, and through 5.1.0 this library made **neither**: `io.find` carried both on one member with a `recursive:` flag while silently dropping every directory it walked past. Listing a folder was not possible at all, and neither was finding a subdirectory, walking a tree yourself, or knowing whether an entry was a link before following it.

`match:` is a glob — `*` within one segment, `**` across them, `?` one character, `[abc]` a class, `{a,b}` an alternation. Through 5.1.0 the filter was a `Pattern` against the whole path, so the thing everyone reaches for, `*.csv`, was `RegExp(r'\.csv$')`.

A symlink pointing at one of its own ancestors would recurse until the stack ran out, so a following walk remembers which real directories it has entered and skips the second visit.

### Finding and sweeping

```dart
io.dir.find('out', pattern: RegExp(r'\.mp3$'));   // files only
io.remove('out/report.pdf');                      // one file or directory
io.dir.sweep('out', pattern: RegExp(r'\.part$')); // every match; returns the count
```

`find` stays, narrowed to what its name says — *find me the files matching this* — because "give me the mp3s" is a real question that should not become two calls. `io.remove` is the single entity; `io.dir.sweep` is the sweep.

Everything here hands back a [`Sequence`](collection.md) of `FileSystemEntry`, so filtering and grouping is the next call — and the entry already carries the size, so the loop does not re-stat every path:

```dart
final logs = io.dir.find('var/log', pattern: RegExp(r'\.log$'));
logs.collect(.count());
logs.collect(.max.by((f) => f.size))?.path;      // the biggest one
logs.collect(.group.by((f) => f.ext));
```

---

## 5a. `FileSystemEntry`

Everything that used to hand back a `dart:io` handle hands back one of these:

```dart
final entry = io.stat('out/report.csv');   // FileSystemEntry?, null when absent

entry!.path;       // where it is
entry.kind;        // .file | .directory | .link
entry.size;        // bytes; 0 for a directory
entry.modified;    // DateTime
entry.name;        // 'report.csv'
entry.stem;        // 'report'
entry.ext;         // '.csv'
entry.dirname;     // 'out'
entry.isfile;      // and isdir, islink, empty
entry.entity;      // the dart:io handle, for the call this does not cover
```

Seventeen signatures on `io` named `File`, `Directory`, `FileSystemEntity` or `FileStat` through 5.1.0 — four types whose API this library does not control, does not document and cannot change — and across the whole repository exactly **one** call chained off a returned handle, and **zero** assigned one to a typed variable. Rule 6 asks for real types at the boundary; it had only ever been applied to parameters.

It is a **snapshot**, not a handle: there is no descriptor and nothing to close, which is the property that lets every `io` call stay complete in itself. `entry.entity` is the one deliberate leak, the way `Json.raw` and `Markup.document` are — one documented door, so reaching for it shows up in review.

```dart
for (final entry in io.dir.list('out').iterable) {
  if (entry.isdir) continue;
  if (entry.ext == '.part') io.remove(entry.path);
  print('${entry.name}  ${util.size.format(entry.size)}  ${util.time.ago(entry.modified)}');
}
```

Every one of those lines used to be a separate `io.stat` or a `p.extension`.

---

## 5b. Metadata

```dart
io.hash(path);                // sha256 hex digest
io.hash(path, Algo.md5);      // md5
await io.async.hash(path);    // sha256, without blocking

io.size(path);                // int?
io.stat(path);                // FileSystemEntry?
await io.async.stat(path);
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

- [`format.csv.*` and `io.csv.*`](csv.md) — CSV
- [`Sequence` and `Dictionary`](collection.md) — the collections, and `dump`/`io.dictionary`
- [`util.size.*`](util.md) — human-readable byte sizes
