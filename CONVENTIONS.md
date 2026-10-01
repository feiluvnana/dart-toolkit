# Conventions

The package optimises for two things, in this order:

1. **How little a script has to write.**
2. **How fast it runs.**

Coherence, documentation and feature count come after both. Every rule below exists because an
audit found the opposite; the *why* line under each rule is that finding. What a release
changed is in `CHANGELOG.md`, not here.

---

## 1. Surface

### One import

`package:dart_toolkit/dart_toolkit.dart` exports every module except the ones listed under
[Own namespaces](#own-namespaces). The per-module libraries exist for a program that measured
and wants less.

### Own namespaces

A module is **not** in the barrel when its names are short enough to collide with a `dart:`
name, or when its compile cost falls on programs that never use it. Today that is
`package:dart_toolkit/chrome.dart` (`ChromeClient`, `ChromePage`, `Device`, `Resource`,
`ChromeWait`, `Dialog`): a third of `http`'s source, −32 ms on every `http` import.

> *Why:* a package name silently beats a `dart:` name. The barrel's old `Native` class hid
> `dart:ffi`'s `@Native` annotation, so `@Native<…>(symbol: …)` failed with "abstract class".
> And a scraper that never drives a tab paid Chrome's compile on every `dart run`.

### One name per operation

No aliases, not even deprecated ones. When two spellings exist, one is deleted.

> *Why:* `download` beside `downloadAll`, `outerHtml` beside `markup`, `isNull` beside
> `isNotNull`, `client.crawl` beside `client.scrape` — each pair made call sites choose for no
> reason.

**Two doors are fine when the situation picks the door.** `url.get()` is for code with no
client in hand (it needs `Http.scope`); `client.get(url)` is for code holding one. Neither can
do the other's job.

### A conversion is the way in

`'…'.url`, `.path`, `.json`, `.yaml`, `.html`, `.sequence`, `.table`, `60.s`. Nothing else is
added to `String`, `Iterable` or `Map`; the vocabulary lives on the type the conversion returns.
A module's conversions are one extension (`StringFormatsExtensions`), not one per getter.

### One word per idea, everywhere

| Idea | Word |
|---|---|
| a default | `or` — `Opt.…or(v)`, `ask(or:)`, `confirm(or:)` |
| a body | `text` / `bytes` / `form` / `json`, plus `files` (pairs with `form` as one multipart body) |
| serialising markup | `markup` |
| one file or a thousand | `download` |
| a guaranteed value | the bare name; `…OrNull` for the caller who expects absence |
| repeatable | `.many()`, on `Opt` and `Arg` alike |
| a link, resolved | `links` — against the document's `<base href>`, else its URL |
| unset | an empty environment variable is unset, for `Env.get`, `getOrNull`, `has` and `parse` |

### A name is written once

Anything declared and then looked up again by string is a typo the compiler cannot see. A CLI
option **is** its value:

```dart
final top = Opt.number('top', 'How many to show').abbr('n').or(10);
final id = Arg.text('id', 'The build').required();
// …
ctx(top); // int
ctx(id);  // String
```

The help text is the second positional and every other property is a chain step (`.abbr`,
`.env`, `.or`, `.many`) — Dart cannot mix an optional positional with named parameters, and
`tk` wrote `description:` thirteen times.

`Opt` and `Arg` differ only in how they are written on the command line. `Opt.among('algo',
Hash.values)` takes the enum, so nothing rebuilds it from a string. `Table` still keys by
column name, because a CSV's columns are unknown until it is read.

### Short syntax is sugar over a class

Every quick spelling is built on a class a program can hold, subclass and test, and there is
one engine behind both.

| Quick | Full |
|---|---|
| `items.parallelize(fn, isolate: true)` | `Worker<T, R>` + `Pool` — `init()` once per isolate, `run(item)` per item |
| `url.scrape<T>()…onResponse(…)` | `class MyCrawler extends Crawler<T>` — the same hooks as methods |

> *Why:* a one-off script wants one line; a real program wants state, reuse and tests. When the
> two are separate implementations they drift. The chain's lifecycle hooks are kept as separate
> hooks in both forms — never collapsed into one handler.

### A method earns its place by what it deletes at the call site

Measured by the scripts people write, of which `bin/keybox.dart`, `bin/books.dart` and
`bin/tk.dart` are examples, not the census. A method that merely composes two others one line
apart does not earn it; one that a script author reaches for — `countBy`, `frame()`, a browser's
`cookies()` — earns it even where `bin/` never calls it.

> *Deleted for this reason:* `gzipTo`, `Table.tsv`, `Ansi.strip`, `Console.table`,
> `Sequence.count`, `String.stripped`, twenty-one per-algorithm digest shortcuts; in Audit IV
> `Mutex`, `Sequence.none`/`whereNot`/`shuffled`, `Either.fold`/`isLeft`, `Env.require`.
> Kept by the same audit, though `bin/` never calls them: Chrome's `frame`, `scroll`, `back`,
> `pdf` and dialogs, `countBy`, `chunkEvery`, `Duration.jittered`, unrar.
> `text.hash(Hash.sha256)` is longer than `text.sha256` was, and is the only spelling for all
> twenty algorithms.

The rule cuts both ways: `Element.attr` and `Sequence.union` duplicate something expressible
elsewhere and stay, because deleting them makes call sites longer.

### A grid has no holes

If an operation exists on one receiver of a family, it exists on all of them — or on none.

> *Why:* `hash`, `hashBytes`, `checksum`, `hmac`, `hmacBytes` once existed on different subsets
> of `String`, `List<int>` and `Path`, and nobody could predict which.

### A guaranteed value is not nullable

`row.number('size')`, `Elements.text`, `Element.attr`, `JsonDocument.to<T>()`, `Env.get` return the value or
throw a `StateError` that names what was missing. `…OrNull` is the form that expects absence.

> *Why:* `attr` returned `String?`, and fourteen call sites wrote `attr('href')!`, which failed
> as "Null check operator used on a null value" with no name in it.

### Illegal states are not representable

Sealed types for option kinds, download states and crawl failures; typed parameters instead of
`Object`. A body is four typed arguments, not one `Object?` that throws at runtime. Two
`Object` parameters remain, each where a receiver-side spelling already takes every form:
`ctx.follow` (a link, a `Uri`, an element, any iterable of them, or a `JsonDocument` holding
them) and `client.scrape` (a `Uri`, `Uri`s or `Request`s).

### Public means a caller uses it

Parser internals, native shims and query engines are private. Something that must cross a library
boundary but is not API says so in its name: `NativeBridge`. Nothing in `lib/` exists only for
tests.

### Names

- A read-only boolean is `is…`; a settable switch or a parameter is a bare adjective.
- The async form is bare; its sync twin ends in `Sync`. Sync twins exist only in `fs`.
- A pure function of the receiver is a getter (`sorted`, `sum`, `res.json`). IO or an argument
  makes it a method.
- Short and meaningful beats descriptive: `done:`, not `successMessage:`.
- A bare name that collides with `dart:` is namespaced: `Lifecycle.exit`, never a top-level
  `exit` (which would silently win over `dart:io`'s).

### Events are pairs

`on<event>` registers, `<event>` fires. `onExit(null)` unregisters. Nothing else.

### A builder only where the order means something

`Scrape`'s hooks are a chain because the order is the lifecycle. A command is a constructor:
`CliCommand(name, description, values:, commands:, handler:)` — one list of `Arg`s and `Opt`s, since the kind is
in the type. Builder methods return the receiver; a
registration returns its unregistration.

### A wait is armed before its trigger

`page.waitForNavigation(() => page.click('a'))`, not `click(); waitForNavigation();` — a fast
page finishes before the next line runs. `waitForDownload` and `waitForResponse` have the same
shape. Where arming first is impossible, wait on a second signal (`back()` waits on the
lifecycle event *or* the URL changing).

### Help describes this command

The usage line is built from what the command holds: its positionals by name, `[options]`,
`[command]` only when it has subcommands, and the ancestor options it accepts as "Global
options". `Arg` and `Opt` share one help renderer.

### A built-in yields to a declaration

`-h`, `-v`, `-q`, `--version` and `--completion` answer only where the program has not taken
the name or the short form. Built-ins are options, never commands — the command namespace is
the program's.

### A reading implies its policy

When the getter a caller reads already says what it wants, the operation lets that getter set
the policy. `run()` starts a microtask late, so `.text`/`.lines` imply `quiet` and `.isOk`
implies `strict: false`:

```dart
await run('git diff --quiet').isOk;   // was: strict: false, quiet: true
(await api.post(json: x).json)['id']; // throws unless 2xx; `await api.post(…)` is lenient
```

> *Why (HTTP):* README's dashboard example carried on after a 401, and every API call wrote a
> three-line status check. A verb returns `Fetch`, a `Future<Response>` whose readings check.

---

## 2. Scopes

### Ambient over threaded

A setting every call would otherwise repeat belongs to a scope.

| Scope | Holds |
|---|---|
| `Http.scope` | client, timeout, headers, cookies (or a `jar:` to start from), `retries`, `delay` (per-origin gap, jittered ±25 %) |
| `Shell.scope` | workdir, environment, timeout, encoding, failure policy |
| `Cancel.scope` | the cancel token |

A genuinely per-call argument (`headers:`, `input:`, `args:`) stays an argument and wins over
the scope.

### A scope inside another inherits what it does not set

An inner `Http.scope(retries: 2)` keeps the outer client, cookie jar and headers; an inner
`Cancel.scope` hears the outer token.

> *Why:* a nested `Http.scope` silently dropped the logged-in session and reset the user agent.

### The scope is the only way in

Not the default way — the only one. A token reaches `download`, `retry`, `run`, `Pool` and
`.cancellable` through `Cancel.scope` and nowhere else. What a scope holds is named once, where
it opens.

> *Why:* `cancelWith(token:)` beside `Cancel.scope` was two ways to say one thing, and audits
> kept finding the token threaded through call sites anyway.

### Every operation honours the scope

If an operation can take time, it stops when `Cancel.scope` cancels — including the parts that
are easy to forget: a process's children, a retry's backoff, a pool's queued items, a plain
`delay`, a lock's waiters, a crawl, a response body whose headers are in (`dart:io` ignores
`abort()` then, so the body is cut from the client side), and a scope opened inside another,
which hears the outer one.

> *Why:* `run('sleep 3')` in a cancelled scope used to finish at 3 s, and `kill -TERM` left
> the children running.

### A scope holds settings, never a capability

Every client means the same thing by a timeout or a cookie jar, so a scope can hold them. A
capability — driving a tab — lives on the object: `chrome.page(…)` sits beside `chrome.get(…)`,
and the compiler rules on it. No probing the ambient client for what it can do.

### Credentials never leave their origin

A scope's `authorization` and cookie jar reach the origin they belong to — scheme, host and
port — and nothing else: not another host or port on a redirect, not `http` after `https`
(`Request._hop`), not a second origin the scope's code talks to (credential headers bind to the
first request's origin), and not a third-party subresource inside a Chrome tab.

> *Why:* `Network.setExtraHTTPHeaders` sent the scope's bearer token to every CDN a page loaded.

### Scopes read alike

`Cancel.isCancelled`, `.reason` and `.throwIfCancelled()` mirror `CancelToken`, so nobody
writes `Cancel.token?.throwIfCancelled()` — whose `?.` silently does nothing outside a scope. A
*reading* is quiet outside a scope; an *adapter* like `.cancellable` throws there.

### Opened once, at the top

`Cli.run` opens the `Cancel.scope` whose token is `ctx.cancel`, so ^C stops downloads,
processes and pools with no code at all. Inside it `print` is a durable write, landing above a
live spinner instead of on its row. Nothing else is opened implicitly.

---

## 3. Seams

### A seam is two methods; unknown means ignored

A pluggable thing is an `abstract interface class` you can implement in an afternoon — `Client`
is `send` and `close`. What one implementation understands and another does not travels as a
typed key (`RequestKey`) that the others ignore. No capability flags, no `switch` over
implementations. A seam ships with a conformance battery (`test/client_conformance.dart`).

A key every implementation must honour belongs to the seam: `Request.raw` (*the resource,
never a rendering of it*) is on `Request`, not on `ChromeClient`.

### A seam absorbs the difference

`Client.close()` is `Future<void>`, never `FutureOr<void>`: one implementation's convenience
must not become every caller's `if (x case Future f)`.

### Sending consumes a request

A client writes on the request it is handed (default headers, `cookie`), so a `Request` is
single-use. Anything that re-sends copies it first.

### A policy with three callers is written once

A redirect hop's rules (303 → bodiless GET, 307/308 keep both, credentials stop at another
host) are `Request._hop`, shared by `IoClient`, the cookie jar and the crawl engine.

