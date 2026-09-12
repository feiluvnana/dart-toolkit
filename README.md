# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A cohesive automation and web-scraping toolkit for Dart, developed by **feiluvnana**. Built for writing clean command-line scripts, with **lowercase, preferably one-word methods** and **hierarchical domain namespaces**.

### Domains

Five of them are **axes** — a way of touching the machine:

| Domain | Sub-namespaces | Focus |
| :--- | :--- | :--- |
| **`io.*`** | `io.path.*`, `io.dir.*`, `io.csv.*`, `io.async.*` | One file: reading it, writing it atomically, asking what is at a path. Paths are `io.path`, directories are `io.dir`, watching and locking sit flat |
| **`net.*`** | `net.http.*`, `net.crawl(...)`, `net.serve` | HTTP requests, streaming downloads, the frontier that crawls, a server that listens — it fetches bytes and parses none of them |
| **`system.*`** | `system.env.*`, `system.console.*`, `system.on.*` | Subprocesses, environment, terminal IO, `system.os` — and `system.on.*`, which is what happens to your files and child processes when the program is interrupted |
| **`concurrent.*`** | `concurrent.run(...)`, `concurrent.rate(...)` | Bounded async task pools, and rate limiting |
| **`util.*`** | `util.time.*`, `util.size.*`, `util.text.*`, `util.hash.*`, `util.rand.*` | Pure helpers: delays, byte sizes, text, digests, randomness — plus the `Json` and `Markup` document cursors |

One is neither, because it is a vocabulary rather than a way in:

| Domain | Hub / Helper | Focus |
| :--- | :--- | :--- |
| **Files** | `Files.*` | File reading, atomic writes, directories, paths, and CSV |
| **Http** | `Http.*` | HTTP requests, downloads, crawler stream, and server |
| **System & Env** | `System.*`, `Env.*` | Subprocesses, environment, exit hooks, and OS |
| **Concurrent** | `Concurrent.*` | Bounded async task mapping, settling, and rate limiting |
| **Formats & Codecs** | `Formats.*`, `Codec.*` | HTML, JSON, YAML, TOML, CSV, ZIP, robots, and sitemaps |
| **Utilities** | `Text`, `Time`, `Hash`, `Rand`, `Size` | Pure helpers: durations, byte sizes, text slugs, digests, and randomness |
| **CLI** | `CliParser`, `Cli` | Flags, options, subcommands, and usage text |

---

## Design Philosophy

1. **Idiomatic Dart, preferably one word.** Primary actions are concise and expressive: `run`, `get`, `post`, `save`, `write`, `dump`, `follow`, `using`, `step`, `ok`, `warn`, `ask`, `pick`, `which`, `clock`, `pack`, `slug`. Effective Dart `lowerCamelCase` is embraced throughout (`makeParent`, `httpOnly`, `perHost`, `sameHost`, `firstWhere`, `groupBy`, `brightRed`).
2. **One name per operation.** Operations live in discoverable static hubs and top-level helpers, providing intuitive discovery without cognitive overhead.
3. **Real types at every boundary.** URLs are `Uri`, delays are `Duration`, paths are `String`, bodies and hash algorithms are sealed types and enums. Universal interoperability ensures methods accept native `Iterable` and `Map`.
4. **Atomic by default.** Every write stages through a `.part` file and is renamed into place only after a successful flush. Interrupted runs never leave truncated files, with robust cross-platform backoff retry and signal guards.
5. **Seams the library already has.** A crawl is not a framework: a transport is a function (`Send`), a document is a `Codec`, and the results are a `Stream<Reply>`. Multi-stage routing is a Dart `switch` on the tag a request carried, which the compiler checks.
6. **DX-First Native Collections.** In v8.0.0, everything operates directly on Dart 3 native `Iterable`, `List`, `Map`, and `Stream`. Standard fluent extensions (`sortedBy`, `chunk`, `window`, `distinct`, `groupBy`, `parallelMap`) empower native collections without proprietary wrapper types.

---

## Installation

Requires Dart 3.10 or newer.

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

