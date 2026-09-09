# Changelog

All notable changes to this project will be documented in this file.

## 1.3.0

Fetch less, parse less. A re-run over pages that have not changed used to cost
exactly as much as the first run, and anything a server sent — a PDF, a video,
half a gigabyte of it — was handed to the HTML parser like any other page.

### Added

- **`HttpClient(cache: HttpCache(dir))` and `net.crawl(...).cache(dir)` keep
  responses between runs.** A second run revalidates with `If-None-Match` and
  `If-Modified-Since`, so a `304` serves the stored body without one byte of it
  crossing the wire; a response still inside its `max-age` or `Expires` is not
  even asked about. Only `GET` responses with status 200 are stored, and only
  when the server did not say `no-store`. `HttpCache` is usable on its own —
  `read`, `write`, `remove`, `clear` — and a `CacheEntry` reports `fresh`,
  `lifetime` and the `validators` it would revalidate with.
- **`HttpResponse.cached`** says a response was served from the cache rather
  than downloaded, so a handler can return early on the pages that did not
  move.
- **`net.crawl(...).accept(types)`** sends the types as the `Accept` header and
  drops a response that arrives as something else anyway before a handler sees
  it, counting it in `Stats.skipped`. Entries take a `/*` wildcard on the
  subtype.
- **`net.crawl(...).cap(bytes)`** reaches the client's existing body limit from
  the builder, so a crawl can refuse a body too large to hold rather than
  discovering it in memory.
- **`Response.follow` takes a `method` and a `body`.** A form is now followed
  the way a link is, instead of reaching past the response for `engine.add`.
  De-duplication reads the body, so two posts to one URL with different fields
  are two requests.
- **`MapDownloader` matches a method-prefixed key** — `'POST /login'` before
  `'/login'` — so one URL can answer differently to a `GET` and a `POST`, and
  records every request it served in `requests`. A POST pipeline can now be
  fixtured and asserted on.
- **`util.rand.seed([seed])`** fixes the generator behind every random choice
  the library makes, which is what a test of a crawl's order or a retry's
  timing needs. Calling it with nothing restores an unseeded generator.

### Fixed

- **A `robots.txt` that answers 5xx disallows the host** (RFC 9309 section
  2.3.1.4). Rules that could not be read are not the same as rules that are not
  there, and the crawler was reading both as permission. A 4xx still allows
  everything, per 2.3.1.3. A transport error is treated as the 4xx case — a
  deliberate departure, since stopping a whole crawl over one failed DNS lookup
  costs more than it protects.

### Changed

- **`HttpClient`'s retry jitter runs through `util.rand.jitter`** instead of a
  private `Random` of its own. Two generators doing one job left half the
  library's randomness outside the reach of `util.rand.seed`.

## 1.2.0

A crawl you can interrupt. The frontier — the queue of pages a run has found
but not yet fetched — used to live only in memory, so a crawl stopped at hour
three restarted from the seed. It now serializes, alongside the visited set and
the counters, and a run picks up where the last one stopped.

Shipped on top of an audit of the library against its own documentation.

### Added

- **`net.crawl(...).resume(path)` saves a crawl's position and carries on from
  it.** An existing file restores the frontier, the visited set and the
  counters, so seeds already visited are not fetched twice and `limit` still
  counts the whole crawl rather than this leg of it. The file is rewritten on a
  timer (`every`, five seconds by default), once more when the run stops, and
  once more again if the process is interrupted. A crawl that drains on its own
  deletes it, having nothing left to resume.
- **`Engine.snapshot()` and `Engine.restore(snapshot)`**, the pair `resume` is
  built from, so a position can be kept anywhere a `Map` can go — `io.store`, a
  database row, a key-value service. `Snapshot` carries the pending requests,
  the `Deduplicator` and the `Stats`, and round-trips through
  `toJson`/`fromJson` with a `version` it refuses to read from the future.
- **`Request`, `Body` and `Stats` serialize.** Everything scheduling and
  routing depend on survives the trip: the method, headers, body, priority,
  tag, depth and `meta`. A `Body.bytes` body is base64-encoded, so a body that
  is not valid UTF-8 comes back intact.
- **`SIGTERM` is watched alongside `SIGINT`.** `kill`, a supervisor and a
  container runtime all send the former, which the watcher ignored — so a
  terminated run left its `.part` files on disk and its exit hooks unrun. The
  exit code follows the shell convention of 128 plus the signal number, so a
  caller can tell a Ctrl-C (130) from a `kill` (143).

