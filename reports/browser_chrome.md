# Report · Chrome & Browser Automation (`lib/lib2/src/chrome/chrome.dart`)

> Companion spec: [`../proposals/11_chrome.md`](../proposals/11_chrome.md). The proposal's headline
> is: **headless (and visible) Chrome automation driven by a native CDP client over native
> WebSockets** (proposals/11:1, proposals/13:Phase 5 "Chrome CDP Engine: tungstenite").
> Current `lib2` drives CDP with the **Dart `WebSocket`** instead, and never manages the profile
> lifecycle the way the native layer would.

---

## 1. Current state of `lib2`

`lib/lib2/src/chrome/chrome.dart` (298 lines) ships:

- `Chrome.launch({executable, headless=true, port, args, visible})` — spawns the binary with
  `--headless=new --disable-gpu --remote-debugging-port` and a fresh `--user-data-dir`, then polls
  the `DevToolsActivePort` file and `GET /json/version`.
- `Chrome.connect(port, host)` — attaches to a running instance.
- `Browser.{version,newPage,pages,close}` — HTTP endpoints; `close()` kills the process and deletes
  the temp profile.
- `Page.{goto,title,content,eval,click,fill,waitFor,screenshot,close}` — a hand-rolled
  id→`Completer` CDP websocket (`_Cdp`).

There is no `pdf`, no `type`, no network/console interception, no real mouse events, no profile
locking, no download folder control, no reaper (the launched child survives if `close()` is not
called on Windows until the process ends).

---

## 2. Gap analysis

| # | Proposal promise (11:file:line) | `lib2` today | Severity |
|---|---|---|---|
| G1 | `chrome.open(url)` returns a page (11:1) | `chrome.newPage()` then `page.goto(url)` — two calls, different noun | MAJOR |
| G2 | `page.html()` (11:1, 4.1) | `page.content()` — same meaning, different name | MAJOR |
| G3 | `page.type('#user', 'alice')` (11:2) — types per char into a focused element | ✗ only `fill` sets `el.value` + fires `input`; React/IE form hooks missed; caret/IME not handled | **BLOCKER** |
| G4 | `page.click('#submit')` — a real CDP `Input.dispatchMouseEvent` at the element's coords | `eval('document.querySelector(sel).click()')` — DOM `.click()`, no hover, no option guard, no `waitForNavigation` | MAJOR |
| G5 | `page.wait('#dashboard')` (11:2) | `waitFor(selector)` in a busy-poll of `Runtime.evaluate` — 100 ms ticks, no CDP events, no MutationObserver | MINOR (behaviour drift) |
| G6 | `page.eval('document.title')` (11:2) | `eval(String)` ✓ | ok |
| G7 | `shot().pipe(File('screenshot.png'))` — a `Reader` whose bytes pipe (11:3) | `page.screenshot()` returns `Uint8List`; works with `(await …).pipe()` only — the proposal's `await page.shot().pipe(…)` needs `shot()` to return an awaitable/Reader directly | MAJOR |
| G8 | `shot(full: true)` (11:4.2) | `screenshot(fullPage: true)` ✓ (same meaning) | MINOR |
| G9 | `page.pdf()` → bytes, pipeable (11:3, 4:3) | ✗ entirely missing | **BLOCKER** |
| G10 | `chrome.close()` cleans up (11:4.3) | kills only the single child; **grandchildren** (renderer/gpu) are not tree-killed (CONVENTIONS §6 r42); temp profile delete has no retry | **BLOCKER** |
| G11 | Pool+Chrome multi-page scraping (11:4.3) | works in principle but each `Page` opens its **own** websocket with **no** shared pump — connection churn | MINOR |
| G12 | Waits: `wait` for navigation + condition (11:4.1) | `goto` waits for `Page.loadEventFired` only; SPA navigation after `click` unhandled (needs `Page.frameNavigated`/`Page.loadEventFired` race-safe wait) | MAJOR |
| G13 | Native CDP over native WebSockets (11:1, 13:5) | Dart `dart:io` WebSocket; no ABI, no worker, no native cache | **BLOCKER** (native goal) |
| G14 | Launched state is a resource (`start`/`connect`, `close()`) | `launch`/`connect` + `close` ✓ | ok |
| G15 | `Html.parse(await page.html())` feeds `html` module (11:4.1) | wireable ✓ | ok |

### Additional robustness gaps not in the proposal but required by PLAN.md/Windows

- **Executable discovery** must honour `DART_TOOLKIT_CHROME` (PLAN.md §9) — `lib2` reads a generic
  `CHROME_PATH` instead.
- **Profile locking / steal** — a `--user-data-dir` in use (`<profile>\lockfile`, Windows error 32)
  must be detected and refused before launch.
- **Alive-check** must be `OpenProcess`+`GetExitCodeProcess` (Windows), not a `kill(); exitCode`
  race.