One import gives you every domain:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```

Every type name it brings is its own. Through 1.7.0 three of them —
`HttpClient`, `HttpResponse` and `Cookie` — were also `dart:io`'s, and Dart
resolved the package import first without saying anything; two more fought
`package:http` for `Request` and `Response`. 2.0.0 renamed all five, so a file
can import both libraries plainly:

```dart
import 'dart:io';                                  // HttpClient is dart:io's
import 'package:dart_toolkit/dart_toolkit.dart';   // Fetcher is this one's
```

The rename table is in [NAMESPACE.md](NAMESPACE.md#resolved-in-200).

---

## Quickstart

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  // 1. Arguments
  final parser = CliParser()
    ..number('concurrency', abbr: 'c', def: 4)
    ..flag('force', abbr: 'f');
  final cli = parser.parse(args);

  final log = logger;
  final clock = Stopwatch()..start();

  // 2. Crawl and collect
  log.step(1, 3, 'Crawling headlines...');
  final crawl = Http.crawl([Fetch('https://news.ycombinator.com'.url)])
    ..concurrent(cli.number('concurrency'))
    ..delay(250.ms)
    ..limit(50);

  final titles = await crawl
      .expand((res) => res.parse(Codec.html).$('.titleline > a').texts)
      .toList();
  log.ok('Found ${titles.length} headlines.');

  // 3. Process concurrently, with a progress bar
  log.step(2, 3, 'Processing...');
  final batch = titles.take(10).toList();
  final bar = Progress(total: batch.length, message: 'Processing');
  final processed = await Concurrent.map(batch, (title) async {
    bar.tick(1, title);
    return title.toUpperCase();
  }, concurrency: System.cpus);
  bar.done('Done.');

  // 4. Report and save atomically
  log.step(3, 3, 'Saving...');
  consoleWriter.write(
    (Table(headers: ['Metric', 'Value'])..addAll([
      ['Crawled', '${titles.length}'],
      ['Processed', '${processed.length}'],
      ['Elapsed', Time.format(clock.elapsed)],
    ])).render(),
  );

  final dest = Files.join('output', 'summary.txt');
  if (cli.flag('force') || !Files.exists(dest)) {
    await Files.writeText(dest, processed.join('\n'));
    log.ok('Saved to $dest');
  }
}
```

This script exits on its own when it finishes — no manual cleanup call is needed.

**Coming from 6.2?** 6.3.0 closed the seam between what this library returns
and what it takes. Every collection parameter is now a `Sequence`, so
`format.csv.format(sheet.maps)`, `format.sitemap.format(parsed)`,
`concurrent.run(rows, work)`, `net.crawl(seeds)`, `table.addAll(sheet.rows)`
and `reader.pick(options: found)` compile without a conversion between them —
a list literal adds `.seq`. `Csv.rows` is a `Sequence<List<String>>` rather
than a nested sequence, so a cell is `row[2]`. `Transformer.tap` and
`concurrent.settle` fill the two gaps where a name existed on one half of a
pair and not the other, and `util.size.format` takes the `num` that
`collect(.sum(...))` returns. Nothing was renamed.

**Coming from 5.5?** 6.0.0 rebuilt `net` around three seams and swept the
other seven domains for names that said the same thing twice. A transport is a
`Send` — a function — so `Downloader`, `HttpDownloader`, `MapDownloader` and
`DownloaderEvents` are gone; `Page<T>` folded into `Reply` and `res.follow`
returns the next request instead of queueing one; `Engine`, `CrawlBuilder`,
`Router`, `Snapshot`, `Stats`, `Failure` and `Deduplicator` collapsed into one
`Crawl` whose terminal is a `Flow<Reply>`. `net.robots`, `net.sitemap` and the
reading half of `Form` moved to `format`, which made the domain's own *this
domain does not parse anything* true. `flow.pipe`/`pour` went back to
`transform`/`collect`; `io.save` is `io.bytes.write`; `util.text.strip` is
`util.text.tags`; `util.hash.encode` is `util.text.base64`; `system.exit`,
`Ansi.strip`, `Ansi.width` and `cli.strict()` are deleted. The full mapping is
in [CHANGELOG.md](CHANGELOG.md).

