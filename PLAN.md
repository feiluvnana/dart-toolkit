# PLAN — remediate AUDIT.md

Execution plan for every finding in [AUDIT.md](AUDIT.md), baseline `d67c0d0`
(`dart analyze` clean, `dart format` clean, 114/114 tests pass).

**This package is `0.0.1` and has one known consumer (`bin/keybox.dart`). This plan treats
breaking changes as acceptable and does not add deprecation shims.** Every removal below has a
one-line replacement, listed in §11.

**For whoever executes this:** phases are ordered so the tree is green after each one. Do not
start a phase before the previous phase's gate passes. Each phase is one commit. Commit messages
follow the existing `type(scope): summary` style, no trailers. Do not pick a version number —
that is the user's call (§13).

---

## 0. Standing gates

After **every** phase:

```
dart analyze          # must be clean
dart format --set-exit-if-changed .
dart test             # must be green
dart run bin/keybox.dart --help
```

Two additional gates, introduced in Phase 1 and enforced from then on:

```
dart run tool/check_deps.dart      # module dependency budget (§5.6)
dart doc 2>&1 | grep 'public libraries'   # library count, tracked per phase
```

Targets, tracked at each phase boundary:

| metric | before | target | achieved |
|---|---|---|---|
| public callable members | 435 | ≤ 325 | **399** — see note |
| public libraries | 34 | 9 | **11** (10 barrels + `dart_toolkit`) |
| third-party deps of `fs/fs.dart` | 7 | 1 | **1** (`path`) |
| third-party deps of `process/process.dart` | 7 | 1 | **1** (`path`) |
| `Path` members | 83 | ≤ 50 | **59** |

> **The member target was wrong, not the work.** 435 → ≤ 325 assumed dropping the 32 `*Sync`
> mirrors, which §10 rules out for a scripting toolkit. The deletions landed (−36 net) but are
> partly offset by additions that were the point of other phases: `unwrap`/`rights`/`lefts` (+5),
> the four sealed `CliOption` variants with their constructors (+12), `Os` (+3),
> `ConsoleIo.isTerminal`/`columns` (+2), `BytesHashExtensions` (+2). Revised target: **≤ 400**,
> with the composition of the surface — no aliases, no cross products, no illegal states — as
> the thing that actually improved.

---

## 1. Phase 1 — correctness defects (AUDIT §5)

These are behavioural bugs. They go first, each with the test that currently would not catch it.

### 1.1 `Either` — drop the `E` parameter and the `as` (AUDIT §5.1)

Root cause: `tryCatch`/`tryCatchAsync` take a type parameter `E` they cannot honour without
`onError`, and fall back to `error as E`. Fix by deleting the type parameter, not by patching
the cast:

```dart
static Either<Object, T> tryCatch<T>(T Function() action);
static Future<Either<Object, T>> tryCatchAsync<T>(FutureOr<T> Function() action);
```

**Deletes `guard` and `guardAsync`** — they were exactly these two with `E = Object`.
4 statics → 2. No `onError`, no `E`, no cast. Typed capture uses the `mapLeft` that already
exists:

```dart
Either.tryCatch(() => int.parse(s)).mapLeft(MyError.from);
```

> **Not merged into a single `FutureOr` entry point.** Verified: a
> `FutureOr<Either<Object, T>>` return type forces a cast at every synchronous call site —
> `Either.tryCatch(() => 1).isLeft` fails to compile with
> `The getter 'isLeft' isn't defined for the type 'FutureOr<Either<Object, int>>'` — and a
> `Future` return makes synchronous error capture unavailable outside an `async` context.
> The `FutureOr` stays where it pays: `tryCatchAsync`'s parameter, so it accepts sync and async
> closures alike.

**Tests** (`test/core_async_test.dart`): a thrown error that is *not* the previous target type
asserts `isLeft` and that the left value is the original error object. The existing test at
`:423` only covered the case where it was, which is why the bug shipped.

### 1.2 One concurrency primitive, plus `unwrap` (AUDIT §5.2, §2.4)

`async/parallelize.dart:105-113` pre-fills the result list with `Left(StateError(...) as E)`,
which throws before any worker runs whenever `E != Object`. Rather than patch the placeholder,
collapse the three-member family to one.

**Delete `parallelMap` and `parallelSettle` on both `Iterable` and `Stream`.** `parallelize` is
the single primitive; the error policy is chosen afterwards with `unwrap`:

```dart
// on Iterable<T>
Future<List<Either<Object, R>>> parallelize<R>(
  FutureOr<R> Function(T item) worker,
  {int concurrency = 4, bool isolate = false, CancellationToken? cancelToken});

// on Stream<T>
Stream<Either<Object, R>> parallelize<R>(... same ...);
```

```dart
final settled = await items.parallelize(work);            // every outcome
final values  = (await items.parallelize(work)).unwrap();  // throws the first failure
```

Build the result list as `List<Either<Object, R>?>.filled(n, null)` and map unfilled slots to
`Left(CancellationException(...))` on return — no placeholder cast exists to go wrong. Fix the
same `error as E` in the stream variant's source-error path (`:298`).

