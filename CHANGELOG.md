# Changelog

## Unreleased

### A client is the only thing that touches the network, so anything can be one

- **`BrowserClient`, a second built-in client, renders every page in Chrome.** It speaks the
  DevTools protocol over a `dart:io` websocket — no third-party package and no Chromium
  download: `BrowserClient.launch()` runs the Chrome already installed, `attach(port:)` joins
  one already running. The rendered DOM arrives as `Response.bytes`, so `res.html`, `$`, `$x`,
  the scrape engine's scope, dedupe and redirects all work over it with nothing changed but the
  one word in `Http.session(client:)`.
  - Only a GET without a `range` is rendered; a POST, a resumable download and an asset go to
    the plain client underneath, carrying the browser's cookies for that host.
  - `tabs:` bounds how many pages render at once — the crawl's `concurrency` is the engine's
    budget, this is the browser's.
  - Added: `BrowserClient`, `BrowserWait`.
- **`RequestKey<T>`: a typed directive a client may honour.** The fields of `Request` describe
  HTTP and nothing else; a client that is not HTTP is told the rest with a key, and **ignores
  every key it does not know** — which is what lets one crawl run over either client.
  `request[BrowserClient.waitFor] = '.item'`, read back as `waitFor(request)`.
  - Added: `RequestKey`, `Request.operator []=`; `BrowserClient.waitFor`, `.waitUntil`,
    `.script`, `.direct`.
- **`Client.close` returns `FutureOr<void>`** and `Http.session` awaits it, so an
  implementation that shuts down over a socket is waited for rather than raced. Breaking for
  implementors only in that the signature widened; a `void close()` still satisfies it.
- **`test/client_conformance.dart` checks an implementation against its own server.** The
  promises the rest of the module relies on, written down and executable: a non-2xx is a
  response and not a throw, `url` is the URL that answered, a body arrives as a stream, an
  unknown directive is ignored, `close` is idempotent. Both built-in clients pass it.

## 0.0.2

A conciseness pass over the whole API. Nothing was removed that cannot still be done; four
places where a caller had to say the same thing twice are gone, and about sixty public members
went with them. Every change below is breaking.

### A name is written once

- **CLI options are values, not strings.** `Flag('verbose')`, `Opt.text`, `Opt.number`,
  `Opt.among(name, values)` and `Opt.by(name, parse)` declare an option; `.or(v)` and
  `.required()` guarantee it; `ctx(option)` reads it at the option's own type.
  `Opt.among('algo', Hash.values)` takes the enum itself, so nothing rebuilds it from a string
  with `firstWhere` afterwards. `Opt.by` parses anything — a `DateTime`, a `Uri` — which the
  old four fixed kinds could not.
  - Removed: `CliContext.flag`, `.option`, `.number`, `.optionOrNull`, `.numberOrNull`, `.values`;
    `CliCommand.option`, `.flag`, `.choice`, `.number`; `CliFlag`, `CliValue`, `CliNumber`,
    `CliChoice`.
  - Added: `Flag`, `Opt`, `OptionalOpt.or`, `OptionalOpt.required`, `CliContext.call`,
    `CliContext.given`, and an `options:` argument on `Cli`, `CliCommand` and `command()`.
- **`Client` left eighteen signatures.** `Http.session` is where a program names its client;
  `get`, `post`, `fetch`, `json`, `html`, `xml`, `send`, `download` and `downloadAll` no longer
  take `client:`. Per-request `headers:` stays. A batch download publishes its own client to
  the transfers inside it, so connection reuse is unchanged.

### One shape for one and for many

- **`Path.download` reports `BatchDownloadProgress`**, the same events `downloadAll` reports,
  with a total of 1. `show()` now renders a single download directly; the per-file state is
  `progress.current`. This deletes the one-entry-map workaround `bin/tk.dart` had to write.

### One markup tree

- **HTML and XML share `Node`, `Element`, `Text`, `Attribute`, `Nodes` and `Elements`.**
  `XmlNode`, `XmlElement`, `XmlText`, `XmlAttribute` and `XmlNodes` are gone; `XmlDocument` and
  `HtmlDocument` remain, holding the same tree. `Element.syntax` decides how an element
  serialises.
- **`$` is CSS and `$x` is XPath, on both.** `XmlDocument.$` was XPath and is now CSS, matching
  XML names as written rather than folded; XPath on XML moves to `$x`. XML gains CSS selectors;
  a prefixed name such as `media:content` is not a CSS identifier and needs `$x`.
- **`XPathTree` is gone.** It existed so one engine could walk two trees; with one tree the
  engine walks `Node` directly, and the type parameter is gone from all of `xpath.dart`.
- Renamed on nodes: `outerHtml`/`outerXml` to `markup`, `innerHtml`/`innerXml` to `innerMarkup`.
  `HtmlDocument.outerHtml` and `XmlDocument.outerXml` are unchanged.
- Added: `Elements.texts` and `Nodes.$`, so the two collections answer the same questions;
  `Element.local` and `Element.prefix` now work for HTML too.

### One spelling per operation

- **Digests.** The twenty-one per-algorithm shortcuts (`.md5`, `.sha1`, `.sha256`, `.sha512`,
  `.blake3`, `.crc32`, `.xxh3` on `Path`, `List<int>` and `String`) are removed. `hash(Hash.x)`,
  `hashBytes`, `checksum`, `hmac` and `hmacBytes` are the whole surface, and they cover all
  twenty algorithms rather than five.
- **Tables.** `Io.table` and `Console.table` are removed; `Table.show()` is the only renderer,
  and `Table.cells(headers, rows)` takes the shape those two took.
- **ANSI.** `Ansi` is removed. `Ansi.enabled` is `Io.color` and `Ansi.strip` was `Io.stripAnsi`;
  `Io` now answers every question about the active sink. The string styling getters (`.red`,
  `.bold`, `.stripped`) are unchanged.
- Removed as pure compositions: `Path.gzipTo`, `Path.gunzipTo` (use `compressTo`/`decompressTo`),
  `Table.tsv`, `Table.toTsv` (use `csv`/`toCsv` with `separator: '\t'`).

### Internal

- `scrape`'s `follow` parameters are spelled once, in a `_Plan`, instead of once per hop
  between the hook and the frontier. No API change.

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
