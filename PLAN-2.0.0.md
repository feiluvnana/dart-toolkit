# 2.0.0 — the plan

**Part 1, the typed core — shipped.** Stages 1–8. Everything that could be
fixed with Dart's own type system: the renames, typed keys, records, typed CLI
handles and sealed results. Where the built API differs from the plan,
[What actually shipped](#what-actually-shipped) at the end says how and why.

**Part 2, the three things the library cannot do — planned.** Stages 9–11:
[multipart bodies](#stage-9--multipart-bodies),
[session persistence](#stage-10--session-persistence) and
[typed JSON reading](#stage-11--typed-json-reading). Not more typing — the
holes that turn up when you try to use the thing.

Every change is in `CHANGELOG.md` with its before and after.

Three decisions the rest of this document assumes:

- **The rename set is domain nouns.** `Fetcher`, `Reply`, `Page<T>`,
  `Fetch<T>`, `Morsel`.
- **No deprecation shims.** NAMESPACE.md Rule 5 settles it: _a migration is
  one edit; two spellings is forever._ There is no `MIGRATING.md` either —
  this is a personal project, and the changelog is the whole audience.
- **No codegen.** It was the original Part 2, as a companion
  `dart_toolkit_gen` package. Part 1 ate it; see
  [Part 2](#part-2--the-three-things-the-library-cannot-do) for why it is
  cancelled rather than deferred.

---

## Why 2.0.0 exists

Two debts, both written down already.

**The vocabulary debt.** NAMESPACE.md's Known Collisions table lists five
exported type names that fail Rule 6, three of them silently — `dart:io`'s
`HttpClient`, `HttpResponse` and `Cookie` are shadowed with no diagnostic at
all for anyone importing both. It says the fix "is owed at 2.0.0" and pins
`test/regression_test.dart` so the rename has something to break.

**The `Object?` debt.** Rule 6 says no `Object` or `dynamic` in a public
signature _unless the value really is arbitrary JSON_. Seventeen public
signatures claim that exemption; four have earned it. The rest are a `Map`
used as a struct, a `T ==` switch used as a type system, and two methods that
take `Object` and throw `ArgumentError` when you guess wrong.

Both are breaking to fix and neither gets easier by waiting.

---

## Stage 1 — The rename

| Old            | New        | Collided with  | Diagnostic today                    |
| :------------- | :--------- | :------------- | :---------------------------------- |
| `HttpClient`   | `Fetcher`  | `dart:io`      | none — package import wins silently |
| `HttpResponse` | `Reply`    | `dart:io`      | none                                |
| `Cookie`       | `Morsel`   | `dart:io`      | none                                |
| `Request<T>`   | `Fetch<T>` | `package:http` | `ambiguous_import`, on use          |
| `Response<T>`  | `Page<T>`  | `package:http` | `ambiguous_import`, on use          |

`CookieJar` keeps its name — it does not collide, and it says what it holds.
The jar/morsel pairing is Python's `http.cookies`, which is where `Morsel`
comes from.

```dart
final session = Fetcher(session: true);
final Reply res = await session.get('https://example.com'.url);

await net.crawl<String>(seed).tag('song', (Page<String> page) {
  page.follow(page.$('a').href!, tag: 'detail');
});
```

Field renames that follow from the type renames, so nothing reads as the old
vocabulary: `Page.request` → `Page.fetch`, `Failure.request` →
`Failure.fetch`, `Downloader.download(Fetch<T>)` keeps its name (there is no
`fetch` method anywhere, so the type name is free).

**Blast radius.** 370 identifier occurrences: 186 in `lib`, 125 in `test`, 32
in `docs`, 29 in `example` and the two root documents. Word-boundary
find-and-replace handles nearly all of it; `Request`/`Response` need review
because `package:http`'s own types appear in the same files.

**Why this stage is first.** Every later stage rewrites signatures, docs and
tests that mention these five names. Renaming afterwards means editing the
same lines twice.

**Also in this stage:** NAMESPACE.md's Known Collisions table becomes a
"Resolved in 2.0.0" note, `test/regression_test.dart`'s pin is rewritten to
assert the _new_ names do not collide, and the full 102-type sweep is re-run
against the new set.

### One thing the rename fixes on its own

`Response.emit` throws `StateError` when a response has no engine — the
"standalone fetch is not part of a pipeline" case. After the split, a
standalone fetch returns `Reply`, which has no `emit`, `follow` or `stop` at
all. The error becomes a compile error for the case that actually caused it.

---

## Stage 2 — `Slot<T>`: one typed key, two users

`Fetch.meta` and `Store` are the same problem twice: a `Map<String, Object?>`
that has to stay JSON-encodable (meta rides through the resume file, a store
_is_ a JSON file) but is used as a struct.

The fix is a typed key. One type, `Slot<T>`, carrying a name and a
JSON codec — so the map underneath is unchanged and the resume format does not
move, while every read and write is checked.

```dart
const name  = Slot<String>('name');
const track = Slot<int>('track');

page.follow(href, tag: 'song', meta: [name('Hey Jude'), track(4)]);

final String? n = page.meta.get(name);   // no cast, no `as`, no fallback
```

`Slot<T>.call(T value)` returns an entry, so the write site is statically
checked; `Meta.get(Slot<T>)` returns `T?`, so the read site keeps the type.
`Meta.raw` stays available as the `Map<String, Object?>` for JSON round-trips
and for keys another library owns.

`Store` takes the same keys:

```dart
const cursor = Slot<int>('cursor');

final db = io.store.open('cache.json');
db.set(cursor, 120);
final int? at = db.get(cursor);
await db.save();
```

`Store.get<T>` currently returns the fallback when a value is the wrong type,
which quietly turns a schema change into a silent reset. With slots, a decode
failure is the slot's decision and can say so.

**Cost:** an ad-hoc `meta: {'name': 'x'}` needs a one-line `const` first. That
is the point. (Part 2 was going to generate these; one line turned out not to
be worth a build step.)

---

## Stage 3 — Records instead of `Map<String, Object?>`

`res.extract(schema)` is the largest `Object?` surface in the library. It takes
a map of strings and hands back a map of `Object?`; every value is cast at the
call site or not at all.

Dart records close this with no codegen and no ceremony. A `Scope` is a
reader positioned at an element; a builder function returns whatever shape it
likes, and the return type is inferred:

```dart
final product = page.read((p) => (
  title: p.text('h1'),
  price: p.number('.price'),
  tags:  p.texts('.tag'),
  variants: p.every('.variant', (v) => (
    name: v.text('.name'),
    sku:  v.attr('data-sku'),
  )),
));

product.variants.first.sku;   // String?, checked
```

`Scope` carries `text`, `texts`, `attr`, `attrs`, `number`, `has`, `one` and
`every` — the same readers `Field` has today, positioned rather than global.
`every` recurses, so a repeated sub-object is a typed list rather than
`List<Map<String, Object?>>`.

`extract` stays. Rule 6 blesses a shorthand _alongside_ the typed form, and
`extract` is genuinely the fastest way to look at an unfamiliar page. What
changes is that it is no longer the only way to get data out with the type
intact.

`Field<T>` stays too, gaining the combinator it has always been missing:

```dart
final price = Field.text('.price').map(util.text.number);   // Field<double?>
```

That one method deletes most calls to `Field.fn`.

**This is the stage that cancelled Part 2's codegen.** A generated
`Product.read` would be a call to these readers with a builder — the same code
a person writes, and a hand-written `static` composes into `all` and `one` as
a bare tear-off. There was nothing left for a generator to invent.

---

## Stage 4 — `Opt<T>`: the CLI stops guessing

`cli.get<T>(name, fallback)` switches on `T == int`, `T == double` and falls
through to `text as T`, which throws for anything else. The declaration
already knows the type; the read should not have to ask again.

Declarations return a typed handle. Reading is calling it:

```dart
final force = cli.flag('force', alias: 'f');          // Opt<bool>
final size  = cli.number('concurrency', def: 4);      // Opt<int>
final out   = cli.option('out', alias: 'o', def: 'dist');  // Opt<String>
final only  = cli.of('level', LogLevel.values);       // Opt<LogLevel>

cli.parse(args);

if (force()) ...
await concurrent.run(items, work, size: size());
```

The fallback is written once, in the declaration, instead of at every call
site — and `cli.get('concurrency', 4)` returning `4` because someone typed
`--concurrency=fast` becomes a parse error at the boundary, where it belongs.

Cascade style is unaffected: `..` returns the receiver whatever the method
returns, so `cli..flag('a')..option('b')` still reads the same.

Two knock-on decisions in this stage:

- **`cli.list`.** It currently means "the positional arguments". The repeated
  option declaration wants the name. Proposal: positionals become `cli.args`,
  freeing `cli.list(name)` for `Opt<List<String>>`. Flagged rather than
  settled — it is the one name in the stage that is a judgement call.
- **Handler return type.** `FutureOr<Object?> Function(Cli)` with a private
  `_code` that maps `null`/`bool`/`int`/anything to an exit code. It becomes
  `FutureOr<int>`, and `_code` is deleted. `return 0;` is not a burden.

---

## Stage 5 — Sealed results instead of nullable tuples

`Pool.settle` returns
`({R? value, Object? error, StackTrace? stack, bool isSuccess})` — four fields
where two are always null, and a boolean saying which two. That is a sealed
class spelled out longhand.

```dart
sealed class Settled<R> {}
final class Done<R> extends Settled<R> { final R value; }
final class Broke<R> extends Settled<R> { final Object error; final StackTrace stack; }

for (final result in await pool.settle(urls, fetch)) {
  switch (result) {
    case Done(:final value): save(value);
    case Broke(:final error): log.warn('$error');
  }
}
```

Exhaustiveness is checked, and `value` is non-nullable in the branch where it
exists.

`PoolFailure` gains its second type parameter in the same stage:
`PoolFailure<I, R>` with `List<R?> results` instead of `List<dynamic>`.

---

## Stage 6 — Methods that take `Object` and throw

Three signatures accept `Object` and decide at runtime what you meant. Each
splits into methods that say it in the signature.

| Today                                             | 2.0.0                                                                                      |
| :------------------------------------------------ | :----------------------------------------------------------------------------------------- |
| `crawl.save(Object sinkOrPath)` → `ArgumentError` | `crawl.save(String path)` and `crawl.sink(IOSink sink)`                                    |
| `io.csv.write(Iterable<dynamic> rows)`            | `io.csv.write(Iterable<Map<String, Object?>>)` and `io.csv.cells(Iterable<List<Object?>>)` |
| `io.csv.pipe(Stream<dynamic> rows)`               | the same split, over streams                                                               |
| `io.json<T>(path)` — cast, throws on shape        | `io.json<T>(path, [T Function(Object?) parse])`                                            |
| `Selector.select(Object? root, …)`                | private; typed entry points only                                                           |

The CSV split mirrors the reads, which already chose the shape by method name
rather than a type argument: `io.csv.maps` and `io.csv.matrix`.

### The three exemptions that stand

`Body.json(Object? data)`, `Table.add(List<Object?>)` and the logger's
`Map<String, Object?> fields` all really are arbitrary JSON or arbitrary
`toString`. They stay, and NAMESPACE.md Rule 6 gains a line naming them, so
the next sweep does not re-litigate them.

### `Engine<dynamic>`

`Fetch.engine`, `Page.engine` and `Downloader.attach` are all typed
`Engine<dynamic>` while sitting on classes that already know `T`. Thread the
type through where it works, and hide the field where it does not — it is
plumbing, not API.

---

## Stage 7 — Ergonomics

Small things, all of them repeat offenders in the examples.

**A crawl that infers its own item type.** `net.crawl<String>(url)` needs the
type argument because `emit` is the only thing that mentions `T`, and it is
called inside a closure. A mapping terminal has the type in its return:

```dart
final titles = await net.crawl(seed).gather((p) => p.$('.title').texts);
// Future<List<String>> — no type argument, no emit
```

`collect` stays for handlers that follow links and emit as they go; `gather`
covers the single-stage case, which is most of them.

**`Field.map`** — Stage 3.

**`Reply` has no pipeline methods** — Stage 1.

Deliberately _not_ in Part 1: the `io` / `io.async` duplication. Every
blocking name has an async twin, which is Rule 3 working as designed, but it
doubles the surface. Whether 2.0.0 inverts the default is a real question and
a separate one — see [Deliberately not in Part 2](#deliberately-not-in-part-2).

---

## Order and independence

Stage 1 must be first — every other stage edits lines it touches. Stages 2–7
are independent of each other and can land in any order, each with its own
tests green.

1. Rename sweep, regression pin, NAMESPACE.md table
2. `Slot<T>`, `Meta`, `Store`
3. `Scope`, `page.read`, `Field.map`
4. `Opt<T>`, handler returns `int`
5. `Settled<R>`, `PoolFailure<I, R>`
6. Shape splits (`save`/`sink`, `csv`, `io.json`, `select`)
7. `gather`
8. Docs, examples, CHANGELOG

Stage 8 is one pass, not fifteen: all fifteen `docs/*.md` files, four
`example/*.dart` files, README and NAMESPACE are rewritten once, at the end,
against the finished API. `test/doc_samples_test.dart` transcribes samples
from the documentation and asserts what they produce, so it is the place the
rewritten samples get pinned — every sample that changes shape needs its
transcription updated in the same pass.

The changelog carries the before and after for every change, which is the
whole audience this repo has.

---

## Part 2 — the three things the library cannot do

Codegen was the original Part 2. It is cancelled: Part 1 ate it. A page model
is a hand-written `static Model read(QueryResult)` whose body is the record
syntax from Stage 3, and it composes as a bare tear-off because `all`, `one`
and a model's `read` all have the same shape — `R Function(QueryResult)`:

```dart
class Product {
  static Product read(QueryResult page) => Product(
    title: page('h1').text,
    price: page.pick(Field.text('.price').when(util.text.number)),
    variants: page.all('.variant', Variant.read),   // no glue
  );
}
```

A generator would have removed `required this.x` and nothing else. The `Slot`
and `Opt` declarations it was also going to emit are one line each already.
And `toJson`/`==`/`copyWith` — the part codegen genuinely earns — belong to
`json_serializable` or `freezed` on the user's own class, which compose with a
separate `read` static and cost this library nothing.

So Part 2 is not more typing. It is the three things the library cannot do at
all, each found by trying to use it rather than by reading it.

---

### Stage 9 — Multipart bodies

**The hole.** `Body` has four cases — `text`, `bytes`, `form`, `json` — and
none of them is `multipart/form-data`. A file cannot be uploaded. Worse, the
API contradicts itself: `Form.body` throws on a multipart form and says

> This form is multipart/form-data, which Form does not encode. Build the
> request yourself with `net.http.post(url, body: ...)`.

which cannot be done, because no such `Body` exists. That is the strongest
signal in the codebase that something is missing: a message telling the caller
to do something the API does not allow.

**The shape.** A fifth sealed case, and a `Part` for what goes in it:

```dart
await net.http.post(url, body: Body.multipart({
  'title': Part.text('Holiday'),
  'photo': Part.file('out/beach.jpg'),
  'thumb': Part.bytes(png, filename: 'thumb.png', type: 'image/png'),
}));
```

`Part.file` reads its path at send time, so a retry does not hold the file in
memory between attempts, and `type` defaults from the extension.

**And the form on the page just works:**

```dart
final done = await page.form('#upload')!
    .fill({'title': 'Holiday'})
    .attach('photo', 'out/beach.jpg')
    .send(client: session);
```

`Form` grows a `_files` map beside `_fields`, `attach(name, path)` adds to it,
and `Form.body` returns a `MultipartBody` when the form declares the enctype
instead of throwing. `attach` on a form that is *not* multipart throws — a
browser would send only the filename, and silently doing that is worse than
refusing.

**Three details worth deciding up front.**

- *No `http.MultipartRequest`.* `HttpClient.send` builds one `http.Request`
  and calls `body.apply(request)`; a `MultipartRequest` is a different class
  and would fork the redirect, retry and cookie path. Encode the boundary body
  into `request.bodyBytes` and set the `Content-Type` instead. The sealed
  `Body` shape survives untouched.
- *Boundaries come from `util.rand.id()`*, not a second generator — so
  `util.rand.seed` makes an upload as reproducible in a test as a crawl's
  order, which is the promise 1.6.0 made for every other random thing here.
- *De-duplication must not read the file.* `Deduplicator` keys on
  `body?.bytes()`, and for a multipart body that is the whole upload. Switch
  the key to `body?.toJson()`, which is already a compact description of every
  body kind — a file part contributes its path, not its contents. This
  invalidates existing resume files, which a major release may do.

---

### Stage 10 — Session persistence

**The hole.** `crawl.resume(path)` restores the frontier, the visited set and
the counters, so an interrupted crawl carries on where it stopped. It does not
restore the session: `CookieJar` has no `save`, `load` or `toJson`, and
`Morsel` has none either. A resumed crawl comes back as a stranger and gets
the login page.

`Fetcher.jar` is public, so the cookies are *reachable* — but with nothing to
serialise them, the only way to persist a session by hand is to re-render
`Set-Cookie` strings from `Morsel`'s fields. The half of the feature that
exists makes the missing half more obvious, not less.

**The shape.** `Morsel` and `CookieJar` gain the same `toJson`/`fromJson` pair
every other stateful thing here has, and the jar gains a file:

```dart
final session = Fetcher(session: true, jar: CookieJar.open('.cache/session.json'));

await session.post(loginUrl, body: Body.form({'user': u, 'pass': p}));
await session.jar!.save();     // atomic, via .part, like every write here
```

and, because a crawl is where this actually bites, one line beside `resume`:

```dart
await net.crawl<Never>(seed)
    .resume('crawl.state')        // the frontier
    .session('.cache/session.json')   // and who you were
    .gather(handler);
```

`session(path)` mirrors `resume(path)` exactly — restored on the way in,
written on a timer, on a clean stop, and on Ctrl-C through the same `Exit`
hook, so the two are one habit rather than two.

**Two details.**

- *Sweep before writing.* `CookieJar.sweep()` already drops expired cookies;
  `save` calls it, so a stored session does not grow a tail of dead entries.
- *Session cookies are kept.* A browser drops a cookie with no `Expires` when
  it closes. A script resuming an interrupted run wants the opposite, so they
  are written like any other. Worth one line in the docs, because it is the
  one place this deliberately does not do what a browser does.

---

### Stage 11 — Typed JSON reading

**The hole.** Part 1 gave the HTML half three typed readers — `all`, `one`,
`pick` — and left the JSON half exactly where it was. `Reply.json` is
`Object?` and every read is a cast:

```dart
final items = (res.json! as Map<String, Object?>)['data'] as List<Object?>;
for (final row in items.cast<Map<String, Object?>>()) {
  final name = row['name'] as String?;      // cast, cast, cast
}
```

Half of what a scraper points at is a JSON API, so the asymmetry shows on the
second script. `NAMESPACE.md` lists `Reply.json` among the standing `Object?`
exemptions, and that is right for the *raw* accessor — the exemption is for
"the value really is arbitrary". It is not a reason for there to be no typed
way to read it.

**The shape.** A cursor, `Json`, that mirrors `QueryResult` reader for reader:

```dart
final rows = res.at('data.items').all((row) => (
  id: row.number('id'),
  name: row.text('name'),
  tags: row.at('meta.tags').texts(),
));
// List<({num? id, String? name, List<String> tags})>
```

| `QueryResult` (HTML) | `Json` |
| :--- | :--- |
| `q('sel')` | `j.at('a.b')` — dotted path, `[0]` for an index |
| `q.text` / `q.texts` | `j.text(key)` / `j.texts()` |
| — | `j.number(key)`, `j.flag(key)` |
| `q.all(sel, build)` | `j.all(build)` — one per element of an array |
| `q.one(sel, build)` | `j.one(build)` |
| `q.length`, `q.isEmpty` | the same |
| — | `j.raw`, the decoded `Object?` underneath |

`res.at(path)` is the way in, and `res.json` stays as the raw escape hatch.

**Two details.**

- *A missing path is empty, not an exception.* `at('data.items')` on a
  document that has neither reads as an empty cursor, and `text` on it reads
  `null` — the same contract `Slot.read` and `Field.text` already keep, and
  for the same reason: the caller asked for a value and the honest answer is
  that there is not one. Only `raw` shows the difference.
- *No `Slot` here.* A slot exists because a *writer* and a *reader* in
  different places must agree on a key; reading a response is one place, so an
  inline `row.text('name')` is the honest shape and matches how the HTML side
  spells the same idea. Adding `Json.get(Slot)` as well would be two ways to
  do one thing — Rule 5.

---

### Order, and what it costs

| Stage | Touches | Independent? |
| :--- | :--- | :--- |
| 9 — Multipart | `http.dart` (`Body`, `Part`), `form.dart`, `engine.dart` (dedupe key) | yes |
| 10 — Session | `http.dart` (`Morsel`, `CookieJar`), `crawl.dart` (`session`) | yes |
| 11 — Typed JSON | one new file, `http.dart` (`Reply.at`) | yes |

None depends on another, so they can land in any order and each ships green on
its own. Stage 9 is the one to do first: it is the only one where the current
API tells a caller to do something impossible.

Each stage carries its own docs and tests in the same pass, the way Part 1's
stages ended up doing — `test/doc_samples_test.dart` compiles every snippet in
`docs/`, so a stale example fails the suite rather than sitting there.

Three new exported names — `Json`, `Part`, `MultipartBody` — have been through
the Rule 6 sweep against `dart:core`, `dart:io`, `dart:async`, `dart:convert`
and every package in `pubspec.yaml`. All three are clear. (`Node` was the
obvious name for the JSON cursor and is `package:html`'s.)

### Deliberately not in Part 2

- **Codegen.** Cancelled, above.
- **`io` / `io.async`.** Every blocking name has an async twin, which doubles
  the surface. Whether the default should invert is a real question and a
  separate one; nothing in Part 2 depends on the answer.
- **A headless browser.** The one thing that would genuinely extend what this
  can scrape, and the one thing that would stop it being lightweight.
- **`docs/` → `doc/`.** `dart pub publish --dry-run` asks for it and a major
  release is the free moment, but it is a link rewrite, not a feature.

---

## What actually shipped

Seven deltas between the plan above and the code. Each was forced by something
the plan did not know.

**`Scope` was not needed.** The plan invented a reader type for `page.read`.
`QueryResult` already was one — it has `text`, `texts`, `attr`, `attrs` and a
callable `find`. So the stage added three methods to it instead of a type:
`all(selector, build)`, `one(selector, build)` and `pick(field)`. `page.read`
is gone too: a record built straight off `page.$` is shorter than one wrapped
in a builder callback.

**`every` became `all`.** `QueryResult` is iterable, so `every` was already
`Iterable.every`. `all`/`one` pair just as well.

**`Field.when`, unplanned.** `Field.text` is a `Field<String?>`, so `map` hands
its converter a `String?` — and every converter worth using (`int.tryParse`,
`util.text.number`) takes a `String`. `when` applies the converter only when
the field found something; `map` stayed as the unconditional form. Without
`when`, `map` would have been unusable for the case it was added for.

**`Field` moved to the selector library.** `pick` belongs on `QueryResult`, and
`QueryResult` cannot import the HTTP library that defined `Field`. The
hierarchy went the other way instead, which is where it belonged — a `Field`
reads an element, not a response. `Field.map` the static became `Field.nest`,
freeing `map` for the combinator.

**`JQuerySelector` was not already private.** Stage 6 planned to hide the
selector engine, whose `select(Object? root, …)` is the loosest signature in
the library. It looked done — `net.dart` already hid the name from the barrel
export — but anything under `lib/` is importable directly, so
`package:dart_toolkit/net/selector.dart` still handed it over. It is now
`_JQuery`, and the `hide` clause came off.

**`all`, `one` and `pick` were scoped wrong on first writing.** They went
through `find`, which searches strict *descendants*, while `page.$` holds the
body's *children* — so `page.$.all('.variant', …)` found nothing unless the
matches sat inside a wrapper element, and `pick` read the body's first child
rather than the document. The Stage 3 test passed only because its fixture
happened to have a wrapping `<div>`. Caught later, writing the hand-written
model probe that cancelled the codegen. They route through `call` and the
document root now, the way `res.$('...')` and `Reply.pick` always did, and
`test/typed_api_test.dart` pins a flat fixture.

**`cli.switches`, unplanned.** Removing `get`/`has`/`count`/`all` left no way
to observe an argument list nobody declared — which the parser's own tests need
in order to watch clustering. One inspection view replaced four typed-guessing
readers, and it returns exactly what the command line carried.

**`gather` still takes a type argument, and it is `Never`.** The plan claimed
`net.crawl(seed).gather(...)` needs none. It does: `Crawl.call` is generic in
the item type, and this project runs `strict-inference`, so an uninferred `T`
is a warning. `net.crawl<Never>(seed)` is the honest spelling — the crawl emits
nothing — and `gather`'s own result type is still inferred from the mapper,
which was the real win.

**The lazy top-level `final`.** Returning a handle from a side-effecting
declaration collides with a Dart fact the plan missed: a top-level `final` runs
its initialiser on first read, so a declaration hidden in one does not exist
when `run` builds `--help`. The API did not change; `docs/cli.md`,
`example/tool.dart` and the changelog all say to declare inside `main` and
keep the handles in `late final` top-level variables.

One thing the plan under-promised: splitting `_offending` by declared shape
made `--concurrency=fast` a usage error. It used to read back as the default
and run on four workers without a word.