**Coming from 5.0?** 5.1.0 replaced `Sequence`'s fifty-eight methods with two —
`transform(Transformer)` and `collect(Collector)` — and a third of the old names
were words this library had invented for an operation everybody already knew.
`to` is `map`, `keep` is `where`, `sift` is `map.nonnull`, `head` is
`take.first`, `best` is `max.by`, `tally` is `count.by`. `Sequence` and `Slot`
moved to a `collection` domain, `Dictionary` joined them and absorbed `Meta`,
`Store` and the three members that handed back a raw `Map`, and the minimum SDK
is 3.10. Every deleted member is a compile error at every call site, and the
full mapping is in [CHANGELOG.md](CHANGELOG.md).

---

## Conventions

Two small extensions keep the strongly-typed signatures short at the call site.

**URLs are `Uri`**, matching `package:http`:

```dart
await Http.get('https://example.com'.url);  // .url parses the string
```

**Delays are `Duration`**:

```dart
await Time.wait(250.ms);
Http.crawl([Fetch(url)]).delay(2.s);
```

`.ms`, `.s` and `.m` produce ordinary `Duration` values, usable anywhere one is accepted.

---

## Domain Tour

### `io` — files, atomically

`io` itself is about **one file**. Paths are `Files.join`, directories are
`Files.listSync` / `Files.walkSync`, and each is a static helper rather than a dozen more names on
one accessor.

```dart
Files.writeTextSync('out/notes.txt', 'hello');            // text
Files.writeBytesSync('out/blob.bin', [1, 2, 3]);          // bytes
Files.writeJsonSync('out/data.json', {'count': 42});      // JSON, atomically
Files.appendSync('out/run.log', 'done\n');                // append
final data = await const JsonAccessor().read('out/data.json');   // -> Json cursor

Files.exists(path);                       // anything at all, of any kind
Files.statSync(path);                     // -> FileSystemEntry?, one syscall
Files.statSync(path)?.isfile;             // and .isdir, .islink, .size, .empty
Files.has(path);                          // exists and non-empty
Files.hashSync(path, Algo.md5);

Files.readLinesSync(path);                // List<String>
Files.writeLinesSync('out/hosts.txt', hosts.keys); // one per line, atomically
Files.tempFile('render_');                // a temporary *file*

Files.join('a', 'b', 'c.txt');
Files.dirname(path);  Files.filename(path);  Files.stem(path);
Files.cwd;  Files.home;                   // read nothing, so they live here

Files.makeDirSync('out/reports');
Files.listSync('out');                    // one level -> List<FileSystemEntry>
Files.walkSync('src', match: '**/*.dart');// the whole tree, a glob
Files.walkSync('out', match: '*.mp3');
Files.sweepSync('out', match: '*.part');  // and how many went
Files.dirSizeSync('out');                 // the recursive byte total
Files.isDirEmptySync('out');              // the directory question
Files.linkSync('out/latest', 'run-2026-09-11');
```

**The read and write halves are spelled the same.** The name says the shape,
and `.write` is how it goes back: `Files.readText`/`Files.writeText`, `Files.readBytes`/
`Files.writeBytes`, `Files.readLines`/`Files.writeLines`, `Files.readCsvRows`/`Files.writeCsv`.

**One matcher, one depth axis.** Every member that looks at more than one
entry takes the same three filters — `only:` for the kind, `match:` for a
glob, `depth:` for how far down.

Everything that reads or writes a file hands back a `FileSystemEntry` — path,
kind, size, mtime and the name parts — instead of a `dart:io` handle:

```dart
for (final entry in Files.listSync('out')) {
  if (entry.isdir) continue;
  if (Files.ext(entry.path) == '.part') Files.deleteSync(entry.path);
}
```

`isfile`, `isdir`, `islink` and `empty` come off the one stat the entry holds,
so they cost nothing. `stem`, `ext` and `dirname` were on it through 5.5.0 and
are `io.path` calls now: the same answer on the same input, and `io.path` is
the domain that owns string arithmetic on a path.

`io.*` blocks. `io.async.*` carries the same names as futures, which is what a
crawl handler or pool worker wants — one blocking read stalls every task in
flight:

```dart
await Files.writeText('out/notes.txt', 'hello');
final text = await Files.readText('out/notes.txt');
await Files.walk('out');
```

Downloading is `Http.download`, because a socket is networking's.

A crawl reaches a spreadsheet without passing through memory:

