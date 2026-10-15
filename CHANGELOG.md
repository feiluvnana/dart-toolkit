# Changelog

## Unreleased

**Added**
- `scrape`: new module: `Scrape(limit:, retries:, rate:, key:, onProgress:).run(seeds, onItem:, onError:)`, a typed work queue: the handler switches on `visit.item`, `visit.add` queues more (deduplicated by `key:`; returns whether it was new), `visit.emit` streams results; `onError` gets the same `Visit`, so it can queue a replacement.
- `yaml`: new module: `Yaml.parse`, `reader.yaml(or:)` → the same `Json` reading API (package:yaml).
- `fs`: `Fs.temp((dir) async {…})` (a scoped temp folder, deleted after, Ctrl-C included), `Fs.home()`, `file.lock(() async {…}, wait:)` (one run at a time across processes), `Entry.modified()`.
- `shell`: `Shell.run(timeout:)` kills the child and throws a `TimeoutException` naming the command; `Shell.which(program)`.
- `core`: `DateTime.format('yyyy-MM-dd_HHmm')`, `Duration.human()` (`11 min 5 s`); every toolkit timeout message uses it.
- `console`: `Bar.update(done, total)` (`onProgress: bar.update`).
- `core`: `Cookies` (a jar with domain/path/expiry: `parse` `encode` `[]` `header` `set`), shared by chrome and http; `Rate` moved here from http (pool paces with it too); `Durations` on `num` (`3.seconds`, `1.5.minutes`); `Writer` is a mixin with `origin()` (a `File` reports its path).
- `http`: `Http.client(base:, headers:, timeout:, retries:, rate:, check:, cookies:, csrf:, proxy:, cache:, ttl:, insecure:, idle:, connections:)` holds the settings a script states once; `client.copy(...)` is a variant sharing jar, `Rate` and sockets; `Http.pool([...])` spreads requests over clients (fewest in flight, 429 benches a member). `Http.client(resume: true)`: a GET piped into a file (`cdn.get(u) | bar > Fs.file(f)`) skips a complete file, resumes a `.part` with `Range` and renames atomically; stored bytes replay through pass-through pipes (bars count everything, hashes verify). `Http.serve(handler)` with `Request`/`Reply`/`Server` for OAuth loopbacks, webhooks and previews. `Response.check()`. `query:`/`Body.form` take `num`/`bool`/null/`Iterable` values. `cache:` answers GETs from disk within `ttl`. `proxy:` (null reads `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`). `HttpRequestException` with `RequestFailure.aborted`/`redirects`/`unsendable`.
- `pool`: `Pool.settle` (one `Outcome` — `Done`/`Failed`, item included — per item, never throws), `retries:`, `rate:`, `isolates:` (long-lived workers), `onDone:`.
- `chrome`: `page.cookie(name, timeout:)` waits for a cookie; `page.responses(glob)` streams XHR/fetch responses as `Capture` readers.
- `json`: `|` alternatives in a path segment (`$('pk|id')`), `text()` for any scalar, `max`/`min`, `json(or:)` for a missing source.
- `html`: `Elements.json()` (embedded JSON/ld+json/`__NEXT_DATA__`), `table()`, `form()`; full CSS selectors (`:nth-child(An+B of S)`, `:is`, `:where`, `:has`, `:lang`, attribute `i` flag …).
- `fs`: `File.text(or:)`, `bytes(or:)`; `Dir.list(match: '**/*.{jpg,png}')` (in-house globs).
- `csv`: new module: RFC 4180 `Csv.parse`/`records`/`encode`, `reader.csv()`.
- `console`: `Console.table(rows, header:)`.
- `cli`: `Command(dotenv: '.env')`.
- `http`: `Rate(count, per, {pause, onWait})` and `rate:` on every verb: shared pacing with a sliding window and a random pause; a 429 on a paced call waits the window out instead of backing off from 1 s.
- `json`: a `**` path segment searches every depth (`$('**.pk')`).
- `cli`: `values:` on `Opt`/`Multi`/`Arg` for a fixed set (enums by name; usage lists them, typos get a suggestion); enum defaults show by name.

**Fixed**
- `cli`: a handler failure prints the toolkit error's message (not `FormatException: …`/`HttpException: …, uri = …`), and a plain `Exception('…')` without its prefix.
- `json`: an escaped `\*` is a literal key again, not a wildcard.
- `chrome`: `Page.cookies()` sends `name=value` as the browser does; values with `=` or `"` were quoted into an invalid header.

