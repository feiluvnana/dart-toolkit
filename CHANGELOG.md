# Changelog

## Unreleased

An API redesign: objects first, one form for each thing, the same readings on every source, and
clearer names. **Every script needs updating**; the old → new for each module is below. Heavy work
now runs in native libraries rewritten from scratch, one per subsystem.

**Shape**

- Files, directories, processes, browsers, pools and channels are objects: `File('a').text()`,
  `Process('git', ['status']).text()`, `Chrome().open(url)`, `Pool(4)`, `Chan<int>(10)`. A
  constructor starts nothing; work starts at the first call.
- Anything readable is a `Source` and anything writable a `Target`. Every source has the same
  readings: `text`, `bytes`, `lines`, `json`, `html`, `image`, `hash`, `unpack` and
  `pipe(dst, resume:)`. `Http.get(u).json()` needs one `await`.
- `close()` is the only way to end anything. Values (`Image`, `Doc`, `Json`) are immutable.
- The method is called on the source: `dir.pack(zip)`, `file.copy(dst)`, `file.symlink(link)`.
- Removed: XML, XPath and `Table` (`xml.dart`, `xpath.dart`, `collection.dart`), the `scrape`
  crawler, `pick`, the Dart torrent client (the native engine stays), `Native.install()`
  (build with `make native` or fetch the release asset), and `example/monitor`.

**Per module**

- **path:** `File`/`Dir` objects replace `Path`/`Link`. `write` is atomic. `exists()`, `size()`,
  `isLink()` and `target()` are methods. `copy`/`move` take and return a `File`.
  `Dir.files()`/`dirs()`/`find(glob)`. Hardlinks are removed.
- **http:** requests are lazy, so `Http.get(u).text()` takes one await. `download`, `head` and
  `patch` are removed; `.pipe(File(p), resume: true)` resumes a download. Bodies are
  `json:`/`form:`/`body:` (a `Source`). `HttpException(status:)` replaces
  `StatusException`/`ClientException`.
- **json / html:** an immutable `Json` (`get<T>(path, or:)`, `[]`, `value`, `encode()`,
  `save()`). `doc.drop(css)` returns a new `Doc`. `prev`/`next`. `TextNode` is `Text`.
  `page.html()` and `source.html()` give a `Doc`. `Html.read`/`decode` are removed.
- **archive:** `dir.pack(file)`, `source.unpack(dir)` (streams from any source, a download
  included), `file.entries()`, `file.entry(name)`. `Archive.pack/unpack/list/extract/open` are
  removed; in-memory `Archive.zip/unzip/gzip/gunzip` stay.
- **hash:** `Hash.sha256(data, key:)` and `source.hash(algo)`. Digests have
  `.hex`/`.base64`/`.toInt()`. `Mac`, `writer()`, `file()`, `Hash.values`, `Hex.encode` and
  `Base64.encode` are removed.
- **image:** `source.image()`, with `fit`/`crop`/`resize`/`blur`/`grayscale`/`draw` chaining on
  `Future<Image>`. `Image.empty`/`fromRgba`/`formatOf`, `w`/`h`, `save(File)`. `fill` returns a
  copy. `Image.load`/`open`/`blank`, `width`/`height` and the pipe sink are removed.
- **process:** `Process(cmd, args, dir:, env:, input:)` starts on its first call.
  `text()`/`lines()` throw `ProcessException` on a non-zero exit, `check()` answers yes or no,
  and `close()` kills the tree. `run`, `exec`, `code`, `ProcessResult` and `cancel` are removed.
- **async:** `Task.run` always uses an isolate. `Pool(n)` takes closures (`run`, `map`). `Chan`
  keeps `send`/`recv`/`close` plus `Chan.post`. `Worker`, `Task.all/bg` and `CancelToken` are
  removed.
- **cli:** `Cli.bar(max)` with `set`/`tick`/`close`. `Cli.out` and the public `testLines` are
  removed (`CliFake.lines` in `testing.dart`).
