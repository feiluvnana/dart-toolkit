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
  `Request`, on `post`/`put`/`patch`/`delete` and on `follow` — and `files`, the fifth, which
  is the one that pairs: `form` with `files` is not two bodies but the fields and the files of
  one `multipart/form-data`. One file or a thousand is `download`. An audit that finds a second word for an idea deletes it rather than documenting
  both.
- **A name is written once.** Anything a caller declares and then looks back up is a name
  spelled twice and a typo the compiler cannot see. A CLI option is a value — `Opt.number('top').or(10)`
  — and `ctx(top)` is an `int` because the option says so; a **positional is a value too**,
  `Arg.text('id').required()`, read through the same `ctx(id)`. It was `ctx.rest` for a while,
  which is the rule broken in the one place it was easiest to break: every program pulled its
  own out of a `List<String>`, checked it by hand, wrote its own error message, and got no
  type, no default and no line in `--help` for any of it. `Opt` and `Arg` differ in how they
  are written on the command line and in nothing else; `Opt.among('algo', Hash.values)` takes
  the values, so nothing rebuilds an enum from a string. `Table` still keys by column name,
  because a CSV's columns are not known until it is read.
- **Ambient over threaded.** A setting every call would otherwise carry belongs to the scope
  that sets it. There are three such scopes and they read alike: `Http.scope` holds the
  client, so no request, download or crawl takes a `client:`; `Shell.scope` holds the
  workdir, environment, timeout, encoding and failure policy, so `run`, `path.run` and a
  pipeline repeat none of them; `Cancel.scope` holds the token, so `download`, `retry` and
  `.cancellable` take no `cancelToken:`. A genuinely per-call argument — `headers:`, `input:`,
  `args:` — stays an argument, and still wins over the scope. This survived the second client:
  `ChromeClient` is named in the same one place `IoClient` is, and `url.html()` says nothing
  about either.
- **The scope is the only way in.** Not the default way — the only one. `cancelWith` kept an
  optional token that defaulted to the scope's, which is two ways to say one thing and the
  one an audit finds threaded through call sites; it takes none now — and, taking nothing and
  doing no IO, it is a getter called `cancellable` — and it throws outside a scope. A token
  reaches an operation through `Cancel.scope` and nowhere else. What a scope *holds* is
  named where it opens — `Http.scope(client:)`, `Cancel.scope(token:)` — and that is the
  one place either word appears.
  - **One door per situation, which is not the same as one door.** A client now has two ways
    to reach the network and they are not alternatives: `url.get()` requires the scope and is
    the only way in for code with no client to hand, and `client.get(url)` requires no scope
    and is the only way in for code holding one. What the rule forbids is two spellings for
    one situation — `cancelWith(token:)` beside `Cancel.scope`, `download` beside
    `downloadAll` — because then a call site chooses for no reason and an audit finds the
    argument threaded. Here the situation picks the spelling, and neither spelling can do the
    other's job: a scope cannot carry a capability, and a receiver cannot appear where there
    is no receiver.
  - A scope's own settings are its arguments too: `timeout:`, `headers:` and `cookies:` are
    all `Http.scope`'s, never a request's.
- **A scope holds settings; it cannot hold a capability.** This is the line the three scopes
  are drawn on, and the one `Http.scope` crossed without saying so. A timeout, a cookie jar,
  default headers, a workdir, a cancel token are all *settings* — every implementation means
  the same thing by them, so the scope can hold them and the call site pays nothing. A
  `Client` is not only settings: `ChromeClient` can drive a tab, and `IoClient` cannot. What a
  scope holds it holds as the seam's type, so through `Http.scope` a client is `send` and
  `close` and nothing else — which is why `ChromePage` was reachable only by keeping the
  client in a variable, the one thing *ambient over threaded* says never to do. The fix is not
  a `url.page(…)` that probes the ambient client for a capability: that is the probe two
  bullets down, and it would resurrect the `Browser` abstraction this release deleted for
  promising something that was never there. Capabilities belong on the object
  (`ClientExtensions`, so `chrome.page` sits beside `chrome.get` and the compiler rules on
  it); the scope keeps the cases with no receiver to hang a client off —
  `stream.download(concurrency: 4)` over a merged stream of records, which is `bin/keybox.dart`
  line for line.
- **Sending consumes a request.** A client writes on the request it is handed — a scope stamps
  its default headers and its `cookie` there — so a `Request` is single-use. Everything that
  sends one a caller owns copies it first, and the seam's own doc says so, because the
  alternative is the bug this found: the same request sent twice carried the first send's jar
  and the refresh was then skipped, since the guard is *does this request already name a
  cookie*. The engine already copied defensively at every site; the discipline is now in the
  type's contract instead of in each caller's memory.
