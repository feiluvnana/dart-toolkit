# Conventions

**One way to do each thing; every method has one behaviour; everything is async; every part works
on its own and plugs into every other through four shapes and one status model.**

The package optimises for these, in this order:

1. **How fast it runs:** startup, throughput and memory, measured (§9).
2. **How little a script writes, and how easily its author finds the way**, ranked equal.
3. Coherence, documentation and feature count.

This file states rules. What a release changed is in `CHANGELOG.md`.

---

## 1. The shapes

| # | Rule |
|---|---|
| 1 | **Four shapes.** A method returns a value, a `Task<T>`, a `Batch<I, T>` or a `Stream<E>`; something you start is a resource with `close()`. Nothing else is returned for work: no progress callbacks, no handle with its own state machine. |
| 2 | **Async only.** Everything that touches the disk, the network, a process, a native library or the terminal is async; there are no `…Sync` twins. Pure computation on values in memory is synchronous (`path.name`, `doc['a']`, `image.resize(…)`). A reading that does I/O is a method, never a getter. |
| 3 | **A `Task` is a `Future`.** It starts at once; `statuses` gives the warnings so far and the current status first, so a display attached late misses nothing. A task made while another work's body runs is part of it: its progress and warnings show as that work's. |
| 4 | **One batch builder: `parallelize`.** No module ships a batch overload or its own scheduler; `Pool.map` and the crawl are built on it. Values come back in input order. |
| 5 | **A stream ends when its source ends;** cancelled, it ends with a `CancelledException`, so `await for` throws it. |
| 6 | **One way to start and end a resource:** `X.start(…)` (or `launch`/`connect` where there are two real ways) and `close()`. Nothing is called `dispose`, `stop`, `kill` or `done`. Resources still open when `Cli.run` ends are closed. |

## 2. Status

| # | Rule |
|---|---|
| 7 | **One `Status` model**, one meaning per state: `Waiting`, `Running`, `Paused`, `Done(value, fresh)`, `Skipped(reason)`, `Failed(error, stackTrace)`, `Stopped(reason)`, and `Warned` notes that are not states. |
| 8 | **Producers report amounts, never rates,** in a `Unit` (bytes, items, none). Whoever draws computes speed and ETA with one meter. |
| 9 | **Every producer names its item:** a file's `folder/name`, a URL's host and path. Nothing guesses a label from text. |
| 10 | **"Nothing had to be done" is `Done(fresh: false)`,** never a `Skipped` holding a value. `Skipped` has no value. |
| 11 | **Every retry is a `Warned(RetryWarning(attempt, of, wait, cause))`,** from every source. |

## 3. Outcomes and errors

| # | Rule |
|---|---|
| 12 | **`await` means success or throw;** `.settled` never throws. A batch throws once, at the end, one `BatchException` with every failure and every success. |
| 13 | **A cancel is `Stopped`, never `Failed`,** thrown once to the awaiter, and never an unhandled error. A timeout is a `Failed(TimeoutException)`. |
| 14 | **A bug is never turned into a value.** An `Error` from your code ends a batch at once and is rethrown as it is. |
| 15 | **The error table, everywhere.** `MissingException(what, where:)` (a reading found nothing), `PathNotFoundException` (an input is not there), `PathExistsException` (`conflict: fail`), `FormatException` and its subtypes (content not valid; `Invalid <FORMAT> in <file>, line n: <why>`), the `HttpException` family, `ShellException`, `TimeoutException`, `CancelledException(reason)`, `BatchException`, `NativeException` (valid input the native layer failed on), and `ArgumentError`/`StateError` for the caller's mistakes only. Runtime facts are never `ArgumentError`/`StateError`. The native layer's errors are mapped at the boundary. |
| 16 | **Every failure names its subject:** the file, URL, selector, column or key it was about. A wrapper keeps its cause and the trace where it was caught. |
| 17 | **Nothing is swallowed unexplained.** An empty `catch` is typed where it can be and says why on its line; `make check` refuses one without. |
| 18 | **Retry never repeats what would fail the same way:** an `Error`, a `FormatException`, a `MissingException`, a cancel, a command that cannot run. The innermost policy wins: an error an inner loop gave up on is not retried by an outer one. |
| 19 | **Exit codes:** usage 64, timeout 124, cannot run 126, not found 127, ^C 130, a signal 128+n, anything else 1. `cli.run` is the only thing that exits. |

## 4. Configuration

