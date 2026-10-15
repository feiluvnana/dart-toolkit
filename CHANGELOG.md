# Changelog

## 0.0.5

**Added**

- `cli`: a `Multi` with `values:` also takes comma lists (`--category=photo,reel`).
- `cli`: `Rest<T>('file', …)` takes the positionals after the `Arg`s as a typed `List<T>` (usage `<file>...`); `context.rest()` is gone, and a positional nothing takes is an error.
- instaloader: `download [--category=photo,reel,story,highlight] <user>...` (default: all the login allows); every user and category is explored at once (posts, stories, highlights) and feeds one queue downloading 8 files at a time, under a full-screen dashboard (`dashboard.`), coloured, every panel scrollable, text selectable by dragging: users still being looked up one bold row each, then per user each folder's bar, new/had/failed, size and what its explorer is doing (listing page N, fetching highlights, rate-limit waits), every file in flight with its bytes and speed, totals (files, size, speed, API calls, elapsed) and a log (`r` retries every failure: failed files queue again and a user whose lookup or listing failed is fetched again; `l` saves the log to `.instaloader.log` next to the script; clicking the log's header shows only failures; a folder finished without failures shrinks to one row; `q` quits, asking first while it runs; failures left at the end exit non-zero); a table per user prints after, and without a terminal the log prints line by line; photos and reels share one feed listing; files land in `photos/<day>/` and `reels/<day>/` with each caption as `<code>.txt`, `stories/<day>/` and `highlights/<title>/` (older flat downloads move into place); every highlight is listed (the profile page embeds few) and fetched 10 per call; the script is split into prefixed imports (`instagram.`, `media.`, `download.`).
- instaloader: each user's `.instaloader.json` (written as the user starts and after every listed page, so an interrupted run never starts over; the cursor resumes even a full listing) remembers (every tracking file is `.instaloader*`: the listing cursor is `.instaloader-cursor-<folders>`) every post with its item ids in file-number order, the posts hidden now, and each highlight's items. An edited album keeps its file names (new items take the next numbers); once a week (or with `--all`) every post is listed, and posts hidden, deleted or shown again, edited albums and changed highlights are reported and notified. Nothing is ever deleted except by `--reset`, which asks, then deletes the chosen categories' folders so they download again.
- instaloader: `--category=profile` keeps every profile picture seen in `profiles/` (HD with a login, named by the day first seen; a new one is reported); the index also records every story seen.
- `yaml`: new module: `Yaml.parse`, `reader.yaml(or:)` → the same `Json` reading API (package:yaml).
- `fs`: `Fs.tempDir((dir) async {…})` (a scoped temp folder, deleted after, Ctrl-C included), `Fs.homeDir()`, `Fs.scriptDir()` (the running script's folder, for data kept next to it), `file.lock(() async {…}, wait:)` (one run at a time across processes), `Entry.modified()`.
- `shell`: `Shell.run(timeout:)` kills the child and throws a `TimeoutException` naming the command; `Shell.which(program)`.
- `core`: `DateTime.format('yyyy-MM-dd_HHmm')`, `Duration.human()` (`11 min 5 s`); every toolkit timeout message uses it.
- `console`: `Bar.update(done, total)` (`onProgress: bar.update`).
- `core`: `Pipe.tap((done, total) {…})`, a pass-through progress probe for hand-drawn progress (a Tui); resumable like a bar, it hears the full length and replayed bytes.
- `tui`: `Region.bar(done, total, bytes: true)` shows sizes (`1.5 KB/4.0 KB`).
- `tui`: a scroll's scrollbar jumps on a click and follows a left drag.
- `tui`: colour everywhere: `box`, `popup`, `tabs`, `list`, `table`, `input`, `button`, `bar`, `spin`, `markdown` and `diff` take `write`'s `color`/`background`/`style`; `highlight:` backs the selection of `list`/`table`/`tabs` (default: the accent); `diff(removed:, added:)`. `box` takes its title positionally (`box('')` for none).
- `tui`: `on:` on `write`, `box` (its header row), `bar`, `spin`, `markdown` and `diff` binds events (`click`, `rightclick`, keys …, as in `Region.on`) to what the widget drew.
- `tui`: a left drag selects text (within the scroll it starts in) and letting go copies it to the clipboard (OSC 52).
- `console`: `Console.bar(..., keep: false)`: the line vanishes when the bar finishes (a failed one still prints ✗), for per-file bars that should not fill the scrollback.
- `core`: `Cookies` (a jar with domain/path/expiry: `parse`/`encode` read and write a Netscape `cookies.txt`, the format browser exports and curl use; `[]` `header` `set`), shared by chrome and http; `Rate` moved here from http (pool paces with it too); `Durations` on `num` (`3.seconds`, `1.5.minutes`); `Writer` is a mixin with `origin()` (a `File` reports its path).
- `http`: `Http.client(base:, headers:, timeout:, retries:, rate:, check:, cookies:, csrf:, proxy:, cache:, ttl:, insecure:, idle:, connections:)` holds the settings a script states once; `client.copy(...)` is a variant sharing jar, `Rate` and sockets; `Http.pool([...])` spreads requests over clients (fewest in flight, 429 benches a member). `Http.client(resume: true)`: a GET piped into a file (`cdn.get(u) | bar > Fs.file(f)`) skips a complete file, resumes a `.part` with `Range` and renames atomically; stored bytes replay through pass-through pipes (bars count everything, hashes verify). `Http.serve(handler)` with `Request`/`Reply`/`Server` for OAuth loopbacks, webhooks and previews. `Response.check()`. `query:`/`Body.form` take `num`/`bool`/null/`Iterable` values. `cache:` answers GETs from disk within `ttl`. `proxy:` (null reads `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`). `HttpRequestException` with `RequestFailure.aborted`/`redirects`/`unsendable`.
- `pool`: `Pool.settle` (one `Outcome` — `Done`/`Failed`, item included — per item, never throws), `retries:`, `rate:`, `isolates:` (long-lived workers), `onDone:`.
- `chrome`: `page.cookie(name, timeout:)` waits for a cookie; `page.responses(glob)` streams XHR/fetch responses as `Capture` readers.
- `json`: `|` alternatives in a path segment (`$('pk|id')`), `text()` for any scalar, `max`/`min`, `json(or:)` for a missing source.
- `html`: `Elements.json()` (embedded JSON/ld+json/`__NEXT_DATA__`), `table()`, `form()`; full CSS selectors (`:nth-child(An+B of S)`, `:is`, `:where`, `:has`, `:lang`, attribute `i` flag …).
- `fs`: `File.text(or:)`, `bytes(or:)`; `Dir.list(match: '**/*.{jpg,png}')` (in-house globs); `Dir.watch()` streams files created or changed.
- `csv`: new module: RFC 4180 `Csv.parse`/`records`/`encode`, `reader.csv()`.
- `console`: `Console.table(rows, header:)`.
- `cli`: `Command(dotenv: '.env')`.
- `http`: `Rate(count, per, {pause, onWait})` and `rate:` on every verb: shared pacing with a sliding window and a random pause; a 429 on a paced call waits the window out instead of backing off from 1 s.
- `json`: a `**` path segment searches every depth (`$('**.pk')`).
- `cli`: `values:` on `Opt`/`Multi`/`Arg` for a fixed set (enums by name; usage lists them, typos get a suggestion); enum defaults show by name.

**Fixed**

- `console`: prompts on stdin from `/dev/null` (or any non-terminal character device) give their default instead of hanging: `stdin.hasTerminal` says yes for those, so the toolkit now checks that the terminal's modes can be read.
- `cli`: dotenv quoted values end at their quote (a `# comment` may follow) and escapes decode once; a Duration option past the largest Duration is a usage error; `-v=no` inside a short group no longer swallows the next token.
- `fs`: globs take a leading `]` in a class, never match `/` with one, and keep an unmatched `{` literal.
- `html`: `not()` is linear on long sibling lists; XHTML and `<head>`/`<body>`-first pages parse as documents; script data follows the spec's escaped states; table parts inside `<template>` stay there; attribute selectors compare HTML's case-blind values (`type`, `rel`, `lang`, …) case-blind; windows-1252's five unassigned bytes decode as WHATWG maps them; the `<meta charset>` prescan reads attributes and skips comments.
- `http`: resume sends `If-Range` (kept in `<file>.part.tag`), so a file that changed restarts instead of being spliced.
- `tui`: a negative `Bar.tick` is ignored in the status row too. `terminal`: widths follow grapheme clusters (ZWJ sequences, VS16), in Console and Tui alike.
- `archive`: a solid RAR run keeps one dictionary in memory between members, not every byte so far.
- `shell`: `check:` and `timeout:` messages mask tokens, secret headers and URL credentials.
- `console`: a `Console.bar(null)` piped into a `resume: true` download learns the file's length from the response, so it shows `done/total` and a filled bar (skipped and resumed files included).
- `chrome`: `Chrome.launch(profile:)` no longer restores the last session's tabs, so tabs stop piling up across runs; cookies and logins stay.
- `cli`: a handler failure prints the toolkit error's message (not `FormatException: …`/`HttpException: …, uri = …`), and a plain `Exception('…')` without its prefix.
- `json`: an escaped `\*` is a literal key again, not a wildcard.
- `chrome`: `Page.cookies()` sends `name=value` as the browser does; values with `=` or `"` were quoted into an invalid header.
- `shell`: a `timeout:`, a cancelled `filter` or a SIGTERM to the script kills the child's whole process tree, and a timed-out run no longer keeps the script alive.
- `pool`: a worker isolate that dies fails its item instead of hanging `map`/`settle`; `retries:` re-runs Exceptions only; fail-fast ends the other lanes' rate waits.
- `tui`: `exit()` inside `Tui.run` still restores the terminal; a slow bracketed paste never turns into keystrokes; modifiers bind in any order, super is `meta+`, Linux console F1–F5 decode; popup titles lay CJK over two cells.
- `http`: resume checks `Content-Range`; `Http.pool` waits out its members' bench; a server `Retry-After` is capped at 5 minutes.
- `fs`: `file.lock` excludes holders in the same process too.
- `archive`: concatenated gzip (bgzip, `pigz -i`, `cat a.gz b.gz`) unpacks, and a stream cut anywhere inside a member still fails; `.tar.xz` streams out of the decoder (one dictionary of memory, not the whole output). Zip and 7z refuse data over 4 GiB instead of writing it short; `archive()` refuses FIFOs and devices; a damaged tar mode is no mode.
- `console`: a narrow terminal keeps the bar's rate; `Console.table` ignores colour codes and tabs in widths.

**Security**

- `http`: `Http.client(limit:)` (256 MiB by default) caps a body read into memory, so a gzip bomb fails instead of filling the heap; piping to a file has no limit. The `csrf:` header goes only where its cookie would; errors and the `serve` log redact URL credentials and tokens; `cache:` keys entries by credentials, skips `Range`, stores no `set-cookie` and creates its folder 0700; the jar refuses `Domain=co.uk`-style registries and `Secure` cookies over http.
- `archive`: unpacking stages in a 0700 folder with file modes applied before the merge; a target that is a link is resolved first; zip members that share bytes (overlap bombs) and 7z keys asking for more than 2^24 rounds are refused.
- `yaml`: alias bombs (over 1,000,000 values) and nesting over 1,000 levels are a `ContentException`; `json`: `**`, `==` and `hashCode` survive any depth.
- `tui`: the status row and popups drop C1 controls; `cli`: a bad value from an environment variable is never echoed.
- `image`: decode and `resize` are budgeted in decoded bytes (512 MiB: a 16-bit image gets half the pixels of an 8-bit one); `resize` never returns a 0-pixel side.

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

- `html`: deep and long documents parse and query in linear time (20,000 nested divs 4.9 s → 51 ms; `section div div div` on 1,000 nested divs 406 s → 5 ms; 52 real pages × 27 selectors 55.9 s → 0.9 s).
- `fs`: `Dir.list` 483 → 20 ms on 20,000 entries.
- `tui`: a `table` frame costs the screen, not the rows (100k rows 35 → 0.95 ms); two `diff` panes keep their own memo (13.6 → 1.0 ms a frame); full repaints flow through box drawing and CJK (a 200x60 `─` frame 110 KB → 12 KB). Markdown breaks over-long words, keeps `(…)` in link URLs and nests `***x***`.
- `archive`: WinZip AES key derivation 5.5 → 2.0 ms per member (in-house HMAC-SHA1 with the pad states hashed once).
- `html`: an in-house HTML5 parser and selector engine replace package:html and csslib: startup ~770 → ~235 ms, chrome ~1750 → ~1300 ms; parsing and queries never recurse, so 20,000-deep pages work. A corpus test holds the tree to package:html's on 50 real pages.
- 7z with 20k files 150 → 25 ms; CRC-32 4× (slicing-by-8); an archive handed over in one chunk 538 → 60 ms and −500 MB; `Region.write` of 80k chars 6.7 s → 65 ms; streamed markdown 4×; `$('div').$('a')` on nested roots 144 → 1 ms; `Json.$('key')` 5×; single-byte charsets 3.6×.

**Docs**

- VISION, ARCHITECTURE and PLAN moved to `docs/`; DOGFOOD.md removed; both PROPOSAL rounds executed and removed.

**Breaking**

- `scrape` removed (never released): a loop over `Http` plus `Pool.map` reads as short.
- `Rate` and `Color` keep their fields private (`count`, `per`, `pause`, `onWait`; `code`, `rgb`): construct them, never read them back.
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
