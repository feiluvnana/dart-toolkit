# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

Audit IV read the source and then ran it: every bug below was reproduced by a probe before it
was fixed, and every measurement is a back-to-back delta. **Everything is breaking; there are no
deprecation shims.**

### Removed

- **`RetryBuilder` and `Function.retry()`.** `retry(action, attempts: 3, delay: 200.ms,
  onRetry: …)` is the one spelling; it reads like `parallelize(f, concurrency: 8)` and the
  builder was 130 lines for a third way to say it.
- **`String.run()`.** `run('cmd')` is the verb; `Path.run(args:)` stays because it execs an
  argv without splitting. **`.pipe()`** — `|` is the operator, and the doc called `pipe` an alias.
- **`CliCommand.subcommand`** — it is `command` at every level.
- **`Response.isolateHtml/isolateJson/isolateXml`** — `res.isolate((r) => f(r.html()))`.
- **`Os`** — `Platform.isMacOS` and friends from `dart:io` are the same thing.
- **`Iterable.mapIndexed`** — the SDK's `indexed`. **`ScrapeContext.emitAll`** — `items.forEach(ctx.emit)`.
- **`Env.get(key, defaultTo)`** — `Env.get(key) ?? fallback`; the parameter never tightened the type.
- **`ConsoleMultiProgress.updateTask/tick/setCompleted`** — `report(BatchProgress)` is the API.
- **`BaseRequest.scrape`** — `[request].scrape(f)`.

### Changed — module layout

- **`res.html()`, `url.html()` moved to `html/html.dart`; `res.xml()`, `url.xml()` to
  `xml/xml.dart`.** `http` compiled both parsers for every program. Measured under `dart run`:
  `http` was +1050 ms over a bare script, of which the parsers were ≈900. A downloader or JSON
  client now pays ≈+155; an HTML scraper saves the XML share, ≈0.4 s per run. Budgets:
  `http: {http, path}`, `html: {html, http}`, `xml: {xml, http}`. `tool/startup.dart` prints
  the table.

### Changed — call sites

- **`ctx.option()` and `ctx.number()` are non-null** and throw `StateError` when the option was
  neither given nor defaulted; `optionOrNull`/`numberOrNull` are for optionals without a default.
  Every program used to bang every read.
- **`Cli.run` owns the lifecycle**: a usage error prints and exits 64, and when the action
  returns the exit hooks run and the signal handlers are released. The five-line `try/catch`
  every program carried is gone. `CliCommand.run` still throws, for tests.
- **`Uri./` appends a path segment** (`'https://x.com/api'.url / 'users'` →
  `https://x.com/api/users`); it used to resolve as an href and drop the last segment.
- **`ShellResult.json` is a `JsonDocument`**, like every other `json` in the package.
- **`Http.session(timeout:, headers:)`** — one place for the request timeout (headers and each
  body chunk) and default headers; nothing in `http` could time out before.
- **`download`/`downloadAll` take `headers:`**; **`run` takes `input:`** for stdin;
  **`CommandPipeline` has pipefail semantics** — the exit code is the rightmost non-zero one and
  `throwOnError` covers every stage.
- **The CLI parser** accepts options before the subcommand (`app -v fetch`), combined short
  flags (`-vd`) and attached values (`-j4`). `--help` is recognised only where an option is
  expected, not as a value or after `--`. A `CliChoice` default outside its choices fails at
  declaration.
- **`scrape` retries 429 and 5xx**, honouring `Retry-After`; `concurrency` and `retries`
  defaults are declared on the entry points. **`ScrapeContext.meta`** is `Map<String, Object?>`.
- **`Logger.silenced` accepts an async body** and returns a `Future`. **`Logger.warn` writes to
  stderr** with `error`.
- **`Path.readText`/`readLines`** take `encoding:` by name, like `writeText`. **`Path.move`**
  copies and deletes when `rename` cannot cross filesystems.

### Fixed

- A script that called `onExit` never exited: the signal watch kept the isolate alive. `Cli.run`
  releases it; the doc says what a bare script must do.
