# Report · Roadmap — Bringing `lib2` to the Proposal (phased, measured)

> Sibling reports: [`README.md`](README.md) (methodology + index), [`native2_architecture.md`]
> (native2.md) (binding design), and the 12 module reports this plan coordinates.
> External anchors: `CONVENTIONS.md` (r-numbers below), `PLAN.md`, 15 ms startup budget (r56),
> deadline-native list, and the git HEAD (master, docs: update proposal) work week.

---

## 0. The whole of the mandate in one paragraph

Ship a `lib2` that is a) **dead simple** (r5 surface, one-status model r7, four-shapes r1),
b) **the proposal's nouns, verbatim**, c) **fast through `native2`** for archive/image/hash/chrome/
tui, d) **safe** (zip-slip r15, tree-kill, constant-time checks), and e) **tested** at the CLI
contract level, with per-module acceptance tests mirroring the legacy corpus.

## 1. Guiding principles (bind every phase)

1. **Noun-first, noun-locked:** the 1-word table (00:76–92) is a *gate*. Each phase ends by running
   `api_names_test.dart` asserting `open/html/type/shot/draw/poll/box/ask/bar/print` etc. so
   drift is caught the same week it happens.
2. **Own-first:** implement in `lib2` (pure Dart) to learn the shape; promote to `native2` only
   for the deadline-native list (hash, archive, image, chrome, tui) — and land native *next to*
   the Dart fallback behind the same `Native` seam (r53 flip, never fork).
3. **Security before speed:** zip-slip, tree-kill, symlink escapes, constant-time checks land in
   Phase A/B *before* any speed work; each carries a named `SecurityException`/typed error test.
4. **Budget discipline:** re-check the 15 ms import budget at every phase end (`dart compile`,
   `NATIVE=sys` timing or the dev `timeImport` harness); `tui` import must not load `native`
   engine; `cli` loads none.
5. **Tests are the contract:** every gap table row marked ≥ MAJOR gets one acceptance test file;
   each module's `test/…_test.dart` mirrors the legacy `test/` fixtures where the API matches.

## 2. Phase plan (weeks within the work week)

### Phase A — Safe foundation, pure Dart (weekday 1)
Goal: no silent data loss, no escapes, correct nouns. Order:

1. **`core`** — tighten `Writer.write` contract, `Seeker` on `File`, add `FnReader`/`FnWriter`
   adapters in `pipe.dart` (for native callback wiring), make `pipe.onProgress` a display-only
   detail. (`core.md` §5.1–3)
2. **`hash` blocking fixes** — `sha256(File)` streaming, `AlgoWriter implements Writer`,
   `.writer()` factory, `xxh3` → real XXH3 (keep XXH64 labelled), constant-time `checksum`.
   (`hash.md` §5.1–2,5)
3. **`archive` security fix** — the zip-slip sandbox in `unpack` + `test/archive_security_test.dart`;
   refuse `..`, absolute members, escaping symlinks. (`archive.md` §5.1)
4. **`fs` glob + typed errors + `Seeker`** — real `**`/`[ ]`/`{ , }` glob; error nouns
   `PathNotFound`-family; `File.seek`. (`io_fs.md` §5.1,3,7)
5. **`process` two-ended pipe** — `Process` as `Reader`/`Writer`, `line()` streaming `lines()`
   on top of it, `wait(timeout:)`, `Closeable` + `cancel()`. (`process.md` §5.1–2)

**Exit gate A:** `archive_security_test`, `process` tree test (route kill reaping on current
platform), `hash` known-answer + `xxh3` vector, glob `**` suite — all green; `api_names` passes.

### Phase B — Concurrency & the flagellum verbs (weekday 2)
1. **`async` real isolates** — `Worker`, `Pool` over `SendPort/ReceivePort`, `Task.run`
   isolate-mode, cross-isolate `Chan` w/ consumer-side buffer, stop-byte seam exposed by
   `work`. (`async.md` §5.1) — the crawler (02:86) becomes runnable.
2. **`http` reader + strict verbs** — `Resp implements Reader` (chunked body, no pre-image),
   `Http.get(url).pipe(...)` via the core extension, strict reading `.json()` 2xx-gated, `body:
   Reader` upload, resume `.part` + `Range`, retry/timeout (`http.md` §5). Local `HttpServer`
   fixtures.
3. **`html` + cli async prompts** — `Html.read`, implied `html>body`, legacy-corpus parity;
   `ask/confirm/choose` async non-blocking. (`html.md` §5.1–3, `cli.md` §5.1)

**Exit gate B:** `async_test` proves event loop stays live during isolate jobs; `http_test`
streaming hash equality + resume + upload; `html` corpus parity; prompts resolve under load.

### Phase C — native2 core wiring (weekday 3)
1. **`DartNative` loader + sys libs** — cdylib layout (`dart_toolkit_native`,
   `dart_toolkit_chrome`, `dart_toolkit_tui`, `dart_toolkit_torrent`), `Native.install()/
   check()`, stop-byte into every handle. (`native2.md` §2,8)
2. **hash → native** — `tk_digest_new/update/finish/free` (+ real XXH3), `tk_mac_new`,
   `tk_hmac`; fallback bit. (`native2.md` §5) — RAM-drop: 16 MiB streaming equality.
