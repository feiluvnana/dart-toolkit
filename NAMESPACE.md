# Namespaces

How this library decides where something lives and what it is called. Read this
before adding a public name; it is the rule set the current layout follows, and
following it is what keeps the surface small enough to hold in your head.

---

## The map

| Domain | Holds | Sub-namespaces |
| :--- | :--- | :--- |
| `io` | The filesystem: paths, atomic writes, reads | `io.csv`, `io.store`, `io.async` |
| `net` | The network: requests, downloads, crawling, parsing what comes back and filling in what it carries | `net.http`, `net.crawl` |
| `system` | This program and the machine running it | `system.env`, `system.console`, `system.on` |
| `concurrent` | Bounded async work on one isolate | — |
| `util` | Pure computation, and the typed keys (`Slot`, `Meta`) that carry values through a JSON map | `util.time`, `util.size`, `util.text`, `util.hash`, `util.rand` |
| `cli` | The command line your script presents to whoever runs it | — |
| `tool` | One wrapped executable or file format per name | `tool.git`, `tool.zip` |
| `$` / `$xpath` | Selectors, opt-in via `package:dart_toolkit/selector.dart` | — |

The first five are **axes**; the rest are **subjects**. Rule 1 is about telling
them apart, because they are sorted by different questions.

---

## Rule 1 — Axis or subject?

An **axis** is a way of touching the machine. `io`, `net`, `system`,
`concurrent` and `util` are axes: every operation on one of them touches that
one thing, and what it touches is what it is about.

A **subject** is a body of knowledge that came from outside Dart — a
command-line convention, an executable, a file format, a selector language. A
subject's operations touch whatever they need to touch along the way, but that
is not what they are about.

Ask which kind you have *first*, because the two tests disagree. Pulling
`--force` out of a `List<String>` touches nothing, so the axis test files it
under `util`, beside `slug` and `bytes`. Packing a folder writes files, so the
axis test files it under `io`, beside `write`. Both answers are wrong in the
same way: they name the mechanism instead of the subject.

A subject is recognisable by arriving with its own words. Flags, options and
subcommands are not Dart concepts and not filesystem concepts; they are forty
years of Unix convention, and whoever writes a script already knows them.
Branches and commits, entries and compression levels, the same. If the
vocabulary came from outside this library, you have a subject.

### If it is an axis — what does it touch?

Take the first match:

1. **Does it read or write files?** → `io`
2. **Does it open a socket?** → `net`
3. **Does it start a process, read the environment, or talk to the terminal or
   the user?** → `system`
4. **Does it schedule other work?** → `concurrent`
5. **None of the above — is it a pure function of its arguments?** → `util`

`util` is the only axis defined by an absence. Nothing in it may touch the
disk, the network, the clock's timezone database, or a process. `util.time.wait`
is the closest call: it schedules a delay but owns no resource and observes
nothing, so it stays.

### If it is a subject — where does it go?

`cli` for the command line, `tool.*` for a wrapped executable or format, `$`
for selectors. A new subject joins `tool` unless Rule 2 says it has earned a
name of its own.

A subject still has to pass Rule 2, and the interesting cases fail on its
second test. `net.crawl` has vocabulary of its own — robots, sitemaps, a
frontier — but the engine *is* an HTTP client with a queue in front of it, so
it is entangled with `net.http` and stays inside `net`. Terminal output has the
same shape: ANSI codes and cursor addressing came from outside Dart, but
`ConsoleWriter` is the thing holding the file descriptor, which is a touch and
not a topic. It is `system.console`.

---

## Rule 2 — Does it earn a top-level name?

A top-level name costs every user of the library an identifier in their global
scope. It has to buy that back. All five must hold:

1. **It is a whole tool, not an operation.** `zip.pack` / `unpack` / `list` /
   `read` / `bundle` / `deflate` / `inflate` is a coherent vocabulary about one
   subject. A single function is never a domain.
2. **It shares nothing with its neighbours.** `tool.git` and `tool.zip` reach
   the filesystem and subprocesses through `io` and `system`, but no `io` or
   `system` call needs them back. A one-directional dependency is fine — `cli`
   resolves an option's `env:` fallback through `system.env` and wraps its
   usage text to `ConsoleWriter().width`, and is still its own domain. What
   disqualifies a candidate is a domain needing it *back*; then it is a
   sub-namespace of that domain, not a peer.
3. **Its name is distinctive.** `cli`, `git` and `zip` are jargon; almost
   nobody has a local variable called any of them. `text`, `hash`, `size`,
   `time`, `rand` and `store` are words people use constantly, so they keep a
   prefix. If you would hesitate to shadow it, prefix it.