- Leaving a `downloadAll` loop early kept downloading: the controller had no `onCancel`.
- `extractToSync` wrote an entry named `../x` outside the destination.
- `Stream.parallelize` resumed the source while the consumer was paused, buffering every result.
- Three `CancelToken.onCancel` registrations were never unregistered (`Stream.parallelize`,
  `downloadAll`, `scrape`).
- `Either.tryCatch` dropped the stack trace; `unwrap` now rethrows with the one it caught.
- `JsonDocument.to<num>()` returned `null` for numeric strings; `to<String>()` on a map or list
  returns JSON. `doc[-1]` counts from the end, as `$[-1]` does.
- JSONPath `$..[0]` dropped the descent step.
- `Element.lines` left entities encoded, and re-serialised the subtree to do it: 4.95 ms →
  0.32 ms on 2000 rows.
- `Env.parse(override: false)` overwrote values loaded earlier, contrary to its doc.
- `run` split on U+0020 only; tabs and newlines in a command string are now separators.
- `✓`, `✖` and `⚠` were counted two columns wide, misaligning table borders.
- A progress bar's last frame was never drawn when the final tick fell inside the 33 ms gate,
  and a deferred frame showed the first throttled label rather than the latest.
- `ConsoleProgress` without a terminal wrote one line per tick (1001 lines for 1000 ticks); it
  now writes one per new tenth.
- Scrape deduplication keyed on a hash of the body; it keys on the value. `throttle` with
  neither `leading` nor `trailing` emitted nothing silently; it throws.

## 0.0.2

Three audits land in this release, newest first. *Audit III* ran the package and measured it;
*Audit II* read the API from the call site — the three examples and `bin/keybox.dart`; *Audit I*
read the surface from the source. **Everything is breaking; there are no deprecation shims.**

### Audit III — performance

#### Removed

- **`rxdart` and `xpath_selector_html_parser` are no longer dependencies.** The six `Stream`
  operators (`chunk`, `chunkTime`, `debounce`, `throttle`, `delayBy`, `flatMap`) keep their names
  and semantics and are now implemented on `dart:async`; `flatMap` still merges its inner streams
  concurrently. `async` now has no third-party dependencies at all.
- **`HtmlDocument.$xpath` and `Element.$xpath`.** Use the CSS `$`. On a 2000-row table
  `$('tr td a')` took 0.43 ms where `$xpath('//tr/td/a')` took 62 ms — 145× — and the gap widened
  quadratically with document size. `XmlDocument`'s XPath is unaffected; it comes from
  `package:xml`.
- **`ListExtensions.getOrNull`** — the SDK's `elementAtOrNull` is the same operation. One
  difference, deliberately not re-implemented: it throws on a negative index where `getOrNull`
  returned `null`.
- **`ShellResult.isFailed`** — `!result.ok`.
- **`IterableExtensions.sortedByDescending`** — `sortedBy(key, desc: true)`.

#### Changed — module layout

- **Programs import modules, not the barrel.** Under `dart run` the front end compiles the whole
  transitive closure every invocation: measured at 1722 ms for `dart_toolkit.dart` against 281 ms
  for a bare script. `example/cli_app.dart` went from **1820 ms to 627 ms** by naming its two
  modules. `tool/check_deps.dart` now fails any `bin/` or `example/` file that imports the barrel.
  AOT is unaffected — tree shaking already made the barrel free for `dart compile`d tools.
- **`HtmlDocument` and `XmlDocument` moved out of `core`** into new `html/html.dart` and
  `xml/xml.dart` libraries. `core` now has no third-party dependencies, so a script that parses
  JSON no longer loads an HTML and an XML parser to do it: 1394 ms → 342 ms.

#### Changed — memory

- **`Path.sha256()` / `Path.md5()` stream the file.** `(await p.readBytes()).sha256` peaked at
  888 MB of resident memory on a 512 MB file; the new form peaks at 266 MB for the same digest in
  the same time. `BytesHashExtensions` remains for callers that already hold bytes.
- **`extractTo`, `extractToSync` and `zipToSync` stream.** Extracting a 320 MB archive peaked at
  685 MB and now peaks at 302 MB; `zipToSync` was 1.5× slower than `zipTo` for reading each entry
  whole.
