# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

An API audit ([AUDIT.md](AUDIT.md)) found 435 public members across 34 public libraries — roughly
one public member per twelve lines of implementation — plus two correctness defects in the typed
error API. This release acts on it. **Everything below is breaking; there are no deprecation
shims.** Every removal has a one-line replacement, listed under Migration.

### Fixed

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

### Changed

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

### Removed

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

### Added

- `Either.unwrap`, `Iterable<Either>.unwrap`/`rights`/`lefts`, `Stream<Either>.unwrap`.
- `Os` for platform detection, split out of `Env`.
- `ConsoleIo.isTerminal` and `ConsoleIo.columns`.
- `BytesHashExtensions` on `List<int>`.
- `tool/check_deps.dart`, a per-module third-party dependency budget, enforced in CI.
- [`CONVENTIONS.md`](CONVENTIONS.md).

### Migration

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
