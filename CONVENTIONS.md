# Conventions

The package optimises for these, in this order:

1. **How fast it runs.** Startup, throughput and memory, measured (§5).
2. **How little a script has to write, and how easily its author finds the way**, ranked equal.
   When they pull apart, keep both: the short spelling, and a facade member (`Http.get`,
   `Doc.json`, `Fs.home`) that forwards to it. Speed beats both: a shorter or more findable
   spelling that costs measurable time loses to one that does not.

Coherence, documentation and feature count come after these. Each rule exists because an audit
found the opposite; its *why* is that finding. What a release changed is in `CHANGELOG.md`.

---

## 1. Surface

**One import.** `package:dart_toolkit/dart_toolkit.dart` exports every module except those with
own namespaces; per-module libraries are for a program that measured.

**Own namespaces.** A module stays out of the barrel when its names could collide with `dart:`
or its compile cost falls on programs that never use it. Today: `chrome.dart` (`ChromeClient`,
`ChromePage`, …; −32 ms on every `http` import) and `tui.dart` (terminal apps; ~35 ms over `core`).

> *Why:* a package name silently beats a `dart:` name — the barrel's old `Native` hid
> `dart:ffi`'s `@Native`; and every scraper paid Chrome's compile.

**One name per operation.** No aliases, not even deprecated: two names on one receiver
(`select`/`$`, `isOpen`/`isClosed`) are out. Two doors are fine when the situation picks the door
— `url.get()` (no client in hand, uses `Http.scope`) vs `client.get(url)` — or when one is a
facade member forwarding to the other: `Http.get(url)` is where a newcomer starts typing,
`'…'.url.get()` is what they write once they know it.

> *Why:* `download`/`downloadAll`, `outerHtml`/`markup`, `client.crawl`/`client.scrape` made
> call sites choose for no reason. Facades stay because a script author who doesn't know a
> conversion exists types the module's name first (owner decision, 2026-10-02).

**A conversion is the way in.** `'…'.url`, `.path`, `.json`, `.html`, `.table`, `60.s`. Nothing
else goes on `String`, `Iterable` or `Map`; the vocabulary lives on the returned type. A module's
conversions are one extension (`StringFormatsExtensions`).

**One word per idea.**

| Idea | Word |
|---|---|
| a default | `or` — `Opt.…or(v)`, `ask(or:)`, `confirm(or:)` |
| a body | `text` / `bytes` / `form` / `json`, plus `files` (multipart with `form`) |
| serialising markup | `markup` |
| one file or a thousand | `download` |
| a guaranteed value | the bare name; `…OrNull` when absence is expected |
| repeatable | `.many()`, on `Opt` and `Arg` |
| a resolved link | `links` — against `<base href>`, else the document URL |
| unset | an empty env var is unset, for `Env.get`, `getOrNull`, `has`, `parse` |

**A name is written once.** A CLI option **is** its value — no string lookup to mistype:

```dart
final top = Opt.number('top', 'How many to show').abbr('n').or(10);
ctx(top); // int
```

Help text is the 2nd positional; every other property is a chain step (`.abbr`, `.env`, `.or`,
`.many`). `Opt.among('algo', Hash.values)` takes the enum. `Table` still keys by column name —
a CSV's columns are unknown until read.

> *Why:* Dart cannot mix an optional positional with named parameters, and `tk` wrote
> `description:` thirteen times.

**Short syntax is sugar over a class.**

| Quick | Full |
|---|---|
| `items.parallelize(fn, isolate: true)` | `Worker<T, R>` + `Pool` — `init()` per isolate, `run(item)` per item |
| `url.scrape<T>()…onResponse(…)` | `class MyCrawler extends Crawler<T>` — same hooks as methods |

One engine behind both; the lifecycle hooks stay separate in both forms, never one handler.

> *Why:* a script wants one line, a program wants state and tests; two implementations drift.

**A method earns its place by what it deletes at the call site** — judged by usefulness to
script authors, not by what `bin/` calls. Composing two others does not earn it; `countBy`,
`frame()`, `cookies()` do. `Element.attr` and `Sequence.union` duplicate others but stay: shorter.

