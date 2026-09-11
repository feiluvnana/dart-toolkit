# Namespaces

How this library decides where something lives and what it is called. Read this
before adding a public name; it is the rule set the current layout follows, and
following it is what keeps the surface small enough to hold in your head.

---

## The map

| Domain | Holds | Sub-namespaces |
| :--- | :--- | :--- |
| `io` | The filesystem: paths, atomic writes, reads, watching (`io.watch`), locking, the collections on disk (`io.dictionary`, `dump`) | `io.csv`, `io.async` |
| `net` | The network: requests, downloads, crawling — and, in the other direction, listening. It parses nothing | `net.http`, `net.crawl` |
| `system` | This program and the machine running it, and what happens to its resources when it is interrupted (`system.on`) | `system.env`, `system.console`, `system.on` |
| `concurrent` | Bounded async work on one isolate: how many at once, and how often | — |
| `util` | Pure computation, the two document cursors (`Json`, `Markup`) and the codec seam (`Codec`) that carries them across domains | `util.time`, `util.size`, `util.text`, `util.hash`, `util.rand` |
| `collection` | The two collections this library returns in place of Dart's (`Sequence`, `Dictionary`), the two operation types that shape them (`Transformer`, `Collector`) and the typed keys (`Slot`). No accessor — a library, not a `collection.something` you call | — |
| `cli` | The command line your script presents to whoever runs it | — |
| `format` | One file format per name — never an executable | `format.html`, `format.json`, `format.yaml`, `format.toml`, `format.zip` |

`$` and `$xpath` had a row of their own here through 3.2.0. They are the jQuery
spelling of `format.html.parse`, still opt-in via
`package:dart_toolkit/html.dart`, and no longer a domain — see Rule 2's fifth
test. 5.0.0 made them methods, and removed the copies that had been sitting on
`Element` and `Document` on the *default* surface all along.

The first five are **axes**; `cli` and `format` are **subjects**. Rule 1 is
about telling them apart, because they are sorted by different questions.

`collection` is neither, and that is why it has no accessor. It is a
vocabulary, not a way of touching anything: every name in it is reached from a
value you already hold. 5.1.0 moved it out of `util`, which had been holding
two unrelated things — functions you call (`time`, `size`, `text`, `hash`,
`rand`) and types you receive. The sequence vocabulary was the largest of the
second kind and it grew two more types and a dozen namespaces, which is
Rule 3's test for a sub-namespace (*a cohesive vocabulary with its own nouns*)
described exactly. It is not a sub-namespace of `util` because nothing in
`util` reaches it; it is a peer. `Json` and `Markup` stayed: they are cursors
over documents, not collections.

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

`cli` for the command line, `format.*` for a file format. A new subject joins
`format` unless Rule 2 says it has earned a name of its own — and selectors,
which had a top-level `$` of their own until 4.0.0, are a *format*: HTML.

**An executable is not a subject; the thing it knows is.** `tool.git`,
`tool.gh` and `tool.docker` were all built and all removed: a wrapper carries
only the subcommands somebody thought to add, while `system.run` carries the
whole binary and already returns a `SysResult` instead of throwing on a
non-zero exit. So `format` holds formats — `html`, `json`, `yaml`, `toml`,
`zip` — and shelling out is `system.run`, paired with `system.which` for "is it
installed". The domain was called `tool` until 4.0.0, which is part of how
those three wrappers got in: a name that says nothing cannot turn anything
away.

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
2. **It shares nothing with its neighbours.** `format.zip` and `format.yaml` reach
   the filesystem through `io`, but no `io` call needs them back. A one-directional dependency is fine — `cli`
   resolves an option's `env:` fallback through `system.env` and wraps its
   usage text to `ConsoleWriter().width`, and is still its own domain. What
   disqualifies a candidate is a domain needing it *back*; then it is a
   sub-namespace of that domain, not a peer.
3. **Its name is distinctive.** `cli` and `zip` are jargon; almost nobody has
   a local variable called either. `text`, `hash`, `size`, `time`, `rand` and
   `json` are words people use constantly, so they keep a prefix. If you would
   hesitate to shadow it, prefix it. `collection` fails this outright — every
   Dart project imports `package:collection` — which is one of the reasons it
   is a library with no accessor rather than a name in your global scope.