| # | Rule |
|---|---|
| 20 | **One behaviour per method.** A mode is a separate method or a sealed setting value (`Quality`, `Retry`, `Browser`, `Render`, `Command`); no flag switches the algorithm, the result type or the meaning of another parameter, and nothing is silently ignored. Every invalid combination or out-of-range value is an `ArgumentError` at the call. |
| 21 | **Scopes are `X.scope(body, {…})`, body first,** and hold until the body's result (a future, task, batch or stream) has finished. An inner scope inherits what it does not set. A scope changes settings; it never turns behaviour on. |
| 22 | **Defaults are one table, the same inside and outside a scope:** `concurrency` 4 (a crawl 8, 4 per host); `Retry.network` for every request, none for local work; 30 s per response and per Chrome render; `Conflict.skip`; `Original.keep` (in-place compress: `trash`); `recursive: false`; links never followed; UTF-8; `Store.memory()`. `Duration.zero` is never "none". |
| 23 | **One word per idea:** `to:` a file, `into:` a folder (exactly one of them), `conflict:`, `original:`, `only:`/`ignore:`/`gitignore:`/`hidden:`, `concurrency:`, `retry:`, `store:`, `timeout:`, `unsafe:`, `title` first positional, `label`, `step`. Type parameters are `<I, T>`, item first. Callbacks are `on<Event>`. |
| 24 | **One way to remember:** `store:` on everything that keeps state between runs, and a typed `Key<T>` for your own. The default writes nothing. Every write is atomic and the store's lock serialises writers; a feature's sub-store carries a version, and another version is a `FormatException` naming the folder. Starting over is `store.clear()`. A store keeps what is needed to continue, never results. |
| 25 | **Credentials are `Secret`s,** bound to an origin, never following a redirect elsewhere, printed as `•••` everywhere. |
| 26 | **Environment variables** are `DART_TOOLKIT_<NAME>`, read only through `Env`. |

## 5. Surface

| # | Rule |
|---|---|
| 27 | **Topic imports.** One public library per topic; a script imports what it uses. A topic re-exports `core` and the public libraries its own code imports; one whose code needs none of `Io`, `Store`, `Border`, `Detachable` and the `Terminal` seam builds on core's foundations (`src/base.dart`) and re-exports those (`src/foundations.dart`). Shared private code lives in one `lib/src/<name>.dart` reached through a hidden `…Internals`/`…Bridge`, never copied, never public. `test/layering_test.dart` enforces the graph. |
| 28 | **One name per operation; no aliases.** The public names are a reviewed list (`test/api_names.txt`). |
| 29 | **`X.read(path)`, `x.save(path)`, `X.parse(text)`, `X.decode(bytes)`, `x.encode()`** for every type with a file form; `save` comes from `Saveable`: a `Task<Path>`, atomic, `conflict:` (overwrite by default: the value in hand is the newer version), and it never makes folders. |
| 30 | **`String` carries conversions, never processing.** Conversion getters to library types stay (`'…'.path`, `.url`, `.json`, `.html`, `.xml`, `to<T>()`, the colours); text processing is Dart's `String` and `RegExp`. Natural order is `compareNatural`. |
| 31 | **Text with a grammar has an opt-in type:** `Mode`, `Glob`, `Css`, `XPath`, `JsonPath`, `Hex`, `Mime` are extension types that implement `String` and are checked when made (`'755'.mode`). Parameters stay `String`, so plain text works and a checked value passes. |
| 32 | **The absence doors:** a reading's `or:`, a nullable type argument (`to<int?>()`), and the thunk `(() => …).orNull` / `.or(v)`. A reading is total otherwise: it throws a `MissingException` naming what was missing. |
| 33 | **No `Object` parameter.** Every public parameter checks something: a sealed type, an enum, a typed value. |
| 34 | **Names are concise whole words** (allowlisted abbreviations only), with no filler verbs and never repeating their receiver. Siblings that do the same thing share one verb and one parameter order. |
| 35 | **The shared interfaces are one list** (`Task`, `Batch`, `Stream`, resource, `Work`, `Status`, `Store`, `Serializer`, `Saveable`, `Secret`, `Detachable`, scope, setting value, fake). A module implements them and adds no parallel one. |

## 6. Cleanup and robustness

| # | Rule |
|---|---|
| 36 | **One way to clean up: `work.defer`,** for user code and library code. Cleanups run once, last first, however the work ends; `work.ended` says how. One that throws is a `Warned`, never the outcome. The work is over only after its cleanups have run. |
| 37 | **Every long operation is atomic and cancellable.** Writes go to a temporary sibling renamed over the target (with the Windows retry); an overwrite is a rename over, never delete-first; a stopped operation leaves nothing half-done, a `.part` only where `resume:` keeps it. |
| 38 | **Folders are never in conflict:** they merge, and the policy applies to each file inside. A name `Conflict.rename` picks is claimed, so two items never pick one. |
| 39 | **A replaced original is never lost:** the result is in place before the original is trashed or deleted. `trash()` refuses where the platform would delete for good. |
| 40 | **Nothing lands in the working directory unless asked.** |
| 41 | **Untrusted archives are contained:** no entry escapes, no link is followed or written through, no setuid survives, output is capped; `unsafe: true` lifts it. |
| 42 | **A child never outlives a stop:** processes and browsers die as a tree on cancel, timeout and signal. The library installs no signal handling of its own; `Cli` decides. An interactive child owns the terminal and its ^C. |
| 43 | **Parse the real world,** bound every depth, and make an unterminated construct a `FormatException`, never a hang. Every in-house parser has a differential test against the reference package (dev only). |
| 44 | **Readings decide their policy:** `Shell.run(…).text` captures, `.output` streams; a response's readings in hand are lenient, `await url.get()` is strict. |