```dart
await Files.writeCsv(
  'products.csv',
  Http.crawl([Fetch(seed)]).map(
    (res) => <String, Object?>{'name': res.url.path, 'price': '0'},
  ),
  headers: ['name', 'price'],
);
```

See [lib/io/io.dart](lib/io/io.dart), [lib/io/csv.dart](lib/io/csv.dart), [lib/collection/collection.dart](lib/collection/collection.dart).

### `net.http` — requests, and the codec seam

```dart
final res = await Http.get('https://example.com'.url);

// `Http` fetches bytes; `Codec` reads them.
final page = res.parse(Codec.html);
page.$('h1').text;                    // text of first h1
page.$('a').attrs('href');            // all hrefs

res.parse(Codec.json).at('data.total').number();   // the other format

// Typed extraction: a record, with every field's type intact.
final item = (
  title: page.$('h1.title').text,
  price: page.pick(Field.text('.price').when(Text.number)),
  variants: page.all('.variant', (row) => (
    name: row.$('.name').text,
    sku: row.attr('data-sku'),
  )),
);
item.variants.firstOrNull?.sku;       // String?, no cast

// The string shorthand, for a first look at an unfamiliar page:
final loose = page.extract({'title': 'h1.title', 'links': ['a.link@href']});

// Stateful session with cookies:
final session = Fetcher(session: true);

await Http.post(url, body: const Body.json({'id': 1}));
await Http.download(url, 'out/file.zip');
```

**A `Fetcher` does what it was asked to do and nothing more.** Retries,
redirect-following, caching, cookies, rate limiting and a browser
`User-Agent` are all parameters, and a parameter nobody filled in stays
switched off:

```dart
// setup: final url = 'https://example.com'.url;
await Http.get(url);                  // one request, no retry; a 302 comes
                                      // back as a 302

final api = Fetcher(retries: 3, redirects: 5);
await api.send(HttpMethod.get, url);  // retried, followed
await api.send(HttpMethod.post, url, body: const Body.json({'id': 1}), retries: 0);

final scraper = Fetcher.browser();    // the Chrome UA and HTML Accept header
```

**One verb, and the method is an argument.** `get`, `post`, `put`, `delete`,
`patch` and `head` were six members through 6.1.0, each restating eight
parameters to fill in one enum. A dot shorthand fills it in at the call site
instead, so `send(.get, url)` is the whole vocabulary — and a tear-off is a
lambda: `concurrent.run(urls, (u) => net.http.send(.get, u))`.

Retries cover transport errors, 5xx and 429, honouring `Retry-After`; the
count is the whole of the decision, so `retries: 3` retries a `POST` as
readily as a `GET`. `redirects` is the hop budget: `0` hands back the `3xx`,
and a chain longer than a positive limit throws. See
[lib/net/http.dart](lib/net/http.dart).

### `net.crawl` — the frontier, and nothing else

A crawl is **a queue that feeds itself**, plus dedupe, per-host politeness,
robots, depth, limit and resume. That is the whole scope of the type. A
single-stage crawl needs none of it and never did:

```dart
// setup: final urls = <Uri>[];
await Concurrent.map(urls, (u) => Http.get(u), concurrency: 4);
```

What `Http.crawl` adds over that line is the frontier:

```dart
final crawl = Http.crawl(
  [Fetch('https://music.example.com/album'.url)],
  // The whole router: reply in, next requests out. A `switch` the compiler
  // checks, where `Router`, `route()` and `tag()` were three public members
  // that it did not.
  (res) => switch (res.fetch.tag) {
    null => res.parse(Codec.html).$('#songlist a').elements.map(
      (a) =>
          res.follow(a.attributes['href']!, tag: 'song', meta: [('name', a.text)]),
    ),
    _ => const <Fetch>[],
  },
)..concurrent(4)..limit(50)..depth(2);

// Extraction is downstream, on the stream.
await for (final res in crawl.where((res) => res.fetch.tag == 'song')) {
  print(
    '${res.fetch.meta['name']} -> '
    '${res.parse(Codec.html).$('a').attr('href')}',
  );
}
```

`res.follow` **returns** the next request rather than queueing one — it
resolves relative URLs, sets a `Referer` and grows the depth — so `next` is a
pure function, testable with a `Reply.text` fixture and no crawl at all.