---

## 4. Robustness

These are the rules the September 2026 audit added. Each was a silent failure.

- **Parse the real world, not the spec's happy path.** Cookie dates use RFC 6265's lenient
  parser; `HttpDate.parse` throws `HttpException`, not `FormatException`. HTML entities without
  `;` decode only for the legacy names, and never inside a URL-like attribute value.
- **Nothing lands in the working directory unless asked.** Chrome downloads go to a folder the
  client owns and are moved to `to:` on completion.
- **A child process never outlives a stop.** Chrome and `run` children are killed as a process
  tree on cancel, timeout and a caught signal; a launched Chrome also on `kill -9` of the parent
  (its watchdog). A `run` child that the parent's `kill -9` orphans is not tracked: its stdin is
  its own, so it cannot be the lifeline.
- **A command string is what a simple command is.** Shell syntax outside quotes is refused, never
  passed as an argument; `shell: true` or `|` is the way to a shell. An unclosed quote is a
  `FormatException`.
- **Every abandoned response is drained.** A timed-out or redirected body is read (small) or
  cancelled (large), so pool permits come back and keep-alive survives.
- **Untrusted archives are contained.** No path escapes the destination, no link leads out even
  before its target exists, nothing is written through a link already there, no setuid bit
  survives, and output is capped by ratio unless the caller opts out.