## 7. The terminal

| # | Rule |
|---|---|
| 45 | **Two UIs, never mixed:** `Console` (`cli`) prints inline above the scrollback; `Tui` (`tui`) owns the screen or an inline region. What both draw is a `Tally`, in the shared terminal library. A Tui app is `draw` and `update` only: everything that happens is an event named by one noun for what arrived (`Start`, `KeyPress`, `Pointer`, `Interrupt`, `Post`, never past tense or an `On`/`Event` affix), and its side effects are `Tui.post`/`listen`/`defer`/`focus`. |
| 46 | **Where lines go:** `info`/`ok`/`line` to stdout; `debug`, `warn`, `error`, prompts and everything an indicator draws to stderr. So `app --json \| jq` gets only data. |
| 47 | **A live region exists only on an ANSI terminal;** elsewhere each item writes one line when it ends. Durable lines print once, above the region, from the outermost display. |
| 48 | **Customization is a theme of builders over typed views,** with one shared `Palette`; the views have the same names in both UIs; an ASCII palette is picked where the terminal cannot draw Unicode. |
| 49 | **One seam per side effect,** each with a shipped fake: `Http.scope(client: Client.fake(…))`, `Shell.scope(runner: Runner.fake(…))`, `Io.scope(terminal: FakeTerminal(…), stdin:, stdout:, stderr:)` (`FakeTerminal` behind its own `testing.dart`), `Clock.scope(clock: Clock.fake())`, `Env.scope`, `Store.memory()`, `cli.test(args)`. |

## 8. Native

| # | Rule |
|---|---|
| 50 | **The native library does what Dart cannot do fast:** digests, archives, content decoding, legacy charsets, `chmod`, images, torrent hashing and the BitTorrent engine. No Dart fallback: without the library those calls are `UnsupportedError`. |
| 51 | **No binary in git, the package or CI.** `Native.install()` is the only thing that downloads (from the release `native-<source hash>`, checked against its `.sha256`) or compiles. `Native.check()` reads files only. |
| 52 | **An export change bumps its library's ABI** (`exports!(n)` and its `NativeHandle` together), so a stale library is refused at load; any change to `native/` wants a `make native-release`. |
| 53 | **Long native work runs on a worker** and checks a stop byte, so a cancel always works; a worker is never killed mid-call. A handle the GC frees has a `NativeFinalizer`; `close()` waits for work in flight. |
| 54 | **Cryptography beyond hashing is out of scope.** |

## 9. Performance

| # | Rule |
|---|---|
| 55 | **Measure back to back, or not at all.** Startup drifts and jumps in bands; a claim is medians of alternating rounds from one sitting (`tool/module_bench.dart`), and says when a delta is a band jump. `dart run` startup is the in-process front end, so measure cold `dart run`, never a cached kernel. A script that returns from `main` also waits for the front end's last background optimisations, one that exits (as `Cli.run` does) does not: measure both. |
| 56 | **A topic import costs at most 15 ms of startup over `core`.** The lever is what a library compiles: a module does not import another to add one method, and rarely used heavy code goes behind its own import (`xpath`, `pick`). `dart:ffi` costs every program that compiles it, so it is imported only where a native call is the only way. A library boundary costs too: split one only where an import then compiles less. |
| 57 | **Nothing third-party at runtime.** |
| 58 | **Small work stays on the caller; a batch goes to a worker,** and an isolate is sent only what it needs (closures built in top-level functions). |
| 59 | **Throughput is `make bench`:** AOT, one process per case with its own peak RSS; `make bench-check` fails on a regression. |

## 10. Tests, docs, release

| # | Rule |
|---|---|
| 60 | **A fixed bug keeps a test** that fails before the fix; a Windows-only change keeps a Windows test. A race that cannot fail on demand gets the strongest deterministic assertion available. |
| 61 | **Tests are one file per library** (plus `<module>_diff_test.dart` for replaced packages), groups named for what they test, shared fixtures in `test/support.dart`, no upper-bound timing assertions. |
| 62 | **Docs:** `README.md` is organised by use case (*I want to … → snippet → what to know*); reference detail lives in dartdoc. A doc comment says what the signature cannot: what it throws, which scope it reads, how it cancels. Every README example compiles (a test extracts them). |
| 63 | **No CI.** `make` (analyze, format, catch check, tests) is the gate, run by hand; a Windows run is a step of the release checklist, and every Windows-only path is in `PLAN.md` until it has run on a real PC. Nothing generated is committed. The version number is the owner's. |