4. **Flattening reads better.** `cli.flag('force')` beats
   `system.cli.flag('force')`, and `util.text.slug(...)` is worth the third
   level because `text.slug(...)` at top level would be a collision waiting to
   happen.
5. **It is not one of a family.** This is the test `zip` fails. It passes the
   first four cleanly — and so would `json`, `yaml`, `toml` and `xml`, each of
   which a script eventually wants. A name that arrives with siblings does
   not take the top level; the family does. So `format.zip` first, then
   `format.json`, `format.yaml` and `format.toml` at no further structural cost — the
   slot was pre-paid. `cli` has no siblings: a script has exactly one command
   line.

   **`$` is the second name to fail this test, and the instructive one.** It
   took the top level in 1.x, when HTML was the only format this library knew
   and it had no siblings to be one of. By 3.2.0 it had three, and it was still
   sitting in the map as a domain — because it had arrived first, not because
   it had earned anything the others had not. It joined the family in 4.0.0 as
   `format.html`, and the jQuery spelling stayed as an opt-in import. A name
   passes or fails test 5 against the library it is in *now*, not the one it
   entered.

Failing test 5 makes it a member of the family that covers it. Failing any of
the first four makes it a sub-namespace or a plain member.

---

## Rule 3 — Sub-namespace or plain member?

A sub-namespace is for a **cohesive vocabulary with its own nouns**: `io.csv`
has rows, delimiters and headers; `system.console` has a writer, a reader and a
cursor. Each would be a domain if Rule 2 let it.

The same test decides a *type*'s namespace, and 5.1.0 is where that started
mattering. `Transformer.take` and `Collector.count` are namespace objects
holding three members and three members — `take.first`, `take.last`,
`take.when` — and they exist for the reason `io.csv` does: the second word has
somewhere to go. See Rule 4's splitting rule.

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

```dart no-compile
res.parse(format.html).pick(Field.text('h1'));       // pick, text
robots.allowed(url);              // allowed
robots.delay(agent: 'MyBot');     // delay
dedupe.seen(url);                 // seen
util.text.slug('Hello, World!');  // slug
format.zip.pack('site', 'site.zip');// pack
cli.flag('force');                // flag
```

When one word genuinely will not do, join the words and stay lowercase. Never
camelCase:

```dart no-compile
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

### The splitting rule

**Where Dart or Kotlin spells an operation as a camelCase compound, split it at
the capital rather than renaming it.**

```dart no-compile
take.when(t)      // takeWhile
first.where(t)    // firstWhere
where.type<R>()   // whereType
flat.map(f)       // flatMap
group.by(f)       // groupBy
count.by(f)       // countBy
max.by(f)         // maxBy
sort.by(f)        // sortBy
index.of(v)       // indexOf
```

This is the rule 5.1.0 added, and it is the one that paid for the rest of that
release. Banning camelCase and leaving the surface flat is what produced most
of `Sequence`'s private dialect: `takeWhile` could not be a member, so it became
`until`; `mapNotNull` became `sift`; `maxBy` became `best`; `countBy` became
`tally`; `associateBy` became `keyed`. Every one of those renames was forced by
a *spelling*, not by a meaning, and every one cost a reader a lookup.

Nothing is invented by splitting. The name on the right is the name on the left
with the capital turned into a dot, which is a rule a reader learns once. Two
words are not available, because Dart reserves them: `while`, so `takeWhile` is
`take.when`; and `for`, so `forEach` is `foreach` rather than `for.each`.

A namespace is also what lets an operation take back a name that collided.
`map` was renamed to `to` because `Map` is a type in every file, and `where` to
`keep` because `Iterable.where` is one autocomplete away. Neither collision
exists inside `Transformer`, so both names came back.

**Prefer the word that makes the call site read as English.** `res.parse(format.json).raw ?? ({})`
over `res.jsonOr({})`; `dedupe.tracked(request)` over `hasRequest(request)`;
`writer.error(msg)` over `writeErr(msg)`. The name is read far more often than
it is written.

**The name has to say what the call does.** A name that only says *when* or
*where* is not a name: `system.now()` became `system.shutdown()` because what
it does is shut down, `crawl.to(path)` became `crawl.save(path)`, and
`Store.map()` became `Store.all()` because it was never `Iterable.map` — a name
the class outlived, since `Dictionary.map` *is* the boundary word now. If you
cannot tell what a call does from its name alone, it is the wrong name.

**Keep the existing word when the existing word is the right one.** A
replacement vocabulary is not a rename spree, and the burden is on the rename.
`Collector` took Dart's `fold`, `cast`, `join`, `zip`, `any`, `all` and `count`
unchanged; `Transformer` took `map`, `where`, `take`, `skip` and `sort`. Where
5.0.0 had a word of its own for one of these, 5.1.0 gave it back — and the
lesson it recorded is that **a rename forced by a spelling is not a rename, it
is a workaround**. Thirteen of `Sequence`'s fifty-eight members were one, and
eight of the thirteen were forced by the camelCase ban alone.

**No complement pair where `!` does the job.** If putting `!` in front of the
call gives the other meaning, there is one member, not two. So `empty` exists
and `notEmpty` does not — `!dict.empty` is already the answer — and `any(t)`
exists while `none(t)` does not, because `!any(t)` *is* `none`. `keep(t)` and
`omit(t)` both stood through 5.0.0 on the grounds that negating the filter meant
rewriting the lambda rather than the call — but that was only true because
`keep` was not a filter's ordinary name. `where((r) => !r.live)` reads as the
other side, so `omit` went with the rename. The line is where `!` genuinely
stops working: `max.by`/`min.by` both stand, since negating a maximum does not
give a minimum.

**A nullable return deletes a whole family.** Kotlin needs `first` and
`firstOrNull`, `single` and `singleOrNull`, `maxBy` and `maxByOrNull`,
`elementAt` and `elementAtOrNull`, plus `getOrElse` — ten names for five
questions, because half of them throw. Everything here returns `T?`, so there
are five, and `?? x` replaces `getOrElse`. That is the same contract
`Slot.read`, `Field.text`, `Json.text` and `util.time.parse` keep, and the
reason is unchanged: the caller asked for a value and the honest answer is that
there is not one.

**A record replaces a variant.** `withIndex`, `mapIndexed` and `forEachIndexed`
are three names for one idea; `enumerate()` gives `Sequence<(int, T)>` and
`map`/`foreach` handle the rest. `split` and `unzip` return records rather than
a `Pair` type, `Slot.call` gives `(String, Object?)` rather than a `MapEntry`,
and `system.os` is one record rather than five loose members.

Three names are exempt, because they are contracts rather than choices:

- `dart:core` interface members — `toString`, `hashCode`, `isEmpty`,
  `isNotEmpty`, `iterator`, `length`, `noSuchMethod`, `toJson`.
- Third-party members you are calling, not declaring — `element.outerHtml`,
  `request.followRedirects`.
- Type names, which stay `UpperCamelCase` as Dart requires: `Reply`,
  `CookieJar`, `Markup`.

Anything that cannot follow the rule and is not one of those three should be
private instead. `Reply.extractFromElement` became `Field.readAll` when the extraction types moved to the markup library;
`Morsel.parseAll` and `Morsel.defaultPath` became private; the tuning constants
behind the bounded caches are `_emitBufferLimit` and friends. If a name is not
worth spelling well, it is not worth exporting.

---

## Rule 5 — Every name appears exactly once

There are no aliases and no flat shortcuts. Each operation is reachable exactly
one way, so there is never a question of which spelling to use.

This has removed real API: `Markup.val()` duplicated `value`; the CLI
declarations accepted both `def` and `defaultValue`; `ConsoleWriter` carried
`createTable`, `progress` and `spinner` that `ConsoleAccessor` already had. All
went. It is also why a name that moves leaves nothing behind: `system.cli`,
`git` and `zip` were deleted when they became `cli` and `format.zip`, `tool.*`
left nothing behind when it became `format.*`, and `Reply.$`, `Reply.json`,
`Reply.at`, `Reply.doc`, `Reply.extract` and `Reply.pick` were all deleted in
4.0.0 rather than forwarded to `res.parse(codec)`. A migration is one edit; two
spellings is forever.

5.0.0 was the first release to run this rule against the library rather than
against the next thing added to it, and it found nine more:

| Deleted | Was |
| :--- | :--- |
| `Markup.href` / `hrefs` / `src` / `srcs`, `Element.href` / `src` | `attr`/`attrs` with a literal — six members for two attribute names |
| `Markup.call`, so `page(sel)` | `find`, and on an XPath cursor silently `xpath` instead |
| `Mutex`, `concurrent.mutex()` | `Semaphore(1)` — a whole exported type for one argument |
| `concurrent.compute` | `Isolate.run`, one line |
| `Sequence.union`, `Sequence.findlast` | `plus().unique()`, `flip.find()` |
| `cli.rest`, `cli.subcommand` | `args` minus its first element; an `if` with a callback |
| `concurrent.retry`'s `times:` | `retries:`, documented as *pass one or the other* |
| `Semaphore.acquire` / `withPermit` | a second dialect of `Limiter.take` / `guard` — and the library's one camelCase member |
| `$` / `$xpath` on `Element` and `Document` | `element.query`, and on the *default* surface, which is what the survivor below is explicitly not |

The pattern in most of them is a member that reads *better* than what it wraps.
`page.find('a').href` is nicer than `attr('href')`, which is exactly the
argument this rule exists to refuse — and it never covered anything, because
the next attribute a script wants is `data-id`.

The one survivor is deliberate and is not a second spelling of anything on the
default surface: `$` and `$xpath` stay as an opt-in import, because jQuery's
`$` is the exact thing Rule 1 means by a subject arriving with its own
vocabulary, and a script that does not want an identifier called `$` never
sees one. 5.0.0 made them methods rather than getters, so the opt-in spelling
carries its own selector argument instead of leaning on a `Markup.call` sitting
on the surface it opted out of.

5.1.0 ran it again, over a vocabulary rather than over a surface, and deleted
four more:

| Deleted | Was |
| :--- | :--- |
| `Meta`, `Store`, `StoreAccessor`, `io.store` | `Dictionary<String, Object?>` and the `Slotted` extension — two classes, nine identical members apiece, because the library had no name for "a map with typed keys" |
| `extension MapSequenced on Map` | the escape hatch out of the raw `Map` that `group`, `keyed` and `tally` handed back; they hand back a `Dictionary` now, so nothing needs to climb back in |
| `Sequence.omit`, `Sequence.order`, `Sequence.tally`, `Sequence.keyed` | `where((x) => !t(x))`, `sort.using(cmp)`, `count.by(f)`, `associate.by(f)` |
| `Store.load` / `save` / `attach` / `path` / `open` | `io.dictionary(path)` and `dump(path)` — the pair that made a collection secretly own a file, and a process-wide mutable singleton with it |

The rule also settles collisions in the other direction. `io.hash(path)` hashes
a file and `util.hash.sha(value)` hashes a value — different inputs, different
domains, no overlap. But two entry points to the *same* behaviour is always a
bug in the API, not a convenience.

The narrow carve-out is a shorthand **defined as** the general form, in one
line, where the shorthand is what a script actually writes: `io.csv.pipe`
beside `write`, and `Collector.count.by(f)` beside `group.into(f, .count())`.
One implementation, two spellings of a *call* — not two implementations.

**It is also why `Sequence` is a type rather than an extension**, and why
`Dictionary` is not a `Map`. An extension member never overrides an instance
member: declare `map` on `Iterable` and `dart:core`'s wins, silently, with no
diagnostic — the `HttpClient` shape of bug again. So an extension could only
*add* names beside Dart's, which is exactly what this rule forbids. Replacing a
vocabulary means replacing the static type, which is the whole reason
`Sequence<T>` does not implement `Iterable<T>` and why `Markup` stopped
mixing it in. `test/regression_test.dart` pins that property, because a future
`implements Iterable<T>` added for convenience would quietly undo it and
nothing else would notice.

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
| `format.json.format(Object? value)` | The same, on the way to a string. `Json.raw` is the read direction. |
| `util.text.render(template, Map<String, Object?>)` | Template values, rendered with `toString`; that *is* the contract. |
| `Table.add(List<Object?> row)` | Cells are rendered with `toString`; that *is* the contract. |
| `logger.info(msg, fields: {...})` | Structured log fields, encoded straight to JSON. |
| `Dictionary<String, Object?>` under `Slot` | The escape hatch under a typed API, deliberately shaped like the JSON it holds. `read`/`write` are the typed twin. |
| `res.parse(format.html).extract(schema)`, `Field.of`, `NestField`, `ListField` | The string shorthand, which this rule blesses *alongside* the typed form. Its whole job is to accept a loose spec; `all`/`one`/`pick` are the typed twin. |

5.0.0 closed the last two places where a URL was not a `Uri`:
`net.crawl(target)` took a `String`, one line from `net.crawl.sitemap(Uri)` and
one call from `net.http.get(Uri)`, and it doubled as a raw-HTML seed depending
on what the string looked like — the untyped overload this rule is for.
`Served.redirect(location)` took one too. `net.crawl.html(markup)` and
`net.crawl.file(path)` keep their `String`, because markup is not a URL and
neither is a path, and `Page.follow` keeps one because a relative reference is
what it is handed and resolving it is the method's job.

Everything else that used to claim the exemption was closed in 2.0.0.
`Fetch.meta` and the key-value store became `Slot` keys, `res.extract` gained a typed
twin in records and `Field`, `cli.get<T>` became `Opt`, `Pool.settle` became a
sealed `Settled`, and the methods that took an `Object` and threw
`ArgumentError` for the wrong shape were split in two.

3.0.0 closed the last two: `Reply.json` and `io.json` were both `Object?`, and
both now have a typed door in `Reply.at` and `format.json.read`, which return the
[`Json`] cursor. `Reply.json` stays as the raw escape hatch, the way
`Dictionary.map` does under a `Slot`.

Where a shorthand is genuinely more ergonomic, it goes *alongside* the typed
form rather than replacing it: `res.extract` takes the string schema,
`res.parse(format.html).pick(Field.text(...))` takes the typed one, and they mix in one call.

**A type name is global no matter how deep its namespace.** `format.zip.pack` is
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

### Swept clean in 3.x

Every type 3.0.0 through 3.2.0 added went through the sweep before it was
built, in a file declaring each name beside imports of `dart:core`, `dart:io`,
`dart:async`, `dart:convert`, `dart:math` and all nine packages in
`pubspec.yaml`: `Sequence`, `Json`, `Server`, `Served`, `Asked`, `Limiter`,
`LockedError`. No collision, no shadow, no warning.

`Server` was the one to watch — it is close to `HttpServer` in the way
`HttpClient` was close, and that shadow was silent. `Served` and `Asked` exist
precisely because `Response` and `Request` were spent once already and renamed
out of; a type called `Request` sitting beside `package:http`'s and `dart:io`'s
is the bug this rule is for.

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
7. Document it, and add the sample to `docs/`. `test/docs_test.dart` compiles
   **every** `dart` block in `docs/`, `README.md`, this file, `example/README.md`
   and every `///` comment under `lib/` — 385 of them, against a set of shared
   fixtures, so a stale example fails the build.

   That claim used to be here and used to be false: the old harness filtered
   to whole programs (`if (!snippet.contains('void main(')) continue;`), which
   was 27 of 244 markdown blocks and none of the 152 in doc comments.
   Everything else rotted unchecked, and 5.0.0's rewrite found doc comments
   still using `tool.json`, `res.$`, `res.form`, `res.pick`, `io.async.json`,
   `cli.has`, `cli.get`, `Failure.request`, `Page(request:)` and
   `meta: {'name': ...}` — API removed as far back as 2.0.0.

   A block that genuinely cannot compile — a signature listing, a naming
   table, a member index — opts out with ` ```dart no-compile `. There are 16,
   and that number is the debt: every one is a line somebody has to justify.
   A fragment that needs a name the fixtures do not carry declares it with a
   `// setup:` comment line.