4. **Flattening reads better.** `cli.flag('force')` beats
   `system.cli.flag('force')`, and `util.text.slug(...)` is worth the third
   level because `text.slug(...)` at top level would be a collision waiting to
   happen.
5. **It is not one of a family.** This is the test `git` fails. It passes the
   first four cleanly — and so would `docker`, `ssh`, `gh` and `ffmpeg`, each
   of which a script eventually wants. A name that arrives with siblings does
   not take the top level; the family does. So `tool.git` and `tool.zip` now,
   and `tool.docker` later at no further cost. `cli` has no siblings: a script
   has exactly one command line.

Failing test 5 makes it a member of the family that covers it. Failing any of
the first four makes it a sub-namespace or a plain member.

---

## Rule 3 — Sub-namespace or plain member?

A sub-namespace is for a **cohesive vocabulary with its own nouns**: `io.csv`
has rows, delimiters and headers; `io.store` has keys and a backing file;
`system.console` has a writer, a reader and a cursor. Each would be a domain if
Rule 2 let it.

Everything else is a plain member of the domain. `io.hash(path)` is one
operation about a file, so it sits directly on `io` — it does not need an
`io.hash.*` of its own. `cli.parse`, `cli.flag` and `cli.option` sit directly
on `cli` for the same reason: flags and options are the domain's whole subject,
not a corner of it.

`io.async` is the one structural sub-namespace: it mirrors `io` exactly, one
name for one name, so the blocking and non-blocking forms never differ except
in the prefix. Use that shape only for a complete mirror, never for a partial
one.

---

## Rule 4 — Naming

**Lowercase. One word if one word will do.**

```dart
res.pick(Field.text('h1'));       // pick, text
robots.allowed(url);              // allowed
robots.delay(agent: 'MyBot');     // delay
dedupe.seen(url);                 // seen
util.text.slug('Hello, World!');  // slug
tool.zip.pack('site', 'site.zip');// pack
cli.flag('force');                // flag
```

When one word genuinely will not do, join the words and stay lowercase. Never
camelCase:

```dart
.perhost()      // not perHost
.samehost()     // not sameHost
cookie.httponly // not httpOnly
style.topleft   // not topLeft
Ansi.brightred  // not brightRed
```

Reach for the second word only after trying: a shorter synonym (`generateHelp`
became `usage`), the noun instead of the phrase (`maxPermits` became
`permits`), dropping a redundant prefix (`robotsUserAgent` became `agent`,
because it is already on a robots API), or splitting the concept
(`Engine.robots` the flag became `obey`, freeing `robots(url)` for the lookup).

**Prefer the word that makes the call site read as English.** `res.decode({})`
over `res.jsonOr({})`; `dedupe.tracked(request)` over `hasRequest(request)`;
`writer.error(msg)` over `writeErr(msg)`. The name is read far more often than
it is written.

**The name has to say what the call does.** A name that only says *when* or
*where* is not a name: `system.now()` became `system.shutdown()` because what
it does is shut down, `crawl.to(path)` became `crawl.save(path)`, and
`Store.map()` became `Store.all()` because it was never `Iterable.map`. If you
cannot tell what a call does from its name alone, it is the wrong name.

Three names are exempt, because they are contracts rather than choices:

- `dart:core` interface members — `toString`, `hashCode`, `isEmpty`,
  `isNotEmpty`, `iterator`, `length`, `noSuchMethod`, `toJson`.
- Third-party members you are calling, not declaring — `element.outerHtml`,
  `request.followRedirects`.
- Type names, which stay `UpperCamelCase` as Dart requires: `Reply`,
  `CookieJar`, `QueryResult`.

Anything that cannot follow the rule and is not one of those three should be
private instead. `Reply.extractFromElement` became `Field.readAll` when the extraction types moved to the selector library;
`Morsel.parseAll` and `Morsel.defaultPath` became private; the tuning constants
behind the bounded caches are `_emitBufferLimit` and friends. If a name is not
worth spelling well, it is not worth exporting.

---

## Rule 5 — Every name appears exactly once

There are no aliases and no flat shortcuts. Each operation is reachable exactly
one way, so there is never a question of which spelling to use.

This has removed real API: `QueryResult.val()` duplicated `value`; the CLI
declarations accepted both `def` and `defaultValue`; `ConsoleWriter` carried
`createTable`, `progress` and `spinner` that `ConsoleAccessor` already had. All
went. It is also why a name that moves leaves nothing behind: `system.cli`,
`git` and `zip` were deleted when they became `cli`, `tool.git` and `tool.zip`,
rather than kept as deprecated forwards. A migration is one edit; two spellings
is forever.

