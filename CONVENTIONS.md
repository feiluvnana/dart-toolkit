# API conventions

Rules this package follows, written down so additions do not re-create what
[AUDIT.md](AUDIT.md) found.

## One name per operation

No aliases. If two spellings exist, one of them is deleted — not deprecated, not kept "for
ergonomics". The audit found fifteen, and every one was a thing a reader had to learn was the
same thing.

## Extensions are `<Receiver>Extensions`

Receiver first, plural, no module prefix, no `Toolkit`. Where two extensions share a receiver,
qualify by purpose after the receiver: `StringAnsiExtensions`, `StringShellExtensions`,
`StringPathExtensions`.

## A member belongs to the module that owns its dependency

Not the module that reads nicest at the call site. `download` is `http`, not `fs`, even though
`path.download(url)` reads better than the alternative. `zipTo` is `archive`. `sha256` is `hash`.

`tool/check_deps.dart` holds a per-module third-party budget and runs in CI. Adding a dependency
means changing the budget on purpose, in a reviewable diff.

## Top-level functions are for verbs you type constantly

`run`, `which`, `retry`, `die`, `onExit`. Everything else is a static namespace — `Console`,
`Logger`, `Prompt`, `Env`, `Os`, `Ansi`. The dividing line is how often a script types it, not
what layer it belongs to.

## No cross products

Do not add a method because it is the combination of two that already exist. `client.json(uri)`
was `uri.json(client: client)`; `uri.isolateHtml(f)` was `(await uri.get()).isolateHtml(f)`.
Twenty-one members expressed four ideas before this rule.

An entry point earns its place when the composition cannot reconstruct it. `Response.isolate`
stayed because it copies four fields instead of shipping the request graph across an isolate
boundary.

## Illegal states should not be representable

Prefer a sealed type to a set of booleans. `CliOption` is `CliFlag | CliValue | CliNumber |
CliChoice`, not four orthogonal fields that let `flag: true, numeric: true` compile.

Prefer a typed parameter to `Object`. Where a union genuinely cannot be expressed — `follow`
takes a `Uri` or a relative `String` href — throw `ArgumentError` on anything else rather than
silently doing nothing.

## Builder methods return the receiver

All of them, including `subcommand`. A chain always configures one object; nesting goes through a
`build` callback, where the indentation shows it.

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