> *Why:* deleted `gzipTo`, `Ansi.strip`, `Sequence.count`, twenty-one digest shortcuts
> (`text.hash(Hash.sha256)` covers all twenty algorithms), `Mutex`, `Env.require`; kept
> Chrome's `frame`/`pdf`/dialogs, `chunk`, `Duration.jittered` though `bin/` never calls them.

**A grid has no holes.** An operation on one receiver of a family is on all of them, or none.

> *Why:* `hash`, `hmac`, `checksum` existed on unpredictable subsets of `String`/`List<int>`/`Path`.

**A guaranteed value is not nullable.** `row.number('size')`, `Element.attr`, `JsonDocument.to<T>()`,
`Env.get` return the value or throw a `StateError` naming what was missing; `…OrNull` expects absence.

> *Why:* fourteen call sites wrote `attr('href')!`, failing with no name in the message.

**Illegal states are not representable.** Sealed types for option kinds, download states and crawl
failures; a body is four typed arguments, not one `Object?`. Two `Object` parameters remain where
the receiver already takes every form: `ctx.follow` and `client.scrape`.

**Public means a script author needs it.** A toolkit is judged by what it offers, not by who
calls it today: a useful member stays with no caller, and a duplicate or a piece of plumbing goes
however many tests touch it. Parser internals, native shims and query engines are private;
something that must cross libraries but is not API says so (`NativeBridge`). Nothing in `lib/`
exists only for tests, except a seam's fake (`FakeTerminal` for `Tui.terminal`).

> *Why:* audits counted callers and proposed cutting useful members nobody in `bin/` happened to
> call yet; the owner's test is "is this useful and needed" (2026-10-02).

**Names.** A read-only boolean is `is…`; a switch or parameter is a bare adjective. Async is bare,
its sync twin ends in `Sync` (only in `fs`). A pure function of the receiver is a getter
(`sorted`, `res.json`). Short beats descriptive (`done:`, not `successMessage:`). A name that
collides with `dart:` is namespaced: `Lifecycle.exit`, never a top-level `exit`.

**Events are pairs.** `on<event>` registers, `<event>` fires, `onExit(null)` unregisters.

**A builder only where order means something.** `Scrape`'s hooks chain because order is the
lifecycle; a command is a constructor, `CliCommand(name, description, values:, commands:, handler:)`.
Builders return the receiver; a registration returns its unregistration.

**A wait is armed before its trigger.** `page.waitForNavigation(() => page.click('a'))`; likewise
`waitForDownload`, `waitForResponse`. Where arming first is impossible, wait on a second signal
(`back()` waits on the lifecycle event *or* the URL changing).

> *Why:* a fast page finishes before the next line runs.

**Help describes this command.** The usage line lists its positionals, `[options]`, `[command]`
only with subcommands, and accepted ancestor options as "Global options". One renderer for both.

**A built-in yields to a declaration.** `-h`, `-v`, `-q`, `--version`, `--completion` answer only
where the program has not taken the name; built-ins are options, never commands.

**A reading implies its policy.** The getter a caller reads sets the policy: `run().text`/`.lines`
imply `quiet`, `.isOk` implies `strict: false`. HTTP verbs return `Fetch`, a `Future<Response>`
whose readings (`.json/.text/.html/.xml/.bytes`) throw unless 2xx; awaiting it bare is lenient.

> *Why:* README's dashboard example carried on after a 401, and every API call wrote a
> three-line status check.

---

## 2. Scopes

**Ambient over threaded.** A setting every call would repeat belongs to a scope. A truly per-call
argument (`headers:`, `input:`, `args:`) stays an argument and wins.

| Scope | Holds |
|---|---|
| `Http.scope` | client, timeout, headers, cookies (or `jar:` to start from), `retries`, `delay` (per-origin, ±25 % jitter) |
| `Shell.scope` | workdir, environment, timeout, encoding, failure policy |
| `Cancel.scope` | the cancel token |