The rule also settles collisions in the other direction. `io.hash(path)` hashes
a file and `util.hash.sha(value)` hashes a value — different inputs, different
domains, no overlap. But two entry points to the *same* behaviour is always a
bug in the API, not a convenience.

---

## Rule 6 — Real types at the boundary

URLs are `Uri`, delays are `Duration`, paths are `String`. Bodies, hash
algorithms and extraction fields are sealed types and enums — `Body`, `Algo`,
`Field`, `Format` — so a wrong call fails in the analyzer rather than at
runtime. No `Object` or `dynamic` in a public signature unless the value really
is arbitrary JSON.

### The exemptions that stand

Four public signatures still say `Object?`, and each is the case the rule
exempts — a value that really is arbitrary. They are listed here so the next
sweep does not re-litigate them:

| Signature | Why |
| :--- | :--- |
| `Body.json(Object? data)` | Anything `jsonEncode` accepts. A type here would be a JSON type, which Dart does not have. |
| `io.dump(path, Object? data)` | The same, on the way to a file. |
| `Table.add(List<Object?> row)` | Cells are rendered with `toString`; that *is* the contract. |
| `logger.info(msg, fields: {...})` | Structured log fields, encoded straight to JSON. |
| `Meta.raw`, `Store.all()` | The escape hatch under a typed API, deliberately shaped like the JSON it holds. |
| `res.extract(schema)`, `Field.of`, `NestField`, `ListField` | The string shorthand, which this rule blesses *alongside* the typed form. Its whole job is to accept a loose spec; `all`/`one`/`pick` are the typed twin. |

Everything else that used to claim the exemption was closed in 2.0.0 — see
`PLAN-2.0.0.md`. `Fetch.meta` and `io.store` became `Slot` keys, `res.extract`
gained a typed twin in records and `Field`, `cli.get<T>` became `Opt`,
`Pool.settle` became a sealed `Settled`, and the methods that took an `Object`
and threw `ArgumentError` for the wrong shape were split in two.

Where a shorthand is genuinely more ergonomic, it goes *alongside* the typed
form rather than replacing it: `res.extract` takes the string schema,
`res.pick(Field.text(...))` takes the typed one, and they mix in one call.

**A type name is global no matter how deep its namespace.** `tool.zip.pack` is
three levels down; the `Format` and `Entry` it returns are still dropped into
the scope of everyone who imports the library. So a type has to clear a bar the
accessors do not: it must not collide with `dart:core`, `dart:io`, or the
packages a user of this one is likely to import alongside it. That test is
mechanical — write `import 'dart:io'; import 'package:crypto/crypto.dart';`
next to the library import and see whether the analyzer complains. It is how
`Digest` and `Process<T>` were caught.

The analyzer only complains where a name is *used*, though, which is why
running the test on two names found two names. Running it on all 102 exported
types found three more.

### Resolved in 2.0.0

1.7.0 recorded five exported type names that failed this rule and renamed none
of them, because the fix was a rename of the library's most-used vocabulary.
2.0.0 spent it.

| 1.x name | Collided with | What used to happen | 2.0.0 name |
| :--- | :--- | :--- | :--- |
| `HttpClient` | `dart:io` | The package import won, silently | `Fetcher` |
| `HttpResponse` | `dart:io` | The package import won, silently | `Reply` |
| `Cookie` | `dart:io` | The package import won, silently | `Morsel` |
| `Request<T>` | `package:http` | `ambiguous_import`, on use | `Fetch<T>` |
| `Response<T>` | `package:http` | `ambiguous_import`, on use | `Page<T>` |

The first three were the dangerous ones: no diagnostic at all, the way
`Process<T>` failed before 1.6.0. A file importing `dart:io` and this library
together got this library's `HttpClient` and was never told.

`CookieJar` keeps its name — it collides with nothing, and it says what it
holds. The jar/morsel pairing is `http.cookies`', which is where `Morsel`
comes from.

So the `hide` clause 1.7.0 needed is gone:

```dart
import 'dart:io';                                  // HttpClient is dart:io's
import 'package:dart_toolkit/dart_toolkit.dart';   // Fetcher is this one's
```

The pin is in `test/regression_test.dart`, which imports `dart:io` both
unprefixed and as `dart_io` and asserts that the unprefixed names now resolve
to `dart:io`'s.

New names still have to pass the rule outright. The sweep is a script, not a
judgement: list every exported `class`, `enum`, `typedef` and `extension`, and
look each one up in `dart:core`, `dart:io`, `dart:async`, `dart:convert` and
every package in `pubspec.yaml`.

