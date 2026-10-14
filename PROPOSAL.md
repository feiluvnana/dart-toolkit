# Library Syntax & Architecture Proposal Guide

**The shift:** keep the shell-pipe model and the call-site shapes that already work, and change three
things. Every **hidden runtime contract** becomes a type: no more `dynamic` probing, `Object` data
parameters or runtime `Type ==` chains. Every **process-wide resource** gets one owner: signals,
HTTP connections and POSIX metadata calls. Every **O(n) per call** that should be O(1) goes: appends,
body copies, list appends, cache keys. Most call sites stay as they are. Where the syntax changes, it
gets shorter: `body: .json(x)`, `choose(q, hits, label: …)` returning a `Hit`, `Pool.map` for I/O
lanes. Names that read ambiguously get the longer name that says what they do (`waitFor`,
`finalUrl`, `hexDigest`); see **Naming**.

**Kept as-is (the good ideas):**

| Idea | Why it stays |
| --- | --- |
| `Reader` / `Writer` / `Pipe` / `Closeable`, `a \| p > w`, null stages | One vocabulary for every byte source; backpressure for free |
| Future mirrors (`Http.get(u).html().$('a').attrs('href')`) | One `await` per chain |
| Outcomes are values (404 = `Response`, exit 1 = `Output`, missing = `null`) | `switch`/`if` instead of `try` |
| Sealed `Entry`, sealed `Def<T>`, `ctx(def)` typed by its definition | Exhaustive and typed at the call site |
| Lazy content (`screenshot`, `pdf`, `encode`, `pack`) | No work until it is stored |
| Routing by function in `Scrape` (`follow(urls, handler)`) | No string routes, typed `emit` |
| State-driven `Tui.run` with `Pick`/`Field`/`Scroll` held by the state | Focus and selection survive `go` |

Evidence: every claim marked **(verified)** was run against this tree on 2026-10-14 (Dart 3.13.4,
macOS arm64), and timings are A/B pairs from the same run. Claims without the mark come from reading
the code.

### OS specifics: nuances and problems

The target is macOS, Linux and Windows. `dart:io` hides less than it seems to: terminal input,
signals, file metadata and process launch each behave differently per OS. Today those differences
are handled ad hoc inside each module, and nothing on Windows has been verified from this Mac.
**(unverified)** marks a Windows claim made from the code that needs `tool/keylog.dart` or a run on a
Windows PC before it lands.

