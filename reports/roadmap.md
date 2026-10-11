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
2. **Rewrite, then cut over:** `native2` is a greenfield rewrite in a new `native2/`
   workspace — no code shared with the legacy `native/` tree, which is frozen the day the
   rewrite starts. `lib2` carries a pure-Dart fallback only while each subsystem is being
   rewritten; at cutover the fallback is deleted and without the library those calls are
   `UnsupportedError` (r50). The rewrite covers everything legacy does (digests, archives,
   image, content decode, torrent engine) plus the two missing subsystems (chrome, tui), so
   no legacy code remains.
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

### Phase C — native2 rewrite + cutover (weekday 3)
The legacy `native/` tree is frozen reference material. The rewrite lives in a greenfield
`native2/` workspace (new crates, new ABI starting at 1 per cdylib, no `#[path]` into
legacy), is differential-tested against the legacy cdylib, then replaces it: `native/` is
deleted, `tool/build_native.dart` and the loader switch to the new cdylibs, and the `lib2`
Dart fallbacks are deleted (r50). Order:
1. **`native2/common` rewrite** — error slot, guard, (pointer, length) views, allocator,
   handle protocol, stop-byte/watch, progress callback, `exports!(1)`. (`native2.md` §2,8)
2. **`native2/engine` rewrite** — digests/MACs (`tk_digest_new/update/finish/free`, real
   XXH3, `tk_mac_new`, `tk_hmac`, `tk_digest_files`) — RAM-drop: 16 MiB streaming equality
   against the legacy cdylib, not against a Dart fallback. (`native2.md` §5)
3. **`native2/engine` archives** — streaming steppers `tk_archive_open/next/member` (zip,
   tar, tar.gz) + zstd decode from scratch; `Archive.open(member).pipe` and RAM-ceiling
   unpack. (`archive.md` §5.3–4)
4. **`native2/engine` image** — jpg/webp/qoi/gif decode, jpg/webp encode w/ `quality` from
   scratch, then the `Image.load()` pipe sink. (`image.md` §5.2–3)
5. **`native2/engine` fs + process** — `tk_chmod`/`tk_copy_file`/`tk_file_id` rewritten,
   new `tk_rename` (Windows 5/32 retry) and `tk_process_kill_tree` in the new `process` crate.
   (`io_fs.md` §5.4, `process.md` §5.3)
6. **`native2/torrent` rewrite** — the BitTorrent engine rewritten into the new workspace.
7. **Cutover** — parity gates green, then: delete `native/`, repoint `tool/build_native.dart`
   + loader + `Native.install()/check()` at the new cdylibs, delete the `lib2` Dart
   fallbacks. From here a missing library is `UnsupportedError`, never a silent fallback.

**Exit gate C:** new-vs-legacy byte parity across the whole hash set (`tk_digest*` vectors +
16 MiB streaming); `unpack(pack(d)) ≡ d` for zip/tar/tar.gz through the rewritten stepper +
image round-trips through the rewritten codecs; Windows rename-retry test passes with a held
handle; kill-tree reaps a 3-level chain; `native/` deleted and the suite green without it.

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

### Phase G — legacy `lib/` removal (last; only after A–F are green)
`lib2` becomes the package: `lib/lib2/*` moves up to `lib/*` and the old tree is deleted.
Prerequisites: Phase C cutover done (fallbacks gone, r50; `native/` already deleted), Phase D/E
native crates (`chrome`, `tui`) landed, all Phase A–F exit gates green. Order:
1. **Surface parity** — every `lib/*.dart` topic has a `lib2` successor or a written deferral.
   The seven topics with no `lib2` equivalent today must each resolve first: `collection`,
   `pick`, `scrape`, `testing`, `torrent` (Dart surface over `native2/torrent`), `xml`,
   `xpath`. No silent loss: every old verb maps to a new noun, or gets a CHANGELOG deferral
   line with a reason.
2. **Consumer migration** — `example/` (keybox per `PLAN.md` §0 runs verbatim from `lib2`),
   `tool/` (`build_native.dart`, benches, `module_bench.dart`), and the old `test/*_test.dart`
   suite move to the `lib2` surface first. `Makefile` follows: `FORMATTED`, the `native*`
   recipes and `audit` point at `native2/`; `test/layering_test.dart` is rewritten for the
   `lib2` graph; the `api_names` noun gate keeps running at every step.
3. **Deletion** — move `lib/lib2/*.dart` → `lib/*.dart` and `lib/lib2/src/*` → `lib/src/*`
   (fixing imports/exports to the new paths), then delete the old `lib/src/` tree. One
   commit, so a checkout never sees a half-moved package.
4. **Docs & release** — README examples compile from the new paths (doc-examples test),
   CHANGELOG carries one removal entry naming every dropped/deferred verb, version bump
   per the owner's rule (CONVENTIONS §10 r63).

**Exit gate G:** no import of the old surface remains (a search for
`package:dart_toolkit/` imports that resolve outside the moved tree is empty);
`dart analyze --fatal-infos`, `dart format --set-exit-if-changed lib test tool example`,
and the full `dart test` suite are green with the old tree gone; `make` is green;
keybox still runs per `PLAN.md` §0.

## 3. Cross-cutting work queue (r-numbers honoured)

| Concern | Where | Gate |
|---|---|---|
| Error table (r15) lands typed exceptions per module | every module report §5 | each module test asserts the exact type thrown |
| r56 budget per cdylib; `Native.install/check` | native2.md §2 | `timeImport` test in CI |
| Stop-byte cancellation into every native handle | native2.md §3 | `async_test` cancel-case, `Tui ^C` case |
| New-vs-legacy parity, then legacy deleted | r50 + native2.md §9 | parity suites green with `native/` gone |
| `SecurityException`/named security errors | r15 + archive/fs | `archive_security_test` mandatory |
| Constant-time comparisons | hash.md §5.5 | `ct_eq` test |
| Legacy-corpus parity | html/image/cli/tui test files | parity suites green |
| `api_names_test` noun gate | core.md §5.5 | runs at EVERY phase exit |
| Legacy `lib/` removal | Phase G | gate G green with the old tree gone |

## 4. Definition of done (the whole *work week* closes)

1. All Phase A–G acceptance suites green under `dart test` on Windows (CI: Linux + macOS tags).
2. The proposal's own examples run verbatim from lib2 (`lib/lib2.dart`-exported APIs,
   pre-G paths; Phase G moves them up to `lib/`):
   `Http.get(...).pipe(File('huge.iso'))`, `...pipe(Archive.unpack(dst:))` ,
   `File('photo.jpg').pipe(Image.load())` → `img.fit(400,300).pipe(File('thumb.webp'))`,
   `Page.shot().pipe(File)`, `Tui.run((term) async { … })`, `Chan`/`Pool` crawler, `box(title:)`
   from inside `Tui`.
3. New-vs-legacy parity, then fallback deleted: the rewritten hash/archive/image output
   is byte-identical to the legacy cdylib on the corpus vectors; after cutover the Dart
   fallbacks are gone (r50) and the legacy `native/` tree is deleted. Budgets: `tui` < 15 ms,
   `cli` loads no lib; no `dart:io` stdio dependency in `cli` interactive paths except the
   Tui-absent fallback.
4. CHANGELOG answered: every gap row in these 12 reports has a resolution line or is explicitly
   deferred with a reason.
5. Legacy removed (Phase G gate): `lib/lib2/` moved up to `lib/`, the old `lib/src/` tree
   deleted, `example/` + `tool/` + tests on the new surface, `make` green, keybox still
   running per `PLAN.md` §0.