---

## Adding something new

1. Apply Rule 1. Axis or subject — and then, which one?
2. Apply Rule 2. Its own name, a slot in a family, or inside a domain?
3. Apply Rule 3. Sub-namespace, or a plain member?
4. Name it by Rule 4. Say the call site out loud.
5. Check Rule 5. Does this behaviour already exist somewhere?
6. Check Rule 6. Are the parameters and the return real types — and does the
   type name survive being imported next to `dart:io`?
7. Document it, and add the sample to `docs/`. `test/doc_samples_test.dart`
   compiles every snippet in `docs/`, so a stale example fails the build.

---

## Where past decisions landed

| Candidate | Decision | Why |
| :--- | :--- | :--- |
| CLI parsing | `cli`, top level, out of `system` | Parsing a `List<String>` touches nothing, so Rule 1's axis test would have filed it under `util`; it is a subject, not an axis. Its `env:` fallbacks and usage wrapping reach into `system`, but nothing in `system` reaches back, so Rule 2's second test passes. And a script has one command line, so there is no family to join |
| Git | `tool.git` | Passes the first four Rule 2 tests, fails the fifth: `docker`, `ssh` and `gh` would pass them identically, and a top level that grows a name per wrapper is not a top level. The family takes the name |
| Archives | `tool.zip` | Same. It wraps a format rather than an executable, which is still knowledge from outside Dart — Rule 1's definition of a subject is the format or the binary, not the subprocess |
| Terminal IO | `system.console` | The vocabulary is external, but `ConsoleWriter` holds the file descriptor. Owning the handle is a touch, so it sorts as an axis |
| Text helpers | `util.text` | Pure, but `text` is far too common a word to take at top level |
| Digests | `util.hash` | Pure; `io.hash` stays separate because it streams a file |
| Randomness | `util.rand` | Pure; `rand` alone is too collision-prone |
| Non-blocking IO | `io.async` | A complete mirror of `io`, so it is a prefix rather than new names |
| `Fs`, `Sys`, `Exit` | Unexported, `lib/src/` | Implementation behind `io` and `system`; never a public name |
| Hash algorithm enum | `Digest` became `Algo` | `Digest` was an `ambiguous_import` error against `package:crypto`, whose `Digest` is a hash *result* where this one selects an *algorithm*. `lib/src/fs.dart` was already writing `crypto.Digest` to name the other one |
| A pipeline's page handler | `Process<T>` became `Handler<T>` | Dart resolves a package import over a `dart:` one silently, so exporting `Process` meant `Process` stopped meaning `dart:io`'s for every user of the library — while `system.adopt(Process)` still meant that one. A shadow with no error is worse than a collision with one |
| HTTP caching | `HttpCache` type, `Fetcher(cache:)`, `crawl.cache(dir)` | A whole tool by Rule 2's first test, but entangled with `net.http` by its second: the client is what decides to revalidate. So a type in `net` and an option on the two things that fetch, not a domain and not a namespace |
| A crawl's position | `Snapshot` + `Engine.snapshot`/`restore`, `crawl.resume(path)` | The type is the noun, the engine pair is the operation, and `resume` is the two of them wired to a file. `save` was taken by "write items to", and Rule 5 forbids a second meaning for it |
| A request that failed | `Failure`, passed to `on.error` | A count without the pages is not an answer. Widening the handler's argument list would have fixed one question and left the next one — an attempt number, a response — needing another break, so the argument is a type |
| Streaming CSV out | `io.csv.pipe`, beside `write` | Different behaviour, not an alias: `write` takes a collection, `pipe` takes a `Stream` and holds one row. A `CsvWriter` you open and close would have been a new noun and a lifecycle to get wrong |
| A page's forms | `Form`, reached by `res.form(selector)` | Rule 2's first test passes — filling, addressing and submitting is a vocabulary — but its second fails: a form is read out of a response and submitted through the same client or engine, so it is entangled with `net` and lives there as a type rather than a domain. No accessor, because there is nothing to reach it from but the page it is on |
| Submitting one in a crawl | `res.submit(form)`, beside `res.follow` | `follow` already takes a `method` and a `body`; this is the same operation with the three details read off the form instead of typed out, so it sits next to it rather than inside `Form`, which knows nothing about an engine |
| Terminal geometry | `ConsoleWriter.width` / `.height`, moved off `Terminal` | Geometry belongs to the thing that knows where the output is going — and to the thing a test can size. `Terminal` keeps what it is named for: the control codes |