- **A compressed body ends where its stream does.** A decoder that ran out of input mid-stream is
  an error, never a short body.
- **A crawl's own files are capped like its pages.** robots.txt is read to 512 KiB and a sitemap
  to 50 MB, compressed or unpacked — the protocols' own limits.
- **A page is its origin's.** robots.txt, `delay` and `perHost` belong to scheme, site and port;
  scope stays by host.
- **A prompt talks to the person, and so does an indicator**: every word of a prompt, spinner,
  bar or board goes to stderr, so `app > out.json` captures only data. **An indicator is a log
  line**: `-q` silences spinners, bars and boards, and nothing in the live region is wider than
  the terminal less one. Colour and redraw are decided per sink; `NO_COLOR` turns off colour,
  not redraw.
- **An abandoned request is aborted, not only drained.** Draining waits for a response; one
  that never comes held its pool permit forever.
- **A write replaces, never truncates.** `writeText`/`writeBytes`/`writeLines` rename a finished
  sibling over the target, keeping its mode and links; a ^C mid-write used to leave half a
  config for the next run to parse.
- **A batch reports its failures.** `download().show()` ends with "2 of 6 failed", never
  "all done" over failures.
- **A test list runs the small case.** `sorted.take(3)` was tested only at 5000 items, so its
  full-sort branch returned every element unnoticed.
