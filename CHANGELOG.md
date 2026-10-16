# Changelog

## Unreleased

**Fixed**

- `fs`: two `file.lock(...)` calls in one process are granted in call order; the second one no longer wins while the first creates the lock's folder.
- `fs`: unawaited `file.write(...)` / `> file` calls to one path land in call order, so the last one wins (they could finish in any order and keep a stale state). medialoader drops its own save chain.
- `http`: a body with no length (SSE, NDJSON) reaches `lines()`/`stream()` as it arrives instead of after 64 KB or its end, and a paused consumer pauses the socket instead of buffering the rest of the body in memory.
- `core`: a `Rate` shared by a `Pool` and an `Http.client` never lets more than its count start in one window (a start that waited could drop a live one from the window), and a start cancelled by a closed client or a failed `Pool.map` no longer counts.
- `yaml`: a one-line flow document (minified JSON read as YAML) parses in linear time; 230 KB took 7 s.
- `html`: `form()` reads the controls a browser posts: a form wrapped in a table (whose controls the parser places after it) and `form="id"` controls elsewhere in the page no longer give `fields: {}`.

**Changed**

- `http`: `client.copy(...)` takes only `headers:`, `timeout:`, `retries:`, `rate:` and `proxy:`; another base, jar or `check:` is a new `Http.client`.

**Removed**

- `http`: `Http.serve` and `Server`/`Request`/`Reply`; the library is not a server. An OAuth loopback redirect is a few lines of `dart:io` `HttpServer` (docs/VISION.md §4.2).
- `http`: `Http.client(connections:, idle:, insecure:)` and the same on `copy`: a client keeps at most 6 sockets per host and releases them 100 ms after its last request (`Pool(limit:)` caps concurrency); a self-signed host is trusted through `SecurityContext.defaultContext.setTrustedCertificates`.
- `http`: `Http.client(cache:, ttl:)` and `copy(cache:, ttl:)`, the GET disk cache; a scraper under development keeps its pages with `get(u) > Fs.file(f)`.

## 0.1.0

Scripts without chores: the plumbing a gallery-dl-class downloader wrote by hand is now the
library's, and `&` works as well inside a Tui as in a terminal.

**Added**