- **Downloads bound their write queue.** `IOSink.add` only queues, so `received` ran up to
  87.8 MB ahead of what was on disk for a 128 MB transfer. The writer now waits for the disk every
  4 MB, which caps the gap at 4 MB.
- **The scrape engine respects a paused consumer.** A 301-page crawl whose subscription was paused
  before the first event used to fetch all 301 pages and buffer every item; it now stops after the
  in-flight requests. `_batchDownload` likewise stops reading its source ahead by more than four
  times `concurrency`.
- **`CancelToken.onCancel` returns a function that unregisters the listener**, and both
  `cancelWith` implementations call it when their work completes. 200 000 completed
  `Future.cancelWith` calls on one token used to retain 52 MB.

#### Changed — algorithms

- **`sortedBy` evaluates its key once per element**, not once per comparison: sorting 10 000 items
  called the key 206 806 times and now calls it 10 000. `maxBy` and `minBy` (renamed from
  `maxByOrNull` / `minByOrNull`) hold the incumbent key instead of recomputing it.
- **`glob` matches each entry once, against its relative path only**, and caches the compiled
  pattern. 9.2 ms → 5.7 ms over 2000 files. **This changes results**: a pattern that only matched
  through the absolute path — `glob('assets/*.mp3')` from inside `.../assets` — no longer matches.
- `Element.lines`, `ShellResult.lines` and `_splitCommand` no longer build regexes or
  one-character strings per call; `JsonDocument.to<T>()` uses `const` type probes; `which` stats
  the `PATH` in parallel.
- **`Response.text`** exposes the body decoded once per response — `package:http` re-decodes
  `bodyBytes` on every `body` access — and `html()`, `xml()` and `json()` share it.
- **`ConsoleProgress` and `ConsoleMultiProgress` share one 33 ms frame gate.** The single-line one
  used to write on every `tick`, so a caller driving it from a per-chunk stream issued a terminal
  write per chunk.

#### Changed — names

`terminalColumns:` → `columns:` · `allowDuplicates:` → `revisit:` · `maxRetries:` → `retries:` ·
`maxAttempts:` / `.maxAttempts(n)` → `attempts:` / `.attempts(n)` ·
`ConsoleIo.stdoutOverride` / `stderrOverride` / `stdinLineReader` → assignable `ConsoleIo.out` /
`err` / `input` (plus `ConsoleIo.redirected`) · `Env.clearOverrides()` → `Env.clear()` ·
`Env.loadFile(p, true)` → `Env.load(path: p, override: true)`, with the positional boolean gone · `Semaphore.availablePermits` / `queueLength` → `permits` /
`waiting` · `BatchDownloadProgress.newDownloads` → `written` · `CancellationToken` /
`CancellationException` → `CancelToken` / `CancelledException` · `Stream.whereNotNull()` →
`Stream.nonNulls` · `JsonDocument.$jsonpath` and `XmlDocument.$xpath` → `$` ·
`ElementQueryExtensions` → `ElementExtensions` · `UriPathMapDownloadExtensions` →
`MapDownloadExtensions` · `FutureShellResultExtensions` → `FutureShellExtensions` ·
`NullableStreamExtensions` → `StreamNullableExtensions`.

#### Measured and deliberately not changed

