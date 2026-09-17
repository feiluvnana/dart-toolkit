# AUDIT — API surface

Audit of the public API of `dart_toolkit` at `d67c0d0`: is the implementation bloated, is the
surface concise, are things named right, and does each member live on the right type?

Baseline gates at time of audit: `dart analyze` clean · `dart format` clean · **114/114 tests pass**.
Nothing below is a build failure. Every claim marked **verified** was reproduced by running code
against the package, not inferred from reading the diff.

This file replaces the previous PLAN.md execution audit. The items that audit left open
(module independence, `Path` equality, unified error strategy, ANSI composition,
`ConsoleMultiProgress` in non-TTY, upstream XPath validation) are all carried forward here —
they turn out to be symptoms of the surface problems in §2–§4, not separate loose ends.

---

## 1. The surface, measured

From `dart doc` (authoritative, not a grep heuristic):

| | count |
|---|---|
| Public libraries | **34** |
| Public types | **68** (32 classes, 31 extensions, 1 extension type, 2 enums, 2 typedefs) |
| Public callable members | **435** (266 methods, 131 properties, 30 constructors, 8 top-level functions) |
| Implementation lines in `lib/` | 5 155 |

435 members over 5 155 lines is roughly **one public member per 12 lines of implementation**.
That ratio is the finding: almost nothing in this package is internal. There is no `src/`
boundary — `lib/core/src/jsonpath.dart` is the only file under `src/`, and it is *still* a
documented public library (`package:dart_toolkit/core/src/jsonpath.dart`) while `JsonPath`
itself is not exported from the barrel. So the one file that declares private intent is
public, and the type it declares is unreachable from the normal import.

Two of the 34 libraries are both named `extensions` (`lib/core/extensions.dart`,
`lib/collection/extensions.dart`).

The largest single type is `Path`: **83 members**, of which **32 are `*Sync` mirrors**.
Counting the `String` members it inherits via `extension type const Path(String) implements String`,
a `Path` offers roughly **140 completions**.

### 1.1 Module graph and its cost

```
collection  -> (none)
core        -> (none)
util        -> (none)
async       -> core, util
cli         -> util
fs          -> async, cli, core
http        -> async, core, fs, util
process     -> fs, util
```

Transitive third-party cost of importing one module:

| import | pulls in |
|---|---|
| `collection/collection.dart` | — |
| `util/util.dart` | — |
| `cli/cli.dart` | — |
| `async/async.dart` | rxdart |
| `core/core.dart` | html, xml, xpath_selector_html_parser |
| `fs/fs.dart` | **archive, crypto, html, http, path, xml, xpath_selector_html_parser** |
| `http/http.dart` | **archive, crypto, html, http, path, xml, xpath_selector_html_parser** |
| `process/process.dart` | **archive, crypto, html, http, path, xml, xpath_selector_html_parser** |

**Verified.** A consumer who wants only `$('git status')` compiles `package:archive`,
`package:crypto`, `package:html`, `package:xml` and an XPath engine. Three edges cause all of it,
and each is a single misplaced member — see §4.

---

## 2. Bloat: the same idea, expressed many times

### 2.1 The `isolate*` combinatorial family — 12 methods, 1 idea