| Area | macOS / Linux | Windows | Problem today → proposal |
| --- | --- | --- | --- |
| **Key input** | A child `/bin/sh -c 'trap "" INT; exec cat -u /dev/tty'` reads keys, so stdin never pins the VM. The terminal sends VT sequences (`ESC [ A`) | `io.stdin` is read directly in raw mode (`echoMode`/`lineMode = false`). Those flags don't turn on virtual-terminal input, so Up/Down/Left/Right produce no character and are dropped before Dart sees them **(unverified)** | **Arrows never arrive and Esc seems to miss in the VS Code terminal.** The decoder's `0x00`/`0xE0` branch is the C runtime `_getch()` format, which Dart's stdin probably never produces. A lone Esc is held 150 ms (`Console`) or up to 1 s (`Tui`), and VS Code keeps Esc for its own widgets while they are open. → A Windows input helper on the same pattern as `cat`: a child that reads `[Console]::ReadKey($true)` and writes VT bytes. It costs a few hundred ms of startup per input session. *Alternative:* `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_INPUT)` through FFI, which rule 14 excludes. Check first with `dart run tool/keylog.dart` (no output for Up = dropped) |
| **No `/dev/tty`** | Containers, `nohup` and CI have no tty, so input falls back to `io.stdin`, which keeps the VM alive until EOF | — | Documented, no change |
| **Signals** | SIGINT, SIGTERM, SIGHUP, SIGWINCH | Only SIGINT can be watched (the others throw); there is no SIGWINCH, so a resize needs the size polled | Three modules each watch signals and call `exit`. A live watch keeps the VM alive **(verified, macOS)**. → `src/exit.dart` is the only subscriber, watches only the signals the OS has, and makes resize detection a per-OS strategy (SIGWINCH, or a size poll at frame time) |
| **File modes and times** | No `chmod`/`utimes` in `dart:io`, so the code runs one `chmod`/`touch` process per entry. macOS `touch -t` keeps whole seconds only; Linux `touch -d @s.frac` keeps sub-seconds | No POSIX modes; folder mtimes are not kept | Fork storms (see fs, archive). → Batched `src/posix.dart` and `cp -pPR`; Windows skips both. Folder mtime precision differs per OS, and the docs say so |
| **Atomic replace** | `rename(2)` replaces atomically, even over an open file | `rename` over a target that another process holds open (an editor, antivirus, the indexer) fails with a sharing violation **(unverified)** | `File.write` can throw intermittently on Windows. → A bounded retry (3 attempts, 50 ms apart) on that error only, in `_atomicWrite` |
| **errno meanings** | 17 = `EEXIST`, 18 = `EXDEV` | 17 = `ERROR_NOT_SAME_DEVICE` | `_isExdev` treats 17 as cross-device everywhere. → Gate it by platform |
| **Broken pipe** | `EPIPE` = 32 | `ERROR_BROKEN_PIPE` = 109, `ERROR_NO_DATA` = 232 | `Shell.filter` checks 32/109 plus message text. → Add 232 and drop the text matching |
| **Opening a URL/path** | `open` (macOS), `xdg-open` (Linux; may be missing on headless boxes and in WSL, and may block, hence the 10 s wait) | `cmd /c start "" <target>` | **Injection on Windows:** `cmd` re-parses `&`, `\|` and `^` in the target. → `rundll32 url.dll,FileProtocolHandler <target>`. A missing `xdg-open` gives a `ProcessException` naming the package to install |
| **Killing a child** | `SIGKILL` reaches only the direct child; anything a `sh -c` command starts survives | `TerminateProcess`, also direct child only | `Shell.filter` failure paths can leave grandchildren running. Documented: use `exec` in `sh -c` |
| **Paths** | `/` | `\` and drive roots (`C:\`); `_strip` keeps drive roots | Temp names built as `'$dir/.name.tmp…'` mix separators. → `p.join` everywhere |
| **Caches** | `~/Library/Caches` (macOS), `$XDG_CACHE_HOME` or `~/.cache` (Linux) | `%LOCALAPPDATA%` | Fine; Chromium downloads once per machine |
| **Colour, Unicode** | Truecolour or 256 colours; `LANG=C` switches to the ASCII theme | Windows Terminal and VS Code handle VT output; legacy conhost may not. Code page vs UTF-8 changes how box drawing and `⠋` look | Capabilities are detected per run (`_Caps`). → One detector in `src/terminal.dart` shared by `Console` and `Tui`, since `Console` currently checks only `hasTerminal`/`NO_COLOR` |

The rule the proposal adds: **an OS difference lives in one `src/` file behind one function.**
Facades never branch on `Platform.isWindows`; they call `src/exit.dart`, `src/posix.dart` or
`src/terminal.dart`. Every Windows-only branch also gets a test that runs on a Windows machine, because a Mac can
cross-build but cannot drive a Windows console.

### Naming

Brevity is good, but not when it comes from clipping names until they are ambiguous. VISION rule 3
now reads **clear names over short names: a name says what the call does, at whatever length that
takes**, and call-site brevity comes from fewer calls, steps and parameters. The bar comes from Effective Dart:
no abbreviations (`eval`, `Ctx`, `Opt`), a `bool` reads as a question (`isSuccess`), a method that
waits, clicks or finishes says so (`waitFor`, `clickToDownload`, `hexDigest`), and one idea has one
name across modules (`fileName()` for a suggested download name, `progressBar` in both `Console` and
`Region`). Names that are already unambiguous stay: `$`, `get`, `pack`, `resize`, `text()`, `html()`,
`close()`. The module sections below use the new names in their proposed snippets.

| Module | Current | Proposed | Why the old name misleads |
| --- | --- | --- | --- |
| chrome | `page.wait(sel)` | `waitFor(sel)` | Reads as a sleep; it waits for an element |
| chrome | `waitIdle()` | `waitForNetworkIdle()` | Doesn't say *what* goes idle |
| chrome | `goto(url)` / `back()` | `goTo(url)` / `goBack()` | One verb family; `goto` is not lowerCamel |
| chrome | `eval<T>(js)` | `evaluate<T>(js)` | Abbreviation |
| chrome | `cookies()` | `cookieHeader()` | Returns one `Cookie:` header string, not cookies |
| chrome | `select(sel, value)` | `selectOption(sel, value)` | "Select" also means pick an element |
| chrome | `upload(sel, reader)` | `attachFile(sel, reader)` | Nothing is uploaded until the form submits |
| chrome | `scroll()` / `scroll(sel, t)` | `scrollToBottom()` / `scrollIntoView(sel, timeout:)` | Two behaviours behind one name; also fixes the positional timeout |
| chrome | `download(sel)` | `clickToDownload(sel)` | The call clicks; the old name hides the side effect |
| chrome | `launch(executable:, profile:)`, `open(block:)` | `chromePath:`, `profileDir:`, `blockResources:` | Say the value's kind |
| http | `res.status()` | `statusCode()` | Status could be a phrase or a state |
| http | `res.ok()` | `isSuccess()` | A `bool` reads as a question; "ok" hides "2xx" |
| http | `res.url()` | `finalUrl()` | It is the URL *after redirects* |
| http | `res.size()` | `contentLength()` | It is the header, nullable, not the body size |
| http, scrape, chrome | `name()` on `Response`/`Visit`/`Download` | `fileName()` | Clashes with `Entry.name()` (basename) |
| fs | `Fs.entry(path)` | `Fs.lookup(path)` | The one `Fs.` call that does I/O; `file`/`dir`/`link` don't |
| fs | `link.target()` / `resolve()` | `targetPath()` / `resolveTarget()` | Which target: the stored string or the final entry |
| shell | `out.errorText()` | `stderrText()` | Not an error message; the stream's name |
| shell | `Shell.open(target)` | `Shell.openInDefaultApp(target)` | Reads as "open a shell" |
| hash | `hex()` | `hexDigest()` | It finishes the hash; `add` after it throws |
| json | `value<List<T>>()` | `listOf<T>()`, `mapOf<T>()` | The element type is the parameter (see json) |
| html | `.map((e) => e.text()).toList()` | `texts()` | Pairs `text`/`texts` like `attr`/`attrs` |
| core | `reader.to(writer)` | `writeTo(writer)` | `to` alone doesn't say it runs the pipeline |
| pool | `Pool.run(job)` / isolate `map` | `Pool.compute(job)` / `computeAll(items, job)` | Says "off-isolate"; `Pool.map` becomes async lanes |
| pool, scrape | `limit:` | `concurrency:` | A limit of what: items, time, depth? |
| pool | `Pool.close()` | `Pool.shutdown()` | Not a `Closeable`; restarts lazily |
| cli | `Opt` `Multi` `Arg` `Def` `Ctx` | `Option` `MultiOption` `Argument` `Param` `Context` | Abbreviations |
| cli | `or:` | `defaultsTo:` | `or` reads as a boolean operator |
| cli | `Command(values:, commands:)` | `params:`, `subcommands:` | `values` are definitions, not values |
| cli | `ctx.rest()` / `parse(argv)` | `extraArgs()` / `run(argv)` | `parse` runs handlers and returns an exit code |
| console | `key()` / `clear()` | `readKey()` / `clearScreen()` | Verbs for actions |
| console | `spin(label, work)` | `withSpinner(label, work)` | It wraps `work`; it isn't a spinner |
| console, tui | `bar(…)` / `Bar` | `progressBar(…)` / `ProgressBar` | "Bar" alone means nothing on its own |
| tui | `Pick<T>` / `Field` / `Scroll` | `Selection<T>` / `TextField` / `ScrollPosition` | Nouns for state objects (`Pick` is a verb) |
| tui | `Bind`, `region.on(events)` | `Binding`, `region.bind(events)` | Same word for the type and the call |
| tui | `app.go(s)` / `say(m)` / `print(d)` / `copy(t)` | `goTo(s)` / `showStatus(m)` / `printAbove(d)` / `copyToClipboard(t)` | `say`/`print`/`copy` hide where the output goes |
| tui | `rows([…])` / `cols([…])`, `pick.set(xs)`, `field.set(t)` | `splitRows` / `splitColumns`, `setItems`, `setText` | Say what is split or set |
| scrape | `Scrape.run(…, delay:, cache:)` | `Scrape.crawl(…, perHostDelay:, cacheDir:)` | Say the scope and the kind |

*Trade-off:* call sites get longer: `res.ok()` becomes `res.isSuccess()` and `page.wait` becomes
`page.waitFor`. This goes against the "concise" priority on purpose. Each rename above fixes a
name that can be misread, and IDE completion makes the extra characters cheap to type. Names with no
second reading stay short.

### Folder architecture

Today, `lib/<module>.dart` holds the 14 public facades plus `core.dart`. `lib/src/` holds `terminal.dart`
(shared tty), `charset.dart` (WHATWG decoders) and `tui.dart` (4,880 lines: engine, painter, widgets,
markdown, diff, test harness). `example/` holds real scripts, `test/` has one file per module plus pty
drivers, and `tool/` has `keylog.dart`.

The proposal keeps the public layout and gives the cross-cutting logic, now duplicated across
modules, one private home each:

```
lib/
  core.dart  archive.dart  chrome.dart  cli.dart  console.dart  fs.dart  hash.dart
  html.dart  http.dart  image.dart  json.dart  pool.dart  scrape.dart  shell.dart  tui.dart
  src/
    terminal.dart   stdin child, key decoder, modes            (unchanged)
    keys.dart       NEW one key-name table: tui, console, chrome.press
    exit.dart       NEW the only signal owner; ordered cleanup hooks
    retry.dart      NEW backoff + Retry-After + retryable(e): http, scrape
    posix.dart      NEW batched chmod/touch, cp -pPR: fs, archive
    origin.dart     NEW file-name rules (content-disposition, URL tail): http, scrape, chrome
    charset.dart                                                (unchanged)
    tui/            session · region · paint · widgets · markdown · diff · harness