**Nothing is fetched until something collects**, and nothing about the *client*
is a member here. A crawl owns the knobs a scheduler owns; headers, timeout,
retries, cap, cache and rate belong to the `Fetcher` you hand it:

```dart
// setup: final seed = 'https://example.com'.url;
// setup: Iterable<Fetch> next(Reply res) => const <Fetch>[];
final crawl = Http.crawl([Fetch(seed)], next)
  ..using(Fetcher(
    headers: const {'User-Agent': 'ExampleBot/1.0'},
    timeout: 10.s,
    retries: 3,
    cap: 5 * 1024 * 1024,
    cache: HttpCache('.cache'),
    limiter: Concurrent.rate(10, per: 1.s),
  ).call)
  ..resume('crawl.state')     // carry on where an interrupted run stopped
  ..accept(const ['text/html'])  // never hand a PDF to the parser
  ..obey('ExampleBot/1.0');   // robots.txt, Crawl-delay included
```

Ten knobs were declared at four levels through 5.5.0 — builder, engine,
downloader and client, thirty-two declarations in all — and a caller-supplied
downloader silently dropped five of them. A knob that lives in one place
cannot be dropped in transit.

See [lib/net/crawl.dart](lib/net/crawl.dart), [lib/net/fetch.dart](lib/net/fetch.dart).

### `Send` — a transport is a function

```dart
typedef Send = Future<Reply> Function(Fetch fetch);
```

`Fetcher` is one, so `net.http` is the default. Everything else that used to
subclass `Downloader` is a closure:

```dart
// A fixture, and the recorder `MapDownloader` was an exported class for: a
// closure over a map, and a list it captures.
Send fixture(Map<String, String> pages, List<Fetch> sent) => (f) async {
  sent.add(f);
  return Reply.text(pages['${f.url}'] ?? '', fetch: f);
};

// Middleware, which had no spelling at all before.
Send logged(Send inner) => (f) async {
  final res = await inner(f);
  print('${res.status} ${f.url}');
  return res;
};
```

No back-pointer, no item type, no inherited worker loop, no
`UnsupportedError`, and no exported type per transport.

### `Form` — the forms a page carries

Reading a page is half of it. `Markup.form(...)` collects a form's controls the
way a browser would submit them — the hidden inputs, the CSRF token, the
options already selected — so a script overrides the two fields it knows about
and sends the rest back untouched:

```dart
final session = Fetcher(session: true);
final res = await session.send(HttpMethod.get, 'https://example.com/login'.url);

final home = await res.parse(Codec.html).form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send(using: session.call);
```

Finding a form and reading its controls is HTML, so `Form` lives in
`format.html`; sending one is a socket, so `net` keeps the `Sending`
extension and nothing else. `at` tells the form which URL its markup came
from, which a cursor cannot know.

Inside a crawl, `form.fetch()` is the request the form describes, and
returning it from `next` is how it gets submitted. See
[lib/format/form.dart](lib/format/form.dart), [lib/net/form.dart](lib/net/form.dart).

### `format.html` — selectors

```dart
// setup: const markup = '<ul><li class="track" data-id="1">'
// setup:     '<a href="/t/1">Track One</a></li></ul>';
const HtmlAccessor().$(markup, '.track a').texts;      // parse and select in one call
Formats.html(markup).$('.track a').texts;  // the same, in two steps
res.parse(Codec.html).$('.title').at(0).text;

// The top-level function, opt-in via package:dart_toolkit/html.dart:
$(markup, '.track a').texts;
$(markup).$('.track').attrs('data-id');
```

`$` is the selector on a cursor and `$xpath` its XPath twin — the jQuery
spelling all the way down, because a *method* named `$` puts nothing in a
script's global scope. Only the two top-level functions do, and those stay
behind the opt-in import. `find` and `xpath` were the method names through
6.0.0, with `$` an extension on `String` beside them.

See [lib/src/markup.dart](lib/src/markup.dart).

### `system` — subprocesses and shutdown

```dart
final res = await System.run('git', ['status', '--short']);
if (res.ok) print(res.out);

System.which('ffmpeg');
Env.get('PORT', 8080);
System.onExit(() => Files.writeJsonSync('out/state.json', db));    // and track, adopt, signals
await System.shutdown();      // the one door out — it runs those hooks
```

