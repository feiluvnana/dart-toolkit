# NOBRAIN run log

## 1. TESTS (c6beaf1..)
- Baseline: 518 tests, 26 s, 75.5% lines, 0 flakes in 10 runs. Added cover for merging `Dir.copy`, the retry matrix and `filename*` decoding (527 tests).
- One `runDart` child runner in test/support replaces five spawn copies; nothing is written into the repo; the live-tee test checks the tee in a child.
- pty and Chromium tests are tagged; `dart test -P quick` = 472 tests in 8 s, the full suite stays 25 s (pty files are the critical path).
- Deferred: precompiling pty probes to kernel (~0.2 s each), revert-the-fix audits of old regression tests, `Shell.open` and `userCacheDir` (platform-only branches).

## 2. BUGPERF (b357d06..d7dd8ef, 15 commits)
- 4 read-only audits (http/scrape, fs/archive/shell, console/tui, core/pool/html/chrome) found 37 verified issues; 18 fixed with regression tests that fail without the fix.
- Speed: a merging `Dir.copy` of 4k files went from 10.7 s to 1.0 s (one walk, folder metadata batched by stamp/mode). Liveness: a cancelled crawl, `Shell.open`, a writer that never reads, and piped `Console.ask` no longer keep the VM alive.
- Correctness: per-chunk upload stalls, HEAD/204 keep-alive, typed bad redirects, shared concurrent reads, Pool close race, Tui cursor-only moves, prompts answered on quit, burst keys in `choose`, archive collisions checked before the merge, chmod after the merge, AppleDouble and V7 tars.
- Deferred (verified, not fixed): A5 redirect `#frag` double visit; B2 pack includes the writer's own temp file; B9 `sortByRelative` cost; C2 long-line `Region.write` O(n²); C4 popups split wide chars; C6 one-line input does not scroll to the cursor; C7 typing bursts O(n²); C9 combining-mark widths; C10 diff memo/table/paste search; D2 piped reader loses the charset; D3 `not()` ignores ancestors; D4 XML prolog parsed as a fragment; D5 Hasher cancelled before start; D7 connected `Browser.close` leaves tabs; D8 WHATWG charset gaps; D9 `Json.value<int>` of 2^63; D10 image decode extra copy.

## 3. SECURITY (aad8da1..4d2190d, 18 commits)
- 4 deferred stage-2 bugs first (A5 fragment revisit, D9 Json 2^63, D10 image copy, D7 connected-browser tabs); then 3 audits (injection, paths/secrets, network/resources) found 23 issues, 14 fixed with tests.
- Fixed: archive modes through umask and never on existing folders; `Dir.copy` never follows a dest folder link; atomic temps take the old mode before any byte; terminal sanitising (C1, bidi, OSC in prompts/log/notify/popup/CLI errors; SGR kept); redirects drop custom secret headers; URLs redacted in errors; crawl credentials scoped to start origins; cache keyed by credentials and 0700; `Shell.open('-a…')`; deep HTML `text()`; markdown hostile-input cost; ICO pixel cap; `.`/`-` network names.
- Over budget by 3 (the stage-2 carry-overs). Deferred: gzip bomb / body size cap and total deadline (need an API: `maxBytes:`/`deadline:`), Chrome `open(headers:)` leaking to third-party subresources (needs interception), `Page.html/text/run` with no timeout, `Page.run` without `args:`, zip unpack size/member caps, unclosed-tag O(n²) in package:html, selector/JSON-path value escaping, page `<base>` overriding the script's base, Windows .bat quoting (PLAN §1), CDP port open to local processes.

## 4. PLATFORM (766fc7a..4969284, 10 commits)
- Fixed on this Mac: TERM=dumb (no escapes, Tui refuses), Unicode 16 zero-width table, 255-byte names (temp suffix), Shell children killed when a signal ends the script, kitty lock bits/keypad/horizontal wheel/X10 mouse, narrow live lines, Console ASCII glyphs under LANG=C, NO_COLOR keeps motion, piped-stdin Tui reads /dev/tty, NFC/NFD archive members.
- Handed off: PLAN §1 W7 (console close hooks), W8 (UTF-8 glyphs on Windows), W9 (rename retries); §2 L1 rewritten (foreground xdg-open), L2 (Chromium on arm64). W3 already covers .bat quoting.
- Matrix: macOS fs/archive/shell/terminal ok after fixes; Linux shell L1 + chrome arm64 handed off, BusyBox `touch -d @s.frac` unknown; Windows exit/caps/rename handed off, winconsole unknown (W1).
- Deferred: `exit()` inside a handler leaves the tty broken (doc it in DOCS); Console prompts invisible when only stderr is redirected; Tui ASCII mode still leaks ✗ ❯ • …; ctrl/shift+F1-F4 (`CSI 1;5P`), rxvt `ESC ESC [A`, paste end search O(n²).

## 5. ARCHITECTURE (3213082..ebffb90, 8 commits + ARCHITECTURE.md)
- ARCHITECTURE.md: import graph (no cycles), startup per module, dependency table, 10 findings, migration order.
- Startup (A/B): scrape 1.77 s → 0.82 s (no chrome import; `src/tabs.dart`), image 1.12 s → 0.99 s (`Region.picture` via `src/pixels.dart`, adds `Image.pixel`), archive 0.53 s → 0.24 s (in-house zip, package:archive dropped; zip pack also 15% faster), cli 0.23 s → 0.19 s (`src/sanitize.dart`).
- Pure refactors: one tree copy (`src/tree.dart`) for fs and archive; `_Unpacker.consume` split into `_Extraction`. Unused `http` dependency dropped.
- Deferred: an in-house HTML parser (~0.7 s off every scrape/chrome script; L, own stage), splitting `tui/session.dart`, pinning html/csslib.

