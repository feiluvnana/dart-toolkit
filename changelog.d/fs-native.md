# fs / hash / native (and the ffi removal)

## Upgrading

| before | after |
|---|---|
| `import 'package:dart_toolkit/ffi.dart'` + `Ffi.open('sqlite3').call(...)` | a dedicated binding (`package:sqlite3`), or `dart:ffi`'s `DynamicLibrary.open(...).lookupFunction` for a one-off |
| `run('chmod +x $script')` / `Process.runSync('chmod', ['755', p])` | `await script.chmod('+x')` / `p.chmodSync('755')` |
| `archive.archiveEntries(password: pw)` | `archive.entries(password: pw)` |
| `Archive.of(name)`, `Archive.rar.isWritable`, `Archive.values` | gone: `archiveTo` reads the extension, and its `ArgumentError` lists the writable ones |
| `src.archiveTo('x.tar.gz', password: pw)` throws `ArgumentError` | throws `FormatException` ("tar has no encryption; write .zip or .7z for a password"), from the library, before anything is created |
| `src.archiveTo('x.rar')` throws `ArgumentError` | throws `FormatException` ("rar can only be read; write .zip or .7z instead") |
| `Hash.sha256.file(path)` | `File(path).hashBytes(Hash.sha256)` / `path.hashBytes(Hash.sha256)` |
| `NativeLib.version`, `NativeLib.expectedVersion` | gone: a library with the wrong ABI is refused at load and `NativeLib.reason` says which version it reported |
| `path.watch()` | `path.changes()` (debounced, yields `Path`s), or `path.asDir.watch()` for raw events |
| `final d = await Directory.systemTemp.createTemp('x'); try { … } finally { await d.delete(recursive: true); }` | `await Path.tempDir((d) async { … })` |
| `'${bytes} bytes'` | `bytes.humanBytes` (`'20.0 MB'`) |

## Removed

- `package:dart_toolkit/ffi.dart`, `lib/src/ffi/` (1067 lines), `test/ffi_test.dart` (397 lines) and `test/fixtures/ffi_probe.c`. Its wider-than-declared calls returned garbage on a wrong signature, and a script that calls C wants one specific library, which a dedicated binding does properly. README's FFI section and table row, GUIDE's `## ffi` section, contents entry, module-table row and *Call SQLite directly* cookbook entry, and the comments in `lib/dart_toolkit.dart`, `lib/native.dart` and `native.dart` are gone with it.
- `Archive` is private (`_Archive`, writable formats only in its error); the Dart copy of the rar and tar-password checks is deleted, and the library's own messages say what to write instead.
- `Hash.file` is private: `File.hashBytes` / `Path.hashBytes` and the `hmac` forms are the spelling.
- `NativeLib.version` and `NativeLib.expectedVersion`: the ABI check is the load-time refusal (NAT-3), nothing to ask afterwards.
- `Path.watch`, a pass-through to `File.watch`.

## Added

- `Path.tempDir((dir) async {…})`: a fresh directory under the system temp, deleted with everything in it after the body returns or throws; returns the body's result. A failed cleanup never replaces the body's result or error.
- `path.chmod(mode)` / `chmodSync(mode)`: octal (`'755'`, `'0600'`) or symbolic (`'+x'`, `'go-w'`, `'u=rw,go=r'`, `X`, `s`, `t`), chmod(1)'s own syntax, since Dart has no octal literal. One syscall through the new `tk_chmod`; on Windows only the owner-write bit means anything (read-only). A bad mode is a `FormatException`, a missing path a `FileSystemException`. The six `Process.runSync('chmod')` calls in the archive and fs tests use it.
- `int.humanBytes` in `lib/src/core/bytes.dart` (one `part` line in `core.dart`): `512 B`, `1.5 KB`, `20.0 MB`, `3.2 GB`, the exact format of `console.dart`'s private `_formatBytes`. `bin/tk.dart`'s four byte prints use it.
- Atomic `writeText`, `writeBytes`, `writeLines` and their Sync twins: a temporary sibling (`.name.<pid>.<µs>.<n>.tmp`) renamed over the target. An existing file keeps its mode (`tk_chmod`); a link keeps pointing where it did and the file it leads to is replaced; a read-only file still refuses (its write permission is asked first, since a rename would not); a device, FIFO, `/dev/null`, `/dev/stdout`, anything under `/dev/` or `/proc/`, and a dangling link are written in place; a folder that takes no new file falls back to writing in place. Without the native library an existing file is written in place (its mode could not be carried). Tests pin each case, including a reader that opened the old file still reading the old bytes.
- FS-4: `copy`/`copySync` give each copied directory its source's mode, deepest first after everything is in it (a read-only `0555` source directory copies too). Skipped on Windows and where the native library did not load.
- `tk_chmod` in Rust; `tk_version` and the Dart ABI are now **3**. All four prebuilts were rebuilt here (`cargo-zigbuild`/zig are installed). A v2 library is refused with "reported ABI version 2, expected 3".
- A test that `DART_TOOLKIT_NATIVE` is the only place looked when set and that a failure names the file (NAT-2), through `test/fixtures/native_reason.dart`.

