# Changelog

All notable changes to this project will be documented in this file.

## 1.1.0

Expands `system.cli` from an argument parser into a full command-line
front end: commands with their own arguments, defaults and environment
fallbacks that are declared once, and validation that catches typos.

### Added

- **`system.cli.handle`** registers a command and returns it, so the arguments
  only that command uses are declared on the spot. **`system.cli.group`** nests
  commands, so `remote add` resolves through a tree.
- **`system.cli.run`** parses, resolves the deepest matching command, re-reads
  the arguments against that command's declarations plus the global ones,
  prints `--help` or `--version`, applies validation, awaits the handler and
  turns what it returns into an exit code: `null` and `true` mean success,
  `false` means failure, an `int` is used as given, and a command line it could
  not understand yields `Cli.usageExit` (`64`) after printing the reason. `--help`,
  `-h` and `--version` are declared for you. `body:` runs when no command
  matches, so a script with no commands at all still gets automatic help and
  validation. Only `ArgumentError` is caught, leaving a genuine failure inside
  a handler its stack trace.
- **`system.cli.strict`** throws on any switch no declaration covers, and
  **`unknown`** returns them, so `--verbse` no longer parses silently as a flag
  nothing reads. `run` applies it with `strict: true`.
- **`option`** gained `allowed:` to limit accepted values, `env:` to name an
  environment variable to fall back on, and `csv:` to split one
  comma-separated value into repeats for `all`.
- **`Cli.usageExit`**, the conventional `EX_USAGE` exit code.
- **`Cli.parsed`** on the accessor, for handing the parsed command line to code
  that takes a `Cli`.

### Changed

- **`get` now resolves the declaration.** Sources are tried in order: the
  command line, the `env` variable, the declared `def`, then the fallback at
  the call site. A default is written once in the declaration instead of at
  every call site.
- **`require` accepts a default or a set environment variable as supplied,** as
  documented, and also checks every given value against its `allowed` list. Its
  message now names each failure rather than only the missing names.
- **Usage blocks wrap to the terminal width**, size the label column to its
  contents, and list commands alongside `allowed` values and `env` fallbacks.
  `(required)` is printed only when nothing else can supply a value.
- **`flag`'s `def` is now `bool?`**, so an unset default falls through to the
  call site rather than forcing `false`.

### Fixed

- **`-abc` now clusters into the short flags `a`, `b` and `c`**, as the
  documentation always claimed; it previously parsed as one flag named `abc`. A
  clustered switch declared with a value ends the cluster and takes the rest of
  it or the next argument, so `-o dist`, `-odist` and `-vodist` all set `o`.
  Only all-letter tokens cluster, and a declared multi-letter short name is
  never split.
- **Declarations registered before `system.cli.parse` are honoured by the
  parse itself.** They were dropped, so a declared flag still swallowed the
  token after it: `tool build --verbose main.dart` lost `main.dart`.
- **`require` no longer throws for an option that declares a default.**

## 1.0.0

First release. A lightweight web-crawling pipeline and command-line automation
toolkit for Dart, organised into seven domain namespaces with lowercase,
preferably one-word methods. [NAMESPACE.md](NAMESPACE.md) records the rules
that decide where a name goes and what it is called.

### `net` — requests, crawling, selectors

- **`net.http`**, a retrying client over `package:http`. Retries transport
  errors, 5xx and 429, honouring `Retry-After` in either delta-seconds or
  HTTP-date form and falling back to jittered backoff when it is unparseable.
  Redirects are followed with correct method rewriting; `cap` refuses
  oversized bodies so one unexpected URL cannot exhaust memory.
- **Sessions.** `HttpClient(session: true)` or your own `CookieJar`, following
  RFC 6265: several `Set-Cookie` headers on one response are all stored (the
  comma-joined form `package:http` produces is split correctly, including
  around the comma inside an `Expires` date), `Max-Age` takes precedence over
  `Expires`, an expired cookie deletes the entry it names, the default path is
  the directory of the request, and cookies are sent longest-path-first.
- **`net.crawl`**, a declarative crawler. Stages are handlers dispatched by
  `route` (the URL) or `tag` (whatever queued the request), with `meta`
  carrying context between them. Scope comes from `depth`, `limit`, `samehost`,
  `allow`/`deny` and `robots`; pacing from `delay` and `perhost`. Finish with
  `run`, `collect`, `stream` or `save` — the last streams to disk, so a long
  crawl never holds its results in memory.
