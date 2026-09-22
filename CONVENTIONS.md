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
- **One word per idea, and the same word everywhere.** A default is `or` — `Opt.…or(v)`,
  `Console.ask(or:)`, `confirm(or:)`, `select(or:)`. A body is `text`/`bytes`/`form`/`json`, on
  `Request`, on `post`/`put`/`patch`/`delete` and on `follow`. One file or a thousand is
  `download`. An audit that finds a second word for an idea deletes it rather than documenting
  both.
- **A name is written once.** Anything a caller declares and then looks back up is a name
  spelled twice and a typo the compiler cannot see. A CLI option is a value — `Opt.number('top').or(10)`
  — and `ctx(top)` is an `int` because the option says so; `Opt.among('algo', Hash.values)` takes
  the values, so nothing rebuilds an enum from a string. `Table` still keys by column name,
  because a CSV's columns are not known until it is read.
- **Ambient over threaded.** A setting every call would otherwise carry belongs to the scope
  that sets it. There are three such scopes and they read alike: `Http.session` holds the
  client, so no request, download or crawl takes a `client:`; `Shell.session` holds the
  workdir, environment, timeout, encoding and failure policy, so `run`, `path.run` and a
  pipeline repeat none of them; `Cancel.session` holds the token, so `download`, `retry` and
  `.cancellable` take no `cancelToken:`. A genuinely per-call argument — `headers:`, `input:`,
  `args:` — stays an argument, and still wins over the scope. This survived the second client:
  `BrowserClient` is named in the same one place `IoClient` is, and `url.html()` says nothing
  about either.
- **The scope is the only way in.** Not the default way — the only one. `cancelWith` kept an
  optional token that defaulted to the session's, which is two ways to say one thing and the
  one an audit finds threaded through call sites; it takes none now — and, taking nothing and
  doing no IO, it is a getter called `cancellable` — and it throws outside a session. A client reaches the network through `Http.session` and a token reaches an
  operation through `Cancel.session`, and there is no second door. What a scope *holds* is
  named where it opens — `Http.session(client:)`, `Cancel.session(token:)` — and that is the
  one place either word appears. A session's own settings are its arguments too:
  `timeout:`, `headers:` and `cookies:` are all `Http.session`'s, never a request's.
- **A scope is opened once, at the top.** `Cli.run` opens the `Cancel.session` whose token is
  `ctx.cancel`, so a program that wants ^C to stop its downloads writes nothing at all.
- **A seam is two methods, and unknown means ignored.** Anything pluggable is an
  `abstract interface class` small enough to implement in an afternoon — `Client` is `send` and
  `close` — and what one implementation understands and another does not travels as a typed key
  (`RequestKey`) that the others skip in silence. A capability flag, a probe, or a `switch` over
  implementations would each put the caller back in the business of knowing which one it has.
  A seam ships with the battery that says whether an implementation honours it.
- **One shape and one name for one and for many.** `dest.download(url)`, `pairs.download()`,
  `stream.download()` and `map.download()` are one word over four receivers, streaming the
  same `BatchDownloadProgress`: one file is a batch of one, so `show()` renders either and
  nothing gets wrapped in a one-entry map to be displayed. Two names for one operation —
  `download` and `downloadAll` — was the second audit's finding.
- **A method earns its place by what it deletes at the call site.** `Elements.attr`, `show()`,
  `merge()`, `thenBy` each removed a line from `bin/keybox.dart`, the benchmark program. A
  method that merely composes two others does not: `gzipTo`, `Table.tsv`, `Ansi.strip`,
  `Console.table`, `Table.records`, `Sequence.count`, `Group.counts`, `String.stripped` and
  twenty-one per-algorithm digest shortcuts were each one line over something one line away,
  and are gone. `text.hash(Hash.sha256)` is longer than `text.sha256` was and is the only
  spelling for all twenty algorithms, which is the trade this rule means.
- **The rule cuts both ways.** `Element.attr` and `Sequence.union` each duplicate something
  spelled out elsewhere and were kept, because deleting them makes a call site longer; that
  is the same rule, not an exception to it. A duplicate is deleted when it costs nothing and
  kept when it pays.