- **chrome:** `Chrome()` launches on the first `open`, and `Chrome(port:)` attaches. `navigate`,
  `screenshot`, `pdf`. `Browser`, `launch`, `connect`, `goto`, `shot`, `fill` and `send` are
  removed.
- **tui:** `term.draw/poll/post/listen/defer/close`. `selected:`, `onPress:`, `style:`,
  `scrollUp`/`scrollDown`, `picture(List<Image>)`. New `ui.spinner(label)` and `SpinGlyphs`
  (shared with `cli`). `menu`, `gap`, `board`, `log` and the `Tui.*` statics are removed.
- **native and testing:** `Native.ok`/`reason` replace `Lib2Native`/`Lib2Chrome`/`Lib2Tui`.
  Test seams (`FakeTerminal`, `CliFake`, `BufferReader`/`BufferWriter`, `NativeReset`) move to
  `testing.dart`. There is one shared error table: `MissingException`, `SecurityException`,
  `NativeException`, `HttpException`, `ProcessException`.

**Fixed**

- Unpacking an archive with subfolders into a destination reached through a symlink (the macOS
  temp folder) was refused as an escape.
- Killing a process tree on macOS missed the children: the child lookup raced the Dart VM's own
  child reaping.
- `File.write` and saving JSON were not atomic.
- HTTP bodies are decoded in the charset they declare (`Content-Type`, else `<meta charset>`),
  so pages in EUC-KR, Shift_JIS or windows-1252 read correctly.
- Chrome hides the marks automation leaves again (`navigator.webdriver`, the headless user
  agent), which bot checks look for.
- The xz multithreaded encoder uses 1 MiB blocks, so stopping it takes effect promptly.

**Native**

- The native layer is rewritten from scratch, one library per subsystem:
  `dart_toolkit_native` (digests, archives, images, charsets, file syscalls, process tree
  kill), `dart_toolkit_chrome` (launch and CDP), `dart_toolkit_tui` (raw mode, input, the
  alternate screen) and `dart_toolkit_torrent`. There is no Dart fallback: without a library,
  its calls are an `UnsupportedError` saying how to build it.
- The sources live in `native/`. `dart_toolkit_native` is at
  ABI 2 (the streaming unpack sink); libraries built before this release are refused at load,
  so rebuild with `make native`.
- JPEG encoding uses mozjpeg again, so building needs `nasm`.

**Fixed** (hardening phases 1 and 4: data loss, crashes, and the terminal)

- `pipe` no longer corrupts files over 64 KiB (file writers await `writeFrom`; process
  stdin copies and flushes per MiB). A failed `pipe` aborts the writer instead of closing
  it, so the old file and no temp remain; `Writer` gains `abort()`, and its `write` lets
  the caller reuse `data` once the future completes.
- `Archive.zip` cannot double-free after a failed finish, and member names over 65535
  bytes are an `ArgumentError`, not a native panic.
- Streaming unpack handles trailing padding, and a mid-stream refusal surfaces as itself
  (e.g. `SecurityException`) through `unpackFinish` instead of "the worker already failed".
- Both unpack paths refuse every link member unless `unpack(dir, trusted: true)`, which
  also lifts the size cap (its message names the parameter); a failed stream removes what
  it created.
- `Process` hangs fixed: `line()` waits for new data, `input:` streams past the pipe
  buffer (a broken pipe is a child that stopped reading), readings close stdin unless a
  writer was taken, `errors()` ends on the buffered tail, and `close()` skips the kill
  once the exit completed. `Chan(0)` is an `ArgumentError`.
- `Task.run` answers an unsendable result with `StateError` and an uncaught async error
  with the remote error and stack (isolate `onExit`/`onError`) instead of hanging; a dead
  `Pool` worker's ports are disposed so the script exits after `close()`; `Chan<int?>`
  keeps nulls, `post` after `close()` answers `false`, and cancelling `recv()` removes
  its waiter.
