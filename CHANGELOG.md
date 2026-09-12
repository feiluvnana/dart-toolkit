# Changelog

All notable changes to this project will be documented in this file.

## 7.1.0

**Modernization & Ergonomics: Strict typing, dot shorthands, unified progress, and legacy sequence retirement.**
v7.1.0 completes the transition started in 7.0.0, retiring legacy sequence transformations (`.transform(...)`), introducing strict typing discipline across JSON/HTTP/Process boundaries, adding concise static dot-shorthands, providing cross-platform shell execution, and offering seamless automated progress tracking.

### 1. Legacy Sequence API Retirement & Native Modernization
- Retired `.transform(...)` and `Transform` sequences across all examples and `bin/` tooling in favor of native Dart 3 features (`.indexed`, record pattern matching, `whereType<T>()`, `mapNotNull()`, and native fluent methods like `sortedByDescending`, `groupBy`, `split`, `countBy`, `avg`, `unique`).
- Refactored `bin/clean.dart` to leverage `io.dir.sweep` and modern CLI specifications (`--target`, `--format`, `--dry-run`, `--yes`).
- Modernized `bin/keybox.dart` with modern CLI flags, declarative asset mappings, format parameterization, and graceful `system.shutdown()`.

### 2. Strict Type Discipline
- **Typed JSON Wrappers**: Eliminated `dynamic` return types from `Reply.json`, `SysResult.json`, `File.readJson()`, and `File.readJsonSync()`, standardizing on the strongly typed `Json` wrapper.
- **Generic Decoders**: Added `Reply.jsonDecoded<T>()`, `SysResult.decodeJson<T>()`, `File.readDecoded<T>()`, and `File.readDecodedSync<T>()` for zero-boilerplate decoding directly into typed domain models or collections.
- **Generic Json Collections**: Parameterized `Json.toMap<T>()` and `Json.toList<T>()` with explicit typing.

### 3. Dot Shorthands
- **Codecs**: Added static getters `Codec.html`, `Codec.json`, `Codec.yaml`, `Codec.toml`, `Codec.csv` allowing `.html`, `.json`, `.yaml`, `.toml`, `.csv` dot shorthand in any `Codec` context.
- **File System**: Added `FileSystemEntryKind.dir` enabling `.dir` dot shorthand alongside `.directory`.

### 4. Developer Experience & Ergonomics
- **Reply Document Helpers**: Added `ReplyDocumentExtensions` exposing `.html`, `.$()`, and `.$xpath()` directly on `Reply` without intermediate markup conversions.
- **String HTTP Extensions**: Added `StringHttpExtensions` (`'url'.get()`, `'url'.post()`, etc.) matching `Uri` extensions.
- **Subprocess Shell Support**: Added `shell: bool` flag to `system.run` and `system.stream` (and `Sys.run` / `Sys.stream`) for executing shell built-ins and platform-specific commands.
- **Interactive CLI & Auto-Help**: Added `cli.choose` interactive prompt helper and `autoHelp: bool` in `cli.parse` for automatic `--help` generation and exit handling.
- **Automated Progress Bars**: Added automated `progress` parameter to `concurrent.run`, `concurrent.settle`, and `Fetcher.sync`.
- **Persistent State Management**: Introduced `io.state(path)` and `io.async.state(path)` returning a lightweight `DiskState` container with typed slot reading/writing and atomic flush via `save()` and `saveAsync()`.
- **Iterable Terminals**: Added `split`, `countBy`, and `avg` terminals to `IterableTerminals`.

## 7.0.0

**The developer experience overhaul: supercharge Dart, don't replace it.**
The earlier v6.x architecture enforced an isolated "walled garden" that separated developers from Dart idioms, standard types (`Iterable`, `Map`, `Stream`), standard HTTP convenience verbs, and standard `dart:io` abstractions. v7.0.0 transforms `dart_toolkit` into a high-productivity DX companion for Dart developers by embracing Dart's native types, bridging seamlessly with `dart:core`, `dart:io`, and `package:http`, delivering fluent extensions, restoring intuitive convenience helpers, and providing robust concurrency, atomic file operations, and CLI ergonomics.

### 1. Native Collections & Universal Interoperability
- **`Sequence<T>` implements `Iterable<T>`**: `Sequence` can now be used directly in `for-in` loops, passed to any Dart standard library function, and converted with `.toList()`.
- **Universal Parameter Acceptance**: All collection-accepting APIs across the library (`concurrent.run`, `concurrent.settle`, `io.lines.write`, `io.chunks.write`, `io.csv.write`, `format.csv.format`, `format.csv.cells`, `net.crawl`, `Crawl`, `Pipe.flatMap`) now accept standard Dart `Iterable<T>` and `Map<K, V>` directly.
- **Fluent Core Extensions**: Added `IterableExtensions` (`.filter()`, `.mapNotNull()`, `.flatMap()`, `.chunk(n)`, `.window()`, `.sorted()`, `.sortedBy()`, `.groupBy()`, `.distinctBy()`, `.zip()`, `.tap()`, `.sum`, `.average`), `MapExtensions` (`.filterKeys()`, `.filterValues()`, `.mapValues()`, `.pick()`, `.omit()`, `.merge()`, `.sortedByKey()`, `.invert()`), and `StreamExtensions` (`.filter()`, `.debounce()`, `.throttle()`, `.chunk()`, `.mergeWith()`, `.concatWith()`, `.recover()`, `.tap()`).
- **Static Helper Trilogy**: Introduced `Iterables`, `Maps`, and `Streams` helpers for functional generation, zip, partition, combination, and transformations.

### 2. HTTP Ergonomics & Ecosystem Coexistence
- **Restored HTTP Convenience Verbs**: Added `.get()`, `.post()`, `.put()`, `.delete()`, `.patch()`, and `.head()` to `Fetcher` and `NetAccessor` (`net.http` and `net`).
- **Method Tear-Off Support**: Convenience verbs work directly as method tear-offs (e.g. `concurrent.run(urls, net.http.get)`).
- **Sane Real-World Redirect Defaults**: `Fetcher` and `Fetcher.browser` now default to `redirects: 5` (with explicit opt-out via `redirects: 0`).
- **Streaming Response Bodies**: Added `Reply.stream` and `Fetcher.stream` yielding native `Stream<List<int>>` for downloading large payloads without memory buffering. Added `Reply.text`, `Reply.json`, `Reply.fromHttpResponse`, and `reply.toHttpResponse()`.
- **Zone-Scoped Client Isolation**: Added `net.withClient(client, () => ...)` for isolated testing and mock injection without global state hazards.
- **Fluent URI Extensions**: Quick HTTP requests on `Uri` and `String` (`uri.get()`, `post()`, `put()`, `delete()`, `patch()`, `head()`).

### 3. Native `dart:io` DX Supercharging & Process Improvements
- **Fluent `dart:io` Extensions**: Added extensions on `File` (`readLines`, `readJson`, `writeAtomic`, `writeBytesAtomic`, `appendLine`, `writeJson`), `Directory` (`walk`, `listEntries`, `ensure`), and `FileSystemEntity` (`entry`, `isFile`, `isDir`, `isLink`).
- **Restored File System Predicates**: Restored non-throwing `io.isFile`, `io.isDir`, `io.isLink`, `io.exists`, `io.size` (and `io.async.*` equivalents).
- **Process DX & `SysResult`**: Enhanced subprocess execution with `SysResult` properties (`exitCode`, `isSuccess`, `stdout`, `stderr`, `lines`, `json`) and real-time streaming execution via `system.stream(cmd, args)`.
- **Typed Environment Accessors**: Added `system.env.int(key, {defaultValue})`, `system.env.bool(key, {defaultValue})`, and `system.env.require(key)`.
- **Cross-Platform Hardening**: Windows-safe guarded signal handlers preventing `SIGTERM` crashes (`errno 50`), plus retry backoff for Windows atomic file swap operations.

### 4. Document Cursors & CLI Isolation
- **Scoped XPath Evaluation**: Fixed `Markup.$xpath` so queries on child element cursors isolate strictly to the element's subtree rather than the document root. Added `Markup.element` and `Markup.elementList`.
- **Quick Parsing Extensions**: Added `String.parseJson()` and `String.parseHtml()`.
- **JSON Direct Conversions**: Added `Json.toMap()` and `Json.toList()`.
- **CLI Re-entrancy & Isolation**: Added `cli.reset()`, `CliAccessor.isolated()`, and `Cli.isolated()` for isolated testing.

### 5. Effective Dart Naming Alignment & Deprecation Removal
- Aligned naming with Effective Dart `lowerCamelCase` (`table.addAll`, `makeParent`, `httpOnly`, `perHost`, `sameHost`, `firstWhere`, `groupBy`, `brightRed`, etc.).
- Completely removed all deprecated legacy APIs, squished names, and backward-compatible forwarders.

## 6.3.0

**The seam.** `Sequence` is deliberately not an `Iterable` — that is what
keeps one collection vocabulary in scope at a call site, and it has been the
design since 5.0.0. What was never checked is the consequence: if the library
*returns* a `Sequence` and *takes* an `Iterable`, the two halves do not meet.

They did not. Eleven crossings in the library's own surface could not be
written without `collect(.list())` — leaving the vocabulary in order to
re-enter it one call later — and three of them were codecs that could not
round-trip their own output:

```dart
format.csv.format(sheet.maps)               // Sequence in, Iterable wanted
format.csv.cells(sheet.rows)                // and again
format.sitemap.format(format.sitemap.parse(xml))
concurrent.run(rows, work)                  // fed from any read in the library
net.crawl(seeds)                            // seeded from what `next` returns
table.add.all(sheet.rows)
reader.pick('which', options: found)        // `picks` returned what it could not take
```

Every one of those is now a compile. **Rule 7** is the rule they were failing
and NAMESPACE.md carries it: *a collection this library hands back fits every
collection parameter it declares.* `Sequence` is the side that wins, because
the bridge is asymmetric — a literal joins with `.seq`, four characters, where
a `Sequence` leaves through `collect(.list())`, seventeen and a documented
exit from the type system the library exists to provide.

### What changed at a call site

| Was | Is |
| :--- | :--- |
| `format.csv.format(rows.collect(.list()))` | `format.csv.format(rows)` |
| `concurrent.run(items.collect(.list()), work)` | `concurrent.run(items, work)` |
| `net.crawl([Fetch(seed)], next)` | `net.crawl([Fetch(seed)].seq, next)` |
| `table..add.all([[1, 2]])` | `table..add.all([[1, 2]].seq)` |
| `reader.pick('x', options: ['a', 'b'])` | `reader.pick('x', options: ['a', 'b'].seq)` |
| `crawl.accept(const ['text/html'])` | `crawl.accept(const Sequence(['text/html']))` |

Nothing was renamed and nothing was deleted. A list literal in a call that
takes a collection adds `.seq`; everything the library reads now goes in
untouched.

### A row is a `List`, not a nested sequence

`format.csv.parse(text).rows` was a `Sequence<Sequence<String>>` and is a
`Sequence<List<String>>` — which is what `io.csv.rows` returned all along, so
the two CSV doors now spell the same grid the same way. The cells of one
record are a fixed tuple read by position, so the question asked of them is
`row[2]`, and `row.collect(.at(2))` was that question wearing the
vocabulary's clothes. This is Rule 7's first test: *is it a fixed record read
by position?*

```dart
sheet.rows.collect(.at(0))!.collect(.at(1))    →    sheet.rows.collect(.at(0))![1]
```

### Two halves of a pair that only had one half

- **`Transformer.tap`.** `Pipe.tap` has existed since flows split from
  sequences in 5.5.0, filed under *what only makes sense over time*. Watching
  an element go past is not particular to time; it was the half that got
  written. A counter or a progress tick now sits mid-chain on a sequence,
  lazily like every other step.
- **`concurrent.settle`.** `concurrent.run` — the half that throws on the
  first failure — was reachable without naming a type, and `settle` — the
  half that hands back a sealed `Done`/`Broke` per item and never throws —
  cost a `Pool`. The failure-tolerant form was the more expensive one to
  write.

### `util.size.format` takes a `num`

`collect(.sum(...))` returns a `num`, so totalling the sizes in a directory
and printing the total was `util.size.format(total.toInt())` — a cast written
only to satisfy a signature. A fractional count floors to the byte it names.

### The trap under a widened `Sequence` parameter

Found while closing the seam, and older than it: a `Sequence<T>` parameter
declared as a **supertype** compiled and then threw.

```dart
int howMany(Sequence<Object?> items) => items.collect(.count());
howMany(['a', 'b'].seq);   // throws: Collector<Object?, int> is not Collector<String, int>
```

`collect` takes a `Collector<T, R>`, and Dart checks that argument against the
receiver's *reified* `T`. The rule is therefore to name the element type
exactly or be generic in it, and where the wider type is the right signature
anyway — `format.csv.format` takes `Sequence<Map<String, Object?>>` so a
parsed sheet and a literal both fit — to widen the receiver first with
`transform(.cast<...>())`, the one step that survives the crossing because it
is a `Transformer<Never, R>`. Every widening site in the library does this,
and `Sequence`'s class doc and Rule 7 both say so.

## 6.2.0

**The helper sweep.** Rule 5 has been run against members, against a
vocabulary, against parameters and across all eight domains. It had never
been run against *helpers* — the member that is one call plus a literal, or a
first element, or a `map` over something the cursor already hands back. Read
that way, `Markup` alone had eleven, and the library had forty-four.

All forty-four are **deleted**. Each row below is the survivor, and every one
of them already existed:

```dart
net.http.get(url)              →  net.http.send(.get, url)
page.$('a').htmls              →  page.$('a').elements.transform(.map((e) => e.innerHtml))
page.$('.row').one(f)          →  page.$('.row').all(f).collect(.first())
page.$('li').data('id')        →  page.$('li').attr('data-id')
page.$('li').has('live')       →  !page.$('li').matching('.live').empty
page.$('li').not('.live')      →  page.$('li').matching(':not(.live)')
io.isfile(path)                →  io.stat(path)?.isfile
io.size(path)                  →  io.stat(path)?.size
io.empty(path)                 →  io.stat(path)!.empty  /  io.dir.empty(path)
cli.help()                     →  print(cli.usage())
util.time.iso()                →  DateTime.now().toUtc().toIso8601String()
util.hash.short(url)           →  util.hash.sha(url).substring(0, 8)
util.text.between(t, a, b)     →  util.text.betweens(t, a, b).collect(.first())
```

### One verb, and the method is an argument

`get`, `post`, `put`, `delete`, `patch` and `head` were six forwarders onto
`send`, each restating eight parameters to fill in one enum. Dart's dot
shorthand fills it in at the call site:

```dart
await net.http.send(.get, url);
await net.http.send(.post, url, body: const Body.json({'id': 1}));
await api.send(.delete, url, retries: 2);
```

The tear-off goes with them, and it is the one call site that gets longer:
`concurrent.run(urls, net.http.get)` is
`concurrent.run(urls, (u) => net.http.send(.get, u))`.

### The cursor reads the first match; `elements` reads the rest

A `Markup` has *held* a `Sequence<Element>` since 5.0.0, so that the
element-level work has one spelling. The plurals that were not that spelling
are gone — `htmls`, `outers`, `values` — and `texts` and `attrs` stay,
because those two are what a scraper writes. So do `at`, `filter`,
`matching`, `children`, `parent`, `closest`, `siblings`, `prev`, `next`,
`text`, `html`, `outer`, `attr`, `value`, `lines`, `all`, `pick` and
`extract`.

`Markup.value` is now defined as `Element.value`, rather than the other way
round: the rules a control follows — a `<select>`'s chosen option, an
unticked box reading as absent — live on the element, and the cursor reads
them off its first match.

### Three names with a capital in the middle

Rule 4 bans camelCase and three public members still had it.

| Was | Is | Why that one |
| :--- | :--- | :--- |
| `Table.addAll(rows)` | `Table.add.all(rows)` | Dart spells it `addAll`, so the splitting rule applies: split at the capital. `add` is a callable namespace, the shape `count()` / `count.by` has had since 5.1.0 |
| `Cli.usageExit` | `Cli.misuse` | Nothing to split — the compound is ours, not Dart's — so one word does it, and it says what happened rather than what the number is for |
| `Field.readAll` | private | No caller outside its own file. A name not worth spelling well is not worth exporting |

### What survived the sweep, and why

Four candidates were read and kept, because each is a *different
implementation* rather than a second spelling — which is the line Rule 5's
carve-out actually draws:

- **`Collector.has`** is `Iterable.contains`: a `Set` answers it in constant
  time where `any` cannot.
- **`logger.step`** carries its own badge and its own `step`/`total` fields
  into the JSON line, so `info('[2/5] …')` is a different record.
- **`Markup.extract`** is the loose-spec door Rule 6 blesses beside `pick`.
- **`Table.add.all`** is one line over `add`, and a script with its rows
  already in hand writes it constantly.

### Migrating

The analyzer names every call site; there are no silent behaviour changes and
nothing was renamed except the three above. Two rewrites are worth doing by
hand rather than mechanically:

- `io.empty(path)` fused two questions with two costs. A file answers from
  the stat you already paid for (`io.stat(p)!.empty`); a directory needs a
  listing (`io.dir.empty(p)`). Pick the one you mean.
- `net.http.get` as a *value* — passed to `concurrent.run` or `.map.async` —
  becomes a lambda.

`test/regression_test.dart` pins the release: one sweep asserts no exported
member is camelCase, another that no doc comment still names a deleted one.

## 6.1.0

**Nothing unasked.** A two-line script compared `package:http`'s `get` with
`net.http.get` against a host that was dropping ~40% of its TLS handshakes.
The bare call returned the `HandshakeException` in 300ms. `net.http` took
eleven seconds and usually succeeded — because it retried twice, unasked,
and each failed handshake costs five seconds to surface. The toolkit looked
slower than the package it wraps while doing strictly more work to hide the
one fact the caller needed.

So the rule, applied to every default in the library: **a feature nobody
asked for is off.** A `Fetcher` now retries nothing, follows nothing and
sends no headers until a parameter says otherwise.

```dart
Fetcher()                  // retries: 0, redirects: 0, headers: {}
Fetcher(retries: 3)        // retried, POST included
Fetcher.browser()          // the Chrome UA and HTML Accept header, by name
```

| Was | Is |
| :--- | :--- |
| `retries: 2` | `retries: 0` |
| a Chrome `User-Agent` + `Accept: text/html` on every `Fetcher()` | `Fetcher.browser()`, or `headers:` |
| `redirects: 5`, followed | `redirects: 0`, handed back |

A `3xx` is an answer the server gave, and the client reports it: `res.status`
is `302` and `res.headers['location']` is where it points. `5` was a hop
budget no caller had chosen.

### One parameter per question

The same review read the *parameters* against Rule 5, which had only ever
been run against members. Three pairs said one thing twice, each a `bool`
deciding whether a number applied:

```dart
get(url, redirect: false)      →  get(url)                  // or redirects: 0
get(url, retry: false)         →  get(url)                  // or retries: 0
concurrentRetry(fn, times: 3)  →  concurrentRetry(fn, retries: 2)
```

`Fetcher.unsafe` is **deleted** — the shape one step on, a `bool` deciding
*which methods* the int applied to. It existed to stop a default of `2`
replaying a `POST`; with the default `0`, `retries: 3` on a `post` is a
caller saying what they meant, and `retries: 0` on the call opts back out.

`concurrent.retry`'s `retries:` is **required**. It is the one number the
library will not invent and cannot default to zero: `retry(fn, retries: 0)`
is `fn()` under a name that promises otherwise.

Per-call `retries:` and `redirects:` are `int?`, and the `null` is
load-bearing — *no override given, use the client's*. `Fetcher(retries: 3)`
would be unreachable through `get` and `post` if theirs defaulted to `0`.

`download`'s `onProgress:` → `onprogress:`, the library's last camelCase
parameter, now spelled like the `onretry:` and `onchange:` it sits beside.
It also takes `retries:`, which every sibling already did.

**Migrating.** A crawl over the default client no longer retries; pass
`Crawl.using(Fetcher(retries: n))`. A scrape that leaned on the implicit
browser headers wants `Fetcher.browser()`. Anything reading a redirect chain
wants an explicit `redirects:`.

### `$` is the selector

`Markup.find` → **`Markup.$`**, `Markup.xpath` → **`Markup.$xpath`**, and
`format.html` gains `$(text, selector)` and `$xpath(text, query)` — parse and
select in one call, with the selector required so neither is a second
spelling of `parse`.

```dart
page.$('.row').$('.name').texts       // was page.find('.row').find('.name')
page.$xpath('//a').attr('href')       // was page.xpath('//a')
format.html.$(markup, '.track')       // new: one call instead of two
```

`$` was the one survivor of Rule 5 for four releases, behind an opt-in import,
on the reasoning that a script should not be forced to see an identifier
called `$`. That argument proves something narrower than the design built on
it: **the objection is to a global named `$`, and a method named `$` is not a
global.** `page.$('a')` adds nothing to any scope. So the subject's own name
won outright, and `find`/`xpath` went rather than standing beside it.

The two top-level functions really are globals and stay behind
`package:dart_toolkit/html.dart`, unchanged. `extension
QuerySelectorOnHtmlString on String` is **deleted** — a third door onto one
operation, and the only one that had to be an extension because `String` is
not ours:

```dart
markup.$('.track')       →  format.html.$(markup, '.track')
                         →  $(markup, '.track')          // with the opt-in import
```

`Markup.xpath`, a named *constructor* with zero callers, is deleted with it.
It had been dead since 6.0.0 and was invisible while a method of the same
name sat beside it.

258 call sites moved; the analyzer named every one.

## 6.0.0

**The sweep.** An API review read every namespace against the same guardrail —
*smaller is not the goal; not saying the same thing twice is* — and came back
with eight files. Seven were proofreads. One was a rebuild.

A name was deleted only when it was **dead**, was **the same operation under a
second name**, was **declared in more than one place** so the copies could
disagree, or was **in the wrong domain** while the right one already existed.
A name that is merely *short for something* stayed, and three of the eight
reviews recommended making a surface *larger*.

---

### `net` — rebuilt on three seams

41 public types → 14, and three of the ones that went moved to `format` rather
than disappearing. `net/serve.dart` was the control: the same domain, written
once with a fixed idea of how small it should be, and its library doc lists
what is deliberately absent. Nothing else in `net` had that paragraph.

#### A transport is a function

```dart
typedef Send = Future<Reply> Function(Fetch fetch);
```

`Downloader`, `DownloaderEvents`, `HttpDownloader` and `MapDownloader` are
**deleted**. A subclass inherited an engine back-pointer, six mutable
scheduling fields, a worker loop with a per-host throttle table, and a
`save()` hook that threw `UnsupportedError` and had **zero callers in `lib/`**
— to plug in a headless browser. A `Fetcher` implements `Send`, so `net.http`
is the default; everything else is a closure:

```dart
// A fixture, and the recorder MapDownloader existed for.
Send fixture(Map<String, String> pages, List<Fetch> sent) => (f) async {
  sent.add(f);
  return Reply.text(pages['${f.url}'] ?? '', fetch: f);
};

// Middleware, which had no spelling at all before.
Send logged(Send inner) => (f) async {
  final res = await inner(f);
  log.debug('${res.status} ${f.url}');
  return res;
};
```

`crawl.downloader(d)` → `crawl.using(send)`.

#### `Page<T>` folded into `Reply`, and `follow` returns

Everything `Page` added was either the request it came from or a call on an
engine:

| Was | Is |
| :--- | :--- |
| `res.requested` | `res.fetch.url` |
| `res.tag`, `res.meta`, `res.depth` | `res.fetch.tag`, `res.fetch.meta`, `res.fetch.depth` |
| `res.emit(item)` | what the caller does with the reply |
| `res.stop(reason)` | cancelling the flow |
| `res.follow(href, …)` | **returns a `Fetch`** instead of queueing one |
| `res.submit(form)` | `form.at(res.url).fetch()` |

That last change is the whole migration for a handler:

```dart
// before — a closure with a side effect, needing an engine behind it
res.parse(format.html).find('a').attrs('href')
   .collect(.foreach((h) => res.follow(h)));

// after — a pure function from a reply to the next requests
res.parse(format.html).find('a').attrs('href').transform(.map(res.follow))
```

`Fetch` loses its type parameter. It carried one — the *item* type a handler
emitted — used in exactly one place: a back-pointer to the engine that owned
it. Thirteen public types were generic for that reason and none is now.

#### One `Crawl`, and a `Flow<Reply>`

`Engine`, `EngineEvents`, `QueueAccess`, `CrawlBuilder`, `CrawlEvents`,
`Router`, `Handler`, `Snapshot`, `Stats` (the class), `Failure` and
`Deduplicator` are **deleted**. What replaces them is one type with twenty
members, where `CrawlBuilder` alone had 45:

```dart
final crawl = net.crawl([Fetch(seed)], (res) => switch (res.fetch.tag) {
  null     => res.parse(format.html).find('.artist a').attrs('href')
                 .transform(.map((h) => res.follow(h, tag: 'artist'))),
  'artist' => res.parse(format.html).find('.album a').attrs('href')
                 .transform(.map((h) => res.follow(h, tag: 'album'))),
  _        => const Sequence<Fetch>([]),
})
  ..using(Fetcher(headers: headers, timeout: 10.s, retries: 3).call)
  ..concurrent(4)
  ..delay(250.ms, perhost: true)
  ..samehost()
  ..obey('ExampleBot/1.0');

final tracks = await crawl.flow
    .transform(.where((r) => r.fetch.tag == 'album'))
    .transform(.flat.map(_tracks))
    .collect(.list());

log.ok('${crawl.stats.fetched} pages, ${crawl.stats.failed} failed');
```

`Router`, `route()` and `tag()` go because Dart's `switch` is a better router
and the compiler checks it. `next` is a pure function — reply in, requests out
— so it is testable with a `Reply.text` fixture and no crawl at all, which the
old `Handler` was not.

The terminals are `flow`, `settle` and `run()`:

| Was | Is |
| :--- | :--- |
| `on.start(fn)` | the line before the terminal |
| `on.progress(fn)` | `.transform(.tap(fn))` |
| `on.item(fn)` | the flow itself |
| `on.done(fn)` | the line after; `crawl.stats` |
| `on.error(fn)` | `.settle`, giving `Done`/`Broke` |
| `crawl.items()` | `.collect(.list())` |
| `crawl.gather(map)` | `.transform(.flat.map(map)).collect(.seq())` |
| `crawl.run(handler)` | `run()`, no argument |
| `crawl.save(path)` | `io.async.lines.write(path, …)` |

`Stats` is a record — `(fetched, failed, skipped, bytes, elapsed, reason)` —
and its JSON encoding moved to `Crawl.position`, which is the only thing that
needed it. `retried` left it entirely: retrying happens inside the client, so
the number is `Fetcher.retried`.

`crawl.engine()` is gone — `Crawl` *is* the engine — and the five entry points
are one, because a seed is a `Fetch` and a `Fetch` takes any URL the library
can answer:

```dart
net.crawl([Fetch(url)], next);             // was crawl(uri)
net.crawl(urls.map(Fetch.new), next);      // was .all(uris)
net.crawl(fetches, next);                  // was .seed(fetches)
net.crawl([Fetch(coerce(markup))], next);  // was .html(markup)
net.crawl([Fetch(Uri.file(path))], next);  // was .file(path)
```

#### One knob, one place

Ten knobs were declared at four levels — builder, engine, downloader, client —
**thirty-two declarations in all**, and `CrawlBuilder.engine()` copied exactly
five of them onto a caller-supplied downloader and dropped `cap`, `cache`,
`timeout`, `headers` and `accept` without a word. A crawl now owns the knobs a
*scheduler* owns; everything about the client is set once on the `Fetcher`:

```dart
crawl.headers(m)  →  Fetcher(headers: m)
crawl.timeout(d)  →  Fetcher(timeout: d)
crawl.retry(n)    →  Fetcher(retries: n)
crawl.cap(n)      →  Fetcher(cap: n)
crawl.cache(dir)  →  Fetcher(cache: HttpCache(dir))
crawl.base(dir)   →  Fetcher(base: dir)
```

`crawl.robots(bool, agent)` → `crawl.obey([agent])`, per Rule 4's *the flag is
not the lookup*. `crawl.perhost(b)` → the `perhost:` argument on `delay`.
`crawl.deduplicator(d)` → `crawl.restore(position)`.

**Nothing is fetched until something collects.** The workers start in the
flow's `onListen` and stop when it is cancelled, so `crawl.flow` built and
thrown away costs nothing, and `crawl.flow.collect(.first())` fetches one page.

#### `net` stops parsing

Its library doc opens with *this domain does not parse anything*, and then
declared three parsers.

- `net.robots(text)` → **`format.robots`**, a `Codec<Robots>` with `parse`,
  `read`, `write` and `format`.
- `net.sitemap(text)` → **`format.sitemap`**, a `Codec<Sequence<Uri>>`.
- `Form` and `Markup.form` → **`format.html`**. Reading a `<form>` is HTML;
  sending one is `net`, which keeps the `Sending` extension — the same shape
  as `io` declaring `Sequence.dump` on a `collection` type. `HttpMethod` moved
  to `lib/src/` for the reason `Codec` is there.

`Robots.load` and `Sitemap.load` are deleted. `.obey()` reads `/robots.txt`
through the crawl's own `Send`, so politeness works against a fixture
transport — which `Robots.load` could not do, because it reached for the
shared client itself. A sitemap index is a crawl, and gets depth, dedupe and
politeness for free:

```dart
final urls = await net
    .crawl([Fetch(index)], (r) => r.parse(format.sitemap).transform(.map(Fetch.new)))
    .depth(8)
    .flow.transform(.map((r) => r.url)).collect(.list());
```

Nine lines against ninety, and it cannot loop.

`TextBody`, `BytesBody`, `FormBody` and `JsonBody` are **private**.
`Body.text`, `.bytes`, `.form` and `.json` are the whole surface.
`PathResolver` is private, having existed only so `Downloader` could share it.
`net.use(client)` **stays**, documented as the one exception it is.

---

### `format` — the domain doc made true

- **`FileCodec.write`**, on all five codecs: `format.yaml.write(path, value)`
  is the inverse of `read`, atomic, one line over `format`. `io.dump` stays as
  JSON's shorthand over it, and the four `dump`s share one encoder now.
- **`format.zip.read` → `format.zip.extract`.** It took two arguments and
  returned `List<int>?` — *take one entry out* — sharing a name with five
  siblings' *parse the document at this path*. `unpack` and `extract` are the
  pair.
- **`Entry` → `ArchiveEntry`.** It landed at top level beside
  `FileSystemEntry`, two types describing "a thing with a name and a size that
  might be a directory", with nothing in the shorter name to say which.
- **`format.html.query` deleted.** It was `parse` plus a flag configuring
  `$xpath`, which is not on the default surface — so nothing there could
  observe the difference. `lib/html.dart`'s `$xpath` sets the flag itself.
- The domain doc now names `format.zip` as the one member that is **not** a
  codec, and says why: an archive is a container of files, not a document with
  a shape.

---

### `io` — the read and write halves spelled the same

- **`io.save` → `io.bytes.write`.** `write` and `save` are the same English
  word for this, and nothing said which took bytes. The rule for the whole
  domain: **the name says the shape, and `.write` is how it goes back.**
  `io.bytes` and `io.chunks` became namespace objects with a `call`, which is
  the shape `io.lines` and `io.append` already had.
- **`io.chunks.write` added**, on both accessors, so copying a file larger
  than memory is one line.
- **`io.has(path, match: true)` deleted.** It was provably `io.similar(path)`
  for every input — `similar` opens by calling `has`.
- **`FileSystemEntry.stem`, `.ext` and `.dirname` deleted.** They were
  `io.path.stem(e.path)` and friends on the same input. `name` stays,
  redefined as the one-liner; `isfile`/`isdir`/`islink`/`empty` stay because
  they read the `kind` the snapshot already holds.
- **`io.dir.cwd` and `io.dir.home` → `io.path.cwd` and `io.path.home`.** They
  read nothing, which is `io.path`'s whole membership rule — and the move
  empties `io.dir`'s mirror exception list.
- `Appender`'s lifecycle is named in the domain doc: it is the one type in
  `io` that owns a resource.

---

### `collection` — one rule for three containers

- **`flow.pipe` → `flow.transform`, `flow.pour` → `flow.collect`.** The four
  operation types 5.5.0 introduced were the point and they survive; the
  *member* rename was forced by a spelling, which Rule 4 calls a workaround.
  Shape with `transform`, finish with `collect`, on a `Sequence`, a
  `Dictionary` or a `Flow`. The `await` in front of a flow's terminal says
  which container you are on more reliably than a member name.
- **`Dictionary.count` and `.empty` kept, redefined** as `collect(.count())`
  and `collect(.empty())` — one implementation, and `if (dict.empty)` keeps
  reading like English. This is the one place in the sweep where the
  recommendation went against the smaller surface, deliberately.
- The docs now say why there is no `Flow.seq`: `await flow.collect(.seq())`
  costs waiting for all of it, and the `await` is the only honest way to say
  so.

---

### `system` — 76 colour names with three duplicate spellings and four holes → 77 with neither

- **`Ansi.strip` and `Ansi.width` deleted.** `s.plain` and `s.width` are the
  names. `plain` is not short for `strip`; it is a different word for it.
- **`Ansi.detect()` private.** `refresh()` is the door.
- **Four missing colours added** — `black`, `bgblack`, `bgmagenta`, `bgwhite`
  — and a regression test pins the mirror: every `static const String` code on
  `Ansi` has a member of the same name on the extension. The extension is the
  surface; the constants are the mechanism.
- **`system.exit` deleted, and `system.shutdown` returns `Never`.** They
  differed in whether the `system.on.exit` hooks ran, which is the whole point
  of `system.on` existing, and neither name said so. A script that genuinely
  means to skip its own cleanup imports `dart:io`.
- `system.windows`, `.macos` and `.linux` are one line off `system.os`
  instead of a second independent reading of the platform.
- `writer.dart`'s seven public types are four files: `table.dart`,
  `progress.dart`, `spinner.dart`, `writer.dart`. No name moved.

---

### `concurrent` — the one domain that got bigger

9 public types → 10.

- **`Waiting`**, implemented by `Semaphore` and `Limiter`. Two axes — *how
  many at once*, *how often* — wore the same three member names with no type
  saying so. `Fetcher(limiter:)` takes it, so a client paced by a semaphore
  compiles where only a rate did.
- **`PoolFailure` carries `Sequence<Settled<R>>` and `Sequence<I>`.** There
  were three shapes for *a task threw*: `PoolFailure.failures`,
  `PoolEvents.error`'s triple, and `Broke`. One outcome type across all three
  terminals now. `e.failures` → `e.outcomes.transform(.where.type<Broke<R>>())`.
- **`concurrent.pool(size:, delay:)` added**, so all three types have a
  factory.
- `Pool.flow`'s doc pointed at `Flow.run`, deleted two releases ago;
  `settle`'s positional-alignment guarantee is written down. A regression test
  now sweeps `lib/` for doc references to members that do not exist.

---

### `cli` — the mirror pinned

- **`CliAccessor.switches` added.** It was on `Cli` only, so a script outside
  a handler wrote `cli.parsed.switches` — a third spelling of a member that
  has one. A regression test now asserts every `Cli` member appears on
  `CliAccessor`, with `parse` and `parsed` the two named exceptions.
- **`Cli.strict()` and `CliAccessor.strict()` deleted.** One word, two failure
  modes: `strict()` threw an `ArgumentError` out of wherever it was called,
  while `run(strict: true)` turned the same condition into a usage block and
  exit code 64. `unknown()` is the question; the caller picks the consequence.
- `cli.dart`'s 1,379 lines are five files, as `part`s. No name moved.
- `Opt`'s four readers get the paragraph that stops a reader reaching for
  `call() != def`.

---

### `util` — a proofread

- **`util.hash.encode`/`decode` → `util.text.base64`/`unbase64`.** Base64 is
  reversible, in a namespace of four one-way digests, named after the
  direction rather than the operation — so `util.hash.encode(secret)` read as
  exactly the thing it is not.
- **`util.text.strip` → `util.text.tags`.** *Remove something*, where the
  something is a whole markup language. Both docs now name the other: this is
  a regex and costs nothing, `format.html.parse(t).text` builds a document and
  is right about entities and malformed nesting.

---

### Migration

| 5.5.0 | 6.0.0 |
| :--- | :--- |
| `net.crawl<T>(uri)` | `net.crawl([Fetch(uri)], next)` |
| `.downloader(MapDownloader(m))` | `.using(fixture)` — a closure |
| `.run(handler)` / `.items(handler)` | `next`, plus `flow`/`settle`/`run()` |
| `.gather(map)` | `.flow.transform(.flat.map(map)).collect(.seq())` |
| `res.emit(x)` | what the caller does with the reply |
| `res.follow(h)` | `res.follow(h)` — now **returns** a `Fetch` |
| `res.submit(form)` | `form.at(res.url).fetch()` |
| `res.tag` / `.meta` / `.depth` / `.requested` | `res.fetch.*` |
| `crawl.headers/timeout/retry/cap/cache/base` | `Fetcher(...)` + `.using` |
| `crawl.robots(true, a)` | `crawl.obey(a)` |
| `net.robots(t)` / `net.sitemap(t)` | `format.robots.parse(t)` / `format.sitemap.parse(t)` |
| `flow.pipe(...)` / `flow.pour(...)` | `flow.transform(...)` / `flow.collect(...)` |
| `io.save(p, d)` | `io.bytes.write(p, d)` |
| `io.has(p, match: true)` | `io.similar(p)` |
| `e.stem` / `e.ext` / `e.dirname` | `io.path.stem(e.path)`, … |
| `io.dir.cwd` / `io.dir.home` | `io.path.cwd` / `io.path.home` |
| `format.zip.read(a, n)` | `format.zip.extract(a, n)` |
| `Entry` | `ArchiveEntry` |
| `format.html.query(t)` | `format.html.parse(t)` |
| `Ansi.strip(s)` / `Ansi.width(s)` | `s.plain` / `s.width` |
| `system.exit(n)` | `system.shutdown(n)` — and it runs your hooks |
| `cli.strict()` | `if (cli.unknown().isNotEmpty) { cli.help(); await system.shutdown(64); }` |
| `util.hash.encode(x)` / `decode(s)` | `util.text.base64(x)` / `unbase64(s)` |
| `util.text.strip(t)` | `util.text.tags(t)` |
| `e.failures` | `e.outcomes.transform(.where.type<Broke<R>>())` |

## 5.5.0

Two vocabularies, and the filesystem overhauled. An API review read the
library against its own documentation and came back with two findings that
were really one: **`Sequence` and `Flow` were being served by one pair of
operation types, and both were paying for it**, and **`io` had grown three
ways to filter a tree, four silent bugs and a corner where the prefix did not
tell you what you got.**

The first is the release. `Transformer` stored the synchronous form as a
required field and the streaming form as an optional one, and three
complaints fell out of that single asymmetry.

**A flow-native operation could not join the vocabulary at all.** An
operation whose element step is asynchronous has no `Iterable` half to
supply, so it could not be a `Transformer` — which is why `asyncMap` was
`flow.run(worker, size: n)`, an extension declared over in `concurrent`,
reached past the two members a flow was documented to have. The same
constraint is why `flow.stream` carried eight `Stream` members with "no
spelling here", and why `debounce`, `throttle`, `merge`, `asyncExpand` and an
async predicate had no spelling anywhere.

**`Flow`'s constraints were billed to `Sequence`.** An operation a flow
cannot stream was demoted to a `Collector` on *both* sides. On a flow that is
right. On a sequence it meant the commonest shape in the library's own
examples changed container twice for nothing:

```dart
rows.collect(.sort.by((r) => r.cost)).transform(.take.first(10)).collect(.list())
```

Three calls and two container types for Kotlin's `sortedBy(cost).take(10)`.

**And the operation types spoke Dart's vocabulary in public.** `Sequence`
exists so `Iterable` is not in scope, and then `Transformer.run` handed one
back as a public field.

### 1. Four operation types, one per job per container

| Container | Shaping step | Terminal |
| :--- | :--- | :--- |
| `Sequence<T>` | `Transformer<A, B>` — `Iterable<B> Function(Iterable<A>)` | `Collector<A, R>` — `R Function(Iterable<A>)` |
| `Flow<T>` | `Pipe<A, B>` — `Stream<B> Function(Stream<A>)` | `Pour<A, R>` — `Future<R> Function(Stream<A>)` |

`Transformer` and `Collector` lose `pour`. `Pipe` and `Pour` have no
synchronous fallback, so the *"streaming is a promise rather than a proof"*
caveat on `fn` is gone — there is nothing left to silently buffer.

**The operations keep their spelling.** A dot shorthand resolves its name
against the context type, so `.where(live)` reads the same on either
container and picks the factory that fits. `pour` was this library's word for
*the same operation over a stream* as a field; it is a type now, which is the
same idea said properly.

### 2. `flow.pipe` and `flow.pour`

A `Flow`'s two members were `transform` and `collect` — the same two words a
`Sequence` uses. With one pair of operation types that was honest. With two
it is not: a member named the same on both containers reads as though one
pipeline value fits either, which is exactly what the library claimed and
could not deliver.

```dart
rows.transform(.where(live));   // Transformer -> Sequence
rows.collect(.count());         // Collector   -> int
flow.pipe(.where(live));        // Pipe        -> Flow
await flow.pour(.count());      // Pour        -> Future<int>
```

Four members and four operation types, paired by name. What the member tells
you is which container the next call is on — the one thing that used to be
invisible.

### 3. What moved back to the sequence side

These were `Collector`s only because a flow cannot stream them. On a sequence
the law is bookkeeping — the source has an end, and reading all of it is what
the operation *is* — so they are `Transformer`s and a chain never changes
container:

| Operation | 5.4.0 | 5.5.0 on a `Sequence` | 5.5.0 on a `Flow` |
| :--- | :--- | :--- | :--- |
| `sort()` / `.by` / `.using` | `Collector<A, Sequence<A>>` | `Transformer<A, A>` | `Pour<A, Sequence<A>>` |
| `flip()` | `Collector<A, Sequence<A>>` | `Transformer<A, A>` | `Pour<A, Sequence<A>>` |
| `take.last(n)` | `Collector<A, Sequence<A>>` | `Transformer<A, A>` | `Pour<A, Sequence<A>>` |
| `skip.last(n)` | `Collector<A, Sequence<A>>` | `Transformer<A, A>` | `Pour<A, Sequence<A>>` |

```dart
rows.transform(.sort.by((r) => r.cost)).transform(.take.first(10)).collect(.list())
```

5.4.0's *"`sort` is not a transformer"* inverts into **"`sort` is not a
pipe"**, which is the sharper statement: on a flow the answer genuinely
cannot exist until the source ends, and `Pour.sort` hands back a `Sequence`
to say so. Sorting inside a bucket keeps the spelling 5.3.0 gave it, because
`group.into` takes a `Collector` and `Transformer.into` makes one:
`group.into(f, Transformer.sort<T>().into(.seq()))`.

### 4. What the flow side gains

None of these had a spelling anywhere through 5.4.0:

| Name | Replaces / adds |
| :--- | :--- |
| `map.async(each, {size, ordered})` | `flow.run` — moves out of `concurrent` into the vocabulary |
| `where.async(test, {size})` | nothing; had no spelling |
| `flat.async(each)` | `asyncExpand` |
| `chunk.time(d)` | nothing; the batch a clock closes |
| `debounce(d)` / `throttle(d)` | nothing |
| `timeout(d)` | `flow.stream.timeout(d).flow` |
| `handle(onError)` | `flow.stream.handleError(…).flow` |
| `merge(other)` | nothing |
| `tap(each)` | a `map` that returns its input |
| `Pour.foreach(FutureOr<void> Function(A))` | the async terminal the library did not have |

`flow.stream` stays as the door and now carries only what is genuinely
foreign — `listen`, `pipe`, `drain`, `asBroadcastStream` — rather than five
operations the vocabulary could not express.

**`Pour.foreach` awaits, and that fixes a silent bug.**
`Collector.foreach` takes a `void Function(A)`, and Dart assigns a
`Future`-returning closure to that type without a word. So this compiled,
started every write and awaited none:

```dart
await flow.collect(.foreach((n) async {
  await io.async.write('out/$n.txt', 'x');   // never awaited
}));
```

The most likely mistake in a streaming script, because `foreach` is the
natural terminal and the docs send you to `io.async` inside concurrent work.
`Pour.foreach` takes a `FutureOr<void>` and awaits each call before the next.
`Collector.foreach` stays synchronous — a sequence is walked synchronously
and there is nothing there that *could* await — and its doc now names the
trap and the two answers: `seq.flow.pour(.foreach(f))`, or `concurrent.run`.

### 5. A binary operand takes the right container

`zip`, `plus`, `minus`, `common` and `or` took a `Sequence` on the one
operation type, so `[1].flow.pipe(.zip([2].flow))` did not compile — two
flows could not be zipped, concatenated, differenced or intersected, and
there was no door, because `flow.stream` reaches `Stream`, which has no `zip`
either.

```dart
Transformer.zip<A, R>(Sequence<R> other)   // walked per walk
Pipe.zip<A, R>(Flow<R> other)              // consumed once, as its contract says
```

Zipping two files line by line is expressible, and no sealed `Source<T>`
union was needed.

### 6. `flat`, retyped

`Transformer.flat<B>()` was a `Transformer<Never, B>` — a trick that made it
type-check against *any* receiver, infer nothing, and throw `StateError` at
runtime on an element that was not iterable:

```dart
[1, 2].seq.transform(.flat<int>()).collect(.list());
// StateError: flat() needs sequence or iterable elements; found int
```

It has the static type it always had:

```dart
Transformer.flat<B>()  ->  Transformer<Sequence<B>, B>
Pipe.flat<B>()         ->  Pipe<Sequence<B>, B>
Pipe.flat.async(each)  ->  each returns a Flow<B>
```

`B` infers from the receiver, so `.flat()` works where `.flat<Row>()` was
required, and the `StateError` branch and its runtime type-sniffing are
deleted. A sequence of something else nested is one `map` away:
`transform(.map((l) => l.seq)).transform(.flat())`.

### 7. One rule for what a callback owes

`flat.map` took a `Sequence` and `crawl.gather` took an `Iterable`, so a
caller could not predict which container a callback owed. One rule now, and
it is directional:

> **What a callback hands the library back is a `Sequence`** — `flat.map`,
> `Pipe.flat.map`, `crawl.gather`. What a caller hands *in* stays an
> `Iterable`, because that is what `.seq` is the seam for.

`Transformer.run`, `Collector.run` and `fn` keep `Iterable` on both sides:
they are the raw function form of an operation, not a collection API, and
that is the honest boundary of an operation *value*.

### 8. `chunk(0)` throws

It yielded nothing, which is a chunking of no rows into no batches and is
nobody's intention. A size that came out zero is an arithmetic bug upstream,
and silence let it reach the output. `ArgumentError`, on both `chunk` and
`Pipe.chunk`.

### 9. `Flow` gap-fill

- **`Flow<T?>.nonnull`** — the twin `Sequence` always had. Asking for it was
  an `undefined_getter`.
- **`Flow.dump(path)`** — a streaming JSON array through a staging file,
  declared in `io` as an extension the way `Sequence.dump` is, so
  `collection` still knows nothing about the disk.
- **`Flow.of(() => stream)`** — a flow that **rebuilds its source** on every
  terminal, so a source that can honestly be read again can be consumed as
  many times as a `Sequence` can be walked. A shaping step carries the
  property forward. `.seq.flow`, `.flow` on an `Iterable` and every listing
  and reader on `io.async` are these now, which is what makes the `io` mirror
  a real one — see §13.

---

## The `io` overhaul

Eight bugs, four consolidations and seven members that were missing.

### 10. The bugs

**`io.async.dir.sweep` deleted under a live walk.** The blocking twin takes
its whole listing first and says why: *deleting under a walk in progress is
the one thing a lazy listing cannot be asked to survive.* The 5.3.0 flow
rewrite made the async twin do exactly that, over a lazy recursive listing.
It collects first now.

**`io.copy` of a directory was lossy about symlinks.** It walked with
`Directory.list(recursive: true)` and branched on `is Directory` / `is File`,
so a link to a file was **dereferenced into a second copy of the content**
and a link to a directory matched neither branch and was **dropped without a
word**. It routes through `Entries.walk(follow: false)` now — the three kinds
and the cycle guard the listing already had — and recreates a link as a link,
pointing where it pointed. `io.copy` of a single link is kind-preserving too.

**`io.move` of a directory onto an existing directory merged the two trees.**
`rename` refuses that; the blanket `on FileSystemException` caught the
refusal, fell back to copy-and-delete, and left the two trees merged with the
source gone. It throws now. The fallback is also for a cross-device error
(`EXDEV`) and nothing else — every other failure is rethrown as itself rather
than becoming a half-finished copy.

**Concurrent atomic writes to one path collided.** The staging path was
`'$path$part'` with no disambiguator, and `atomic` deleted an existing
staging file before writing, so two `io.async.write` calls to one path took
each other's file out and the loser failed with an internal `.part` path in
the error message — platform-dependently, since Windows throws on the delete
instead. This is the exact concurrency the docs encourage. The staging name
carries the pid and a per-process counter now, so writers race only on the
final rename, which POSIX makes atomic. The suffix is still `part`, so
`io.dir.sweep(out, match: '*.part')` still finds an abandoned one.

