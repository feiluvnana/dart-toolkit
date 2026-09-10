# Web Crawler (`net.crawl`)

A declarative multi-stage crawler. You describe how to handle each kind of page; the engine schedules, de-duplicates, fetches and routes.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final titles = await net.crawl<String>('https://news.ycombinator.com'.url)
      .concurrent(4)
      .delay(250.ms)
      .limit(50)
      .collect((res) {
        for (final title in res.parse(format.html).find('.titleline > a').texts.list) {
          res.emit(title);
        }
        for (final next in res.parse(format.html).find('a.morelink').attrs('href').list) {
          res.follow(next);
        }
      });

  system.console.logger.ok('Collected ${titles.count()} titles.');
}
```

`T` in `net.crawl<T>` is the type of item your handlers emit.

---

## 1. Seeding

| Entry point | Seeds |
| :--- | :--- |
| `net.crawl<T>(String target)` | One URL, raw HTML markup, or custom task string |
| `net.crawl.all<T>(Iterable<String> targets)` | Several URLs, raw HTML markups, or task strings |
| `net.crawl.html<T>(String markup)` | Explicit raw HTML markup |
| `net.crawl.file<T>(String path)` | Explicit local file path |
| `net.crawl.sitemap<T>(Uri sitemapUrl)` | Seeds discovered by parsing XML/text sitemap |
| `net.crawl.seed<T>(requests)` | Fully-formed `Fetch` objects |

> Seeds and `res.follow(String url)` accept plain **`String`** inputs — they do not need to be `Uri` objects. You can pass raw HTML markup (`'<article>...</article>'`), local file paths, or custom task identifiers directly.

Use `seed` when the starting pages need their own headers, tag, priority, depth, or HTTP method:

```dart no-compile
await net.crawl.seed<String>([
  Fetch('https://example.com/a', tag: 'listing', priority: 10),
  Fetch('https://example.com/b', headers: {'Cookie': 'session=abc'}),
]).run((res) { ... });
```

---

## 2. Configuration

Every setter returns the builder, so configuration reads as one expression. **Nothing runs until you finish it.**

```dart
net.crawl<String>(url)
    .concurrent(8)                       // max simultaneous fetches
    .delay(500.ms, perhost: true)        // pause after each fetch (optionally per-host)
    .perhost(true)                       // enforce delay per host independently
    .retry(3)                            // retries per failed fetch
    .base('downloads')                   // base dir for relative save paths
    .dedupe(false)                       // allow revisiting URLs (default: on)
    .deduplicator(restored)              // supply a pre-seeded visited set
    .downloader(mock)                    // swap the transport (e.g. MapDownloader)
    .limit(100)                          // stop after crawling at most 100 pages
    .depth(3)                            // maximum link traversal depth
    .allow(RegExp(r'/blog/'))            // only crawl URLs matching pattern
    .deny(RegExp(r'\.pdf$'))             // skip URLs matching pattern
    .samehost(true)                      // restrict crawl to the seed's host
    .robots(true, 'MyBot')               // obey robots.txt rules before requests
    .sitemap('https://example.com/sitemap.xml'.url) // seed with all sitemap URLs
    .headers({'User-Agent': 'CustomBot'}) // custom headers for every request
    .timeout(10.s)                       // per-request timeout
    .resume('crawl.state')               // save the position, and carry on from it
    .accept(['text/html'])               // only handle these content types
    .cap(util.size.parse('5MiB')!)         // refuse a body larger than this
    .cache('.cache')                     // reuse unchanged pages between runs
    .run(handler);