- **Input that is not UTF-8 does not fail the operation.** Process output decodes with
  `allowMalformed: true`.
- **Every CLI failure is one line and a code.** 64 for usage, 1 for anything else, 128+n for
  a signal. The stack trace is for `--verbose`.
- **Nothing a signal must reach blocks the event loop.** A blocking read (a prompt) runs on a
  helper isolate, so ^C is always heard.
- **A data format refuses nesting deeper than 1000; a walk over decoded data uses a stack.** A
  config file that deep is an attack; JSONPath `..` runs over what `jsonDecode` accepted, so it
  walks any depth. (YAML flow collections overflowed at 4 000 levels.)
- **An unterminated construct is a `FormatException`, never a hang or a `RangeError`.** Every
  scanning loop either consumes input or fails. (`[a: 1]` used to hang the YAML parser.)
- **A tree walk recurses to a depth, then continues on a stack.** Recursion is a third faster on
  real pages; the stack lets a document nested 100 000 deep still parse, query and serialise.
- **A browser-wide setting belongs to whoever owns the browser.** A launched browser is set
  once; a browser we joined is changed only while needed, then handed back.
- **Stored bytes are never decoded.** `Request.raw` or a `range` means the representation: ask
  for `identity` and decode nothing.
- **One retry policy.** A sender with its own budget (the crawl) marks its requests, so an
  enclosing `Http.scope(retries:)` does not multiply it. It never sends a POST or PATCH twice —
  the server may have acted on the first — except after a 429 or 503 with `Retry-After`, which
  says the request was not processed.