- **An event is a pair: `on<event>` registers, `<event>` fires.** Two shapes and no others,
  and the pair reads the same way round from either end. The lifecycle had four names for one
  event in three shapes — `onExit`, `die`, `runExitHooks`, `clearExitHooks` — two of them
  named after the list they kept rather than after anything a caller wants, and none of them
  telling you from its name that the other three existed. `Lifecycle.onExit` and
  `Lifecycle.exit` are the whole surface: `onExit(null)` is how a registration is undone, so
  removal needs no verb of its own, and *fire the listeners without leaving* turned out to be
  something only `Cli.run` does, so it is private. A pair like this is namespaced when the
  bare name would collide: a top-level `exit` does not merely clash with `dart:io`'s, it
  **silently wins**, because Dart resolves a name to a non-platform library without calling it
  ambiguous — a call site that reads `exit(0)` would stop meaning what it says.
- **A wait is armed before the thing it waits for.** `ChromePage.navigating` takes the action
  rather than being a bare `waitForNavigation()` called after a click, because a click returns
  immediately and a fast page finishes loading before the next line runs — a wait armed
  afterwards has already missed its event and sits until its timeout. `downloading` and
  `fetching` are the same shape for the same reason, and the three read alike on purpose: a
  present participle takes the action that causes the thing it names. Where a wait cannot be
  armed first, it needs a second signal: `back()` waits on the lifecycle event *or* the URL
  moving, because a page the back/forward cache restores fires no second `load` at all.
- **A policy with three callers is written once.** What a redirect hop carries — 303 and a
  non-GET 301 or 302 becoming a bodiless GET, 307 and 308 keeping both, credentials stopping at
  another host — is `Request._hop`, and `IoClient`, the cookie jar's walk and the crawl engine
  all call it. The engine had it spelled out inline and the other two followed no chain at all;
  the audit that found the jar losing a login's cookie found the same rule about to be written
  a third time.
- **A seam absorbs the difference; it does not export it.** `Client.close()` was
  `FutureOr<void>`, which saved a synchronous implementation one `Future.value()` and cost
  every caller an `if (client.close() case final Future<void> pending)` to find out which it
  got. It is `Future<void>` now.
- **A scope is opened once, at the top.** `Cli.run` opens the `Cancel.scope` whose token is
  `ctx.cancel`, so a program that wants ^C to stop its downloads writes nothing at all.
- **A seam is two methods, and unknown means ignored.** Anything pluggable is an
  `abstract interface class` small enough to implement in an afternoon — `Client` is `send` and
  `close` — and what one implementation understands and another does not travels as a typed key
  (`RequestKey`) that the others skip in silence. A capability flag, a probe, or a `switch` over
  implementations would each put the caller back in the business of knowing which one it has.
  A seam ships with the battery that says whether an implementation honours it.
  - **A key every implementation must honour belongs to the seam, not to one side of it.**
    `Request.raw` — *the resource, never a rendering of it* — reads like the Chrome-specific
    keys beside it and is not one: it was `ChromeClient.direct`, and a download that wanted it
    had to name Chrome to ask, which is the layering inverted. It sits on `Request` now, where
    the contract does, so `download` says what it wants of any client and a renderer written
    later inherits the obligation instead of reintroducing the bug.
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
  wrote in three places, and whose `?.` silently does nothing outside a scope where it looks
  like it checked. A reading is quiet outside the scope (nothing has cancelled it); an adapter
  like `.cancellable` throws there instead, because binding to a scope that does not exist
  would leave a wrapper that does nothing at all.
- **A grid with a hole in it cannot be guessed.** `hash`, `hashBytes`, `checksum`, `hmac` and
  `hmacBytes` are on `String`, `List<int>` and `Path` alike; when three receivers offered three
  different subsets, nobody could predict which. Fill the grid or cut the column.
- **Help describes this command and nothing else.** `Usage: zlib [options] [command]` on a
  program with no subcommands invites the reader to type something that cannot work, and a
  program whose positionals appear nowhere in its help has not documented its own interface.
  The usage line is now built from what the command actually holds — its arguments by name,
  `[options]` always, `[command]` only when there are some — and one renderer writes the help
  line for an `Arg` and an `Opt` alike, so the two cannot drift.
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
  `Native`; only `fs`, `hash` and `http` import it, so `dart:ffi` costs a program that uses
  none of them nothing. `http` imports `hash` for `download(checksum:)` and `native` for brotli
  and zstd, and both are free at import: it already loads `fs`, which already loads `native`.
  What is not free is *opening* the library, which is lazy and costs 12.5 ms the first time —
  8 ms of it `Isolate.resolvePackageUriSync`, measured back to back three times — so `http`
  pays it on its first request, against 15–20% off every response body from then on. The FFI
  itself stays in `NativeBridge`: `http` binds none of its own, because a decoder handle is not
  a thing a module about requests should be holding. Measured alternating, three rounds — +406/+373/+389 ms
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
- **One namespace owns the terminal, and one live region underneath it.** Everything that
  writes to a terminal is on `Console` — the log verbs, the prompts, the rule, and the three
  indicators. `Logger` was a second namespace for the same terminal, and the two could not see
  each other: a `Logger.info` during a `Console.spin` wrote to the row the spinner was
  redrawing, and they garbled. A renderer now owns the bottom rows and declares how many, so
  any durable write clears them, lands where they stood, and draws them again below. That is
  the whole reason the parts compose, and it is why the verbs are on the same class rather
  than merely in the same module.
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
