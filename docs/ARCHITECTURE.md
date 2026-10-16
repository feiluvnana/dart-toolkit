# Architecture

Structure, not features: module edges, startup cost, dependencies and the seams that hold the library together. Startup numbers are JIT `dart run` of a script that only imports the module, as the median of three back-to-back deltas against `void main() {}` (141 ms) on an M-series Mac. The machine drifts ±80 ms, so compare with A/B runs, never with a number from another day.

## Import graph

```
core ─────────────── src/resume, src/cookies, src/format, src/progress, src/rate, src/time
json ─────────────── core, src/names
hash ─────────────── core, src/resume (+crypto)
csv ──────────────── core
yaml ─────────────── json, src/names, src/yaml_parser
pool ─────────────── core, src/format, src/progress, src/rate, src/retry
fs ───────────────── core, src/exit, src/format, src/glob, src/names, src/posix, src/progress, src/tree (+path)
shell ────────────── core, src/exit, src/names, src/progress, src/quiet, src/timeout
archive ──────────── src/tar (part file) → core, shell, src/exit, src/format, src/posix, src/progress, src/tree, src/tool, src/unpack, src/zip, src/sevenzip, src/rar, src/xz (+path)
http ─────────────── core, src/charset, src/cookies, src/origin, src/posix, src/rate, src/resume, src/retry, src/timeout
html ─────────────── json, src/dom, src/html_parser, src/selector
image ────────────── core, src/media, src/pixels (+path)
cli ──────────────── core, src/sanitize
console ──────────── core, src/exit, src/format, src/keys, src/logbook, src/progress, src/terminal
tui ──────────────── src/tui (part files) → core, src/exit, src/format, src/keys, src/logbook, src/pixels, src/progress, src/terminal
video ────────────── image, src/format, src/media, src/media_proxy, src/progress (+path)
chrome ───────────── core, html, src/cdp, src/chrome_find, src/cookies, src/exit, src/format, src/glob, src/keys, src/names, src/origin, src/progress (+path)

src/media ── shell, src/cache, src/posix, src/quiet, src/tool        src/tool ── shell, src/cache, src/names, src/posix (+path)
src/chrome_find ── src/cache, src/cdp        src/cache ── src/download_line (+path): the user cache and fetchInIsolate
src/download_line ── src/bridge, src/format: a first-use download's live line or status-row bar
src/progress ── src/format: Probe, Task, Meter and the private run that feeds them
src/fetch ── archive, http, hash, fs: spawned by URI, never imported
src/unpack ── names (+path): member checks and link placement shared by every extraction
src/posix ── SDK only        src/tree ── posix (+path)        src/terminal ── bridge, format, sanitize, width, keys_decode, winconsole
src/logbook ── SDK only: every Console.log line, which console writes and tui's Region.log draws
src/zip, src/xz ── aes, bcj, crc32, lzma (+crypto)   src/sevenzip, src/rar ── aes, bcj, budget, crc32, lzma, ppmd, zip (+crypto)
```

