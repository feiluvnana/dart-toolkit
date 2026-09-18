# API conventions

Rules this package follows, written down so additions do not re-create what three audits found.
The audits themselves are gone; what they concluded is here, and what changed because of them is
in [CHANGELOG.md](CHANGELOG.md).

## One name per operation

No aliases. If two spellings exist, one of them is deleted — not deprecated, not kept "for
ergonomics". The audit found fifteen, and every one was a thing a reader had to learn was the
same thing.

## A program imports modules, not the barrel — and an executable runs through the snapshot

`dart_toolkit.dart` re-exports everything. Under `dart run file.dart` the front end compiles the
whole transitive closure on every invocation, so the barrel costs ~1.4 s per run against ~0.3 s
for the modules a program actually uses. Narrow imports in `bin/` and `example/` are enforced by
`tool/check_deps.dart`. The barrel is for tools you `dart compile` once, where tree shaking makes
it free.

`dart run dart_toolkit:<name>` is different: pub keeps an incremental snapshot of a package
executable and recompiles only what changed. Measured on `keybox --help`, three pairs: 352–414 ms
against 1 332–1 475 ms for `dart run bin/keybox.dart`, edits included. That is how `bin/` is run.

The same rule shapes the modules themselves: `core` has no third-party dependencies, and
`HtmlDocument` and `XmlDocument` live in `html` and `xml` so that parsing JSON does not load an
HTML and an XML parser to do it.

## Extensions are `<Receiver>Extensions`

Receiver first, plural, no module prefix, no `Toolkit`. Where two extensions share a receiver,
qualify by purpose after the receiver: `StringAnsiExtensions`, `StringShellExtensions`,
`StringPathExtensions`. Receiver first even when an adjective reads better —
`StreamNullableExtensions`, not `NullableStreamExtensions`.

## A member belongs to the module that owns its dependency

Not the module that reads nicest at the call site. `download` is `http`, not `fs`, even though
`path.download(url)` reads better than the alternative. `zipTo` is `archive`. `sha256` is `hash`.

`tool/check_deps.dart` holds a per-module third-party budget and runs in CI. Adding a dependency
means changing the budget on purpose, in a reviewable diff.

## Top-level functions are for verbs you type constantly

`run`, `which`, `retry`, `die`, `onExit`. Everything else is a static namespace — `Console`,
`Logger`, `Prompt`, `Env`, `Os`, `Ansi`. The dividing line is how often a script types it, not
what layer it belongs to.

## One query operator per document type, spelled `$`

`HtmlDocument.$` is CSS, `XmlDocument.$` is XPath, `JsonDocument.$` is JSONPath — one query
language per format, each the one native to it. HTML XPath existed alongside the CSS `$` and was
145× slower on a 2000-row page and quadratic in document size; it is gone, along with the package
that supplied it.

`$` on HTML returns `Elements`, a `List<Element>` that also answers `text`, `attr()`, `lines`
and `$()` for its first match. Eight call sites lost a `.first`; an empty match throws a
`StateError` that says so, where `.first` said "No element". HTML also has `$x`, XPath under
the name the browser console gives it, returning `Nodes` — elements, text and attributes —
because `//tr[td[2]="FLAC"]/td[1]/a/@href` has no CSS spelling. XML's `$` is that engine.

## The parsers and the client are ours

`package:html`, `xml`, `archive` and `http` together cost about a second of front-end work per
`dart run` for machinery a scripting toolkit does not need: an HTML5 tree builder, a
schema-aware XML stack, a pure-Dart deflate, a client layer over the `dart:io` client. Each is
replaced in-house — a tag-soup HTML parser and CSS engine, an XML parser and an XPath 1.0
subset (`lib/xpath.dart`, shared with HTML as `$x`), a zip container over `dart:io`'s zlib,
`Request`/`Response`/`Client` over `HttpClient` — and each is checked against the package it
replaced on real inputs in `test/<module>_test.dart`. The reference packages stay dev
dependencies for those tests and nothing else. `path` is the one runtime dependency.

Where Dart is genuinely slow and the operating system already has the code, `dart:ffi` binds
it: hashing runs on CommonCrypto or libcrypto at 2–3 GB/s against 170 MB/s in Dart, with
`package:crypto` as the fallback. Rust is not on the table until a measured, CPU-bound,
non-parsing hot spot appears that the SDK and the OS do not already cover.

## A module is one library

