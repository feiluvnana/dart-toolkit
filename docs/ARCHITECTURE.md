# Architecture

Structure, not features: module edges, startup cost, dependencies and the seams that hold the library together. Startup numbers are JIT `dart run` of a script that only imports the module, as the median of 7 alternating runs minus `void main() {}`'s (136–141 ms) on an M-series Mac. The machine drifts ±80 ms, so compare with A/B runs, never with a number from another day.

## Import graph

```
core ─────────────── src/progress (re-exported), src/resume
utils ────────────── core, src/cookies, src/missing; re-exports src/console_utils, src/cookies, src/csv, src/format, src/hash, src/rate, src/shell_utils, src/time: a separate import, re-exported by no module
json ─────────────── core, src/missing, src/names
yaml ─────────────── json, src/missing, src/names, src/yaml_parser
pool ─────────────── core, src/exit, src/format, src/progress, src/rate, src/retry
fs ───────────────── core, src/exit, src/format, src/glob, src/missing, src/names, src/posix, src/progress, src/resume, src/tree (+path)
shell ────────────── core, src/exit, src/names, src/progress, src/quiet, src/time, src/timeout
archive ──────────── src/tar (part file) → core, shell, src/exit, src/format, src/glob, src/posix, src/progress, src/rar, src/sevenzip, src/tool, src/tree, src/unpack, src/xz, src/zip (+path)
http ─────────────── src/http/feed, proxy, response (part files) → core, src/charset, src/cookies, src/decoders, src/exit, src/missing, src/origin, src/rate, src/resume, src/retry, src/time, src/timeout
html ─────────────── json, src/dom, src/html_parser, src/missing, src/selector
image ────────────── core, src/media, src/pixels (+path)
cli ──────────────── core, src/sanitize
console ──────────── core, src/exit, src/format, src/logbook, src/progress, src/terminal, src/time
tui ──────────────── src/tui (part files) → core, src/exit, src/format, src/keys, src/logbook, src/pixels, src/progress, src/terminal, src/time
video ────────────── image, src/format, src/media, src/media_proxy, src/progress (+path)
chrome ───────────── html, src/cdp, src/chrome_find, src/cookies, src/exit, src/format, src/glob, src/keys, src/names, src/origin, src/posix, src/progress, src/time (+path); re-exports core

src/media ── pool, shell, src/cache, src/exit, src/format, src/posix, src/quiet, src/tool (+path)      src/tool ── shell, src/cache, src/names, src/posix, src/which (+path)
src/shell_utils ── src/which: `ShellUtils.which` and `open`      src/console_utils ── src/bridge: `ConsoleUtils.copy`, never the terminal layer
src/chrome_find ── core, src/cache, src/cdp, src/which (+path)      src/cache ── core, src/download_line (+path): the user cache, the download lock and fetchInIsolate
src/download_line ── src/bridge, src/format: a first-use download's live line or status-row bar
src/progress ── src/format: Probe, Task, Meter and the private run that feeds them
src/fetch ── archive, fs, http, src/hash, src/progress (+path): spawned by URI, never imported
src/hash ── core, src/resume (+crypto)      src/csv ── core, src/decoders, src/missing      src/missing ── core: the `or:` rule (a missing file, a 404/410)
src/resume ── core, src/names      src/exit ── core, src/progress      src/cdp ── core, src/exit      src/retry, src/cookies ── core
src/origin ── src/names      src/media_proxy ── src/names      src/html_parser ── src/dom, src/entities      src/selector ── src/dom
src/unpack ── core, src/names (+path): member checks and link placement shared by every extraction      src/tree ── src/posix (+path)
src/terminal ── src/format, src/sanitize, src/width, src/winconsole; re-exports src/bridge, src/keys_decode, src/sanitize, src/width
src/logbook ── SDK only: every Console.log line, which console writes and tui's Region.log draws
src/zip ── core, aes, crc32 (+crypto)      src/xz ── core, bcj, crc32, lzma      src/sevenzip ── core, aes, bcj, budget, crc32, lzma, ppmd, zip (+crypto)
src/rar (part src/rar4) ── core, aes, budget, crc32, lzma, ppmd (+crypto)
SDK only: bcj, charset, crc32, decoders, dom, entities, format, glob, keys, keys_decode, logbook, names, pixels, posix, quiet, rate, sanitize, time, timeout, which, width, winconsole, yaml_parser
```
No import cycles between public modules (inside, `core` and `src/resume` import each other). Cross-module edges are the compositions the API promises: `chrome → html` (a page's `html()`/`json()`), `html → json` (`Elements.json()`), `yaml → json` (a YAML document is a `Json`), `video → image` (`frame()`). `archive → shell` runs 7-Zip (through `src/tool`); `image` and `video` reach `shell` (ffmpeg, ffprobe) and `pool` (the encode limit) through `src/media`. The one-time downloads (`src/fetch`) need http, archive and fs, so they run in an isolate spawned by URI (`src/cache.dart` `fetchInIsolate`, called by `src/tool` and `src/chrome_find`): a deferred import still compiles them at startup under `dart run`. The 7z/RAR/xz decoders stay imported by `archive`: a URI isolate per extraction would cost 240–380 ms each time (PLAN.md O2).

## Startup per module

Each module imported alone, measured as above, 2026-10-16 (utils 2026-10-17).

| import | ms | what it costs |
|---|---|---|
| core, json, pool, shell | 62–75 | — |
| utils | 80 | crypto (hashes) |
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
| path | joins, relative, normalize | fs, archive, chrome, image, video, src/cache, src/chrome_find, src/fetch, src/media, src/tool, src/tree, src/unpack; correct on every OS |
| crypto | md5 … sha512, HMAC, the archive KDFs | src/hash, src/aes, src/zip, src/sevenzip, src/rar |

Archives (zip, 7z, RAR, xz), AES, the HTTP client and SOCKS, the HTML5 parser with its selector engine, YAML, CSV, the DevTools client and the isolate pool are in-house on the SDK. package:html stays a dev dependency: `test/html_corpus_test.dart` holds the in-house parser to its tree on 52 saved real pages.

**Native tools** (`src/tool.dart`), run as processes, never linked: ffmpeg/ffprobe 9.0.2 for `image` and `video`, 7-Zip 26.04 for `archive`'s 7z writes and big or exotic reads, Chrome for Testing 155.0.8059.84 for `chrome` (`src/chrome_find.dart`). A PATH copy with the needed encoders wins (an installed Chrome for `chrome`); otherwise a build pinned by sha256 is downloaded once per machine into the user cache under a file lock. No `HOME` is an error, never a shared temp folder.

## Rules

- **One lifecycle owner.** Only `src/exit.dart` watches signals and calls `exit`. Only `src/terminal.dart` consumes stdin and sets its modes (capture, raw, line, restore). Child processes outside `shell` are named here: in `src/terminal` the tty reader (`sh`: `cat -u /dev/tty`), the timed piped-line reader (`sh -c 'IFS= read -r …'`) and `stty … </dev/tty`; the Tui exit guard (`tui/session`, `sh` with `stty -g`); Chromium (exec'd by `sh` over two `mkfifo` FIFOs on POSIX) and its `sh` watchdog (`chrome`); the media spool watchdog (`src/media`); the `chmod`/`touch` batches and `cp -pPR` (`src/posix`); the OS launcher `open`/`xdg-open`/`rundll32` (`src/shell_utils`); macOS `xattr` (`src/fetch`, in its isolate). `shell` runs `ps` for its tree kill. ffmpeg, ffprobe and 7-Zip go through `shell`, so Ctrl-C ends them. Isolates: pool workers and archive's unarchive and decoder offload (`Isolate.spawn`), the CDP FIFO reader (`src/cdp`), `src/fetch` by URI (`src/cache`), and `Isolate.run(readLineSync)` for an untimed piped line (`src/terminal`).
- **One shared model.** `Reader`/`Writer`/`Pipe`/`Probe`/`Closeable`/`Origin` cross modules (and utils' `Cookies` and `Rate`, which modules import from `src/` so none re-exports utils); no module has a lookalike. Progress has one path: a run (`src/progress.dart`) counts at a flow's root or takes the work a source, writer or `Task` reports, and feeds every probe; sources and writers register their work in the `working`/`writing` Expandos and built-in probes their watcher in `watchers`, so none of it is public. Stopping is `src/rate.dart`'s `Halt`: http and pool end their waits through it. Two more private handshakes: `src/missing` (`or:`, shared by json, yaml, html, fs, utils' csv and cookies) and the `decoders` Expando (`src/decoders`: http's charset decoder for utils' `rows()`).
- **Engines stay behind small interfaces.** `Region.picture` draws a `Pixels` (`src/pixels.dart`, exported by both `tui` and `image`), so the TUI never loads the image engine. `html` never loads `charset`: decoding belongs to the `Reader`.
- **Big files follow seams.** These are data or state machines: `charset.dart` (tables), `entities.dart`, `html_parser.dart` (tokenizer, tree builder), `yaml_parser.dart`, `width.dart` (tables), the archive decoders. The rest are facades: `http.dart` (client, pool, send and redirect, resume delivery; `Response`, `Feed` and the proxy are part files under `src/http/`), `terminal.dart` (input, modes, caps; key decoding is `keys_decode.dart`, widths `width.dart`), `tui/session.dart` (loop, input, prompts bridge).
- **SDK-only helpers stay SDK-only.** `src/posix.dart` imports no package, so a module that needs a `chmod` (chrome, `src/media`'s spool folder) pays nothing for it. Path-shaped helpers (`tmpPath`, `sortByRelative`) live in `src/tree.dart`, next to their only users.

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
