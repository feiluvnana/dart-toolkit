# Namespaces

How this library decides where something lives and what it is called. Read this
before adding a public name; it is the rule set the current layout follows, and
following it is what keeps the surface small enough to hold in your head.

---

## The map

| Domain | Holds | Sub-namespaces |
| :--- | :--- | :--- |
| `io` | One file: what is at a path, reading it, writing it atomically, moving it — plus watching (`io.watch`), locking (`io.lock`) and the collections on disk (`io.dictionary`, `dump`) | `io.path`, `io.dir`, `io.csv`, `io.async` |
| `net` | The network: requests, downloads, crawling — and, in the other direction, listening. It parses nothing | `net.http`, `net.crawl` |
| `system` | This program and the machine running it, and what happens to its resources when it is interrupted (`system.on`) | `system.env`, `system.console`, `system.on` |
| `concurrent` | Bounded async work on one isolate: how many at once, and how often | — |
| `util` | Pure computation, and nothing else | `util.time`, `util.size`, `util.text`, `util.hash`, `util.rand` |
| `collection` | The three collections this library returns in place of Dart's (`Sequence`, `Dictionary`, `Flow`), the four operation types that shape them (`Transformer`/`Collector` for a sequence, `Pipe`/`Pour` for a flow) and the typed keys (`Slot`). No accessor — a library, not a `collection.something` you call | — |
| `cli` | The command line your script presents to whoever runs it | — |
| `format` | One file format per name — never an executable | `format.html`, `format.json`, `format.yaml`, `format.toml`, `format.csv`, `format.zip` |

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
`util` reaches it; it is a peer.

`Json`, `Markup`, `Csv`, `Codec` and the `.url`/`.ms` extensions stayed behind
in `lib/util/` at the time, and 5.5.0 finished the job by moving them to
`lib/src/`. They are types and extensions several domains return; none of them
was ever reachable as `util.` anything, and a directory named after an
accessor should hold that accessor's members and no strays. They are exported
from the package root exactly as before, so nothing a caller writes changed —
`lib/util/` is now five files and five accessors.

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

A sub-namespace is for a **cohesive vocabulary with its own nouns**: `io.dir`
has entries, depth and links to follow; `system.console` has a writer, a reader
and a cursor. Each would be a domain if Rule 2 let it.

5.2.0 split two out of `io` on exactly this test. Making a directory is not
what `io` is mainly for, and neither is listing one — *entries, depth, links to
follow or not* is a vocabulary, so it is `io.dir`. And `io.path` is the one
corner of the domain where nothing is read, written or created, which is a
cohesion of its own and the reason it needs no `io.async` twin. What is left on
`io` is one file at a time, which is what the domain is actually about.

The same test decides a *type*'s namespace, and 5.1.0 is where that started
mattering. `Transformer.take` and `Collector.count` are namespace objects
holding two members and three — `take.first`, `take.when`, and `count()`,
`count.where`, `count.by` — and they exist for the reason `io.csv` does: the
second word has somewhere to go. See Rule 4's splitting rule. A namespace can
span two types where the operations differ in kind: on a flow `take.first` is
a `Pipe` and `take.last` a `Pour`, because only one of them can emit before
its source ends.

**And the same name can span two *containers*.** There are four operation
types, one pair per collection: `Transformer`/`Collector` shape and end a
`Sequence`, `Pipe`/`Pour` a `Flow`. Every operation keeps one spelling across
all four — `.where(live)` is `.where(live)` wherever it is written, because a
dot shorthand resolves against the context type — so the vocabulary a reader
learns is one vocabulary, declared twice. What differs is the member it is
handed to: `seq.transform`/`seq.collect` against `flow.pipe`/`flow.pour`.

That is Rule 5 read carefully rather than broken. Two *names* for one
operation is what the rule forbids; here there is one name per operation and
one member per container, and the member is what tells you which container
the next call is on. One pair served both through 5.4.0, with the streaming
half of every operation an optional field on the value, and the cost fell on
both sides: an operation whose element step is asynchronous had no `Iterable`
form, so it could not join the vocabulary at all and lived in `concurrent` as
`flow.run`; and an operation a *flow* could not stream was demoted to a
terminal on the *sequence* too, so `sort` changed container for nothing.