- `Native.ok` loads the engine itself and checks the chrome/tui library files by path,
  so a fresh script with `DART_TOOLKIT_NATIVE=/nonexistent.dylib` is not vacuously ok.
- `Chrome(port:).pages()` borrows tabs (release frees without closing), and a failed
  launch deletes its owned temp profile.
- `drop()` copies are wired, so selectors run on them; the `Element` constructor is private.
- HTML serialisation escapes text and `&` in attributes, drops void closers, and keeps the
  doctype; the parser reads `<`/`>` in text and quoted attributes literally, maps bad
  code points to U+FFFD, and ships the full HTML5 entity table (`entities.dart`).
- HTTP: the timeout covers every body chunk and stays a `TimeoutException`; only
  idempotent requests (or re-readable bodies, or explicit `retry:`) retry, backing off
  `250 ms × 2^attempt` and honouring `Retry-After`; a second `reader()` is a `StateError`;
  non-2xx responses release on status; redirect URLs resolve absolute; a 416 on a complete
  file copies nothing and a mis-offset 206 throws; `lengthHint` is null under a
  content-encoding.
- `Json` maps hash unordered like their equality; `File.write` keeps the mode bits and
  never replaces a symlink.
- Regression tests for the already-fixed charset bodies (EUC-KR, Shift_JIS, header and
  `<meta>`) and hidden automation marks (`navigator.webdriver`).
- Once closed, `poll` and `draw` throw an end-of-run (`Tui.run` swallows it) instead of
  spinning on `null`s; teardown runs once in `Tui.run`'s `finally`, and two ^Cs end the
  run promptly with the terminal restored.
- A failing `defer` no longer goes to the zone before the terminal is restored:
  cleanup errors are collected, the backend closes, then the first is rethrown. A
  `listen` stream error arrives from the next `poll` by default.
- `pointer: false` no longer captures the mouse (the start binding took three
  arguments, Rust one); wheel up and down were swapped.
- ^Z is `Suspend`/`Resume` again on POSIX (restore, stop, re-enter, full redraw);
  Windows keeps it a key. Clicks hit-test in reverse paint order, and a popup
  swallows clicks on its empty rows.

**Hardening, phase 2: throughput** (medians, back to back, old → new)

- HTTP body reads keep the current chunk and an offset: 100 MB from localhost pipes in
  ~6.4 s → ~70 ms (plain dart:io ~34 ms).
- One `HttpClient` per isolate with a 15 s idle timeout: 200 GETs go from 200 sockets to
  1 (75 ms → 47 ms).
- The process stdout buffer is a chunk queue with a head offset: `text()` of 100 MB in
  ~820 ms → ~115 ms (`io.Process.run` ~100 ms).
- The pool queue is a `ListQueue`: 80k jobs in 6.8 s → 0.5 s.
- `lines()` streams UTF-8 through the decoder with cancellation wired (a break stops the
  source); legacy charsets still decode whole first.
- The script/style close-tag search compares in place: 29k scripts in 16.5 s → 68 ms.
- Sibling position is wired, not searched: `div:first-child` over 34k siblings in
  34 s → 65 ms.
- `Json.parse` wraps the decode lazily instead of copying it: 28 MB in ~600 ms → ~290 ms
  (`jsonDecode` ~285 ms).
- The archive stepper keeps zip/7z open and decompresses lazily: `unzip` of 2000 entries
  in 11.4 s → 16 ms; file extraction streams through the size cap, so a 600 MB member
  holds RSS flat (was +560 MB).
- `blur`/`resize`/`fit`/`crop` run on the native RGBA handle (Lanczos3): `blur(10)` on
  2000×1500 in 4.5 s → 70 ms.
- `Bar.set` redraws only on a changed line, at most every 80 ms: 200k sets write
  ~19 MB → 230 bytes.
- Decoupling startup through core interfaces: `process` over `core` drops from +85 ms
  to +72 ms, `tui` from +192 ms to +99 ms (module medians, same sitting).