- **The download folder**: backslash paths, copy-then-rename across volumes via
  `FileBridge.rename` fallback, a download's final rename honouring conflicts.
- **Tree kill on cancel/timeout/signal**: everything Chrome spawned dies together.

---

## 3. Native requirements (`native2` → `dart_toolkit_chrome` ABI 1)

`native2_architecture.md` §7 gives the FFI. Ownership split:

| Concern | Owned by |
|---|---|
| Binary discovery (`DART_TOOLKIT_CHROME`, `LOCALAPPDATA`, Program Files, `/Applications`, `which`) | Dart (`chrome.dart`) passes `exe` path to `tk_cdp_launch` |
| Process spawn, tree ownership (Windows **Job Object**), profile dir lock, temp-profile **reaper**, "alive" check | native `chrome` crate |
| WebSocket + CDP framing, id→completer, event dispatch, `waitFor` via `Runtime.evaluate`-as-needed | native `chrome` crate (tungstenite) |
| `click` coordinates (scroll into view + bounding box), `type` keystrokes (`Input.dispatchKeyEvent`), `screenshot`/`pdf` capture | native exports |
| `Page`/`Browser` Dart objects, `pipe(Writer)` of shot/pdf bytes, `Tui` friendliness | Dart |
| Network/console/request interception, cookies, storage | phased native addition |

Each long call (`open`, `wait`), `shot`, `pdf`) runs on the crate's worker with the standard **stop
byte**, so `Chrome.close()`/task cancel halts a hung render immediately (r53).

---

## 4. Actionable implementation specification

### 4.1 Naming & surface (Phase 1 — keep the Dart WebSocket, fix the API)

1. **Rename `newPage`+`goto` → `open`:** `Browser.open(String url)` creates a tab and navigates;
   `Browser.newTab({String? about})` stays for blank tabs. Alias `goto` on `Page` to `open`.
2. **Add `Page.type(String selector, String text)`** implemented as CDP `Input.dispatchKeyEvent`
   over the current prototype (focus the element first, `insertText` when supported).
3. **Add `Page.pdf({bool landscape, String format})`** → `Uint8List` via `Page.printToPDF`.
4. **Return pipeable captures:** keep `screenshot()` but add `shot()` returning
   `Future<Uint8List>` and rely on `Uint8List.pipe` (core pipe) — and document the two forms —
   or make `Page.shot()` return a `Reader`; choose **one** (see core.md G5). Recommended: `shot()`
   returns `Future<Uint8List>` and the `await x.pipe` extension covers the proposal example.
5. **`_Cdp` hardening:** apply a request timeout (default 30 s, CONVENTIONS §4 r22), `close()` waits
   for the socket to drain, `Runtime.evaluate` `awaitPromise:true` keeps its current semantics.
6. **Tree kill on close:** on POSIX kill `-pid`; on Windows start Chrome inside a Job Object
   (native, Phase 2) or enumerate `taskkill /T /F` (transitional, PLAN.md §2). Retry deleting the
   temp profile.
7. **Tests** (`test/chrome_test.dart` for lib2, mirroring legacy): launch, open, eval, click on a
   `data:`/local serving page, wait, screenshot non-empty PNG signature, pdf starts with `%PDF`,
   close cleans the temp dir, connect to an externally started instance.

### 4.2 Native CDP engine (Phase 2 → `dart_toolkit_chrome`)

Reuse the FFI table in native2 §7. Implementation order:

1. `tk_cdp_launch` / `tk_cdp_attach` + event pump worker + id/completer map (Rust `HashMap<u32,
   oneshot::Sender<String>>` on the worker; results cross as `give()` strings).
2. `tk_cdp_open` (navigate + `waitForLoad`), `tk_cdp_eval` (return by value, `exceptionDetails` →
   typed error), `tk_cdp_wait`.
3. `tk_cdp_click` (`DOM.getContentQuads` → center → `Input.dispatchMouseEvent` pressed/released),
   `tk_cdp_type` (keyDown/text/keyUp with `char`), then `tk_cdp_shot` / `tk_cdp_pdf`.
4. Windows job-object tree kill + alive check + profile lock detection (share the logic from
   PLAN.md §9 with the `process` module's `tk_process_kill_tree`).
5. ABI: `dart_toolkit_chrome` starts at **1**; Dart loader key `chrome`; `Native.install()`/
   `Native.check()` gain it.

### 4.3 Acceptance

- `Chrome.launch(headless:false)` on Windows: spawn, drive, `close()` leaves **no** child.
- A JS-rendered SPA: `open` → `wait('.product-card')` → `page.html()` contains hydrated markup
  (proposal 11:4.1).
- Cancel `page.pdf()` mid-way → `CancelledException`, browser still usable.
- `(await page.shot()).pipe(File('x.png'))` writes a file opening in any viewer; `Image.read` of it
  succeeds (feeds `image` module — proposal 11:4.2 pipeline).