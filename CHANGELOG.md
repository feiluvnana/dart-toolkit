# Changelog

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
