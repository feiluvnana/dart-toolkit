# Changelog

Every release so far is breaking and ships no deprecation shims. Numbers are back-to-back
deltas measured on the same machine; `tool/startup.dart` reproduces the startup ones.

## Unreleased

`crypto` is native only and covers what scripts commonly reach for. `package:crypto` is gone;
`path` is the only dependency.

- **No Dart fallback.** Digests, HMAC, HKDF and PBKDF2 no longer have a pure-Dart twin; without
  the native library they throw `UnsupportedError` like everything else. One implementation per
  primitive, and `crypto` imports nothing third-party.
- **Digests**: SHA-512/256, SHA3-224, SHA3-384, Keccak-256, BLAKE2s, RIPEMD-160 join the ten
  there were; HMAC, PBKDF2 and HKDF work over every cryptographic digest (not BLAKE2/BLAKE3).
  `bytes.hashBytes` is one native call, no streaming handle.
- **Checksums** in the same `Hash` enum: CRC-32, CRC-32C, xxHash64, XXH3; `bytes.crc32`,
  `file.xxh3()`, `checksum(Hash.crc32c)`. `Hash.isChecksum` tells them apart.
- **Passwords** in their standard string forms: `Argon2id`, `Bcrypt`, `Scrypt`, `Pbkdf2` all
  implement `PasswordHasher`; `Password.hash(pw, const Bcrypt())` writes `$2b$…`,
  `Password.verify` reads bcrypt (`$2a$`/`$2b$`/`$2y$`) and PHC Argon2, scrypt and PBKDF2
  strings, so tables other software wrote verify as is. `Scrypt.derive` for raw keys.
  `Pbkdf2`'s and `Hkdf`'s `hash` field is now `digest`; `Pbkdf2(Hash.sha256, 4096)` is positional.
- **Ciphers**: `XChaCha20Poly1305` (24-byte nonce) and `Aes.cbc` (PKCS#7, no tag, for
  `openssl enc` interop; `aad` is refused).