- **`robots.txt` per RFC 9309.** Product-token matching, so a `User-agent:
  MyBot` group governs a crawler calling itself `MyBot/1.0`; `Crawl-delay` is
  obeyed as a per-host floor; the pending fetch is cached, so workers arriving
  at a new host together share one request.
- **Selectors.** `res.$('...')` is a chainable jQuery-like set with the CSS
  extensions (`:contains`, `:has`, `:eq`, `:first`, `[attr!=value]`, …) and
  full traversal; `res.$xpath('...')` for what CSS cannot say. Single-element
  matching is memoised per (root, selector), which keeps `closest`, `not` and
  the child combinators linear instead of quadratic, and each distinct selector
  string is parsed once rather than on every call.
- **Extraction, loose or typed.** `res.extract({...})` takes a string schema
  (`'h1'`, `'a@href'`, `['li']`, `['.row', {...}]`); `res.pick(Field.text('h1'))`
  keeps the type. They mix freely in one schema.
- **Testability.** Swap `.downloader(MapDownloader({...}))` and the rest of the
  pipeline is unchanged, so a crawl can be tested without the network.

### `io` — the filesystem

- Every write is atomic: it stages into a `.part` sibling and is renamed into
  place only after a successful flush, with the staging file removed on Ctrl-C.
- **`io.*` blocks; `io.async.*` is the same names as futures.** One isolate runs
  every task in a crawl, so a blocking read stalls everything in flight — reach
  for `io.async` inside handlers and pool workers.
- **`io.csv`** parses, formats, reads and streams tables, as rows or as maps.
- **`io.store`** is a JSON-backed key-value map for the state scripts keep
  between runs: cursors, tokens, "last seen" markers.

### `system` — this program and the machine

- **`system.cli`** parses `--flag`, `--key=value`, `--key value`, `-k value`,
  `--no-key`, repeated options and trailing positionals. Declare the interface
  once and `--help` writes itself; a declared alias is honoured by every later
  lookup.
- **`system.console`** covers status logging, tables, boxes, rules, progress
  bars, spinners, ANSI colour with terminal detection, and prompts.
- **`system.env`** reads the environment and `.env` files, typed through a
  required fallback.
- **Crash-safe shutdown.** `system.on.exit` registers a hook; `system.shutdown`
  kills adopted children, deletes tracked partials, runs the hooks and exits.

### `concurrent` — bounded async work

- `concurrent.run` maps over items with at most `size` in flight, results in
  input order; `stream` yields them in completion order, honouring pause and
  cancel; `Pool.settle` runs everything to completion and reports per-item
  outcomes.
- `concurrent.retry` with linear backoff, a cap and jitter; `Semaphore` and
  `Mutex`; `concurrent.compute` for a separate isolate.

### `git` and `zip`

- **`git`** wraps the executable: `branch`, `hash`, `dirty`, `status`, `tag`,
  `add`, `commit`, `push`, `pull`, `clone`.
- **`zip`** packs and unpacks `.zip`, `.tar`, `.tar.gz`, `.tgz` and `.tar.bz2`,
  choosing the format from the file name. `list` and `read` look inside without
  unpacking, `bundle` builds an archive from data that never touched the disk,
  and entries that would escape the destination — the "zip slip" attack — are
  skipped rather than trusted.

### `util` — pure helpers

Nothing here touches the disk or the operating system; that is the rule that
keeps it small.

- **`util.text`**: `slug`, `clean`, `strip`, `clip`, `fold`, `title`, `words`,
  `number`/`numbers` (which read `$1,234.50`), and `between`/`betweens` for
  reaching a value no selector can.
- **`util.hash`**: `sha`, `md5`, `short` (a cache key), `sign` (HMAC-SHA256),
  base64 `encode`/`decode`.
- **`util.rand`**: `pick`, `some`, `shuffle`, `between`, `id`, `jitter`,
  `chance`.
- **`util.time`** and **`util.size`**: delays, stopwatches, timestamps,
  relative descriptions, and human-readable byte sizes.

### Throughout

- **Real types at every boundary.** URLs are `Uri`, delays are `Duration`,
  paths are `String`; bodies, digests, extraction fields and archive formats
  are sealed types and enums, so a wrong call fails in the analyzer.
- **Every name appears exactly once.** No aliases and no flat shortcuts — each
  operation is reachable one way.
- **176 tests**, and every code sample in `docs/` is compiled by the suite, so
  a stale example fails the build.