`lib/<module>.dart` holds a module's doc, its imports and its `part` list; every file under
`lib/src/<module>/` is a part of it. What a module does not publish is `_private` and shared
freely between its parts — no `show` lists, no re-exports, no "not exported" comments. Another
module is used through its module file, `import 'http.dart'`, never through a file inside its
`src/`; what one module offers another is therefore public API. Programs import
`package:dart_toolkit/<module>.dart`.

## A file operation streams

Hashing, archiving and downloading name the file, not its bytes. `p.sha256()` reads a stream;
`(await p.readBytes()).sha256` held the whole file, which cost 888 MB of resident memory on a
512 MB file against 266 MB. Where a whole-file read is unavoidable the API says so.

## A registration returns its unregistration

`onExit` and `CancelToken.onCancel` both return a `void Function()` that undoes them, and
everything that registers internally calls it when its work finishes. Without that, a long-lived
token retains every listener it was ever given — measured at 52 MB for 200 000 completed
`cancelWith` calls.

## The session owns what every request shares

The client, the timeout and the default headers are set once on `Http.session`. A timeout on
each entry point would be six parameters expressing one decision; a stalled server should fail
the same way everywhere.

## No cross products

Do not add a method because it is the combination of two that already exist. `client.json(uri)`
was `uri.json(client: client)`; `uri.isolateHtml(f)` was `(await uri.get()).isolateHtml(f)`.
Twenty-one members expressed four ideas before this rule.

An entry point earns its place when the composition cannot reconstruct it, or when it deletes a
line at every call site: `Response.isolate` stayed because it copies four fields instead of
shipping the request graph across an isolate boundary; `isolateHtml` did not, because it was
`isolate((r) => f(r.html))`. `Elements.attr`, `Stream<BatchProgress>.show()` and
`Iterable<Stream>.merge()` are compositions too, and stay because each replaced a loop or a
`.first` in `bin/keybox.dart`. `Map.downloadAll` and `pairs` both stay: `{url: dest}.downloadAll()`
is the common case and `pairs` is for merging with a stream.

## Two modules meet through an interface in `util`

`util` has no dependencies, so every module can see it. A producer and a renderer that must not
depend on each other — `http`'s `DownloadProgress` and `cli`'s `ConsoleMultiProgress` — meet at
`TaskProgress`/`BatchProgress` declared there. This is the legal shape for a cross-module seam;
an import edge between two leaf modules is not, and `tool/check_deps.dart` fails it.

## A format bridge lives with its parser

`res.html()` and `url.html()` are in `html`, `res.xml()` and `url.xml()` in `xml`; `http` keeps
`json()` because `core` is dependency-free. Under `dart run` the import closure is compiled on
every invocation, and `http` used to carry both parsers for every program: about a second per
run for a downloader that parsed neither. `tool/startup.dart` measures it; quote its deltas.

## `Cli.run` is the lifecycle

It parses, dispatches, turns a usage error into a message and exit code 64, runs the exit
hooks, and releases the signal handlers so the process can end. A signal watch keeps the
isolate alive — a script that registers `onExit` and never reaches `Cli.run`, `die` or
`clearExitHooks` does not exit. `CliCommand.run` throws instead of exiting; tests use it.

## A guaranteed value is not nullable

A declared default or `required: true` guarantees a value, so `ctx.option` and `ctx.number`
return it non-null and throw `StateError` when the guarantee was not made. The `*OrNull` forms
are for an optional without a default. Every program used to bang every read.

## A component is not a path

`sanitized` cleans a path and keeps its separators. `filename` turns one string into one
component and escapes them. Anything that came from outside — a scraped title, a header, user
input — goes through `filename`.

## `isolate*` extracts, it does not return the document

`res.isolateHtml((d) => d)` copies the whole parsed graph back across the boundary and buys
nothing over parsing here. Return the data the callback extracted.

## Illegal states should not be representable

Prefer a sealed type to a set of booleans. `CliOption` is `CliFlag | CliValue | CliNumber |
CliChoice`, not four orthogonal fields that let `flag: true, numeric: true` compile;
`DownloadProgress` is `Downloading | Downloaded | DownloadSkipped | DownloadFailed`, not three
booleans and a nullable error. A `required` option cannot also carry a default — the constructor
asserts it.

Prefer a typed parameter to `Object`. Where a union genuinely cannot be expressed — `follow`
takes a `Uri` or a relative `String` href — throw `ArgumentError` on anything else rather than
silently doing nothing.

## Builder methods return the receiver

All of them, including `subcommand`. A chain always configures one object; nesting goes through a
`build` callback, where the indentation shows it.

## A default is declared once