**`FileSystemEntry.empty` did blocking disk IO inside a getter** —
`Directory(path).listSync(followLinks: false).isEmpty` — reached from
`io.async.empty`, so the non-blocking accessor blocked on every directory it
was asked about. It also broke the type's own promise of *one stat, four
answers*. It is `!isdir && size == 0` now and touches nothing. Counting what
is in a directory is a second listing, so it is a second call that says which
accessor it is on: **`io.dir.empty(path)`**, with an async twin.
`io.empty(path)` still answers for either kind, by asking the right one.

**The async write path made sync syscalls.** `Fs.atomic` used
`existsSync`/`renameSync` and `download` used `lengthSync`, from the accessor
whose whole promise is not blocking. All three are awaited now.

**Ninety lines of dead duplicate implementation** — `Fs.find`, `Fs.findAsync`,
`Fs.delete`, `Fs.deleteAsync` — re-implemented listing and sweeping with
*different* semantics from `Entries`: basename-only matching, `followLinks`
defaulted on, no cycle guard. Two implementations of one operation, one
unreachable. Deleted. `Fs.parent`/`Fs.parentAsync` were the same thing as
`Fs.mkparentSync`/`Fs.mkparent` and went with them.

**`io.lines` was eager inside a type documented as lazy.** It wrapped
`readAsLinesSync`, so the whole file was a `List` before the `Sequence`
existed — where `Sequence`'s class doc promises *a view, not a snapshot* and
warns about double walks. It is a generator over the decoded text now:
nothing is read until something walks it, a walk that stops early stops
reading, and a second walk re-reads the file.

### 11. `io.dir` — one matcher, one depth axis

There were three vocabularies for *filter a tree*: `walk`'s glob, `find`'s
`Pattern` with a `recursive:` bool, and `glob`'s pattern-as-the-argument.
`find`'s own doc said it gave *the same set* as `walk(only: .file, match: …)`.

| After | Before |
| :--- | :--- |
| `io.dir.list(dir, {only, match})` | unchanged |
| `io.dir.walk(dir, {only, match, depth, follow})` | unchanged |
| `io.dir.glob(pattern)` | unchanged |
| `io.dir.sweep(dir, {only, match, depth})` | `sweep(dir, {pattern, recursive})` |
| — | **`io.dir.find` deleted** |

- **`match:` is the only matcher**, and it is a glob. A `RegExp` filter is the
  collection vocabulary's job: `walk(d).transform(.where((e) => re.hasMatch(e.name)))`.
- **`depth:` is the only depth axis.** `recursive: false` is `depth: 1`, which
  the docs already defined as equal to `list`. No member keeps a bool.
- **`sweep` defaults to the whole tree**, matching the member it is built from
  rather than contradicting it. This is a behaviour change. It also leaves
  directories alone unless `only: .directory` asks for them, and deletes
  deepest-first so nothing is counted twice.

New: **`io.dir.size(dir)`** (the recursive byte total, where `io.size` on a
directory is `0` by design; links count as nothing so a tree is not counted
twice), **`io.dir.empty(path)`**, and **`io.dir.link(path, target)`** /
**`io.dir.target(path)`** — `io.islink` could read a link and nothing could
make or resolve one. All four have async twins.

### 12. `io.csv` is a mirror

`io.csv.records` and `rows` returned a `Flow` and `write`/`pipe` a `Future`,
all reached through `io`, whose doc promises *everything here blocks*. It was
the one corner where the prefix did not tell you what you got, and the reason
the mirror rule needed a carve-out for it.

| | `io.csv` | `io.async.csv` |
| :--- | :--- | :--- |
| `rows` | `Sequence<List<String>>` | `Flow<List<String>>` |
| `records` | `Sequence<Map<String, String>>` | `Flow<Map<String, String>>` |
| `write` | takes a `Sequence` | takes a `Flow` |

The blocking reads are lazy views — a row at a time, walkable twice, stoppable
early — so a file larger than memory still works from either accessor.

**`io.csv.pipe` is deleted.** Rule 5 allows a shorthand *defined as* the
general form in one line; `pipe` was forty lines of its own implementation
beside `write`, which is two implementations of one operation, and it was the
weaker name. The streaming form is `io.async.csv.write`.

### 13. The mirror is now parity, and says where it is not

Every member whose shape differs follows one rule with no exceptions: a
`Sequence` on `io`, a `Flow` on `io.async`. That covers `lines`, `chunks`,
`io.dir`'s listings and the whole of `io.csv`.

The one property that is not parity is stated rather than glossed: **a `Flow`
is consumed once where a `Sequence` can be walked again.** `io.async.dir.walk(d)`
threw `StateError` on the second terminal while `io.dir.walk(d)` simply
re-read the disk, and the docs called the two sides *the same four words,
differing only in the `await`* — true of one terminal and false of anything
that reused the listing. Every listing and reader on `io.async` is a
`Flow.of` now: re-derivable, so a second terminal reads the disk again,
exactly as a second walk does.

### 14. The members that were missing

| New | Shape | Covers |
| :--- | :--- | :--- |
| `io.chunks(path, {size})` / `io.async.chunks` | `Sequence<List<int>>` / `Flow<List<int>>` | streaming byte read — `io.bytes` reads the whole file |
| `io.lines.write(path, seq)` / `io.async.lines.write(path, flow)` | atomic, one element per line | writing a collection to a file |
| `Flow.dump(path)` | streaming JSON array, atomic | `dump` existed for `Sequence` and `Dictionary` only |
| `io.temp([prefix])` | `FileSystemEntry` | a temp *file*, beside `io.dir.temp` for the directory |
| `io.append.open(path)` | an `Appender`, closed by the caller | repeated appends without reopening per call |
| `io.dir.link` / `io.dir.target` | create and resolve | symlinks |
| `io.dir.size` / `io.dir.empty` | `int` / `bool` | a tree's size, and the directory question |

`io.lines` and `io.append` are callable namespaces now, the way
`Transformer.map` and `Collector.count` are: `io.lines(path)` reads and
`io.lines.write(path, seq)` writes; `io.append(path, text)` opens, writes and
closes and `io.append.open(path)` hands back a handle that stays open.
Nothing a caller already wrote changed.

**`Appender` is the deliberate exception to "no open handles in `io`."** That
rule exists because a lifecycle is a thing to get wrong, and it still holds
for everything else; the exception is narrow on purpose — one member, `open`
in its name so the lifecycle is visible at the call site, and `close`
idempotent so a `finally` after an early close is not an error.

---

## The follow-ons the separation unblocked

### 15. `crawl.flow` is lazy

`net.crawl<T>(seed).flow(handler)` armed the engine **in the method body**, so
building a flow and never collecting it still fetched a page. `Pool.flow` has
guarded this with `onListen` since 5.3.0. `Flow`'s *nothing runs until
something collects* is a property of the operations; a source has to keep it
for itself.

### 16. `crawl.collect` is `crawl.items`

Same name, same receiver position, unrelated meaning: `rows.collect(.count())`
takes a `Collector` and reduces a collection, `crawl.collect(handler)` took a
page handler and ran a crawl. Rule 5 forbids exactly that, and the engine
already called them items.

### 17. `crawl.save` and `crawl.sink` are retired

They were private versions of a member the library did not have: *write this
collection to a file, one element per line, atomically*.

```dart
await io.async.lines.write('titles.txt', net.crawl<String>(seed).flow());
```

One name covers a crawl, a log, a piped stdin and a directory walk, and
`Flow.dump` is its JSON twin. A crawl that wants a sink that is not a file
writes `flow().pour(.foreach(out.writeln))`.

### 18. `crawl.gather` takes a `Sequence`

See §7. A literal or a `split(',')` crosses with `.seq`; everything this
library returns is one already.

---

## Housekeeping

### 19. `lib/util/` holds five accessors and no strays

`Json`, `Markup`, `Csv`, `Codec` and the `.url`/`.ms`/`.s` extensions sat
under `lib/util/` and were **never reachable as `util.` anything**. They are
types and extensions several domains return; a directory named after an
accessor should hold that accessor's members. They moved to `lib/src/`, where
the rest of the cross-domain machinery already lives, and they are exported
from `package:dart_toolkit/dart_toolkit.dart` exactly as before — **nothing a
caller writes changed.** `lib/util/` is five files and five accessors:
`time`, `size`, `text`, `hash`, `rand`.

The bounded-work machinery behind `Pipe.map.async` moved to
`lib/src/bounded.dart` for the same reason: `collection` and `concurrent`
both need it and neither may depend on the other.

### 20. The `docs/` folder is gone

Seventeen prose files, every sentence of which had a twin in a `///` comment.
That is Rule 5 applied to prose: two places saying one thing, and the one
further from the code is the one that goes stale. The comments are also the
copy the reader actually meets — in dartdoc, and on hover in an editor — and
they cannot drift from the signature they sit above. The narrative a folder
carried that a comment cannot lives in the library-level `///` at the top of
each file, which is where `# IO Domain (io.*)` already was.
`test/docs_test.dart` still compiles every `dart` block in every `///`
comment under `lib/`, plus `README.md`, `NAMESPACE.md` and
`example/README.md`.

---

## Migration

| 5.4.0 | 5.5.0 |
| :--- | :--- |
| `flow.transform(step)` | `flow.pipe(step)` |
| `flow.collect(step)` | `flow.pour(step)` |
| `rows.collect(.sort.by(f))` | `rows.transform(.sort.by(f))` |
| `rows.collect(.flip())` | `rows.transform(.flip())` |
| `rows.collect(.take.last(n))` | `rows.transform(.take.last(n))` |
| `rows.collect(.skip.last(n))` | `rows.transform(.skip.last(n))` |
| `group.into(f, .sort.by(g))` | `group.into(f, Transformer.sort.by(g).into(.seq()))` |
| `flow.run(worker, size: n)` | `flow.pipe(.map.async(worker, size: n))` |
| a `Transformer` on a flow | `flow.pipe(Pipe.of(transformer))` |
| `.flat<Row>()` | `.flat()`, over `Sequence` elements |
| `Transformer.fn(run, pour: p)` | `Transformer.fn(run)` and `Pipe.fn(p)` |
| `chunk(0)` | throws `ArgumentError` |
| `io.dir.find(d, pattern: re)` | `io.dir.walk(d, only: .file).transform(.where((e) => re.hasMatch(e.name)))` |
| `io.dir.find(d, pattern: '*.mp3')` | `io.dir.walk(d, only: .file, match: '*.mp3')` |
| `io.dir.sweep(d, pattern: re, recursive: r)` | `io.dir.sweep(d, match: glob, depth: r ? null : 1)` |
| `io.dir.sweep(d)` | now sweeps the whole tree, not one level |
| `io.csv.records(p)` / `io.csv.rows(p)` (a `Flow`) | `io.async.csv.records(p)` / `.rows(p)` |
| `io.csv.pipe(p, flow)` | `io.async.csv.write(p, flow)` |
| `io.csv.write(p, Iterable<Map>)` | `io.csv.write(p, Sequence<Map>)` — `.seq` on a literal |
| `entry.empty` on a directory | `io.dir.empty(path)` |
| `io.move(dir, existingDir)` | throws instead of merging |
| `crawl.collect([handler])` | `crawl.items([handler])` |
| `crawl.save(path)` | `io.async.lines.write(path, crawl.flow())` |
| `crawl.sink(out)` | `crawl.flow().pour(.foreach(out.writeln))` |
| `crawl.gather((p) => Iterable<R>)` | `crawl.gather((p) => Sequence<R>)` |
| `docs/*.md` | the `///` comments under `lib/` |

Imports are unchanged: everything still comes from
`package:dart_toolkit/dart_toolkit.dart`.

## 5.4.0

`Flow`, and the rule that sorts the vocabulary. Two complaints: *add flow to
collection — flow is just sequence, but async*, and *a method that is not
invokable on one is used for another; anything to prevent that?* The first is
right and one sentence long. 5.1.0 replaced `Iterable` with `Sequence` and
`Map` with `Dictionary`, on the argument that a vocabulary you cannot replace
is a vocabulary you are stuck with — and then stopped one collection short.
**`Stream` is Dart's third collection and it was still Dart's.**

Nine public signatures handed one back, and the moment a script touched one it
left this library's vocabulary and did not come back. Those were not edge
cases: they were the *large-data* members of four domains, the ones a script
reaches for precisely when the data is too big to hold, which is when a good
vocabulary matters most. Twenty-six of `Stream`'s thirty-seven members already
had a name here, twelve of them camelCase compounds **Rule 4 forbids in this
library's own code** — exempted only because they belonged to somebody else.

The second complaint is what makes this a rule rather than a list.

### 1. The rule

> **A `Transformer` can emit before its source ends. A `Collector` needs the
> end.**

That is why one hands back a collection and the other hands back a value, and
it is the shape the library already had — `count`, `max.by`, `group.by` and
`join` are collectors precisely because none can answer until the last element
has arrived. **Six operations were on the wrong side of it**, and nobody
noticed while there was one container, because on a `Sequence` both sides end
in the same call.

| Was | Is | Hands back |
| :--- | :--- | :--- |
| `Transformer.sort()` / `.by(k)` / `.using(c)` | `Collector.sort()` / `.by(k)` / `.using(c)` | `Sequence<A>` |
| `Transformer.flip()` | `Collector.flip()` | `Sequence<A>` |
| `Transformer.take.last(n)` | `Collector.take.last(n)` | `Sequence<A>` |
| `Transformer.skip.last(n)` | `Collector.skip.last(n)` | `Sequence<A>` |

A second container is what makes the rule observable, and enforcing it is what
answers the second complaint — with no marker type, no `FlowTransformer` and
no duplicated factory:

```dart
flow.transform(.where(live));      // fine
flow.transform(.sort.by(cost));    // does not compile
flow.collect(.sort.by(cost));      // Future<Sequence<Row>>, and it says so
```

`take.first`, `take.when`, `skip.first` and `skip.when` stay where they are.
They stream, and the split across the two types is the teaching device rather
than a wart: the verb at the call site tells you what the operation costs.

| | `Transformer` | `Collector` |
| :--- | :--- | :--- |
| `take` | `first(n)`, `when(t)` | `last(n)` |
| `skip` | `first(n)`, `when(t)` | `last(n)` |

**What it buys beyond the refusal**: `sort` becomes usable as a downstream
collector, which it could not be before.

```dart
rows.collect(.group.into((r) => r.host, .sort.by((r) => r.cost)));
// Dictionary<String, Sequence<Row>> — every bucket sorted, in one pass
```

**What it costs**: the common shape gains a `collect`. Fifty sites paid it.

```dart
spend.pairs.collect(.sort.by((e) => e.$1)).collect(.foreach(print));
```

Two `collect`s in a row reads oddly the first time and is exactly accurate:
reduce to a sorted sequence, then reduce that to a side effect. Composition
keeps working through the door that already exists — `Transformer.into` takes
any collector, so `.then(Transformer.sort…)` becomes `.into(Collector.sort…)`.

`test/regression_test.dart` pins the law the way 4.0.0 pinned *no HTML parser
under `lib/net/`*: every `Transformer` factory, run over a counting source,
must produce its first element before the source is exhausted.

### 2. `Flow<T>`, three members

```dart
final class Flow<T> {
  Flow(Stream<T> source);
  Flow.empty();
  Flow<R> transform<R>(Transformer<T, R> step);
  Future<R> collect<R>(Collector<T, R> step);
  Stream<T> get stream;
}
```

The same two doors `Sequence` has, and the boundary word in a third spelling:
`Sequence.collect(.list())`, `Dictionary.map`, `Flow.stream`. **`collect`
gives a `Future<R>` where `Sequence.collect` gives an `R`, and that is the
only difference in shape between the two types.**

```dart
final spend = await io.csv.records('big.csv')
    .transform(.where((r) => r['live'] == 'yes'))
    .transform(.take.first(1000))
    .collect(.count.by((r) => r['host']));
```

**Lazy, the same way a sequence is.** `transform` builds a pipeline and
nothing runs until something collects — and then only as much of the source as
that collect asks for. Three elements out of a `take.first(3)` behind a
`where` costs five produced, and `collect(.first())` costs one. Over a crawl
that means the crawl stops.

**Consumed once, in one voice.** Dart gives three answers to a second listen —
a `StateError` from a controller, a `FileSystemException` from a closed file,
and silence from `Stream.fromIterable`, which starts over — and which one you
get is not in the type. So `transform`, `collect` and `stream` each claim the
source, and a second claim throws one message for all three, when the second
pipeline is *built* rather than when it is listened to:

```
StateError: This flow has already been consumed.
```

The whole cost of the guard is that `Flow.empty()` cannot be `const`, where
`const Sequence([])` can.

`.flow` is the seam on `Stream`, `Iterable` and `Sequence`, beside `.seq` and
`.dict`. Crossing back is `await flow.collect(.seq())`, or `flow.stream` for
the eight `Stream` members with no spelling here:

```dart
final safe = flow.stream.handleError((e) => log.warn('$e')).timeout(30.s).flow;
```

Deliberately not pretty. It is the shape `Json.raw` and `Markup.document`
already have: one documented door, visible in review, rather than a partial
re-spelling of somebody else's API.

### 3. One operation, two consumers

`Transformer.run` is `Iterable<B> Function(Iterable<A>)`, which a flow cannot
call element by element. So each operation gained a second **function** — not
a second type, and not a second factory:

```dart
const Transformer(this.run, {Stream<B> Function(Stream<A> items)? pour});
const Collector(this.run, {Future<R> Function(Stream<A> items)? pour});
```

**Its default is correct rather than fast**: collect the stream, run the
synchronous form, emit the result. So every transformer and collector —
including one a caller subclassed three releases ago — works on a flow with no
change and no adapter. All twenty-one transformers and thirty-one of the
thirty-eight collectors override it and stream; the rest hold the source
because that is what the operation *is*. `fn` is the door, and
`fn(run, pour: …)` closes it.

`then` and `into` compose both functions, so a named pipeline runs on either
container:

```dart
final cleanup = Transformer.where<Row>(live).then(Transformer.unique.by(sku));

rows.transform(cleanup);          // Sequence<Row>
flow.transform(cleanup);          // Flow<Row>, streaming
await cleanup.pour(src).length;   // and neither, for a test
```

The alternative — one incremental machine per operation, with `run` and `pour`
derived from it — was built and benchmarked, and it is not viable. Two million
elements through a `map` and a `where`: **52 ms** today against **764 ms** for
a `sync*` driver, 14.7× slower. For collectors it is worse, because the
current `run` inherits Dart's optimised terminals — `count()` is `List.length`
at 34 µs against 31,583 µs through a sink. Two functions is not a compromise;
it is what Dart's lack of a unified sync/async iterator forces, and it is the
same fact that makes `Flow` and `Sequence` two types in the first place.

### 4. Bounded async work over a source you do not hold

Every bounded-work member in the library took an `Iterable`, so a crawl
emitting ten thousand items, a CSV too large for memory or a directory walk
could not be fed through a bounded pool without `await …toList()` first —
which is the materialisation the streaming member existed to avoid.

```dart
Flow<R> run<R>(FutureOr<R> Function(T item) worker,
    {int size = 1, bool ordered = true});
```

`size: 1` is `asyncMap`. `ordered: true` yields in the order elements arrived
however the work finishes; `false` yields in completion order. It honours its
subscription, so pausing stops new tasks launching and cancelling stops the
run. Declared in `lib/concurrent/` rather than `lib/collection/`, because
`concurrent` already depends on `collection` and a member on `Flow` would make
a cycle — the same direction `dump` and `io.dictionary` already go.

The argument for the whole release, in five lines — a piped stdin, fetched
four at a time, which was not expressible at all before:

```dart
await system.console.reader.lines
    .transform(.map((line) => line.trim()))
    .transform(.where((line) => line.isNotEmpty))
    .run(fetch, size: 4)
    .collect(.foreach(save));
```

### 5. Eight signatures, and the one that stays

| Was | Is |
| :--- | :--- |
| `net.crawl(…).stream([process])` | `net.crawl(…).flow([process])` → `Flow<T>` |
| `io.async.lines(path)` | `Flow<String>` |
| `io.csv.rows(path)` | `Flow<List<String>>` |
| `io.csv.records(path)` | `Flow<Map<String, String>>` |
| `io.csv.pipe(path, rows)` | takes a `Flow<Map<String, Object?>>` |
| `system.console.reader.lines` | `Flow<String>` |
| `Pool.stream(items, worker)` | `Pool.flow(items, worker)` → `Flow<R>` |
| `concurrent.stream(items, worker)` | **deleted** — `items.flow.run(worker, ordered: false)` |
| **`Engine.items`** | **stays a `Stream<T>`** |

`crawl.stream` is **renamed rather than retyped**, because a member called
`stream` that hands back a `Flow` no longer says what the call does — the
Rule 4 test `system.now` failed. All eight call sites then fail to compile,
which is the only acceptable shape for this change.

`Engine.items` is the one that does not move, and reading the call sites is
what found it: it is a `StreamController.broadcast`, `crawl.dart` listens to
it internally *while* a caller may also be listening, and every call site uses
it fire-and-forget. A flow is single-consumption and its terminals return a
`Future` you are meant to await, which is the opposite on both counts. So the
split is: **`CrawlBuilder` — the thing a script uses — hands back a `Flow`;
`Engine` — the plumbing under it, where a broadcast belongs — hands back a
`Stream`.** `Flow` is a pipeline, and a broadcast bus is not a pipeline.

`concurrent.run` keeps its current implementation rather than becoming
`items.flow.run(…).collect(.seq())`: it carries a `delay` parameter and
`Pool`'s error semantics that `flow.run` does not, and dropping either would
be a breaking change nothing accounts for. The two coexist honestly —
`flow.run` is the general form over a source you do not hold, `concurrent.run`
the short one over items you do.

### 6. Four operations 5.3.0's laziness pass missed

`unique`, `unique.by`, `enumerate` and `or` built a `List` or asked `isEmpty`
before yielding anything, so they walked their whole source for a
`collect(.first())`. Writing the streaming forms found them; all four are
`sync*` generators now, and both containers produce identical counts
everywhere.

| | Was | Is |
| :--- | ---: | ---: |
| `unique`, `unique.by`, `enumerate` | 1000 | **1** |
| `or` | 2 | **1** |

### 7. Rules

- **The domain map.** `collection` holds *the three collections this library
  returns in place of Dart's* — `Sequence`, `Dictionary`, `Flow`. Rule 2's
  third test still keeps it a library with no accessor.
- **A new law, under Rule 3**, pinned in `test/regression_test.dart`: an
  operation that cannot emit before its source ends is a `Collector`, not a
  `Transformer`.
- **Rule 3's `io.async` paragraph** gets a general rule in place of its special
  case: every mirrored member has the same name on both accessors, the
  blocking one returning `T` or a `Sequence<T>` and the async one `Future<T>`
  or a `Flow<T>`. That rule needed `Flow` to exist.
- **Rule 4's exemption for third-party members** stays as it is, but the reason
  it was carrying twelve camelCase names on the library's own large-data
  surface stops applying.

### The surface, after

| | Was | Is |
| :--- | ---: | ---: |
| Types in `collection` | 5 | 6 — `Flow` |
| `Transformer` factories | 27 | 21 — six moved |
| `Collector` factories | 32 | 38 — six arrived |
| New factories, net | — | **0** |
| Transformers that buffer over a flow | 7 | **0**, plus `fn` |
| Public signatures naming `Stream` | 9 | 2 — `Flow.stream`, `Engine.items` |
| Bounded async work over a stream | impossible | `flow.run(worker, size: n)` |
| Members deleted | — | 1 — `concurrent.stream` |

The library gains one type, moves six operations between two it already had,
and loses one member.

### What this release deliberately does not do

**No broadcast flow.** A flow is consumed once, and the value of the guard is
that there is one behaviour instead of three.
`flow.stream.asBroadcastStream()` is the door.

**No error handling.** An error in the source propagates out of the `Future`
that `collect` returns. There is no `handleError`, no `timeout` and no
`onError`, because *what should a pipeline do when element 900 throws* is a
design of its own — `Pool.settle`'s sealed `Done`/`Broke` is the shape that
would want generalising — and guessing at it now is how `Store.load`'s silent
empty got written.

**`io.watch` is untouched.** A watch is an endless flow of paths and the fit is
obvious, but `io.watch` returns a stop function, and that stopper is a
documented lifecycle a subscription would hide.

**No keyed flow.** There is no async `Dictionary` and nothing has asked for
one. `flow.collect(.group.by(f))` gives a `Dictionary` at the end, which is
where a keyed collection is actually wanted.

**No `Flow.unzip`.** Two views over one source means two subscriptions, which
a flow does not have. Correctly absent rather than refused.

## 5.3.0