**Changed** (hardening phases 3, 5 and 6, plus the TUI look and examples)

- Long native calls are jobs on native threads (`Done` listener, stop byte, throttled
  progress): every waiting `tk_cdp_*` call (`dart_toolkit_chrome` ABI 2) and the TUI
  reader (`tk_tui_listen`, `dart_toolkit_tui` ABI 2 — rebuild with `make native`). A
  timeout completes with `TimeoutException`; closing the owning resource with
  `StateError('closed')`.
- Handles are answered at queue time behind shared state: closing a page fails its
  in-flight calls with `StateError('closed')`; closing the browser stops a launch
  still in flight. `Term.poll` answers from a Dart queue — a `post` wakes a waiter at
  once. A 5 ms timer keeps ticking through a `page.navigate`, a 200 MB `Dir.pack` and
  a 500 MB file hash; `onProgress` (on `dir.pack`, `source.unpack`, `file.hash`,
  `file.copy`, `file.move`) fires at least twice per pack and ends at total.
- `Resp` is `Response`; `headers` is an unmodifiable multi-value map with
  `header(name)` for the first value. `find`/`all` search descendants only, `matches`
  tests the element itself, unknown pseudo-classes are a `FormatException`.
  `Json.get<T>` converts int↔double and throws a naming `FormatException` otherwise;
  `or:` covers only missing values. `Image.fit` never enlarges; `decode` is
  synchronous; `Digest.toInt()` needs ≤ 8 bytes. `dir.pack` refuses `.rar`/`.7z` and
  bare `.gz`, levels are 0–9, and native archive failures map (`FormatException`,
  `PathNotFoundException`). `File.text()` on malformed UTF-8 is a `FormatException`.
  `Process.kill`/`pid`/`exitCode` are gone (`close()`/`wait()`); `Process(dir:)`
  takes any `Located`, `Canvas.picture` any `Frame`. `Chan(0)` is an `ArgumentError`.
  Headless Chrome launches with a `Chrome/` user agent (no `HeadlessChrome`); eval
  errors show `exception.description`.
- The console look: accent live bars with speed/ETA, `✓`/`✗` end lines, prompts
  through the live region, arrow-key `choose`, `NO_COLOR`/pipe fallbacks, bars closed
  in `finally`. The TUI default matches: continuous box borders, accent markers and
  spinner, `label bar pct details` bars.
- annasarchive reopens visible with a kept profile when the browser check needs a
  human; keybox prints one line on an unreachable site.

## 0.0.3

A second review pass, on memory above all. Every bug below keeps a regression test.

**Tui**

- An app is `draw` and `update` only: `init` and `view` are gone. Everything that happens is an
  event named by one noun: `Start`, `KeyPress` (now also every typed character: `Char` is gone,
  `.text` gives the text), `Paste`, `Pointer` (was `Mouse`, opt in with `pointer:`), `Resize`,
  `Focus`, `Blur`, `Suspend`, `Resume`, `Interrupt` and your own `Post` (was `Sent`).
- Side effects are statics: `Tui.post(future, onError:)`, `Tui.listen`, `Tui.defer`, `Tui.focus`,
  `Tui.quit`. `run` returns a `Task`. ^C reaches `update` (a new state keeps the app open; a second
  ^C within 2 s always quits); ^Z suspends and redraws on `fg`.
- `cli` no longer exports the events. Removed: `KeyPress.f`, `Tally.items`, `Tally.values`,
  `TuiApp.state`/`send`/`listen`/`focus`.

**Changed**

- Imports: XPath is `xpath.dart`; the pickers are `pick.dart` as `list.pick(question)` and
  `list.pickMany(question)`; `Semaphore` is in `core`. `json`, `html`, `xml`, `xpath`, `path`,
  `archive`, `hash` and `image` no longer re-export `Io`, `Store`, `Key`, `Serializer`, `Border`,
  `Align`, `Detachable` or `Terminal` (import `core.dart` beside them), and no longer re-export
  `collection`: `Element.table`/`Doc.table` are `rows`, made a table by `Table.rows(x.rows)`. `Html`
  and `Xml` share the `Markup` interface.
