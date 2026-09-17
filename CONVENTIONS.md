# API conventions

Rules this package follows, written down so additions do not re-create what three audits found.
The audits themselves are gone; what they concluded is here, and what changed because of them is
in [CHANGELOG.md](CHANGELOG.md).

## One name per operation

No aliases. If two spellings exist, one of them is deleted — not deprecated, not kept "for
ergonomics". The audit found fifteen, and every one was a thing a reader had to learn was the
same thing.

## A program imports modules, not the barrel

`dart_toolkit.dart` re-exports everything. Under `dart run` the front end compiles the whole
transitive closure on every invocation, so the barrel costs ~1.4 s per run against ~0.3 s for the
modules a program actually uses. Narrow imports in `bin/` and `example/` are enforced by
`tool/check_deps.dart`. The barrel is for tools you `dart compile` once, where tree shaking makes
it free.

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

An entry point earns its place when the composition cannot reconstruct it. `Response.isolate`
stayed because it copies four fields instead of shipping the request graph across an isolate
boundary; `isolateHtml` did not, because it was `isolate((r) => f(r.html()))`.

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

`sanitized()` cleans a path and keeps its separators. `filename` turns one string into one
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

## Error policy is chosen at the use site

`parallelize` settles every task and returns `List<Either<Object, R>>`. The caller picks:
`.rights`, `.lefts`, or `.unwrap()` to throw the first failure. There is no fail-fast variant of
the primitive.

`Either.tryCatch` has no error type parameter. A function that cannot honour `E` without a
converter should not accept `E` — narrow with `mapLeft` afterwards.

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
