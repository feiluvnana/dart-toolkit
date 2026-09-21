# Changelog

## 0.0.1

First release. A scripting, automation and web-scraping toolkit for Dart, in ten modules
behind one import, with `path` as its only runtime dependency.

### What is in it

- **`core`** — `Either` for settling failures where the caller decides what they mean, `Env`
  with in-memory overrides and `.env` parsing, the `Io` seam every write goes through, the
  `TaskProgress` interface a producer and a renderer meet on, and duration helpers (`60.s`).
- **`async`** — `parallelize` over an iterable or a stream, bounded and settling every task
  into an `Either`; `retry` with backoff, jitter and a predicate; `CancelToken` that composes
  onto any future or stream; `Mutex` and `Semaphore`; `chunk`, `debounce`, `throttle`,
  `delayBy`, `flatMap`, `merge`.
- **`collection`** — `Sequence`, a lazy query over any `Iterable` or `Map` with LINQ's and
  Kotlin's vocabulary, multi-key sorting, joins and grouping; `Table`, rows of named columns
  from maps, records, JSON, CSV, TSV, NDJSON or an HTML table, with pivots and aggregates.
- **`formats`** — JSON, YAML, TOML and INI decode to one `JsonDocument` with JSONPath, so one
  query language serves all four; HTML with CSS selectors (`$`) and XPath (`$x`); XML with
  XPath. Every parser is the package's own and is checked against the package it replaced,
  on real documents, in the test suite.
- **`fs`** — `Path`, an extension type over `String` that goes anywhere a path string does:
  globbing, streaming reads, atomic-ish writes that create their parents, and zip, 7z, rar,
  tar and gz/xz/zstd/bz2 archives with passwords.
- **`hash`** — sixteen digests and four checksums, HMAC, hex/base64/base32, secure random
  tokens and UUIDs, and a constant-time compare. Files stream, so memory is flat.
- **`http`** — `Request`, `Response` and `Client` over `dart:io`; `Http.session` for one
  client, one timeout and default headers across a whole program; atomic resumable downloads
  with progress; and `url.scrape<T>()`, a crawl as five hooks on a chain and a
  `Stream<Either<ScrapeFailure, T>>`.
- **`cli`** — `Cli` with subcommands and four kinds of option, `Console` (tables, rules,
  spinners, single and multi progress, prompts), levelled `Logger`, ANSI styling, signal
  handling and exit hooks.
- **`process`** — `run` with timeouts and stdin, shell-style pipelines with `pipefail`
  semantics, and `which`.
- **`native`** — the loader for `dart_toolkit_native`, one Rust `cdylib` holding the digests,
  MACs and archive formats. `Native.isAvailable` and `Native.reason` say whether it loaded;
  anything needing it throws `UnsupportedError` naming what and why when it did not.

### What is deliberately not in it

- **Cryptography beyond hashing.** No ciphers, password hashing, key agreement, signatures or
  JWT. This package automates scripts; owning that code means owning its failure modes, which
  are silent and expensive. Hashing, HMAC and the encodings stay, because identifying and
  verifying data is what a script does.
- **A Dart fallback for the native library.** Two implementations of one primitive is two
  places for a bug.
- **Aliases.** One name per operation; when two spellings exist, one is deleted.

### Known limits

- **Only `macos_arm64` is prebuilt.** On every other platform the digests and every archive
  call throw `UnsupportedError`. Cross-compiling the other four targets is `PLAN.md` step 1.
- The HTML parser is tag soup with the implicit closes a scraper meets, not an HTML5 tree
  builder. TOML and YAML cover what scripts use, checked against `package:yaml` and the
  system tools rather than against the specifications' own suites.
- Response bodies decode as UTF-8 or Latin-1; `<meta charset>` is not consulted, so a page in
  another encoding comes back with replacement characters.
- There is no cookie store, so anything behind a login needs the header threaded by hand.

### Conventions

`CONVENTIONS.md` records the rules the API follows — call-site brevity first, speed second —
so that additions do not re-create what the audits behind them found.