- `package:path` is gone: the path grammar is in-house, checked against it in both styles. Nothing
  third-party runs.
- Added `Shell.open(target)` and per-follow `onError:` on `follow`/`send`; removed `ctx.resolve`
  (`follow` resolves relative links), `readLines`, `writeLines`, `appendBytes`, `replaceText`,
  `Path.sanitized` and `Hash.isChecksum`.
- A `Pool` keeps its last 100 finished jobs (a failed one until removed or resumed). Waiting jobs
  cost a queue entry, not a running task. `parallelize(isolate: true)` shares `Pool`'s worker.
- A merging copy, move or unarchive with `fail` refuses before writing anything; `overwrite`
  replaces a file where a folder goes. `readText` of bad bytes is a `FormatException`.
- `Element.attributes` is a live view; `Doc.toString` shows a non-finite number as its text.
- `compress` scores at 2048 px, one file at a time per process, and lands on slightly different
  qualities. `lines` splits as `output` does.
- Native ABI: `dart_toolkit_native` 14 (`dart_toolkit_torrent` stays 3).

**Fixed**

- Crashes: a pool whose idle worker isolate had died; a key code past Unicode in `Console.pick`.
- Hangs or a program that would not exit: a failed `save()` left its command running; cancelling a
  batch over an endless iterable; an isolate batch whose result cannot cross or whose worker exits;
  a cancelled batch held the process 1 s; `TorrentClient.close()` during a magnet's metadata fetch;
  a torrent `read` when its job ended; `contents()` cancelled at once decoded the whole archive.
- A batch of instant items could not be cancelled or drawn; `Job.timeout` did not stop the job; a
  merged batch hid its source's error; a Pool isolate item cancelled as it was sent still ran; a job
  added after the store opened was not recorded until it finished.
- Wrong output: a batch's equal inputs merged in its display; a stream batch with no terminal logged
  every item; kitty keypad keys typed glyphs; `Style.truncate` with a custom ellipsis; cookie expiry
  ignoring a fake clock; an XML element named `base` moving link resolution; `changes()` under
  constant writes never ending a batch; `duplicates()` failing on an unreadable file.
- The 0.0.2 entity table made a rarer HTML entity ~1000× slower than a common one.

**Memory** (peak, before → after)

- Batches keep one status per finished item and no child task's value: 1M items 860 → 128 MB;
  1000 items holding 1 MiB each 1034 → 47 MB. A removed cancel listener no longer keeps later ones.
- `Pool.map` and `Pool.changes` no longer queue progress: 100k items with progress 1968 → 58 MB;
  `merge` of 2M events 292 → 17 MB.
- A crawl page keeps only its URL once read: 100k pages 311 → 86 MiB. The cookie jar is indexed and
  capped (180 a domain, 3000 in all); a memory store's cache goes with the store.
- Image: 16 × 12 MP compressed 4.2 → 1.2 GB; encoders, EXIF turns and lossy WebP copy nothing;
  Chrome's socket is uncompressed and `pdf()` streams.
- Files: listings, `size()`, `duplicates()`, copies and moves go folder by folder (300k files
  105 → 18 MiB); reading, writing, hashing and archive entries hold 1 GiB once, not twice.
- HTML/XML trees are 37% smaller (50 MB page 766 → 479 MB); sibling queries need no index; kept CSV
  rows hold only their cells; `Table.save`, `Doc.save` and Store writes stream; YAML holds each line
  once.
- Terminal: a display over 1M items adds 24 MB (was 463); `Bar.tick` keeps nothing; `Scroll` paints
  only what shows; a full-screen app keeps prints as text.

**Faster**

