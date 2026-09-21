# Conventions

Two things this package optimises for, in this order: **how little a script has to say** and
**how fast it runs**. Every rule below is one of those two written down after an audit found the
opposite. Coherence, documentation and feature count rank below both.

## Brevity

- **One import.** `package:dart_toolkit/dart_toolkit.dart`. Modules exist for a program that
  measured and wants less.
- **One name per operation.** No aliases, not even deprecated ones. When two spellings exist,
  one is deleted.
- **A conversion is the way in.** `'…'.url`, `.path`, `.json`, `.yaml`, `.html`, `.sequence`,
  `.table`, `60.s`. Nothing is added to `Iterable`, `Map` or `String` beyond those entry points;
  the vocabulary lives on the type they return.
- **A name is written once.** Anything a caller declares and then looks back up is a name
  spelled twice and a typo the compiler cannot see. A CLI option is a value — `Opt.number('top').or(10)`
  — and `ctx(top)` is an `int` because the option says so; `Opt.among('algo', Hash.values)` takes
  the values, so nothing rebuilds an enum from a string. `Table` still keys by column name,
  because a CSV's columns are not known until it is read.
- **Ambient over threaded.** A setting every call would otherwise carry belongs to the scope
  that sets it: `Http.session` holds the client, so no request, download or crawl takes a
  `client:` of its own. A genuinely per-call argument — `headers:` — stays an argument. This
  survived the second client: `BrowserClient` is named in the same one place `IoClient` is, and
  `url.html()` says nothing about either.
- **A seam is two methods, and unknown means ignored.** Anything pluggable is an
  `abstract interface class` small enough to implement in an afternoon — `Client` is `send` and
  `close` — and what one implementation understands and another does not travels as a typed key
  (`RequestKey`) that the others skip in silence. A capability flag, a probe, or a `switch` over
  implementations would each put the caller back in the business of knowing which one it has.
  A seam ships with the battery that says whether an implementation honours it.
- **One shape for one and for many.** `dest.download(url)` reports what `downloadAll` reports,
  a batch of one, so `show()` renders either and nothing gets wrapped in a one-entry map to be
  displayed.
- **A method earns its place by what it deletes at the call site.** `Elements.attr`, `show()`,
  `merge()`, `thenBy` each removed a line from `bin/keybox.dart`, the benchmark program. A
  method that merely composes two others does not: `gzipTo`, `Table.tsv`, `Ansi.strip`,
  `Console.table` and twenty-one per-algorithm digest shortcuts were each one line over
  something one line away, and are gone. `text.hash(Hash.sha256)` is longer than `text.sha256`
  was and is the only spelling for all twenty algorithms, which is the trade this rule means.
- **A guaranteed value is not nullable.** `ctx.option('x')` with a default, `row.number('size')`,
  `Elements.text` return the value or throw a `StateError` that names what was missing. The
  `*OrNull` form is for the caller who expects absence.
- **Illegal states are not representable.** Sealed types for option kinds, download states and
  crawl failures; a typed parameter over `Object`.
- **Names.** A read-only boolean is `is*`; a settable switch is a bare adjective; a parameter is
  a bare adjective. The async form is bare and the sync twin ends in `Sync`. A pure function of
  the receiver is a getter (`sorted`, `sum`, `res.json`); IO or an argument makes a method. One
  word per idea across modules. Short and meaningful beats descriptive: `done:` not
  `successMessage:`.
- **Builder methods return the receiver; a registration returns its unregistration.**
- **Sync mirrors are allowed only on `fs`.**

## Performance

- **Measure back to back or not at all.** Startup drifts ±80 ms between runs; a claim is two
  numbers from the same minute, never one. `tool/startup.dart` prints the per-module table.
- **Nothing third-party at runtime but `path`.** Every parser, the HTTP client and the archive
  formats are the package's own; `package:html`, `xml`, `archive` and `http` together cost a
  second of front-end work per `dart run`.