The lazy sequence. 5.1.0 made `Sequence` a snapshot: the constructor copied
into a `List`, every `transform` copied again, and the argument for it was that
a callback then runs exactly once per element however often the result is read.
That is true, and it is the smaller of the two problems. **The larger one is
that every source paid for a full walk however little of it the caller
wanted** — `take.first(10)` over a crawl mapped the whole crawl, and
`io.dir.walk` over a tree materialised the tree before a `where` could look at
the first entry.

```dart
final Iterable<T> _items;     // was: final List<T> _items, copied in
```

A sequence now holds the `Iterable` it was given and nothing else, and
`transform` does not run its `Transformer` — it hands back a sequence that
will. Nothing is walked until a `collect` asks, and then only as far as that
`collect` needs.

### Three removals and one rule

**1. `Sequence.list` is gone.** `collect(.list())` is the way out, and the only
one. There is deliberately no `iterable` getter in its place: a getter would
put Dart's vocabulary one dot from every sequence in the library, which is
what not implementing `Iterable` was for in the first place, and it would hand
back the recipe rather than a result — `seq.iterable.length` and
`seq.iterable.first` would be two walks that read like two field reads.
Leaving is a call, and it says so. 302 call sites across `lib`, `test`,
`example` and the docs; 31 of them were `for`-in loops that became
`collect(.foreach(…))` and stayed lazy.

| To | Write |
| :--- | :--- |
| loop over it | `collect(.foreach((x) { … }))` |
| `await` inside the loop | `for (final x in seq.collect(.list()))` |
| pass it to a `List<T>` or `Iterable<T>` parameter | `collect(.list())` |
| pass it to a `Set<T>` parameter | `collect(.set())` |

**2. `Sequence.empty()` is gone.** It existed for one reason — the generative
constructor could not be `const` while it copied into a `List`. It can be
again, so `const Sequence([])` is that value and Rule 5 keeps the one
spelling.

**3. The library speaks its own vocabulary at its own boundaries.**
`Sequence.toString` now reads `collect(.join(', ', limit: 4))` rather than
taking a list and calling Dart's `take`, `map` and `join` on it — the `limit`
stops the walk at the fifth element and writes the `…` itself. `Dictionary`
does the same.

### What went lazy behind it

A lazy `Sequence` over an eagerly built `List` defers nothing, so the sources
moved too:

| | |
| :--- | :--- |
| `io.dir.list`, `walk`, `find`, `glob` | a directory is opened when the walk reaches it |
| `format.zip.list` | one entry built per entry read |
| `Markup.texts`, `attrs`, `values`, `lines`, `all` | mapped over the matches, not into a list |
| `Csv.rows`, `maps`, `column` | one row built per row read |
| `util.text.numbers` | one match read at a time |

```dart
io.dir.walk('src')
    .transform(.where((e) => e.name.endsWith('.dart')))
    .collect(.first());      // opens directories until the first match
```

The walk keeps its resolved-link set inside the generator body, which runs once
per walk, so walking the same sequence twice follows the same links both times.
`io.dir.sweep` takes its whole listing before the first delete: deleting under
a walk in progress is the one thing a lazy listing cannot be asked to survive.

`Dictionary` is the exception and stays a snapshot. `keys`, `values` and
`pairs` copy on the way out, because a dictionary has `set`, `delete` and
`clear`, and a view over those turns an ordinary walk into a
`ConcurrentModificationError`.

### The cost, stated

A sequence is a recipe, not a result. Every terminal call walks again, a source
that changes underneath shows the change, and a single-subscription source
throws on the second walk:

```dart
var n = 0;
final s = [1, 2, 3].seq.transform(.where((x) { n++; return true; }));
s.collect(.count()); s.collect(.list()); s.collect(.first());
// n == 7 — three walks, and the last one stops at the first element
```

Where a sequence is walked more than once and the walk is not free, spend one
`collect(.list())` and work from the list. That is the trade 5.1.0 made for
every sequence in the library; it is now the caller's to make, at the one call
site that needs it.

## 5.2.0

The filesystem. The complaint was three things at once — *the naming is not
unified, it lacks features like listing a folder, and it is hard to use* — and
all three checked out. `io` was 55 members across two accessors documented as
mirrors that were not; **the single most common filesystem question, does this
path exist, had no answer in the API**; and listing a directory was impossible,
because the one member that walked the disk silently dropped every directory it
found.

There was a fourth thing, which is not about names or holes: **two of `io`'s
sub-namespaces did not belong to `io`, and two more needed to exist.**

### Six moves

**1. One question per member.** `io.has` meant *a file exists and holds at
least one byte* — a useful question, and three questions fused into one whose
ingredients were not available separately:

```dart
io.has('a.txt');      // true   — a file with content
io.has('empty.txt');  // false  — a file that exists, with zero bytes
io.has('emptydir');   // false  — a directory that exists
io.has('nope.txt');   // false  — nothing there
```

Three of those `false`s mean different things and a caller could not tell them
apart. A script writing `if (!io.has(dir)) io.mkdir(dir)` was correct by
accident; one writing `if (io.has(out)) skip()` silently reprocessed every
zero-byte file forever.

```dart
io.exists(path);   // anything at all: file, directory or link
io.isfile(path);   io.isdir(path);   io.islink(path);
io.size(path);     // int?, null when there is nothing there
io.empty(path);    // exists and has nothing in it
```

`io.has` **keeps its name and its meaning**, because that composite is
genuinely what a resumable script asks and it had 29 call sites.

**2. Listing, walking, and an entry that knows what it is.** `io.find` returned
`Sequence<File>`: directories dropped, symlinks returned as if they were files,
no way to ask what kind of thing an entry was. Listing a folder, finding
subdirectories, walking a tree yourself and spotting a link before following it
were all impossible.

```dart
io.dir.list('out');                      // one level, everything
io.dir.list('out', only: .directory);
io.dir.walk('src', match: '**/*.dart');  // a glob, not RegExp(r'\.dart$')
io.dir.walk('src', depth: 2);
io.dir.walk('src', follow: false);
io.dir.glob('out/report-{2024,2025}.json');
```

`list` is one level and returns everything; `walk` is recursive. That is the
split Python (`iterdir`/`walk`), Node and Go all make, and `io.find` carried
both on one member with a `recursive:` flag while also filtering to files.
`io.find` **stays**, narrowed to what its name says.

**`FileSystemEntry` is what took the API back.** Seventeen `io` signatures
returned `File`, `Directory`, `FileSystemEntity` or `FileStat` — four
`dart:io` types whose API this library does not control, does not document and
cannot change. Counted across `lib`, `test`, `example`, `docs` and the root
documents: **one** call chained off a returned handle, and **zero** assigned
one to a typed variable. Seventeen signatures leaked a dependency to buy one
`.path`.

```dart
for (final entry in io.dir.list('out').list) {
  if (entry.isdir) continue;
  if (entry.ext == '.part') io.remove(entry.path);
  log.info('${entry.name}  ${util.size.format(entry.size)}');
}
```

Every one of those lines used to be a separate `io.stat` or a `p.extension`.
It is a **snapshot**, not a handle — no descriptor, nothing to close, so every
`io` call stays complete in itself. `FileSystemEntry.entity` is the one
deliberate door out, the way `Json.raw` and `Markup.document` are.

The sweep went past `io`: `net.http.download`, `Reply.save`, `Downloader.save`,
`HttpCache.write`, `format.zip.pack` and `format.zip.bundle` return one too, so
**no public signature in the library names a `dart:io` type**.

**3. Two sub-namespaces out of `io`, and the names that follow.** Creating a
directory is not what `io` is mainly for, and neither is listing one. Rule 3
says a cohesive vocabulary with its own nouns gets its own name:

| Through 5.1.0 | Now | |
| :--- | :--- | :--- |
| `io.join`, `io.abs`, `io.rel`, `io.expand`, `io.sanitize`, `io.ext` | `io.path.*` | nothing here touches the disk |
| `io.dir(path)` | `io.path.dirname(path)` | it returned the parent and read like it made one |
| `io.base(path)` | `io.path.filename(path)` | keeps the extension |
| `io.name(path)` | `io.path.stem(path)` | drops it |
| `io.mkdir`, `io.temp`, `io.find`, `io.sweep` | `io.dir.make`, `io.dir.temp`, `io.dir.find`, `io.dir.sweep` | addressed by a directory |
| `io.parent(path)` | `io.dir.makeparent(path)` | it *creates*; it read like it returns |
| `io.cwd`, `io.home` | `io.dir.cwd`, `io.dir.home` | they are directories |

`base` and `name` differed only in whether the extension survived, which
neither word said. And the `dir`/`parent` swap was checked rather than assumed:
renaming `parent` to *read* while `dir` meant *create* would have left every
existing `io.parent(...)` call compiling, because a call in statement position
discards its result — so four call sites would have quietly stopped creating
the directory they were there to create, with no test and no analyzer to catch
it. Moving both to different namespaces makes every old call site fail to
compile, which is the only acceptable shape for a rename that changes what a
name means.

`io.path.join` cost 118 call sites. Taken deliberately: an exception to the
rule is worse than three extra characters.

**4. The missing members, and the mirror made true.**

```dart
io.append(path, text);      // and io.async.append — the one non-atomic write
io.touch(path);             // create empty, or update mtime
io.path.normalize(path);
io.path.parts(path);        // Sequence<String>
io.lines(path);             // now truly blocking: Sequence<String>
io.async.lines(path);       // stays Stream<String>
```

NAMESPACE.md Rule 3 said `io.async` *"mirrors `io` exactly"*, and it did not:
`download` existed only on the async side, `lock`/`locked`/`watch` only on the
blocking one, and `lines` returned a `Stream` from both — including from the
accessor whose whole promise is that it blocks.

**`io.async.download` is gone**, and not replaced. A blocking twin cannot be
written — Dart has no synchronous HTTP and no way to block on a `Future` — and
it was a second spelling of `net.http.download`, which Rule 5 forbids. A socket
is `net`'s.

Rule 3 now says what a complete mirror can actually mean: every member that has
both forms appears on both sides under one name, with `lock`, `locked`, `watch`
and `io.path` outside it because they have no second form. `io.lines` is the
one member whose *shape* differs, and that is the mirror working rather than
failing. `test/regression_test.dart` pins the exception set the way 4.0.0
pinned *no HTML parser under `lib/net/`*.

**5. CSV becomes a format.** Rule 1 is explicit that a file format is a
*subject* — the sentence that admitted `format.zip`, then `format.json`,
`yaml`, `toml` and `html`. CSV was the only one left outside, for a historical
reason rather than a rule. 4.0.0 and 5.0.0 both deferred it fearing two
spellings for *read a CSV file*; the `Codec` seam 4.0.0 built is what answers
that, since `read` comes from `FileCodec` exactly as it does for the other five.

```dart
final sheet = format.csv.parse(text);          // Csv
final sheet = await format.csv.read('a.csv');  // free, from FileCodec
io.write('out.csv', format.csv.format(rows));

final sheet = res.parse(format.csv);           // and this now works
```

That last line is the unlock: a crawl that fetches a CSV export had no way to
read it through the seam every other format goes through.

`Csv` is the cursor, in `util` beside `Json` and `Markup` — `Table` is taken by
`system.console`, so it is named for what it is over. `io.csv.maps` and
`io.csv.matrix` were two methods for two shapes, so you chose before you had
seen the file; they are `sheet.maps` and `sheet.rows` off one parse now, plus
`headers`, `column(name)`, `count` and `empty`.

`io.csv` keeps `rows`, `records`, `write` and `pipe` — the four that are about
a file larger than memory rather than about CSV.

**And the two independent parsers became one.** 5.0.0 proved they agreed on all
fifteen awkward inputs it tested, which was the precondition for merging them
rather than a substitute for it: two parsers that agree today are two parsers
that drift at the next bug fix. One state machine now, driven two ways — a
whole string, or a chunk at a time.

**6. `io.dir.sweep`, `io.dir.find`.** See move 3.

### The surface

| | 5.1.0 | 5.2.0 |
| :--- | ---: | ---: |
| `io` itself | 35 | 24 |
| `io.path` | — | 11 |
| `io.dir` | — | 10 |
| `io.async` | 20 | 21 (+ `io.async.dir`) |
| `io.csv` | 9 | 4 (+ 4 in `format.csv`) |
| Signatures naming a `dart:io` type | 17 | 0 (+1 door) |
| Questions with no answer | 6 | 0 |

The filesystem half grew and the rest shrank. 5.0.0 and 5.1.0 shrank things
because they were duplicates; the six members that close the
`exists`/`isdir`/`size` gap are absences, and an API that cannot say whether a
path exists is not small, it is incomplete.

### Migration

| Through 5.1.0 | 5.2.0 |
| :--- | :--- |
| `io.join`, `io.abs`, `io.rel`, `io.ext`, `io.expand`, `io.sanitize` | `io.path.*`, same names |
| `io.dir(path)` | `io.path.dirname(path)` |
| `io.base(path)` / `io.name(path)` | `io.path.filename(path)` / `io.path.stem(path)` |
| `io.mkdir` / `io.parent` / `io.temp` | `io.dir.make` / `io.dir.makeparent` / `io.dir.temp` |
| `io.find` / `io.sweep` | `io.dir.find` / `io.dir.sweep` |
| `io.cwd` / `io.home` | `io.dir.cwd` / `io.dir.home` |
| `io.stat(path).size` | `io.size(path)` — nullable, since the path may not be there |
| `io.lines(path)` as a `Stream` | `io.async.lines(path)` |
| `io.async.download(url, path)` | `net.http.download(url, path)` |
| `io.csv.parse` / `format` / `cells` | `format.csv.parse` / `format` / `cells` |
| `io.csv.maps(path)` | `(await format.csv.read(path)).maps` |
| `io.csv.matrix(path)` | `(await format.csv.read(path)).rows` — without the header line, which is `.headers` |
| a returned `File` / `Directory` / `FileStat` | `FileSystemEntry`; `.entity` for the `dart:io` handle |

Every one of these fails to compile rather than changing behaviour quietly,
which was the constraint the `dir`/`parent` swap was designed around.

## 5.1.0

The vocabulary. `Sequence` had fifty-eight methods, and the complaint was not
that there were too many — `Iterable` has about the same and nobody minds. It
was that **roughly a third of them were words this library invented for an
operation every reader already knows under a different name.** `to` was `map`,
`keep` was `where`, `sift` was `mapNotNull`, `only` was `whereType`, `head` was
`take`, `sole` was `single`, `best` was `maxBy`, `tally` was `countBy`. Learning
`Sequence` meant learning a private dialect for a public idea.

Each rename was defensible on its own, and the set was exhausting. Two things
forced them, and neither was about meaning:

- **A collision at the top level of a class.** `map` is also the noun for the
  other collection. `where` is one autocomplete away from `Iterable.where`.
- **Rule 4 forbids camelCase.** Eight of the thirteen renames say exactly that
  and nothing else. `takeWhile` could not be a member, so it became `until`.
  `maxBy` became `best`. `associateBy` became `keyed`.

A namespace dissolves both. Inside `Transformer` there is no `Map` to collide
with, and a compound operation has somewhere to put its second word.

```dart
rows.transform(.where((r) => r.live))
    .transform(.sort.by((r) => r.cost))
    .transform(.take.first(10))
    .collect(.group.into((r) => r.host, .sum((r) => r.cost)));
```

So `Sequence` has **two** members now — `transform(Transformer)` and
`collect(Collector)` — plus `list` and `toString`. Everything else is a static
factory on one of the two operation types, and the operation types are values:
a pipeline can be named, stored, passed, supplied by a caller, and tested
against a plain list with no `Sequence` in the test at all.

This is Java's `Collectors`, which is twenty years old and uncontroversial —
with the part Java leaves as methods moved behind `transform` as well, because
keeping `take` and `skip` on `Sequence` would mean building the `take` and
`skip` namespace objects twice and keeping them in step forever.

**The minimum SDK is now 3.10.0**, for the dot-shorthand syntax the leading
`.map` above is. Every form has a longer spelling that needs nothing —
`rows.transform(Transformer.map(f))` — so a toolchain problem degrades to
verbosity rather than to nothing.

---

### The splitting rule

Rule 4 gained the rule that paid for the rest of this release. **Where Dart or
Kotlin spells an operation as a camelCase compound, split it at the capital
rather than renaming it.**

| Everyone spells it | Was | Is |
| :--- | :--- | :--- |
| `takeWhile(t)` / `skipWhile(t)` | `until(t)` / `after(t)` | `take.when(t)` / `skip.when(t)` |
| `firstWhere(t)` | `find(t)` | `first.where(t)` |
| `lastWhere(t)` | — | `last.where(t)` |
| `singleWhere(t)` | — | `single.where(t)` |
| `whereType<R>()` | `only<R>()` | `where.type<R>()` |
| `flatMap(f)` | `flat(f)` | `flat.map(f)` |
| `mapNotNull(f)` | `sift(f)` | `map.nonnull(f)` |
| `groupBy(f)` | `group(f)` | `group.by(f)` |
| `countBy(f)` | `tally(f)` | `count.by(f)` |
| `associateBy(f)` | `keyed(f)` | `associate.by(f)` |
| `distinctBy(f)` | `unique(f)` | `unique.by(f)` |
| `maxBy(f)` / `minBy(f)` | `best(f)` / `worst(f)` | `max.by(f)` / `min.by(f)` |
| `sortBy(f)` / `sortedWith(c)` | `sort(f)` / `order(c)` | `sort.by(f)` / `sort.using(c)` |
| `indexWhere(t)` | `index(t)` | `index.where(t)` |
| `forEach(f)` | `each(f)` | `foreach(f)` |

Nothing is invented. Every name on the right is the name on the left with the
capital turned into a dot, which is a rule a reader learns once and then never
looks anything up again. Two words are not available because Dart reserves
them: `while`, so `takeWhile` is `take.when`; and `for`, so `forEach` is
`foreach` rather than `for.each`.

The same rule absorbs the pairs that had to invent a word for their second half:

| Was | Is | |
| :--- | :--- | :--- |
| `head(n)` / `tail(n)` | `take.first(n)` / `take.last(n)` | Dart has no name for the second |
| `skip(n)` / `trim(n)` | `skip.first(n)` / `skip.last(n)` | `trim` also read as `String.trim` |

Six members, four of them invented, became two namespaces of three that read as
opposites — which `head`/`skip` and `tail`/`trim` never did. `take.first(10)` is
eight characters longer than `head(10)`, and nobody has to remember which of the
four dropped from which end, which was the actual complaint.

---

### `Sequence` — the whole mapping

**Shaping — `transform(...)`:**

| Was | Is |
| :--- | :--- |
| `to(f)` | `.map(f)` |
| `sift(f)` | `.map.nonnull(f)` |
| `keep(t)` | `.where(t)` |
| `omit(t)` | `.where((x) => !t(x))` — **deleted**; see below |
| `only<R>()` | `.where.type<R>()` |
| `flat(f)` / `flat<R>()` | `.flat.map(f)` / `.flat<R>()` |
| `unique()` / `unique(f)` | `.unique()` / `.unique.by(f)` |
| `sort()` / `sort(f)` | `.sort()` / `.sort.by(f)` |
| `order(c)` | `.sort.using(c)` — **deleted** as a name |
| `flip` | `.flip()` |
| `head(n)` / `tail(n)` | `.take.first(n)` / `.take.last(n)` |
| `skip(n)` / `trim(n)` | `.skip.first(n)` / `.skip.last(n)` |
| `until(t)` / `after(t)` | `.take.when(t)` / `.skip.when(t)` |
| `pairs` | `.enumerate()` |
| `chunks(n)` | `.chunk(n)` |
| `zip(o)`, `plus`, `minus`, `common`, `or`, `cast<R>()` | the same names |

**Reducing — `collect(...)`:**

| Was | Is |
| :--- | :--- |
| `count()` / `count(t)` | `.count()` / `.count.where(t)` |
| `empty`, `has(v)`, `at(i)`, `any(t)`, `all(t)`, `fold`, `sum`, `avg`, `join`, `set` | the same names, as calls |
| `first` / `last` / `sole` | `.first()` / `.last()` / `.single()` |
| `find(t)` | `.first.where(t)` |
| `index(t)` | `.index.where(t)` — and `.index.of(v)` is new |
| `best(f)` / `worst(f)` | `.max.by(f)` / `.min.by(f)` |
| `group(f)` | `.group.by(f)` |
| `keyed(f)` | `.associate.by(f)` |
| `keyed(f, v)` | `.transform(.map((x) => (f(x), v(x)))).collect(.dict())` |
| `tally(f)` | `.count.by(f)` |
| `split(t)` | `.split(t)` |
| `each(f)` | `.foreach(f)` |
| `list` | `list` — still a member, and still the boundary word |

`list` stays on `Sequence` as well as being a collector, and `map` is the same
word on `Dictionary`. They are what the README promises — *`.list` is the one
word at the boundary* — `list` appears 306 times across the repo, and
`seq.collect(.list())` to hand a `List` to a `dart:io` call would be a tax on
the one operation that exists to pay a tax. `Collector.list()` is there for
where there is no receiver to say it on: a downstream collector.

**Deleted outright:**

- **`omit(t)`.** It stood through 5.0.0 on the grounds that `!keep(t)` reads as
  nonsense, and that was true only because `keep` was not a filter's ordinary
  name. `where((r) => !r.live)` is the other side, so Rule 4's `!` test finally
  applies to a filter.
- **`order(c)`.** Folded into `sort.using(c)`; a comparator is not a different
  operation from a key.
- **`tally(f)` and `keyed(f)`** as names. They are `count.by(f)` and
  `associate.by(f)`, which is what they always were.
- **`extension MapSequenced on Map`**, the `.seq` that existed only to climb
  back out of the raw `Map` grouping handed back. Grouping hands back a
  `Dictionary` now.

---

### `Transformer` and `Collector`

Two value types, each a thin wrapper over one function, each with a family of
`static` factories and a public `run` — which is what makes an operation
testable with no collection in sight:

```dart
Transformer.map<int, String>((n) => '$n').run(const [1, 2]);   // ('1', '2')
```

**A pipeline is a value.** `Transformer.then` joins two transformers, so a chain
can be named once and used twice — the capability the method form cannot offer
at any price:

```dart
final cleanup = Transformer.where<Row>(live)
    .then(Transformer.unique.by(sku))
    .then(Transformer.sort.by(price));

rows.transform(cleanup).transform(.take.first(10));
archive.transform(cleanup).collect(.count());
```

`Transformer.into` gives a transformer an ending, which makes it a `Collector` —
Java's `Collectors.mapping(f, downstream)` generalised to any transformer with
any collector. `Collector.then` is `collectingAndThen`, for a *named* collector
rather than for inline chaining: it changes the result type, which leaves
inference nothing to pin the element type to.

**Downstream collectors** are the one Java idea that changes what you can
express rather than how it reads. `group.into(key, down)` reduces every bucket
in the same pass:

```dart
rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)));
// Dictionary<String, num> — not a dictionary of sequences and then a map over it
```

`group.by(f)` and `group.into(f, down)` are two members rather than one with an
optional argument, because an omitted downstream collector leaves its result
type with nothing to be inferred from and every bucket arrives as `dynamic`.
`count.by(f)` is `group.into(f, .count())` and is defined as it, in one line:
one implementation, two spellings of a call, which is the carve-out Rule 5's
`io.csv.pipe`-beside-`write` note already describes.

**`fn` is the door in a closed set**, the same one `Field.fn` has been in
`util/markup.dart` for three releases:

```dart
rows.transform(.fn((xs) => xs.toList()..shuffle()));
rows.collect(.fn((xs) => xs.fold(0, (t, r) => t + r.qty)));
```

And for an operation with options, one used in six pipelines, or one worth a
test of its own, **subclass**. `Transformer` and `Collector` are plain `class`
with a public generative constructor rather than `final class`, deliberately:

```dart
final class Dearer extends Transformer<Row, Row> {
  Dearer(num floor) : super((rows) => rows.where((r) => r.cost > floor));
}

rows.transform(Dearer(0.05)).transform(.take.first(10));
```

A user-defined transformer composes with the built-ins on equal footing, needs
no registration, and is testable against a plain list.

**Where inference stops.** `Collector.fold` takes its result type from a *value*
and `Collector.then` changes it after the fact, so neither survives a dot
shorthand. One rule covers both, and it is in both class doc comments: **when
the result type comes from anywhere but a lambda's return, name it** — with a
context type or explicit type arguments. `sum`, `avg`, `count` and `join` exist
so the common folds never reach for `fold` at all, which is why Java ships
`summingInt` beside `reducing`.

---

### `Dictionary<K, V>` — the keyed collection

Design Philosophy 6 promised that everything handed back to shape is a
`Sequence`. It held right up to the moment you grouped, and then handed back a
raw `Map` with an extension to climb back in. The absence of a keyed collection
showed up in three places that turned out to be the same place:

1. **`group`, `keyed` and `tally` returned a raw `Map`**, and
   `extension MapSequenced on Map` existed solely to undo that.
2. **`Meta` and `Store` were the same class, written twice.** Nine identical
   members — `get`, `set`, `has`, `delete`, `length`, `isEmpty`, `isNotEmpty`
   and the map underneath — in two files, in two domains. One was what a crawl
   carried on a `Fetch`; the other was what a script kept in a JSON file.
   Neither was about crawling or about files. Both were *a map with typed keys*,
   and the duplication is what happens when the library has no name for that.
3. **`Markup.dataset`, `Cli.switches` and `system.env.map`** hand back raw
   maps for want of anything else to return. They still do: converting them is
   a separate change to three domains that have nothing else in this release,
   and `system.env.map()` would want a new name once it stopped returning a
   `Map`. The type they were missing exists now.

`Dictionary` is the keyed collection, as `Sequence` is the ordered one. It is
not a `Map` for the reason `Sequence` is not an `Iterable`: an extension member
never overrides an instance member, so `get` beside `[]` and `count` beside
`length` would be two spellings of one operation forever.

```dart
spend.get('a.com');      spend.has('a.com');     spend.count;   spend.empty;
spend.set(k, v);         spend.delete(k);        spend.clear();
spend.ensure(k, make);   spend.update(k, change);  spend.merge(other);
spend.keys;              spend.values;           spend.pairs;
spend.invert();          spend.map;              // the boundary word
```

`transform` and `collect` run over `(K, V)` records, so the whole `Transformer`
and `Collector` vocabulary reaches a dictionary without a second set of
factories. `.dict` on a `Map` is the way in, as `.seq` is for an iterable.

**Typed keys go on an extension**, because `Slot` needs `K == String` and
`V == Object?`, which the generic class cannot promise — the same place
`NullableSequence` already lives:

```dart
extension Slotted on Dictionary<String, Object?> {
  T? read<T>(Slot<T> slot);
  void write<T>(Slot<T> slot, T value);
  bool holds(Slot<Object?> slot);
  void drop(Slot<Object?> slot);
}
```

They are `read`/`write` rather than `get`/`set` so they do not collide with the
untyped members on the class — and because that pair says the value is going
through a codec, which is exactly what a `Slot` is.

**`Meta` is deleted** and `Fetch.meta` is a `Dictionary<String, Object?>`.
**`Store`, `StoreAccessor` and `io.store` are deleted** and replaced by
`io.dictionary(path)` and `dump(path)`. Two types and twenty-two members became
one type and one extension, and typed keys started working on every dictionary
in the program rather than only inside the two classes that happened to
implement them.

`Slot.call` gives a `(String, Object?)` record rather than a `MapEntry`, so it
goes straight into a dictionary and comes straight back out of
`Dictionary.pairs`:

```dart
res.follow(href, tag: 'song', meta: [name('Hey Jude'), track(4)]);
res.follow(href, meta: [...res.meta.pairs.list, track(2)]);   // was .entries
final String? title = res.meta.read(name);                    // was .get
```

---

### Persistence: the path is named, not held

```dart
rows.dump('out/rows.json');              // a JSON array
spend.dump('out/by-host.json');          // a JSON object
final db = io.dictionary('out/cache.json');
```

`dump` is an extension declared in `lib/io/collections.dart`, **not** a member of
`Sequence` or `Dictionary`. The direction is the point: Rule 1 says anything
that writes a file is `io`, and Rule 2's second test forbids `collection`
needing `io` back. `io` already depends on `collection` — `io.find` returns a
`Sequence` — so this adds no new edge, and a collection still knows nothing
about the disk, which is what keeps it testable. The package has one export, so
a caller sees `rows.dump(path)` with no extra import at all.

`Store`'s `path`, `open`, `attach`, `load` and `save` do not come across. They
are what made `Store` a file rather than a collection, and they carried a
process-wide mutable singleton (`io.store` was a `StoreAccessor extends Store`)
plus a `load` that swallowed a missing file, unparseable JSON and a non-map
document into the same silent empty — so a half-written snapshot read as a fresh
start and the next save overwrote it.

`io.dictionary` splits those apart. An **absent** file is an empty dictionary,
because a first run has nothing to read. A file that is there and is not a JSON
object **throws `FormatException`**, because that is a broken file rather than a
missing one.

```dart
final db = io.dictionary('cache.json');   // reads, or empty if absent
db.write(cursor, 120);
db.dump('cache.json');                    // writes, atomically
```

The path is named twice instead of held. That is the trade for a collection that
does not secretly own a file, and it is the same trade `format.json.read(path)`
already makes.

---

### Moved — `Sequence` and `Slot` left `util`

`lib/util/sequence.dart` and `lib/util/slot.dart` became:

```
lib/collection/sequence.dart     Sequence, the .seq extensions
lib/collection/dictionary.dart   Dictionary, .dict, the Slotted extension
lib/collection/transformer.dart  Transformer and its namespaces
lib/collection/collector.dart    Collector and its namespaces
lib/collection/slot.dart         Slot
lib/io/collections.dart          the dump extensions
```

`util` was holding two unrelated things: functions you call — `time`, `size`,
`text`, `hash`, `rand` — and types you receive. The collections are the largest
of the second kind, they grew two more types and a dozen namespaces here, and
Rule 3's test for a sub-namespace (*a cohesive vocabulary with its own nouns*)
describes them exactly. Not a sub-namespace of `util`, because nothing in `util`
reaches them; a peer.

**There is no `collection` accessor.** It is a library, not a
`collection.something` you call — the shape `Json` and `Markup` already have,
and for the reason NAMESPACE.md records: *Rule 2 spends no top-level name; you
reach it from the data you already hold.* It also sidesteps
`package:collection`, which every Dart project imports and whose prefix a
top-level `collection` identifier would sit next to uncomfortably.

The types were exported bare before and are exported bare now, so nothing
outside the package changes. `Json`, `Markup` and `Codec` stay in `util`: the
first two are cursors over documents rather than collections, and `Codec` has to
stay where both `net` and `format` can see it.

---

### Also

- **`dart:core` lints.** The SDK bump turned on `use_null_aware_elements`; six
  collection-`if` null checks in `net/cache.dart`, `util/markup.dart` and
  `util/text.dart` became `?x`.
- **Formatting churn.** `dart format` lays out a conditional expression
  differently under a 3.10 language version, so five files that this release
  otherwise does not touch were reflowed.
- **`docs/store.md` is `docs/collection.md`**, and now covers the whole
  vocabulary rather than just the typed keys. `docs/util.md`'s sequence section
  points at it.
- **`example/shape.dart`** is the showcase for the new vocabulary, and
  `test/sequence_test.dart` grew groups for operations-as-values, `Dictionary`
  and `Slotted`.

---

## 5.0.0

The rule set, run against the library instead of against the next thing added
to it.

4.0.0 finished the structural work — the formats live in `format`, `net` parses
nothing, and the seam between them is one interface with one method. The shape
was right. What was wrong was inside it: 122 exported types and about a thousand
public members behind a README that opens by saying the point is to keep the
surface small enough to hold in your head; nine functions that returned a
plausible value that was not the right value; and a documentation harness that
NAMESPACE.md said compiled every snippet in `docs/` and that actually compiled
27 of 244.

Three parts, in the order they landed: the wrong answers, the surface, and the
net that catches both. Then a fourth on speed.

---

### Fixed — nine wrong answers

None of these threw. Each returned something that looked like an answer, which
is why 515 passing tests and a clean `dart analyze` never mentioned them.

**`util.text.fold` folded 14 of 71 letters to the wrong letter.** It mapped
accented Latin letters by index into two parallel string constants. `from` was
72 characters and `to` was 73 — six `c`s for five `ç` variants — so every group
boundary after that shifted by one and the *first* letter of each remaining
group folded to the previous group's letter:

```dart
util.text.fold('Crème Brûlée');   // was 'Crcme Brulee'
util.text.slug('Señor Muñoz');    // was 'seior-muioz'
```

`è`→`c`, `ì`→`e`, `ñ`→`i`, `ò`→`n`, `ù`→`o`, `ý`→`u`, `š`→`n`, `ž`→`s`,
`đ`→`z`, `ł`→`d`, `þ`→`l`, `ð`→`p`, `æ`→`d`, `œ`→`a`. And `ñ` was listed twice,
so the second entry was unreachable; `ß` was missing; `æ` and `œ` lost a letter
because indexing a `String` cannot express a two-character replacement.

The table is a `Map<String, String>` now — a duplicate key is a compile error
rather than a silent dead entry, a replacement may be two letters (`ß` → `ss`,
`æ` → `ae`, `œ` → `oe`, `ĳ` → `ij`, `þ` → `th`), and there is no second thing to
go out of step with. All 71 letters and both cases are named explicitly in
`test/util_test.dart`, because a spot-check cannot catch a shift.

**`util.time.format` emitted malformed strings for a negative duration.**
The sign reached the remainders: `format(-5.s)` was `'00:-5'` and
`format(-3725.s)` was `'-2:-5'`. It formats the magnitude behind a `-` now.
A duration is negative whenever a script subtracted two timestamps in the order
it happened to have them.

**`util.time.parse` read a Unix timestamp as a year.** `DateTime.parse` accepts
a run of digits as ISO 8601 basic format, so `parse('1700000000')` came back as
year 170000 with a zero month and day, rolled back to `169999-11-30`. Eight
digits is the longest a bare date can be; anything longer is `null`.

**`util.size` labelled binary units as decimal ones.** The arithmetic was
1024-based and every label said `KB`, `MB`, `GB`, so a terabyte of disk printed
as `'931.3 GB'` and `parse('5MB')` answered 5,242,880 — five *mebibytes* under a
name that means five million. `format` writes `KiB`/`MiB`/`GiB` now, and `parse`
accepts both families and gives each the scale its name carries:

```dart
util.size.format(5 * 1024 * 1024);   // '5.0 MiB'  (was '5.0 MB')
util.size.parse('2.5 MiB');          // 2621440
util.size.parse('2.5 MB');           // 2500000    (was 2621440)
util.size.parse('10 XB');            // null       (was 0)
util.size.format(-2048);             // '-2.0 KiB' (was '0 B')
util.size.format(1023);              // '1023 B'   (was '1023.0 B')
```

`parse` returns **`int?`**. It used to answer `0` for text that was not a size,
for a unit nobody knows, and for a unit with no number — a value a caller
cannot tell apart from an empty file, and the exact failure Rule 4 names.

**`util.text.number` returned confident wrong answers.**

| Input | Was | Is |
| :--- | :--- | :--- |
| `'(5)'` | `5` | `-5` — an accounting negative |
| `'(1,234.50)'` | `1234.5` | `-1234.5` |
| `'1e3'` | `1` | `1000` |
| `'1,2'` | `12` | `1` — a comma groups only in whole threes |

`(5)` is the one that mattered: a scraped financial table read the wrong way
round. The grouping fix applies to the comma the reasoning the space already
followed, which the comment above `_digits` had spelled out and never acted on.

**The four format writers had four failure modes for one bad input.**
`format.json.format` threw, `format.toml.format` returned `''`, and
`format.yaml.format` returned text that read back *different*. One rule now,
stated once: **reading never throws and gives the empty cursor; writing never
returns text that is wrong or absent.**

- `format.toml.format` throws `ArgumentError` naming what it was handed.
  Returning `''` meant `io.write(path, format.toml.format(rows))` wrote a blank
  file and reported success — a caller can check for a throw and cannot check
  for a file that is silently empty.
- `format.yaml.format` emits anything not spellable bare as a JSON string
  literal. YAML is a superset of JSON, so that is valid YAML and round-trips
  exactly, where the single quotes it used to write could not escape a newline
  at all: `{'multi': 'line1\nline2'}` came back as `'line1 line2'`. A trailing
  space was lost the same way. Both are lossless now.

**`format.zip` was the one read in the library that threw for a missing file.**
`list`, `read` and `unpack` are empty for an archive that is not there, like
`io.find`, `io.csv.rows` and `format.json.read`. And `Format.of` throws
`ArgumentError` for an extension none of the four covers, instead of falling
back to `zip` — `pack('site', 'site.rar')` used to write a zip, name it `.rar`
and report success.

**`:nth-child(n)` matched nothing and `:nth-of-type` threw.** `package:csslib`
evaluates `:first-child` and `:last-child` and then stops, so
`page.find('li:nth-child(2)')` was silently empty — a scraper written against
it collected nothing and reported success — and `:nth-of-type(2)` raised
`UnimplementedError` from the middle of a match, out of a cursor documented to
give the empty result instead.

`nth-child`, `nth-last-child`, `nth-of-type`, `nth-last-of-type`,
`first-of-type`, `last-of-type`, `only-of-type`, `only-child`, `:is` and
`:where` are evaluated here now, with a full `an+b` parser. Anything the
evaluator does not implement — `:hover`, `:target`, `::marker` — is a
`FormatException` naming the part it could not read, which is an `Exception`
about a selector rather than an `Error` from inside a match.

**`cli.usage` wrapped by code units.** A `desc:` holding CJK wrapped at half
the columns it asked for. It goes through `Ansi.width` now, like every other
box this library draws.

#### Checked and found correct

Recorded because "I looked and it was already right" is worth as much to the
next sweep as a bug is. `ConsoleWriter.table` was reported to measure ANSI
escapes as width; it does not — `Table._widest` and `Table._pad` both use
`Ansi.width`, and a table mixing colour, CJK and emoji measures exactly 22
columns on every line. `box` and `rule` likewise. `cli.date` returning
`Opt<DateTime?>` where its six siblings return a non-nullable `Opt<T>` is
deliberate and its doc comment already says so: there is no sensible default
date, and `--since` exists precisely so a script can tell "not given" from "the
beginning of time".

---

### Changed — the surface

Rule 5 says every name appears exactly once, and that *two entry points to the
same behaviour is always a bug in the API, not a convenience*.

#### Deleted: names that were one call's argument

| Was | Is | Because |
| :--- | :--- | :--- |
| `Markup.href` / `.hrefs` | `attr('href')` / `attrs('href')` | the same call with a literal |
| `Markup.src` / `.srcs` | `attr('src')` / `attrs('src')` | the same |
| `Element.href` / `.src` | `element.attributes[...]` | the same, again |
| `Mutex`, `concurrent.mutex()` | `concurrent.semaphore(1)` | a whole exported type for one argument |
| `concurrent.compute` | `Isolate.run` | one line, and the domain's own doc says *bounded async work on **one isolate*** |
| `Sequence.union(o)` | `plus(o).unique()` | |
| `Sequence.findlast(t)` | `flip.find(t)` | |
| `cli.rest` | `cli.args` | see below |
| `cli.subcommand(n, f)` | `if (cli.command == n)` | its own doc listed four things `run` did that it did not |

`href` and `src` are the instructive set: six members for two attribute names,
each of them `attr` with a literal, and they read *better* than `attr('href')`
— which is exactly the argument Rule 5 exists to refuse. They also never
covered anything, since the next attribute a script wants is `data-id`.

`Semaphore` keeps its distinction from `Limiter` — one bounds how many run at
once and the other how often they start — but not its second dialect:
`acquire`/`withPermit` are now `take`/`guard`, spelled like `Limiter`'s. That
also removes the library's one camelCase member, which Rule 4 forbids outright.

`io.delete(dir, pattern:)` is **`io.sweep`**. It and `io.remove` were synonyms,
so neither name said which was the single entity and which was the sweep, and
`io.delete(path)` read like it would remove that one file.

#### `find` and `()` were one search, so they are one spelling

4.0.0's changelog entry is titled *"`find` and the callable are one search"*,
and it kept both names for it. `Markup.call` is gone.

Rule 5 is only half the reason. The other half:

```dart
Markup call([String? selectorOrQuery]) =>
    selectorOrQuery == null
        ? this
        : (_isXPath ? xpath(selectorOrQuery) : find(selectorOrQuery));
```

**Which selector *language* `page('...')` spoke depended on hidden state.** On a
cursor from `format.html.query` it ran the string as XPath; on one from
`format.html.parse` the same call was a CSS selector, and nothing at the call
site said which. `find` and `xpath` each say so in their names.

```dart
page.find('h1').text;        // was page('h1').text
page.xpath('//h1').text;     // was page('//h1').text, on a query cursor
```

`$` and `$xpath` on `Element` and `Document` went with it. They sat on the
**default** surface, contradicting both `lib/html.dart`'s own doc comment and
Rule 5's "the one survivor is an opt-in import", and they were `element.query`
under a second name. The `String` extension stays where the rule put it, now as
methods rather than getters — `markup.$('.track')` is one call, and the opt-in
jQuery spelling no longer leans on a second spelling of `find` sitting on the
default surface.

#### `retries` and `times` were one parameter

```dart
/// [times] is the total number of attempts; [retries] is the number of extra
/// attempts after the first. Pass one or the other.
```

Two parameters for one number, documented as such, in the library whose Rule 5
records the CLI's `def`/`defaultValue` pair going for exactly this. And the
resolution was silent: `retries` was read first, so
`concurrent.retry(fn, times: 5, retries: 1)` ran **two** attempts and ignored
the five. `times` is gone; `retries` means what `Fetcher.retries` means.

#### `Sequence` or `List`, one of them

Design Philosophy 6 says *everything this library hands back for you to shape is
a `Sequence`*. It was **53 public members returning `List`/`Map`/`Set` against
30 returning a `Sequence`** — and `page.find('a').elements` and
`page.find('a').texts` were the same cursor one call apart in two vocabularies.

Converted: `Markup.texts`, `htmls`, `outers`, `attrs`, `values`, `lines`,
`xpathvalues`, `all`; `io.csv.parse`; `concurrent.run`, `Pool.run`,
`Pool.settle`; `format.zip.unpack`; `Robots.group`; `ConsoleReader.picks`. The
count is now 38 to 39, and what is left is `List<int>` byte buffers, `toJson`
maps and the `Map`s `group`/`keyed`/`tally` return on purpose.

**And `Sequence` is a snapshot now, not a lazy view.** It held an `Iterable` and
re-walked the whole chain on every terminal call:

```dart
var n = 0;
final s = [1, 2, 3].seq.keep((x) { n++; return true; });
s.count(); s.list; s.first;
// n == 7 before, and 3 now
```

Three reads, three passes — and a `.to(expensiveParse)` over a crawl's results
paid for the parse once per read, while a sequence built over a
single-subscription source was a `StateError` waiting for its second reader.
Nothing in the vocabulary was lazy on purpose and every source the library hands
you is already a materialised list. `Sequence.empty()` is the `const` for the
empty case.

The trade is stated rather than hidden: `head(10)` after a `to` maps the whole
source rather than stopping at the eleventh element. Where that matters the
answer is a `Stream` — `crawl.stream` rather than `crawl.collect` — which was
already the advice.

`also`, `scan` and `windows` went with the laziness: `also` was a tap that only
made sense while the chain was lazy, and the other two had no caller in the
library, the docs or any example. `Sequence` is 58 members, down from 65 — a
replacement vocabulary larger than the one it replaces has stopped being a
simplification.

#### `cli` said the same thing three ways

`args`, `rest` and `raw` were one list at three offsets, and nothing in `args`
or `rest` said which included the first positional. `rest` is gone, and the
reason is the opposite of what it looks like: **inside a handler `cli.run`
dispatched to, the command names have already been taken off**, so `args` is
already the arguments to that command and `rest` would drop one more. `rest`
existed only to serve `subcommand`; both went together. `command` stays, for a
script that branches by hand.

#### `system.watch` gave `io` its name back

NAMESPACE.md, in *Where past decisions landed*:

> **A filesystem watcher** → `io.observe`, not `io.watch` — `system.watch()`
> already means *watch for Ctrl-C* […] `observe` is free, honest, and **slightly
> less good than `watch`**.

A worse name taken because a better one was occupied by something that had not
earned it. Meanwhile `system.on` was a sub-namespace with **one** member,
`exit`, while the cohesive vocabulary that would justify it sat flat on `system`
beside it: `watch`, `unwatch`, `track`, `untrack`, `adopt`, `disown` — six
members about one thing, which is what happens to your resources when the
program is interrupted. The structure was inverted.

```dart
system.on.signals();   // was system.watch()
system.on.stop();      // was system.unwatch()
system.on.track(file); system.on.untrack(file);
system.on.adopt(proc); system.on.disown(proc);
system.on.exit(cb);    // unchanged

final stop = io.watch('src', rebuild);   // was io.observe
```

#### Two URLs that were `String`

Rule 6 opens with *URLs are `Uri`*. `net.crawl(...)` took a `String`, sitting
one line from `net.crawl.sitemap(Uri)` and one call from `net.http.get(Uri)`;
`Served.redirect` took one too.

```dart
await net.crawl<String>('https://example.com'.url).collect(handler);
return Served.redirect('/done'.url);
```

`net.crawl.html(markup)` and `net.crawl.file(path)` keep their `String`, because
markup is not a URL and neither is a path — and a seed that could be *either* a
URL or raw HTML depending on what it looked like was the untyped overload Rule 6
objects to. `Page.follow` also stays a `String`: it takes a relative reference
out of a document and resolving it is the method's job.

---

### Added — the harness that catches all of it

NAMESPACE.md step 7, since 1.x:

> `test/doc_samples_test.dart` compiles every snippet in `docs/`, so a stale
> example fails the build.

It did not. Its snippet pass filtered to whole programs —
`if (!snippet.contains('void main(')) continue;` — which was **27 of 244**
markdown blocks and **none of the 152** in `///` comments under `lib/`.