- **Key agreement**: `X25519` and `Ecdh.p256`, both `generate()` / `agree(theirPublicKey)`.
- **Keys as PEM**: `Ed25519.fromPem`, `Ecdsa.fromPem` (PKCS#8 or SEC1), `.pem`, `.publicPem`,
  `publicFromPem`; keys from `openssl genpkey` load and the exported PEMs match `openssl pkey`.
- **RSA** is a full type: `Rsa.generate(bits)`, `Rsa.fromPem`, `publicPem`, `sign` with PKCS#1
  v1.5 or PSS, `verify` with either, `Rsa.encrypt` / `decrypt` with OAEP.
- **`Jwt`**: `sign(claims, key)` chooses HS256/384/512, EdDSA, ES256, RS256/PS256 from the key;
  `verify` checks the signature, `exp` and `nbf` and refuses `alg: none` or an `alg` that does
  not match the key's kind. The HS256 output is byte-for-byte jwt.io's example.
- **`Totp`**: RFC 6238 codes, HOTP, `verify` with a drift window, `uri` for QR enrolment,
  `Key.fromBase32` and `.base32` for the secrets.
- `Crypto.uuid()`; `Native.take` for library-allocated results, which also shortened the
  archive listing binding.

Measured back to back, importing `crypto` costs the same as before within the noise; the
library grew from 2.5 to 3.0 MB and loads lazily in about 15 ms on first use.

## 0.0.4 — dependency-free, native where it counts

Every parser and the HTTP client are in-house, hashing is native, one library per module, and
a widening pass over what scripts reach for. Measured on the same machine as 0.0.3: importing
`html` costs +278 ms over a bare script against +660–720 in 0.0.2, `xml` +252 against +693,
`archive` +190 against +413, `http` +168 against +291; the barrel +221 against +1 250. The one
runtime dependency left is `path`.

### In-house

- **`archive`**: a streaming zip writer and reader over `dart:io`'s native zlib, ZIP64 when
  sizes or counts overflow, directory entries, UTF-8 names. Same throughput as before (the
  old file API already used native zlib), 330 ms less startup. `zipEntries()` lists an archive
  without extracting. Checked against `package:archive` and the system `zip`/`unzip`.
- **`xml`**: an XML parser and an XPath 1.0 subset — axes and abbreviations, `*`, `prefix:*`,
  `text()`, predicates with positions, comparisons, `and`/`or`/`not()`, `contains()`,
  `starts-with()`, `normalize-space()`, `count()`, `last()`, union. `XmlDocument.root`,
  `XmlElement`, `XmlNodes` with `text`, `texts`, `attr()`, `elements`. Checked against
  `package:xml` expression by expression; where the reference departs from XPath 1.0 (`!=` and
  node-set-to-number comparisons) ours follows the spec.
- **`xpath.dart`**: the engine, generic over an `XPathTree`, so **HTML has `$x`** — the browser
  console's name — returning `Nodes` (elements, text, attributes) with `text`, `texts`, `attr()`
  and `elements` to continue with CSS: `doc.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts`.
- **`http`**: `Request`, `Response`, `StreamedResponse`, `Headers`, `Client`, `IoClient` over
  `dart:io`'s `HttpClient`; `ClientException` for transport failures. `Response.text` decodes
  by charset once; `Response.url` is the URL that answered, absolute. `MockClient` lives in
  `package:dart_toolkit/testing.dart`. Breaking: every `http.Response`/`http.Request` in user
  code becomes `Response`/`Request`; `body` is `text`, `bodyBytes` is `bytes`.
- **`hash`** runs on CommonCrypto (macOS) or libcrypto (Linux) through `dart:ffi` — 2–3 GB/s
  against 170 MB/s — and falls back to `package:crypto`. `isNativeHashing` says which.

### Layout

- **One library per module.** `lib/<module>.dart` is the module — doc, imports, `part` list —
  and `lib/src/<module>/*` are its parts. Internals are private instead of hidden by `show`;
  `fetchOk` became the public `Uri.fetch()`. Imports are `package:dart_toolkit/<module>.dart`.
- **Tests: one file per module.** Twenty files became thirteen; the differential tests against
  the replaced packages live in the module they check.

### Added

- Hashing: `Hash` enum (md5, sha1, sha224, sha256, sha384, sha512), `hash(Hash)`, `sha1()`,
  `sha512()` and the rest on `Path`, bytes and strings; `crc32`; `hmac(Hash, key)`. `Crc32` in
  `util`, shared with the zip writer.
- `Path`: `isAbsolute`, `absolute`, `relativeTo`, `withExt`, `withName`, `modified()`,
  `touch()`, `lines()` (streamed), and their sync twins where IO is involved.
- `String.json`, `String.xml`, `String.html` parse a string.
- HTTP: `head`, `put`, `patch`, `delete`; `json:` on every method with a body;
  `Uri.withQuery({...})`; `Uri.send(Request)`.
- **Downloads resume.** A failed or interrupted transfer keeps its `.part`; the next download of
  the same path sends `Range: bytes=N-` and appends on 206, starts over on 200, restarts on 416.
  `resume: false` turns it off. Breaking: the `.part` is no longer deleted on failure.
- `Cli(version:)` answers `--version`. `Iterable.partition`, `Iterable.indexBy`.

### Fixed

- The redirect target a client followed was reported relative; it is resolved.
- After gzip decoding, `content-length` and `content-encoding` no longer describe the body and
  are dropped from the response headers.


### The native library

- **`dart_toolkit_native`**, one Rust `cdylib` under `native/`, prebuilt per platform into
  `native/prebuilt/<os>_<arch>/`, loaded by `native.dart`'s `Native` through `dart:ffi` (a path in
  `DART_TOOLKIT_NATIVE`, next to the executable, or inside the package). The same functions on
  every platform; nothing asked of the user's machine. `make native` builds it; only
  `macos_arm64` is built so far, so other platforms throw `UnsupportedError` from what needs it.