`system.exit` was the other door through 5.5.0: `dart:io`'s `exit` under this
domain's name, skipping every hook `system.on` exists to guarantee. The only
reason to reach for it was not knowing the difference.

See [lib/system/system.dart](lib/system/system.dart), [lib/system/env.dart](lib/system/env.dart).

### `cli` — the command line your script presents

```dart
final force = cli.flag('force', alias: 'f');
final size = cli.number('concurrency', def: 4);
final out = cli.option('out', alias: 'o', def: 'dist');
cli.parse(args);

if (force()) rebuild(out(), size());
```

Declaring returns the handle that reads it, so the type and the default live in
one place and `--concurrency=fast` is a parse error rather than a silent 4.

Or declare commands and `cli.run` parses, prints `--help`, validates and
dispatches, returning an exit code:

```dart
final build = cli.handle('build', _build, desc: 'Build the project');
final out = build.option('out', alias: 'o', def: 'dist', desc: 'Output directory');

await System.shutdown(await cli.run(args));
```

See [lib/cli/cli.dart](lib/cli/cli.dart).

### `concurrent` — bounded async work

```dart
final bodies = await Concurrent.map(
  urls,
  (url) async => (await Http.get(url)).parse(Codec.json),
  concurrency: 8,
);
```

Results keep input order. The first failure propagates with its own error and stack; register `Pool.on.error` to collect failures and continue instead, or use `Concurrent.settle`, which returns a sealed `Done`/`Broke` per item and never throws:

```dart
for (final result in await Concurrent.settle(urls, (u) => Http.get(u))) {
  switch (result) {
    case Done(:final value): print(value.status);
    case Broke(:final error): print('failed: $error');
  }
}
```

It was reachable only by naming a `Pool` through 6.2.0, while `run` — the half that throws — had a shorthand here.

`Semaphore` is *how many at once* and `Limiter` is *how often*; both implement `Waiting`, so a `Fetcher` can be paced by either. See [lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart).

### `format.*` — one name per format

Every codec is spelled identically — `parse`, `read`, `write`, `format` — and
every one implements `Codec`, which is what `res.parse(...)` takes:

```dart
final pubspec = await const YamlAccessor().read('pubspec.yaml');
pubspec.text('version');                          // no cast
pubspec.jsonpath(r'$..sdk').map((n) => n.text()).nonNulls;

Formats.json(res.body).at('data.items').all((i) => i.text('sku'));
Formats.html(res.body).$('h1').text;
Formats.csv(res.body).column('sku');
await const YamlAccessor().write('out.yaml', {'name': 'x'});

res.parse(Codec.robots).allowed(url);
res.parse(Codec.sitemap);                        // List<Uri>

Formats.toCsv(Formats.csv(text).maps);
```

`format.json`, `format.yaml` and `format.toml` all hand back a `Json` cursor,
because they decode to the same maps, lists and scalars; `format.html` hands
back a `Markup` cursor. See [lib/format/json.dart](lib/format/json.dart),
[lib/format/yaml.dart](lib/format/yaml.dart) and [lib/src/markup.dart](lib/src/markup.dart).

**`format` holds formats, never binaries.** `tool.git`, `tool.gh` and
`tool.docker` were all tried and all removed: a wrapper only ever has the
handful of subcommands somebody thought to add, where `System.run` has the
whole executable and already returns a `SysResult` rather than throwing.

```dart
final head = await System.run('git', ['rev-parse', '--short', 'HEAD']);
if (head.ok) print(head.out.trim());
```

### `format.zip` — archives

```dart
await Formats.zip('site', 'site.zip');          // or site.tar.gz, .tgz, .tar.bz2
await Formats.unzip('site.zip', 'restored');    // skips zip-slip entries
await const ZipAccessor().list('site.zip');     // without unpacking
await const ZipAccessor().extract('site.zip', 'index.html'); // one entry, in memory
```

`format.zip` is the one member of this domain that is **not** a codec: an
archive is a container of files, not a document with a shape, so there is no
cursor to hand back.

See [lib/format/zip.dart](lib/format/zip.dart).

### `collection` — Dart 3 Native Iterables & Modern Extensions

```dart
rows.where((r) => r.live)
    .take(10)
    .sortedBy((r) => r.cost);

rows.groupBy((r) => r.host);
rows.countBy((r) => r.host);
rows.maxBy((r) => r.score)?.url;
```