**An inner scope inherits what it does not set.** An inner `Http.scope(retries: 2)` keeps the outer
client, jar and headers; an inner `Cancel.scope` hears the outer token.

> *Why:* a nested `Http.scope` silently dropped the logged-in session.

**The scope is the only way in.** A token reaches `download`, `retry`, `run`, `Pool` and
`.cancellable` through `Cancel.scope` alone.

> *Why:* `cancelWith(token:)` beside `Cancel.scope` was two ways to say one thing.

**Every operation honours the scope** — including a process's children, a retry's backoff, a pool's
queue, a plain `delay`, a lock's waiters, and a response body whose headers are in (cut client-side,
since `dart:io` then ignores `abort()`).

> *Why:* `run('sleep 3')` in a cancelled scope finished at 3 s, and `kill -TERM` left children running.

**A scope holds settings, never a capability.** Timeouts and jars mean the same to every client;
driving a tab lives on the object (`chrome.page(…)` beside `chrome.get(…)`), checked by the compiler.

**Credentials never leave their origin.** A scope's `authorization` and jar reach only their
scheme+host+port: not across a redirect (`Request._hop`), not to a second origin the code talks to,
not to a third-party subresource in a Chrome tab.

> *Why:* `Network.setExtraHTTPHeaders` sent the bearer token to every CDN a page loaded.

**Scopes read alike.** `Cancel.isCancelled`, `.reason`, `.throwIfCancelled()` mirror `CancelToken`
(`Cancel.token?.throwIfCancelled()` silently did nothing). A *reading* is quiet outside a scope;
an *adapter* like `.cancellable` throws.

**Opened once, at the top.** `Cli.run` opens the `Cancel.scope` behind `ctx.cancel`, so ^C stops
everything with no code; inside it `print` lands above a live spinner. Nothing else opens implicitly.

---

## 3. Seams

**A seam is two methods; unknown means ignored.** A pluggable thing is an `abstract interface class`
(`Client` is `send` and `close`). Implementation-specific options travel as typed keys
(`RequestKey`) others ignore — no capability flags, no `switch` over implementations. A key all must
honour belongs to the seam (`Request.raw`). Each seam ships a conformance battery
(`test/client_conformance.dart`).

**A seam absorbs the difference.** `Client.close()` is `Future<void>`, never `FutureOr<void>`.

**Sending consumes a request.** A client writes on it (default headers, `cookie`), so a `Request`
is single-use; anything that re-sends copies it first.

**A policy with three callers is written once.** Redirect rules (303 → bodiless GET, 307/308 keep
both, credentials stop at another origin) are `Request._hop`, shared by `IoClient`, the jar and the crawl.

---

## 4. Robustness

Each of these was a silent failure.

- **Parse the real world.** Cookie dates use RFC 6265's lenient parser; HTML entities without `;`
  decode only for legacy names, never inside a URL-like attribute.
- **Nothing lands in the working directory unless asked.** Chrome downloads go to a client-owned
  folder and move to `to:` on completion.
- **A child never outlives a stop.** Chrome and `run` children die as a process tree on cancel,
  timeout and caught signal; a launched Chrome also on the parent's `kill -9` (a POSIX
  watchdog; Windows on `close()`).
- **A command string is a simple command.** Unquoted shell syntax is refused; `shell: true` or `|`
  reaches a shell. An unclosed quote is a `FormatException`.
- **An abandoned response is aborted and drained,** so pool permits return and keep-alive survives.
- **Untrusted archives are contained.** No path or link escapes the destination, nothing is written
  through an existing link, no setuid survives; output is capped at 200× the archive, never below
  1 GiB (a fixed cap is wrong for both big archives and small bombs).
- **A compressed body ends where its stream does;** truncated input is an error, never a short body.
- **A crawl's own files are capped:** robots.txt at 512 KiB, sitemaps at 50 MB. robots.txt, `delay`
  and `perHost` belong to the origin; crawl scope stays by host.
- **A terminal app reads and draws on `/dev/tty`,** reading in a helper isolate under
  `stty … min 0 time 1`, so stdin stays the program's and `app > out` stays clean; every exit —
  `Lifecycle.exit` too, which skips `finally` — restores it through `IoBridge.restores`.