**Changed**
- `cli`: `Command.run` sets `exitCode` itself (64 usage, 1 failure; success leaves it alone), so scripts write `await cmd.run(args)`.

- `console`: several `spin`/`bar` lines at once (stacked; was a `StateError`); `ask` on piped stdin no longer blocks timers; a second Ctrl-C during cleanup exits at once.
- `cli`: a bare group command prints usage to stderr and exits 64; `--no-x` only for a `Flag(or: true)`; messages read `Option --x needs a value`; Duration defaults show as `1m30s`.
- `tui`: status-row errors drop the SDK prefix; handler stacks print to stderr after quitting; a throwing `suggest` shows `✗ msg`.
- `archive`: an existing file in `dir` is kept (was replaced); zip CRC, RAR5 BLAKE2sp and 7z header CRC are checked; a truncated RAR fails; every damaged-archive and gunzip error is a `ContentException` with `cause`; zip entries carry the file's mtime; tar typeflag `7` extracts.
- `fs`: `File`/`Dir.exists()` follow links; `delete()` on a link removes the link; a wrong-kind `delete()` throws; chmod/touch failures throw (BSD `chmod` was always exiting 1).
- `chrome`: every action wraps engine failures as `BrowserException`; `select` with a missing option is a `BrowserException`; timeouts read `… after 1 s`; `idle()` settles with a long-poll or SSE open.
- `shell`: `check:`/`filter` errors keep the last 64 KB of stderr.
- `json`: `print(json)` shows JSON, `==` is deep; `json()` errors name the URL/path and status; `value<List<int>>()` throws in every build mode.
- `http`: JSON bodies are always UTF-8 (no `<meta charset>` sniffing outside HTML); `redact` masks exact secret names only.
- `html`: a bad `<base href>` is ignored.
- `image`: webp/ico refusals throw from `encode()`.

**Performance**
- `html`: an in-house HTML5 parser and selector engine replace package:html and csslib: startup ~770 → ~235 ms, chrome ~1750 → ~1300 ms; parsing and queries never recurse, so 20,000-deep pages work. A corpus test holds the tree to package:html's on 50 real pages.
- 7z with 20k files 150 → 25 ms; CRC-32 4× (slicing-by-8); an archive handed over in one chunk 538 → 60 ms and −500 MB; `Region.write` of 80k chars 6.7 s → 65 ms; streamed markdown 4×; `$('div').$('a')` on nested roots 144 → 1 ms; `Json.$('key')` 5×; single-byte charsets 3.6×.

**Docs**
- VISION, ARCHITECTURE and PLAN moved to `docs/`; DOGFOOD.md removed; both PROPOSAL rounds executed and removed.

**Breaking**
- `http`: `Client.save` is gone: `Http.client(resume: true)` and `get(u) | … > file` do it through the pipe.
- `http`: the static verbs, `Http.hold`, `Http.abort` and `options` are gone: `Http.client(...)` holds settings, `client.close()` cancels its own requests. Per-call parameters are only `query`, `headers`, `body`. Retries default to 2 for every verb but only resend what provably was not processed (POST retries on connect failures, 429 and 503; 500 is never retried); backoff has ±25% jitter. Cookies belong to a client, not the process. `HttpStatusException.status` is non-null; redirect failures are `HttpRequestException`. Piping a non-2xx throws what `check()` throws (with the snippet). `size()` is null for a body decoded on the fly; `lines()` works on any status.
- `pool`: `Pool.runAll` → `Pool.map(isolates: true)`; `onResult:` → `onDone:` (no argument, so `onDone: bar.tick`).
- `chrome`: `page.cookies()` returns `Cookies` (was a `Cookie:` string); closing the window during `cookie()`/`wait()` is `BrowserException('browser closed…')`.
- `html`: a fragment with loose text is returned as its root (was a synthetic `<div>` that `$('div')` matched); `noscript` content is text, as in a browser with scripting; a page nested too deep no longer overflows; selectors package:html rejected now work, and `:empty`/`:nth-child` follow the spec.
- `core`: `Writer` is a mixin class: `implements Writer` → `with Writer`.