```

### Crawl Scope & Politeness

- **`limit(n)`**: Caps the total number of pages fetched. Workers exit once the limit is reached.
- **`depth(depth)`**: Restricts recursion depth. Seeds have depth 0; links discovered via `res.follow` have `request.depth + 1`.
- **`allow(pattern)`** and **`deny(pattern)`**: Filter URLs before scheduling.
- **`samehost([enabled = true])`**: Prevents following external links.
- **`robots([enabled = true, agent = '*'])`**: Fetches and respects `robots.txt` disallow paths and crawl delays. A host whose `robots.txt` answers 4xx has no rules and is crawled freely; one that answers 5xx has rules that could not be read, and RFC 9309 §2.3.1.4 says to stay out entirely rather than assume the best. A transport error — DNS, a refused connection — is treated as the 4xx case, since stopping a whole crawl over one failed lookup costs more than it protects.
- **`perhost([enabled = true])`**: When delays are configured, rate-limits per domain host instead of stalling all concurrent workers globally.

### What Comes Back

- **`accept(types)`**: Sends the types as the `Accept` header, and drops a response that arrives as something else anyway before a handler sees it — counted in `stats.skipped`. Without it a PDF or an image is handed to the HTML parser like any other page. Entries take a `/*` wildcard on the subtype, and a response carrying no `Content-Type` matches nothing.
- **`cap(bytes)`**: Abandons a transfer whose body is larger, as soon as `Content-Length` or the arriving bytes say so.
- **`cache(dir)`**: Keeps responses between runs. A re-run revalidates with `ETag`/`If-Modified-Since` and reuses what has not changed; anything still inside its `max-age` is not even asked about. Both arrive with `res.cached` set, so a handler can return early on the pages that did not move. See [`http.md`](http.md#7-caching-httpcache).

```dart no-compile
await net.crawl<String>('https://example.com'.url)
    .accept(['text/html'])
    .cap(util.size.parse('5MiB')!)
    .cache('.cache')
    .run((res) {
      if (res.cached) return;   // unchanged since the last run
      ...
    });
```

---

## 3. Finishing

| Method | Returns |
| :--- | :--- |
| `run([process])` | `Future<Stats>` |
| `collect([process])` | `Future<Sequence<T>>` of everything emitted |
| `stream([process])` | `Stream<T>`, yielding items as they are emitted |
| `gather(map)` | `Future<Sequence<R>>`, collecting what `map` returned per page |
| `save(path, [process])` | `Future<Stats>`, writing items to a file |
| `sink(destination, [process])` | `Future<Stats>`, writing items to an `IOSink` you own |
| `engine([process])` | The configured `Engine`, unrun |

Prefer `stream` or `save` over `collect` for large crawls — they do not hold every item in memory:

```dart
// Stream items to an async consumer:
await for (final title in net.crawl<String>(url).stream(handler)) {
  sink.write(title);
}

// Or stream directly to a file (Maps/Lists formatted as JSON lines):
final stats = await net.crawl<Map<String, Object?>>(url)
    .save('out/results.jsonl');
```

`gather` is the single-stage form, and the one to reach for first. The item
type comes from what the mapper returns rather than from an `emit` buried in a
closure, so it is inferred, and returning nothing for a page filters it out:

```dart
final titles = await net.crawl<Never>(seed)
    .gather((page) => page.parse(format.html).find('.title').texts.list);
// Future<Sequence<String>>
```

`Never` is the crawl's own item type: `gather` emits nothing, so there is
nothing for it to be. A crawl that follows links into tagged stages emits, and
wants `collect`.

Both hand back a [`Sequence`](util.md#6-sequences-sequencet), so the shaping a
script came for is the next call rather than an import — and `.list` is the one
word at the boundary to anything outside this library:

```dart
// setup: Future<void> rowHandler(Page<Row> p) async {}
final rows = await net.crawl<Row>(seed).collect(rowHandler);

rows.group((r) => r.host)
    .seq.to((e) => (host: e.$1, spend: e.$2.sum((r) => r.cost)))
    .sort((e) => e.host)
    .each(print);

await concurrent.run(rows.list, enrich, size: system.os.cpus);
```

`save` writes the way every other write in this library does: items go to a `.part` staging file, its folder is created if it is missing, and it is renamed into place once the run finishes. A crawl that fails part way leaves whatever was already at the destination. `sink` writes to an `IOSink` you own — it is written to and flushed, never closed.

They used to be one method taking `Object`, which threw `ArgumentError` for anything that was neither.

---

## 4. Resuming an Interrupted Crawl

A crawl that dies partway through has two things worth keeping: the pages it already visited, and the pages it had queued but not yet fetched. `deduplicator` hands back the first. `resume` hands back both.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final stats = await net.crawl<String>('https://example.com'.url)
      .resume('crawl.state')
      .concurrent(4)
      .limit(5000)
      .run((res) {
        for (final href in res.parse(format.html).find('a').attrs('href').list) res.follow(href);
      });

  system.console.logger.ok('Crawled ${stats.completed} pages');
}
```

Run it, stop it with Ctrl-C, run it again: the second run picks up the frontier where the first left off. Ctrl-C and `kill` both flush the file before the process goes, so the position saved is the one actually reached rather than the last tick's.

| | |
| :--- | :--- |
| **On the way in** | An existing file restores the frontier, the visited set and the counters. Seeds already visited are dropped instead of fetched twice, and `limit` keeps counting the whole crawl rather than this leg of it. |
| **While running** | The file is rewritten every `every` (5 seconds by default), and once more when the run stops. |
| **On the way out** | A crawl that drained on its own deletes the file, having nothing left to resume. One that stopped early — `limit`, `res.stop`, a signal — keeps it. |

A page that was mid-fetch when the run stopped counts as pending, not as done, so it is fetched again rather than silently skipped. `Fetch.meta` travels through the file, so anything a handler stores there has to be JSON-encodable. A file that exists but cannot be read throws rather than starting the crawl over.

### Driving it yourself

`resume` is `Engine.snapshot` and `Engine.restore` wired to a file. Both are public, so a crawl can keep its position anywhere — a database row, a key-value store, `io.store`:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final engine = net.crawl<String>('https://example.com'.url).engine((res) {
    for (final href in res.parse(format.html).find('a').attrs('href').list) res.follow(href);
  });

  const position = Slot<Map<String, Object?>>('position');

  final store = io.store.open('crawl.json');
  final saved = store.get(position);
  if (saved != null) engine.restore(Snapshot<String>.fromJson(saved));

  await engine.run(['https://example.com']);

  store.set(position, engine.snapshot().toJson());
  await store.save();
}
```

`Snapshot` carries `pending` (the unfinished requests), `deduplicator` (the visited set) and `stats` (the counters), and round-trips through `toJson`/`fromJson`.

---

## 5. Multi-Stage Crawls

A handler advances the crawl with `res.follow(...)`. Relative URLs resolve against the current page, a `Referer` is set, and duplicates are dropped.

Tags keep the stages apart:

```dart
const name = Slot<String>('name');

final stats = await net.crawl<String>('https://music.example.com/album'.url)
    .tag('song', (res) {
      print('${res.meta.get(name)} -> ${res.parse(format.html).find('a').attr('href')}');
    })
    .run((res) {
      for (final a in res.parse(format.html).find('#songlist a').elements.list) {
        res.follow(
          a.attr('href')!,
          tag: 'song',
          meta: [name(a.text)],
        );
      }
    });
```

`res.follow` takes a `method` and `body` too, so a form is followed the same way a link is:

```dart
res.follow(
  res.parse(format.html).find('form.search').attr('action')!,
  method: HttpMethod.post,
  body: Body.form({'q': 'widgets', 'page': '2'}),
  tag: 'results',
);
```

De-duplication reads the body, so two posts to one URL with different fields are two requests rather than one.

`res.submit` does the same thing from the form itself, which is what a page with hidden inputs and a CSRF token needs — the fields already on the page are carried, and only the ones you name are changed:

```dart
res.submit(
  res.parse(format.html).form('form.search')!
    ..fill({'q': 'widgets', 'page': '2'}),
  tag: 'results',
);
```

See [docs/form.md](form.md).

- `tag(name, handler)` routes pages queued with that tag.
- `route(pattern, handler)` routes by URL pattern.
- The function passed to `run`/`collect`/`stream` handles anything unmatched.

---

## 5b. Carrying Context Between Stages

`meta` is carried untouched from fetch to page, which is how a handler recovers the context it queued a page with. It is keyed by `Slot`s — the same typed keys `io.store` uses, see [store.md](store.md#1-slots):

```dart
const artist = Slot<String>('artist');
const track = Slot<int>('track');

res.follow(href, tag: 'song', meta: [artist('Nick Drake'), track(4)]);

// in the 'song' handler:
final String? by = res.meta.get(artist);   // no cast
final int? no = res.meta.get(track);
```

Writing is checked against the slot's type, and a value that is not the shape the slot names reads back as `null` rather than throwing.

To pass one page's context on to the next, spread its entries:

```dart
res.follow(href, tag: 'detail', meta: [...res.meta.entries, track(4)]);
```

Whatever a slot writes has to survive `jsonEncode`, because `meta` travels through the [resume file](#4-surviving-interruption). `Slot.coded` covers a type JSON does not carry. `res.meta.raw` is the map underneath, for a key another library owns.

---

## 6. Inside a Handler

```dart no-compile
res.emit(item);                    // yield a result
res.follow(url, tag: ..., meta: ..., priority: ...);
res.stop('reason');                // wind down after in-flight work
res.tag;                           // the tag this page was queued with
res.meta.get(slot);                // the context it was queued with
res.engine;                        // the running Engine
res.fetch;                         // the scheduled Fetch
res.depth;                         // current hop depth (seed is 0)
```

### Declarative Extraction (`res.extract`)

Extract structured data declaratively using CSS selectors and property targets (`@attr` or `@text`):

```dart
final article = res.parse(format.html).extract({
  'title': 'h1.headline',
  'author': '.byline > a',
  'link': 'link[rel="canonical"]@href',
  'tags': ['ul.tags > li'],
  'comments': ['.comment', {
    'user': '.author',
    'body': '.text',
  }],
});
```

For a typed read, `res.parse(format.html).pick(Field.text('h1'))` returns a `String?` rather than
an `Object?` — see [`http.md`](http.md#declarative-extraction-extract).

Everything from [`Reply`](http.md) is available too — `res.parse(format.html).find('...')`, `res.parse(format.html).xpath('...')`, `res.body`, `res.parse(format.json).raw`, `res.save(...)`.

---

## 7. Priority & De-duplication

Higher `priority` is served first; ties keep insertion order. Useful for draining detail pages before discovering more listings:

```dart
res.follow(href, tag: 'detail', priority: 10);
```

`Deduplicator` normalizes trailing slashes, folds host case, and keys on HTTP method, URL, and tag. It can be persisted and restored:

```dart
final dedup = Deduplicator();
// ... run crawl ...
final jsonState = dedup.toJson();
io.dump('cache/seen.json', jsonState);

// Later:
final restored = Deduplicator.fromJson(
  ((await format.json.read('cache/seen.json')).raw as List).cast<Object?>(),
);
await net.crawl<String>(url).deduplicator(restored).run(handler);
```

---

## 8. Events

Every handler hands the builder back, so they join the same expression as the rest of the configuration:

```dart
await net.crawl<String>(url)
    .concurrent(4)
    .on.start(() => log.info('starting'))
    .on.item((item) => bar.tick())
    .on.progress((res) => log.debug('${res.status} ${res.url}'))
    .on.error((f) => log.error('${f.fetch?.url} failed', f.error, f.stack))
    .on.done((stats) => log.ok('${stats.completed} pages'))
    .run(handler);
```

> Without an `on.error` handler, a failing page is skipped silently so one bad URL cannot end the run. Register it while developing.

`Stats` carries `scheduled`, `completed`, `failed`, `retried`, `emitted`, `bytes`, `elapsed` and `reason`. `retried` counts the attempts the client made again after a transport error, a 5xx or a 429 — the retries `retry(n)` bought.

### The pages that did not make it

`stats.failed` counts the failures; `on.error` says which pages they were. A `Failure` carries the `error`, the `stack` and the `request` it happened on, so a crawl can keep its own dead-letter list:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final lost = <Failure<String>>[];

  final stats = await net.crawl<String>('https://example.com'.url)
      .on.error(lost.add)
      .run((res) {});

  system.console.logger.warn('${stats.failed} failed');
  for (final failure in lost) {
    system.console.logger.warn('${failure.fetch?.url}: ${failure.error}');
  }

  // Retry just those, on their own.
  await net.crawl.seed<String>([
    for (final failure in lost)
      if (failure.fetch case final request?) request,
  ]).run((res) {});
}
```

A failed request is unfinished work, so a crawl using [`resume`](#4-resuming-an-interrupted-crawl) keeps it pending and fetches it again on the next run without being asked.

---

## 9. Testing a Pipeline

Use `MapDownloader` to serve fixture responses from an in-memory map without network access:

```dart
final titles = await net.crawl<String>('https://site.test'.url)
    .downloader(MapDownloader<String>({
      'https://site.test': '<html><body><h1>Hi</h1></body></html>',
    }))
    .collect((res) => res.emit(res.parse(format.html).find('h1').text));
```

Keys are matched most specific first — `'POST https://host/login'`, then `'POST /login'`, then `'https://host/login'`, then `'/login'` — so one URL can answer differently to a `GET` and a `POST`, which is what a multi-step form crawl needs:

```dart
final downloader = MapDownloader<String>({
  '/login': '<form action="/login" method="post"></form>',
  'POST /login': '<p class="welcome">Signed in</p>',
});

await net.crawl<String>('https://site.test/login'.url)
    .downloader(downloader)
    .run(handler);

expect(downloader.fetches.last.method, HttpMethod.post);
```

`downloader.fetches` holds every fetch served, in order, so a test can assert on the method, headers and body the pipeline actually sent.

For custom fixture resolution, subclass `Downloader`:

```dart
class MockDownloader<T> extends Downloader<T> {
  final Map<String, String> pages;
  MockDownloader(this.pages);

  @override
  Future<Page<T>> download(Fetch<T> fetch) async => Page<T>(
        fetch: fetch,
        status: pages.containsKey('${fetch.url}') ? 200 : 404,
        bytes: utf8.encode(pages['${fetch.url}'] ?? ''),
      );
}
```

---

## 10. Driving the Engine Directly

For full control, build the engine and use its router:

```dart no-compile
final engine = Engine<String>(
  downloader: HttpDownloader(concurrency: 4),
  process: (res) => res.emit(res.parse(format.html).find('h1').text),
);

engine.router
  ..on(RegExp(r'/album$'), (res) { ... })
  ..tag('disc', (res) { ... })
  ..status(404, (res) => log.warn('missing ${res.url}'))
  ..fallback((res) => log.debug('unhandled ${res.url}'));

engine.items.listen(print);
final stats = await engine.run(['https://example.com']);
```

`engine.queue` reports the frontier (`length`, `isEmpty`, `clear()`); `engine.stopped`, `engine.running`, `engine.active` and `engine.idle` report state. `engine.snapshot()` captures its position and `engine.restore(snapshot)` puts one back — see [section 4](#4-resuming-an-interrupted-crawl).