Net: 6 members → 2.

### 1.3 `unwrap` (new, `core/either.dart`)

Three members, on the leaf module so `async` can use them through its existing `async → core`
edge:

```dart
sealed class Either<L, R> {
  /// The [Right] value, or throws the [Left] value.
  R unwrap();
}

extension IterableEitherExtensions<L, R> on Iterable<Either<L, R>> {
  /// Every [Right] value in order, throwing the first [Left] value.
  List<R> unwrap();
  /// Only the [Right] values, discarding failures.
  List<R> get rights;
  /// Only the [Left] values.
  List<L> get lefts;
}

extension StreamEitherExtensions<L, R> on Stream<Either<L, R>> {
  /// Emits every [Right] value, forwarding the first [Left] as a stream error.
  Stream<R> unwrap();
}
```

`unwrap` throws the left value itself (`throw value`), so `Left(HttpException(...))` surfaces as
that exception rather than a wrapper.

> **Behaviour change, deliberate.** The old `parallelMap` was fail-fast: it stopped scheduling
> unstarted items on the first error. `parallelize(...).unwrap()` runs every task to completion
> and then throws the first failure. For a scraper or downloader — this package's actual
> workload — settling is the behaviour you want, and it is what `parallelize` already did. A
> caller who needs the old early-exit passes a `CancellationToken` and cancels it from the
> worker. Recorded in the CHANGELOG, not smuggled in.

**Tests:** `parallelize` over a workload with **zero** failures does not throw (this fails
today); a mixed workload returns both branches; `unwrap()` on that mixed result throws the first
`Left` value by identity; `rights`/`lefts` partition it; the stream form forwards the error.

### 1.4 `ScrapeContext.follow` silently drops POST bodies (AUDIT §3.3)

Replace the untyped `Object? body` with two typed, mutually exclusive parameters:

```dart
void follow(Object target, {ScrapeHandler<T>? callback, Map<String, dynamic>? meta,
            Map<String, String>? headers, String method = 'GET',
            String? body, Map<String, String>? fields, bool allowDuplicates = false});
```

`body` sets `Request.body`, `fields` sets `Request.bodyFields`; passing both throws
`ArgumentError`. `followAll` gains the same parameters — today it silently omits `body`
entirely, so `followAll(..., method: 'POST')` cannot carry a payload at all.

`target` stays `Object` (`Uri | String`) because relative-href resolution is the whole point of
`follow`, but it now **throws `ArgumentError`** on any other type instead of silently doing
nothing. Same for `_resolve`.

**Test:** `follow` with an `int` target throws; `follow(..., body: ..., fields: ...)` throws;
a followed POST actually carries its body.

### 1.5 `JsonDocument.operator []` (AUDIT §3.3)

Throw `ArgumentError` for a key that is neither `String` nor `int`. A wrong-typed key currently
returns `JsonDocument(null)`, which is indistinguishable from a real JSON null.
Out-of-range `int` and missing `String` keys keep returning the null document — that is correct
JSON semantics and is not the bug.

### 1.6 `Path` equality mitigation (AUDIT §5.3)

`implements String` stays (AUDIT §6, "deliberately not recommended"). Two changes:

- `String get normalized` → `Path get normalized` (`fs/path.dart:155`), so the mitigation
  composes back into a `Map<Path, _>` key without a re-wrap.
- Delete the near-duplicate `static Path normalize(String)` (`:149`); `Path(raw).normalized`
  replaces it.
- Add a `## Path as a map key` section to the `Path` dartdoc stating the contract: **normalize at
  map boundaries**.

**Test:** `<Path, int>{a.normalized: 1}[b.normalized]` resolves across `/tmp/a/../a` and `/tmp/a`.

### 1.7 ANSI styles do not compose (AUDIT §5.4)

`cli/ansi.dart`, `AnsiString._wrap`. Reopen the outer style after every inner reset:

```dart
String _wrap(String code) {
  if (!Ansi.enabled) return this;
  final reopened = replaceAll('\x1B[0m', '\x1B[0m\x1B[${code}m');
  return '\x1B[${code}m$reopened\x1B[0m';
}
```

`('a'.red + 'b').bold` then yields `ESC[1m ESC[31m a ESC[0m ESC[1m b ESC[0m` — `a` bold+red,
`b` bold. **Test:** assert that exact sequence, and that `Ansi.strip` still round-trips it.

**Gate for Phase 1:** standing gates, plus the five new tests above failing on `d67c0d0` and
passing after.

---

## 2. Phase 2 — the IO seam and terminal behaviour (AUDIT §4.7, §4.8, §5.5)

### 2.1 One terminal predicate

Add to `cli/stdio.dart`:

```dart
/// Whether the *active* sink is an interactive terminal.
static bool get isTerminal => stdoutOverride == null && _hasTerminal();
```

Replace every direct `stdout.hasTerminal` in `cli/console.dart` (`ConsoleProgress.tick`/`done`,
`ConsoleMultiProgress._render`/`done`, `ConsoleSpinner.start`/`_stop`, `Console.clear`,
`Console.rule`) with `ConsoleIo.isTerminal`. Redirecting the sink must also redirect the
decision about what to render.