Which half an operation lives on is a rule: **a shaping step can emit before
its source ends, a terminal needs the end.** On a flow that is a real
constraint, so `sort`, `flip`, `take.last` and `skip.last` are `Pour`s
returning a `Sequence` — the answer cannot exist until the source ends, and
the type says so. On a sequence the same law is bookkeeping, so they are
`Transformer`s and a chain never changes container.

Everything else is a plain member of the domain. `io.hash(path)` is one
operation about a file, so it sits directly on `io` — it does not need an
`io.hash.*` of its own. `cli.parse`, `cli.flag` and `cli.option` sit directly
on `cli` for the same reason: flags and options are the domain's whole subject,
not a corner of it.

`io.async` is the one structural sub-namespace: it mirrors `io`, one name for
one name, so the blocking and non-blocking forms never differ except in the
prefix. Use that shape only for a complete mirror, never for a partial one.

**What "complete" can mean.** This rule said *exactly* through 5.1.0, and the
mirror did not meet it in either direction — so either the rule was wrong or
the members were, and it was some of each. A complete mirror is now defined as:
**every member that has both forms appears on both sides under one name.** Three
things are outside that, and each is a category rather than an oversight:

- **Members with no blocking form.** `io.lock`, `io.locked` and `io.watch` are
  inherently asynchronous — holding a lock and waiting for a change have no
  blocking twin to write — so they sit on `io` and not on `io.async`. So does
  `io.path`, where there is nothing to wait for.
- **Members with no async form.** There are none, and there is no longer a
  temptation. `io.async.download` was the one, and the blocking twin it wanted
  could not be written at all: Dart has no synchronous HTTP and no way to block
  on a `Future`. It was also a second spelling of `net.http.download`, which
  Rule 5 forbids, so 5.2.0 deleted it rather than inventing a twin. A socket is
  `net`'s.
- **Members whose *shape* differs, under one rule.** Every mirrored member has
  the same name on both accessors; the blocking one returns `T` or a
  `Sequence<T>` and the async one `Future<T>` or a `Flow<T>`. So `io.lines`
  gives a `Sequence<String>` and `io.async.lines` a `Flow<String>` — the same
  four words at a call site, differing only in the `await`. This was a *special
  case* through 5.3.0, because with `Stream` on the async side there was no
  general rule to state: `io.async.lines` left the library's vocabulary and did
  not come back. A rule a reader learns once needed `Flow` to exist.

  There was a fourth entry on this list through 5.4.0, and it was an
  embarrassment rather than a category: **`io.csv`**, every member of which
  was already a `Flow` or a `Future` — reached through `io`, whose doc
  promises that everything there blocks. It was the one corner where the
  prefix did not tell you what you got. 5.5.0 split it: `rows`, `records` and
  `write` sit on both accessors under the same three names, differing exactly
  as the rule above specifies, and `io.csv.pipe` went with it — a second name
  *and* a second implementation of what `write` already was.

  **One property is not parity, and the docs say so.** A `Flow` is consumed
  once where a `Sequence` can be walked again. `Flow.of` is the answer: a
  source that can honestly be re-derived — a directory walk, a file's lines, a
  CSV — rebuilds on each terminal, so `io.async.dir.walk(d)` can now be read
  twice exactly as `io.dir.walk(d)` can. Through 5.4.0 the two sides were
  documented as *the same four words, differing only in the `await`*, which
  was true of one terminal and false of anything that read the listing twice.

`test/regression_test.dart` pins this, the way 4.0.0 pinned *no HTML parser
under `lib/net/`*: it reads both accessors out of the source and asserts the
difference is exactly the set above. A member added to one side and forgotten
on the other fails the build.

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
`Collector` took Dart's `fold`, `cast`, `join`, `zip`, `any`, `all`, `count`
and `sort` unchanged; `Transformer` took `map`, `where`, `take` and `skip`. Where
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
line, where the shorthand is what a script actually writes:
`Collector.count.by(f)` beside `group.into(f, .count())`. One implementation,
two spellings of a *call* — not two implementations.

