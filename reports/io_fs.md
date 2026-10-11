# Report · I/O & Filesystem (`lib/lib2/src/fs/io.dart`)

> Companion spec: [`../proposals/01_io.md`](../proposals/01_io.md). Dead-simple filesystem work
> through `File`, `Dir`, `Path`, `Link`, all on `Reader`/`Writer`.

---

## 1. Proposal promise (01:5–27)

`File.text()/bytes()/write()/copy()/move()/drop()/hardlink()/chmod()/atomic()/temp(ext:)`,
`Dir.make()/drop()/find('*.dart')/watch()/temp()`, `Path./ , isLink, target, resolve(), starts()`,
`Link.make(target:)/target/drop()`, and §4 advanced: atomic swap, zip-slip-safe `resolve()`+
`starts()`, live watcher pipeline.

## 2. Current `lib2` state

`lib/lib2/src/fs/io.dart` (358 lines): `Path`, `File`, `FileWriter`, `Dir`, `WatchEvent`,
`Link`, an internal `_glob` translating `*`/`?` only. `chmod` shells out to the `chmod` process.
`atomic()` writes a `tmp_<µs>` sibling then `rename`. `find` walks `list(recursive: true)`.

## 3. Gap analysis

| # | Proposal | `lib2` today | Severity |
|---|---|---|---|
| G1 | `Dir.find('*.dart')` recursive glob | ✓ `**` handling: `_glob` turns `*` into `[^/\\]*` — **`a/**/*.dart` does not work** (`**` = `[^/\\]*` twice, i.e. any single path segment, not zero-or-more dirs); no `[abc]`, `{a,b}`, `!`, escaping | MAJOR |
| G2 | `chmod(0755)` one-word permission set | `io.Process.run('chmod', ...)` — process spawn per call, no octal string→mode conversion needed (caller passes int), **Windows no-op**, and uses the raw dart:io | **BLOCKER** (native) |
| G3 | `File.atomic(data)` zero-downtime swap | ✓ exists but no `conflict:`; no Windows held-target retry (error 5/32, PLAN.md §4); no fsync | MAJOR |
| G4 | `copy` / `move` with progress & cancellation, "result in place before original gone" | `io.File.copy`/`rename` — no progress, not cancellable, `rename` over a held file fails on Windows | MAJOR (native) |
| G5 | `File` pipe-ability and **seek** for Range-resume | `File` implements `Reader/Writer/Closer` but **not `Seeker`**; `read` has an internal `_readPos` but no public `seek` | MAJOR (`core.md` G7) |
| G6 | `Path.isLink` / `Path.target` | ✓; `target` throws on non-link via `dart:io` | ok |
| G7 | `resolve()` + `starts(root)` safe-traversal | `resolve` doesn't follow-links into a canonical form you can prefix-compare; `starts` is a **string prefix** (no case normalisation, `..` not collapsed, Windows drive case) | MAJOR |
| G8 | `Dir.watch()` live events (`create/modify/delete`) | present; `WatchType.move` conflates; no **debounce**; dart:io `FileSystemMoveEvent` may not fire on some platforms | MINOR |
| G9 | `Link.make(target:)` / `drop` / hardlink | ✓ | ok |
| G10 | `File.temp`, `Dir.temp` | ✓ (unique under system temp) | ok |
| G11 | `File.write('/foo/bar')` creates parent? | NOT required by proposal — `write` does not create parents; keep. (Proposal's `Dir.make` covers it.) | ok |
| G12 | Typed errors (`PathNotFoundException`, `PathExistsException`, `MissingException`) | ✗ raw `dart:io` exceptions leak; conflict semantics absent | MAJOR |
| G13 | `Dir.find` returns paths in directory order, non-recursive option | proposal shows recursive only; no `only:`/`ignore:` filtering or `hidden:` control (those are legacy, not in the lib2 proposal) | MINOR |
| G14 | Symlink loop safety on `find` | `followLinks:false` ✓ | ok |

## 4. Native requirements (`native2`)

Everything below is reimplemented in `native2/engine` (parity with the FFI entries the legacy
engine already has); the task is the rewrite plus Dart wiring, with one addition:

| Behaviour | FFI | Note |
|---|---|---|
| `chmod(0755)` | `tk_chmod(path, len, mode)` (native/src/lib.rs:26) | Windows: read-only bit semantics as documented there |
| Copy with progress + stop | `tk_copy_file` (lib.rs:104) | gets source perms, removes dest on failure/stop |
| Cheap identity for `exists`-style checks | `tk_file_id` (lib.rs:50) | use for fast skip/change detection |
| Atomic rename over Windows-held target | **add `tk_rename(src,dst)`**: retry on error 5/32 with backoff (PLAN.md §4), then `MoveFileExW(MOVEFILE_REPLACE_EXISTING)` | new export → bump `dart_toolkit_native` ABI |
| Claims for single-writer locks | `tk_claim`/`tk_unclaim` (lib.rs:200/210) | process-wide exclusive names |

The proposal doesn't ask for *native watching*; keep `dart:io` watchers in Dart.

## 5. Actionable specification

1. **Extend the glob engine** to a real mini-glob supporting `**` (zero-or-more segments, refusing
   `..`), `*`, `?`, `[a-z]`, `{a,b}`, `\` escape — port the grammar in
   `lib/src/fs/glob.dart` (legacy), keep the regex cache. Add `Dir.find(pattern, {recursive: true,
   only:, ignore:, hidden:})` for feature parity with README but keep the lib2 surface small.
2. **Kill the `chmod` process spawn:** call `tk_chmod` via the native loader; fall back only to
   `UnsupportedError` when the library is missing (r50). Windows is covered by the FFI itself.
3. **`Seeker` on `File`** (`Future<int> seek(int offset)`), and `File.open` returns a reader
   already positioned for `bytes(start:, end:)` convenience used by resume.
4. **Atomic + rename paths use `tk_rename`** — `atomic()`, `move()`, and the archive/copy
   completion renames; Windows retries error 5/32.
5. **`copy`/`move` become `Task`s** that stream through `tk_copy_file` with a stop byte (cancel
   works), `done/fresh` reported via the `Work` model, and **the destination is complete before
   the source is touched** on `move` (rename-over after copy).
6. **Safe-traversal helpers:** after native resolve, compare **casefolded canonical** paths on
   Windows (`Path.equals`/`relativeTo` case rules per PLAN.md §6); `starts(root)` must use the
   same canonical form. Add the zip-slip pair:
   `Future<Path> sandbox(Path root, Path p) => p.resolve(); if (!x.starts(root)) throw SecurityException`.
7. **Typed errors:** wrap `dart:io` at the module boundary into `PathNotFoundException(path)` /
   `PathExistsException(path, conflict:)` / `MissingException(what, where:)`; a reading that finds
   nothing answers `or:` (r29,r32).
8. **Tests** (`test/fs_test.dart` for lib2): glob `**`; chmod case on POSIX + no-op parity on
   Windows; atomic-over-held-file retry (simulate with a second open handle); copy/move cancel
   leaves no half file; `seeker` resume matches a full read; symlink escape is refused in
   `unpack` (see `archive.md`).