`lib/http/response.dart` declares `isolate`, `isolateHtml`, `isolateJson`, `isolateXml` on
`http.Response`, then again on `http.Client`, then again on `Uri`. Twelve methods. Each of the
nine derived ones is two lines: fetch (or don't), then call the format parser inside
`Isolate.run`.

Counting the format getters on the same three types (`html()`, `json()`, `xml()` ×3), the module
spends **21 of its 28 members** on the cross product of {three formats + raw} × {three receivers}.

There are, right now, **eight** ways to fetch a URL and get a `JsonDocument`:

```dart
uri.json()                      client.json(uri)                  res.json()
uri.isolateJson(f)              client.isolateJson(uri, f)        res.isolateJson(f)
uri.isolate((r) => r.json())    client.isolate(uri, (r) => r.json())
```

A single `Future<R> isolate<R>(R Function() compute)` on the closure (which already exists as
`IsolateFunctionExtension`) plus `res.json()` composes to all of them. The cross product adds
no capability.

### 2.2 `scrape` — 4 identical extensions

`lib/http/scrape.dart` declares `ScrapeUriExtension`, `ScrapeIterableUriExtension`,
`ScrapeBaseRequestExtension`, `ScrapeIterableBaseRequestExtension`. All four declare the same
`Stream<T> scrape<T>(ScrapeHandler<T>, {concurrency, delay, client, maxRetries, cancelToken})`
and all four forward to `_scrape(Object seeds, ...)` — `lib/http/scrape.dart:242` — which
re-discovers the seed type at runtime anyway. The six-parameter signature is written out five
times; changing a default means editing five places.

The runtime dispatch is also partly dead: `toRequest` handles `String` seeds and there is an
`else if (seeds is Iterable)` fallback, but no public extension can reach either branch —
`Iterable<Uri>` already satisfies `Iterable<Object>`.

### 2.3 `Path` — the sync/format/concern matrix

83 members. The structure is a matrix, not a vocabulary:

| axis | members |
|---|---|
| read × {text, bytes, lines, json, html, xml} × {async, sync} | 12 |
| write × {text, bytes, lines, json, html, xml} × {async, sync} | 12 |
| list × {all, files, dirs, links, glob} × {async, sync} | 10 |
| archive/hash × {zip, unzip, sha256, md5} × {async, sync} | 8 |
| mutate × {mkdir, mklink, copy, move, delete, append, replace} × {async, sync} | 14 |

Every new format costs four members (`readX`, `readXSync`, `writeX`, `writeXSync`). The
composition that replaces them already exists and is one line:
`JsonDocument.parse(p.readTextSync())`.

### 2.4 Pure aliases — 15 members that carry no meaning

| alias | real member | file |
|---|---|---|
| `Path.exist()` | `exists()` | `fs/path.dart:202` |
| `Path.existSync()` | `existsSync()` | `fs/path.dart:222` |
| `Env.isMac` | `isMacOS` | `util/env.dart:54` |
| `Env.isWin` | `isWindows` | `util/env.dart:60` |
| `ShellResult.failed` | `isFailed` | `process/shell_result.dart:26` |
| `Iterable.parallelize` | `parallelSettle` | `async/parallelize.dart:130` |
| `Stream.parallelize` | `parallelSettle` | `async/parallelize.dart:311` |
| `$(cmd)` | `run(cmd)` | `process/process.dart:90` |
| `Mutex.protect` | `Mutex.run` | `async/sync.dart:88` |
| `String.operator \|` | `String.pipe` | `process/process.dart:355` |
| `CommandPipeline.operator \|` | `pipe` | `process/process.dart:233` |
| `Either.guard` | `tryCatch` with `E = Object` | `core/either.dart:55` |
| `Either.guardAsync` | `tryCatchAsync` with `E = Object` | `core/either.dart:46` |
| `Prompt.ask` | `askWith` | `cli/prompt.dart:28` |
| `Path.normalize` (static) | `Path.normalized` (getter) | `fs/path.dart:149,155` |

The previous audit kept these deliberately, on the grounds that `parallelize` is the README
headline. That argument holds for exactly one of them. The other fourteen are two spellings a
reader has to learn are the same thing.

### 2.5 `ScrapeContext` — 5 delegations

`html()`, `xml()`, `json()`, `$()`, `$xpath()` on `ScrapeContext` are one-line forwards to
`ctx.response`. The context already exposes `response`. Its actual job — `emit`, `emitAll`,
`follow`, `followAll`, `meta` — is 5 of its 13 members.

### 2.6 Nine `run`s

`run` (top-level shell), `$` (same), `String.run`, `Path.run`, `CommandPipeline.run`,
`Semaphore.run`, `Mutex.run`, `Mutex.protect`, `RetryBuilder.run`, `CliCommand.run`. Four
distinct meanings — execute a subprocess, execute under a lock, execute a retry loop, dispatch a
CLI command — behind one word, all reachable from one import.

---

## 3. Naming

### 3.1 Defects that will mislead a reader

| # | Name | Problem |
|---|---|---|
| 1 | `ShellResult.exitcode` | Not camelCase. `dart:io` spells it `exitCode` (`Process.exitCode`, top-level `exitCode`). This is the only such name in the package. |
| 2 | `Path.path` vs `String.path` | On a `Path`, `.path` returns `String`. On a `String`, `.path` returns `Path`. One identifier, inverse meanings. **Verified:** `'foo'.path.path.path` type-checks. |
| 3 | `Path.file` / `dir` / `link` vs `files` / `dirs` / `links` | Singular = a `dart:io` object for *this* path. Plural = a stream of *children*. One character apart, unrelated semantics. |
| 4 | `Path.replace(Pattern, String)` | Reads the file, substitutes, writes it back to disk. `Path implements String`, so the pure `p.replaceAll(a, b)` sits next to it in completion. One writes your disk, one doesn't. |
| 5 | `Path.normalize` (static factory, returns `Path`) vs `Path.normalized` (getter, returns `String`) | One letter apart; the getter loses the `Path` type. |
| 6 | `Stream.delay(Duration)` vs `Duration.delay()` | Same name; one shifts a stream's emissions, one awaits. Both in scope from the barrel. |
| 7 | `Stream.flatmap` | Should be `flatMap` — it forwards to rxdart's `flatMap`. Lowercase `m` breaks camelCase and the name it wraps. |
| 8 | `Stream.notnull()` | Should be `whereNotNull()` (what it calls) or mirror Dart 3's `nonNulls`. Not camelCase. |
| 9 | `Stream.chunk(int)` vs `Stream.buffer(Duration)` | Same operation — group items into lists — under two unrelated names, distinguished only by argument type. |
| 10 | `Path.mklink` | POSIX symlink creation under the Windows `mklink` command name, in a package that otherwise spells things out (`writeText`, `readBytes`). `symlink` is the concept. |
| 11 | `dontFilter` (`ScrapeContext.follow`) | Negated boolean. Scrapy's name, but `allowDuplicates` states the same thing positively. |
| 12 | `RetryBuilder.cancelWith` | **Verified collision.** `RetryBuilder<T> implements Future<T>`, so `CancellableFuture.cancelWith` is also in scope on the same object. `b.cancelWith(t)` → `RetryBuilder<T>` (aborts the retry loop); `(b as Future<T>).cancelWith(t)` → `Future<T>` (completes the outer future with an error, retries keep running). Same name, same receiver, different behaviour. |
| 13 | `$` | Means "run a shell command" (top-level) and "querySelectorAll" (`HtmlDocument.$`, `Element.$`, `Response.$`, `ScrapeContext.$`) in one namespace. |
| 14 | `ConsoleSpinner.info()` | Stops the spinner, like `success()` and `fail()`. Named like a log level. |
| 15 | `CliCommand.option/flag/number` vs `CliContext.option/flag/number` | The first three *declare*, the second three *read*. Identical names, adjacent types, opposite direction. |
| 16 | `BatchDownloadProgressMultiProgressExtension` | 43 characters, and it is an extension on a console widget declared in `fs/path.dart` (§4.1). |

### 3.2 No convention for extension names

31 extensions, six competing schemes:

- `<Type>Extension` — `ScrapeUriExtension`, `PathStringExtension`, `ShellPathExtension`
- `<Type>Extensions` — `CollectionListExtensions`, `ElementQueryExtensions`, `DurationExtensions`
- `Toolkit<Type>Extensions` — `ToolkitStreamExtensions`, `ToolkitNullableStreamExtensions`
- `<Verb><Type>` — `ParallelizeIterable`, `ParallelizeStream`
- `<Adjective><Type>` — `CancellableStream`, `CancellableFuture`, `PairedIterable`
- `<Noun><Type>` — `AnsiString`, `HttpToolkitResponse`

The module qualifier also flips order: `CollectionIterableExtensions` (module first) against
`StringCoreExtensions` (type first). And `Toolkit` is noise — the whole package is the toolkit.

`DurationInt` and `PathStringExtension` name the *result* before the receiver (`int → Duration`,
`String → Path`), the reverse of every other extension in the package.

### 3.3 `Object` as an untyped union

Five public parameters take `Object` where the real domain is a two- or three-way union. The
package otherwise leans on generics and sealed types.

| signature | real domain | failure mode |
|---|---|---|
| `ScrapeContext.follow(Object target)` | `Uri \| String` | anything else is silently dropped |
| `ScrapeContext.follow(body: Object?)` | `String \| Map<String,String>` | a POST with any other body type silently sends an empty body |
| `JsonDocument.operator [](Object keyOrIndex)` | `String \| int` | a wrong-typed key returns `JsonDocument(null)`, indistinguishable from a real null |
| `Path.zip(Object)`, `Path.unzip(Object)` | `Path \| String` | falls through to `toString()` |
| `Path.writeHtml(Object)`, `writeXml(Object)` | `HtmlDocument \| Stringable` | falls through to `toString()` |

`ScrapeContext.meta` is `Map<String, dynamic>` and `ShellResult.json` returns `dynamic` — the
only `dynamic`s left in the public API.

### 3.4 `CliOption` encodes a sum type as independent booleans

```dart
CliOption(name, {flag: bool, numeric: bool, choices: List<String>?, defaultTo: String?})
```

`flag`, `numeric` and `choices` are four mutually exclusive kinds (flag / string / number /
choice) modelled as orthogonal fields, so illegal states are representable.

**Verified:** `option('weird', flag: true, numeric: true)` constructs without complaint;
`--weird` yields `flags={weird}, options={}` and `ctx.number('weird') == null` — the `numeric`
declaration is silently inert. Adding `defaultTo: '7', choices: ['a','b']` to the same option
makes the parser throw `Invalid value "7"` for a flag that was never given a value.

Values also stay stringly typed after validation: `number('port', defaultTo: 8080)` produces
`ctx.option('port') == '8080'` as a `String`, re-parsed on every `ctx.number()` call.

### 3.5 The fluent builder switches receivers mid-chain

**Verified:** `CliCommand.option/flag/choice/number/action` return `this`;
`CliCommand.subcommand` returns the *child*. In a chained expression nothing at the call site
says which object the next call lands on.

---

## 4. Members on the wrong type or in the wrong module

### 4.1 `fs → cli` — one adapter, 608 lines of terminal code

`lib/fs/path.dart:111` declares `extension BatchDownloadProgressMultiProgressExtension on
ConsoleMultiProgress`, a 20-line method. To get it, `path.dart` imports `cli/console.dart`.

This one extension is why the filesystem module depends on the terminal module, and therefore
why `process` and `http` do too. It belongs in `cli/` if it is kept at all —
`ConsoleMultiProgress.updateTask` already accepts exactly the fields it forwards.

### 4.2 `http → fs` — one delegating method

`lib/http/response.dart:217`:

```dart
Stream<DownloadProgress> download(Path destination, {...}) =>
    destination.download(this, client: client, overwrite: overwrite);
```

`Uri.download` exists only so you can write `url.download(path)` instead of
`path.download(url)`. It is the sole reason `http/` imports `fs/`, and therefore why
`import 'package:dart_toolkit/http/http.dart'` compiles `package:archive` and `package:crypto`.
It also drops `cancelToken`, which `Path.download` accepts — so the alias is strictly weaker
than what it forwards to.

### 4.3 Downloading lives in the filesystem module

`DownloadProgress`, `BatchDownloadProgress`, `Path.download`, `Map<Path,Uri>.downloadAll` and
`Map<Uri,Path>.downloadAll` are all in `lib/fs/path.dart`. They are HTTP operations; they are
why `fs` imports `package:http`. They belong in `http/`, taking a `Path` as a parameter.

`downloadAll` is additionally declared twice, once per map orientation, for one operation.

### 4.4 Archiving and hashing live on `Path`

`zip`/`zipSync`/`unzip`/`unzipSync` and `sha256`/`sha256Sync`/`md5`/`md5Sync` are the only reason
`fs` depends on `archive` and `crypto`, and therefore the only reason `process` does.

**Combined effect of 4.1–4.4:** moving those four groups out would take `fs/fs.dart`'s
third-party dependencies from **7 to 1** (`package:path`), and `process/process.dart`'s from
**7 to 1**, with no capability lost.

### 4.5 Format parsing lives on `Path`

`readJson`, `readHtml`, `readXml`, `writeJson`, `writeHtml`, `writeXml` (12 members with their
`Sync` twins) put document-format knowledge on the path type, and are why `fs` imports
`core/core.dart`. `Path`'s job is locating and moving bytes.

### 4.6 `Env` is two unrelated things

`Env` owns environment *variables* — a mutable in-memory override map plus `get/set/require/has/
parse/load/all`. It also owns `isMacOS`, `isMac`, `isWindows`, `isWin`, `isLinux`: thin wrappers
over `Platform` that have nothing to do with the variable store. `isCI` is genuinely
env-derived and belongs.

`Env.load` additionally does file IO from `util/`, and decides whether its argument is a path or
`.env` content by sniffing for `\n` or `=` — a positional overload resolved by string inspection.
`Env.parse(Path('.env').readTextSync())` is the composition that already exists.

### 4.7 The `ConsoleIo` seam has a hole exactly where it matters

Every CLI component writes through `ConsoleIo` — except the subprocess runner.
`lib/process/process.dart` writes captured child output with bare `stdout.write(data)` /
`stderr.write(data)`.

**Verified:**

```
ConsoleIo.stdoutOverride = buf;
Logger.ok('via ConsoleIo');      // captured
await run('echo PROCESS_OUTPUT_HERE');  // printed to the real terminal
→ buffer = ['✓ via ConsoleIo']
→ process output captured? false
```

Separately, the progress widgets *write* to `ConsoleIo.out` but *gate* on the real
`stdout.hasTerminal` and on `Ansi.enabled`, so redirecting the sink does not redirect the
decision about what to render.

### 4.8 `Ansi` and `Env` read different environments

`Ansi.enabled` consults `Platform.environment['NO_COLOR']` directly.

**Verified:** after `Env.set('NO_COLOR', '1')`, `Env.has('NO_COLOR') == true` while
`Platform.environment.containsKey('NO_COLOR') == false` — so the package's own environment
override is invisible to its own colour gate. One of the two should be the single source.

### 4.9 `FutureShellResultExtension` is a one-off convention

`Future<ShellResult>` gets `text`, `lines`, `json`, `ok` mirrored onto it. No other result type
in the package — `Either`, `DownloadProgress`, `JsonDocument`, `ShellResult` itself — gets that
treatment. Either it is the convention or it is not.

### 4.10 Two idioms for receiver-less API

`Console`, `Logger`, `Prompt`, `Env`, `Ansi` are static-method namespaces. `run`, `$`, `which`,
`retry`, `die`, `onExit`, `runExitHooks`, `clearExitHooks` are top-level functions. `die` and
`onExit` are CLI lifecycle, the same layer as `Console` and `Logger`; the split is not along any
visible line.

---

## 5. Correctness defects found while auditing the surface

These are behavioural, not stylistic. Each was reproduced by running code.

### 5.1 `Either.tryCatch<E, T>` throws instead of returning `Left` — **verified**

`lib/core/either.dart:75` and `:93`, the no-`onError` path:

```dart
if (error is E) return Left(error);
return Left(error as E);   // ← throws _TypeError
```

```dart
Either.tryCatch<MyError, int>(() => throw StateError('boom'));
→ _TypeError: type 'StateError' is not a subtype of type 'MyError' in type cast
```

The entire purpose of `tryCatch` is not to throw. The existing test
(`test/core_async_test.dart:423`) only exercises the case where the thrown error *is* an `E`,
so the fallback is uncovered.

### 5.2 `parallelSettle<E, R>` throws on a fully successful workload — **verified**

`lib/async/parallelize.dart:105-113` builds the result list pre-filled with
`Left(StateError('Uninitialized outcome') as E)`. With any `E` other than `Object` and no
`onError`, that cast throws before a single worker runs:

```dart
await [1, 2].parallelSettle<MyError, int>((n) => n * 2);   // no failures at all
→ _TypeError: type 'StateError' is not a subtype of type 'MyError' in type cast
```

So the typed-error overload — the headline of the "typed errors" work — is unusable unless you
also pass `onError`. Nothing in the signature says so. The same `error as E` pattern appears in
`ParallelizeStream.parallelSettle`'s source-error path (`:298`).

### 5.3 `Path` equality still splits map keys — **verified, carried forward**

```dart
Path('/tmp/a/../a') == Path('/tmp/a')   → false
<Path, String>{a: '1', b: '2'}.length   → 2
```

`extension type ... implements String` cannot override `==`. Unchanged since the last audit; the
mitigation is `normalized`, which returns `String` rather than `Path` (§3.1 #5) so it does not
compose back into a `Map<Path, _>` key without a re-wrap.

### 5.4 ANSI styles do not compose — **verified, carried forward**

```dart
('a'.red + 'b').bold  →  ESC[1mESC[31maESC[0mbESC[0m
```

The inner reset cancels `bold` for `b`. `AnsiString` emits a full reset per style instead of
accumulating SGR parameters.

### 5.5 Sibling progress widgets disagree in non-TTY — **verified, carried forward**

Under a redirected sink with no terminal: `ConsoleProgress` emits 4 lines (one per tick plus the
summary); `ConsoleMultiProgress` emits 1 (the summary only). Two widgets from the same factory
class, opposite behaviour in CI.

---

## 6. What a concise surface looks like

Ordered by benefit per unit of churn. All of it is behaviour-preserving except where noted.

### Tier 1 — fixes defects, small and mechanical

1. Fix `error as E` in `Either.tryCatch`/`tryCatchAsync` and both `parallelSettle`s: require
   `onError` when `E != Object`, or make the fallback `Left` construction lazy. Add the
   uncovered test (§5.1, §5.2).
2. Route `process`'s child-process echo through `ConsoleIo` (§4.7).
3. Gate the progress widgets on the seam, not on the real `stdout` (§4.7, §5.5).
4. Pick one environment source for `NO_COLOR` (§4.8).
5. `exitcode` → `exitCode`; `flatmap` → `flatMap`; `notnull` → `whereNotNull` (§3.1).

### Tier 2 — cuts the dependency graph

6. Move `BatchDownloadProgressMultiProgressExtension` to `cli/`, or delete it. Cuts `fs → cli`.
7. Move downloading (`DownloadProgress`, `BatchDownloadProgress`, `download`, `downloadAll`) to
   `http/`, taking `Path` as a parameter. Delete `Uri.download`. Cuts `fs → http` and `http → fs`.
8. Move `zip`/`unzip` and `sha256`/`md5` off `Path`. Cuts `archive` and `crypto`.
9. Move the format read/write pairs off `Path`. Cuts `fs → core`.

   Result: `fs` and `process` depend on `package:path` alone (7 → 1 each), and `Path` drops from
   83 members to ~59.

### Tier 3 — collapses the cross products

10. One `scrape` entry point over a `ScrapeSeed` union (sealed type or `Uri | Iterable<Uri> |
    BaseRequest | Iterable<BaseRequest>` constructors) instead of four identical extensions,
    and delete the now-unreachable runtime branches (§2.2). −3 extensions, −5 copies of the
    signature.
11. Delete the nine derived `isolate*` methods; keep `res.html()/json()/xml()` and the existing
    `IsolateFunctionExtension.isolate()` they compose from (§2.1). −9 members.
12. Delete the five `ScrapeContext` delegations (§2.5). −5 members.
13. Delete the 14 non-load-bearing aliases, keeping `parallelize` (§2.4). −14 members.
14. Model `CliOption` as a sealed kind — flag / value / number / choice — so illegal
    combinations stop compiling, and give `CliContext` typed accessors so a `numeric` option is
    not re-parsed from a string on every read (§3.4).

    Combined: **435 → roughly 340 members**, with nothing removed that cannot be written as a
    one-line composition of what remains.

### Tier 4 — conventions, worth doing once

15. Settle on one extension naming scheme (`<Type>Extensions`, receiver first, no `Toolkit`
    prefix) and rename all 31 (§3.2).
16. Move implementation files under `lib/src/`, export only the eight module barrels plus
    `dart_toolkit.dart`. 34 public libraries → 9, and `jsonpath` stops being importable (§1).
17. Replace the five `Object` unions and the two `dynamic`s with sealed types or records (§3.3).
18. Split platform detection out of `Env` (§4.6).
19. Rename `Path.replace` → `replaceInFile`, `Path.mklink` → `symlink`, make `normalized`
    return `Path`, and rename `Stream.buffer` → `chunkTime` (§3.1).

### Deliberately not recommended

- **Removing the `*Sync` mirrors.** For a scripting toolkit synchronous IO is the point.
  Tier 2 already removes 16 of the 32 as a side effect of moving concerns off `Path`; the
  remaining 16 mirror a genuinely useful core.
- **Dropping `implements String` from `Path`.** It causes §3.1 #2/#4 and §5.3, but it is also
  what makes `Path` ergonomic enough to pass anywhere a path string is expected. Document
  `normalized` at map boundaries as the contract instead.
- **Removing `parallelize`.** It is the README headline; renaming it now costs more than the
  one duplicate spelling.
- **Upstream XPath strictness.** `xpath_selector` accepts malformed expressions; capped by the
  dependency, unchanged from the previous audit.