example/  test/  tool/
```

| Rule | Today | Proposed |
| --- | --- | --- |
| A module imports core + its engine | `chrome`/`scrape` mix `package:dart_toolkit/…` and relative imports | Relative imports everywhere inside `lib/` |
| Shared logic | Signals ×3, retry ×2, chmod/touch ×2, key names ×2, file-name rules ×2 | One `src/` file each |
| Test seams | `TestSession` lives in `src/tui.dart` | `src/tui/harness.dart`, still never exported |

### Dependency choices

| Capability | Today | Proposed | Why |
| --- | --- | --- | --- |
| Bytes, files, processes, sockets | SDK `dart:io` | SDK | — |
| Paths | `path` | keep | Correct Windows rules; tiny |
| HTTP | `http` over `dart:io` | **SDK `HttpClient` directly** | `package:http` only adds `IOClient` + `ClientException` mapping; redirects and retries are already in-house. Pooling (see http) needs the raw client. One less stream wrapper per chunk |
| Charset decoding | in-house (WHATWG tables) | keep | No pub engine covers the CJK legacy set; tables parse lazily |
| HTML + CSS selectors | `html` + `csslib` (+ `html/src/query_selector.dart`) | keep, **pin `html` to `>=0.15.7 <0.16.0`** and cover `matches` in tests | The `src/` import is an implementation import and can break on a minor bump |
| JSON | SDK `dart:convert` | keep | — |
| Browser | `puppeteer` | keep | Only CDP client with downloads and interception |
| zip | `archive` | keep | Central directory needs random access |
| tar / tgz | `archive`, in memory | **in-house streaming tar (~150 lines) + SDK `gzip`** | `pack`/`unpack` run at O(largest member) memory instead of O(archive) |
| Hashes | `crypto` | keep | — |
| Images | `image` | keep; heavy calls go through `Isolate.run` | Pure Dart codecs; no native |
| Worker isolates | `worker_manager` | keep **until an A/B against `Isolate.run`** | Measured fine (see pool); a swap needs numbers, not taste |
| CLI, console, TUI, terminal | in-house | keep | — |
| POSIX modes and times | one `chmod`/`touch` process per entry | **batched**: one `chmod` per distinct mode, `cp -pPR` for trees; later FFI into libc (see Native core) | `dart:io` has no chmod/utimes |

### Native core (C or Rust)?

The question is whether `image`, `archive`, `fs` and the terminal should sit on a compiled C or Rust
library instead of pure Dart and child processes. **Recommendation: no compiled core, but allow
`dart:ffi` calls into libraries the OS already ships.** That relaxes rule 14 from "no native code" to
"no native *artifacts*". The heavy engines get a native backend only when an A/B shows they are the
bottleneck in a real script, and then as an optional package.

| Option | Wins | Costs |
| --- | --- | --- |
| **A. FFI into OS libraries only** (`libc`, `kernel32`): no build, nothing to download | `chmod`/`utimensat`/`clonefile`/`copy_file_range` in-process, which ends the fork storms in fs and archive (one `chmod` fork per file today). `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_INPUT)` fixes Windows arrows with no helper process. Signals stay in `dart:io` | Per-OS bindings (~300 lines: POSIX + Win32) that need tests on all three OSes. A wrong struct layout crashes the VM instead of throwing |
| **B. A Rust core** (`image` + `fast_image_resize`, `zip`, `zstd`/`xz`, `walkdir`) built through Dart build hooks | Image decode and resize are likely several times faster (SIMD, threads) — not measured here. New formats (zstd, xz, 7z, WebP encode). Streaming zip | Builds for 6 targets (macOS/Linux/Windows × x64/arm64) on every native change. Either a Rust toolchain on every user's machine or prebuilt binaries per release: the "release assets by source hash" setup this repo dropped in v2. A first-run download or a bigger package. A panic or segfault kills the script with no Dart stack. FFI calls block the isolate unless the work runs on native threads with ports, which takes back part of the speed-up |
| **C. A C core** (libjpeg-turbo, libpng, zlib-ng, libarchive) | The same speed as B, with mature libraries | Everything B costs, plus memory-unsafe parsers of untrusted input (images and archives from the web); these libraries have long CVE histories. Not recommended |
| **D. Stay pure Dart** (today) | `dart run` works everywhere with nothing to install; one stack trace; Windows from the Mac by cross-compile only | Slow image work and forks per file — mostly fixed by the batching in this proposal and by A |

What each module would get:

| Module | Bottleneck today | Pure-Dart fix in this proposal | Would native help? |
| --- | --- | --- | --- |
| fs, archive (modes, times) | One `chmod`/`touch` process per entry | Batched `chmod`, `cp -pPR` | **Yes, through A**: zero forks, in-process, no build |
| terminal (Windows keys) | Arrows dropped | ReadKey helper process | **Yes, through A**: `SetConsoleMode`, no helper |
| image | Pure-Dart codecs on the main isolate | `Isolate.run` (no frozen UI), area-average resize | Maybe, through B: only if batch-thumbnail scripts are measured slow after `Isolate.run`; ship as optional `dart_toolkit_native` with the Dart path as fallback |
| archive (formats) | No zstd/xz | Out of scope | B, only when a script needs those formats |
| gzip, hashing | `dart:io` gzip is already native zlib; `crypto` is fast enough for scripts | — | No |
| http, html, json, cli, tui | Network- or allocation-bound | Pooling, caches, zero-copy | No |

Order: land the pure-Dart fixes, add the FFI bindings of option A, then A/B the image pipeline (a
24 MP JPEG decode → resize → encode, alternating rounds) before considering B.

---

## Module: archive

**Current Syntax / API:** pack is a lazy `Reader` and unpack is a `Writer`. Every member is checked
before anything is written, and unpacking merges into the target and never deletes from it.

```dart
await (Archive.pack('site', .zip) > Fs.file('site.zip'));
await (Http.get(releaseUrl) > Archive.unpack('vendor'));
await (Http.get(dumpUrl) | Archive.gunzip() > Fs.file('dump.sql'));
```

**Proposed Syntax / API:** the call sites don't change. The behaviour behind them does.

```dart
await (Archive.pack('site', .tgz) > Fs.file('site.tgz'));      // streams: one member in memory at a time
await (Http.get(releaseUrl) > Archive.unpack('vendor'));        // tar/tgz stream straight to the temp sibling
await (Http.get(dumpUrl) | Archive.gunzip() > Fs.file('dump.sql'));  // a truncated stream now fails
```

**Why This Change Was Made:** the shape is already right: a format enum, Reader out, Writer in. What
is wrong is correctness under truncation, memory, and the fork count.

**Bugs & Performance Bottlenecks Addressed:**

- **Truncated gzip passes silently (verified).** 1 MiB of random data, gzipped with the 8-byte
  trailer removed, passes `Archive.gunzip()` and yields 1,048,576 bytes with no error. The cause is
  `magicCount`, which counts `1f 8b` pairs anywhere in the compressed bytes (about one per 64 KiB of
  deflate output). Above 1, the stream is treated as "concatenated members" and the trailer check is
  skipped. **Fix:** always check the final trailer against the CRC32/ISIZE of the output. A
  multi-member file (bgzip) then fails with `FormatException('multi-member gzip')` instead of
  corrupting silently. *Alternative considered:* an in-house member-aware inflate (~400 lines) that
  knows member boundaries. It is deferred until a real script needs bgzip. (A flipped CRC byte is
  already caught by the SDK decoder (verified); only truncation slips through.)
- **One `chmod` process per member** (`_chmodMember` → `Process.run('chmod')`). Unpacking 1,000
  files forks 1,000 times. `src/posix.dart` groups paths by mode and runs one
  `chmod <mode> p1 p2 …` per distinct mode, chunked under `ARG_MAX`. That is usually 2–3 forks per
  archive.
- **O(archive) memory:** `pack` reads every file into one `a.Archive` before encoding, and
  `unpack` buffers the whole input (`BytesBuilder`). Streaming tar caps memory at the largest member.
  Zip stays in memory because its directory sits at the end; the docs say so.
- `_crc32` and the streaming CRC loop are two copies of one table walk. They merge into one helper.

## Module: chrome

**Current Syntax / API:** chains need no inner `await`, actions auto-wait, and captures are
`Reader`s.

```dart
final page = await Chrome.launch(profile: '.chrome').open(loginUrl, block: ['image', 'font'])
    .fill('#user', name).fill('#pass', pass).click('button[type=submit]').wait('.dashboard');