The terminal renderer (6.4 µs per frame), `run()` (at parity with a hand-rolled `Process.start`),
download throughput (93 ms for 64 MB, against 89 ms for raw `dart:io`), and `parallelize(isolate:)`
(30 ms against 103 ms single-threaded, near a hand-built pool's 25 ms). `parallelize` gained one
doc line instead: the worker and everything it captures is copied **per item**, not per isolate.

### Audit II — the API as used

#### Fixed

- **`Path.sanitized()` could not sanitize a filename.** Its character class excluded separators,
  so `'AIR / Farewell song'.path.sanitized()` kept the slash and a scraped title silently created
  a directory. `String.filename` is the component-level operation; `sanitized()` still cleans a
  whole path.
- **`die()` dropped async exit hooks.** It ran hooks without awaiting them, so an `async` hook
  that ran on SIGINT was skipped on `die`. It is now `Future<Never>`: `await die('...')` still
  has static type `Never`.
- **`Map<Uri, Path>` was the only batch download entry point**, so two destinations for one URL
  collapsed to one with no error.
- **`Uri.html()`/`json()`/`xml()` parsed error pages.** A 404 body parsed fine and matched
  nothing; they now throw `HttpException` unless the status is 2xx. `get()` is unchanged — check
  `Response.ok` yourself.

#### Added

- **`required: true` on `option`, `number` and `choice`.** Absence is an `ArgumentError` at parse
  time, and the help text says `[required]`. A required option cannot also declare a default.
- **`String.filename`** — one string, one path component, separators escaped.
- **`Response.ok`** — 2xx, mirroring `ShellResult.ok`.
- **`TaskProgress` and `BatchProgress` in `util`**, plus `ConsoleMultiProgress.report`, so a
  producer and a renderer in different modules meet without an import edge. An 18-line adapter at
  each call site becomes `progress.report(p)`.
- **`downloadAll` on `Iterable<({Uri url, Path path})>` and `Stream<…>`**, so discovery overlaps
  with transfer, and `Map<Uri, Path>.pairs` to bridge the two shapes.
- **`ScrapeContext.url` and `.resolve`** — the base the engine itself resolves against, instead of
  reconstructing it from a nullable `response.url`.
- **`Http.session`** — one client for every HTTP call inside the callback, closed on return. The
  13 `client:` parameters remain as the per-call override.
- **`Logger.stages`** — a counter that owns the total: `stage('…')` prints `[n/total] …`.

#### Changed

- **`DownloadProgress` is sealed**: `Downloading | Downloaded | DownloadSkipped | DownloadFailed`.
  `isDone`/`isSkipped`/`isFailed`/`error` are gone; `error` now exists only on the failure case.
- **`BatchDownloadProgress.total` is `int?`** — `null` while a stream source is still producing —
  and `ratio` is nullable with it. `percent` is gone.
- **`CliContext.option`/`number` lost their `defaultTo` parameter.** The declaration already
  carries it.
- **`Logger.step` is gone**, replaced by `Logger.stages`.
- **`Console.multiProgress` takes `total:` as a named parameter**, defaulting to 0 for work that
  is still being discovered, and revises it upward from `report`.
- **`Console.table` rows are `List<List<Object?>>`**, so call sites stop interpolating.

#### Migration

| was | now |
|---|---|
| `title.path.sanitized()` | `title.filename` |
| `die('x')` | `await die('x')` |
| `p.isSkipped ? … : p.isFailed ? … : …` | `switch (p) { … }` over the sealed cases |
| `p.percent` | `p.ratio` |
| `ctx.option('f', defaultTo: 'all') ?? 'all'` | `ctx.option('f')!`, default declared once |
| `Logger.step(1, 3, 'x')` | `final stage = Logger.stages(3); stage('x');` |
| `Console.multiProgress(n, slots: 4)` | `Console.multiProgress(total: n, slots: 4)` |
| 18-line `updateTask(…)` block | `progress.report(p)` |
| `(await uri.get()).isolateHtml((d) => d)` | `await uri.html()` |

---

### Audit I — the API surface

An API audit found 435 public members across 34 public libraries — roughly
one public member per twelve lines of implementation — plus two correctness defects in the typed
error API. This release acts on it. **Everything below is breaking; there are no deprecation
shims.** Every removal has a one-line replacement, listed under Migration.

#### Fixed

- **`Either.tryCatch`/`tryCatchAsync` threw instead of returning a `Left`.** With a type
  parameter `E` and no `onError`, the fallback was `error as E`, so capturing an error that was
  not an `E` threw a `TypeError` — the one thing the API exists to prevent. The type parameter is
  gone; narrow with `mapLeft` afterwards.
- **`parallelSettle` threw before any worker ran.** With any `E` other than `Object` and no
  `onError`, the placeholder `Left` carried the same cast, so even a workload with zero failures
  threw.
- **Subprocess output bypassed the `ConsoleIo` seam**, writing straight to `dart:io` stdout, so
  redirecting the sink captured `Logger` output but let child output through to the terminal.
- **Progress widgets gated on the real terminal** while writing to the seam, so redirecting the
  sink did not redirect what was rendered.
- **`Ansi` read `NO_COLOR` from `Platform.environment`**, making the package's own `Env` override
  invisible to its own colour gate.
- **`ConsoleMultiProgress` emitted only a final line without a terminal** while `ConsoleProgress`
  emitted one per tick. It now reports each task completion.
- **Nested ANSI styles did not compose**: `('a'.red + 'b').bold` left `b` unbolded because the
  inner reset cancelled the outer style.
- **`ScrapeContext.follow` silently dropped POST bodies** of any type other than `String` or
  `Map<String, String>`, and `followAll` could not carry a body at all.
- **`follow` silently ignored a target** that was neither `Uri` nor `String`; it now throws.
- **`JsonDocument[key]` returned the null document** for a key that was neither `String` nor
  `int`, indistinguishable from a real JSON null; it now throws.

#### Changed

- **`parallelMap` and `parallelSettle` are gone.** `parallelize` is the single primitive; it
  settles every task. `unwrap`, `rights` and `lefts` pick the error policy at the use site.
  **Note:** `parallelize(...).unwrap()` is *not* fail-fast — every task runs to completion before
  the first failure is thrown, where `parallelMap` stopped scheduling.
- **`CliOption` is a sealed type**: `CliFlag | CliValue | CliNumber | CliChoice`. Previously four
  mutually exclusive kinds were encoded as orthogonal boolean fields, so
  `option('x', flag: true, numeric: true)` compiled and silently misbehaved.
  `CliContext.values` now holds a parsed `int` for a `CliNumber`.
- **`CliCommand.subcommand` and `Cli.command` return the receiver**, like every other builder
  method. Nesting goes through the `build` callback.
- **Downloading moved from `fs` to `http`**, archiving to a new `archive` module, hashing to a
  new `hash` module, and format parsing off `Path` entirely. `fs` and `process` now depend on
  `package:path` alone — down from seven third-party packages each.
- **Implementation moved under `lib/src/`.** 34 public libraries → 11.

#### Removed

- Fifteen aliases: `Path.exist`/`existSync`, `Env.isMac`/`isWin`, `ShellResult.failed`,
  `Mutex.protect`, top-level `$()`, `Prompt.askWith`, `Either.guard`/`guardAsync`,
  `Path.normalize`, and the duplicate `parallelSettle`.
- The `http.Client` format extension and `Uri.isolate*` — seven and four members that were
  `uri.<same>(client: client)` and `(await uri.get()).<same>(f)`.
- `Response.$` and `$xpath`: HTML query methods on a transport type.
- The five `ScrapeContext` delegations to `ctx.response`.
- `Uri.download`, a forward to `Path.download` that dropped `cancelToken`.
- `Map<Path, Uri>.downloadAll`; only the source-to-destination orientation survives.
- `example/example.dart`, which claimed to demonstrate every API.

#### Added

- `Either.unwrap`, `Iterable<Either>.unwrap`/`rights`/`lefts`, `Stream<Either>.unwrap`.
- `Os` for platform detection, split out of `Env`.
- `ConsoleIo.isTerminal` and `ConsoleIo.columns`.
- `BytesHashExtensions` on `List<int>`.
- `tool/check_deps.dart`, a per-module third-party dependency budget, enforced in CI.
- [`CONVENTIONS.md`](CONVENTIONS.md).

#### Migration

| removed / renamed | replacement |
|---|---|
| `$('cmd')` | `run('cmd')` |
| `ShellResult.exitcode` / `.failed` | `.exitCode` / `.isFailed` |
| `Path.exist()` / `existSync()` | `exists()` / `existsSync()` |
| `Path.file` / `dir` / `link` | `asFile` / `asDir` / `asLink` |
| `Path.replace(a, b)` | `replaceInFile(a, b)` |
| `Path.mklink(t)` | `symlink(t)` |
| `Path.normalize(s)` | `Path(s).normalized` (now returns `Path`) |
| `Path.readJson()` | `JsonDocument.parse(await p.readText())` |
| `Path.writeJson(d)` | `await p.writeText(jsonEncode(d))` |
| `Path.writeJson(d, pretty: true)` | `await p.writeText(const JsonEncoder.withIndent('  ').convert(d))` |
| `Path.readHtml()` / `readXml()` | `HtmlDocument.parse(...)` / `XmlDocument.parse(...)` |
| `Path.sha256()` / `md5()` | `(await p.readBytes()).sha256` / `.md5` |
| `Path.zip(d)` / `unzip(d)` | `p.zipTo(d)` / `p.extractTo(d)` |
| `url.download(path)` | `path.download(url)` |
| `Map<Path, Uri>.downloadAll()` | `Map<Uri, Path>.downloadAll()` |
| `Env.isMac` / `isMacOS` / `isWin` / `isWindows` / `isLinux` | `Os.isMacOS` / `Os.isWindows` / `Os.isLinux` |
| `Env.load(content)` / `load(path)` | `Env.parse(content)` / `Env.loadFile(path)` |
| `Either.guard(f)` / `guardAsync(f)` | `Either.tryCatch(f)` / `tryCatchAsync(f)` |
| `Either.tryCatch<E, T>(f)` | `Either.tryCatch(f).mapLeft(toE)` |
| `items.parallelMap(w)` | `(await items.parallelize(w)).unwrap()` |
| `items.parallelSettle(w)` | `items.parallelize(w)` |
| `items.parallelSettle<E, R>(w, onError: g)` | `(await items.parallelize(w)).map((e) => e.mapLeft(g))` |
| `Mutex.protect(f)` | `Mutex.run(f)` |
| `stream.flatmap(f)` / `notnull()` | `flatMap(f)` / `whereNotNull()` |
| `stream.buffer(d)` / `delay(d)` | `chunkTime(d)` / `delayBy(d)` |
| `client.html(uri)` etc. | `uri.html(client: client)` etc. |
| `uri.isolateHtml(f)` | `(await uri.get()).isolateHtml(f)` |
| `res.$(sel)` / `res.$xpath(q)` | `res.html().$(sel)` / `res.html().$xpath(q)` |
| `ctx.html()` / `json()` / `$()` | `ctx.response.html()` / `.json()` / `.html().$()` |
| `ctx.follow(t, dontFilter: true)` | `ctx.follow(t, allowDuplicates: true)` |
| `ctx.follow(t, body: map)` | `ctx.follow(t, fields: map)` |
| `Prompt.ask('m', 'd')` | `Prompt.ask('m', defaultTo: 'd')` |
| `RetryBuilder.attempts(n)` / `retry(attempts: n)` | `.maxAttempts(n)` / `retry(maxAttempts: n)` |
| `RetryBuilder.cancelWith(t)` | `.cancelOn(t)` |
| `spinner.success()` / `info()` | `succeed()` / `stop()` |
| `option('x', flag: true)` / `numeric: true` / `choices: [...]` | `flag('x')` / `number('x')` / `choice('x', [...])` |
| `cli.command('a').option('b')` | `cli.command('a', build: (a) => a..option('b'))` |
| `multiProgress.update(batchProgress)` | `updateTask(...)` directly |

## 0.0.1

- Initial release of `dart_toolkit`.
- Shell and subprocess automation (`$`, `run`, `String.run()`, `Path.run()`, `which()`, command pipelines).
- Ergonomic filesystem and path operations (`Path`, `readText`, `writeText`, `readJson`, `writeJson`, `append`, `replace`, `sanitized`, `sha256`, `md5`, `zip`, `unzip`).
- Environment variable management and `.env` loader (`Env.get`, `Env.set`, `Env.require`, `Env.load`, `Env.all()`).
- Async concurrency and flow control (`parallelize`, `retry`, `Mutex`, `Semaphore`, `isolate`, stream extensions).
- Core document parsing and types (`Either`, `JsonDocument`, `HtmlDocument`, `XmlDocument`).
- HTTP response extensions and web scraping pipeline.
- Rich CLI, terminal console, spinners, progress bars, tables, prompts, and lifecycle hooks (`Console`, `Prompt`, `Cli`, `onExit`, `die`).
