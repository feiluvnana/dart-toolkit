# Architecture

Structure, not features: module edges, startup cost, dependencies and the seams that hold the library together. Numbers are JIT startup of a script that only imports the module (`void main() {}` baseline: 139 ms), median of 3 on an M-series Mac; they drift ±80 ms, so compare with back-to-back A/B runs.

## Import graph

```
core ─────────────── (no imports)            src/abort, src/cache, src/exit, src/keys,
                                             src/pixels, src/retry, src/sanitize, src/tabs,
                                             src/winconsole: no package imports
json, hash ───────── core (+crypto)
fs ───────────────── core, src/exit, src/posix, src/tree
shell ────────────── core, src/exit
archive ──────────── core, src/exit, src/posix, src/tree, src/zip
http ─────────────── core, src/abort, src/charset, src/origin, src/retry
html ─────────────── core, src/origin (+html, csslib)
image ────────────── core, src/pixels (+image)
pool ─────────────── core
cli ──────────────── src/sanitize
console ──────────── core, src/exit, src/keys, src/terminal
tui ──────────────── src/tui (part files) → src/exit, src/keys, src/pixels, src/terminal
chrome ───────────── core, html, json, src/cache, src/exit, src/keys, src/origin, src/tabs (+puppeteer)
```
No cycles. The one cross-module edge: `chrome → html, json` (a page's `html()`/`json()` return those types), the composition the API promises.

## Startup per module

| import | ms | what it costs |
|---|---|---|
| core, json, shell | 145–160 | — |
| hash, fs, cli | 160–230 | crypto ~15; path ~40–60 |
| http, console, pool, tui | 160–290 | — |
| archive | 228–256 | in-house codecs |
| html | ~770 | package:html ~570, csslib ~240 |
| image | 977–1003 | package:image ~820 |
| chrome | ~1750 | puppeteer ~1150 |

## Dependencies

| package | used for | startup | note |
|---|---|---|---|
| path | joins, relative, normalize | ~40 ms | correct on every OS |
| crypto | md5 … sha512 (`hash`) | ~15 ms | |
| html + csslib | `Html.parse`, `$` selectors | ~710 ms | the largest cost a scraping script pays; `html.dart` imports `package:html/src/query_selector.dart`, so a minor `html` upgrade can break it |
| image | decode/encode/resize | ~820 ms | no in-house substitute for the codecs |
| puppeteer | `chrome` | ~1150 ms | only chrome scripts pay it |

Archives (zip, 7z, RAR, xz), AES, isolate pools and the HTTP client are in-house on the SDK.

## Rules

- **One lifecycle owner.** Only `src/exit.dart` watches signals and calls `exit`; only `src/terminal.dart` reads stdin. Facades and `shell` children register exit hooks.
- **One shared model.** `Reader`/`Writer`/`Pipe`/`Closeable`/`Origin` cross modules; no module has its own lookalike.
- **Engines stay behind private interfaces.** `Region.picture` draws through `src/pixels.dart`, so the TUI never loads the image engine.
- **Big files follow seams**: `charset.dart` (tables), `tui/session.dart` (loop, input routing, prompts bridge), `http.dart` (client pool, `Response`, send/redirect), `terminal.dart` (decoder, caps, widths).

## Next levers

1. An in-house HTML tokenizer and tree builder behind `Html.parse` (~710 ms off every html and chrome script), with a corpus test against package:html.
2. Split `tui/session.dart` along input routing vs the loop once a second consumer of either appears.