await (page.pdf() > Fs.file('report.pdf'));
final invoice = await page.download('a.invoice');
await (invoice > Fs.dir('invoices').file(invoice.name()));
```

**Proposed Syntax / API:** the same chains, under names that say what each step does (see Naming).

```dart
final page = await Chrome.launch(profileDir: '.chrome').open(loginUrl, blockResources: ['image', 'font'])
    .fill('#user', name).fill('#pass', pass).click('button[type=submit]').waitFor('.dashboard');
await page.scrollToBottom();                         // infinite lists
await page.scrollIntoView('.load-more', timeout: const Duration(seconds: 5));
await page.attachFile('input[type=file]', Fs.file('cv.pdf'));   // name/path come from Reader.origin()
final rows = await page.evaluate<int>('document.querySelectorAll("tr").length') ?? 0;
final invoice = await page.clickToDownload('a.invoice');
await (invoice > Fs.dir('invoices').file(invoice.fileName()));
await browser.close();                               // and the script now exits
```

**Why This Change Was Made:** `scroll([String? selector, Duration? timeout])` puts two behaviours
behind one name and is the only method with a positional timeout (Dart can't mix optional positional
and named parameters). Splitting it into `scrollToBottom()` and `scrollIntoView(selector, timeout:)`
fixes both. `attachFile` and `evaluate` also drop their `dynamic` and JSON round-trip workarounds.

**Bugs & Performance Bottlenecks Addressed:**

- **The script never exits after `browser.close()` (verified).** Launch, open a page, close, return
  from `main`: the process was still alive 25 s later and had to be killed by an alarm. The same
  flow on raw `puppeteer` exits with 0. The cause is `Browser._watchSignals`, which subscribes to
  SIGINT/SIGTERM/SIGHUP once and never cancels. A live `ProcessSignal.watch` subscription keeps the
  VM alive (verified separately: a bare `sigint.watch().listen` script never exits). **Fix:** the
  `src/exit.dart` registry. `launch` registers a cleanup hook and `close` removes it, and when the
  last hook goes, the signal subscriptions are cancelled.
- **Three signal owners race.** `chrome`, `Console` prompts and `Tui` each watch SIGINT/SIGTERM and
  call `exit`. Ctrl-C during `Console.ask` with a browser open runs console's synchronous
  `exit(130)` while chrome's async `close()` is still awaiting. Chromium and its temp profile are
  orphaned. With `src/exit.dart`, one owner runs the hooks in reverse order, awaited and bounded
  (terminal restore first, then the browsers), and then calls `exit` once.
- **`waitIdle` undercounts.** `onRequest` skips `data:`/`ws:` URLs, but `onRequestFinished`/`Failed`
  still decrement for them, so `_inflight` reaches 0 while real requests are pending and the page is
  declared idle early. Both sides should use one `countable(req.url)` (the typed `req.url`, not
  `(req as dynamic).url`). The 50 ms wall-clock polling becomes a `Stopwatch` plus a completer
  that fires on each 1→0 transition.
- **4–6 CDP round trips per action, with a TOCTOU gap.** `_checkSelector` (evaluate), then
  `waitForSelector(visible)`, then an `enabled` evaluate loop at 100 ms, then `click(selector)`,
  which queries again. An element re-rendered between the check and the click is missed or
  mis-hit. The proposal is one `waitForFunction` predicate (selector valid, attached, visible,
  enabled), polled on `requestAnimationFrame`, that returns the `ElementHandle` the action then uses:
  1–2 round trips.
- `eval<T>` goes `evaluate` → `jsonEncode` → `Json.parse`: two O(n) passes and one transient string.
  It becomes `Json.of(v).value<T>()` (see json).
- **Downloads:** `onDownloadWillBegin` is browser-wide, so a download started by another tab inside
  the gate is credited to this call. Filter on the event's `frameId`. `_stableFile` polls the file
  size *after* the `completed` event, when the size is already final, so drop it. `'$dir/$name'`
  becomes `p.join`.
- `fill` sends one CDP call per character. That stays the default because frameworks listen for key
  events. *Trade-off noted:* `insertText` would make it O(1) calls but fires no `keydown`.

## Module: cli

**Current Syntax / API:** the definition carries the type, `ctx(def)` reads it back typed, and the
result is an exit code, never `exit()`.

```dart
final port = Opt<int>('port', 'Port.', short: 'p', or: 8080);
final url = Arg<String>('url', 'URL to fetch.', required: true);
exitCode = await Command('fetch', 'Fetch pages.', values: [port, url],
    handler: (ctx) => fetch(ctx(url), ctx(port))).parse(argv);
```

**Proposed Syntax / API:** `parse` becomes `run`, because it runs handlers. Abbreviations are
spelled out, and `T` is inferred where `defaultsTo:` or `parse:` gives it.

```dart
final port = Option('port', 'Port.', short: 'p', defaultsTo: 8080);              // Option<int>
final since = Option('since', 'Start date.', parse: DateTime.parse, defaultsTo: DateTime(2020));
final url = Argument<String>('url', 'URL to fetch.', required: true);
exitCode = await Command('fetch', 'Fetch pages.', params: [port, since, url],
    handler: (context) => fetch(context(url), context(port), context(since))).run(argv);
```

**Why This Change Was Made:** §3 of VISION names `run` as "run a program, a job, an app", and
`Shell.run`, `Pool.run`, `Tui.run` and `Scrape.run` follow it. `parse` promises a pure parse but
prints, dispatches and returns an exit code. Inference removes `<int>` when `defaultsTo:` already
says it.

**Bugs & Performance Bottlenecks Addressed:**

- **Runtime `Type` dispatch per token.** `_readTyped` compares `T` against up to 14 types (`_same<T,
  int>()`, `_same<T, int?>()`, …) for every value parsed, and `_typeHint` repeats the chain for
  every usage row. The proposal resolves the reader once in the constructor into a `String → T`
  closure, so each token costs O(1).
- **Sealed hierarchy carries throwing members.** `Flag._parseOne`, `Opt._parseMany` and
  `Arg._mergeMany` all `throw UnsupportedError`: six virtual getters plus three methods per subclass
  to fake a tagged union. They are replaced by one private record per `Def` (`name`, `short`, `help`,
  `read`, `absent`, `kind`) and a `switch` on the sealed subtype where behaviour differs.
- `Ctx.call` scans every command in the chain (`_declares`) on each read. A `Set<Def>` built once at
  parse makes it O(1).

## Module: console

**Current Syntax / API:** everything goes to stderr, prompts are async, a bar is a `Pipe`, and
inside `Tui.run` the same calls become popups.

```dart
final labels = _uniqueLabels([for (final h in all) h.title]);           // example/rawfree.dart
final byLabel = {for (var i = 0; i < all.length; i++) labels[i]: all[i]};
final choice = await Console.choose('Pick a series:', [...labels, _newSearch, _quit],
    clear: true, initial: keep, escapeValue: _newSearch, shortcuts: const {'b': _newSearch, 'q': _quit});