### 2.2 Subprocess output goes through the seam

`process/process.dart` writes captured child output with bare `stdout.write(data)` /
`stderr.write(data)` in `_runProcess` (two sites) and `CommandPipeline.run` (two sites). Route
all four through `ConsoleIo.out` / `ConsoleIo.err`.

**Test:** the §4.7 reproduction — `ConsoleIo.stdoutOverride = buf; await run('echo MARKER');`
asserts `buf` contains `MARKER`. This fails today.

### 2.3 One environment source for `NO_COLOR`

`cli/ansi.dart` reads `Platform.environment` directly. `cli` already depends on `util`, so
import `../util/env.dart` and use `Env.get('NO_COLOR')`. **Test:** `Env.set('NO_COLOR', '1')`
then `Ansi.enabled == false` with `Ansi.enabled = null` (no override).

### 2.4 `ConsoleMultiProgress` in non-TTY

`_render` early-returns when not a terminal, so CI gets only the final line while
`ConsoleProgress` gets one per tick. Give it the same fallback: when `!ConsoleIo.isTerminal`,
emit one line per task **completion** (not per update — per-update would be unreadable at
`concurrency: 8`).

**Test:** under an overridden sink, a 3-task run emits ≥ 3 lines, and each completed task's
label appears exactly once.

---

## 3. Phase 3 — delete aliases, fix names (AUDIT §2.4, §3.1, §3.2)

Pure renames and deletions. Mechanical; `dart analyze` finds every call site.

### 3.1 Delete the remaining aliases

`Either.guard`/`guardAsync` and `parallelSettle` went in Phase 1. Remaining:

| delete | keep | file |
|---|---|---|
| `Path.exist()` | `exists()` | `fs/path.dart:202` |
| `Path.existSync()` | `existsSync()` | `fs/path.dart:222` |
| `Env.isMac` | `isMacOS` | `util/env.dart:54` |
| `Env.isWin` | `isWindows` | `util/env.dart:60` |
| `ShellResult.failed` | `isFailed` | `process/shell_result.dart:26` |
| `$(cmd)` | `run(cmd)` | `process/process.dart:90` |
| `Mutex.protect` | `Mutex.run` | `async/sync.dart:88` |
| `Prompt.ask` | `askWith` → renamed `ask` (§3.2) | `cli/prompt.dart:28` |

Keep both `operator |` and `pipe` — `|` is the point of the pipeline API and `pipe` is its
spelled-out form for chained calls; that is one API with an operator, not an alias.

