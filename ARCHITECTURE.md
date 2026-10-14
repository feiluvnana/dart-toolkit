# Architecture

Structure, not features: module edges, startup cost, dependencies and the seams that hold the library together. Numbers are JIT startup of a script that only imports the module (`void main() {}` baseline: 139 ms), median of 3 on an M-series Mac; they drift ±80 ms, so every claim below came from back-to-back A/B runs.

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
pool ─────────────── core (+worker_manager)
cli ──────────────── src/sanitize
console ──────────── core, src/exit, src/keys, src/terminal
tui ──────────────── src/tui (part files) → src/exit, src/keys, src/pixels, src/terminal
chrome ───────────── core, html, json, src/cache, src/exit, src/keys, src/origin, src/tabs (+puppeteer)
scrape ───────────── core, fs, hash, html, http, src/abort, src/charset, src/origin,
                     src/posix, src/retry, src/tabs
```
No cycles. Cross-module edges left: `chrome → html, json` (a page's `html()`/`json()` return those types) and `scrape → fs, hash, html, http` (cache files, cache keys, parsing, fetching). Both are the composition the API promises.

## Startup per module

| import | before | after | what it costs |
|---|---|---|---|
| core, json, shell | 145–160 | same | — |
| hash, fs, cli | 160–230 | cli 186 | crypto 15 ms; fs/path ~60 ms |
| http, console, pool, tui | 215–290 | same | worker_manager ~110 ms (pool) |
| archive | 464–598 | 228–256 | package:archive was ~250 ms, for zip only |
| html | 770 | same | package:html ~570 ms, csslib ~240 ms |
| image | 1113–1135 | 977–1003 | package:image ~820 ms; the Tui edge was ~140 ms |
| scrape | 1733–1813 | 795–847 | puppeteer (via chrome) ~950 ms |
| chrome | 1750 | same | puppeteer ~1150 ms |

## Dependencies

| package | used for | startup | verdict |
|---|---|---|---|
| path | joins, relative, normalize | ~40 ms | keep: correct on every OS |
| crypto | md5/sha1/sha256 (`hash`) | ~15 ms | keep |
| html + csslib | `Html.parse`, `$` selectors | ~710 ms | keep for now; the largest cost a scraping script pays. An in-house parser is the next lever (see 4) |
| image | decode/encode/resize | ~820 ms | keep: no in-house substitute for the codecs |
| puppeteer | `chrome` | ~1150 ms | keep: only chrome scripts pay it now |
| worker_manager | `Pool` isolates | ~110 ms | keep (squadron rejected for codegen) |
| http | nothing (`http.dart` is on `dart:io`'s client) | — | **dropped**: declared but never imported |
| archive | zip | ~250 ms | **dropped**: `src/zip.dart`, 230 lines on the SDK's deflate (still in the lock file through `image`) |

## Findings and what happened

1. **scrape compiled puppeteer.** It imported `chrome` for the `Browser` type. Now `Browser`/`Page` implement two private interfaces (`src/tabs.dart`) and the crawl takes those, so HTTP crawls never load puppeteer. Done (3213082).
2. **image loaded the whole Tui** for one extension. `Region.picture` is now a Region method taking a private `Pixels` interface that `Image` implements (adding the `pixel(x, y)` reading). Done (04c66fe).
3. **cli loaded the terminal layer** for one sanitiser. The sanitisers live in `src/sanitize.dart`. Done (13aad5a).
4. **Two tree copies.** `archive` kept a weaker `_copyTree` (a chmod fork per file, no collision walk) next to `fs`. Both now use `src/tree.dart`. Done (fc40adf).
5. **A 220-line god function.** `_Unpacker.consume` mixed sniffing, zip, tar, AppleDouble and the merge. Split into `_Extraction`. Done (366be9f).
6. **package:archive for zip only.** Replaced. Done (666224a). `package:http` was declared and never imported: dropped (ebffb90).
7. **Lifecycle has one owner.** Only `src/exit.dart` watches signals and calls `exit`, and only `src/terminal.dart` reads stdin. `shell` children now register exit hooks too. OK.
8. **Shared model.** `Reader`/`Writer`/`Pipe`/`Closeable`/`Origin` are used across modules; no module has its own lookalike. `Bar` is a `Pipe` and a `Closeable`, `Hash` a `Pipe` and a `Writer`, `Response` a `Reader` and a `Closeable`. OK.
9. **Extensibility.** `Writer`, `Pipe` and `Reader` are open interfaces/mixins and user classes compose with every module (the tests use several). Tui widgets are builder functions over `Region`. OK.
10. **Private engine import.** `html.dart` imports `package:html/src/query_selector.dart`; a minor upgrade of `html` can break it. Pin `html` tightly (RELEASE) and replace the evaluator if it moves.

## Size

Files over ~800 lines follow seams: `charset.dart` (2,801, tables), `tui/session.dart` (1,430: loop, input routing, prompts bridge), `http.dart` (1,154: client pool, Response, send/redirect), `console.dart` (1,129), `cli.dart` (1,117), `chrome.dart` (1,079), `archive.dart` (1,070), `terminal.dart` (1,074: decoder, caps, widths). Functions over 80 lines left: `csiName` (132, one switch), `_mdHighlight` (127, one tokenizer), `Field.edited` (131), `_Filter.transform` (120, one generator with its cleanup paths). Splitting them would scatter state for no reuse.

## Migration order (next)

1. An in-house HTML tokenizer and tree builder for the subset scripts use, behind `Html.parse` (~710 ms off every scrape and chrome script). Large: needs its own stage with a corpus test against package:html.
2. Split `tui/session.dart` along input routing vs the loop once a second consumer of either appears.
3. Pin `html` and `csslib` to the minor versions tested.