- Startup over `core` (cold `dart run`, `main` calling `exit`): html 173 → 58 ms, xml 174 → 37,
  json 136 → 39, cli 124 → 86, archive 137 → 98, path 110 → 70, async 52 → 21, native 31 → 2;
  `module_bench --exit` measures this way.
- One entry of a 5000-entry AES zip 2.2 s → 24 ms; `lines` 8×; Tui frames 3×; the cookie jar at 8k
  cookies 14.9 → 1.2 s; per-item timeouts reuse one timer; `FakeClock.advance` is linear.

## 0.0.2

A review pass: every bug below keeps a regression test. The three examples are rewritten to read
plainly.

**Changed**

- `FakeTerminal` moved to `package:dart_toolkit/testing.dart`, out of the `cli`/`tui` compile.
- `Chrome.launch(headless:, store:, executable:, args:, stealth:)` takes its settings directly;
  `Browser` is only for `connect(start:)`. `page.eval<T>(…)` replaces `.to<T>()` on its result.
- Crawl hooks are named parameters only: `Hooks` and `Crawler(hooks:)` are gone, `follow`/`send`
  take `onResponse:`, `url.crawl` gains `onInit:`. Shared hooks are a `Crawler` subclass.
- `Selection.text`, `attr(name, or:)` and `link` read the first match; `DocSelection` is an
  `Iterable<Doc>` (`.list` removed); JSONPath's leading `$` is optional.
- `'text'.link(url)` replaces `Style.link(url)(text)`. `Torrent.read(p).download(into:)` chains.
- Removed: `Env.isCI`, `Cancel.reason`, `Bar.add`, `Element.pairs`/`prepend`/`classes`/
  `innerMarkup`, `Selection.elements`, `Html.decodeEntities`; `Retry.attempt` is internal.
- `Batch.timeout` cancels the batch and names it; a scope timeout is a `TimeoutException` for
  batches too. A negative `Retry` is an `ArgumentError` at the call.
- `to<T>` with a type it cannot read is an `ArgumentError`; text dates without a zone read as UTC;
  `Env.get` treats a blank variable as absent.
- `Shell.run` refuses `#` comments, `$1`/`$$`, brace expansion and `FOO=1 cmd` (use `Shell.sh`).
- TSV has no quoting (a tab or line break in a cell is a `FormatException`); the INI writer
  refuses what would not read back as itself.