`io.csv.pipe` sat here as the other example through 5.4.0 and did not
qualify: it was forty lines of its own implementation beside `write`, which
is two implementations of one operation, and `pipe` was the weaker name.
5.5.0 deleted it — the streaming form is `io.async.csv.write`, which is the
mirror rule doing the work instead.

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
7. Document it **in the `///` comment above it**, with a `dart` sample.
   `test/docs_test.dart` compiles **every** `dart` block in every `///`
   comment under `lib/`, plus the ones in `README.md`, this file and
   `example/README.md`, against a set of shared fixtures — so a stale example
   fails the build.

   There was a `docs/` folder of seventeen prose files through 5.4.0, and
   5.5.0 retired it. Every sentence in it had a twin in a doc comment, which
   is Rule 5 applied to prose: two places saying one thing, and the one
   further from the code is the one that goes stale. The comments are also
   the copy the reader actually meets — in dartdoc, and on hover in an
   editor — and they cannot drift from the signature they sit above. What
   the folder carried that a comment cannot is a *narrative* across members;
   that lives in the library-level `///` doc at the top of each file, which
   is where `# IO Domain (io.*)` and `# Pipes and Pours` already were.

   The compile claim used to be here and used to be false: the old harness
   filtered to whole programs (`if (!snippet.contains('void main(')) continue;`),
   which was 27 of 244 markdown blocks and none of the 152 in doc comments.
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
| The `Markup` cursor type | `util`, beside `Json` | The same split, one release later, and named the same way: for what it is over rather than for the operation that produced it. `QueryResult` was a result type named after a query. The 800-line jQuery evaluator behind it went to `lib/src/jquery.dart`, so `src/markup.dart` reads as the vocabulary rather than the machinery |
| The domain's own name | `format`, not `tool` | `tool` was chosen when the domain held one archiver, and it invited precisely the thing its own doc comment spent a paragraph forbidding — three executable wrappers were added under it in 3.1.0 and removed in 3.2.0. `format.zip` cannot be misread as a wrapper around the `zip` binary. Rule 4 says say the call site out loud: `format.yaml.read('config.yaml')` says what it does and `tool.yaml.read(...)` says where it happens to live |
| The sequence API | `Sequence<T>`, a type in `collection` | Rule 2 spends no top-level name: you reach it from the data you already hold, the same argument that put `Form` in `net` with no `net.form`. Not a sub-namespace either — `util.list.group(...)` would be a namespace standing where a receiver belongs. It sat in `util` through 5.0.0; 5.1.0 moved it out, because `util` was holding both functions you call and types you receive, and the collections are the largest of the second kind |
| The sequence *vocabulary* | `Transformer` and `Collector`, not methods on `Sequence` | Fifty-eight members, a third of them words invented for an operation everybody already knew, and eight of those forced by nothing but the camelCase ban. A namespace has no `Map` to collide with and no compound to forbid, so `map`, `where`, `take.first` and `count.by` all became sayable. Java's `Collectors` is the same design, twenty years old and uncontroversial; the part Java leaves as methods — the intermediates — went behind `transform` here anyway, because keeping `take` and `skip` as methods would mean building the namespace objects twice and keeping them in step forever |
| A keyed collection | `Dictionary<K, V>`, beside `Sequence` | Design Philosophy 6 promised that everything handed back to shape is a `Sequence`, and that held right up to the moment you grouped. `Meta` and `Store` were then the same nine members written twice, in two domains, because the library had no name for *a map with typed keys*. One type and one extension replaced two types and twenty-two members, and typed keys started working on every dictionary in the program |
| A collection over time | `Flow<T>`, beside `Sequence` and `Dictionary` | `Stream` is Dart's third collection, and nine public signatures handed one back — the *large-data* members of four domains, the ones a script reaches for precisely when a good vocabulary matters most. Twenty-six of `Stream`'s thirty-seven members already had a name here, twelve of them camelCase compounds Rule 4 forbids in this library's own code, so a script that switched from `crawl.collect` to `crawl.stream` rewrote its whole pipeline for no reason but which container arrived. One type, the same two doors, and no new factory anywhere: `Transformer` and `Collector` grew a second function each rather than a second vocabulary |
| Bounded work over a flow | `Pipe.map.async(worker, size: n)` | It was `extension Bounded on Flow`, declared in `lib/concurrent/`, through 5.4.0 — placed there because `collection` may not depend on `concurrent` and a member on `Flow` would have made a cycle. That was the right answer to the wrong question: the reason it could not be a member of the vocabulary is that one operation type had a required `Iterable` half, and an asynchronous element step has none. Separating the vocabularies removed the constraint, so it is an ordinary factory now, and the machinery moved to `lib/src/bounded.dart` where both callers can reach it without either domain depending on the other |
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
| Non-blocking IO | `io.async` | A complete mirror of `io`, so it is a prefix rather than new names. "Complete" is defined in Rule 3 and pinned by a test, because it was asserted and untrue for four releases |
| Directories | `io.dir.*` | *Entries, depth, links to follow or not* is a vocabulary with its own nouns, which is Rule 3's test — and creating a directory is not what `io` is mainly for. It also freed the name: `io.dir(path)` was a **path reader** that returned the parent and created nothing, which is precisely backwards |
| Path arithmetic | `io.path.*` | The one corner of `io` where nothing is read, written or created. That is a cohesion, and it is also why it is the one sub-namespace with no `io.async` twin. The cost is `io.path.join`, which is the library's most-used member; taken deliberately, because an exception to the rule is worse than three extra characters |
| Creating the parent of a path | `io.dir.makeparent`, not `io.parent` | `parent` reads like it *returns* the parent and instead creates it, and `dir` read like it *made* a directory and instead returned a string. Renaming them in place was checked and rejected: a call in statement position discards its result, so every `io.parent(...)` would have kept compiling and quietly stopped creating the directory it was there to create. Moving both to different namespaces makes every old call site fail to compile, which is the only acceptable shape for a rename that changes what a name means |
| `base` and `name` | `io.path.filename` and `io.path.stem` | They differed only in whether the extension survived, and neither word said which. `stem` is Python's word and one lowercase syllable |
| One thing on the filesystem | `FileSystemEntry`, returned everywhere | Seventeen `io` signatures named `File`, `Directory`, `FileSystemEntity` or `FileStat` — four types this library does not control, does not document and cannot change — and across the whole repository **one** call chained off a returned handle and **zero** assigned one to a typed variable. Rule 6 asks for real types at the boundary; it had only ever been applied to parameters. It sits one letter from `dart:io`'s `FileSystemEntity`, which was close enough to run the Rule 6 collision check rather than assume: a file declaring both, beside imports of `dart:io`, `dart:async`, `dart:convert`, `package:archive`, `package:http` and `package:path`, analyzes clean |
| The door out of it | `FileSystemEntry.entity`, exactly one | `Json.raw`, `Markup.document` and `Meta.raw` are the precedent: a typed surface with a single documented way to the thing underneath, so that needing it is a visible choice rather than the default |
| An open file handle | Deliberately absent | Every other standard library has one and it is the obvious next thought after `FileSystemEntry`. It is also a lifecycle to get wrong, and `io`'s whole shape is that a path is a `String` and every call is complete in itself. The line: **if a member would need a matching `close`, it does not belong here.** `io.lock` proves the alternative — it takes the action as a callback rather than handing out something to release |
| Listing versus walking | `io.dir.list` and `io.dir.walk` | The split Python (`iterdir`/`walk`), Node and Go all make. This library made neither: `io.find` carried both on one member with a `recursive:` flag *and* dropped every directory it walked past, so listing a folder was impossible, and so was knowing whether an entry was a link before following it |
| `io.dir.find` | Deleted in 5.5.0 | *Give me the mp3s* is a real question, and 5.2.0 kept a member for it — `walk` filtered to files, with its old `Pattern` signature intact. Keeping the signature is what made it a mistake: `walk` matched a **glob** and `find` a `Pattern`, `walk` took `depth: int?` and `find` a `recursive: bool`, so `io.dir` spoke two matcher languages and two depth axes on sibling members, and `find`'s own doc said it gave *the same set* as `walk(only: .file, match: …)`. That is Rule 5 exactly. One matcher, one depth axis, one member per question; a `RegExp` filter is the collection vocabulary's job, one `transform` further on |
| CSV | `format.csv` for the codec, `io.csv` for the streams | Rule 1 says a file format is a subject — the sentence that admitted `format.zip`, then the other four. CSV was the last one filed under the axis that happened to read the bytes. 4.0.0 and 5.0.0 both deferred the move fearing two spellings for *read a CSV file*; the `Codec` seam 4.0.0 built is what answers it, since `read` comes from `FileCodec` exactly as it does for the other five. What stayed in `io` is `rows`, `records` and `write` — about a file larger than memory rather than about CSV — and 5.5.0 made them a real mirror across `io` and `io.async` instead of three futures hanging off the blocking accessor |
| The CSV cursor | `Csv`, in `lib/src/` | `Table` is taken by `system.console`, so it is named for what it is over, the way `Json` and `Markup` are — and it sits beside them for their reason too: `net` hands it back through `Codec`, and a type `net` needs cannot live under `format`. It was under `lib/util/` through 5.4.0, which was never right: nothing reached it as `util.` anything, and a directory named after an accessor should hold that accessor's members |
| `Fs`, `Sys`, `Exit` | Unexported, `lib/src/` | Implementation behind `io` and `system`; never a public name |
| Hash algorithm enum | `Digest` became `Algo` | `Digest` was an `ambiguous_import` error against `package:crypto`, whose `Digest` is a hash *result* where this one selects an *algorithm*. `lib/src/fs.dart` was already writing `crypto.Digest` to name the other one |
| A pipeline's page handler | `Process<T>` became `Handler<T>` | Dart resolves a package import over a `dart:` one silently, so exporting `Process` meant `Process` stopped meaning `dart:io`'s for every user of the library — while `system.on.adopt(Process)` still meant that one. A shadow with no error is worse than a collision with one |
| HTTP caching | `HttpCache` type, `Fetcher(cache:)`, `crawl.cache(dir)` | A whole tool by Rule 2's first test, but entangled with `net.http` by its second: the client is what decides to revalidate. So a type in `net` and an option on the two things that fetch, not a domain and not a namespace |
| A crawl's position | `Snapshot` + `Engine.snapshot`/`restore`, `crawl.resume(path)` | The type is the noun, the engine pair is the operation, and `resume` is the two of them wired to a file. `save` was taken by "write items to", and Rule 5 forbids a second meaning for it |
| A request that failed | `Failure`, passed to `on.error` | A count without the pages is not an answer. Widening the handler's argument list would have fixed one question and left the next one — an attempt number, a response — needing another break, so the argument is a type |
| Streaming CSV out | `io.async.csv.write`, the mirror of `io.csv.write` | It was `io.csv.pipe` beside `write` through 5.4.0, defended as *different behaviour, not an alias*. That was true and beside the point: the difference is exactly the one the `io` mirror already encodes — a `Sequence` on the blocking accessor and a `Flow` on the async one — so the two need one name, not two. A `CsvWriter` you open and close would still have been a new noun and a lifecycle to get wrong |
| A page's forms | `Form`, reached by `res.form(selector)` | Rule 2's first test passes — filling, addressing and submitting is a vocabulary — but its second fails: a form is read out of a response and submitted through the same client or engine, so it is entangled with `net` and lives there as a type rather than a domain. No accessor, because there is nothing to reach it from but the page it is on |
| Submitting one in a crawl | `res.submit(form)`, beside `res.follow` | `follow` already takes a `method` and a `body`; this is the same operation with the three details read off the form instead of typed out, so it sits next to it rather than inside `Form`, which knows nothing about an engine |
| A cursor's two selector languages | `find` and `xpath`, and no callable | `page(sel)` was a second spelling of `find` — and *which language it spoke depended on hidden state*: XPath on a cursor from `format.html.query`, CSS on one from `format.html.parse`, with nothing at the call site to say which. Rule 5 would have deleted it anyway; the hidden state is why it was not worth arguing about. `find` and `xpath` each name their language |
| The sequence's evaluation | Eager, a snapshot | `Sequence` held an `Iterable` and re-walked the chain on every terminal call, so three reads of a three-element sequence ran the predicate seven times and a `.to(expensiveParse)` over a crawl's results paid once per read. Nothing in the vocabulary was lazy on purpose and every source the library hands one is already a list. The trade — `head(10)` after a `to` shapes the whole source — is stated in the doc rather than discovered |
| Positional arguments | `command` and `args`, no `rest` | `rest` was `args` without its first element, and neither name said which. The deciding fact is that inside a handler `cli.run` dispatched to, the command names are already off, so `args` is the arguments to *that command* and `rest` would drop one more. `rest` existed to serve `subcommand`; both went |
| Terminal geometry | `ConsoleWriter.width` / `.height`, moved off `Terminal` | Geometry belongs to the thing that knows where the output is going — and to the thing a test can size. `Terminal` keeps what it is named for: the control codes |
| One vocabulary or two | Two: `Transformer`/`Collector` and `Pipe`/`Pour` | One pair served both containers through 5.4.0, with the streaming half an optional field. It cost both sides. A flow-native operation has no `Iterable` form, so it could not join at all — `asyncMap` was `flow.run`, an extension in `concurrent`, and `debounce`, `throttle`, `merge`, `asyncExpand` and an async predicate had no spelling anywhere. And an operation a *flow* could not stream was billed to the *sequence* too, so `sort` was a `Collector` on both and the commonest chain in the library's own examples changed container twice for nothing. The price is that the vocabulary is declared twice and a named pipeline is no longer portable; `Pipe.of` is the one-way adapter, kept as a conversion rather than a second spelling, and it says out loud that it buffers where the old design did that silently |
| The two names for the flow's doors | `flow.pipe` and `flow.pour` | They were `transform` and `collect`, the same two words a `Sequence` uses. With one pair of operation types that was honest; with two it is not — a member named the same on both containers reads as though one pipeline value fits either, which is exactly what the library claimed and could not deliver. The operations keep their spelling, because a dot shorthand resolves against the context type; the *member* is what now says which container you are on. `pour` is this library's own word for *the same operation over a stream*, which is what it meant as a field before it was a type |
| Where the bounded-work machinery lives | `lib/src/bounded.dart` | `Pipe.map.async` needs it and so does `concurrent`, and neither domain may depend on the other — `collection` is the bottom of the stack by Rule 2. `src` is for exactly this: implementation more than one domain reaches |
| A crawl's collected items | `crawl.items()` | It was `crawl.collect()`, which is the collection vocabulary's own word in the collection vocabulary's own receiver position meaning something else: `rows.collect(.count())` takes a `Collector` and reduces, `crawl.collect(handler)` took a page handler and ran a crawl. Rule 5 forbids that outright, and the engine already called them items |
| Writing a crawl to a file | `io.async.lines.write(path, crawl.flow())` | `crawl.save(path)` and `crawl.sink(out)` were private versions of a member the library did not have: *write this collection to a file, one element per line, atomically*. Rule 1 says anything that writes a file is `io`, and a crawl is not a special case of it. The general form covers a crawl, a log, a piped stdin and a directory walk with one name, and `Flow.dump` is its JSON twin |
| An open file handle, reconsidered | `io.append.open` → `Appender` | The row above says **if a member would need a matching `close`, it does not belong here** — and this one does. It is the deliberate exception, and the reason is that `io.append` reopens, writes and closes on *every call*, which is right for the log line a script writes twice and wrong for the loop that writes ten thousand. The exception is narrow on purpose: one member, one namespace, `open` in its name so the lifecycle is visible at the call site, and `close` idempotent so a `finally` after an early close is not an error |
