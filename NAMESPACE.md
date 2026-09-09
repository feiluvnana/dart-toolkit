# Namespaces

How this library decides where something lives and what it is called. Read this
before adding a public name; it is the rule set the current layout follows, and
following it is what keeps the surface small enough to hold in your head.

---

## The map

| Domain | Holds | Sub-namespaces |
| :--- | :--- | :--- |
| `io` | The filesystem: paths, atomic writes, reads | `io.csv`, `io.store`, `io.async` |
| `net` | The network: requests, downloads, crawling, parsing what comes back | `net.http`, `net.crawl` |
| `system` | This program and the machine running it | `system.env`, `system.cli`, `system.console`, `system.on` |
| `concurrent` | Bounded async work on one isolate | — |
| `git` | The `git` executable | — |
| `zip` | Archives | — |
| `util` | Pure computation | `util.time`, `util.size`, `util.text`, `util.hash`, `util.rand` |
| `$` / `$xpath` | Selectors, opt-in via `package:dart_toolkit/selector.dart` | — |

---

## Rule 1 — Which domain?

Ask what the operation *touches*, not what it is about. Take the first match:

1. **Does it read or write files?** → `io`
2. **Does it open a socket?** → `net`
3. **Does it start a process, read the environment, or talk to the terminal or
   the user?** → `system`
4. **Does it schedule other work?** → `concurrent`
5. **None of the above — is it a pure function of its arguments?** → `util`

`util` is the only domain defined by an absence. Nothing in it may touch the
disk, the network, the clock's timezone database, or a process. `util.time.wait`
is the closest call: it schedules a delay but owns no resource and observes
nothing, so it stays.

This is why `zip` did not stay in `util` and `git` did not stay there either.
Packing a folder is filesystem work; querying a branch runs a subprocess. Once
that was clear, the question became whether they belonged *inside* `io` and
`system` or beside them — which is Rule 2.

---

## Rule 2 — Does it earn a top-level domain?

A top-level name costs every user of the library an identifier in their global
scope. It has to buy that back. All four must hold:

1. **It is a whole tool, not an operation.** `zip.pack` / `unpack` / `list` /
   `read` / `bundle` / `deflate` / `inflate` is a coherent vocabulary about one
   subject. A single function is never a domain.
2. **It shares nothing with its neighbours.** `zip` and `git` reach the
   filesystem and subprocesses through `io` and `system`, but no `io` or
   `system` call needs them back. If a candidate is entangled with a domain,
   it is a sub-namespace of that domain, not a peer.
3. **Its name is distinctive.** `git` and `zip` are jargon; almost nobody has a
   local variable called either. `text`, `hash`, `size`, `time`, `rand` and
   `store` are words people use constantly, so they keep a prefix. If you would
   hesitate to shadow it, prefix it.
4. **Flattening reads better.** `zip.pack('site', 'site.zip')` beats
   `io.zip.pack(...)`. `util.text.slug(...)` is worth the third level because
   `text.slug(...)` at top level would be a collision waiting to happen.

Failing any one of these makes it a sub-namespace or a plain member.

---

## Rule 3 — Sub-namespace or plain member?

A sub-namespace is for a **cohesive vocabulary with its own nouns**: `io.csv`
has rows, delimiters and headers; `io.store` has keys and a backing file;
`system.cli` has flags, options and subcommands. Each would be a domain if its
name were distinctive enough.

Everything else is a plain member of the domain. `io.hash(path)` is one
operation about a file, so it sits directly on `io` — it does not need an
`io.hash.*` of its own.

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
zip.pack('site', 'site.zip');     // pack
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
- Type names, which stay `UpperCamelCase` as Dart requires: `HttpResponse`,
  `CookieJar`, `QueryResult`.

Anything that cannot follow the rule and is not one of those three should be
private instead. `HttpResponse.extractFromElement` became `_extractFrom`;
`Cookie.parseAll` and `Cookie.defaultPath` became private; the tuning constants
behind the bounded caches are `_emitBufferLimit` and friends. If a name is not
worth spelling well, it is not worth exporting.

---

## Rule 5 — Every name appears exactly once

There are no aliases and no flat shortcuts. Each operation is reachable exactly
one way, so there is never a question of which spelling to use.

This has removed real API: `QueryResult.val()` duplicated `value`; the CLI
declarations accepted both `def` and `defaultValue`; `ConsoleWriter` carried
`createTable`, `progress` and `spinner` that `ConsoleAccessor` already had. All
went.

The rule also settles collisions in the other direction. `io.hash(path)` hashes
a file and `util.hash.sha(value)` hashes a value — different inputs, different
domains, no overlap. But two entry points to the *same* behaviour is always a
bug in the API, not a convenience.

---

## Rule 6 — Real types at the boundary

URLs are `Uri`, delays are `Duration`, paths are `String`. Bodies, hash
algorithms and extraction fields are sealed types and enums — `Body`, `Digest`,
`Field`, `Format` — so a wrong call fails in the analyzer rather than at
runtime. No `Object` or `dynamic` in a public signature unless the value really
is arbitrary JSON.

Where a shorthand is genuinely more ergonomic, it goes *alongside* the typed
form rather than replacing it: `res.extract` takes the string schema,
`res.pick(Field.text(...))` takes the typed one, and they mix in one call.

---

## Adding something new

1. Apply Rule 1. Which domain does it touch?
2. Apply Rule 2. Peer domain, or inside that one?
3. Apply Rule 3. Sub-namespace, or a plain member?
4. Name it by Rule 4. Say the call site out loud.
5. Check Rule 5. Does this behaviour already exist somewhere?
6. Check Rule 6. Are the parameters and the return real types?
7. Document it, and add the sample to `docs/`. `test/doc_samples_test.dart`
   compiles every snippet in `docs/`, so a stale example fails the build.

---

## Where past decisions landed

| Candidate | Decision | Why |
| :--- | :--- | :--- |
| Archives | `zip`, top level | A whole tool, entangled with nothing, distinctive name, reads better flat |
| Git | `git`, top level | Same, and it wraps an external executable rather than extending `system` |
| Terminal IO | `system.console` | Talks to the OS and the user; pairs with `system.cli` |
| Text helpers | `util.text` | Pure, but `text` is far too common a word to take at top level |
| Digests | `util.hash` | Pure; `io.hash` stays separate because it streams a file |
| Randomness | `util.rand` | Pure; `rand` alone is too collision-prone |
| Non-blocking IO | `io.async` | A complete mirror of `io`, so it is a prefix rather than new names |
| `Fs`, `Sys`, `Exit` | Unexported, `lib/src/` | Implementation behind `io` and `system`; never a public name |