Async stream processing over files and network feeds:

```dart
await for (final r in Files.readCsvRecords('big.csv')) {
  if (r['live'] == 'yes') {
    print(r['host']);
  }
}

// bounded async work over a stream
await Concurrent.map(
  await Files.readLines('urls.txt'),
  (line) => Http.get(line.trim().url),
  concurrency: 8,
);
```

See [lib/collection/collection.dart](lib/collection/collection.dart).

### `util` — pure helpers

Nothing here touches the disk or the OS; that is what keeps it small.

```dart
// setup: final clock = Stopwatch()..start();
Time.format(clock.elapsed);           // '02:15'
Size.format(5242880);                 // '5.0 MiB'
Text.slug('Hello, World!');           // 'hello-world'
Text.number(r'$1,234.50');            // 1234.5
Hash.sha256(url).substring(0, 8);     // an 8-character cache key
Rand.jitter(1.s);                     // 1.0s..1.25s
```

See [lib/util/util.dart](lib/util/util.dart).

---

## Testing Your Pipelines

A transport is a function, so a fixture is a closure over a map:

```dart
final titles = await (Http.crawl([Fetch('https://site.test'.url)])
      ..using((f) async => Reply.text('<h1>Hi</h1>', fetch: f)))
    .map((res) => res.parse(Codec.html).$('h1').text)
    .toList();
```

`next` is a pure function, so the routing is testable with no crawl at all:

```dart
// setup: Iterable<Fetch> next(Reply res) => const <Fetch>[];
final urls = next(Reply.text('<a href="/b">b</a>', fetch: Fetch(seed)))
    .map((f) => f.url.toString())
    .toList();
```

To configure custom client options:

```dart
// setup: final token = 'xyz';
final client = Fetcher(headers: {'Authorization': 'Bearer $token'});
```

See [lib/net/crawl.dart](lib/net/crawl.dart).

---

## Documentation

The documentation is the `///` comments under `lib/`, read through dartdoc or
on hover in an editor. Each file opens with a library-level comment that is
the narrative for its domain — what the vocabulary is, why it is shaped that
way, and what it cost. There was a `docs/` folder beside them through 5.4.0;
5.5.0 retired it rather than keep two copies of every sentence.

| Domain | Reference |
| :--- | :--- |
| Files & paths | [lib/io/io.dart](lib/io/io.dart) |
| CSV tables | [lib/io/csv.dart](lib/io/csv.dart) |
| Sequences, dictionaries, typed keys | [lib/collection/collection.dart](lib/collection/collection.dart) |
| HTTP & downloads | [lib/net/http.dart](lib/net/http.dart) |
| Crawling | [lib/net/crawl.dart](lib/net/crawl.dart) |
| Requests & the transport seam | [lib/net/fetch.dart](lib/net/fetch.dart) |
| Forms | [lib/format/form.dart](lib/format/form.dart) |
| robots.txt & sitemaps | [lib/format/robots.dart](lib/format/robots.dart) |
| HTML & selectors | [lib/src/markup.dart](lib/src/markup.dart) |
| Subprocesses & shutdown | [lib/system/system.dart](lib/system/system.dart) |
| CLI arguments | [lib/cli/cli.dart](lib/cli/cli.dart) |
| Environment & `.env` | [lib/system/env.dart](lib/system/env.dart) |
| Concurrency | [lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart) |
| Terminal IO | [lib/system/console/console.dart](lib/system/console/console.dart) |
| Time, sizes, text, hashing, randomness | [lib/util/util.dart](lib/util/util.dart) |
| JSON & JSONPath | [lib/format/json.dart](lib/format/json.dart) |
| YAML & TOML | [lib/format/yaml.dart](lib/format/yaml.dart) |
| Serving (`net.serve`) | [lib/net/serve.dart](lib/net/serve.dart) |
| Archives | [lib/format/zip.dart](lib/format/zip.dart) |
| Namespace & naming rules | [NAMESPACE.md](NAMESPACE.md) |

A short runnable script per use case lives in [`example/`](example/), with
[example/example.dart](example/example.dart) putting them together as one
pipeline.

---

## License

MIT — see [LICENSE](LICENSE).