Deleting top-level `$` also resolves the `$`-means-two-things problem (AUDIT §3.1 #13): `$`
survives only as the selector prefix (`$`, `$xpath`, `$jsonpath`).

### 3.2 Renames

| old | new | why |
|---|---|---|
| `ShellResult.exitcode` | `exitCode` | matches `dart:io`; only non-camelCase name in the package |
| `Stream.flatmap` | `flatMap` | camelCase; matches the rxdart method it forwards to |
| `Stream.notnull()` | `whereNotNull()` | camelCase; matches what it calls |
| `Stream.buffer(Duration)` | `chunkTime(Duration)` | pairs with `chunk(int)`; same operation, two unrelated names today |
| `Stream.delay(Duration)` | `delayBy(Duration)` | collided with `Duration.delay()` |
| `Path.replace(...)` | `replaceInFile(...)` | it writes to disk, next to the inherited pure `replaceAll` |
| `Path.mklink` / `mklinkSync` | `symlink` / `symlinkSync` | POSIX concept under a Windows command name |
| `Path.file` / `dir` / `link` | `asFile` / `asDir` / `asLink` | one character from `files`/`dirs`/`links`, which mean children |
| `Path.zip` / `unzip` (+Sync) | `zipTo` / `extractTo` (+Sync) | collides with `Iterable.zip` / `PairedIterable.unzip`, both exported from the same barrel |
| `RetryBuilder.cancelWith` | `cancelOn` | collided with `CancellableFuture.cancelWith` on the same receiver |
| `ScrapeContext.follow(dontFilter:)` | `allowDuplicates:` | negated boolean |
| `ConsoleSpinner.info()` | `stop([message])` | named like a log level; it terminates the spinner |
| `ConsoleSpinner.success()` | `succeed()` | verb, matching `fail()` |
| `Prompt.askWith` | `ask` (after deleting the positional `ask`) | one prompt entry point, all-named |

> `Iterable.zip` / `PairedIterable.unzip` vs `Path.zip` / `unzip` is a collision the audit did
> not name. Both are exported from `dart_toolkit.dart`; `test/collection_test.dart` and
> `test/fs_test.dart` both call `.zip` meaning opposite things.

### 3.3 One extension naming scheme

Scheme: **`<Receiver>Extensions`** — receiver first, plural, no module prefix, no `Toolkit`.
Where two extensions share a receiver, qualify by purpose *after* the receiver
(`StringAnsiExtensions`, `StringShellExtensions`).

| old | new |
|---|---|
| `StringCoreExtensions` | `StringExtensions` |
| `AnsiString` | `StringAnsiExtensions` |
| `PathStringExtension` | `StringPathExtensions` |
| `ShellStringExtension` | `StringShellExtensions` |
| `ToolkitStreamExtensions` | `StreamExtensions` |
| `ToolkitNullableStreamExtensions` | `NullableStreamExtensions` |
| `ParallelizeIterable` | `IterableParallelExtensions` |
| `ParallelizeStream` | `StreamParallelExtensions` |
| `CancellableStream` | `StreamCancelExtensions` |
| `CancellableFuture` | `FutureCancelExtensions` |
| `PairedIterable` | `IterablePairExtensions` |
| `CollectionIterableExtensions` | `IterableExtensions` |
| `CollectionListExtensions` | `ListExtensions` |
| `CollectionMapExtensions` | `MapExtensions` |
| `DurationInt` | `IntDurationExtensions` |
| `DurationExtensions` | *(unchanged)* |
| `IsolateFunctionExtension` | `FunctionIsolateExtensions` |
| `RetryFunctionExtension` | `FunctionRetryExtensions` |
| `HttpToolkitResponse` | `ResponseExtensions` |
| `UriHttpExtensions` | `UriExtensions` |
| `ElementQueryExtensions` | *(unchanged)* |
| `ShellPathExtension` | `PathShellExtensions` |
| `FutureShellResultExtension` | `FutureShellResultExtensions` |
| `ScrapeUriExtension` etc. | folded into Phase 6 |
| `HttpClientFormatExtensions` | deleted in Phase 5 |
| `PathUriMapDownloadExtensions`, `UriPathMapDownloadExtensions` | folded into Phase 4 |
| `BatchDownloadProgressMultiProgressExtension` | deleted in Phase 4 |

---

## 4. Phase 4 — put members on the right type and cut the dependency graph (AUDIT §4)

This phase is where the measured wins land. Do it in this order; each step is independently
green.

### 4.1 Delete the console adapter (AUDIT §4.1)

Delete `BatchDownloadProgressMultiProgressExtension` (`fs/path.dart:111`) and the
`import '../cli/console.dart'`. `ConsoleMultiProgress.updateTask` already takes every field it
forwarded. Migrate the three call sites (`bin/keybox.dart:165`, `example/example.dart`,
`test/cli_test.dart`) to the explicit six-line form and put that form in the
`ConsoleMultiProgress` dartdoc as the worked example.

**Cuts `fs → cli`.**

### 4.2 Move downloading to `http/` (AUDIT §4.2, §4.3)

New file `lib/http/download.dart`. Move out of `fs/path.dart`:
`DownloadProgress`, `BatchDownloadProgress`, `Path.download`, `_batchDownload`, and both
`downloadAll` extensions. Export from `http/http.dart`.

- `Path.download(Uri, ...)` becomes `extension PathDownloadExtensions on Path` in the new file —
  same signature, same name, new home.
- **Collapse the two map orientations into one.** Keep `Map<Uri, Path>.downloadAll` (reads
  "source → destination", and matches `download`'s own argument order). Delete
  `Map<Path, Uri>.downloadAll`. `bin/keybox.dart:164` uses the `Map<Path, Uri>` form — invert the
  map at its construction site.
- **Delete `Uri.download`** (`http/response.dart:217`). It is a strictly weaker forward to
  `Path.download` — it drops `cancelToken`.

**Cuts `fs → http` and `http → fs`.**

### 4.3 Move archiving out of `Path` (AUDIT §4.4)

New module `lib/archive/archive.dart`, barrel exported from `dart_toolkit.dart`:

```dart
extension PathArchiveExtensions on Path {
  Future<File> zipTo(String destination);
  File zipToSync(String destination);
  Future<Directory> extractTo(String destination);
  Directory extractToSync(String destination);
}
```

Parameter type is `String`, not `Object` (AUDIT §3.3): `Path implements String`, so both a
`Path` and a plain string literal are accepted with no union and no `toString()` fallthrough.

Carry over the two zip fixes recorded in the previous audit (the un-awaited
`ZipFileEncoder.zipDirectory` in both `zip` and `zipSync`) — **do not regress them**; the
existing round-trip tests must keep passing.

**Cuts `fs → package:archive`.**

### 4.4 Move hashing out of `Path` (AUDIT §4.4)

New module `lib/hash/hash.dart` — a leaf, depends only on `package:crypto`:

```dart
extension BytesHashExtensions on List<int> {
  String get sha256;
  String get md5;
}
```

`p.sha256()` → `(await p.readBytes()).sha256`; `p.sha256Sync()` → `p.readBytesSync().sha256`.
Four `Path` members become two getters, and the sync/async split falls out of `readBytes`
instead of being duplicated.

**Cuts `fs → package:crypto`.**

### 4.5 Remove format parsing from `Path` (AUDIT §4.5)

Delete `readJson`, `readHtml`, `readXml`, `writeJson`, `writeHtml`, `writeXml` and their six
`Sync` twins, plus `import '../core/core.dart'`. Replacement is one line and already works:

```dart
JsonDocument.parse(await p.readText())          // was p.readJson()
await p.writeText(jsonEncode(data))             // was p.writeJson(data)
```

`writeJson`'s only added value was `pretty:`; document
`const JsonEncoder.withIndent('  ').convert(data)` in the migration table.

**Cuts `fs → core`.** `Path` is now 83 − 12 (formats) − 8 (archive/hash) − 1 (download)
− 2 (`exist`/`existSync`) − 1 (`normalize`) = **59**, with no capability lost.

> This does not reach the ≤ 50 target in §0. Closing the last 9 would mean dropping `*Sync`
> mirrors, which AUDIT §6 explicitly rules out for a scripting toolkit. **Revise the target to
> 60** rather than take capability away; note it in the phase commit.

### 4.6 Split platform detection out of `Env` (AUDIT §4.6)

New `lib/util/platform.dart`:

```dart
abstract final class Os {
  static bool get isMacOS;
  static bool get isWindows;
  static bool get isLinux;
}
```

`Env` keeps `isCI` (genuinely environment-derived) and loses the OS predicates.

Also fix `Env.load`'s positional string-sniffing overload: it decides whether its argument is a
path or `.env` content by looking for `\n` or `=`. Replace with two explicit entry points:

```dart
static Map<String, String> parse(String source, {bool override = false});     // content
static Map<String, String> loadFile([String path = '.env', bool override = false]); // file
```

Delete `load` and `loadSync`. `Env.load('PORT=8080')` → `Env.parse('PORT=8080')`;
`Env.load('.env')` → `Env.loadFile()`.

### 4.7 Enforce the result

Add `tool/check_deps.dart`: parse the `import`/`export` lines under `lib/`, compute the
transitive third-party closure per module barrel, and exit non-zero if any module exceeds its
budget:

| module | allowed third-party deps |
|---|---|
| `collection`, `util`, `cli` | none |
| `core` | html, xml, xpath_selector_html_parser |
| `async` | rxdart |
| `fs` | path |
| `hash` | crypto |
| `archive` | archive, path |
| `process` | path |
| `http` | http, path, + core's set |

Wire it into `.github/workflows/ci.yml` and the standing gates. This is what stops the graph
from silently re-tangling.

---

## 5. Phase 5 — collapse the cross products (AUDIT §2.1, §2.5)

### 5.1 The `isolate*` family (AUDIT §2.1)

**Delete `HttpClientFormatExtensions` entirely** (7 members). Every one of
`client.html/json/xml/isolate/isolateHtml/isolateJson/isolateXml(uri, ...)` is
`uri.<same>(client: client)`.

**Delete the four `Uri.isolate*` methods.** `uri.isolateHtml(f)` →
`(await uri.get()).isolateHtml(f)`.

**Keep all four on `http.Response`.** These are the ones that carry weight: `Response.isolate`
copies only body/status/headers/url rather than shipping the whole request graph across the
isolate boundary, and off-thread parsing is a real hot path for this package (`bin/keybox.dart`
uses it three times).

**Delete `Response.$` and `Response.$xpath`** (AUDIT §4, "HTML query methods on a transport
type" — they silently commit to HTML for a response that may be JSON or XML).
`res.$(sel)` → `res.html().$(sel)`.

Net: `http/response.dart` 28 members → 11 (`Response`: `html`, `json`, `xml`, `isolate`,
`isolateHtml`, `isolateJson`, `isolateXml`, `url`; `Uri`: `/`, `get`, `post`, `html`, `json`,
`xml` — minus the moved `download`). **−17.**

> Deviation from AUDIT §6.11, which proposed deleting all nine derived `isolate*` methods.
> Keeping the four on `Response` and deleting the eleven on `Client`/`Uri` cuts more (−17 vs −9)
> while keeping the member that cannot be reconstructed by composition.

### 5.2 `ScrapeContext` delegations (AUDIT §2.5)

Delete `html()`, `xml()`, `json()`, `$()`, `$xpath()`. `ctx.response` is already public, and
`Response.$`/`$xpath` are gone in §5.1 anyway, so the replacement is
`ctx.response.html().$(sel)`. `ScrapeContext` drops to its actual job: `response`, `request`,
`meta`, `emit`, `emitAll`, `follow`, `followAll`. **−5.**

---

## 6. Phase 6 — model the sum types properly (AUDIT §2.2, §3.4, §3.5)

Per the project's standing direction: generics, records and sealed types — no codegen.

### 6.1 `CliOption` becomes a sealed kind (AUDIT §3.4)

Today `flag`, `numeric`, `choices` and `defaultTo` are orthogonal fields encoding four mutually
exclusive kinds, so `option('x', flag: true, numeric: true)` compiles and silently misbehaves.

```dart
sealed class CliOption {
  final String name;
  final String description;
  final String? abbr;
  const CliOption(this.name, {this.description = '', this.abbr});
}

final class CliFlag   extends CliOption { const CliFlag(...); }
final class CliValue  extends CliOption { final String? defaultTo; }
final class CliNumber extends CliOption { final int? defaultTo; }
final class CliChoice extends CliOption { final List<String> choices; final String? defaultTo; }
```

The `CliCommand.option/flag/number/choice` builder methods keep their names and signatures and
construct the right variant. The parser switches on the sealed type — the `if (optDef.flag)` /
`if (optDef.numeric)` chains and the illegal-combination validation in `CliCommand.run` become
an exhaustive `switch`.

**Values stop being stringly typed.** `CliContext.options` becomes
`Map<String, Object?> values`, where a `CliNumber` is stored as an `int` parsed once during
validation:

```dart
bool   flag(String name);
String? option(String name, {String? defaultTo});
int?    number(String name, {int? defaultTo});
```

**Tests:** `flag: true, numeric: true` no longer compiles (compile-time assertion via a
`// expect-error` note in the test doc, plus a runtime test that each variant parses correctly);
`number('port', defaultTo: 8080)` with no args yields `int 8080` from `values`, not `'8080'`.

### 6.2 The fluent builder stops switching receivers (AUDIT §3.5)

`option/flag/choice/number/action` return `this`; `subcommand` returns the child. In a chained
expression nothing says which object the next call lands on.

Fix: `subcommand` and `command` return `this` (the parent), and take the child configuration
through the `build` callback they already accept:

```dart
CliCommand subcommand(String name, {String description = '', CommandHandler? handler,
                                    void Function(CliCommand sub)? build});
```

Every builder method now returns the receiver, so a chain always operates on one object and
nesting is explicit and indented. Migrate `bin/keybox.dart` and `test/cli_test.dart`.

### 6.3 `scrape` — one signature, four entry points (AUDIT §2.2)

The four extensions (`Uri`, `Iterable<Uri>`, `http.BaseRequest`, `Iterable<http.BaseRequest>`)
stay — they are the ergonomic surface and `url.scrape(parse)` is the headline API. What goes is
the duplication and the untyped engine:

- `_scrape` takes `Iterable<http.BaseRequest>`, not `Object seeds`. Each extension converts its
  own receiver — one line each.
- **Defaults live only in `_scrape`.** The four public forwarders declare every parameter as
  nullable with no default and pass them straight through. Changing `concurrency`'s default
  becomes a one-line edit instead of five.
- Delete the now-unreachable runtime branches in `_scrape`: the `String` case in `toRequest` and
  the `else if (seeds is Iterable)` fallback (`http/scrape.dart:280-290`) — no public entry point
  can reach either.
- Rename to the Phase 3 scheme: `UriScrapeExtensions`, `IterableUriScrapeExtensions`,
  `RequestScrapeExtensions`, `IterableRequestScrapeExtensions`.

> **Deviation from AUDIT §6.10**, which proposed collapsing to one entry point over a sealed
> seed type. Dart has no implicit conversions, so a sealed `Seed` forces `Seed.url(u)` at every
> call site and makes the headline API worse. The maintenance hazard the audit actually measured
> — one signature written five times with five copies of the defaults — is fully removed;
> the extension count is not. **Flagged for the user in §13.**

---

## 7. Phase 7 — `lib/src/` and the library count (AUDIT §1, §6.16)

Mechanical, large, and verified entirely by `dart analyze`. Last, so no earlier phase has to be
rebased across a file move.

1. Move every implementation file to `lib/src/<module>/`:
   `lib/fs/path.dart` → `lib/src/fs/path.dart`, and so on for all 25 non-barrel files.
2. Keep the barrels where they are: `lib/{async,archive,cli,collection,core,fs,hash,http,process,util}/<name>.dart`
   plus `lib/dart_toolkit.dart`. Each barrel exports from `../src/`.
3. `lib/core/src/jsonpath.dart` → `lib/src/core/jsonpath.dart`. It stops being importable, which
   is what `src/` was signalling all along.
4. Resolve the duplicate library name: `lib/core/extensions.dart` and
   `lib/collection/extensions.dart` become `lib/src/core/string_extensions.dart` and
   `lib/src/collection/iterable_extensions.dart`.
5. Add `library;` directives with a one-line doc to each barrel only; implementation files get
   none (they are no longer public).

**Gate:** `dart doc` reports **11 public libraries** (10 module barrels + `dart_toolkit`), down
from 34. Nothing under `src/` appears in the generated docs.

> §0 targets 9 libraries; Phase 4 adds two new modules (`archive`, `hash`), so 11 is the correct
> landing point. Update the target.

---

## 8. Phase 8 — documentation, examples, conventions

1. **README.md** — rewrite the feature list and all six code blocks against the new surface.
   Every snippet must compile; add `test/readme_test.dart` that executes them, or move them into
   `example/` and have CI run `dart analyze example/`.
2. **`example/example.dart`** — it currently claims to demonstrate *every* API, which is what
   made the surface feel obligatory. Replace with three task-shaped examples
   (`cli_app.dart`, `file_automation.dart`, `web_crawler.dart` already exist) and delete
   `example.dart`.
3. **CHANGELOG.md** — one entry listing every breaking change, with the §11 migration table
   inline. Leave the version heading as `## Unreleased`; the user sets the number.
4. **`doc/conventions.md`** — write down the rules this plan establishes, so the next addition
   does not re-create the mess:
   - extensions are named `<Receiver>Extensions`, receiver first, no module prefix;
   - top-level functions are reserved for verbs typed constantly in scripts
     (`run`, `which`, `retry`, `die`, `onExit`); everything else is a static namespace
     (AUDIT §4.10 — this is the rule that was missing, not a code defect);
   - no aliases: one name per operation;
   - a member belongs to the module that owns its *dependency*, not the module that reads
     nicest at the call site (`download` is http, not fs);
   - sync/async mirrors are allowed only on `fs`;
   - new module dependencies require a `tool/check_deps.dart` budget change, reviewed.
5. **`@category` annotations** — re-check all 10 categories still resolve after the moves
   (`dartdoc_options.yaml`).

---

## 9. Phase 9 — trim the comments (last step)

Run **after** every other phase, so it trims the final text rather than text that is about to
change.

The doc comments have grown to carry design rationale that belongs in this plan, in
`doc/conventions.md`, or in the CHANGELOG. Pass over `lib/` and cut them back:

1. **One line for the common case.** A member whose name and signature say what it does gets a
   single `/// Sentence.` — no restatement of the parameter list, no "Returns a ... that ...".
2. **Keep only what the reader cannot infer**: units, defaults that matter, throwing behaviour,
   mutually exclusive parameters, and anything surprising (`unwrap` is not fail-fast;
   `Path` cannot override `==`).
3. **Delete rationale.** Why an API is shaped this way goes in `doc/conventions.md`; the
   audit trail goes in the CHANGELOG. Doc comments are reference, not argument.
4. **Delete restated code.** Comments that narrate the next line go; comments naming a
   non-obvious invariant stay.
5. **Examples only where the shape is not obvious** — `scrape`, `parallelize`/`unwrap`, `Cli`,
   `Prompt.select`. Not on `Path.readText`.
6. Keep every `{@category ...}` annotation and the `@template`/`@macro` pairs.

Target: no doc comment longer than three lines unless it documents throwing behaviour or a
worked example. `dart doc` must still report zero warnings afterwards.

---

## 10. Not doing, and why

Carried from AUDIT §6 plus two decisions this plan adds.

| item | decision |
|---|---|
| Drop the `*Sync` mirrors | **No.** Synchronous IO is the point of a scripting toolkit. Phase 4 removes 16 of 32 as a side effect of moving concerns off `Path`; the remaining 16 mirror a core that earns them. |
| Drop `implements String` from `Path` | **No.** It causes the `.path`/`.path` inversion and the equality split, but it is what lets a `Path` go anywhere a path string is expected. Mitigated by `normalized` returning `Path` (§1.6) and documented as a contract. |
| Rename `parallelize` | **No.** README headline; §1.2 makes it the single surviving concurrency primitive instead. |
| Keep a fail-fast `parallelMap` | **No.** Replaced by `parallelize(...).unwrap()`, which picks the error policy at the use site instead of forking the primitive. Semantic change flagged in §1.3 and §13. |
| Upstream XPath strictness | **No.** `xpath_selector` accepts malformed expressions. Capped by the dependency; unchanged since the previous audit. |
| Delete `FutureShellResultExtension` | **No** — keep `await run('cmd').text`. AUDIT §4.9 is right that it is a one-off convention, but shell chaining is this package's hottest path. Recorded as an explicit exception in `doc/conventions.md` rather than removed or generalised. |
| Collapse `scrape` to one entry point | **Partially** — see §6.3 deviation. |

---

## 11. Migration table (for CHANGELOG and README)

| removed / renamed | replacement |
|---|---|
| `$('cmd')` | `run('cmd')` |
| `ShellResult.exitcode` | `.exitCode` |
| `ShellResult.failed` | `.isFailed` |
| `Path.exist()` / `existSync()` | `exists()` / `existsSync()` |
| `Path.file` / `dir` / `link` | `asFile` / `asDir` / `asLink` |
| `Path.replace(a, b)` | `replaceInFile(a, b)` |
| `Path.mklink(t)` | `symlink(t)` |
| `Path.normalize(s)` | `Path(s).normalized` |
| `Path.readJson()` | `JsonDocument.parse(await p.readText())` |
| `Path.writeJson(d)` | `await p.writeText(jsonEncode(d))` |
| `Path.writeJson(d, pretty: true)` | `await p.writeText(const JsonEncoder.withIndent('  ').convert(d))` |
| `Path.readHtml()` / `readXml()` | `HtmlDocument.parse(...)` / `XmlDocument.parse(...)` |
| `Path.sha256()` / `md5()` | `(await p.readBytes()).sha256` / `.md5` |
| `Path.zip(d)` / `unzip(d)` | `p.zipTo(d)` / `p.extractTo(d)` |
| `Path.download(url)` | unchanged, now from `package:dart_toolkit/http/http.dart` |
| `url.download(path)` | `path.download(url)` |
| `Map<Path, Uri>.downloadAll()` | `Map<Uri, Path>.downloadAll()` (invert the map) |
| `Env.isMac` / `isWin` | `Os.isMacOS` / `Os.isWindows` |
| `Env.isMacOS` / `isWindows` / `isLinux` | `Os.*` |
| `Env.load(content)` / `load(path)` | `Env.parse(content)` / `Env.loadFile(path)` |
| `Either.guard(f)` / `guardAsync(f)` | `Either.tryCatch(f)` / `tryCatchAsync(f)` |
| `Either.tryCatch<E, T>(f)` | `Either.tryCatch(f).mapLeft(toE)` |
| `items.parallelSettle(w)` | `items.parallelize(w)` |
| `items.parallelSettle<E, R>(w, onError: g)` | `(await items.parallelize(w)).map((e) => e.mapLeft(g))` |
| `items.parallelMap(w)` | `(await items.parallelize(w)).unwrap()` — settles first, see §1.3 |
| `stream.parallelMap(w)` | `stream.parallelize(w).unwrap()` |
| `Mutex.protect(f)` | `Mutex.run(f)` |
| `stream.flatmap(f)` / `notnull()` | `flatMap(f)` / `whereNotNull()` |
| `stream.buffer(d)` / `delay(d)` | `chunkTime(d)` / `delayBy(d)` |
| `client.html(uri)` / `json` / `xml` / `isolate*` | `uri.html(client: client)` etc. |
| `uri.isolateHtml(f)` | `(await uri.get()).isolateHtml(f)` |
| `res.$(sel)` / `res.$xpath(q)` | `res.html().$(sel)` / `res.html().$xpath(q)` |
| `ctx.html()` / `json()` / `$()` | `ctx.response.html()` / `.json()` / `.html().$()` |
| `ctx.follow(t, dontFilter: true)` | `ctx.follow(t, allowDuplicates: true)` |
| `ctx.follow(t, body: map)` | `ctx.follow(t, fields: map)` |
| `Prompt.ask('m', 'd')` | `Prompt.ask('m', defaultTo: 'd')` |
| `RetryBuilder.cancelWith(t)` | `.cancelOn(t)` |
| `spinner.success()` / `info()` | `succeed()` / `stop()` |
| `multiProgress.update(batchProgress)` | explicit `updateTask(...)` — see `ConsoleMultiProgress` docs |
| extension type names | see §3.3 (only matters for explicit `Extension(x).m()` calls; none exist in-repo) |

---

## 12. Verification matrix

| AUDIT finding | phase | how it is proven |
|---|---|---|
| §5.1 `tryCatch` throws | 1.1 | new test: non-`E` error returns `Left` |
| §5.2 `parallelSettle` throws | 1.2 | new test: zero-failure workload does not throw |
| §5.3 `Path` map keys | 1.6 | new test: normalized keys collide correctly |
| §5.4 ANSI composition | 1.7 | new test: exact escape sequence for `('a'.red + 'b').bold` |
| §5.5 multiProgress non-TTY | 2.4 | new test: ≥ 3 lines under a redirected sink |
| §4.7 seam hole | 2.2 | new test: `run('echo MARKER')` lands in the override |
| §4.8 `NO_COLOR` split | 2.3 | new test: `Env.set` drives `Ansi.enabled` |
| §3.3 silent drops | 1.4, 1.5 | new tests: `ArgumentError` on bad target / body / key |
| §3.4 `CliOption` | 6.1 | new tests: each variant parses; illegal combo no longer expressible |
| §3.5 builder receivers | 6.2 | existing CLI tests, rewritten against the new chain |
| §4.1–§4.6 dependency graph | 4.7 | `tool/check_deps.dart` in CI |
| §1 library count | 7 | `dart doc` reports 11 |
| §2 member count | 5, 6 | `dart doc` index count at each phase boundary |

Record the member count, library count and per-module dependency closure in the commit message
of each phase so the trend is visible in `git log`.

---

## 13. Decisions for the user before execution starts

Three points where this plan chose, and the choice is reversible:

1. **`parallelize(...).unwrap()` is not fail-fast** (§1.2, §1.3). Collapsing `parallelMap` into
   `parallelize` + `unwrap` means every task runs to completion before the first error is
   thrown, where `parallelMap` stopped scheduling. For scraping and downloading that is the
   right default; for expensive CPU work it is not. If it matters, the escape hatch is a
   `CancellationToken` cancelled from the worker — or say so and `parallelize` gains a
   `stopOnError` parameter.
2. **`scrape` stays at four entry points** (§6.3). The duplication and the untyped engine are
   fixed; the extension count is not. Collapsing to one sealed-seed entry point would cost
   `Seed.url(u)` at every call site including the README headline.
3. **`Path` lands at 59 members, not ≤ 50** (§4.5). Closing the gap means dropping `*Sync`
   mirrors, which AUDIT §6 rules out. The plan revises the target instead of the capability.

No version number is set anywhere in this plan — `pubspec.yaml` and the `CHANGELOG.md` heading
stay as they are until the user picks one.