An audit of the library against its own documentation. Every item below was
reproduced first and now has a regression test in `test/regression_test.dart`.

### Security

- **A `Set-Cookie` header can no longer widen a cookie to a domain the
  responding host does not belong to.** The `Domain` attribute was stored
  verbatim, so a response from `evil.example.com` could set `Domain=com` and
  have that cookie sent to every other `.com` host the client later visited.
  A domain is now honoured only when the request host equals it or sits under
  it at a label boundary, and a bare TLD is refused outright; anything else
  falls back to a host-only cookie (RFC 6265 section 5.3.6).

### Fixed

- **`system.cli.get<bool>` reads the `env` variable an option declares.** The
  environment value arrives as text and was type-tested against `bool`, so it
  could never satisfy a boolean option, and `def` was consulted ahead of `env`
  against the documented order. Both now match every other type: the command
  line, then `env`, then `def`, then the call site's fallback.
- **`require` no longer accepts a valueless switch for an option.** `--out`
  with nothing after it parses as a bare switch, which satisfied
  `required: true` while `get` still handed back the call site's fallback. A
  flag is still satisfied by its presence alone.
- **A `robots.txt` group holding only `Crawl-delay` no longer absorbs the
  rules of the group after it.** Group boundaries were inferred from whether
  any rule had been collected, so a `User-agent` with just a crawl delay stayed
  open and inherited the next agent's `Disallow` lines.
- **`Sitemap.load` cannot recurse forever.** A sitemap index pointing at itself,
  or at another index pointing back, looped indefinitely. Fetched URLs are now
  remembered and the descent stops at `Sitemap.maxDepth`.
- **`coerce` no longer turns a URL into a `data:` document** because its query
  carried `</` or `/>`; recognised schemes are tested before markup is sniffed.
- **A `file:` URI for a path that is not there reports 404.** It fell through to
  the generic branch and returned status 200 with the URI string as the body.
- **A crawl's `.base()` is honoured for HTTP downloads.** `Downloader.save`
  delegated the destination to the client, which resolves against its own base
  — usually the shared `net.http` client, which has none — so `.base('out')`
  silently wrote to the working directory. The other schemes already resolved.
- **`HttpClient.send` no longer spends its retry budget on settled failures.**
  A body over `cap` and a redirect chain past its limit were caught by the
  generic retry handler and re-downloaded; both now raise
  `FatalHttpException`, which is rethrown immediately.
- **The per-request `timeout` covers the response body.** It wrapped only the
  request, so a server dribbling bytes could hold a worker open indefinitely.
- **`find` searches descendants for jQuery selectors as it always did for
  plain CSS.** An extended selector also matched the context element itself, so
  `find('div')` and `find('div:contains(x)')` disagreed on the same fragment.
  Use `matching` to ask whether the set itself qualifies, or the callable
  shorthand to search the whole parsed document; a document root can still
  match itself, as `querySelectorAll` does.
- **`system.untrack` releases the file it names.** Tracked files were held in a
  `Set<File>` and `dart:io`'s `File` has no value equality, so untracking
  through a different instance left the entry — and a stuck entry keeps the
  `SIGINT` watcher, and so the process, alive.
- **A timed-out subprocess is followed to `SIGKILL`.** `system.run` sent
  `SIGTERM`, reported `-1` and disowned the process, leaving a child that traps
  the signal orphaned. Its stdin is also closed now, so a child that reads
  input cannot block a captured run forever.
- **Atomic writes no longer unlink the destination first.** POSIX `rename`
  replaces atomically; deleting first opened a window in which a reader saw no
  file at all. The unlink now happens only on Windows, where it is required.
- **`Fs.download` closes its sink when a transfer fails**, instead of leaking
  the descriptor and blocking the cleanup unlink on Windows.
- **`io.hash` streams the file**, as `util.hash`'s documentation always claimed;
  both variants read the whole thing into memory.
- **`io.csv.format` keeps columns that only later rows carry.** Columns came
  from the first row's keys alone, so a field absent from it was dropped with
  no error. Columns are now the union of every row's keys, first-seen order.
- **`io.csv` honours a multi-character delimiter**, in `parse` and in the
  streaming reader, including one straddling a chunk boundary. It was compared
  a character at a time, so anything longer never matched.