if (choice == _quit) return;
final hit = byLabel[choice]!;
```

**Proposed Syntax / API:** `choose<T>` returns the item. Shortcuts and Escape share one typed
`keys:` map.

```dart
final hit = await Console.choose('Pick a series:', hits, label: (h) => h.title, initial: keep);
final next = await Console.choose('Next?', Next.values, label: (n) => n.label,
    keys: {'b escape': Next.back, 'q': Next.quit});
Console.clearScreen();              // one way to clear; no clear: parameter on every prompt
final me = await Console.withSpinner('Signing in', () => Http.get(api).json());
final bar = Console.progressBar(res.contentLength(), label: 'iso');
```

**Why This Change Was Made:** the example spends about 15 lines mapping labels back to values and
inventing sentinel strings (`'↩ New search [b]'`) that could collide with real titles. With
`choose<T>`, those lines disappear and the sentinels become typed values. `clear:` on four prompts
plus `Console.clear()` (now `clearScreen()`) is two ways to do one thing. The public mutable `Console.forceColor`
gives way to the `FORCE_COLOR`/`NO_COLOR` environment conventions.

**Bugs & Performance Bottlenecks Addressed:**

- **Busy-wait while a human thinks.** `_pumpKeys` loops on `Future.delayed(20 ms)`: 50 wakeups a
  second for as long as a menu is open. Each pump also copies the pending buffer (`List.of`). The
  proposal wakes on a completer completed by the stdin listener, plus one ESC timer.
- `spin` installs a SIGWINCH subscription that does nothing (`listen((_) {})`). It can be removed,
  since the width is re-read on each frame anyway.
- `_byteLine` and `_itemLine` are about 90 duplicated lines. The bar-width loop calls `displayWidth`
  up to 10 times per frame; computing the fixed part once and deriving `width = cols − fixed` makes
  it O(1).
- The rate is measured from construction with `DateTime.now()`, so setup time lowers the
  displayed speed. A `Stopwatch` started at the first tick fixes that.
- **Drift:** the accent is orange (`38;5;173`) in code and cyan in VISION §4.12. One theme constant
  in `src/terminal.dart` serves both `Bar` and `Tui`. The public surface (`key`, `clear`,
  `forceColor`, `initial`/`escapeValue`/`shortcuts`) has grown past VISION's
  `ask confirm choose spin bar`. The proposal settles on `ask confirm choose readKey withSpinner progressBar clearScreen`.

## Module: core

**Current Syntax / API:** four interfaces, two operators and null stages.

```dart
await (Http.get(url) | (quiet ? null : bar) | hash > (dry ? null : Fs.file('a.zip')));
```

**Proposed Syntax / API:** the same operators. `Reader` gains a typed origin and an in-memory
constructor, and `Pipe` gains an abort hook.

```dart
abstract mixin class Reader {
  Stream<List<int>> stream();
  Origin origin() => const Origin();               // url / status / name / path, typed
  static Reader of(List<int> bytes) => _Memory(bytes);
  // bytes() text() pipe() | >  — unchanged; to() is renamed writeTo()
}
final class Origin {
  const Origin({this.url, this.status, this.name, this.path});
  final String? url, name, path;
  final int? status;
}
abstract mixin class Pipe {
  Stream<List<int>> transform(Stream<List<int>> input);
  void abort(Object error) {}                       // the run failed: a Hasher poisons, a Bar prints ✗
}