- **Prompts and live frames go to stderr,** so `app > out.json` captures only data and log lines;
  an indicator's final ok line is an info log, on stdout. `-q` silences
  spinners, bars and boards; the live region is never wider than the terminal less one. `NO_COLOR`
  turns off colour, not redraw.
- **A write replaces, never truncates.** `writeText`/`writeBytes`/`writeLines` rename a finished
  sibling over the target, keeping mode and links. (*Why:* ^C left half a config.)
- **A batch reports its failures:** `download().show()` ends "2 of 6 failed", never "all done".
- **A test list runs the small case.** (*Why:* `sorted.take(3)` was tested only at 5000 items and
  its full-sort branch returned everything.)
- **Non-UTF-8 input does not fail;** process output decodes with `allowMalformed: true`.
- **Every CLI failure is one line and a code:** 64 usage, 1 otherwise, 128+n signal; stack trace
  under `--verbose`.
- **Nothing a signal must reach blocks the event loop;** a blocking prompt read runs on a helper isolate.
- **Depth is bounded or walked on a stack.** YAML and TOML refuse nesting deeper than 1000; JSON, XML and
  HTML parse any depth on a stack; walks over
  decoded data use a stack; tree walks recurse to a depth, then continue on a stack (a third faster,
  and 100 000 levels still parse). (*Why:* YAML flow collections overflowed at 4 000.) YAML
  aliases may expand to at most 1 000 000 nodes (*why:* a 236-byte alias bomb printed 23 MB).
- **An unterminated construct is a `FormatException`,** never a hang. (*Why:* `[a: 1]` hung YAML.)
- **A browser-wide setting belongs to the browser's owner.** A joined browser is changed only while
  needed, then handed back.
- **Stored bytes are never decoded.** `Request.raw` or a `range` asks for `identity`.
- **One retry policy.** The crawl marks its requests so an outer `Http.scope(retries:)` does not
  multiply them. POST/PATCH is never re-sent, except after 429/503 with `Retry-After`.
- **Every in-house replacement has a differential test** against `package:html`, `xml`, `yaml` (dev only).

---

## 5. Performance

**Measure back to back, or not at all.** Startup drifts ±80 ms. A claim is two numbers from the same
minute, alternating order; `tool/bench.dart` runs six alternating rounds (median, min over bare).
`dart run` startup is front-end compile; `dart run -r` halves it for repeated runs.

> *Why:* two rounds in fixed order produced 120 ms phantoms.

**Nothing third-party at runtime but `path`.** `package:html`, `xml`, `archive` and `http` cost a
second of compile per `dart run`.

**Sharing code across modules is measured like anything else.**

> *Why:* building `NativeBridge` on a general `ffi.dart` would have cost every `hash`/`fs`/`http`
> import ~30 ms and hashing calls 11 → 57 ns. `ffi.dart` was later deleted: wider-than-declared
> signatures returned garbage; `chmod` is a typed method on `Path` instead.

**An isolate is sent only what it needs.** Closures for `Isolate.run`/`Pool` are built in a
top-level function; one written in a method captures the whole context.

> *Why:* `parallelize(isolate: true)` sent its entire input to every isolate — 20.9 s, now 70 ms.

**A module does not import another to add one method.** `Table.read(path)`, not `Path.table()`.

> *Why:* `fs` in `collection` cost +40–253 ms; moving `JsonDocument.table` into `formats` saved 125 ms.

**An order is applied when read.** `take(n)` after `orderBy` selects `n`; `length`/`isEmpty` never sort.

> *Why:* `orderBy(…).take(10)` sorted all 500k rows (165 ms, now 25).

**A hot return is not a record:** a per-token four-field record cost 8 % of the HTML parse.

### The native library does what Dart cannot do fast

`native/` is one Rust `cdylib`, prebuilt under `native/prebuilt/<os>_<arch>/`, loaded lazily
(~12 ms) by `NativeLib`, imported only by `fs`, `hash`, `http`.