- **The renderer is the type.** `Table.show()` is the only table renderer; `Table.cells`
  takes the headers-and-rows shape a program already has. `Io` owns every question about the
  active sink — where it goes, whether it is a terminal, how wide it is, whether it takes
  colour — and `cli` asks `Io`, never a second namespace of its own.
- **The native library does what Dart cannot do fast.** `native/` is one Rust `cdylib`,
  `dart_toolkit_native`, prebuilt per platform and loaded through `dart:ffi` by `native.dart`'s
  `Native`; only `fs` and `hash` import it, so `dart:ffi` costs a program that uses neither
  nothing. It holds the digests, MACs and archive formats and nothing else; there is no Dart
  fallback for any of them, because two implementations of one
  primitive is two places for a bug. Without the library those calls throw `UnsupportedError`
  naming what was needed and why it is absent. Bytes cross as pointer and length, files by path,
  long work inside `Isolate.run`; no callbacks into Dart. Every function that fills a caller
  buffer takes its capacity and every entry point is wrapped in `guard`, so neither an overrun
  nor a panic can cross the ABI; memory comes from the library's own `tk_alloc`, never the host
  process's `malloc`. A new primitive is one Rust function behind one `lookupFunction`, plus its
  published vector in `test/hash_test.dart`.
- **Cryptography beyond hashing is out of scope.** No ciphers, password hashes, key agreement,
  signatures or JWT. This package automates scripts, and owning that code means owning its
  failure modes; hashing, HMAC and the encodings stay, because identifying and verifying data
  is what a script actually does.
- **A file operation streams.** Hashing, downloading and archiving name the file, not its bytes.
- **An executable runs through pub's snapshot**: `dart run dart_toolkit:<name>`.
- **Error policy is chosen at the use site.** `parallelize` and `scrape` settle everything into
  `Either`; the caller picks `rights`, `lefts` or `unwrap()`. Nothing reaches a stream's error
  channel but a throwing `onInit` or `onFinish`.

## Layout

- **Ten modules, one library each.** `lib/<module>.dart` holds the doc, the imports and the
  `part` list; `lib/src/<module>/` holds the parts. Internals are `_private`; there is no `show`,
  no re-export, no `part` across modules. A module uses another through its module file.
- **Every document format is `formats`**, decoded into `JsonDocument` where the model fits
  (JSON, YAML, TOML, INI) and into the markup tree where it does not (HTML, XML). The `http`
  bridges (`res.html`, `url.xml()`) are in `http`, which imports `formats`.
- **One markup tree.** `Node`, `Element`, `Text`, `Attribute`, `Nodes` and `Elements` serve
  HTML and XML alike; they differ in the parser, and in `Element.syntax`, which decides how an
  element serialises and whether a CSS name folds case. Because there is one tree, the XPath
  engine walks `Node` directly instead of being generic over a tree interface.
- **`$` is CSS and `$x` is XPath, on every document.** `$` meaning CSS on HTML and XPath on
  XML was one glyph with two meanings; XML now answers both, matching names as written.
- **Two modules meet through an interface in `core`** (`TaskProgress`, `BatchProgress`).
- **Nothing in `lib/` exists for tests.** The handler-backed `Client` is `test/mock_client.dart`.
- **Tests are one file per module**, and where a piece replaced a package, a differential test
  against that package or the system tool on real inputs. No timing assertions in tests; those
  are `make bench`.
- **`make`** is the release: analyze, format, test, `make native`.

## Crawling

`url.scrape<T>()` is five hooks on a chain and a `Stream<Either<ScrapeFailure, T>>`. Every
crawl-wide setting is on `onInit`'s context; anything per request is `onRequest` editing the
request. `follow` stays on the seeds' hosts (`www.` or not), strips fragments, never fetches a
page twice, and returns whether it scheduled anything. `Cli.run` owns one `CancelToken` per
run, `ctx.cancel`. After `stop()`, a request that fails in flight is not reported; a hook that
throws still is.

## Documentation

One line for the common case; document only what the signature cannot say. Rationale is here;
what each release contains is `CHANGELOG.md`.