- **An ambient scope answers every question its token does.** `Cancel.isCancelled`,
  `Cancel.reason` and `Cancel.throwIfCancelled()` mirror the three readings on `CancelToken`,
  because the alternative is `Cancel.token?.throwIfCancelled()` — which the package itself
  wrote in three places, and whose `?.` silently does nothing outside a session where it looks
  like it checked. A reading is quiet outside the scope (nothing has cancelled it); an adapter
  like `.cancellable` throws there instead, because binding to a scope that does not exist
  would leave a wrapper that does nothing at all.
- **A grid with a hole in it cannot be guessed.** `hash`, `hashBytes`, `checksum`, `hmac` and
  `hmacBytes` are on `String`, `List<int>` and `Path` alike; when three receivers offered three
  different subsets, nobody could predict which. Fill the grid or cut the column.
- **A guaranteed value is not nullable.** `ctx.option('x')` with a default, `row.number('size')`,
  `Elements.text` return the value or throw a `StateError` that names what was missing. The
  `*OrNull` form is for the caller who expects absence.
- **Illegal states are not representable.** Sealed types for option kinds, download states and
  crawl failures; a typed parameter over `Object`. A body was `Object?` accepting a `String`, a
  `List<int>` or a `Map` and throwing at runtime for anything else; it is now four typed
  arguments, which is the same length at the call site and a compile error instead.
- **What is public is what a caller uses.** A parser's internals, an FFI shim and a query
  engine behind a glyph are not API. `CliOption.parse`/`fallback`/`isRequired`/`choices`,
  `CliCommand.findOption`/`findAbbr`/`printUsage`/`subcommands`/`parent`, `XPath` and
  `JsonPath` were all reachable and none was meant to be. What has to cross a library boundary
  and still is not API says so: `NativeBridge`, not `Native`.
- **Names.** A read-only boolean is `is*`; a settable switch is a bare adjective; a parameter is
  a bare adjective. The async form is bare and the sync twin ends in `Sync`. A pure function of
  the receiver is a getter (`sorted`, `sum`, `res.json`); IO or an argument makes a method. One
  word per idea across modules. Short and meaningful beats descriptive: `done:` not
  `successMessage:`.
- **A builder is for a chain that reads better than a constructor, not for everything.**
  `Scrape`'s five hooks are a chain because the order is the lifecycle. A command is not:
  `CliCommand(options:, commands:, handler:)` says everything once, where `declare()`,
  `action()`, `command(build:)` and a public `handler` field were four ways to say two things.
  Where a builder is right, its methods return the receiver; a registration returns its
  unregistration.
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
  nothing. `http` imports `hash` for `download(checksum:)`, and that is free: it already loads
  `fs`, which already loads `native`. Measured alternating, three rounds — +406/+373/+389 ms
  over bare without it, +386/+415/+369 ms with. A module that does *not* reach `fs` still pays
  nothing, which is what the rule is for. It holds the digests, MACs and archive formats and nothing else; there is no Dart
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
- **Writing names the format; reading works it out.** `archiveTo` and `compressTo` read the
  destination's extension, because a file that does not exist has nothing else to go on.
  `extractTo`, `archiveEntries` and `decompressTo` read the file's magic number and fall back
  to its name, so a `.bin` that is really a 7z opens. The sniff is in Rust, next to the readers
  it feeds; `Archive` names every format including read-only `rar`, and `isWritable` is what
  `archiveTo` checks.
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
crawl-wide setting is on `onInit`'s context — `robots` among them, which fetches each host's
rules once and drops what they forbid; anything per request is `onRequest` editing the
request. `follow` stays on the seeds' hosts (`www.` or not), strips fragments, never fetches a
page twice, and returns whether it scheduled anything. `Cli.run` owns one `CancelToken` per
run, `ctx.cancel`. After `stop()`, a request that fails in flight is not reported; a hook that
throws still is.

## Documentation

One line for the common case; document only what the signature cannot say. Rationale is here;
what each release contains is `CHANGELOG.md`.