await (Reader.of(pngBytes) > Fs.file('a.png'));    // bytes reach every Writer the same way
```

**Why This Change Was Made:** `html`, `json` and `chrome` each probe readers with
`(reader as dynamic).url()`, `.status()`, `.path()` and `.name()` inside `try/catch` to find a base
URL, an error status or an upload name. That breaks the package's own `avoid_dynamic_calls` lint and
fails silently on a rename. `Response`, `Visit`, `File` and `Download` override `origin()` instead.
Modules still never import each other.

**Bugs & Performance Bottlenecks Addressed:**

- **The writer-failure probe has side effects.** When a writer throws before it reads, `to()` listens
  to the piped stream and cancels it straight away, so pipe generators run their cleanup. For a
  `Shell.filter` stage, that listen **starts a child process just to kill it**, and for an `Http`
  source it marks the body as streamed. With `Pipe.abort`, `writeTo()` walks the `_PipedReader` chain and
  calls `abort(e)` on each stage without starting anything. *Trade-off:* `Pipe` becomes a mixin
  class. `with Pipe` stays one class and one member; `implements Pipe` must now write `abort`.
- The probe also skips broadcast streams, so a broadcast source leaves `Hasher`/`Bar` unpoisoned.
  `abort` covers every source.

## Module: fs

**Current Syntax / API:** handles do no I/O, `switch (await Fs.entry(p))` is exhaustive, and writes
are atomic.

```dart
await Fs.file('app.log').append('started\n');
await Fs.file('a.bin').write(bytes);          // Object data: String or List<int>, else ArgumentError
```

**Proposed Syntax / API:** text is typed, bytes come through the one `Writer` path, and `append` is a
real append.

```dart
await Fs.file('app.log').append('started\n');        // O_APPEND + exclusive lock: O(len(data))
await Fs.file('notes.md').write('# Notes\n');        // write(String)
await (Reader.of(bytes) > Fs.file('a.bin'));         // bytes: the same path as every other Reader
for (final e in await Fs.dir('src').list(recursive: true)) print(e.path());   // depth-first, by path
if (await Fs.lookup('out') case Dir dir) await dir.delete();                    // was Fs.entry
```

**Why This Change Was Made:** `write(Object)` and `append(Object)` reject anything but `String` and
`List<int>` at runtime, which goes against VISION rule 11. `Reader.of` already exists for every other
Writer, so the byte case needs no second method.

**Bugs & Performance Bottlenecks Addressed:**

- **Concurrent appends lose data (verified).** 20 concurrent `append`s kept **1** line. `append`
  reads the whole file and atomically renames the old content plus the new data over it, so the
  last rename wins. VISION §4.5 promises `O_APPEND` and a lock. The proposal opens with
  `FileMode.append`, takes `RandomAccessFile.lock(FileLock.exclusive)`, writes and unlocks.
- **Append is O(file size) (verified).** Ten 1-byte appends to an 8 MiB file took 607 ms, about
  60 ms each. On top of that, `[...existing, ...add]` builds a boxed growable `List<int>` (8 bytes
  per byte, so about 64 MiB transient for an 8 MiB file). The proposal makes it O(len(data)).
- **Every overwrite forks `chmod` (verified).** 50 overwrites of an existing file took 166 ms against
  14 ms for 50 new files in the same run: about 12× slower, all in `Process.run('chmod')` to keep
  the old mode. The proposal stats the temp file and calls chmod only when its mode differs, which
  under the same umask is almost never.
- **`_isExdev` treats errno 17 as cross-device.** 17 is `EEXIST` on POSIX; it means
  `ERROR_NOT_SAME_DEVICE` only on Windows. The check gets a platform gate.
- **`Dir.copy` forks per directory.** It walks the tree twice (collision pre-check, then copy), stats
  each file three times, and runs `touch` plus `chmod` per folder. The proposal keeps the pre-check
  and then runs a single `cp -pPR` on POSIX, which keeps modes, times and links. The in-process
  loop stays on Windows, where there is no chmod. *Trade-off:* this relies on the platform `cp`
  semantics, which are the same on macOS and GNU for `-pPR`.
- **Recursive `list` is sorted by basename (verified):** `[a, b.txt, a/z.txt]`, where depth-first by
  path is `[a, a/z.txt, b.txt]`. The proposal sorts by the relative path.
- Temp names are built as `'$dir/.name.tmp…'`, which becomes `p.join` (mixed separators on Windows).

## Module: hash

**Current Syntax / API:** one type with three uses: incremental, Writer and tee.

```dart
final id = Hash.md5().add(url).hex();
await (Http.get(isoUrl) | check > Fs.file('disc.iso'));
```

**Proposed Syntax / API:** typed feeds.

```dart
final id = Hash.md5().add(url).hexDigest();               // add(String); hexDigest() finishes
final h = Hash.sha256().addBytes(header).add(name);       // addBytes(List<int>)
if (check.hexDigest() != expected) await Fs.file('disc.iso').delete();
```

**Why This Change Was Made:** `add(Object)` is the last `Object` data parameter left in a sync API.
Two typed methods give compile-time errors in place of an `ArgumentError`.

**Bugs & Performance Bottlenecks Addressed:**

- Three booleans (`_done`, `_poisoned`, `_running`) can encode 8 states, of which 4 are real. The
  proposal uses a private `enum _State { idle, running, done, poisoned }`, so a `switch` makes every
  transition explicit. `_abort(Object e)` ignores its argument and becomes `abort` from core's `Pipe`.
- The guard checks are copied four times (`_checkUsable`, `hex`, `consume`, `transform`). They become
  one `switch`.

## Module: html

**Current Syntax / API:** `$` everywhere, `text()` reads like `innerText`, links resolve against the
base, and `without` never mutates.

```dart
final body = (await Http.get(url).html()).without('script, style, nav').$('article').text();
final links = await Http.get(url).html().$('a.item').attrs('href');
```

**Proposed Syntax / API:** unchanged at the call site, plus `texts()`. The base comes from
`Reader.origin().url` or `.path`.

```dart
final titles = await Http.get(url).html().$('h2.title').texts();   // was .map((e) => e.text()).toList()
```

**Why This Change Was Made:** this module's API is the model the others should follow. The changes
are internal: types and caches.

**Bugs & Performance Bottlenecks Addressed:**

- **The base URL is re-parsed per attribute.** `Element.attr` calls `Uri.parse(base)` on each call,
  so `attrs('href')` over 1,000 links parses the same base 1,000 times. The proposal parses it once
  per `Elements` and shares it with every child `Element`.
- **Each `$` re-parses the selector** with csslib and allocates a new `SelectorEvaluator`. Scrapes
  run the same handful of selectors on every page. A 64-entry LRU of parsed `SelectorGroup`s keyed by
  the selector string makes repeats O(1).
- `_statusOf` and `_baseUrlOf` use `dynamic` and become `origin()`.
- The `package:html/src/query_selector.dart` import gets a pinned range plus a test of `matches` on a
  root element (see Dependency choices).

## Module: http

**Current Syntax / API:** a verb completes at the headers, non-2xx is a value, only a 2xx body can be
piped, and `retries:` is in-house.

```dart
final res = await Http.post('$api/items', json: item);
final form = await Http.post('$base/ajax', body: {'action': 'decode', 'p': '$id'}).json();
await Http.put(uploadUrl, body: Archive.pack('site', .zip));
```

**Proposed Syntax / API:** a sealed `Body` with dot shorthands replaces `body: Object?` +
`json: Object?`.

```dart
sealed class Body {
  const Body._();
  const factory Body.text(String text) = _Text;            // text/plain; charset=utf-8
  const factory Body.bytes(List<int> bytes) = _Bytes;
  const factory Body.form(Map<String, String> fields) = _Form;
  const factory Body.json(Object? value) = _Json;          // application/json
  const factory Body.stream(Reader reader) = _Stream;      // sent once, never retried
}

