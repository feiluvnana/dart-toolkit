# Architecture

Structure, not features: module edges, startup cost, dependencies and the seams that hold the library together. Startup numbers are JIT `dart run` of a script that only imports the module, as the median of three back-to-back deltas against `void main() {}` (141 ms) on an M-series Mac. The machine drifts ±80 ms, so compare with A/B runs, never with a number from another day.

## Import graph

```
core ─────────────── src/resume, src/cookies, src/rate, src/time
json ─────────────── core, src/names
hash ─────────────── core, src/resume (+crypto)
csv ──────────────── core
yaml ─────────────── json (+yaml)
pool ─────────────── core, src/rate, src/retry
fs ───────────────── core, src/exit, src/glob, src/names, src/posix, src/tree (+path)
shell ────────────── core, src/exit, src/timeout
archive ──────────── core, src/exit, src/posix, src/tree, src/zip, src/sevenzip, src/rar, src/xz (+path)
http ─────────────── core, src/charset, src/cookies, src/origin, src/posix, src/rate, src/resume, src/retry, src/timeout
html ─────────────── json, src/dom, src/html_parser, src/names, src/selector
image ────────────── core, src/pixels (+image)
cli ──────────────── core, src/sanitize
console ──────────── core, src/exit, src/format, src/keys, src/resume, src/terminal
tui ──────────────── src/tui (part files) → core, src/exit, src/format, src/keys, src/pixels, src/terminal
chrome ───────────── core, html, json, src/cache, src/cookies, src/exit, src/glob, src/keys, src/origin, src/tabs (+path, +puppeteer)

src/posix ── SDK only        src/tree ── posix (+path)        src/terminal ── sanitize, winconsole
src/zip, src/xz ── aes, crc32, lzma (+crypto)   src/sevenzip, src/rar ── aes, crc32, lzma, ppmd, zip (+crypto)
```

No cycles. Cross-module edges are the compositions the API promises: `chrome → html, json` (a page's `html()`/`json()`), `html → json` (`Elements.json()`), `yaml → json` (a YAML document is a `Json`). `Cookies` and `Rate` live in core because two modules share each one. `src/resume.dart` is the private handshake behind `resume: true`, so http never imports fs or console.

## Startup per module

| import | +ms over an empty script | what it costs |
|---|---|---|
| core, csv | 21–24 | — |
| json, pool, cli, shell, hash | 57–73 | crypto (hash) |
| fs, http, html, console | 96–103 | path (fs); charset tables (http); parser and selectors (html) |
| archive, yaml, tui | 208–239 | in-house codecs; package:yaml; widgets and markdown |
| image | 892 | package:image |
| chrome | 1197 | puppeteer |

## Dependencies

| package | used for | note |
|---|---|---|
| path | joins, relative, normalize | fs, archive, chrome, src/tree, src/cache; correct on every OS |
| crypto | md5 … sha512, the archive KDFs | |
| image | decode/encode/resize | no in-house substitute for the codecs |
| puppeteer | `chrome` | only chrome scripts pay it |
| yaml | `Yaml.parse` | only yaml scripts pay it; read only |

Archives (zip, 7z, RAR, xz), AES, the HTTP client, the HTML5 parser with its selector engine, CSV and the isolate pool are in-house on the SDK. package:html stays a dev dependency: `test/html_corpus_test.dart` holds the in-house parser to its tree on 52 saved real pages.

## Rules

- **One lifecycle owner.** Only `src/exit.dart` watches signals and calls `exit`. Only `src/terminal.dart` reads stdin and sets its modes (capture, raw, line, restore). Child processes outside `shell` are named here: the tty reader (`terminal`), the Tui exit guard (`tui/session`), the Chromium watchdog (`chrome`) and the `chmod`/`touch` batches (`src/posix`).
- **One shared model.** `Reader`/`Writer`/`Pipe`/`Closeable`/`Origin` cross modules; no module has a lookalike. Stopping is `src/rate.dart`'s `Halt`: http and pool end their waits through it.
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
| A5 | `http.dart` was ~1,950 lines, five seams in one file | done: `Response`, the cache and `Http.serve` are part files under `lib/src/http/` |
| A6 | `Console.ask` on a pipe reads through `Isolate.run(readLineSync)` per line: an abandoned prompt keeps the VM alive until a line arrives | open: needs a cancellable prompt (a `timeout:` on ask) |
| A7 | `scrape` had no user in projects/ any more (plain loops + `Pool` read shorter) | done: removed |

## Migration order

3. A6: a `timeout:` on `Console.ask` that cancels the reader isolate. This changes the API, so ERGONOMIC decides it.
4. Split `tui/session.dart` along input routing and the loop once a second consumer of either appears.