- **A blank line no longer yields an empty CSV row**, so a trailing newline
  does not add one.
- **`io.store` survives a malformed file.** `load` threw `FormatException`
  from the constructor, so one interrupted write made every later run fail.
  A missing, empty, unreadable, malformed or non-object document leaves the
  store untouched.
- **`Ansi.width` counts terminal columns.** It counted UTF-16 code units, so a
  CJK ideograph measured 1 against the 2 it renders and every table, box and
  rule built from wide text came out crooked. Combining marks now measure zero.
- **`Table` renders with a partial `alignments` list** instead of throwing
  `RangeError`; it is padded to the column count with `ColumnAlign.left`.
- **`util.text.number` stops merging separate numbers.** A space counted as
  digit grouping unconditionally, so `'12 34'` read as `1234` and
  `numbers('1 2 3')` as `[123]`. A space now groups only when it separates
  whole groups of three, leaving `'1 234 567'` a single number.
- **`util.text.slug` keeps letters of other scripts.** Everything outside
  `a-z0-9` collapsed, so a CJK or Cyrillic title produced an empty slug — and
  an empty filename with it.
- **`util.text.clip` never splits a character in half**, which turned a clipped
  emoji into a replacement character.
- **`util.size.format` picks the unit after rounding**, so 1048575 bytes is
  `1.0 MB` rather than `1024.0 KB`.
- **`util.size.parse` returns 0 for a unit it does not know**, as documented,
  instead of reading `'10 XB'` as ten bytes.
- **`util.rand.jitter` is never shorter than its base**, as documented; a
  negative spread is treated as zero. **`between`** handles spans wider than
  `Random.nextInt`'s 32-bit bound instead of throwing `RangeError`.
- **`Semaphore.release` no longer raises the permit ceiling.** A release that
  paired with no acquire pushed the count above the maximum, removing the bound
  the semaphore exists to enforce.
- **`PoolFailure.toString` describes an empty failure list** instead of
  throwing `StateError`.
- **`reader.pick`, `picks` and `ask` give up at end of input.** Each re-prompted
  forever once stdin closed — an unattended run spun writing prompts nothing
  could answer — and now throw `StateError` explaining how to supply the value.
  **`reader.close`** completes any prompt still waiting rather than leaving its
  future pending, and **`secret`** works off a terminal, where reading
  `echoMode` threw before the guard could restore it.
- **`logger.task` honours `level`**, so a `LogLevel.none` logger no longer
  prints a spinner. **`Progress.done`, `Progress.fail` and `Spinner.stop`** no
  longer write a stray newline or carriage return when stdout is not a
  terminal, as "piped output stays clean" promised.
- **`git` query methods fail softly when `git` is not installed.**
  `ProcessException` escaped, against the documented contract; the result now
  carries `GitAccessor.missingExit`. **`branch`** reports `''` for a detached
  `HEAD` rather than the literal `HEAD`.
- **`zip.pack` no longer follows symlinks**, which pulled in files from outside
  the tree and could walk in circles, and **`unpack` skips link entries**
  rather than recreating them as directories.
- **The robots, host-throttle and selector caches evict least-recently-used
  entries**, as their comments claimed; all three dropped the oldest insertion,
  so a host or selector in constant use could be evicted ahead of one seen once.

### Changed

- **`Progress`'s default glyphs match `system.console.progress`** (`█` and `░`);
  the two entry points disagreed.
- **`Cli.get<bool>` accepts the same words as `system.env.get`** — `true`, `1`,
  `yes`, `on` — for values reached through `env` or `def`.
- **A request counts as crawled when its handler has run, not when its worker
  settles.** A response that arrived after the run stopped, or one whose
  handler threw, is unfinished work: it stays pending in a snapshot so a
  resumed crawl fetches the page again rather than losing it. `Engine.skip`
  now takes the request it dropped, as an optional argument, for the same
  reason. `Engine.leave` is unchanged.
- Documentation corrected where the code was right and the prose was not:
  `io.async` mirrors every disk operation rather than literally every name on
  `io`; `Cookie.parse` points at `CookieJar.add` instead of a private method;
  `Engine`'s truncated doc comment no longer sits on the frontier queue; and
  `zip.deflate` says plainly that it produces a gzip stream. `docs/crawl.md`
  finishes a crawl with `save`, the name `to` was given in 1.1.0.

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