3. **archive streaming steppers → native** — `tk_archive_open/next/member` (zip, tar, tar.gz)
   + zstd decode; `Archive.open(member).pipe` and RAM-ceiling unpack. (`archive.md` §5.3–4)
4. **image native decode/encode** — jpg/webp/qoi/gif decode, jpg/webp encode w/ `quality`, then
   the `Image.load()` pipe sink. (`image.md` §5.2–3)
5. **fs `tk_rename`** (Windows retry) + `chmod`/copy/id native reuse; `tk_kill_tree` in the new
   `process` crate. (`io_fs.md` §5.4, `process.md` §5.3)

**Exit gate C:** `native==fallback` equality across the whole hash set; `unpack(pack(d)) ≡ d`
for zip/tar/tar.gz + image round-trips; Windows rename-retry test passes with a held handle;
kill-tree reaps a 3-level chain.

### Phase D — Chrome CDP native + browser pipeline (weekday 4)
1. **`chrome` crate ABI 1** — launch/attach worker, id/completer map, `open`, `eval`, `wait`,
   `click` (coord), `type` (keys), `shot`/`pdf` (bytes), job-object tree kill, profile lock +
   reaper. (`browser_chrome.md` §4.2)
2. **Dart surface** — `Browser.open`, `Page.type`, `Page.pdf`, capture-as-Reader/pipe form, all
   named per 00:76. Loose-end rename closes `click`/`wait`/`html()` drift. (`browser_chrome.md`
   §4.1)
3. Pipeline: `Html.parse(await page.html())`; `Image.decode(page.shot())` (now native); the
   `page.shot().pipe(File)` path. (`core.md` G5, `image.md` G9)

**Exit gate D:** real-SPA fixture (local server): `open → wait('.product-card') → html()`
contains hydrated markup; close leaves zero children on Windows; `shot().pipe(File)` +
`Image.read` opens the PNG.

### Phase E — TUI (weekday 5+; the biggest single lift)
1. **Phase A engine** — `TuiEvent` sealed set, `Term`, `Canvas`, `Tui.run/quit/post/listen`,
   flex layout nodes, cell-buffer diff painter, `FakeTerminal` seam. (`tui.md` §4.1)
2. **Phase B native `tui` crate** — `tk_tui_start/stop/poll/render`, raw mode + alt screen +
   restore, diff rendering, coloured cells, resize/pointer/paste events, Unicode width + wrap.
   (`tui.md` §4.2)
3. **Phase C widgets** — List/Menu scroll+keys, Button/Clickable, Field, Popup/Tooltip, Tabs/Grid,
   Board(Tally)/TaskView, Markdown, Picture, inline-region run. (`tui.md` §4.3)
4. **Acceptance** — ^C semantics, resize redraw, 10k-row list without porting, diff < 40 cells
   on one-label change, `Chan → Board` bounded-fps. (`tui.md` §4.4)

**Exit gate E:** full `tui_test.dart` suite; import-budget check (`tui` loads only its loader);
the 12:4.1 example runs.

### Phase F — polish & release prep (as time allows)
- `$lib` archive native writer (PLAN.md Phase 6), `su`/`ch` (post-1.0), `tar.zst` pack, `webp`
  quality knob, PNG-ignores-quality documented, `Picture` sixel, `BarGlyphs`/palette fallbacks.
- CHANGELOG entries per module; docs per verb; release checklist in `Makefile`/`tool`.

## 3. Cross-cutting work queue (r-numbers honoured)

| Concern | Where | Gate |
|---|---|---|
| Error table (r15) lands typed exceptions per module | every module report §5 | each module test asserts the exact type thrown |
| r56 budget per cdylib; `Native.install/check` | native2.md §2 | `timeImport` test in CI |
| Stop-byte cancellation into every native handle | native2.md §3 | `async_test` cancel-case, `Tui ^C` case |
| `SecurityException`/named security errors | r15 + archive/fs | `archive_security_test` mandatory |
| Constant-time comparisons | hash.md §5.5 | `ct_eq` test |
| Legacy-corpus parity | html/image/cli/tui test files | parity suites green |
| `api_names_test` noun gate | core.md §5.5 | runs at EVERY phase exit |

## 4. Definition of done (the whole *work week* closes)

1. All Phase A–E acceptance suites green under `dart test` on Windows (CI: Linux + macOS tags).
2. The proposal's own examples run verbatim from lib2 (`lib/lib2.dart`-exported APIs):
   `Http.get(...).pipe(File('huge.iso'))`, `...pipe(Archive.unpack(dst:))` ,
   `File('photo.jpg').pipe(Image.load())` → `img.fit(400,300).pipe(File('thumb.webp'))`,
   `Page.shot().pipe(File)`, `Tui.run((term) async { … })`, `Chan`/`Pool` crawler, `box(title:)`
   from inside `Tui`.
3. `native==fallback` equality across hash/archive/image; budgets: `tui`< 15 ms, `cli` loads no
   lib; no `dart:io` stdio dependency in `cli` interactive paths except the Tui-absent fallback.
4. CHANGELOG answered: every gap row in these 12 reports has a resolution line or is explicitly
   deferred with a reason.