final res = await Http.post('$api/items', body: .json(item));
final form = await Http.post('$base/ajax', body: .form({'action': 'decode', 'p': '$id'})).json();
await Http.put(uploadUrl, body: .stream(Archive.pack('site', .zip)));
final img = await Http.get(src, retries: 2, insecure: true);   // per-call, for one broken CDN chain
if (!img.isSuccess()) throw StateError('${img.statusCode()} at ${img.finalUrl()}');
await (img > Fs.dir('imgs').file(img.fileName()));
```

**Why This Change Was Made:** `body:` accepts four runtime types plus a `Map` checked entry by
entry, and passing both `body:` and `json:` is an `ArgumentError` at runtime. With `Body`, the
compiler rejects all of that. The syntax compiles on Dart 3.13 (`body: .json({'a': 1})`, verified).
`insecure:` replaces the example's hand-written `_getPageInsecure` (about 40 lines of `dart:io`)
around `CERTIFICATE_VERIFY_FAILED`. It is visible at the call site and scoped to that request.

**Bugs & Performance Bottlenecks Addressed:**

- **No connection reuse (verified).** 100 sequential `Http.get(...).text()` calls to one loopback
  server opened **100 TCP connections**, because `_attempt` builds a fresh `http.Client` per send.
  Over TLS, every request pays a full handshake. **Proposed:** one shared `HttpClient`, counted by
  responses in flight. When the count reaches 0, `close()` is scheduled with `Timer.run`, so a
  sequential `for … await` loop (which calls the next verb within the same microtask chain) still
  finds the open connection, while a finished script exits without waiting on an idle timeout.
  `Scrape` holds the client for the whole crawl. *Alternatives:* (a) today's no reuse; (b) a 1 s
  `idleTimeout`, which delays exit by up to 1 s. Pick by A/B.
- **Body copies.** `bytes()` returns `Uint8List.fromList(cache)` on every call, and also on the first
  read, so peak memory is 2× the body. `text()` copies through `bytes()` too. The proposal returns an
  `UnmodifiableUint8ListView` of the cache: O(1).
- `header()` scans every header with `toLowerCase`. The engine already lowercases keys, so it becomes
  a map lookup: O(1).
- **Permanent errors are retried.** `HandshakeException`/`TlsException` are `IOException`s, so a bad
  certificate is retried with 1 s, 2 s, … backoff. TLS errors get excluded in `src/retry.dart`.
- A 5xx retry drains the error body (`close()` waits up to the full timeout) before it backs off.
  Force-closing the socket instead is fine, since the connection is discarded anyway.
- **Drift:** VISION says the `Future<Response>` mirrors leave the body readable, but
  `ResponseFuture` closes it after every mirror read. Closing is right for one-liners
  (`Http.get(u).status()`). The proposal keeps the code and fixes VISION.

## Module: image

**Current Syntax / API:** encoding is a lazy `Reader`, `Reader.image()` decodes, and
`Region.picture` lives here so `tui` never loads codecs.

```dart
await (Fs.file('photo.jpg').image().resize(width: 800).encode(.jpg) > Fs.file('thumb.jpg'));
```

**Proposed Syntax / API:** unchanged. Resizing defaults to area averaging, and large images are
decoded off the main isolate.

**Why This Change Was Made:** the API is right. The thumbnails it produces are not.

**Bugs & Performance Bottlenecks Addressed:**

- **Resizes use nearest-neighbour.** `img.copyResize` defaults to `Interpolation.nearest` (checked
  in `image` 4.12.0), and the facade never overrides it, so every thumbnail is aliased. The proposal
  uses `Interpolation.average` when shrinking and `cubic` when enlarging. *Cost:* average is
  O(source pixels) where nearest is O(target pixels), so the default needs an A/B on a 24 MP photo
  before it lands.
- **Decoding blocks the event loop.** Decode, resize and encode run on the main isolate, so a large
  JPEG freezes every `Console.spin` and `Tui` frame while it decodes. Above about 1 MP, they go
  through `Isolate.run`, whose result comes back through `Isolate.exit` without a copy.
- `Uint8List.fromList(bytes)` copies any non-`Uint8List` input. With core's zero-copy readers, inputs
  are already `Uint8List`.

## Module: json

**Current Syntax / API:** dotted paths with `*`, `value<T>()` returns null on a mismatch, and
iteration is lazy.

```dart
final port = await Fs.file('conf.json').json().$('server.port').value<int>() ?? 8080;
final tags = p.$('tags').value<List<int>>() ?? [];
final users = doc.$('users').value<List<Map<String, Object?>>>();   // null, for valid data
```

**Proposed Syntax / API:** `value<T>()` reads scalars, `listOf<T>()` and `mapOf<T>()` read flat
collections in one pass, and anything nested is read by iterating.

```dart
final port = cfg.$('server.port').value<int>() ?? 8080;               // unchanged
final names = doc.$('data.users.*.name').listOf<String>() ?? [];      // List<String>?
final counts = doc.$('stats').mapOf<int>() ?? {};                     // Map<String, int>?
final users = [for (final u in doc.$('users')) (name: u.$('name').value<String>() ?? '', age: u.$('age').value<int>() ?? 0)];
final wrapped = Json.of(decoded);                                     // wrap a value you already hold
```

**Why This Change Was Made:** `value<T>()` accepts any `T` but only works for the roughly 30 shapes
hard-coded in `_valueList`/`_valueMap`. Every other shape returns `null` as if the data were wrong.
Two explicit methods with the element type as `T` cover the flat cases in O(n) with no lookup table.
Nested data reads through the existing `Iterable<Json>`, which is also where records come from.

**Bugs & Performance Bottlenecks Addressed:**

- **`value<List<Map<String, Object?>>>()` returns null for valid data (verified)**, and so does
  `List<Map<String, dynamic>>`, the most common REST shape. Only `List<Object?>` works.
- **Mismatches cost O(33·n).** A failing `value<List<X>>()` runs up to 33 `attempt`s, and each one
  allocates and fills a list before it gives up.
- `Json.of` (an addition) lets `chrome.eval` skip `jsonEncode → Json.parse`, and lets scripts wrap
  values without re-encoding them.

## Module: pool

**Current Syntax / API:** one process-wide pool, started lazily, with results in input order, and
`onResult` running on the caller's isolate. Idle workers never keep the script alive.

```dart
await Pool.map(urls, fetch, onResult: (_) => bar.tick());   // isolates
Future<void> lane() async {                                   // example: hand-rolled I/O lanes
  while (next < todo.length) { final i = todo[next++]; await _fetchPage(job, i, imgs[i]); onTick?.call(); }
}
await Future.wait([for (var k = 0; k < 4; k++) lane()]);
```

**Proposed Syntax / API:** I/O concurrency gets its own verb, and isolates get theirs.

```dart
await Pool.map(todo, (i) => fetchPage(job, i), concurrency: 4, onResult: (_) => bar.tick());  // async lanes, this isolate
final thumbs = await Pool.computeAll(paths, makeThumb, onResult: (_) => bar.tick());         // worker isolates
final digest = await Pool.compute(() => hashFile(path));                                     // one job on a worker
```

**Why This Change Was Made:** most concurrency in real scripts is I/O, and the example hand-rolls
lanes (`next++` shared between four closures) because `Pool.map` only offers isolates, which can't
capture a `Job` or a `Bar`. `Scrape` contains a third copy of the same lane loop. One in-isolate
`map` replaces both. `compute`/`computeAll` make the cost (sendable values, isolate hops) visible in the name.

**Bugs & Performance Bottlenecks Addressed:**

- **Measured, not a bottleneck (verified):** 10 sequential `Pool.run` calls took 12 ms in total, and
  `Pool.map` over 200 tiny jobs took 4 ms, boot and dispose included. `worker_manager` stays. An
  `Isolate.run`-based swap (one dependency fewer) waits for an A/B (VISION §6).
- `_sendableError` classifies engine errors by looking for `sendable`/`transferable` in the message
  string. That breaks on any wording change in the SDK. The proposal checks whether the job is
  sendable up front, with one `SendPort` round trip on the first call per job type, and maps
  `IsolateSpawnException`/`ArgumentError` by type.

## Module: scrape

**Current Syntax / API:** routing is by function, `emit` is typed, URLs are deduplicated, and the
cache makes a rerun offline. A browser changes nothing for the handlers.

```dart
final albums = await Scrape.run<Album>([listUrl], listing, delay: Duration(milliseconds: 250), cache: '.cache').toList();
Future<void> listing(Visit<Album> v) async {
  final doc = await v.html();
  v.follow(doc.$('a.album').attrs('href'), album).follow(doc.$('a.next').attrs('href'), listing);
}
```

**Proposed Syntax / API:** the same handlers. The entry point and options get scoped names,
`Visit.fileName()` follows the `Response` rules, and `Visit.origin()` feeds `html()`/`json()`.

```dart
final albums = await Scrape.crawl<Album>([listUrl], listing,
    concurrency: 4, perHostDelay: const Duration(milliseconds: 250), cacheDir: '.cache').toList();