## 6. ERGONOMIC (476bb69..cb22087, 9 + 12 user-directed commits)
- User-directed mid-stage: `Archive.archive(paths, {format, dir, password})` / `unarchive(dir, {password})` replace pack/unpack; zip AES-256 (write) + AES/ZipCrypto (read); 7z read (LZMA/LZMA2/PPMd/Deflate/BCJ/AES) and write (Deflate, AES with hidden names); RAR5 and RAR4 read (filters, solid, PPMd, AES) — all pure Dart, fixtures from libarchive; pointycastle measured (+370 ms startup) and not taken. The user removed examples/ (acda85c): the gate is `dart analyze lib test projects tool`.
- Audit fixes: an unread response no longer keeps the VM alive (60 s → 0 s, 64 KB prefetch); `retries:` honoured on every verb; a ticked bar closes at its total; network/TLS errors name the request; `insecure:` lists trusted hosts; `Shell.run(check:)`; `Image.sniff` → `ImageFormat` (+ read-only webp); `archive(dir:)`.
- Deferred: public names for `TabHost`/`Pixels` (doc lines in DOCS instead), `Fs.safe(name)` (FEATURE), `attrs` alternatives, `Http.client`, label/`setTotal`/accent naming, 7z LZMA encoder, BCJ2/bzip2/xz, PPMd speed (~5 MB/s).

## 7. FEATURE (676267d..pool rewrite, 12 commits + PROPOSAL.md)
- PROPOSAL.md: 12 missing tasks ranked, redundant members, module verdicts (no YAML/glob/sqlite: startup or native), gaps, defaults, do-next with decisions.
- Done: `.tar.xz` in unarchive, `Reader.lines()`, `query:` on the verbs, `Fs.sanitize(name)` (named at the user's request), GET/HEAD `retries: 2` + `Pool.map` `limit: 4`, `Opt(env:)`, `Console.notify/copy` (App's removed), a 100 ms idle grace (20 → 1 connections for a sequential download loop), a process cookie jar (form login now works), `Pool.runAll` on `Isolate.run` (worker_manager, `Pool.run`, `Pool.close` dropped; pool startup 0.32 → 0.18 s).
- From here every commit is also pushed (user's request); gh switched back to feiluvnana once.
- Deferred: `Http.send` merge (skipped: `Http.put` is easier to find), `Reader.from(stream)`, `Console.table`, `Fs.temp`, `Entry.modified`, `Shell.run(timeout:)`, prefer an installed Chrome.

## 8. DOGFOOD (B1 fix..DOGFOOD.md, 9 commits + DOGFOOD.md)
- Five scripts (mirror, sync CLI, Tui dashboard, listing scrape, release install) on the library alone; code lines 248 → 204 after the fixes.
- Bugs fixed: `Http.hold()` as a script's first call kept it alive 15 s (every crawl; my stage-6 regression); tgz unarchive stopped at the tar marker (truncated .tar.gz extracted, hashes upstream incomplete); `retries:` + `Body.stream` silently one try.
- Added: `Hash.sha256(expect:)` + `Hasher.of`, `Shell.run(onLine:)`, `follow(under:, skip:)`, `crawl(onProgress:)`, `path(from:)` (always `/`).
- Deferred: `Console.table`, `Pool.map(onError:)`, a missing JSON file reading as null, hash mismatch naming its subject, `Bar` wiring for `onProgress`; not doable: `Json.encode` of records; kept: `exitCode` set by the caller.

## 9. DOCS (dart doc refs..doc comments, 6 commits)
- `dart doc` 7 → 2 warnings (both harmless canonicalization notes); README for pub.dev (tour compiled by `dart analyze`), CHANGELOG for 0.0.4.
- A 3-way audit compiled every VISION and library-doc snippet: 4 did not compile (`json:` on post, a `Reader` as `body:`, `from:` for `dir:`, `const Color.index`); all fixed.
- VISION synced: `Body`, `Origin`, `Json.of`, `texts`, `pixel`, the http engine (`dart:io`), import graph, tables and the named-parameter list; doc comments state rules (history notes and issue ids removed), and missing docs were added.
- Code: `Hasher.add(text)`. `Page.scroll(selector, timeout)` stays positional (Dart has no optional-positional + named mix).
- Deferred: `Color.code`/`rgb` are public fields (rule 2), `TabHost`/`Pixels` unexported in public signatures.

## 10. RELEASE (pubspec..format, 3 commits)
- `dart pub publish --dry-run`: 0 warnings; pana 150/160 (the 10 lost: no example/, which the user removed).
- pubspec: a 148-char description, repository, topics, platforms linux/macos/windows (dart:io, no web); dependencies already at their latest, and `pub downgrade` analyzes clean.
- `.pubignore`: the archive is lib + README/CHANGELOG/VISION/ARCHITECTURE/LICENSE (660 → 403 KB); one `dart format` pass at width 120.
- Version stays 0.0.4 (the CHANGELOG section); not published. Manual steps: `dart pub publish`, tag `v0.0.4`, GitHub release notes from CHANGELOG, optionally a verified publisher.