- **Scope:** digests, MACs, archives, content-decoding, legacy charsets (decode), `chmod`. No Dart
  fallback — two implementations are two bugs; without the library those calls throw `UnsupportedError`.
- **Boundary:** bytes as pointer+length, files by path, long work in `Isolate.run`, no callbacks.
  Buffers carry their capacity, entry points are wrapped in `guard`, memory comes from `tk_alloc`;
  "call again" is a full buffer; no length is an `i32`. Files are read by the library: on the caller up to 4 MiB, a worker above.
- **An export changes the ABI:** bump `tk_version` and `NativeLib._abi` together and rebuild all
  four prebuilts, so a stale library is refused at load.
- A new primitive is one Rust function, one `lookupFunction`, and its published test vector.
- Native assets (`hook/build.dart`) are not used: +50–65 ms on every `dart run`.

**Cryptography beyond hashing is out of scope** (no ciphers, password hashing, signatures, JWT).

**Files stream:** hashing, downloading and archiving take the file, not its bytes.

**Writing names the format; reading works it out.** `compressTo` uses the extension;
`decompressTo` and `entries` sniff the magic number, so a `.bin` that is a 7z opens.

**Two UI approaches, never mixed.** `Console` (in `cli`) prints inline above the scrollback: logs,
spinners, bars, boards, prompts. `Tui` (`tui.dart`) owns the screen: an app loop, widgets, keys.
Neither imports the other; what both need (`Border`, `IoBridge.restores`) lives in `core`.

**Customization is a theme of tokens plus a builder per component.** The theme (`ConsoleTheme`,
`TuiTheme`) holds only what components share: palette, marks, glyphs, `Border`. Anything else is
the component's own builder over a typed snapshot (`task: (t) => …`, `item: (c) => …`), and the
snapshot's helpers (`t.bar(20)`) draw in the theme unless told otherwise. Same names in both UIs.

> *Why:* presets (`SpinnerStyle`) and format strings capped what a script could draw; a builder
> caps nothing and is still one line.

**The renderer is the type.** `Table.show()` is the only table renderer. `Io` answers sink
questions (terminal? width? colour?) *per sink*, so `2>log` gets no escape codes.

**Errors are chosen at the use site.** `parallelize`, `Pool` and `scrape` settle items into
`Either`; the caller picks `rights`, `lefts` or `unwrap()`. `Cli.run` prints the rest as one line.

---

## 6. Layout

- **One library per module.** `lib/<module>.dart` holds doc, imports, `part` list; parts in
  `lib/src/<module>/`. No `show`, no re-export, no cross-module `part`.
- **Every document format is `formats`.** JSON/YAML/TOML/INI decode to `JsonDocument`; HTML/XML to one
  tree (`Node`, `Element`, …; `Element.syntax` decides serialisation). `$` is CSS, `$x` XPath.
  `http`'s bridges (`res.html`) live in `http`.
- **Two modules meet through an interface in `core`** (`TaskProgress`, `BatchProgress`).
- **One namespace owns the terminal:** `Console`, over one live region that durable writes clear,
  land above, and redraw. A module that writes without importing `cli` goes through `IoBridge`.
- **Tests are one file per module,** plus `<module>_diff_test.dart` for replaced packages. No
  upper-bound timing assertions; speed is `make bench`.

---

## 7. Release

- `make` — analyze, format, tests. `make native` — build for this host (`RUST_TARGET=…` cross-builds
  via `cargo-zigbuild`). `make release` — all, plus `cargo audit`.
- **`.pubignore` repeats `.gitignore`** — it replaces it for pub. (*Why:* a 65 MB dry run.)
- **Nothing generated is committed.** (*Why:* a stray download went into a commit.)
- Executables run as `dart run dart_toolkit:<name>`. The version number is the owner's call.

---

## 8. Documentation

- `README.md` is the tour: one example per idea, common case only.
- `GUIDE.md` is the manual: every module, every use case, a cookbook.
- This file is the rationale; `CHANGELOG.md` is what each release contains.
- A doc comment says what the signature cannot. Keep the *why*; drop the restatement.
