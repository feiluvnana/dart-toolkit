# Architecture

Structure, not features: module edges, startup cost, dependencies and the seams that hold the library together. Numbers are JIT startup of a script that only imports the module (`void main() {}` baseline: 139 ms), median of 3 on an M-series Mac; they drift ±80 ms, so compare with back-to-back A/B runs.

## Import graph

```
core ─────────────── src/cookies, src/rate,     src/cache, src/exit, src/glob, src/keys,
                     src/resume, src/time
                                                src/pixels, src/retry, src/sanitize, src/tabs,
                                                src/winconsole: no package imports
json, hash ───────── core (+crypto)
csv ──────────────── core
scrape ───────────── core, src/rate, src/retry
yaml ─────────────── json (+yaml)
fs ───────────────── core, src/exit, src/glob, src/posix, src/tree
shell ────────────── core, src/exit, src/timeout
archive ──────────── core, src/exit, src/posix, src/tree, src/zip
http ─────────────── core, src/charset, src/cookies, src/origin, src/rate, src/resume, src/retry, src/timeout
html ─────────────── json, src/dom, src/html_parser (src/entities), src/selector, src/names
image ────────────── core, src/pixels (+image)
pool ─────────────── core, src/rate, src/retry
cli ──────────────── core, src/sanitize
console ──────────── core, src/exit, src/keys, src/terminal
tui ──────────────── src/tui (part files) → src/exit, src/keys, src/pixels, src/terminal
chrome ───────────── core, html, json, src/cache, src/cookies, src/exit, src/glob, src/keys, src/origin, src/tabs (+puppeteer)
```
No cycles. The cross-module edges: `chrome → html, json` (a page's `html()`/`json()` return those types) and `html → json` (`Elements.json()` returns embedded data), the compositions the API promises. `Cookies` and `Rate` sit in core because two modules share each (chrome → http, http + pool); `src/glob.dart` serves fs (`list(match:)`) and chrome (`responses`). `src/resume.dart` is the private handshake behind `resume: true`: `Reader.to` asks the chain's source (a lazy GET) to deliver itself to a path, through pipes that declare `PassThrough` (console's `Bar`, hash's `Hasher`), so http never imports fs or console.

## Startup per module

| import | ms | what it costs |
|---|---|---|
| core, csv, pool, scrape, shell | 150–170 | — |
| json, hash, fs, cli | 185–230 | crypto ~15; path ~40–60 |
| http, console, tui | 230–290 | — |
| yaml | ~350 | package:yaml ~150 |
| html | ~235 | in-house parser and selectors (was ~770 with package:html + csslib) |
| archive | 228–256 | in-house codecs |
| image | 977–1003 | package:image ~820 |
| chrome | ~1300 | puppeteer ~1150 |

## Dependencies

| package | used for | startup | note |
|---|---|---|---|
| path | joins, relative, normalize | ~40 ms | correct on every OS |
| crypto | md5 … sha512 (`hash`) | ~15 ms | |
| image | decode/encode/resize | ~820 ms | no in-house substitute for the codecs |
| puppeteer | `chrome` | ~1150 ms | only chrome scripts pay it |
| yaml | `Yaml.parse` | ~150 ms | only yaml scripts pay it; read only |

Archives (zip, 7z, RAR, xz), AES, isolate pools, the HTTP client, the HTML5 parser with its CSS selector engine, and CSV are in-house on the SDK. package:html stays a dev dependency: `test/html_corpus_test.dart` holds the in-house parser to its tree on 50 saved real pages (`test/fixtures/html`) plus edge-case snippets.

## Rules

- **One lifecycle owner.** Only `src/exit.dart` watches signals and calls `exit`; only `src/terminal.dart` reads stdin. Facades and `shell` children register exit hooks.
- **One shared model.** `Reader`/`Writer`/`Pipe`/`Closeable`/`Origin` cross modules; no module has its own lookalike.
- **Engines stay behind private interfaces.** `Region.picture` draws through `src/pixels.dart`, so the TUI never loads the image engine.
- **Big files follow seams**: `charset.dart` (tables), `entities.dart` (the HTML5 entity table, parsed on first `&name;`), `html_parser.dart` (tokenizer, tree builder), `selector.dart`, `tui/session.dart` (loop, input routing, prompts bridge), `http.dart` (client, pool, `Response`, send/redirect, cache), `terminal.dart` (decoder, caps, widths).
- **html never loads charset**: decoding belongs to the `Reader` (http), so `html` imports only the small `src/names.dart` (~100 ms saved).

## Next levers

1. Split `tui/session.dart` along input routing vs the loop once a second consumer of either appears.