`test/docs_test.dart` compiles **385** `dart` blocks: `docs/`, `README.md`,
`NAMESPACE.md`, `example/README.md` and every doc comment in `lib/`. Fragments
are wrapped in a `main` with a shared fixture set in scope as top-level getters,
which a snippet's own `final res = ...` shadows without complaint; a fragment
needing something else declares it in a `// setup:` line; and a block that
genuinely cannot compile — a signature listing, a naming table, a member index —
opts out with ` ```dart no-compile `. There are 17 of those, and that number is
the debt.

**What it found, on the first run.** Documentation still using API removed as
far back as 2.0.0:

| Stale reference | Removed in | Found in |
| :--- | :--- | :--- |
| `tool.json`, `tool.yaml`, `tool.zip` | 4.0.0 | 28 doc comments, 8 files |
| `res.$`, `res.form`, `res.pick`, `res.at` | 4.0.0 | `crawl.dart`, `form.dart`, `pipeline.dart`, `docs/crawl.md`, `docs/http.md` |
| `QueryResult`, `Response.emit` | 4.0.0, 2.0.0 | `util/json.dart`, `net/crawl.dart` |
| `io.async.json` | 3.0.0 | `net/engine.dart` |
| `Failure.request` | 2.0.0 | `net/crawl.dart`, `net/engine.dart` |
| `Page(request:)` | 2.0.0 | `docs/crawl.md` |
| `meta: {'name': ...}`, `res.meta['name']` | 2.0.0 | `net/pipeline.dart` |
| `cli.has`, `cli.get` | 2.0.0 | `cli/cli.dart` |
| `Markup.all(build)` with one argument | never valid | `docs/http.md` |
| `res.links()`, `res.srcs()` | never existed | `docs/http.md` |
| `Fetcher(redirect:, redirects:)` | never existed | `docs/http.md` |

`docs/crawl.md` used `res.form(...)` in the same file whose migration table
records its removal. `dart doc` had been publishing all of it.

---

### Performance

Measured on a 500-row page, a 20,000-row CSV export and 50,000 characters of
accented text.

| | Before | After | |
| :--- | ---: | ---: | ---: |
| `Markup.matching` (2,500 calls) | 390 ms | **4 ms** | 97× |
| `util.text.fold` (50 × 50k chars) | 59 ms | **26 ms** | 2.3× |
| `io.csv.parse` (5 × 20k rows) | 50 ms | **31 ms** | 1.6× |

**`matching`, `not` and `closest` were a document scan per element.** They went
through a match cache keyed on the document root, so testing 500 rows against
`.row` walked to the root and ran `querySelectorAll` over the whole tree 500
times — 156µs a call. A compound selector with no combinator (a tag, classes, an
id, attribute tests) is now parsed once and answered directly off the element.
Anything more — a descendant, a pseudo-class, a selector list — still takes the
general path, and `test/markup_test.dart` pins the two against each other
across 28 selector shapes, because a fast path that disagreed with the slow one
would be a nasty bug.

**`util.text.fold` allocated two objects per character.** A
`String.fromCharCode` and a `toLowerCase()` for every rune of every input. The
table is keyed by code point with the upper-case forms folded in, the walk is
one pass, the runs between replacements are copied in bulk, and a string with
nothing to fold — which is most scraped text, since nothing here is ASCII — is
handed straight back without allocating at all.

**`io.csv.parse` indexed with `text[i]`.** That allocates a one-character
`String` per character, so a 20,000-row export made about a million throwaway
objects. It reads code units and copies runs with `substring` now.

Also fixed while there: **`io.csv.parse` was the one CSV entry point that kept a
UTF-8 BOM**, gluing it to the first header, where `row['name']` answered `null`
for a file that plainly had a `name` column. Excel writes one. The streaming
reader behind `io.csv.rows` had always dropped it; the two agree on all 15
awkward inputs now.

---

### Counting the result

| | 4.0.0 | 5.0.0 |
| :--- | ---: | ---: |
| Exported types | 122 | 121 |
| Public members | ~1,021 | ~1,010 |
| `Sequence` members | 65 | 58 |
| `Markup` members | 57 | 52 |
| Collection returns that are a `Sequence` | 30 of 83 | 39 of 77 |
| Doc snippets compiled | 27 of 396 | **385 of 402** |
| Tests | 515 | 530 |

The type and member counts barely move, and they should not: this was not a
purge. The number that moves by an order of magnitude is the second-to-last row,
and that is the one that stops the others drifting back.

### Not in this release

**`format.csv`.** Unchanged from 4.0.0, and the reasoning holds. `io.csv` still
offers nine ways in and out — `parse`, `format`, `cells`, `maps`, `matrix`,
`rows`, `records`, `write`, `pipe` — across two shapes and three deliveries, on
two independent parser implementations. They now agree on every input tested,
which is the precondition for merging them rather than a substitute for it.

**`format.xml`.** Unchanged: `xpath_selector_xml_parser` could not be resolved,
and the two remaining routes each break something 4.0.0 established. Additive,
so it costs nothing to ship later.

**Splitting the accessor layer.** `Engine` has 40 public members and
`CrawlBuilder` 31, six of them terminal — `run`, `collect`, `gather`, `save`,
`sink`, `stream`. `sink` is `save` pointed at an `IOSink` and is probably one
member too many, but the six are a coherent set of endings and picking them
apart means deciding what a pipeline's result type is.

## 4.0.0

`net` stops knowing what HTML is.

A crawler fetches JSON, sitemaps, archives, feeds and images as readily as it
fetches pages, but `Reply` parsed everything as HTML and carried nine members
to prove it — five about HTML, three about JSON, none about HTTP. That is a
format table living in a class about the network, and it only ever held two
rows.

The formats now live where the library's own rules said they should. `tool`
becomes `format`, HTML joins the family it always belonged to, and the seam
between fetching and reading is one interface with one method.

### Changed — `tool` is `format`

`tool` was chosen when the domain held one archiver, and it invited exactly the
thing its own doc comment spent a paragraph forbidding: three executable
wrappers were added under it in 3.1.0 and removed in 3.2.0. `format.zip` cannot
be misread as a wrapper around the `zip` binary.

```dart
format.yaml.read('config.yaml');     // was tool.yaml.read
format.json.parse(text);             // was tool.json.parse
format.zip.pack('site', 'site.zip'); // was tool.zip.pack
```

Rule 4 says say the call site out loud. `format.yaml.read(...)` says what it
does; `tool.yaml.read(...)` said where it happened to live.

### Added — `Codec<T>`, the seam

One interface, in `util`, because both `net` and `format` need it and Rule 2
forbids either depending on the other:

```dart
abstract interface class Codec<T> {
  T parse(String text);
}
```

Every accessor under `format` already had that method and now declares it. So
`net` gains one member, and it names no format:

```dart
res.parse(format.html).find('h1').text;
res.parse(format.json).at('data.items');
res.parse(format.yaml).text('version');
```

Which is what makes a mixed crawl one expression instead of two APIs:

```dart
final items = switch (res.type) {
  'application/json' => res.parse(format.json).at('items').all(Item.from),
  _                  => res.parse(format.html).find('.item').all(Item.from),
};
```

Results are memoised per codec — the accessors are `const`, so `format.html` is
one canonical instance — which is the old `_doc` and `_json` caching, for every
format instead of two. Nothing throws: a body that is not the format asked for
is the empty cursor, the same as a missing path.

`Codec` also collapses four copies of `read`: it is `io` plus `parse`, written
once as `FileCodec` and mixed into all five. `format.html.read('page.html')` is
new and cost nothing.

### Added — `format.html`

The format codec HTML never had, spelled like its three siblings — `parse`,
`read`, `format` — plus `query` for an XPath cursor and `fragment` for a piece
of a page that should not be wrapped in `<html><body>`.

```dart
final page = format.html.parse(res.body);
final cached = await format.html.read('fixtures/product.html');
io.write('out.html', format.html.format(page.find('.card')));
```

`$` and `$xpath` survive as the jQuery spelling, opt-in from
`package:dart_toolkit/html.dart` (was `selector.dart`). They are off the
default surface, so they are not a second spelling anyone trips over — but
`net.$` and `net.$xpath`, which were on it, are gone.

### Changed — `QueryResult` is `Markup`, and it lives in `util`

A result type named after the operation that produced it, the way
`HttpResponse` was named before 2.0.0. Its sibling is `Json`: a cursor, named
for what it is over. The same split too — the cursor is a pure value in `util`,
the codec is a subject in `format` — and for the same reason: a type `net`
hands back cannot live in a domain `net` must not depend on.

The 800-line jQuery evaluator behind it moved to `lib/src/jquery.dart`, so
`util/markup.dart` reads as the vocabulary rather than the machinery.

`Markup` also gains `extract`, `document` and `form`, which `Reply` used to
own.

### Changed — `find` and the callable are one search

`find` meant strict descendants of the current set while `page(selector)`
searched the whole parsed document. On a page cursor — whose elements are the
body's *children* — `find('h1')` missed an `<h1>` at the top level and `('h1')`
did not. One page, two answers, depending on which spelling you reached for.

They are the same search now. A result is always scoped, so a chained `find`
cannot quietly search the page again:

```dart
page.find('.row').find('.name').texts;   // names inside rows, only
```

`matching(selector)` is still how you ask whether the set *itself* qualifies.

### Changed — finding a form is reading a page

`res.form('#login')` needed `net` to parse, which is the thing this release
removes. Finding a form hangs off the cursor; sending one stays in `net`,
because its output is an `HttpMethod`, a `Uri` and a `Body`.

A cursor cannot know what URL its markup came from, so `Form.at(url)` carries
it — and a form asked to resolve a relative action without one throws saying so
rather than quietly resolving against `localhost`:

```dart
final res = await net.http.get(loginUrl);
await res.parse(format.html).form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send(client: session);
```

Inside a crawl, `res.submit(form)` calls `at` for you.

### Removed — every `Reply` member that named a format

No deprecation shims. Rule 5 settles it: a migration is one edit; two spellings
is forever.

| Was | Is |
| :--- | :--- |
| `res.$('h1')` | `res.parse(format.html)('h1')` |
| `res.$xpath('//h1')` | `res.parse(format.html).xpath('//h1')` |
| `res.doc` | `res.parse(format.html).document` |
| `res.extract({...})` | `res.parse(format.html).extract({...})` |
| `res.pick(field)` | `res.parse(format.html).pick(field)` |
| `res.json` | `res.parse(format.json).raw` |
| `res.decode(fallback)` | `res.parse(format.json).raw ?? fallback` |
| `res.at('data.items')` | `res.parse(format.json).at('data.items')` |
| `res.form('#login')` | `res.parse(format.html).form('#login')!.at(res.url)` |
| `net.$(markup)` | `format.html.parse(markup)` |
| `net.$xpath(markup)` | `format.html.query(markup)` |
| `QueryResult` | `Markup` |
| `tool.*` | `format.*` |
| `package:dart_toolkit/selector.dart` | `package:dart_toolkit/html.dart` |

A handler that reads a page more than once names the cursor, which most already
should:

```dart
final page = res.parse(format.html);
page.find('h1').text;
page.find('a').hrefs;
```

### Pinned

Four assertions in `test/regression_test.dart`, so this cannot rot:

- **No HTML parser under `lib/net/`.** A source scan, and the one-line
  statement of the release. `net/form.dart` still imports `package:html/dom.dart`
  for the element type it is handed — a form is a request the page describes —
  but nothing in `net` turns text into a tree.
- **`Reply` carries no member that names a format.**
- **`parse` memoises per codec**, so one page is parsed once.
- **Every `format` accessor is a `Codec`**, so the next format cannot arrive
  with a differently-spelled entry point.

### Not in this release

**`format.xml`.** It was planned, and it is deferred rather than dropped.
`xpath_selector_xml_parser` — the binding that would let `Markup.xpath` serve
XML with no second implementation — could not be resolved here, and the two
remaining routes each break something this release just established: adding
`package:xml` with a cursor of its own creates the second cursor `Markup` was
named to avoid, and mapping XML onto `Json` gives it a query language that is
not XPath. `Sitemap` keeps its `<loc>` regex until there is somewhere better
for it to go. Being additive, it costs nothing to ship later.

**`format.csv`.** `io.csv` holds two things: `pipe` and the streaming writers,
which are a file API and correctly in `io`, and whole-file parse and format,
which are a codec. Splitting it is right by the same rule that moved HTML, and
it creates a real risk of two spellings for "read a CSV file" — the failure
Rule 5 exists to prevent. It needs its own decision and its own release.

## 3.2.0

The small things a script that can be *left running* needs, and the last of the
namespace debts. `concurrent` learns the limit it was missing — **how often**,
not how many. `io` learns to hold a lock so two copies of a scheduled script do
not fight over one output file. `util.text` learns to produce text as well as
read it. And `tool` becomes what it should always have been: file formats, and
nothing else.

### Added

- **`concurrent.rate(count, per:)` → `Limiter`.** `Semaphore` and `Mutex` bound
  how many run at once; nothing bounded how often they start, and that is the
  limit every public API publishes. `Semaphore(4)` satisfies none of *5000 per
  hour*, *10 per second* or *60 per minute*: four instant requests then four
  more is eight in a second, so the script works until the day the network is
  fast.

  ```dart
  final limit = concurrent.rate(10, per: 1.s);

  await limit.take();                                  // waits for a token
  await limit.guard(() => net.http.get(url));          // the wrapping form

  await concurrent.run(urls, (u) => limit.guard(() => net.http.get(u)),
      size: 8);          // 8 in flight, never more than 10 per second
  ```

  `guard` mirrors `Semaphore.withPermit` and `Mutex.protect`. The bucket
  refills **smoothly**, one token every `per / count`, rather than in a lump per
  window — smooth is what servers measure, and it stops a burst at second zero
  from locking out second one. It starts full, so the first `count` calls do not
  wait, and waiters are served in arrival order. `available`, `waiting` and
  `close()` round it out.

- **`Fetcher(limiter:)`.** Where a rate belongs when it is the server's rather
  than the script's. Every attempt takes a token, retries included, because the
  server counts those too. The dependency points this way on purpose:
  `concurrent` stays ignorant of responses, so there is no `Limiter.absorb`
  reading `Retry-After` and tangling the two domains.

- **`io.lock(path, action, {wait})` and `io.locked(path)`.** Atomic writes made
  the *file* safe; they never stopped the *result* from being whichever process
  finished last. A slow run overlapping the next cron tick, or a human running
  the script by hand while cron does, now blocks.

  ```dart
  await io.lock('.crawl.lock', () async {
    await net.crawl<Row>(seed).save('out.csv');   // exactly one process here
  });
  ```

  Without `wait` a second process throws `LockedError` straight away; with it,
  it queues. The lock is released on a normal return, on a throw, **and on
  Ctrl-C** — it rides the same registry that removes a half-written `.part`
  file, because a lock file that outlives an interrupt is worse than no lock at
  all: the next run refuses to start. The file holds the pid and a timestamp, so
  a stale lock is diagnosable, and one whose process is gone is taken rather
  than obeyed. There is deliberately no age cut-off; "older than an hour is
  stale" breaks the one run that legitimately took ninety minutes.

- **`util.text.render(template, values)`.** The one member of `util.text` that
  *produces* text. `{key}` substitution and nothing else — a missing key renders
  empty, the fourth reader to keep that contract after `Slot.read`, `Field.text`
  and `Json.text`.

  ```dart
  util.text.render('Hello {name}, {count} new', {'name': 'Ada', 'count': 3});
  util.text.render(io.read('template.md'), vars);
  ```

  No conditionals, no loops, no filters, no partials. Each is one step towards a
  template engine, and a script that needs one should have one.

- **`tool.json`.** The third format codec, spelled exactly like `tool.yaml` and
  `tool.toml`: `parse`, `read`, `format`.

### Changed — `tool` holds formats, and only formats

- **`util.json` is `tool.json`.** A *format* is a subject in Rule 1's sense —
  the sentence that admitted `tool.zip` says so outright — and JSON sitting in
  `util` while YAML and TOML sat in `tool` left a reader asking where formats
  live. All three are now one family with one spelling.

  ```dart
  util.json.parse(text)     ->  tool.json.parse(text)
  util.json.format(value)   ->  tool.json.format(value)
  ```

  The `Json` **type** did not move: `net` hands one back from `Reply.at` and
  `Asked.json`, and a type `net` needs cannot live under `tool` without making
  `tool` something `net` depends on — Rule 2's second test. It stays a pure
  value in `util`, beside `Slot` and `Sequence`, and `lib/src/jsontext.dart` is
  the codec both domains sit on, the way `Fs` backs `io`.

- **`io.json(path)` is `tool.json.read(path)`.** One file door per format
  rather than JSON's in `io` and the other two in `tool`. `io.dump` stays where
  it is, because staging a write through a `.part` file is `io`'s job and not
  the format's. `io.async.json` went with it.

  ```dart
  io.json(path)                 ->  await tool.json.read(path)
  io.json<T>(path, Parse.from)  ->  T.from((await tool.json.read(path)).raw)
  ```

- **`tool.git`, `tool.gh` and `tool.docker` are gone.** Wrapping an executable
  is `system.run` plus arguments, and a wrapper only ever carries the handful of
  subcommands somebody thought to add — where `system.run` carries the whole
  binary and already returns a `SysResult` rather than throwing on a non-zero
  exit. `tool.gh` and `tool.docker` shipped in 3.1.0 and are removed in the same
  breath; `tool.git` had been there since 1.5.0.

  ```dart
  await tool.git.branch();
  // ->
  final head = await system.run('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
  if (head.ok) print(head.out.trim());
  ```

  Pair it with `system.which('git')` for "is it installed" — that is the one
  thing the wrappers added over `system.run`, and it was already a member.
  `Container`, `GitAccessor`, `GhAccessor` and `DockerAccessor` are gone with
  them. Rule 1 now reads: an executable is not a subject; the thing it knows is.

### Docs

`docs/json.md` is new. `docs/concurrent.md` gains the limiter, `docs/io.md`
gains locking, `docs/util.md` gains `render`, and `docs/git.md` and
`docs/gh.md` are deleted. `example/shape.dart` is new and `example/parallel.dart`
and `example/files.dart` grew the rate limiter and the lock.

### Fixed

- **`Server.port` after `close()`.** The underlying socket throws once it is
  unbound, so a script logging where it *had* been listening crashed. The port
  and host are now read at bind and kept.

### Deliberately not in this release

The **async `Sequence`** — `seq.pool(8).to(fetch)`, a bounded-concurrency map
that reads like the sync one. It is the one real design question left, it needs
a complete mirror of thirty members to be allowed at all (`io`/`io.async` is the
precedent and `NAMESPACE.md` is explicit that a partial mirror is not), and it
should be decided by counting the `.list`/`.seq` seams in a few real scripts
rather than in advance of them. If they cluster around the slow step, it is
worth its cost; if they scatter, `Sequence` was the wrong boundary and this
would double the wrong thing.

---

## 3.1.0

The errands. Four whole jobs a normal script hands to something outside this
library — three by shelling out, one by importing `dart:io`. Every stage is
additive, and none spends a top-level name.

### Added

- **`net.serve(port, handler)` and `net.once(port, handler)`.** `net` was
  entirely client-side; nothing listened. Three ordinary script jobs need
  something that does — an OAuth callback, a webhook receiver, and a preview of
  what was just scraped — and all three meant `dart:io`'s `HttpServer` and a
  hand-rolled request switch.

  ```dart
  final server = await net.serve(8080, (req) async {
    return switch (req.path) {
      '/callback' => Served.text(req.query['code'] ?? ''),
      '/health' => Served.json({'ok': true}),
      _ => Served.status(404),
    };
  });
  await server.close();
  ```

  The client half reads a URL and returns a `Reply`; the server half takes an
  `Asked` and returns a `Served`. `Asked` carries `path`, `query`, `headers`,
  `method` and the body three ways — `text()`, `bytes()` and `json()`, which
  gives a `Json` cursor. `Served` has `text`, `json`, `bytes`, `file`, `status`
  and `redirect`. `Server` reports its `port` — pass `0` to let the OS pick one
  — and closes.

  `net.once` is the one-shot case, because an OAuth callback is not a server: it
  is a single answer a script waits for, and writing it as a server means
  writing the shutdown too.

  ```dart
  final code = await net.once(8080, (req) => req.query['code'], timeout: 2.m);
  ```

  It serves until the handler returns non-null, replies, waits for that reply to
  actually flush, then closes — closing on the handler's return raced the write
  and the browser saw a refused connection.

  `Served` and `Asked` rather than `Response` and `Request`: 2.0.0 spent those
  names once and renamed out of them. Routing with path parameters, middleware,
  static directories, HTTPS and WebSockets are all deliberately absent — each is
  the first step towards a web framework, and this is a scraping toolkit that
  needs to catch a redirect. No new dependency; `HttpServer` never reaches a
  public signature.

- **`io.observe(path, onchange, {pattern, settle, recursive})`.**
  Rebuild-on-change, re-run-on-save, reload-the-config. Returns the function
  that stops it.

  ```dart
  final stop = io.observe('lib', (changed) => rebuild(changed),
      pattern: RegExp(r'\.dart$'), settle: 200.ms);
  await stop();
  ```

  `settle` is the part everyone hand-rolls wrong: an editor writes a file two or
  three times per save, so the naive version fires three builds. A burst for one
  path coalesces into one call. `FileSystemEntity.watch` recurses on macOS and
  Windows but not on Linux, so a recursive watch there is a subscription per
  directory — including directories created later — and hiding that asymmetry is
  most of why the member exists.

  It is `observe` and not `watch` because `system.watch()` already means *watch
  for Ctrl-C*, with `track`/`untrack` beside it. Two `watch`es meaning two
  unrelated things on two accessors is precisely what Rule 5 is for.

- **`tool.yaml` and `tool.toml`.** Every tool a script coordinates with is
  configured in one of these — `pubspec.yaml` first, then CI, then Docker
  Compose, then Kubernetes; `Cargo.toml` and `pyproject.toml` for the other
  half. `io.store` covered the format this library *writes*; neither covered
  what everything else *reads*.

  ```dart
  final pubspec = await tool.yaml.read('pubspec.yaml');
  pubspec.text('version');
  pubspec.jsonpath(r'$..sdk').sift((n) => n.text());
  ```

  Reading returns the `Json` cursor rather than a type of its own: YAML, TOML
  and JSON decode to the same maps, lists and scalars, so a second cursor would
  be two spellings of one operation. That is the stage's best property. `format`
  writes block-style YAML, quoting any scalar that would read back as a number,
  a boolean or a null.

  Two dependencies: `package:yaml` (maintained by the SDK team — YAML's subset
  boundary is exactly where the bugs live) and `package:toml`. Neither type
  reaches a public signature.

- **`tool.gh` and `tool.docker`.** *Removed again in 3.2.0 — see above.* Rule
  2's fifth test had named both as the reason `git` did not take a top level, so
  the slot was pre-paid; what the release found was that the slot should not have
  existed for an executable at all.

---

## 3.0.0

The standard library a script actually uses. `import 'package:dart_toolkit/dart_toolkit.dart';`
was already the only import a normal script needed for the *edges* — fetching,
parsing, arguments, the terminal, files. It was not true for the *middle*: a
script that crawled a site and wrote a CSV still reached past this library three
times in between, to `dart:convert` for JSON, to `package:collection` for
grouping, and to `dart:core` for the collection API itself.

This closes the middle. It is a major release for one reason: the library's own
signatures flipped to the new sequence type.

### Added — `Sequence<T>`

Everything a script does *between* fetching and writing — grouping rows,
batching them for a pool, deduplicating, summing, taking the best of each group
— was Dart's `Iterable` plus `package:collection`, and the second half of that
is a dependency this library was written to avoid needing. So the middle of
every real script was three loops of nothing:

```dart
final byHost = <String, List<Row>>{};                 // groupBy, by hand
for (final r in rows) (byHost[r.host] ??= []).add(r);

final batches = <List<Row>>[];                        // chunking, by hand
for (var i = 0; i < rows.length; i += 100) {
  batches.add(rows.sublist(i, math.min(i + 100, rows.length)));
}
```

`Sequence<T>` is about 45 members covering Kotlin's hundred. Shaping — `to`,
`sift`, `nonnull`, `keep`, `omit`, `only`, `flat`, `unique`, `sort`, `order`,
`flip`, `head`, `tail`, `skip`, `trim`, `until`, `after`, `chunks`, `windows`,
`zip`, `pairs`, `scan`, `also`, `plus`, `minus`, `union`, `common`, `or`,
`cast` — is lazy. Reducing — `count`, `empty`, `has`, `first`, `last`, `sole`,
`at`, `find`, `findlast`, `index`, `any`, `all`, `fold`, `sum`, `avg`, `best`,
`worst`, `group`, `keyed`, `tally`, `split`, `unzip`, `join`, `each`, `list`,
`set` — is eager.

```dart
rows.group((r) => util.time.day(r.at))
    .seq.to((e) => (day: e.$1, spend: e.$2.sum((r) => r.cost)))
    .sort((e) => e.day)
    .each((e) => log.info('${util.time.stamp(e.day)}  ${e.spend}'));
```

**It deliberately does not implement `Iterable<T>`,** and that is the whole
design. An extension member never overrides an instance member — declare `map`
on `Iterable` and `dart:core`'s wins silently, which is the `HttpClient` bug
again — so an extension could only *add* names beside Dart's, and `keep` next
to `where` forever is what Rule 5 forbids. Replacing a vocabulary means
replacing the static type.

The cost, measured rather than guessed:

| Lost | Replacement |
| :--- | :--- |
| `for (final x in seq)` | `seq.each((x) { ... })` |
| `[...seq]`, `seq.toList()` | `seq.list` |
| passing to a `List<T>` parameter | `seq.list` |
| passing to this library's own APIs | nothing — they take a `Sequence` |

`.seq` on any `Iterable` is the way in, and `Map.seq` gives
`Sequence<(K, V)>` — records, because `MapEntry` is a noun nobody wants.

Four naming laws kept the vocabulary from doubling, and two of them are now
general rules in `NAMESPACE.md`: keep Dart's word where Dart's word is right
(`fold`, `cast`, `join`, `skip`, `zip`, `any`, `all`, `count` are unchanged);
no complement pair where `!` does the job (`empty` with no `notEmpty`, `any`
with no `none`); a nullable return deletes a whole family (five readers, not
ten, and `?? x` instead of `getOrElse`); a record replaces a variant (`pairs`
instead of `withIndex`/`mapIndexed`/`forEachIndexed`).

### Changed — the library returns `Sequence`

The breaking half. Roughly fifteen of the 102 collection-typed positions
flipped: the ones a caller *shapes*.

| Was | Is |
| :--- | :--- |
| `crawl.collect`, `crawl.gather` | `Future<Sequence<T>>` |
| `io.csv.maps`, `io.csv.matrix` | `Future<Sequence<...>>` |
| `io.find`, `io.async.find` | `Sequence<File>` |
| `util.text.words`, `numbers`, `betweens` | `Sequence<...>` |
| `net.sitemap`, `Sitemap.parse`, `Sitemap.load` | `Sequence<Uri>` |
| `Robots.agents`, `CookieJar.cookies` | `Sequence<...>` |
| `util.rand.shuffle`, `util.rand.some` | `Sequence<T>` |
| `tool.zip.list` | `Sequence<Entry>` |

Every `List<int>` stayed: bytes are a buffer, not a sequence. Every parameter
typed `Iterable<T>` stayed, and `Map` returns stayed maps with `.seq` a call
away.

- **`QueryResult` holds a `Sequence` rather than being an `Iterable`.** It
  mixed in `IterableMixin<Element>`, which is how `every` came to mean
  `Iterable.every` here and left Dart's whole collection vocabulary live in the
  selector API. `length` is `count`, `isEmpty` is `empty`, `isNotEmpty` is gone
  (`!empty`), and `elements` is the `Sequence<Element>`. Everything
  markup-shaped — `find`, `at`, `filter`, `children`, `texts`, `all`, `one` — is
  unchanged.

  ```dart
  page.$('tr').length                ->  page.$('tr').count
  page.$('tr').firstOrNull           ->  page.$('tr').elements.first
  for (final e in page.$('tr'))      ->  page.$('tr').elements.each(...)
  ```

`test/regression_test.dart` pins the `Sequence`-is-not-an-`Iterable` property,
because a future `implements Iterable<T>` added for convenience would quietly
undo the whole stage and nothing else would notice.

### Added — `Json`

`Reply.json` was `Object?` and so was `io.json`'s raw form, so every read was a
cast — and a script that got JSON from anywhere but a response had no typed
path at all and called `jsonDecode` directly. `Json` is the cursor the HTML
side already had:

| `QueryResult` (HTML) | `Json` |
| :--- | :--- |
| `q('sel')` | `j.at('a.b')` — dotted path, `[0]` or `.0` for an index |
| `q.text` / `q.texts` | `j.text(key)` / `j.texts()` |
| — | `j.number(key)`, `j.flag(key)` |
| `q.all(sel, build)` | `j.all(build)` |
| `q.one(sel, build)` | `j.one(build)` |
| `q.count`, `q.empty` | `j.count`, `j.empty` |
| `q.xpath(query)` | `j.jsonpath(expr)` |
| — | `j.raw` |

```dart
final items = res.at('data.items').all((item) => (
  sku: item.text('sku'),
  price: item.number('price.amount'),
));                                              // Sequence<({...})>
```

A missing path is empty, not an exception — the same contract `Slot.read` and
`Field.text` keep — and a body that is not JSON at all is the empty cursor too,
so `at` never needs the `try` that `json` does. No `Slot`s here: a slot exists
so a writer and a reader in different places can agree on a key, and reading a
document is one place.

**`jsonpath`** runs a query where `at` walks one path, and returns
`Sequence<Json>` — the JSON side of `QueryResult.xpath`, named after its
language for the same reason. `$`, `.name`, `['a','b']`, `.*`, `..name`, `[0]`,
`[-1]`, `[0,2]`, `[1:4]`, `[::2]`, `[::-1]`, `[?(@.field)]`,
`[?(@.price < 10)]` and `[?(@.name =~ /^wid/)]`. Script expressions and
arithmetic are absent: each is a language rather than a query, and a filter that
needs one is a `keep` on the sequence. An expression it cannot parse selects
nothing.

Three doors produce the same cursor — `Reply.at`, `tool.json.parse` and
`tool.json.read` (`util.json.parse` and `io.json` at the time; see 3.2.0).

### Added — `util.time` learns to read

`stamp`, `iso`, `ago` and `format` all went `DateTime` → `String`; nothing came
back, so a script reading a date out of a CSV column was on `DateTime.parse`
and a `try`.

```dart
util.time.parse('2024-03-09T10:15:00Z');   // ISO first
util.time.parse('20240309_101500');        // what `stamp` writes
util.time.parse('09/03/2024');             // day first, stated rather than guessed
util.time.parse('9 Mar 2024');             // English month names
util.time.span('1h30m');                   // 90.m
util.time.day(row.at);                     // the grouping primitive
```

Both readers are nullable, so a bad cell is a `null` to handle rather than a
`try` to write. `parse` also refuses a date `DateTime.parse` would silently roll
over: `2024-13-01` is `null`, not January 2025.

- **`cli.duration` and `cli.date`.** The sixth and seventh option kinds, read
  through `util.time.span` and `util.time.parse`, so `--timeout 1h30m` and
  `--since 09/03/2024` work and `require` reports a value that is neither.
  `date` reads `null` when nothing was given, because `--since` exists
  precisely so a script can tell *not given* from *the beginning of time*.

- **`int.h` and `int.d`,** the two missing rungs beside `.ms`, `.s` and `.m`.

### Added — the OS facts

Nothing in `io` resolved `~`, nothing reported the platform, and nothing gave
the CPU count — which is the honest default for a pool size and was hardcoded
to 4 in every example.

```dart
io.home;                                 // $HOME, %USERPROFILE% on Windows
io.cwd;
io.expand('~/.config/x');                // ~ at the start, $VAR and ${VAR}
io.abs(path);  io.rel(path, from: dir);
system.os;    // ({String name, int cpus, String host, String user})
```

Each is one line of `package:path` or `Platform`, which is the point: they were
absent, not hard, and their absence is what sent a script back to `dart:io` for
the least interesting reason available. `system.os` is a record rather than five
loose members, per 2.0.0's rule that a struct is a record.

### Removed

No deprecation shims, per Rule 5: a migration is one edit, and two spellings is
forever. Every rename above is analyzer-caught, never silent.

## 2.0.0

The names, and the `Object?`s. Two debts were written down in 1.7.0 and both
are paid here: five exported type names that collided with `dart:io` and
`package:http` — three of them with no diagnostic at all — and the public
signatures that said `Object?` while meaning something specific. A `Map` used
as a struct is now a typed key. A `T ==` switch is now a declaration that
returns its own reader. Four fields where two were always null are now a sealed
type with two cases. Nothing is deprecated, and every change below carries the
before and after.

### Changed — the vocabulary

- **`HttpClient` is `Fetcher`, `HttpResponse` is `Reply`, `Cookie` is
  `Morsel`, `Request<T>` is `Fetch<T>`, `Response<T>` is `Page<T>`.** The first
  three shadowed `dart:io`'s silently — a file importing both got this
  library's and was never told, the way `Process<T>` failed before 1.6.0. The
  other two produced an `ambiguous_import` against `package:http` on use.
  `NAMESPACE.md` recorded all five in 1.7.0 rather than renaming them, and said
  it was owed at 2.0.0. `CookieJar` keeps its name; `Morsel` is what
  `http.cookies` calls the thing a jar holds. The members followed:
  `Page.fetch`, `Failure.fetch`, `Downloader.fetches`.

  The `hide` clause is gone with them:

  ```dart
  import 'dart:io';                                  // HttpClient is dart:io's
  import 'package:dart_toolkit/dart_toolkit.dart';   // Fetcher is this one's
  ```

  `test/regression_test.dart` now pins the opposite of what it used to: that
  the unprefixed names resolve to `dart:io`'s.

- **A standalone fetch cannot `emit`.** `net.http.get` returns a `Reply`, which
  has no `emit`, `follow` or `stop`; only a crawl's `Page<T>` does. The
  `StateError` that said "this response has no engine attached" is a compile
  error for the case that caused it.

### Changed — the `Object?`s

- **`Slot<T>`, and `Meta`.** `Fetch.meta` and `io.store` were the same problem
  twice: a `Map<String, Object?>` that has to stay JSON-encodable but is used
  as a struct. A slot is a typed key — declared `const` once, checked at both
  ends, and the map underneath is untouched, so a resume file and a store on
  disk both still read.

  ```dart
  const name = Slot<String>('name');

  page.follow(href, tag: 'song', meta: [name(a.text)]);
  final String? title = page.meta.get(name);   // no cast, no fallback
  ```

  `Slot.coded` carries a type JSON does not. `Meta.raw` and `Store.all()` stay
  as the plain map underneath.

- **Records instead of `Map<String, Object?>`.** `QueryResult.all` builds one
  typed record per match, scoped to that match; `one` is the singular; `pick`
  reads a `Field` at any depth. Nothing in the result is `Object?`:

  ```dart
  final product = (
    title: page.$('h1').text,
    variants: page.$.all('.variant', (row) => (
      name: row('.name').text,
      sku: row.attr('data-sku'),
    )),
  );
  product.variants.first.sku;   // String?
  ```

  `extract` stays — Rule 6 blesses a shorthand alongside the typed form, and it
  is still the fastest way to look at an unfamiliar page. It is no longer the
  only way to get data out with the type intact.

- **`Field.when` and `Field.map`.** `when` applies a converter only when the
  field found something, which is what a nullable reader and a
  `String`-taking converter actually need; `map` is the unconditional form.
  Between them they delete most calls to `Field.fn`.

  ```dart
  Field.text('.price').when(util.text.number);   // Field<num?>
  ```

  The `Field` hierarchy moved into the selector library, where it reads
  elements rather than responses. `Field.map(schema)` — the static that built a
  nested object — is now `Field.nest(schema)`, and `MapField` is `NestField`.

- **`Opt<T>`: the CLI stops guessing.** `cli.get<T>(name, fallback)` switched on
  `T == int` and `T == double` at runtime and fell through to a cast. A
  declaration now returns the handle that reads it, so the type and the default
  are settled in one place:

  ```dart
  final force = cli.flag('force', alias: 'f');       // Opt<bool>
  final size = cli.number('concurrency', def: 4);    // Opt<int>
  cli.parse(args);

  if (force()) rebuild(concurrency: size());
  ```

  Six declarations — `flag`, `option`, `number`, `decimal`, `list`, `choice` —
  and `choice` reads an enum, so the accepted spellings, the usage block and
  the validation all come from the type. `Opt.given`, `Opt.count` and
  `Opt.negated` replace `cli.has`, `cli.count` and `cli.no`. `cli.list` now
  declares a repeated option, so the positionals moved to `cli.args`.
  `cli.switches` is the parser's own answer for an argument list nobody
  declared. A command handler returns `FutureOr<int>`.

- **`Settled<R>`, sealed.** `Pool.settle` returned
  `({R? value, Object? error, StackTrace? stack, bool isSuccess})` — four
  fields where two were always null and a boolean said which two. It is now
  `Done<R>` and `Broke<R>`, so the branch that has a value is the branch where
  it is not nullable, and the switch is exhaustive. `PoolFailure<I>` became
  `PoolFailure<I, R>` with `List<R?> results` instead of `List<dynamic>`.

- **The three methods that took an `Object` and threw for the wrong shape.**
  `crawl.save(sinkOrPath)` is `save(String path)` and `sink(IOSink)`.
  `io.csv.format`, `write` and `pipe` take records; the cell-shaped twin is
  `io.csv.cells`, which renders text `io.write` puts on disk — mirroring the
  reads, which always split into `maps` and `matrix`. `io.json` gained an
  optional parser, so a document can become a real type instead of a cast that
  throws later.

- **`Engine<dynamic>` is `Engine<T>`** on `Fetch`, `Page` and `Downloader`,
  which all knew `T` already. Three casts came out with it.

- **The jQuery selector engine is private.** `JQuerySelector.select` took an
  `Object? root` and was hidden from the barrel export, but anything under
  `lib/` is importable directly — so `package:dart_toolkit/net/selector.dart`
  still exposed it. It is `_JQuery` now; use `$`, `res.$` or `QueryResult`.

### Added

- **`crawl.gather(map)`**, the single-stage terminal. The item type is inferred
  from what the mapper returns rather than from an `emit` buried in a closure,
  and returning nothing for a page filters it out:

  ```dart
  final titles = await net.crawl<Never>(seed)
      .gather((page) => page.$('.title').texts);
  // Future<List<String>>   (a Sequence since 3.0.0)
  ```

- **`test/typed_api_test.dart`**, which pins each thing that used to be
  untyped against what it is now.

### Note

Declare a CLI interface inside `main`, not in a top-level `final`. A top-level
`final` in Dart is lazy, so a declaration hidden in one does not exist when
`run` builds `--help`. `example/tool.dart` shows the shape.

## 1.7.0

Filling in the form, and ten things that were quietly wrong. `res.$('select').value`
has read a control the way a browser submits it since 1.4.0, and there was
nothing to do with the answer: a login was still a hand-copied CSRF token and
three guesses at the field names. Meanwhile a counter counted nothing, a
cookie went where it should not, a saved crawl truncated last night's results
before it fetched a page, and a stream whose seeds were unreachable waited
forever for a crawl that was never going to start.

### Added

- **`Form`, and `res.form(selector)` to find one.** A page's form comes back
  filled in the way a browser would submit it — the hidden inputs, the CSRF
  token, the ticked boxes, the option already selected — so a script overrides
  the two fields it knows about and sends the rest back untouched. `fill`
  returns the form, so filling and sending are one expression:

  ```dart
  final home = await page.form('#login')!
      .fill({'user': user, 'pass': pass})
      .send(client: session);
  ```

  Values come from the same reader as `QueryResult.value`, so what a form
  submits and what `res.$('select').value` reports cannot drift apart. It
  collects what HTML calls the successful controls and skips what a browser
  skips: a file input, a reset button, anything disabled or unnamed, an
  unticked box, and every submit button but the first. `action` resolves
  against the page, an empty one posting back to it; `method` reads the
  attribute; a `GET` puts its fields in the query and replaces whatever query
  the action had, which is also what a browser does. A form declaring
  `multipart/form-data` throws from `body` rather than sending url-encoded
  fields the server cannot parse.
- **`res.submit(form)`**, beside `res.follow`. Inside a crawl the submission
  is scheduled on the engine instead of fetched on the spot, so the answer
  reaches a tagged handler like any other page. Everything `follow` does still
  applies — the `Referer`, the depth, and de-duplication that reads the body,
  so one search form submitted with two terms is two pages.
- **`docs/form.md`**, and the `<form>` half of `example/scrape.dart`.
- **`io.async.parent`.** Rule 3 says `io.async` mirrors `io` exactly, one name
  for one name; `parent` was the one operation that touches the disk and had
  no twin there.

### Fixed

- **`Stats.retried` counted nothing.** It is documented in `docs/crawl.md`,
  printed by `Stats.toString`, restored from a resume file — and never once
  incremented, because retrying happens inside the client, below the engine
  that reports it. `HttpClient.send` now takes an `onretry` callback and the
  downloader passes each one up. A crawl that retried twice said `retried: 0`.
- **A cookie with no `Domain` followed the crawl into every subdomain.** RFC
  6265 section 5.3 makes such a cookie *host-only*: it goes back to the host
  that set it and to no other. This stored the request host as the cookie's
  domain and then matched by suffix, so a session cookie set by `example.com`
  was sent to `sub.example.com` — the same leak 1.2.0 closed for a `Domain`
  the host does not own, left open on the path where no `Domain` is named at
  all. `Cookie.host` now says which kind it is, and `matches` asks for an
  exact host when it is set.
- **`crawl.save(path)` destroyed the last good results to write the next.** It
  opened the destination directly, which truncated it before the first page
  was fetched and failed outright when the folder did not exist yet — in a
  library whose first promise is that every write is atomic. It now stages
  through a `.part` file like `io.csv.pipe`: the folder is created, the file
  is renamed into place once the run finishes, and a run that fails leaves
  whatever was already there. An `IOSink` is still the caller's own.
- **A crawl whose seeds could not be resolved hung.** `stream()` sent the
  error on and then left the stream open, the subscription live and the resume
  hook registered — so `await for` waited on a crawl that had already failed,
  and the hook held the process open behind it. Both endings now run the same
  cleanup.
- **`concurrent.retry`'s backoff drew from a second generator.**
  `util.rand.seed` documents that every random choice in the library runs
  through one generator, and `net.http`'s retry jitter carries a comment
  saying two would be one too many. The retry helper had a `Random` of its
  own, so seeding a run made the crawl repeatable and the pool not.
- **`['sel@text']` handed back the page's indentation.** 1.5.0 made every text
  read collapse source whitespace the way a browser does, through one reader,
  so `extract` and `res.$` could not disagree. The repeated attribute
  shorthand was the one path that still called `.text.trim()`, so
  `['h1@text']` and `['h1']` answered differently for the same element.
- **`util.size.parse` could not read what `util.size.format` writes.**
  `format` reaches `PB`; the parse table stopped at `TB`, and an unknown unit
  is refused outright — correctly — so `parse(format(n))` answered `0` above a
  petabyte.
- **`HttpResponse.text(requested: ...)` still sat at `localhost`.** A fixture
  that says where it came from now resolves its own links from there, which is
  what a form action or a followed link needs.
- **Four documentation references pointed at nothing**, two of them `dart doc`
  warnings: `[Field.call]` for a method named `fn`, `[net.http]`, `[now]` for
  what became `shutdown`, and `[zip]`/`[git]` for what became `tool.zip` and
  `tool.git` in 1.6.0.

### Known

- **Five exported type names collide, and stay for now.** Running Rule 6's
  mechanical test over all 102 exported types rather than the two that
  happened to error found three more: `HttpClient`, `HttpResponse` and
  `Cookie` are `dart:io`'s names too, and Dart resolves the package import
  first without a diagnostic — the `Process<T>` case again. `Request` and
  `Response` are `package:http`'s, which at least errors on use. All five fail
  the rule; renaming the library's most-used vocabulary is a 2.0.0 change, not
  a point release. `NAMESPACE.md` records them with the escape hatch
  (`import 'dart:io' hide HttpClient, HttpResponse, Cookie;`), and
  `test/regression_test.dart` pins the current behaviour so the rename has
  something to break.

### Migration

Nothing to change. Every name from 1.6.0 still means what it meant; the
additions are new names, and the fixes are behaviour that already claimed to
work this way.

Two of them are behaviour changes worth knowing about. A host-only cookie is
no longer sent to subdomains — if a crawl relied on that, the server was
relying on it too and should set `Domain`. And `crawl.save(path)` no longer
creates the file until the run finishes, so anything watching the destination
mid-crawl sees the previous file rather than a growing one.

## 1.6.0

The namespace, sorted. `system` had become the drawer everything went into when
it was not obviously files or sockets — argument parsing sat beside subprocess
spawning, and `NAMESPACE.md`'s own Rule 1 said it should not have. Meanwhile
`git` and `zip` each held a top-level name, and the next wrapped binary would
have taken a third. Two exported type names collided with the packages any user
of this one imports, and one of those collisions was silent.

Nothing here changes behaviour. Everything here changes where a name lives.

### Changed

- **Argument parsing is `cli`, not `system.cli`.** Rule 1 sorts a domain by
  what it touches, and parsing a `List<String>` touches nothing — no process,
  no environment, no terminal. The axis test would have filed it under `util`,
  beside `slug` and `bytes`, which is just as wrong. It is a *subject*: flags,
  options and subcommands are forty years of Unix convention, not a way of
  reaching the machine. `cli.parse(args)`, `cli.flag('force')`,
  `cli.run(args)`. It still resolves an `env:` fallback through `system.env`
  and still wraps its usage text to the terminal's width; those are
  one-directional, and nothing in `system` needs `cli` back.
- **`git` and `zip` are `tool.git` and `tool.zip`.** Both passed every test for
  a top-level name — whole tool, entangled with nothing, distinctive jargon,
  better flat. So would `docker`, `ssh`, `gh` and `ffmpeg`, and a top level
  that grows a name per wrapped binary is not a top level. Rule 2 gained a
  fifth test for exactly this: a name that arrives with siblings does not take
  the top level, the family does. `tool.docker` now costs nothing.
- **`Digest` is `Algo`.** `package:crypto` exports a `Digest` of its own, so a
  file importing both it and this library did not compile — `ambiguous_import`,
  on a name neither library will give up. The two meant different things
  anyway: crypto's is a hash *result*, this one selects an *algorithm*.
  `io.hash(path, Algo.md5)`. `lib/src/fs.dart` had been writing
  `crypto.Digest` to name the other one for as long as both existed.
- **`Process<T>` is `Handler<T>`.** Dart resolves a package import over a
  `dart:` one *without an error*, so exporting `Process` quietly stopped
  `Process` meaning `dart:io`'s for everyone who imported this library — while
  `system.adopt(Process)`, in the same package, still meant that one. A shadow
  with no diagnostic is worse than a collision with one. The typedef is a
  pipeline's page handler, so `Handler` is also the better name.
- **`system.which`'s parameter is `exe`, not `tool`.** It shadowed the new
  domain, which is the smell Rule 3 warns about. Positional, so no call site
  changes.

### Added

- **`NAMESPACE.md` distinguishes axes from subjects.** An *axis* is a way of
  touching the machine — `io`, `net`, `system`, `concurrent`, `util` — and what
  it touches is what it is about. A *subject* is knowledge that came from
  outside Dart: a command-line convention, an executable, a file format, a
  selector language. Ask which kind you have first, because the two tests
  disagree, and the old single ladder is what produced `system.cli`. A subject
  still has to pass Rule 2; `net.crawl` and `system.console` are the cases that
  do not, and the document now says why each stays where it is.
- **Rule 6 covers type names.** A type is global no matter how deep its
  accessor: `tool.zip.pack` is three levels down and the `Format` it returns is
  still in every user's scope. The rule now carries the mechanical test —
  import the library next to `dart:io` and `package:crypto` and see whether the
  analyzer complains — which is how both renames above were found.
- **A regression test for that.** `test/regression_test.dart` imports
  `package:crypto` unprefixed alongside `dart:io`, so the file compiling at all
  is the collision check. It failed against both names before this release.

### Fixed

- **The test suite no longer commits your staged work.** `git mutating methods
  return SysResult` ran `git commit` in the project directory on the assumption
  that nothing would ever be staged, and asserted that it failed. Run it with
  work staged and the assertion was wrong in the worst possible way: the commit
  succeeded, and the suite had committed it. It now runs against a throwaway
  repository under the system temp directory, which also makes the "nothing to
  commit" failure deterministic rather than dependent on the developer's
  working tree.
- **`README.md` called `tool.git.tag('v1.0.0')` a way to create a tag.** `tag()`
  *reads* the most recent one and takes an optional `cwd`, so the argument bound
  to the working directory and the call silently did something else. Creating a
  tag is `mark`.

### Migration

| 1.5.0 | 1.6.0 |
| :--- | :--- |
| `system.cli.parse(args)` | `cli.parse(args)` |
| `git.branch()` | `tool.git.branch()` |
| `zip.pack(src, dest)` | `tool.zip.pack(src, dest)` |
| `Digest.sha256` | `Algo.sha256` |
| `Process<T>` | `Handler<T>` |

Rule 5 forbids two spellings of one operation, so the old names are gone rather
than deprecated. Each row is a find-and-replace; the analyzer finds every call
site for you.

## 1.5.0

The parts a real script needs and had to hand-roll. Scraped text arrived with
the page's own indentation in it. A crawl counted its failures without saying
which pages they were, so there was nothing to retry or report. Results could
only reach a CSV by way of memory. And a tool could not read what was piped
into it without a loop of its own.

### Added

- **`Failure`, and `on.error` receives it.** It carries the `error`, the
  `stack` and the `request` the failure happened on, so a crawl can keep a
  dead-letter list, log which URLs it lost, or queue those requests again:
  `net.crawl(seed).on.error(lost.add)`. `Stats.failed` counted them; nothing
  said which.
- **`io.csv.pipe(path, stream)`** writes a stream of rows as they arrive,
  holding one row at a time. That is a crawl of any size into a spreadsheet in
  one call, where `write` needed every result collected first. The file appears
  complete or not at all: rows go to a `.part` staging file that is renamed
  once the stream closes and discarded if it fails.
- **`system.console.reader.lines` and `.piped`.** `lines` is what was piped in
  — `cat urls.txt | mytool` — sharing the one stdin subscription with the
  prompts, so a tool can read a pipe and still ask a question. `piped` says
  which mode it is in.
- **`net.crawl(...).on` hands the builder back**, so lifecycle handlers join
  the same expression as the rest of the configuration instead of being the one
  part that has to be written separately.

### Fixed

- **Scraped text reads as text.** A page is indented, so the markup for one
  heading carries newlines and runs of spaces that a browser collapses before
  it draws anything — `res.$('h1').text` came back as
  `'Wireless\n        Keyboard'`, and every call site had to collapse it again
  by hand. `res.$(...).text`, `.texts`, `res.extract` and `res.pick` now read
  through one reader, so they cannot drift apart. Inside a `<pre>` or a
  `<textarea>` the whitespace *is* the content, so there it is kept and only
  trimmed.
- **A crawl whose pages all failed no longer deletes its resume file.**
  `resume` decided there was nothing left to save by looking at the queue,
  which a failed request is not in — throwing away the very list worth
  resuming. It now asks the snapshot, which counts anything unfinished.
- **`$('select').value` and the checkbox reading** landed in 1.4.0; the
  documentation table describing form values, and the removed
  `QueryResult.val()`, are corrected here.

### Changed

- **`on.error` takes one argument, not two.** `(error, stack)` becomes
  `(Failure failure)`, with the request alongside them. A handler that wants
  what it had before reads `failure.error` and `failure.stack`.
- `test/doc_samples_test.dart` analyzes every documentation snippet in one
  pass rather than starting the analyzer once per snippet, which had grown to
  take longer than the test's own timeout.

## 1.4.0

Output you can test. `ConsoleWriter` took injectable sinks, but `Progress`,
`Spinner`, `Terminal` and `Cursor` wrote straight to stdout, so half the
library's output was unreachable from a test and a logger pointed at a file
still drew its spinner on the screen. Everything now goes through one writer.

### Added

- **`ConsoleWriter` decides where output goes and how wide it is**, through
  `tty`, `width` and `height`. `tty` gates everything screen-only — escape
  codes, a repainting bar, a spinner frame — and defaults to whether stdout is
  a terminal for a writer using stdout, and to `false` for one given a sink of
  its own. Pass `tty: true` with a `StringBuffer` to capture exactly what a
  terminal would have received.
- **`Progress`, `Spinner`, `Terminal` and `Cursor` all take a `writer`**, and
  `system.console.*` binds them to `system.console.writer`. A logger's
  `task` spinner now follows the logger rather than always finding stdout.
- **`ConsoleLogger.writer` can be replaced**, so a run logs to a file the same
  way it logs to a screen: `logger.writer = ConsoleWriter(out: sink)`.
- **`ConsoleLogger.format` and `ConsoleLogger.stamp`.** `LogFormat.json`
  writes one JSON object per line — the badge becomes a named `level`, escape
  codes are stripped, `step` carries `step` and `total`, and `error` carries
  `error` and `stack`. `stamp` adds an ISO-8601 prefix, or a `time` field in
  JSON.
- **`Table` takes a `width`** and wraps to fit it, narrowing the widest columns
  first. A cell may hold newlines and renders as several lines of one row.
- **`Ansi.wrap(text, width)`** breaks text to a column count, at spaces where
  it can and inside a word where it cannot, measuring terminal columns rather
  than code units so a wrapped cell of CJK or emoji still fits.
- **`io.csv.rows(path)`** streams raw rows, completing a typed set of four
  readers: `maps` and `matrix` read the whole file, `records` and `rows` yield
  a row at a time.
- **`io.csv.format` and `io.csv.write` take a `newline`**, for the `\r\n` that
  Excel and RFC 4180 expect.
- **`system.cli.count(name)`** reports how many times a switch was given, so
  `-vvv` reads as a level.
- **`flag` takes an `env`**, which only `option` did, so a boolean can be set
  by the shell as well as on the command line.
- **`git.fetch` and `git.checkout`**, matching the shape of `push`, `pull` and
  `clone`.

### Fixed

- **`$('select').value` reads the selected option.** It read the `<select>`'s
  own `value` attribute, which no select has, so every dropdown reported
  `null`. A checkbox or radio now reports its value only when `checked`, where
  it used to report it regardless — an unticked box read as ticked.
- **`.lines` decodes HTML entities.** It strips the tags but left `&amp;`
  sitting in what is documented as text.
- **`zip.unpack` restores permissions and modification times.** An archive of
  shell scripts unpacked with nothing runnable in it, and a restored tree was
  stamped with the moment it was restored. The two container families disagree
  about how the timestamp is stored — a tar counts seconds from the epoch, a
  zip packs a DOS date — so the format decides how it is read.
- **Cancelling a `Pool` stream stops launching work.** A task's body starts a
  turn after it is scheduled, so a cancel landing in between still ran one more
  item. This was the flake in `pool streaming cancelling the stream stops
  launching work`.

### Changed

- **The terminal's size is `system.console.writer.width` and `.height`**, not
  `system.console.terminal.*`. Geometry belongs to the thing that knows where
  the output is going, and to the thing a test can size; `Terminal` keeps the
  control codes — `clear`, `line`, `bell`.
- **`io.csv.read` and `io.csv.stream` are gone**, along with the deprecated
  `io.csv.table`. All three returned `dynamic` or duplicated a typed method
  that already existed, against Rule 6 of `NAMESPACE.md`. `read(path)` becomes
  `maps(path)`, `read(path, headers: false)` becomes `matrix(path)`,
  `stream(path, headers: true)` becomes `records(path)`, `stream(path)` becomes
  `rows(path)`, and `table(...)` becomes `format(...)`.
- **`io.csv.records` is no longer deprecated.** It pointed at
  `stream(path, headers: true)`, which was the untyped spelling of it.

## 1.3.0

Fetch less, parse less. A re-run over pages that have not changed used to cost
exactly as much as the first run, and anything a server sent — a PDF, a video,
half a gigabyte of it — was handed to the HTML parser like any other page.

### Added

- **`HttpClient(cache: HttpCache(dir))` and `net.crawl(...).cache(dir)` keep
  responses between runs.** A second run revalidates with `If-None-Match` and
  `If-Modified-Since`, so a `304` serves the stored body without one byte of it
  crossing the wire; a response still inside its `max-age` or `Expires` is not
  even asked about. Only `GET` responses with status 200 are stored, and only
  when the server did not say `no-store`. `HttpCache` is usable on its own —
  `read`, `write`, `remove`, `clear` — and a `CacheEntry` reports `fresh`,
  `lifetime` and the `validators` it would revalidate with.
- **`HttpResponse.cached`** says a response was served from the cache rather
  than downloaded, so a handler can return early on the pages that did not
  move.
- **`net.crawl(...).accept(types)`** sends the types as the `Accept` header and
  drops a response that arrives as something else anyway before a handler sees
  it, counting it in `Stats.skipped`. Entries take a `/*` wildcard on the
  subtype.
- **`net.crawl(...).cap(bytes)`** reaches the client's existing body limit from
  the builder, so a crawl can refuse a body too large to hold rather than
  discovering it in memory.
- **`Response.follow` takes a `method` and a `body`.** A form is now followed
  the way a link is, instead of reaching past the response for `engine.add`.
  De-duplication reads the body, so two posts to one URL with different fields
  are two requests.
- **`MapDownloader` matches a method-prefixed key** — `'POST /login'` before
  `'/login'` — so one URL can answer differently to a `GET` and a `POST`, and
  records every request it served in `requests`. A POST pipeline can now be
  fixtured and asserted on.
- **`util.rand.seed([seed])`** fixes the generator behind every random choice
  the library makes, which is what a test of a crawl's order or a retry's
  timing needs. Calling it with nothing restores an unseeded generator.

### Fixed

- **A `robots.txt` that answers 5xx disallows the host** (RFC 9309 section
  2.3.1.4). Rules that could not be read are not the same as rules that are not
  there, and the crawler was reading both as permission. A 4xx still allows
  everything, per 2.3.1.3. A transport error is treated as the 4xx case — a
  deliberate departure, since stopping a whole crawl over one failed DNS lookup
  costs more than it protects.

### Changed

- **`HttpClient`'s retry jitter runs through `util.rand.jitter`** instead of a
  private `Random` of its own. Two generators doing one job left half the
  library's randomness outside the reach of `util.rand.seed`.

## 1.2.0

A crawl you can interrupt. The frontier — the queue of pages a run has found
but not yet fetched — used to live only in memory, so a crawl stopped at hour
three restarted from the seed. It now serializes, alongside the visited set and
the counters, and a run picks up where the last one stopped.

Shipped on top of an audit of the library against its own documentation.

### Added

- **`net.crawl(...).resume(path)` saves a crawl's position and carries on from
  it.** An existing file restores the frontier, the visited set and the
  counters, so seeds already visited are not fetched twice and `limit` still
  counts the whole crawl rather than this leg of it. The file is rewritten on a
  timer (`every`, five seconds by default), once more when the run stops, and
  once more again if the process is interrupted. A crawl that drains on its own
  deletes it, having nothing left to resume.
- **`Engine.snapshot()` and `Engine.restore(snapshot)`**, the pair `resume` is
  built from, so a position can be kept anywhere a `Map` can go — `io.store`, a
  database row, a key-value service. `Snapshot` carries the pending requests,
  the `Deduplicator` and the `Stats`, and round-trips through
  `toJson`/`fromJson` with a `version` it refuses to read from the future.
- **`Request`, `Body` and `Stats` serialize.** Everything scheduling and
  routing depend on survives the trip: the method, headers, body, priority,
  tag, depth and `meta`. A `Body.bytes` body is base64-encoded, so a body that
  is not valid UTF-8 comes back intact.
- **`SIGTERM` is watched alongside `SIGINT`.** `kill`, a supervisor and a
  container runtime all send the former, which the watcher ignored — so a
  terminated run left its `.part` files on disk and its exit hooks unrun. The
  exit code follows the shell convention of 128 plus the signal number, so a
  caller can tell a Ctrl-C (130) from a `kill` (143).

An audit of the library against its own documentation. Every item below was
reproduced first and now has a regression test in `test/regression_test.dart`.

### Security

- **A `Set-Cookie` header can no longer widen a cookie to a domain the
  responding host does not belong to.** The `Domain` attribute was stored
  verbatim, so a response from `evil.example.com` could set `Domain=com` and
  have that cookie sent to every other `.com` host the client later visited.
  A domain is now honoured only when the request host equals it or sits under
  it at a label boundary, and a bare TLD is refused outright; anything else
  falls back to a host-only cookie (RFC 6265 section 5.3.6).

### Fixed

- **`system.cli.get<bool>` reads the `env` variable an option declares.** The
  environment value arrives as text and was type-tested against `bool`, so it
  could never satisfy a boolean option, and `def` was consulted ahead of `env`
  against the documented order. Both now match every other type: the command
  line, then `env`, then `def`, then the call site's fallback.
- **`require` no longer accepts a valueless switch for an option.** `--out`
  with nothing after it parses as a bare switch, which satisfied
  `required: true` while `get` still handed back the call site's fallback. A
  flag is still satisfied by its presence alone.
- **A `robots.txt` group holding only `Crawl-delay` no longer absorbs the
  rules of the group after it.** Group boundaries were inferred from whether
  any rule had been collected, so a `User-agent` with just a crawl delay stayed
  open and inherited the next agent's `Disallow` lines.
- **`Sitemap.load` cannot recurse forever.** A sitemap index pointing at itself,
  or at another index pointing back, looped indefinitely. Fetched URLs are now
  remembered and the descent stops at `Sitemap.maxDepth`.
- **`coerce` no longer turns a URL into a `data:` document** because its query
  carried `</` or `/>`; recognised schemes are tested before markup is sniffed.
- **A `file:` URI for a path that is not there reports 404.** It fell through to
  the generic branch and returned status 200 with the URI string as the body.
- **A crawl's `.base()` is honoured for HTTP downloads.** `Downloader.save`
  delegated the destination to the client, which resolves against its own base
  — usually the shared `net.http` client, which has none — so `.base('out')`
  silently wrote to the working directory. The other schemes already resolved.
- **`HttpClient.send` no longer spends its retry budget on settled failures.**
  A body over `cap` and a redirect chain past its limit were caught by the
  generic retry handler and re-downloaded; both now raise
  `FatalHttpException`, which is rethrown immediately.
- **The per-request `timeout` covers the response body.** It wrapped only the
  request, so a server dribbling bytes could hold a worker open indefinitely.
- **`find` searches descendants for jQuery selectors as it always did for
  plain CSS.** An extended selector also matched the context element itself, so
  `find('div')` and `find('div:contains(x)')` disagreed on the same fragment.
  Use `matching` to ask whether the set itself qualifies, or the callable
  shorthand to search the whole parsed document; a document root can still
  match itself, as `querySelectorAll` does.
- **`system.untrack` releases the file it names.** Tracked files were held in a
  `Set<File>` and `dart:io`'s `File` has no value equality, so untracking
  through a different instance left the entry — and a stuck entry keeps the
  `SIGINT` watcher, and so the process, alive.
- **A timed-out subprocess is followed to `SIGKILL`.** `system.run` sent
  `SIGTERM`, reported `-1` and disowned the process, leaving a child that traps
  the signal orphaned. Its stdin is also closed now, so a child that reads
  input cannot block a captured run forever.
- **Atomic writes no longer unlink the destination first.** POSIX `rename`
  replaces atomically; deleting first opened a window in which a reader saw no
  file at all. The unlink now happens only on Windows, where it is required.
- **`Fs.download` closes its sink when a transfer fails**, instead of leaking
  the descriptor and blocking the cleanup unlink on Windows.
- **`io.hash` streams the file**, as `util.hash`'s documentation always claimed;
  both variants read the whole thing into memory.
- **`io.csv.format` keeps columns that only later rows carry.** Columns came
  from the first row's keys alone, so a field absent from it was dropped with
  no error. Columns are now the union of every row's keys, first-seen order.
- **`io.csv` honours a multi-character delimiter**, in `parse` and in the
  streaming reader, including one straddling a chunk boundary. It was compared
  a character at a time, so anything longer never matched.
- **A blank line no longer yields an empty CSV row**, so a trailing newline
  does not add one.
- **`io.store` survives a malformed file.** `load` threw `FormatException`
  from the constructor, so one interrupted write made every later run fail.
  A missing, empty, unreadable, malformed or non-object document leaves the
  store untouched.
- **`Ansi.width` counts terminal columns.** It counted UTF-16 code units, so a
  CJK ideograph measured 1 against the 2 it renders and every table, box and
  rule built from wide text came out crooked. Combining marks now measure zero.
- **`Table` renders with a partial `alignments` list** instead of throwing
  `RangeError`; it is padded to the column count with `ColumnAlign.left`.
- **`util.text.number` stops merging separate numbers.** A space counted as
  digit grouping unconditionally, so `'12 34'` read as `1234` and
  `numbers('1 2 3')` as `[123]`. A space now groups only when it separates
  whole groups of three, leaving `'1 234 567'` a single number.
- **`util.text.slug` keeps letters of other scripts.** Everything outside
  `a-z0-9` collapsed, so a CJK or Cyrillic title produced an empty slug — and
  an empty filename with it.
- **`util.text.clip` never splits a character in half**, which turned a clipped
  emoji into a replacement character.
- **`util.size.format` picks the unit after rounding**, so 1048575 bytes is
  `1.0 MB` rather than `1024.0 KB`.
- **`util.size.parse` returns 0 for a unit it does not know**, as documented,
  instead of reading `'10 XB'` as ten bytes.
- **`util.rand.jitter` is never shorter than its base**, as documented; a
  negative spread is treated as zero. **`between`** handles spans wider than
  `Random.nextInt`'s 32-bit bound instead of throwing `RangeError`.
- **`Semaphore.release` no longer raises the permit ceiling.** A release that
  paired with no acquire pushed the count above the maximum, removing the bound
  the semaphore exists to enforce.
- **`PoolFailure.toString` describes an empty failure list** instead of
  throwing `StateError`.
- **`reader.pick`, `picks` and `ask` give up at end of input.** Each re-prompted
  forever once stdin closed — an unattended run spun writing prompts nothing
  could answer — and now throw `StateError` explaining how to supply the value.
  **`reader.close`** completes any prompt still waiting rather than leaving its
  future pending, and **`secret`** works off a terminal, where reading
  `echoMode` threw before the guard could restore it.
- **`logger.task` honours `level`**, so a `LogLevel.none` logger no longer
  prints a spinner. **`Progress.done`, `Progress.fail` and `Spinner.stop`** no
  longer write a stray newline or carriage return when stdout is not a
  terminal, as "piped output stays clean" promised.
- **`git` query methods fail softly when `git` is not installed.**
  `ProcessException` escaped, against the documented contract; the result now
  carries `GitAccessor.missingExit`. **`branch`** reports `''` for a detached
  `HEAD` rather than the literal `HEAD`.
- **`zip.pack` no longer follows symlinks**, which pulled in files from outside
  the tree and could walk in circles, and **`unpack` skips link entries**
  rather than recreating them as directories.
- **The robots, host-throttle and selector caches evict least-recently-used
  entries**, as their comments claimed; all three dropped the oldest insertion,
  so a host or selector in constant use could be evicted ahead of one seen once.

### Changed

- **`Progress`'s default glyphs match `system.console.progress`** (`█` and `░`);
  the two entry points disagreed.
- **`Cli.get<bool>` accepts the same words as `system.env.get`** — `true`, `1`,
  `yes`, `on` — for values reached through `env` or `def`.
- **A request counts as crawled when its handler has run, not when its worker
  settles.** A response that arrived after the run stopped, or one whose
  handler threw, is unfinished work: it stays pending in a snapshot so a
  resumed crawl fetches the page again rather than losing it. `Engine.skip`
  now takes the request it dropped, as an optional argument, for the same
  reason. `Engine.leave` is unchanged.
- Documentation corrected where the code was right and the prose was not:
  `io.async` mirrors every disk operation rather than literally every name on
  `io`; `Cookie.parse` points at `CookieJar.add` instead of a private method;
  `Engine`'s truncated doc comment no longer sits on the frontier queue; and
  `zip.deflate` says plainly that it produces a gzip stream. `docs/crawl.md`
  finishes a crawl with `save`, the name `to` was given in 1.1.0.

## 1.1.0

Expands `system.cli` from an argument parser into a full command-line
front end: commands with their own arguments, defaults and environment
fallbacks that are declared once, and validation that catches typos.

### Added

- **`system.cli.handle`** registers a command and returns it, so the arguments
  only that command uses are declared on the spot. **`system.cli.group`** nests
  commands, so `remote add` resolves through a tree.
- **`system.cli.run`** parses, resolves the deepest matching command, re-reads
  the arguments against that command's declarations plus the global ones,
  prints `--help` or `--version`, applies validation, awaits the handler and
  turns what it returns into an exit code: `null` and `true` mean success,
  `false` means failure, an `int` is used as given, and a command line it could
  not understand yields `Cli.usageExit` (`64`) after printing the reason. `--help`,
  `-h` and `--version` are declared for you. `body:` runs when no command
  matches, so a script with no commands at all still gets automatic help and
  validation. Only `ArgumentError` is caught, leaving a genuine failure inside
  a handler its stack trace.
- **`system.cli.strict`** throws on any switch no declaration covers, and
  **`unknown`** returns them, so `--verbse` no longer parses silently as a flag
  nothing reads. `run` applies it with `strict: true`.
- **`option`** gained `allowed:` to limit accepted values, `env:` to name an
  environment variable to fall back on, and `csv:` to split one
  comma-separated value into repeats for `all`.
- **`Cli.usageExit`**, the conventional `EX_USAGE` exit code.
- **`Cli.parsed`** on the accessor, for handing the parsed command line to code
  that takes a `Cli`.

### Changed

- **`get` now resolves the declaration.** Sources are tried in order: the
  command line, the `env` variable, the declared `def`, then the fallback at
  the call site. A default is written once in the declaration instead of at
  every call site.
- **`require` accepts a default or a set environment variable as supplied,** as
  documented, and also checks every given value against its `allowed` list. Its
  message now names each failure rather than only the missing names.
- **Usage blocks wrap to the terminal width**, size the label column to its
  contents, and list commands alongside `allowed` values and `env` fallbacks.
  `(required)` is printed only when nothing else can supply a value.
- **`flag`'s `def` is now `bool?`**, so an unset default falls through to the
  call site rather than forcing `false`.

### Fixed

- **`-abc` now clusters into the short flags `a`, `b` and `c`**, as the
  documentation always claimed; it previously parsed as one flag named `abc`. A
  clustered switch declared with a value ends the cluster and takes the rest of
  it or the next argument, so `-o dist`, `-odist` and `-vodist` all set `o`.
  Only all-letter tokens cluster, and a declared multi-letter short name is
  never split.
- **Declarations registered before `system.cli.parse` are honoured by the
  parse itself.** They were dropped, so a declared flag still swallowed the
  token after it: `tool build --verbose main.dart` lost `main.dart`.
- **`require` no longer throws for an option that declares a default.**

## 1.0.0

First release. A lightweight web-crawling pipeline and command-line automation
toolkit for Dart, organised into seven domain namespaces with lowercase,
preferably one-word methods. [NAMESPACE.md](NAMESPACE.md) records the rules
that decide where a name goes and what it is called.

### `net` — requests, crawling, selectors

- **`net.http`**, a retrying client over `package:http`. Retries transport
  errors, 5xx and 429, honouring `Retry-After` in either delta-seconds or
  HTTP-date form and falling back to jittered backoff when it is unparseable.
  Redirects are followed with correct method rewriting; `cap` refuses
  oversized bodies so one unexpected URL cannot exhaust memory.
- **Sessions.** `HttpClient(session: true)` or your own `CookieJar`, following
  RFC 6265: several `Set-Cookie` headers on one response are all stored (the
  comma-joined form `package:http` produces is split correctly, including
  around the comma inside an `Expires` date), `Max-Age` takes precedence over
  `Expires`, an expired cookie deletes the entry it names, the default path is
  the directory of the request, and cookies are sent longest-path-first.
- **`net.crawl`**, a declarative crawler. Stages are handlers dispatched by
  `route` (the URL) or `tag` (whatever queued the request), with `meta`
  carrying context between them. Scope comes from `depth`, `limit`, `samehost`,
  `allow`/`deny` and `robots`; pacing from `delay` and `perhost`. Finish with
  `run`, `collect`, `stream` or `save` — the last streams to disk, so a long
  crawl never holds its results in memory.
- **`robots.txt` per RFC 9309.** Product-token matching, so a `User-agent:
  MyBot` group governs a crawler calling itself `MyBot/1.0`; `Crawl-delay` is
  obeyed as a per-host floor; the pending fetch is cached, so workers arriving
  at a new host together share one request.
- **Selectors.** `res.$('...')` is a chainable jQuery-like set with the CSS
  extensions (`:contains`, `:has`, `:eq`, `:first`, `[attr!=value]`, …) and
  full traversal; `res.$xpath('...')` for what CSS cannot say. Single-element
  matching is memoised per (root, selector), which keeps `closest`, `not` and
  the child combinators linear instead of quadratic, and each distinct selector
  string is parsed once rather than on every call.
- **Extraction, loose or typed.** `res.extract({...})` takes a string schema
  (`'h1'`, `'a@href'`, `['li']`, `['.row', {...}]`); `res.pick(Field.text('h1'))`
  keeps the type. They mix freely in one schema.
- **Testability.** Swap `.downloader(MapDownloader({...}))` and the rest of the
  pipeline is unchanged, so a crawl can be tested without the network.

### `io` — the filesystem

- Every write is atomic: it stages into a `.part` sibling and is renamed into
  place only after a successful flush, with the staging file removed on Ctrl-C.
- **`io.*` blocks; `io.async.*` is the same names as futures.** One isolate runs
  every task in a crawl, so a blocking read stalls everything in flight — reach
  for `io.async` inside handlers and pool workers.
- **`io.csv`** parses, formats, reads and streams tables, as rows or as maps.
- **`io.store`** is a JSON-backed key-value map for the state scripts keep
  between runs: cursors, tokens, "last seen" markers.

### `system` — this program and the machine

- **`system.cli`** parses `--flag`, `--key=value`, `--key value`, `-k value`,
  `--no-key`, repeated options and trailing positionals. Declare the interface
  once and `--help` writes itself; a declared alias is honoured by every later
  lookup.
- **`system.console`** covers status logging, tables, boxes, rules, progress
  bars, spinners, ANSI colour with terminal detection, and prompts.
- **`system.env`** reads the environment and `.env` files, typed through a
  required fallback.
- **Crash-safe shutdown.** `system.on.exit` registers a hook; `system.shutdown`
  kills adopted children, deletes tracked partials, runs the hooks and exits.

### `concurrent` — bounded async work

- `concurrent.run` maps over items with at most `size` in flight, results in
  input order; `stream` yields them in completion order, honouring pause and
  cancel; `Pool.settle` runs everything to completion and reports per-item
  outcomes.
- `concurrent.retry` with linear backoff, a cap and jitter; `Semaphore` and
  `Mutex`; `concurrent.compute` for a separate isolate.

### `git` and `zip`

- **`git`** wraps the executable: `branch`, `hash`, `dirty`, `status`, `tag`,
  `add`, `commit`, `push`, `pull`, `clone`.
- **`zip`** packs and unpacks `.zip`, `.tar`, `.tar.gz`, `.tgz` and `.tar.bz2`,
  choosing the format from the file name. `list` and `read` look inside without
  unpacking, `bundle` builds an archive from data that never touched the disk,
  and entries that would escape the destination — the "zip slip" attack — are
  skipped rather than trusted.

### `util` — pure helpers

Nothing here touches the disk or the operating system; that is the rule that
keeps it small.

- **`util.text`**: `slug`, `clean`, `strip`, `clip`, `fold`, `title`, `words`,
  `number`/`numbers` (which read `$1,234.50`), and `between`/`betweens` for
  reaching a value no selector can.
- **`util.hash`**: `sha`, `md5`, `short` (a cache key), `sign` (HMAC-SHA256),
  base64 `encode`/`decode`.
- **`util.rand`**: `pick`, `some`, `shuffle`, `between`, `id`, `jitter`,
  `chance`.
- **`util.time`** and **`util.size`**: delays, stopwatches, timestamps,
  relative descriptions, and human-readable byte sizes.

### Throughout

- **Real types at every boundary.** URLs are `Uri`, delays are `Duration`,
  paths are `String`; bodies, digests, extraction fields and archive formats
  are sealed types and enums, so a wrong call fails in the analyzer.
- **Every name appears exactly once.** No aliases and no flat shortcuts — each
  operation is reachable one way.
- **176 tests**, and every code sample in `docs/` is compiled by the suite, so
  a stale example fails the build.