- **A cap is a ratio with a floor.** A fixed number is too small for a big archive and too
  large to stop a small bomb: extraction is capped at 200× the archive, never below 1 GiB.
- **A differential test backs every in-house replacement.** The HTML, XML and YAML parsers are
  checked against `package:html`, `xml` and `yaml` (dev dependencies only).

---

## 5. Performance

### Measure back to back, or not at all

Startup drifts ±80 ms between runs. A claim is two numbers from the same minute, alternating
order. `tool/startup.dart` prints the per-module table: six alternating rounds, median and
minimum over bare. Two rounds in a fixed order produced 120 ms phantoms.

Startup under `dart run` is front-end compile: the same programs compiled to kernel start in
~90 ms whatever they import. `dart run -r` (the resident compiler) halves it for a script run
again and again.

### Nothing third-party at runtime but `path`

Every parser, the HTTP client and the archive formats are the package's own. `package:html`,
`xml`, `archive` and `http` together cost a second of front-end compile per `dart run`.

### Sharing code across modules is measured like anything else

> *Why:* rebuilding `NativeBridge` on the old general-purpose `ffi.dart` would have cost every
> `hash`/`fs`/`http` import ~30 ms of compile, and hashing's calls would have gone from ~11 ns
> to ~57 ns. `ffi.dart` itself was deleted in Audit IV: calling through wider-than-declared
> signatures returned garbage silently, and the OS calls a script needs (`chmod`) are typed
> methods on `Path` instead.

### An isolate is sent what it needs and nothing near it

A closure handed to `Isolate.run` or a `Pool` is built in a top-level function. A closure written
inside a method shares that method's whole context, and the isolate copies all of it.

> *Why:* `parallelize(isolate: true)` sent its entire input list to every isolate — 20.9 s for
> what now takes 70 ms.

### A module does not import another to add one method

`Table.read(path)` lives on `Table`, not `Path.table()`: importing `fs` into `collection`
measured +40 to +253 ms on `formats`, and would put `dart:ffi` in modules that never use it.
`collection` also imported all of `formats` for `JsonDocument.table`; the extension now lives in
`formats`, −125 ms back to back for a collection-only script.

### An order is applied when it is read

`take(n)` after `orderBy`/`sortedBy` selects `n`; `length` and `isEmpty` never sort.

> *Why:* `orderBy(…).take(10)` sorted all 500k rows (165 ms, now 25).

### A hot return is not a record

A non-inlined per-token function returning a four-field record cost 8% of the whole HTML parse.
Measure before choosing records on a hot path.

### The native library does what Dart cannot do fast

`native/` is one Rust `cdylib`, `dart_toolkit_native`, prebuilt per platform under
`native/prebuilt/<os>_<arch>/` and loaded by `NativeLib`.

- Only `fs`, `hash` and `http` import it, so `dart:ffi` costs nothing to a program that uses
  none of them. Opening the library is lazy (~12 ms, first use).
- It holds digests, MACs, archive formats, content-decoding, the WHATWG legacy charsets
  (decode only) and `chmod`, which `dart:io` lacks — nothing else. There is no Dart
  fallback: two implementations of one primitive are two places for a bug. Without the library
  those calls throw `UnsupportedError` saying what was needed.
- Bytes cross as pointer and length (zero-copy leaf calls where the SDK allows), files cross by
  path, and long work runs in `Isolate.run`. No callbacks into Dart.
- Every buffer-filling function takes its capacity; every entry point is wrapped in `guard`, so
  neither an overrun nor a panic crosses the ABI. Memory comes from `tk_alloc`, never the host
  `malloc`.