No import cycles between modules. Cross-module edges are the compositions the API promises: `chrome → html` (a page's `html()`/`json()`), `html → json` (`Elements.json()`), `yaml → json` (a YAML document is a `Json`), `video → image` (`frame()`). `archive → shell` runs 7-Zip. The one-time downloads (`src/fetch`) need http and archive, so they run in an isolate spawned by URI (`src/cache.dart` `fetchInIsolate`): a deferred import still compiles them at startup under `dart run`. The 7z/RAR/xz decoders stay imported by `archive`: a URI isolate per extraction would cost 240–380 ms each time (PLAN.md O2).

## Startup per module

Each module imported alone, as the median of 7 runs minus an empty script's (141 ms), 2026-10-16 on an M-series Mac. The machine drifts ±80 ms: compare with back-to-back A/B runs, never with these numbers on another day.

| import | ms | what it costs |
|---|---|---|
| core, csv, json, pool, shell, hash | 62–75 | — |
| yaml, cli | 88–89 | in-house YAML parser; option parsing |
| fs | 103 | path |
| html, console, http | 119–127 | parser and selectors; terminal; charset tables |
| video | 165 | ffmpeg glue, the loopback header proxy |
| image | 188 | ffmpeg glue, header readers |
| tui | 227 | widgets and markdown |
| chrome | 257 | the DevTools client, re-exports html |
| archive | 266 | in-house zip, 7z, RAR and xz decoders (~50 ms of it the 7z/RAR/xz ones) |

## Dependencies

| package | used for | note |
|---|---|---|
| path | joins, relative, normalize | fs, archive, chrome, image, video, src/tree, src/cache, src/tool; correct on every OS |
| crypto | md5 … sha512, HMAC, the archive KDFs | |

Archives (zip, 7z, RAR, xz), AES, the HTTP client and SOCKS, the HTML5 parser with its selector engine, YAML, CSV, the DevTools client and the isolate pool are in-house on the SDK. package:html stays a dev dependency: `test/html_corpus_test.dart` holds the in-house parser to its tree on 52 saved real pages.

**Native tools** (`src/tool.dart`), run as processes, never linked: ffmpeg/ffprobe 9.0.2 for `image` and `video`, 7-Zip 26.04 for `archive`'s 7z writes and big or exotic reads, Chrome for Testing 155.0.8059.84 for `chrome` (`src/chrome_find.dart`). A PATH copy with the needed encoders wins (an installed Chrome for `chrome`); otherwise a build pinned by sha256 is downloaded once per machine into the user cache under a file lock. No `HOME` is an error, never a shared temp folder.

## Rules

- **One lifecycle owner.** Only `src/exit.dart` watches signals and calls `exit`. Only `src/terminal.dart` reads stdin and sets its modes (capture, raw, line, restore). Child processes outside `shell` are named here: the tty reader (`terminal`), the Tui exit guard (`tui/session`), Chromium (talking CDP over two FIFOs on POSIX), its watchdog and the macOS `xattr` call (`chrome`), and the `chmod`/`touch` batches (`src/posix`). ffmpeg, ffprobe and 7-Zip go through `shell`, so Ctrl-C ends them.
- **One shared model.** `Reader`/`Writer`/`Pipe`/`Probe`/`Closeable`/`Origin` cross modules; no module has a lookalike. Progress has one path: a run (`src/progress.dart`) counts at a flow's root or takes the work a source, writer or `Task` reports, and feeds every probe; sources and writers register their work in the `working`/`writing` Expandos and built-in probes their watcher in `watchers`, so none of it is public. Stopping is `src/rate.dart`'s `Halt`: http and pool end their waits through it.
- **Engines stay behind private interfaces.** `Region.picture` draws through `src/pixels.dart`, so the TUI never loads the image engine. `html` never loads `charset`: decoding belongs to the `Reader`.
- **Big files follow seams.** These are data or state machines: `charset.dart` (tables), `entities.dart`, `html_parser.dart` (tokenizer, tree builder), the archive decoders. The rest are facades: `http.dart` (client, pool, `Response`, send and redirect, cache), `terminal.dart` (decoder, caps, widths), `tui/session.dart` (loop, input, prompts bridge).
- **SDK-only helpers stay SDK-only.** `src/posix.dart` imports no package, so a module that needs a `chmod` (http's cache) pays nothing for it. Path-shaped helpers (`tmpPath`, `sortByRelative`) live in `src/tree.dart`, next to their only users.

## Findings (2026-10-15)

| # | Finding | Status |
|---|---|---|
| A1 | `posix.dart` pulled in package:path for two helpers only fs and archive use; http re-implemented `chmod` to avoid it | done: 5e972c38 |
| A2 | Console wrote `stdin.echoMode/lineMode` itself, bypassing the terminal owner | done: 4f8effaa |
| A3 | The SGR pattern existed twice (sanitize, Console.table) | done: 6b417248 |
| A4 | `cli.dart` `_parseCommand` was ~280 lines: options, positionals and sub-commands in one loop | done: a `_Parse` class with one method per token kind and one value-taking helper |
| A5 | `http.dart` was ~1,950 lines, five seams in one file | done: `Response`, `Feed` and the proxy are part files under `lib/src/http/` |
| A6 | `Console.ask` on a pipe reads through `Isolate.run(readLineSync)` per line: an abandoned prompt keeps the VM alive until a line arrives | done: `Console.ask(timeout:)` stops its reader |
| A7 | `scrape` had no user in projects/ any more (plain loops + `Pool` read shorter) | done: removed |

## Migration order

4. Split `tui/session.dart` along input routing and the loop once a second consumer of either appears.