- **`crypto`** on it: digests MD5, SHA-1, SHA-2, SHA-3, BLAKE2b, BLAKE3 (SHA-256 at 2.4 GB/s
  against 168 MB/s in Dart), HMAC, PBKDF2, HKDF, Argon2id, `Password.hash/verify`, `Key`,
  `Crypto.token/equals`, `Aes.gcm` and `ChaCha20Poly1305` with `seal`/`open` and chunked
  `encryptFile`/`decryptFile`, `Ed25519`, `Ecdsa.p256`, `Rsa.verify`, hex and base64url
  helpers. Pure Dart stays for digests, HMAC, HKDF and PBKDF2 when the library is absent.
  Every primitive is checked against RFC and NIST vectors and `openssl`.
- **`fs` archives** on it: `archiveTo`, `extractTo`, `archiveEntries` for zip (AES-256
  passwords), 7z (passwords), rar (read, RAR4 and RAR5, passwords and encrypted headers), tar
  and tar.gz/xz/zst/bz2; `compressTo`/`decompressTo`, `gzipTo`/`gunzipTo` for single streams.
  Permissions and times restored; a traversal check on every entry. The Dart zip writer and
  reader are gone; `zipTo` is `archiveTo('x.zip')`.
- **Names.** `Prompt` folded into `Console` (`Console.ask`, `confirm`, `select`, `secret`);
  `ConsoleIo` is `Io`. `Crc32` left `core`; `crc32` stays on bytes, strings and paths.
- **Housekeeping.** `Makefile` for check, test, native and release; `.gitignore` for the Rust
  build tree and the binaries, `.pubignore` letting the binaries into the package;
  `tool/check_deps.dart` removed (the pubspec is the budget now); timing assertions removed from
  the tests, which are `make bench`'s job; `CONVENTIONS.md` rewritten around the two things the
  package optimises for.

- **One import.** With every parser and the client in-house, `dart_toolkit.dart` is within
  70 ms of the five module imports a scraper listed by hand, so programs import it; the module
  files stay for a program that wants less, and `check_deps` no longer forbids the barrel.