- Output per call is bounded, and "call again" is signalled by filling the buffer exactly. No
  length travels as an `i32`.
- Every file is read by the library: on the calling isolate up to 4 MiB, in a worker isolate
  above it — starting one costs about what SHA-256 takes over 4 MiB.
- **An export changes the ABI.** Adding or changing a `tk_` function bumps `tk_version` and
  `NativeLib._abi` together and rebuilds all four prebuilts, so a stale library is refused at
  load instead of failing later with "Failed to lookup symbol".
- A new primitive is one Rust function, one `lookupFunction`, and its published test vector.
- Native assets (`hook/build.dart`) were measured at +50–65 ms on every `dart run` and are not
  used.

### Cryptography beyond hashing is out of scope

No ciphers, password hashing, key agreement, signatures or JWT. Hashing, HMAC and encodings
stay, because identifying and verifying data is what scripts do.

### Files stream

Hashing, downloading and archiving take the file, not its bytes.

### Writing names the format; reading works it out

`archiveTo`/`compressTo` read the destination's extension. `extractTo`, `archiveEntries` and
`decompressTo` sniff the magic number and fall back to the name, so a `.bin` that is a 7z opens.

### The renderer is the type

`Table.show()` is the only table renderer. `Io` answers every question about the active sink —
where it goes, whether it is a terminal, how wide, whether it takes colour — *per sink*, so
`2>log` gets no escape codes. `cli` asks `Io`; it keeps no second namespace.

### Errors are chosen at the use site

`parallelize`, `Pool` and `scrape` settle each item into `Either`; the caller picks `rights`,
`lefts` or `unwrap()`. Only a throwing `onInit` or `onFinish` reaches a stream's error channel.
`Cli.run` catches everything else and prints one line.

---

## 6. Layout

- **One library per module.** `lib/<module>.dart` holds the doc, imports and `part` list;
  `lib/src/<module>/` holds the parts. No `show`, no re-export, no `part` across modules. A
  module uses another through its module file.
- **Every document format is `formats`.** Data formats decode into `JsonDocument` (JSON, YAML,
  TOML, INI); markup into one tree (HTML, XML). `http`'s bridges (`res.html`, `url.get().xml`) live
  in `http`.
- **One markup tree.** `Node`, `Element`, `Text`, `Attribute`, `Nodes`, `Elements` serve HTML
  and XML; `Element.syntax` decides serialisation and case folding.
- **`$` is CSS and `$x` is XPath**, on every document.
- **Two modules meet through an interface in `core`** (`TaskProgress`, `BatchProgress`).
- **One namespace owns the terminal.** Everything that writes to it is on `Console`, over one
  live region: a renderer owns the bottom rows, and any durable write — including `run`'s
  echoed output — clears them, lands, and redraws them below.
- **Tests are one file per module**, plus `<module>_diff_test.dart` where a piece replaced a
  package and is checked against it. No upper-bound timing assertions (a lower bound — "waited
  at least the delay" — cannot flake); speed is `make bench`.
- **A module that writes to the terminal without importing `cli` goes through `IoBridge`**, so
  the live region is never overwritten.

---

## 7. Release

- `make` — analyze, format check, tests. `make native` — build the Rust library for this host
  (`RUST_TARGET=…` cross-builds with `cargo-zigbuild`; Windows needs an MSVC toolchain for
  unrar). `make release` — all of it, plus `cargo audit`.
- **`.pubignore` repeats `.gitignore`.** A `.pubignore` *replaces* `.gitignore` for pub; the
  0.0.5 dry run was 65 MB without the scratch patterns.
- **Nothing generated is committed.** A stray download in the repo root once went into a commit.
- Executables run through pub's snapshot: `dart run dart_toolkit:<name>`.
- The version number is the owner's call.

---

## 8. Documentation

- `README.md` is the tour: one example per idea, the common case only.
- `GUIDE.md` is the manual: every module, every use case, a cookbook.
- This file is the rationale. `CHANGELOG.md` is what each release contains.
- A doc comment says what the signature cannot. Keep the *why*; drop the restatement.