- `tui`: `Region.bars()` draws every live `Console.bar` (and every future watched with one) as a row of its own, and `Region.log(only:, color:, failures:)` draws the run's `Console.log` lines with their times. A screen that draws them takes them out of the status row, so a script watches work the same way with and without a Tui.
- `console`: `Console.log(line, failed: true)` marks a failure (`✗`, bold in a Tui log); `Console.logged()` is the run's log as a `Reader`: `await (Console.logged() > Fs.file('run.log'))`.
- `http`: `Feed(page, cursor:)` walks a newest-first listing page by page: `run((page) {…}, all:)` hands each page as a `FeedPage` (`items()`, `add(work)`, `follow(cursor)`, `stop()`), fetches the next page while a page's work runs, visits each cursor once, and keeps a cursor file that moves only past finished work, so an interrupted run lists what is new, then continues where it stopped.
- `http`: `Http.client(browser: .page | .api)` sends what a desktop browser sends for a page or for its script's API call; `login: [paths]` turns a redirect to a sign-in page into a `SessionException` (a `ToolkitException`, with the `url` it landed on).
- `json`: `Json.texts()` (every item's text, as `Elements.texts()`); `value<DateTime>()` (and `or`, `asList`) reads ISO text and Unix seconds or milliseconds.
- `image`/`video`: `Compression.text()` says what compressing did (`1.6 MB (compressed from 2.7 MB, -39%)`, `kept: …`).

**Changed**

- `pool`: a held `Pool(limit:).run(job)` returns a `Task`, so `lanes.run(job) & bar` watches it, waiting for its lane included.
- `core`: a probe that watches work in two units (a download, then its encode) shows the latest unit's runs instead of adding bytes and microseconds; a failed run without a total no longer leaves the sum unknown.
- `image`/`video`: `KeptReason.text` is a method, `text()`.
- medialoader: `queue.dart`, its `Transfer`, the transfers pane and the log plumbing are gone (Console's bars and log in `bars()`/`log()` panes, `Pool.run` lanes); the platforms use `browser:`, `login:`, `Json.texts()`, epoch dates and `Feed.follow` (Facebook's photo walk). 2,272 → 2,125 lines; keybox 204 → 195.

## 0.0.6

**Added**

- `core`: progress is one pattern, `reader | pipe & probe > writer`. `&` attaches a `Probe` to a reader, a `Task` or any future (`Watch`), and the probe shows the whole run: a flow's source bytes against its length (learned from `Origin.size()` or a file's stat, never passed; still right after gzip or a filter), the work a source or writer reports (an encode in media time, a 7z built or extracted by 7-Zip), a `Task`'s count, or a spinner. Counted once at the root, so probes cost nothing per chunk; one probe watching many runs sums them. `Meter` (`done` `total` `rate`) is a probe to draw by hand; `Task<T>` is a future that counts; `Probe` takes one member, `update(done, total)`.
- Long work returns a `Task`: `Pool.map`/`settle` (items), `File`/`Dir`/`Link` `copy`/`move` (bytes; watched, a folder copy streams so it can count), `Dir.list` (entries), `Video.compress` (media time), `Shell.run` (a spinner). `Video.encode` and `Archive.archive` report their work to a probe on their reader; `page.download` returns when the browser names the file and its `Download` streams with the browser's progress. First-use downloads of ffmpeg, 7-Zip and Chrome for Testing show a live line on stderr (the status row inside a `Tui.run`).
- `shell`: `Shell.read(cmd)`, a program's stdout as a live `Reader` (stderr passes through; a non-zero exit fails it); `Output.check()`.
- `console`: `Console.out()` and `Console.input()` (stdout as a `Writer`, stdin as a `Reader`); `timeout:` on `confirm`, `choose` and `key`, and `or:` on `key`.
- `core`: `Origin.size()`; `reader.cookies(or:)`. `csv`: `reader.csv(or:)`. `chrome`: `Capture.name()`. `video`: `Video.format()`.
- `http`: a `Map` in `query:` is sent as JSON (GraphQL's `variables`/`features`), so `Json.encode(…)` wrappers go.
- `shell`: `ExitException` (a `ProcessException` and a `ToolkitException`) for a program that exits non-zero under `check:` or as a filter; one that cannot start stays a plain `ProcessException`.
- `core`: `PasswordException` (a `ContentException`) for a missing or wrong archive password; `fs`: `LockedException` when `File.lock` is held elsewhere.
- `image`/`video`: `compress` returns `Compressed(before, after)` or `Kept(reason)` (`KeptReason.unknown`, `.lossy`, `.notSmaller`, with `text`); `Video.compress` is a `Task`.
- `image`/`tui`: `Pixels` is exported (what `image.pixels()` returns and `Region.picture` takes).
- `image`: now runs on ffmpeg (package:image is gone; import startup 892 → ~330 ms). Reads HEIC (tile grids included) and AVIF, writes WebP and AVIF; `image()` on a file reads it in place, other readers go to a temp file once, never memory. `resize`/`crop` record steps and `encode` runs them in one ffmpeg call. `Image.compress(path, quality:)` re-encodes in the same format and replaces the file only when ≥ 5% smaller (returns `(before, after)` or null); animated, CMYK and HEIC files are left alone, JPEG EXIF/ICC survive. `image.pixels(width:)` for `Region.picture`; `format()`.
- `video`: `Video.open(URL, audio:, headers:)` (HLS/DASH, a separate audio source; a file is `Fs.file(path).video()`); `encode` copies streams when no quality/size/codec is asked (remux), `codec:` (`h264` `h265` `av1` `vp9`), `start:`/`end:`, and a probe on it sees the encode; audio-only `m4a`/`mp3`/`opus`; `frame(at:)` → `Image`; `format()` `codec()` `audioCodec()` `bitrate()`; `Video.compress(path, quality:, codec:)`.
- ffmpeg/ffprobe 9.0.2: a PATH copy is used when it has the encoders a call needs, else a static build pinned by sha256 is downloaded once into the user cache (native arm64 on Apple silicon), one process at a time; encodes share a limit of half the cores and run through `shell`, so Ctrl-C ends them.
- `core`: `bytes.size()` (`12.1 MB`).
- `http`: `Body.multipart(fields, files: {name: reader})` (files stream); `Rate(perHost: true)`; ETag/Last-Modified revalidation in `cache:`; `socks5://`/`socks5h://` proxies; `client.sent()`; `reader.cookies(or:)`, `Cookies.agent()`, `Cookies(agent:)`; `Http.serve(max:)` (413 over 64 MB).
- `fs`: `Dir.size({match})` → `(files, bytes)`, skipping partial and temp files; `File.touch([time])`.
- `pool`: `Pool(limit:)` with `run(job)`: shared FIFO lanes.
- `shell`: `Shell.run(cancel:)`.
- `chrome`: `page.cookies(all: true)`; `run` takes a function source; Chrome for Testing downloads with resume (chrome-headless-shell for headless runs); `connect` takes an `http://` URL.
- `console`: `Console.ask(timeout:)` returns `or` and stops its reader, so the script can exit.
- `tui`: `Region.write(inline: true)` spans measured in cells; `Region.bar(meter)` draws a `Meter` in its unit, with its rate.
- `cli`: `Opt(min:, max:)` (usage shows `[1-100]`); `Command(version:)` answers `--version` at any depth.
- `html`: `:scope` and a leading `>`/`+`/`~` relative to the receiver (`ul.$('> li')`); `Element`/`Elements.markup()`; `srcset`/`data-srcset`/`<meta content>` paths resolve against the base.
- `json`: negative indexes (`items.-1`); `asList<Json>()`/`asMap<Json>()` wrap their values; `Reader.ndjson()`.
- `csv`: `Reader.rows()` streams records.
- `hash`: `Hasher.base64()`/`bytes()`; `key:` (HMAC) on every algorithm.
- `archive`: symlinks are kept when they resolve inside `dir` (hardlinks land as copies; others fail naming `name -> target`), and `archive` stores links that point inside `dir`; zip64; the zip writer streams (a 140 MB file: 769 → 290 MiB peak); bzip2, zstd, lz4, lzip, .Z, .lzma, cab, ar and xar are named in the error; zip/7z/RAR decode on their own isolate and `.tar.xz` streams through one, so Ctrl-C and UIs stay live.
- `archive`: 7-Zip 26.04 (pinned, downloaded once like ffmpeg) writes 7z with LZMA2 on every core, and reads what Dart should not hold or cannot decode: 7z/RAR over 32 MiB (no whole archive or solid folder in memory), BCJ2/RAR 1.5/VM-filter archives, `.tar.bz2`, `.tar.zst`, `.tar.Z`, `.lzma`, cab, ar (`.deb`) and xar (`.pkg`); its output is sandbox-checked and merged exactly as Dart's. Windows gets the 7z-only `7zr.exe`.
- `archive`: `.tar.xz` with x86, ARM64 and delta filters (as `xz --x86` and 7-Zip's own releases write them).

**Changed**

- Removed, one way each instead: `Pipe.tap` and `Speed` (→ `Meter`), `Console.spin` (→ `work & Console.bar('label')`), `Pool.map/settle(onDone:)` and `Video.encode(onProgress:)` (→ `& probe`), `Shell.run(live:, onLine:)` (→ `Shell.read`), `Shell.run(check:)` (→ `.check()`), `Cookies.load` (→ `reader.cookies(or:)`). A `Bar` is a `Probe`, no longer a `Pipe`: `reader & bar`, not `reader | bar`.
- `console`: `Console.bar(label, {total, keep})`: the label is the one positional and the total is learned from the run; `Console.key(prompt)` and `choose(question, items, label)` take their text and item function positionally.
- Rates (`Console.bar`, `Meter`, the status row) are the speed now: 100 ms steps smoothed with a 1 s time constant, not a 5 s average.
- `html`: `Element(s).html()` is `markup()`; `html()` only parses. `video`: `audio()` is `audioCodec()`. `fs`: `lock(wait:)` is `lock(timeout:)`.
- `chrome`: `BrowserException` is a `ToolkitException` (an `Exception`), no longer a `StateError`.
- `http`: the byte cap is `max:` (`Http.client`, `copy`, `Http.serve`); `limit:` always means how many at once, as in `Pool`. A `copy()` counts in its parent's `sent()` and closes with it.
- `http`: `Body.multipart(fields, files: {name: reader})` replaces the mixed map.
- `chrome`: `Page.run(js)` returns `Json` (`.or('')`, `.value<int>()`, `.asList<T>()`) and runs its source once (a function result ran twice). `open(block:)` takes a `Set<Resource>` (`{.image, .font}`). Chrome for Testing is pinned to 155.0.8059.84 and checked by sha256 (downloaded again once into a versioned folder).
- `console`: `Console.ask` returns `String`: an empty line, a closed stdin, a cancelled popup or a timeout give `or` (`''` by default).
- `tui`: `Region.bar` takes a `Meter` instead of counts and `since:`. A run without a terminal says to use `Console`; one whose terminal input closes ends with an error instead of hanging.
- `pool`: `retries:` no longer re-runs bad data (`ContentException`), TLS failures or HTTP status errors.
- `cli`: a failing handler prints every line of its error.
- no `HOME` (or `LOCALAPPDATA`) is an error for the native tools and media spooling, never a shared temp folder.
- `image`: `Image.decode` is async; `Image` no longer implements the pixel interface (use `pixels()`); `ImageFormat` gains `avif`, `heic` (read only). JPEG `quality` is calibrated to the old scale by SSIM.
- `video`: `width()`/`height()` are null for audio only; size is as displayed (rotation applied); `VideoFormat.avi` is read only; `encode(quality:)` defaults to a stream copy.
- `http`: requests send a desktop Chrome User-Agent by default (or the jar's `agent()`); the set-cookie parser is in-house and lenient, with a small public-suffix list; `cache:` streams bodies to disk; cookie files read and write a `user-agent:` line.
- `pool`: `Pool` is a `final class` you can hold.
- `fs`: atomic writes fsync the file before the rename.
- `chrome`: an in-house DevTools client over `dart:io` WebSocket replaces puppeteer (import startup +1352 → +307 ms); a cached or installed Chrome is used before downloading; `scroll(to:, timeout:)`; downloads use `allowAndName`; a script throwing in `run` is a `BrowserException`.
- `console`/`tui`: one key-hold rule: a lone ESC is Escape after 50 ms (was 30 ms in the Tui, 150 ms in Console), a split sequence waits up to 1 s; `Region.bar` keeps to one row; fenced code renders plain in the accent colour.
- `archive`: `ArchiveFormat.sevenZip` is `ArchiveFormat.sevenzip`.
- `json`: `|` separates whole paths (`$('a.b|c')` is `a.b`, else `c`); wildcards flatten; `or<String>` reads any scalar as text; `Reader.json` decodes bytes directly (10–30% faster).
- `html`: re-exports json's names; `form().fields` is `Map<String, List<String>>`.
- `yaml`: an in-house reader replaces package:yaml (import startup +225 → +80 ms, ~3× faster parse); `Yaml.parse` takes no `from:`.
- `archive`: the LZMA2 window keeps a quarter of the dictionary as slack.
- ffmpeg and 7-Zip download in an isolate spawned by URI, so `image`, `video` and `archive` never compile http at startup; a compiled exe asks for the tool on PATH instead.
- `cli`: a long `values:` list shows as `<value>` with the choices after the help, so one option no longer pushes every description off the screen; a `Multi` defaulting to every value shows `[default: all]`.

**Security**

- `archive`: 7z and RAR decode under one budget: 1 GiB of output (past it the archive goes to 7-Zip, which streams to disk), 4M members, 2^26 key rounds; a 7z encoded header over 64 MiB, a second RAR5 encryption record on a member, more than 8192 RAR5 filters (or one over 4 MiB) are refused, and a PPMd model over 256 MiB goes to 7-Zip. Archive passwords reach 7-Zip on stdin, never its argv.
- `http`: secret client `headers:` (`authorization`, `cookie`, names with token/key/auth …) go only to the `base:` origin, or the first request's without one. The `cache:` key covers every secret header and a hit must match its stored request. A loopback `Http.serve` answers only loopback `Host` names (421 otherwise: DNS rebinding). SOCKS fields over 255 bytes are refused; proxy passwords stay out of errors.
- `video`: `Video.open(headers:)` goes through a loopback proxy scoped to the source's origin: the headers never sit in ffmpeg's argv or reach a CDN or redirect elsewhere; tool errors mask URL tokens.
- `chrome`: a launched Chrome talks CDP over `--remote-debugging-pipe` (no TCP port; Windows keeps the port); a proxy password is refused instead of landing in argv.
- media spooling lives in the user cache at 0700, no longer a shared `/tmp/dart_toolkit_media`; concurrent Chrome downloads share a lock and a fresh temp folder.
- `tui`: markdown links become OSC 8 only for `http`, `https` and `mailto`.
- `html`: unclosed formatting tags parse in linear time (120,000 of them: 3 s → 90 ms).

**Fixed**

- `http`: a SOCKS proxy that never answers times out and no longer keeps the script alive; a dropped download keeps its `.part`, a failing pipe deletes it; a reply that fails after the handler is logged, and unencodable JSON is a 500.
- `shell`: an `onLine` that throws fails the run and kills the child tree (it crashed the script); a reaped child's pid is never signalled; a 7-Zip `-p…` password is masked in errors.
- `chrome`: a fast download's end is no longer missed (a 30 s timeout); `connect` times out with a `BrowserException`, and a launch failure carries Chrome's stderr; a send during `close()` fails its future instead of escaping.
- `archive`: a source that fails mid-stream (a dropped connection) keeps its error instead of "corrupt archive"; a crashed decoder isolate is a `StateError`; Windows device names cover `COM0`/`LPT0`, superscripts, `CONIN$`/`CONOUT$` and `nul .txt`.
- `fs`: a destination link that cannot be removed fails the copy instead of writing through it; an atomic write reports the target, not its hidden temp; a failed `cp -pPR` reports its reason.
- `pool`: an empty batch with `limit: items.length` returns nothing instead of throwing.
- `yaml`: `\x`/`\u` escapes take exactly their hex digits; surrogates must pair.
- `console`: `notify` and `copy` send no escapes under `TERM=dumb`.
- `video`: `sniff` called HEIC/AVIF photos mp4; the whole video was held in memory and copied per call; probing parsed stderr; audio was always re-encoded; the ffmpeg download was x86_64 on Apple silicon, unchecked and raced on first use.
- `http`: the cache never hit when a response set a cookie; a cached gzip answer reported its wire size; `lines()` ignored the charset; `Http.pool` skipped `resume:`; `copy(timeout:)` kept the old connect timeout; pool `copy(proxy:)`; resume made two GETs for a changed file and restarted a complete `.part`; strict cookie parsing dropped browser-accepted cookies; proxy default port, relative URL in the pool abort error, silent https→http redirects, unbounded server bodies.
- `fs`/`shell` docs match the code (`tempDir`/`homeDir`/`scriptDir`, timeout kills the tree, 64 KB of stderr).
- `chrome`: closing a connected browser restores its download behaviour; `download` hears downloads started in iframes; `fill` works on `contenteditable`; a profile keeps session cookies.
- `console`: prompts and `table` erase and repaint the live block instead of being overwritten by it.
- `tui`: a lone UTF-8 lead byte (a split read over SSH) is no longer Escape; the status row keeps combining marks; `✗` is `x` under LANG=C; Ctrl-Z waits for the tty reader before stopping.
- `console`: OSC 777 notifications carry a title and a body.
- `cli`: dotenv values belong to one run, not the process.
- `yaml`: multi-document input read the first document only as documented (it threw); the source URL is redacted in errors.
- `html`: `table()` honours `rowspan`; ld+json scripts with parameters are read; an empty form `action` posts to the document URL; selector errors name the selector once and engine bugs are no longer reported as bad selectors; `*-of-type` and `:nth-child(… of S)` are cached per parent (1–2.8 s → 5–21 ms on 20k siblings).
- `csv`: a blank line is no longer a record.
- `archive`: mtimes are kept for zip, tar, 7z and RAR, and the 7z writer stores them; a non-tar `.xz` no longer says "gzip data"; the AppleDouble check no longer depends on chunk splits; a `.tar.gz` with zero padding unpacks; `dir:` can be a link; the xz index size check.
- `core`: a piped reader no longer reports its source file's path, so `(file | pipe).image()`/`.video()` and uploads read the piped bytes instead of the file.
- `image`/`video`: a stream is spooled to a temp file as it arrives (never held in memory), and the temp file is deleted with the last value that uses it.
- `json`: a `*`/`**` path matching nothing no longer wins over the next `|` path.
- `fs`: `Dir.size` skips the temp files of an encode in flight.

**Removed**

- `core`: `Reader.pipe`/`to` and their mirrors (`|` and `>` are the one spelling).
- `console`: `Console.clear`, the `Console.accent` field and the `Color` re-export (`tui` exports it); `tui`: `App.state()`.
- `image`/`video`: `Image.decode`/`Video.decode` (`Reader.of(bytes).image()`/`.video()`); `hash`: `Hasher.of` and `Hasher.base64` (`base64Encode(h.bytes())`).
- `image`: the isolate thresholds and decode budget (ffmpeg runs in its own process).
- `video`: writing AVI.
- `chrome`: `DownloadFuture.name()`, `src/tabs.dart` and the puppeteer dependency.
- `tui`: the markdown code highlighter (~480 lines of keyword tables).
- `console`: `Bar.setTotal` (use `update(done, total)`).
- `html`: `Element.not` (filter with `Elements.not`).
- the package:yaml dependency.
- `archive`: the 4 GiB / 65,535-member refusals (zip64).
- `archive`: the in-house Deflate-only 7z writer (it made files the size of zip; kept as a test fixture builder).


**medialoader**

- Rewritten on `Image`/`Video.compress`, `Speed`, `Pool(limit:)`, `Dir.size`, `Cookies.load`, `csrf:`, `sent()`, inline Tui spans and `Opt(min:, max:)`: 3,705 → 2,141 lines; Facebook reads the page's embedded JSON instead of ~40 regexes.
- New: single post URLs (`instagram.com/p|reel/…`, `x.com/<user>/status/<id>`), `--since`, `--dry-run`, files dated to their post, failures retried once without a terminal, `--version`.
- Fixed: `r` retried with closed clients after the run; no summary without a terminal; negative speed; partial files counted as had; requests counted twice; the CDN client sent no referer; usage errors and `--reset` showed only in the Tui; Facebook 404/429 hidden, duplicate and re-fetched media, stories downloaded again every month, the photo cursor saved before its files; whole videos read into memory and animated GIFs flattened by compression.
- Removed: the alias options (`--compress-image`, …), folder names as category values, the posts→tweets and flat-layout migrations.
- Categories are one shared set for every platform: `posts` `stories` `highlights` `photos` `videos` `albums` `profiles` (`--category=posts,stories`); each platform offers its own, and a user whose platform has none of the chosen ones is skipped. Folders are named after them; Twitter's `tweets/` is renamed to `posts/` on the next run.
- Restructured so a new platform (TikTok, Bluesky, …) is one file in `platforms/` extending `Platform` plus a line in `platforms.dart`: login from `.<code>.session`, rate-limit waits, error wording, CLI values, `update` and dashboard colours come for free. `job.dart` (a user's download and index), `queue.dart` (downloads and compression), `feed.dart` (newest-first timelines), `run.dart` (a run, `update`'s discovery).
- Fixed: `--reset` deleted every listing cursor, not only the reset categories'; it looked for the folder under the name as typed instead of the resolved one; a tweet whose media did not resolve still wrote its caption; Instagram fetched the first posts page twice per user; a crash inside the dashboard exited 0; with `--since`, the Facebook photos walk kept opening older photos' pages.
- Dashboard: an overall progress row, each user's new files and size beside their name, `f` toggles failures only (the log's header is no longer clickable).
- Fixed: a compressed file's log line showed its downloaded size instead of the size on disk (`2.7 MB (compressed from 2.7 MB, -39%)`).
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
- `tui`: `Region.lines(count, (row, i) {…})`: one-row lines; in a scroll only those in view are drawn (a long log).
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
- instaloader: the dashboard log draws with `lines` (20,000 lines 300 → 1.2 ms a frame), so keys such as `l` (save log) answer at once; `retrying N…` shows while `r` runs.
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