8. No deprecation shim. Rule 5 settles it: a migration is one edit, and two
   spellings is forever. When a name moves, the old one goes — which is why
   `io.json`, `tool.git`, `tool.gh` and `tool.docker` are gone rather than
   forwarding.

---

## Where past decisions landed

| Candidate | Decision | Why |
| :--- | :--- | :--- |
| CLI parsing | `cli`, top level, out of `system` | Parsing a `List<String>` touches nothing, so Rule 1's axis test would have filed it under `util`; it is a subject, not an axis. Its `env:` fallbacks and usage wrapping reach into `system`, but nothing in `system` reaches back, so Rule 2's second test passes. And a script has one command line, so there is no family to join |
| Archives | `format.zip` | Passes the first four Rule 2 tests, fails the fifth: `json`, `yaml` and `toml` pass them identically, and a top level that grows a name per format is not a top level. The family takes the name. It wraps a format rather than an executable, which is still knowledge from outside Dart — Rule 1's definition of a subject is the format or the binary, not the subprocess |
| Wrapped executables | Deleted; use `system.run` | `tool.git` shipped in 1.x and `tool.gh`/`tool.docker` were added in 3.1.0; all three were removed in 3.2.0. A wrapper only ever carries the handful of subcommands somebody thought to add, while `system.run` carries the whole binary and already returns a `SysResult` rather than throwing for a non-zero exit. Pair it with `system.which` for "is it installed". So `format` holds **formats only**, and Rule 1's "the format or the binary" now means the format |
| HTML | `format.html`, beside `json`, `yaml` and `toml` | It was the top-level `$` through 3.2.0 — the one format Rule 1 was never applied to, because it was there first. `Reply` carried five HTML members and three JSON ones, which is a format table living in a class about HTTP, and it only ever held two rows while a crawler fetches archives, feeds and images too. 4.0.0 moved the codec to `format.html`, the cursor to `util` as `Markup`, and left `net` with one member that names no format: `res.parse(codec)` |
| The seam between them | `Codec<T>`, a one-method interface in `util` | `net` needs to read bodies and `format` needs to read text, and Rule 2's second test forbids either depending on the other. One interface both implement is the whole of it: `net` is handed something that reads bytes and never learns which format it is, which is what makes `res.parse(format.json)` and `res.parse(format.html)` the same call. `read` from a file comes free with it, written once instead of five times |
| Finding a form | `Markup.form`, sending stays in `net` | `res.form('#login')` needed `net` to parse a page, which is the thing 4.0.0 removed. Finding a form is reading markup, so it hangs off the cursor. Sending one is a socket and its output is an `HttpMethod`, a `Uri` and a `Body` — all `net` types — so `Form` stays in `net`, entangled with `net.http` by Rule 2's second test exactly as `net.crawl` is. `Form.at(url)` carries the one thing a cursor cannot know |
| JSON | `format.json`, beside `yaml` and `toml` | It was `util.json` through 3.1.0, on the grounds that decoding is pure. But a format is a *subject*, which is the sentence that admitted `format.zip`, and JSON in one place with YAML in another left a reader asking where formats live. The three codecs are now spelled identically — `parse`, `read`, `format` |
| The `Json` cursor type | `util`, exported bare | The accessor moved; the type could not. `net` hands one back through `Codec`, and a type `net` needs cannot live under `format` without making `format` something `net` depends on — Rule 2's second test. It is a pure value, so `util` is its home. `lib/src/jsontext.dart` is the codec both domains sit on, the way `Fs` backs `io` |
| The `Markup` cursor type | `util`, beside `Json` | The same split, one release later, and named the same way: for what it is over rather than for the operation that produced it. `QueryResult` was a result type named after a query. The 800-line jQuery evaluator behind it went to `lib/src/jquery.dart`, so `util/markup.dart` reads as the vocabulary rather than the machinery |
| The domain's own name | `format`, not `tool` | `tool` was chosen when the domain held one archiver, and it invited precisely the thing its own doc comment spent a paragraph forbidding — three executable wrappers were added under it in 3.1.0 and removed in 3.2.0. `format.zip` cannot be misread as a wrapper around the `zip` binary. Rule 4 says say the call site out loud: `format.yaml.read('config.yaml')` says what it does and `tool.yaml.read(...)` says where it happens to live |
| The sequence API | `Sequence<T>`, a type in `collection` | Rule 2 spends no top-level name: you reach it from the data you already hold, the same argument that put `Form` in `net` with no `net.form`. Not a sub-namespace either — `util.list.group(...)` would be a namespace standing where a receiver belongs. It sat in `util` through 5.0.0; 5.1.0 moved it out, because `util` was holding both functions you call and types you receive, and the collections are the largest of the second kind |
| The sequence *vocabulary* | `Transformer` and `Collector`, not methods on `Sequence` | Fifty-eight members, a third of them words invented for an operation everybody already knew, and eight of those forced by nothing but the camelCase ban. A namespace has no `Map` to collide with and no compound to forbid, so `map`, `where`, `take.first` and `count.by` all became sayable. Java's `Collectors` is the same design, twenty years old and uncontroversial; the part Java leaves as methods — the intermediates — went behind `transform` here anyway, because keeping `take` and `skip` as methods would mean building the namespace objects twice and keeping them in step forever |
| A keyed collection | `Dictionary<K, V>`, beside `Sequence` | Design Philosophy 6 promised that everything handed back to shape is a `Sequence`, and that held right up to the moment you grouped. `Meta` and `Store` were then the same nine members written twice, in two domains, because the library had no name for *a map with typed keys*. One type and one extension replaced two types and twenty-two members, and typed keys started working on every dictionary in the program |
| Writing a collection to disk | `extension Dumpable on Sequence`, declared in `lib/io/` | Rule 1 says anything that writes a file is `io`, and Rule 2's second test forbids `collection` needing `io` back. `io` already depends on `collection` — `io.find` returns a `Sequence` — so the extension adds no edge in the wrong direction, and `collection` still knows nothing about the disk. One export means the caller sees `rows.dump(path)` with no extra import |
| A filesystem watcher | `io.watch` — after 5.0.0 moved the other one | It was `io.observe` through 4.0.0, because `system.watch()` meant *watch for Ctrl-C* and two `watch`es meaning two unrelated things on two accessors is precisely what Rule 5 is for. That entry ended *`observe` is free, honest, and slightly less good than `watch`* — a worse name taken because a better one was occupied by something that had not earned it. Signal watching is `system.on.signals()` now, beside `track`, `adopt` and `exit`, which is the cohesive vocabulary Rule 3 describes; `io` took the name back. A compromise written down is a compromise that can be revisited |
| The interrupt vocabulary | `system.on.*`, not flat on `system` | `watch`, `unwatch`, `track`, `untrack`, `adopt` and `disown` sat directly on `system` through 4.0.0 while `system.on` held exactly one member, `exit`. Rule 3 says a sub-namespace is for a cohesive vocabulary with its own nouns, and *what happens to your resources when the program is interrupted* is that vocabulary — the structure was inverted, with the namespace on the single function and the family flat beside it |
| A rate limiter | `concurrent.rate` → `Limiter` | Pure coordination over time, so Rule 1 would file it under `util` — but `Semaphore` and `Mutex` set the precedent and a limiter has nothing to say to `util`. It bounds *how often* where they bound *how many*, and it composes with `concurrent.run`. `RateLimiter` is camelCase where this library uses domain nouns, and `Rate` alone reads like a number |
| Reading `Retry-After` into a limiter | `Fetcher(limiter:)`, not `Limiter.absorb` | The obvious shape entangles `concurrent` with `net`, which Rule 2's second test dislikes. Pointing the dependency the other way leaves `concurrent` ignorant of responses |
| A server | `net.serve` / `net.once` | Rule 2's second test fails deliberately: a server shares `HttpMethod`, headers, bodies and (via `Served.file`) `io` with the rest of `net`, so it is a member of that domain rather than a peer. `HttpCache` is the precedent and it landed the same way. `Served` and `Asked` rather than `Response` and `Request`, per Rule 6 |
| Terminal IO | `system.console` | The vocabulary is external, but `ConsoleWriter` holds the file descriptor. Owning the handle is a touch, so it sorts as an axis |
| Text helpers | `util.text` | Pure, but `text` is far too common a word to take at top level |
| Locking | `io.lock` | It makes a file, so `io`. One operation with no vocabulary of its own, so a plain member. `lock` is one lowercase word and unclaimed |
| Digests | `util.hash` | Pure; `io.hash` stays separate because it streams a file |
| Randomness | `util.rand` | Pure; `rand` alone is too collision-prone |
| Non-blocking IO | `io.async` | A complete mirror of `io`, so it is a prefix rather than new names |
| `Fs`, `Sys`, `Exit` | Unexported, `lib/src/` | Implementation behind `io` and `system`; never a public name |
| Hash algorithm enum | `Digest` became `Algo` | `Digest` was an `ambiguous_import` error against `package:crypto`, whose `Digest` is a hash *result* where this one selects an *algorithm*. `lib/src/fs.dart` was already writing `crypto.Digest` to name the other one |
| A pipeline's page handler | `Process<T>` became `Handler<T>` | Dart resolves a package import over a `dart:` one silently, so exporting `Process` meant `Process` stopped meaning `dart:io`'s for every user of the library — while `system.on.adopt(Process)` still meant that one. A shadow with no error is worse than a collision with one |
| HTTP caching | `HttpCache` type, `Fetcher(cache:)`, `crawl.cache(dir)` | A whole tool by Rule 2's first test, but entangled with `net.http` by its second: the client is what decides to revalidate. So a type in `net` and an option on the two things that fetch, not a domain and not a namespace |
| A crawl's position | `Snapshot` + `Engine.snapshot`/`restore`, `crawl.resume(path)` | The type is the noun, the engine pair is the operation, and `resume` is the two of them wired to a file. `save` was taken by "write items to", and Rule 5 forbids a second meaning for it |
| A request that failed | `Failure`, passed to `on.error` | A count without the pages is not an answer. Widening the handler's argument list would have fixed one question and left the next one — an attempt number, a response — needing another break, so the argument is a type |
| Streaming CSV out | `io.csv.pipe`, beside `write` | Different behaviour, not an alias: `write` takes a collection, `pipe` takes a `Stream` and holds one row. A `CsvWriter` you open and close would have been a new noun and a lifecycle to get wrong |
| A page's forms | `Form`, reached by `res.form(selector)` | Rule 2's first test passes — filling, addressing and submitting is a vocabulary — but its second fails: a form is read out of a response and submitted through the same client or engine, so it is entangled with `net` and lives there as a type rather than a domain. No accessor, because there is nothing to reach it from but the page it is on |
| Submitting one in a crawl | `res.submit(form)`, beside `res.follow` | `follow` already takes a `method` and a `body`; this is the same operation with the three details read off the form instead of typed out, so it sits next to it rather than inside `Form`, which knows nothing about an engine |
| A cursor's two selector languages | `find` and `xpath`, and no callable | `page(sel)` was a second spelling of `find` — and *which language it spoke depended on hidden state*: XPath on a cursor from `format.html.query`, CSS on one from `format.html.parse`, with nothing at the call site to say which. Rule 5 would have deleted it anyway; the hidden state is why it was not worth arguing about. `find` and `xpath` each name their language |
| The sequence's evaluation | Eager, a snapshot | `Sequence` held an `Iterable` and re-walked the chain on every terminal call, so three reads of a three-element sequence ran the predicate seven times and a `.to(expensiveParse)` over a crawl's results paid once per read. Nothing in the vocabulary was lazy on purpose and every source the library hands one is already a list. The trade — `head(10)` after a `to` shapes the whole source — is stated in the doc rather than discovered |
| Positional arguments | `command` and `args`, no `rest` | `rest` was `args` without its first element, and neither name said which. The deciding fact is that inside a handler `cli.run` dispatched to, the command names are already off, so `args` is the arguments to *that command* and `rest` would drop one more. `rest` existed to serve `subcommand`; both went |
| Terminal geometry | `ConsoleWriter.width` / `.height`, moved off `Terminal` | Geometry belongs to the thing that knows where the output is going — and to the thing a test can size. `Terminal` keeps what it is named for: the control codes |