**Deviations from the proposal**
- `html` startup is ~235 ms for a bare import; a script that also parses pays ~260 ms (target "under 250"): the remaining cost is compiling the parser and json.
- `json`: `|` alternatives are per segment, as specified, so `image_versions2.candidates|display_resources` (different depths) is written as two reads.
- A `resume: true` GET piped into an existing file sends a GET and drops it after the headers to compare `content-length`, so a rerun costs one request per file.
- `Fs.temp` and `File.lock` are scopes (`(dir) async {…}`), not handles: an exit hook only runs on signals and keeps the VM alive while registered, so a handle deleted "on exit" would hang a finished script.
- `yaml` does not support `<<` merge keys (package:yaml follows YAML 1.2).
- Projects (1124 lines before round 1): instaloader 278, keybox 206, mediapure 153 (the catalog's three item types cost 15 lines over the hand loop), rawfree 477, plus the new backup 51, release 83 and lgtmeow 60 (a random LGTM cat as Markdown, copied to the clipboard).
- `scrape` removed: a loop over `Http.get` + `Html.parse` (with `rate:` and `Json.$('**.k')`) reads as well and has nothing extra to learn.
- Unified errors: failures the toolkit itself reports are typed `ToolkitException`s — `HttpStatusException` (non-2xx, with `status`/`method`/`url`/`snippet`), `ContentException` (bad JSON, selectors, archives, images, checksums), `BrowserException` (failed tab actions); `UsageException` extends the same base. Each extends the SDK type it replaces, so existing `on HttpException`/`on FormatException`/`on StateError` catches keep working, and messages are unchanged. Engine failures, `ArgumentError`/`RangeError`, `TimeoutException` and rethrows keep their SDK types.

## 0.0.4

**Breaking**
- Short names across every module (`status` `ok` `url` `hex` `wait` …); `writeTo` is `to`.
- `archive`: `Archive.archive(paths, {format, dir, password})` and `unarchive(dir, {password})` replace `pack`/`unpack`.
- `pool`: `Pool.run` and `Pool.close` are gone (use `Isolate.run`); `Pool.map` runs 4 lanes by default.
- `console`: `Console.notify`/`copy` replace `App.notify`/`copy`.
- `tui`: alternate screen only (inline mode removed); no colour unless an accent is set.
- `http`: GET/HEAD retry twice by default; `insecure:` takes a host list; `retries:` with a `Body.stream` is an `ArgumentError`.
- `image`: `Image.sniff` returns an `ImageFormat`.
- Dependencies dropped: `archive`, `http`, `worker_manager`.

**Added**
- `archive`: zip with AES-256 (write) and AES/ZipCrypto (read); 7z read (LZMA, LZMA2, PPMd, Deflate, BCJ, AES) and write (Deflate, AES, hidden names); RAR4 and RAR5 read (filters, solid, PPMd, AES); `.tar.xz` read. All pure Dart.
- `core`: `Reader.lines()`.
- `http`: `query:` on every verb, a per-host cookie jar (redirect hops included), a 100 ms idle grace so sequential requests share a connection, `Http.abort()`.
- `fs`: `Fs.sanitize(name)`, `Entry.path(from: dir)`.
- `hash`: `expect:` verifies inside a pipe; `Hasher.of(reader)`.
- `shell`: `Shell.run(check:, onLine:)`.
- `cli`: `Opt(env:)`.
- `scrape`: `follow(under:, skip:)`, `crawl(onProgress:)`.

**Fixed**
- Security: terminal escapes in untrusted text are neutralised; redirects drop secret headers; credentials are redacted from errors and scoped to their origin; archive member names are checked (traversal, case clashes, non-portable names) and modes go through the umask; links are not followed into destinations.
- Platform: `TERM=dumb`, `LANG=C`, `NO_COLOR`, Unicode 16 widths, kitty/X10 keys, piped stdin for Tui and Console, Ctrl-Z suspend.
- Signals: one exit owner, so Ctrl-C restores the terminal, closes browsers and ends child processes.
- Many smaller fixes in http (stalls, unread bodies, Retry-After), tar streaming (8 GiB+, pax), scrape cache keys and Tui drawing.

## 0.0.3

Memory pass, Tui draw/update events, a startup split.

## 0.0.2

Stream operators and XPath in-house; `rxdart` and `xpath` dropped.

## 0.0.1

First release of the redesigned API.