The declaration owns it: `..number('workers', defaultTo: 4)`. Readers have no `defaultTo`
parameter, because the parsed values already carry it.

## Deleting beats wrapping when the SDK already has it

`elementAtOrNull` and `nonNulls` ship with Dart; the package's `getOrNull` and `whereNotNull`
were second names for them and are gone. The one behavioural difference is documented rather than
re-implemented: `elementAtOrNull` throws on a negative index where `getOrNull` returned `null`.

## A failure carries its trace

`Either.tryCatch` records the stack trace with the error and `unwrap` rethrows with it, so a
`parallelize` failure points at the throw, not at the unwrap.

## Names

1. A read-only boolean is `is*` (`isDone`, `isOk`, `isCI`). A boolean *switch* the caller sets
   is a bare adjective (`Ansi.enabled = false`), as `stdin.echoMode` is. A boolean *parameter*
   is a bare adjective or imperative (`recursive: true`, `descending: true`).
2. When a sync and an async form both exist, the async one is bare and the sync one ends in
   `Sync`: `exists`/`existsSync`, `tryCatch`/`tryCatchSync`. A member with one form has no
   suffix.
3. A pure function of the receiver is a getter; anything that does IO or takes an argument is a
   method. `name`, `sanitized`, `res.json` are getters; `size()`, `exists()`, `url.json()` are
   methods.
4. One word per idea across modules: a hook's failure is `HookFailed`; the wrapped tree is `raw`;
   the message printed on success is `done:`; restoring defaults is `reset()`.
5. Short and meaningful beats descriptive: `done:` not `successMessage:`, `chunkEvery` not
   `chunkTime`. A name typed once per program may be long (`throwIfCancelled`).

## Error policy is chosen at the use site

`parallelize` settles every task and returns `List<Either<Object, R>>`. The caller picks:
`.rights`, `.lefts`, or `.unwrap()` to throw the first failure. There is no fail-fast variant of
the primitive. `scrape` is the stream instance of the rule: `Stream<Either<ScrapeFailure, T>>`,
`.rights`, `.lefts` or `.unwrap()`, and nothing on the error channel — a crawl that died on one
TLS handshake 600 pages in is how the rule reached streams.

`Either.tryCatch` has no error type parameter. A function that cannot honour `E` without a
converter should not accept `E` — narrow with `mapLeft` afterwards.

After `stop()`, a request that fails in flight is not reported — the crawl is over — but a hook
that throws still is: a programmer error is never swallowed.

## A crawl is a chain of hooks

`url.scrape<T>()` returns a `Scrape<T>`: five hooks whose registration returns the receiver,
and a `Stream<Either<ScrapeFailure, T>>`. Every crawl-wide setting lives on one object, the
`InitContext` handed to `onInit`, so a reader finds the whole configuration in one block and the
chain stays five names long. Anything that can differ per request — a header, the `user-agent`
— is not a setting; it is `onRequest` editing the request. Behaviour is the other four hooks —
`onRequest`, `onResponse`, `onError`, `onFinish` — each given the context for its moment and
nothing else. A bare named parameter on `scrape`, or a builder method per setting, is not the
shape: the first cannot chain, the second puts twelve limits between a reader and the hooks. The
defaults are chosen so that a chain with one `onResponse` finishes a crawl of one site without
taking the site down — and "one site" means the seeds' hosts with or without `www.`, without
fragments, and never a second fetch of a page already followed. `follow` says whether it
scheduled anything, because a silent drop cost keybox every FLAC.

`Cli.run` owns one `CancelToken` per run, `ctx.cancel`, cancelled on a signal, on `die` and
when the action ends. A script that needs cancellation passes it on instead of building its own.

## Sync mirrors are allowed only on `fs`

Synchronous IO is the point of a scripting toolkit, and only there. Nothing else in the package
gets a `*Sync` twin.

## Every console write goes through `ConsoleIo`

Including subprocess output. `ConsoleIo.isTerminal` and `ConsoleIo.columns` — never
`stdout.hasTerminal` — so redirecting the sink also redirects the decision about what to render.

## Accepted exception

`Future<ShellResult>` mirrors `text`, `lines`, `json` and `ok` onto itself so that
`await run('cmd').text` works. No other result type does this. Shell chaining is this package's
hottest path and it earns the inconsistency; nothing else does.

## Doc comments are reference, not argument

One line for the common case. Document only what the signature cannot say: units, throwing
behaviour, mutually exclusive parameters, and anything surprising. Rationale goes here; the audit
trail goes in the CHANGELOG.