```

**Why This Change Was Made:** the API holds up. The cost is in memory, tabs and duplicated code.

**Bugs & Performance Bottlenecks Addressed:**

- **Body copies.** `Visit.stream()` and `bytes()` return `List<int>.of(_body)`: a boxed growable copy
  at 8 bytes per byte on every read. The proposal returns unmodifiable views.
- **Browser mode opens a tab per URL and serializes the DOM twice:** `eval(outerHTML)` for the body,
  then `page.html()` again (`page.content`) inside `Visit.html()`. The proposal keeps `limit` tabs
  and reuses them with `goto`, and parses the DOM once per visit.
- **No connection reuse** in HTTP mode (see http). The crawl holds one client for its lifetime.
- `Visit.name()` (now `fileName()`) ignores `content-disposition`, while VISION says "as on Response". Both use
  `src/origin.dart`.
- `_waitWork` wakes every 500 ms as a "missed notify" guard. Every enqueue and every finish already
  notifies, so the guard is removed, with a test that crawls a 3-level tree with `limit: 8`.
- `_backoff` and `_parseRetryAfter` copy `http`'s code and move to `src/retry.dart`. The per-host
  `delay` uses `DateTime.now()` and moves to a `Stopwatch` (monotonic).

## Module: shell

**Current Syntax / API:** an argv list with no shell, `Output` as a value, and `filter` as a `Pipe`
that treats EPIPE as an early stop. `text()` drops one trailing newline.

```dart
final head = await Shell.run(['git', 'rev-parse', 'HEAD']).text();
await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
await Shell.open(url);
```

**Proposed Syntax / API:** the same, plus `live:` for build steps a human watches.

```dart
final out = await Shell.run(['dart', 'compile', 'exe', 'bin/app.dart'], live: true);  // tee to our stdout/stderr, still captured
if (out.exitCode() != 0) throw StateError(out.stderrText());
await Shell.openInDefaultApp(reportUrl);                       // was Shell.open
await Shell.run(['make'], env: {'CC': 'clang', 'CFLAGS': null});   // null unsets
```

**Why This Change Was Made:** release scripts run long steps, and either show nothing until the
exit or drop to `dart:io` for `inheritStdio`, losing `Output`. `live:` tees the output and keeps the
value. Nullable `env` values give an unset without a second parameter.

**Bugs & Performance Bottlenecks Addressed:**

- **Command injection on Windows in `Shell.open`.** `cmd /c start "" <target>` hands the target to
  `cmd`'s parser, so `&`, `|` and `^` in a URL run as commands: `https://x/?a=1&calc` starts
  `calc`. The proposal uses `rundll32 url.dll,FileProtocolHandler <target>`, which does no shell
  parsing.
- `env` is merged into `{...Platform.environment, ...env}` by hand, but `includeParentEnvironment`
  (the default) already does that. Each call builds an extra O(env) map, and there is no way to
  unset a variable.
- `Output.bytes()` returns `List<int>.from(_out)`, a boxed copy (8×). It becomes a view.
- In `open`, the `err` variable is dead (always `''`) and the drained stderr is discarded. The
  proposal keeps the first 4 KB for the `ProcessException`.

## Module: src (terminal, charset)

**Current Syntax / API (private):** a restartable `cat -u /dev/tty` child, so stdin never pins the
VM; one `decodeKeys` for `console` and `tui`; WHATWG charset tables parsed lazily.

**Proposed Syntax / API (private):**

```dart
// src/exit.dart — the only ProcessSignal subscriber in the package.
Object onExit(FutureOr<void> Function() cleanup);   // first hook installs SIGINT/SIGTERM/SIGHUP watchers
void offExit(Object token);                         // last hook removed → watchers cancelled, VM may exit
void claimInterrupt(bool Function() asKey);         // Tui: raw-mode Ctrl-C is a key, not an exit
// src/terminal.dart — Windows: keys come from a ReadKey helper child that writes VT bytes (see OS specifics)
// src/keys.dart — one table: 'enter' 'escape' 'pageup' 'f1'… ↔ CSI/SS3 decoding and CDP key names
```

**Why This Change Was Made:** signals and key names are process-wide or package-wide facts, and
today each module keeps its own copy.

**Bugs & Performance Bottlenecks Addressed:**

- See chrome for the hang and the race between handlers. `Tui._quitSync` runs `exit(143)` on SIGTERM
  without awaiting a live `Browser.close()`, which is the same orphaned-Chromium race.
- Key names drift: `Page.press` accepts `esc`, `cmd`, `control`, `meta`, which `Screen(keys:)`
  never produces. `src/keys.dart` fixes one name set (VISION §4.12) and turns aliases into
  `ArgumentError`s.
- `charset.dart` (about 2,600 lines of hex tables) is compiled into every `http` import. It is
  already parsed lazily, so this costs AOT size, not startup. No change; noted for size budgets.

## Module: tui

**Current Syntax / API:** the state is a sealed class, `screen` is a pure description, widget state
lives in `Pick`/`Field`/`Scroll`, and every event goes through one `Bind` map.

```dart
await Tui.run<Page>(Search(), (page, app) => switch (page) {
  Search s => Screen(title: 'search', (r) {
      final [body, foot] = r.rows([0, 3]);
      body.list(s.hits, (h) => h.title, empty: 'type a title, press enter');
      foot.box('query').input(s.query);
    }, keys: {'enter': ('search', () => _search(s)), 'escape': ('quit', app.quit)}),
});
```

**Proposed Syntax / API:** the same model (restored in `8dcc850` on purpose). Only the names change:
nouns for state objects and verbs that say where output goes. The rest of the work is in the engine.

```dart
final class Search extends Page { final query = TextField(); final hits = Selection<Hit>(); }
final class Series extends Page { Series(this.back, this.hit); final Search back; final Hit hit; final chapters = Selection<String>(); }

await Tui.run<Page>(Search(), (page, app) => switch (page) {
  Search s => Screen(title: 'search', (r) {
      final [body, foot] = r.splitRows([0, 3]);
      body.list(s.hits, (h) => h.title, empty: 'type a title, press enter');
      foot.box('query').input(s.query);
    }, keys: {
      'enter': ('search', () async => s.hits.setItems(await Console.withSpinner('searching', () => search(s.query.text())))),
      'ctrl+o': ('open', () => app.goTo(Series(s, s.hits.selected()!))),
      'ctrl+y': ('', () => app.copyToClipboard(s.query.text())),
      'escape': ('quit', app.quit),
    }),
  Series c => Screen(title: c.hit.title, (r) => r.list(c.chapters, (t) => t), keys: {'b escape': ('back', () => app.goTo(c.back))}),
});
```

**Why This Change Was Made:** the state-driven model already removes widget trees and rebuild
plumbing. What is left is the cost of long-running apps (chat logs, streamed markdown) and a single
4,880-line file.

**Bugs & Performance Bottlenecks Addressed:**

- **Appends are O(n²).** `Pick.add` (now `Selection.add`), `addAll` and `remove` rebuild the list (`set([..._items, item])`
  plus an `indexOf`), so adding n messages one at a time costs O(n²). The proposal keeps an internal
  growable list and exposes an `UnmodifiableListView`: O(1) amortised per `add`.
- **The markdown cache key is O(n) per frame.** `'$width:…\n$source'` builds a new string from the
  whole source on every draw, so its hash is never cached (O(n) copy + O(n) hash). A streamed reply
  also re-lays the whole document for each token: O(n²) over the reply. The proposal remembers the last
  `(source, width, layout)` per call site: `identical(source, last)` is an O(1) hit, and
  `source.startsWith(last)` (a streamed append: one compare, no allocation) re-lays only from the
  last closed block. Any other edit lays out from scratch, so a stale layout is never reused.
- Zone `runUnary` marks the frame dirty on **every** callback inside handler work, including each
  socket chunk of a download started from a key. Frames are coalesced to 60 fps, so this costs
  wakeups, not paints. It stays as is, noted as an optional throttle.
- Signals go through `src/exit.dart` (see src).
- The doc comment on `App.notify` still says `TODO(1b): no-op while focused`, but `_notify` already
  checks `_termFocused`. The stale TODO goes.
- **Split** `src/tui.dart` into `session` (loop, zone, routing), `region` (layout), `paint` (cells,
  diffed flush), `widgets` (list, table, input, tabs, scroll, button), `markdown`, `diff` and
  `harness` (`TestSession`). No public change.
