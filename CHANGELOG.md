# Changelog

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
