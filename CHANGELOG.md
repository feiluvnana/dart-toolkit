# Changelog

All notable changes to this project will be documented in this file.

## 1.3.0

- **Java-Style Domain Namespaces (`io`, `net`, `system`, `concurrent`, `util`)**:
  - Reorganized all subsystems into 5 cohesive root domain singletons mirroring professional standard library architecture (like Java's `java.io`, `java.net`, `java.lang`, `java.util.concurrent`, `java.util`).
  - Subsystems are cleanly arranged:
    - **`io.*`**: Unified file operations, paths, atomic writes (`.part`), `io.csv.*`, `io.store.*`, and `io.archive.*`.
    - **`net.*`**: Unified HTTP networking (`net.get`, `net.post`, `net.http.*`), crawler engine (`net.crawl.*`), and jQuery-like selectors (`net.$()`).
    - **`system.*`**: Unified subprocess execution (`system.run`), signals (`system.listen`, `system.unlisten`), CLI arguments (`system.cli.*`), and environment variables (`system.env.*`).
    - **`concurrent.*`**: Concurrency pool (`concurrent.pool`) and bounded task execution (`concurrent.run`).
    - **`util.*`**: Utilities including time & delays (`util.time.*`), Git automation (`util.git.*`), and terminal formatting & prompts (`util.console.*`).
- **Complete Elimination of Loose Aliases**:
  - Removed all top-level shorthand aliases (`fs`, `sys`, `parallel`, `cli`, `env`, `console`, `git`, `time`, `http`, `csv`, `store`, `crawl`). Autocomplete and imports now exclusively expose the 5 domain singletons alongside essential models.
  - Removed backward-compatible `typedef ParallelAccessor = ConcurrentAccessor`.
  - Added `system.unlisten()` / `Sys.unlisten()` to teardown background POSIX/Windows signal listeners, enabling scripts to terminate normally without dangling listeners keeping the Dart VM alive.
- **Zero `dynamic` Usage Across Codebase**:
  - Completely eliminated the `dynamic` type across `lib/`, `bin/`, `example/`, and `test/`.
  - Replaced all loosely typed parameters and variables with concrete types, generics (`<T>`), `Object`, and `Object?`.
  - Enabled `strict-casts: true` and the `avoid_annotating_with_dynamic: true` linter rule in `analysis_options.yaml`.
- **Complete Elimination of Legacy Compatibility Variables & Shims**:
  - Removed legacy forwarder file `lib/crawler.dart`.
  - Merged archive logic directly into `lib/io/` for a unified filesystem and archive architecture.
  - Renamed `ProcResult` to `SysResult` and removed backwards-compatible typedefs `typedef Proc = Sys;` and `typedef SysResult = ProcResult;`.
  - Removed backwards-compatible typedef `typedef Scheduler<T> = Deduplicator;` and removed `scheduler` parameters.
  - Standardized on `downloader:` everywhere, eliminating legacy `dl:` parameters, `Engine.dl`, `crawl.dl()`, and `CrawlBuilder.dl()`.
  - Removed redundant alias methods across namespaces:
    - `console.logger`: removed `success` (use `ok`), `warning` (use `warn`), `fail` (use `error`), and `line` (use `writeln`).
    - `console.ansi`: removed `Ansi.len` and `String.len` (use `visibleLength`).
    - `concurrent`: consolidated `each`, `map` into `concurrent.run`.
    - `crawl`: removed `Deduplicator.reset` (use `clear`), `Engine.isIdle` (use `idle`), `Engine.url` (use `add`), `QueryResult.toElements` (use `list`), `QueryResult.has` (use `hasClass`), and `CrawlBuilder.process` (use `run`).
    - `system`: removed redundant `sys.exit` alias in favor of `exit()`.

## 1.2.0

- **`proc.*` Removal & `sys.*` Unification**: Fully unified external process execution into `sys.*` (`sys.run`, `sys.which`, `sys.listen`, `sys.clock`, `sys.track`), removing redundant `proc.*` namespace alias and consolidating `Proc` class into `Sys` (with backward-compatible typedefs). Added `res.out`, `res.err`, `res.output` getters to `ProcResult`.
- **Dedicated `http.*` Namespace**: Separated HTTP networking out of crawler logic into a top-level `http.*` namespace providing strictly 1-word methods (`get`, `post`, `put`, `delete`, `patch`, `head`, `download`, `sync`, `client`, `send`).
- **`HttpResponse` Capabilities**: Integrated DOM querying (`res.$(selector)`), link extraction (`res.link()`, `res.links()`), media/script extraction (`res.src()`, `res.srcs()`), text lines extraction (`res.lines`), and atomic saving (`res.save(filePath, [sourceUrl])`) directly into `HttpResponse`.
- **Simplified `crawl.*` Subsystem**:
  - Restructured architecture into 4 clean, focused components: `Engine`, `Downloader`, `Processor`, and `Deduplicator`.
  - Shifted concurrency and rate-limiting delay ownership into `Downloader`: workers in `downloader.work(engine)` actively pull requests on demand via `engine.serve()`.
  - Renamed `crawl.dl()` to `crawl.downloader()` (with `crawl.dl()` preserved as a 1-word alias).
  - Replaced the previous complex priority scheduler with `Deduplicator` (`add`, `has`, `see`, `clear`, `reset`) with automatic fragment and trailing slash normalization.
- **5 New Namespaces (Strictly 1-Word Method Names)**:
  - **`env.*`**: `.env` loader and environment manager (`load`, `get`, `int`, `double`, `bool`, `has`, `set`, `delete`, `clear`, `map`, `parse`).
  - **`git.*`**: Git automation and repository inspection (`branch`, `hash`, `dirty`, `status`, `tag`, `add`, `commit`, `push`, `pull`, `clone`, `run`).
  - **`time.*`**: Ergonomic delays, timestamps, and benchmarking (`wait`, `stamp`, `iso`, `ago`, `now`, `clock`, `epoch`, `sleep`).
  - **`csv.*`**: RFC-4180 CSV serialization, parsing, and atomic file I/O (`parse`, `format`, `read`, `write`).
  - **`store.*`**: Lightweight persistent JSON key-value store and cache (`open`, `get`, `set`, `has`, `delete`, `clear`, `save`, `load`, `map`).
- **`Fs.write` Flexibility**: Updated `Fs.write` to accept both file path strings and `File` instances seamlessly.

## 1.1.0

- **`parallel.*`**: Strictly preserved input order in `parallel.run`, `parallel.map`, and `parallel.each` regardless of asynchronous resolution timings; added `delay` parameter to `Pool` and `parallel.run` for request rate-limiting.
- **`fs.*`**: Added 1-word helpers: `fs.json` (read or write JSON atomically with pretty option), `fs.lines` (stream lines from large files asynchronously), `fs.hash` (SHA-256 and MD5 cryptographic checksums), and `fs.stat` (file/directory metadata).
- **`cli.*`**: Added `cli.all` (collect multiple option values like `--tag a --tag b`), `cli.no` (negative flag detection for `--no-xxx`), `cli.help` (formatted CLI help generator), and automatic boolean handling for negative flags.
- **`sys.*`**: Added `timeout: Duration` support in `sys.run` / `Proc.run`, and 1-word platform predicates: `sys.win`, `sys.mac`, and `sys.nix`.
- **`console.*`**: Added `console.reader.picks` for multi-selection prompts, and `console.logger.level` (`LogLevel` filtering to silence debug/info logs).
- **`crawl.*` & `$()`**: Added automatic `Referer` header resolution in `res.follow(...)`, HTTP download retries and exponential backoff in `HttpDownloader` and `CrawlBuilder.retry(n)`, and DOM helpers in `QueryResult`: `prev()`, `next()`, `val()`, and `data()`.
- **Packaging & Repository**: Added MIT `LICENSE` file, `.pubignore`, `.github/workflows/dart.yml` continuous integration, and pubspec discoverability metadata (`topics`, `issue_tracker`).

## 1.0.0

- Initial release of `dart_toolkit` (Dart Script Toolkit by feiluvnana).
- **`console.*`**: Dedicated status loggers sub-namespace (`console.logger.*` with `step`, `ok`, `warn`, `fail`, `error`, `info`, `debug`, `task`, `write`, `writeln`), table formatting, boxed callouts, divider rules, dynamic progress bars, animated spinners, interactive prompts (`ask`, `confirm`, `pick`, `secret`), terminal geometry, ANSI color extensions on String.
- **`fs.*`**: Atomic file writes with `.part` staging and signal cleanup, zero-dependency path helpers (`join`, `base`, `name`, `ext`, `dir`), directory creation/walking, streaming downloads, human-readable size and time formatters, sanitization, 7-Zip archive integration (`fs.archive`).
- **`crawl.*` / `$()`**: Fluent builder crawler API (`crawl(urls).concurrent(n).delay(d).base(...).tag(...).run(process)` with process-only execution arguments, `crawl.collect`, `crawl.run`), unified crawler engine (`crawl.engine`), declarative route and tag handlers, pipeline response controls (`follow`, `save`, `emit`, `stop`), automatic relative URL resolution, streaming atomic downloads, batch asset synchronization (`crawl.sync`), jQuery-like CSS DOM query results.
- **`parallel.*`**: Bounded concurrency execution (`parallel.run`, `parallel.map`, `parallel.each`), dedicated `Pool` with progress and error event hooks.
- **`sys.*`**: Subprocess execution (`sys.run`), signal interception (`SIGINT`, `SIGTERM`), exit hooks, temporary file tracking, benchmark stopwatch (`sys.clock`), binary resolution (`sys.which`).
- **`cli.*`**: Command-line flag parsing with short/long aliases, typed option extraction with default values, positional argument access.