- **Nine modules.** `util` folded into `core`; `archive` into `fs` (zip is in-house, the
  compression the SDK's); `hash` is `crypto`; `html`, `xml` and `xpath` joined JSON, YAML, TOML
  and INI in `formats`, with the `http` bridges (`res.html`, `url.xml()`) in `http`;
  `testing.dart` is gone — the handler-backed `Client` is `test/mock_client.dart`. Imports:
  `package:dart_toolkit/{core,collection,formats,async,cli,fs,crypto,process,http}.dart`.
  `Io.table`, `width`, `truncate` and `stripAnsi` live in `core` so `Table.show()` and
  `Console.table` share one renderer without `cli` importing the parsers. `ShellResult.json`
  is gone: `run(cmd).text` then `.json`, so a shell script does not compile the parsers either.
  Three pairs over bare: `cli` +30 ms, `process` +100, `http` +240, `formats` +120.

- **`collection` is a query type, not a set of extensions.** Every extension on `Iterable`,
  `List` and `Map` is gone. `items.sequence` and `map.sequence` give a `Sequence<T>` — lazy, still an
  `Iterable`, with the SDK's `where`/`map`/`take`… returning `Sequence` so the chain continues, and
  LINQ's and Kotlin's vocabulary on top: `distinct`, `distinctBy`, `chunk`, `windowed`,
  `pairwise`, `zip`, `cartesian`, `interleave`, `scan`, `takeLast`, `skipLast`, `reversed`,
  `shuffled`, `whereNot`, `indexed`; `sorted`/`sortedBy` returning `Sorted` with `thenBy` and
  `thenWith`; `union`, `intersect`, `except` keeping order; `innerJoin`, `leftJoin`, `groupJoin`
  as hash joins; `groupBy` and `countBy` as `(key, value)` records with `mapValues`, `mapKeys`,
  `inverted`, `sortedByKey`, `sortedByValue`, `toMap([merge])`, `unzip`; `indexBy`,
  `partition`, `sumBy`, `averageBy`, `count`, `minBy`, `maxBy`, `minMax`, `none`;
  `Sequence.range`. A group is a `Sequence` with a `key`, so `groupBy(…).expand((g) => g.take(2))`
  reads on. Typed where the type allows it: `sum`, `average` are getters on a `Sequence<num>`,
  `sorted`, `sortedDescending`, `min`, `max` on a `Sequence` of `Comparable`s — no cast, no
  runtime surprise; `sortedWith` takes a comparator for the rest.
- **`Table`**: rows of named columns from `Table.rows`, `Table.records`, `Table.csv`,
  `json.table`, `doc.$('table').table`; `where`, `orderBy`/`thenBy`, `select`, `rename`,
  `derive`, `drop`, `distinct`, `take`, `skip`, `join`/`leftJoin`, `groupBy` with `count`,
  `sum`, `avg`, `min`, `max`, `agg`, `aggWith`, `pivot`; `t['column']` for a column, `numbers`,
  `texts`; typed reads on rows (`number`, `get<T>`, `text`, with `'1,200'` counting as 1200)
  that throw naming the column and row when a cell does not convert (`numberOrNull`,
  `getOrNull` for the quiet form); a wrong column name anywhere is an `ArgumentError` that
  lists the columns; out as `toCsv`, `saveCsv`, `toJson`, `show()`.
- **`formats.dart`**: YAML (block and flow, `|` and `>`, anchors, several documents), TOML 1.0
  (tables, arrays of tables, dotted keys, all four string kinds, inline tables) and INI decode
  to `JsonDocument` — `text.yaml`, `text.toml`, `text.ini` — so JSONPath and `to<T>()` serve
  every configuration file; `doc.toYaml()` writes YAML back. In-house, dependency-free; YAML is
  checked against `package:yaml` (a dev dependency) on a pubspec- and workflow-shaped document.
- **`Table` formats**: `Table.tsv`, `Table.ndjson`, `toTsv`, `toNdjson`, `toMarkdown`
  (numbers right-aligned) beside CSV.
- **keybox takes no options.** It downloads every format and zips the result; `Cli` stays only
  as the lifecycle (`--help`, `--version`, `ctx.cancel`).
- **No CI.** The GitHub workflow is gone; `tool/check_deps.dart`, `dart analyze` and `dart test`
  are run by hand before a release.

## 0.0.3 — brevity and speed

An audit that read every public member, then probed the engine with mock clients. Ten defects
reproduced and fixed, the API renamed to one set of rules, five additions judged by what they
delete from `bin/keybox.dart` (stage 2 went from 38 lines to 27 and now downloads FLAC), and
the two largest startup costs removed.

### Speed

- **`html` is in-house.** A tag-soup parser and a CSS selector engine replace `package:html`
  and `csslib`, which cost about 580 ms of front-end work per `dart run` — the whole startup
  cost of a scraper. Importing `html` now costs +230–280 ms over a bare script against +660–720
  before, three pairs each; what is left is `http`. Parsing is 2–4× faster too (a 1.1 MB page:
  16 ms against 40). Checked
  against the old parser on three real pages in `test/html_differential_test.dart`, selector by
  selector. Intended differences: `<noscript>` content is parsed as markup, `:empty` follows the
  spec, `:nth-child` works.
- **Executables run through pub's snapshot.** `dart run dart_toolkit:keybox` starts in 350–420 ms
  against 1 330–1 480 ms for `dart run bin/keybox.dart`, and picks up edits. The README and the
  examples say so.
- `String.match` walks its matches once (462 → 231 ms per 200 000). `Ansi.enabled` asks the
  terminal once instead of per styled string (65 → 11 ms per 200 000). `run` inherits the
  environment untouched when nothing overrides it.

### Brevity

- **`$` returns `Elements`**, a `List<Element>` whose `text`, `attr()`, `lines` and `$()` act on
  the first match: `doc.$('a').attr('href')` for `doc.$('a').first.attr('href')`. An empty match
  answers `null` to `attr` and throws a `StateError` naming the problem to the others.
- **`ctx.cancel`** on `CliContext`: a `CancelToken` that `Cli.run` cancels on SIGINT, SIGTERM,
  `die` and when the action ends. Scripts stop declaring their own.
- **`[a, b].merge()`** on `Iterable<Stream<T>>` runs its sources at the same time — what
  `yield*` after `yield*` looks like it does and does not.
- **`.show()`** on `Stream<BatchProgress>` renders a `ConsoleMultiProgress` and returns the last
  event: one line for the five that built the widget, looped and closed it.
- **`follow` returns `bool`**: `false` when the target was dropped as visited, out of scope, too
  deep or not http. `ScrapeSummary.dropped` counts them.
- **`res.json`, `res.html`, `res.xml` are getters**, as `ShellResult.json` already was.
  `String.html` parses a string.

### Names

One set of rules, now in CONVENTIONS.md: read-only booleans are `is*`; the async form is bare and
the sync twin ends in `Sync`; a pure function of the receiver is a getter; one word per idea.

| was | is |
|---|---|
| `Response.ok`, `ShellResult.ok`, `Future<ShellResult>.ok` | `isOk` |
| `Io.redirected`, `CliOption.required`, `Logger.enabled()` | `isRedirected`, `isRequired`, `isEnabled()` |
| `sortedBy(desc:)` | `sortedBy(descending:)` |
| `Either.tryCatch` (sync), `tryCatchAsync` | `tryCatchSync`, `tryCatch` |
| `Path.sanitized()`, `Duration.humanize()` | `sanitized`, `humanized` |
| `HandlerFailed`, `BadStatus` | `HookFailed`, `StatusFailed` |
| `InitContext.maxPages`, `maxDepth` | `pages`, `depth` |
| `Env.clear()` | `Env.reset()` |
| `Console.spin(successMessage:, failMessage:)` | `spin(done:, failed:)` |
| `Path.replaceInFile` | `replaceText` |
| `Stream.chunkTime` | `chunkEvery` |
| `HtmlDocument.document` | gone — the document is the tree; `root`, `head`, `body`, `outerHtml` |

Usage errors are a `UsageException`; `Cli.run` catches only that, so an `ArgumentError` thrown by
the action is no longer reported as "Run --help for usage".

### Fixed

- `run(cmd, input:)` deadlocked when the child echoed more than a pipe holds: stdin was fed
  before stdout was read.
- The command splitter escaped inside single quotes and escaped everything inside double
  quotes; it now reads as a POSIX shell does.
- A hook that called `stop()` and then threw hung the stream.
- A second `follow` of a URL already followed was dropped silently; keybox `-f all` never
  fetched FLAC.
- `/p#a`, `/p#b` and `/p` were three fetches; fragments are stripped.
- A seed at `a.com` dropped every `www.a.com` link; the default scope ignores a leading `www.`.
- A redirect to another host carried `authorization` and `cookie` with it.
- Leaving a `downloadAll` loop early left the in-flight `.part` file on disk.
- A non-2xx download never closed its body; the connection was held until GC.
- Exit hooks did not run when the action threw, and the signal watch kept the process alive.
- `app --help | head` died with an unhandled `Broken pipe`.
- `Retry-After` as an HTTP date fell through to the backoff; a second 429 could shorten a
  longer pause.

## 0.0.2 — three audits

Surface, call sites, then measurements. Names settled to one per operation and fifteen aliases
went; `parallelize` became the one concurrency primitive returning `List<Either>`; `CliOption`
and `DownloadProgress` became sealed types; implementation moved under `lib/src/` with eleven
public libraries, one per module, each with a third-party budget enforced by
`tool/check_deps.dart`. `rxdart` and the XPath-for-HTML package were dropped (the stream
operators are in-house; HTML XPath was 145× slower than CSS). Hashing, archiving and downloads
stream instead of holding the file (888 → 266 MB on a 512 MB file). `HtmlDocument` and
`XmlDocument` left `core`, then the format bridges left `http`, so a JSON client stopped
compiling two parsers (about a second per `dart run`). `Http.session` owns the client, timeout
and default headers. `scrape` became a chain of five hooks with every setting on `onInit`'s
context and every failure a `Left`. `Cli.run` owns the lifecycle; `ctx.option` and `ctx.number`
are non-null when a default or `required` guarantees a value.

## 0.0.1

Initial release: shell and subprocess automation, `Path`, `Env`, concurrency helpers, `Either`
and the JSON/HTML/XML documents, HTTP extensions and a scraping pipeline, and the CLI, console
and prompt toolkit.