## Fixed (verifying phase 2)

ARC-2…8, FS-1…3, HASH-1 and NAT-1…3 were in place. Two gaps closed:
- ARC-8: zip's `finish()` returned the `BufWriter` and dropped it, so a failed final flush of the central directory was swallowed. It is flushed explicitly now.
- `tk_archive_create` validated the format and the tar password only after making the destination's folder and walking the source; both are refused first now, and an unknown format code no longer reaches the end of the walk.

## Faster

Back-to-back A/B, alternating order, median of 6 process runs (each itself a median or mean of many in-process reps), JIT, macOS arm64 (10 cores). Base is `0b10471` with its own v2 library.

- P-HASH-1 (+P-RS-1): a file ≤ 4 MiB is read by the library on the calling isolate instead of `readAsBytes` and two copies. `file.hashBytes(Hash.xxh3)` 1 MiB: 454 → 97 µs. `Hash.sha256` 4 MiB: 2650 → 1435 µs. `Hash.sha256` 4 KiB: 72.5 → 28.0 µs.
- P-FS-1: directory `size()` walks in `Isolate.run` over a top-level `_dirSize`: 10k files in 100 folders 113 → 28 ms.
- P5: `duplicates()` lists once (`_walkSync` + `whereType<File>`) instead of `globSync('**')` plus a type stat per path: 10k files, 5k same-size pairs, 123.5 → 108 ms.
- P-RS-1: `Running::file` allocates `min(file length, 1 MiB)`, not 1 MiB per file. `Hash.sha256.filesSync` over 10k small files: 87 → 78 ms (median of 16, noisy under a loaded machine; minimums 77 → 73), and up to 1 MiB less memory per rayon worker per file.
- P-NAT-1: `inflate` yields `outView.sublist(0, w)` (already a copy) instead of copying it twice: 64 MiB gzip body in 64 KiB chunks 50 → 46 ms.
- P-RS-2: zstd `multithread(n)` and xz `MtStreamBuilder` once the input is ≥ 32 MiB (below that the threads cost more than they win, and xz's 24 MiB blocks would leave them idle). 96 MiB of log-like text: `compressTo('.zst')` 299 → 88 ms; `compressTo('.xz')` 48.3 → 15.7 s; `archiveTo('.tar.zst')` 285 → 81 ms. Output: `.zst` 33.42 → 33.29 MB, `.xz` 23.48 → 23.52 MB (+0.2%). A 34 MiB round-trip test covers both multi-threaded encoders. Dylib cost of `zstdmt` + `tk_chmod` together:

  | prebuilt | before | after | delta |
  |---|---|---|---|
  | macos_arm64 | 2,795,824 | 2,829,296 | +33,472 (+1.2%) |
  | macos_x64 | 3,169,988 | 3,215,596 | +45,608 (+1.4%) |
  | linux_x64 | 3,546,832 | 3,587,112 | +40,280 (+1.1%) |
  | linux_arm64 | 3,036,504 | 3,071,456 | +34,952 (+1.2%) |

  (macos_arm64 "before" rebuilt here from `0b10471`; the others are the prebuilts that were in the main checkout. linux still needs only GLIBC_2.30.)

Slower, on purpose: an atomic rewrite of an existing 1 KiB file costs 41 → ~170 µs (`writeTextSync`) and 79 → ~220 µs (`writeText`) on APFS. Creating the sibling (~65 µs) and the rename (~78 µs) are the price of never leaving half a file; the permission probe is ~19 µs.

## Skipped

- Converting the 49 `Directory.systemTemp.createTemp` sites to `Path.tempDir`: most are `setUp`/`tearDown` pairs, which a closure does not fit, and most live in other modules' tests. The new fs tests use it.
- `process_test.dart:164`'s `run('chmod +x …')` is the process module's test (it may be exercising `run` on purpose); left for that owner.

## CONVENTIONS (integrator applies)

- *Own namespaces*: already names only `chrome.dart` on master; nothing to do. (`lib/dart_toolkit.dart`'s comment now names `chrome.dart` where it named `ffi.dart`, and GUIDE's "Installing" line says "every module except `chrome.dart`".)
- *The native library* (line ~427): "It holds digests, MACs, archive formats, content-decoding and the WHATWG legacy charsets" → add "and `chmod`, which `dart:io` lacks".
- *The native library* (line ~437): "A small file is read by Dart and hashed in memory; a large one (> 4 MiB) is read by the library inside an isolate" → "Every file is read by the library: on the calling isolate up to 4 MiB, in a worker isolate above it — starting one costs about what SHA-256 takes over 4 MiB."
- New, under Robustness: **A write replaces, never truncates.** `writeText`/`writeBytes`/`writeLines` rename a finished sibling over the target, keeping its mode and links. *Why:* a ^C or a crash mid-write left half a config or cache that the next run parsed.
- New, under the native library: **An export changes the ABI.** Adding or changing a `tk_` function bumps `tk_version` and `NativeLib._abi` together and rebuilds all four prebuilts. *Why:* a stale prebuilt otherwise fails later with "Failed to lookup symbol" (NAT-3); with the bump it is refused at load, and `reason` says so.