- Globs and `only:` take `\` as an escape; `only:` refuses `..`. `duplicates` compares by BLAKE3.
- A merging copy or move settles a folder a file is in the way of by `conflict:`.
- Native ABIs: `dart_toolkit_native` 13, `dart_toolkit_torrent` 3.

**Fixed**

- Crashes: `Run.errors` listened to before any stderr; `Batch.merge` when a later part fails
  first; BLAKE3 (SIGBUS) on a file truncated while it is hashed.
- Lost files: two moves, copies or saves at once landing on one name (a claimed name is taken
  under every policy); a cancelled `Renames.apply` leaving files under hidden names.
- Hangs: a script that made a request waiting up to 30 s to exit; a `Pool` after a worker failed
  to start or its isolate died; `tail()`/`changes()` cancelled at once; a segmented download from a
  server that ignores ranges; a cut paste end marker swallowing every later key; page waits and
  `Chrome.launch` ignoring a cancel; a `Store` update that writes inside its lock.
- Processes: grandchildren surviving a stop when their parent died first; a `stream:` input kept
  after the command ended; a resumed failed job duplicated by `add`; a leftover pool record adopted
  twice; a cancelled native install leaving cargo's children.
- Work: cleanups cancelled with the scope around the task; an isolate batch cancelled early still
  running; nested batch progress every 32 items; nullable and `Map<String, List<String>>` keys.
- HTTP: a retried revalidation's 304 thrown; `Vary` against the scope's headers; a cached answer's
  redirect target; `events()` replayed from the cache; a redirect loop retried.
- Files: `unarchive` into a mount point; a merge changing an existing folder's mode; 7z dropping
  symlinks; escaped gitignore characters; `clear()` creating a folder.
- Formats: YAML comments after an apostrophe in a plain scalar; srcset URLs with commas; streamed
  NDJSON line numbers; TOML dotted-key, XPath and CSS nesting depth; HTML button scope, `<p>`
  closers and SVG `style`/`title`; all 2125 HTML5 entities; a stray `]` in JSONPath.
- Terminal: widths from Unicode 16 (emoji, NFD marks, jamo); a slow UTF-8 read turning into Esc;
  completion quoting, option values taken for commands, fish short letters; `-n` named `--n`; a
  subcommand's usage hint; `wrap` dropping indentation; `plain` keeping charset escapes.
- Torrent: file indices with BEP 47 padding files; create/verify opening every file at once; a
  wrong piece count, a padded base32 hash and a bad creation date; a cancelled job never
  restarting; a `read` that could not be stopped.
- Image: `optimize` dropping a turned PNG's EXIF; `ImageInfo` reading EXIF from JPEG only.

**Faster**

- `Quality.under` without `visual:` searches by size alone (1.46 s → 0.14 s on 2000×1500).
- Folder-store pools are linear (2000 jobs: 1.1 s → 23 ms); isolate progress is throttled.
- `compareNatural` allocates nothing (5×); stream `parallelize` keeps nothing per item.
- Relative selectors walk siblings only; bulk `detach` is linear (8k nested: 513 → 7 ms); YAML
  writing 3.8× and TOML 2.2× faster.
- Connections are kept 100 ms between requests; the memory cache stops holding bodies past
  64 MiB; `Archive.contents` hands bytes over without a copy; folder copies do fewer syscalls.
- `isPidAlive` is a syscall, not a process (5 ms → 6 µs).

## 0.0.1

The first release: a toolkit for Dart scripts, built on one model.

- **Four shapes.** Every operation gives a value, a `Task<T>` (one result, a `Future` that reports
  its `Status`), a `Batch<I, T>` (many, made by `parallelize`, values in input order, one
  `BatchException` for every failure) or a `Stream`. `await` is success or throw; `.settled` never
  throws; a cancel is `Stopped`. Cleanup is `work.defer`; what remembers takes `store:`
  (`Store`, `Key<T>`); credentials are `Secret`s. Async only, one behaviour per method.
- **Modules.** `core`, `path` (atomic writes, `to:`/`into:`, `Conflict`, rename plans, listings,
  watching), `archive`, `hash`, `async` (`Worker`, `Pool`, `Job`, detached jobs, stream operators),
  `process` (`Shell`, `Command`, `Runner.fake`), `json` (`Doc`: JSON, YAML, TOML, INI), `html`/`xml`
  (`Html`, `Xml`, CSS and XPath), `collection` (`Table`), `http` (strict `url.get()`,
  `Http.scope`, `download`, `Client.fake`), `scrape` (`url.crawl`, `Crawler`), `chrome`, `image`
  (`compress` by perceived quality), `torrent`, `cli` (`Cli`, typed options, `Console`, `show`),
  `tui` (apps, widgets, mouse and hover, overlays, `Markdown`, `Picture`) and `native`.
- **Checked text, opt-in:** `'755'.mode`, `'**/*.mp3'.glob`, `'h2 a'.css`, `'//a'.xpath`,
  `r'$.a'.jsonPath`, `'9f86…'.hex`, `'image/'.mime`; parameters still take plain `String`s.
- **Test seams:** `Clock.fake()`, `Client.fake`, `Runner.fake`, `FakeTerminal`, `Store.memory()`,
  `Io.scope`, `Env.scope`, `cli.test`.
- **Native libraries** (`dart_toolkit_native` ABI 12, `dart_toolkit_torrent` ABI 2): a first use
  downloads this platform's build from the release of these sources (checked against its
  `.sha256`), else compiles it with `cargo`.

The rules are in `CONVENTIONS.md`; what is left for Windows is in `PLAN.md`.
