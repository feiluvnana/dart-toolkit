# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A cohesive automation and web-scraping toolkit for Dart, developed by **feiluvnana**. Built for writing clean command-line scripts in **plain, idiomatic Dart**: top-level functions, extensions on the native types, and ordinary classes.

### What is in it

| Area | Reach for | Focus |
| :--- | :--- | :--- |
| **Files** | `readText`, `writeJson`, `listDir`, `walkDir`, `withLock` | One file: reading it, writing it **atomically**, asking what is at a path. Paths are `joinPath`/`dirname`/`stemName`; directories are `listDir`/`walkDir`/`makeDir` |
| **Networking** | `get`, `post`, `download`, `crawl`, `serve` | HTTP requests, streaming downloads, the frontier that crawls, a server that listens — it fetches bytes and parses none of them |
| **System** | `run`, `runStream`, `which`, `env`, `onExit`, `shutdown` | Subprocesses, environment, terminal IO — and the hooks that decide what happens to your files and child processes when the program is interrupted |
| **Concurrency** | `parallelMap`, `settle`, `retry`, `Pool`, `RateLimiter` | Bounded async task pools, failure-tolerant fan-out, and rate limiting |
| **Formats** | `parseHtml`, `parseJson`, `parseYaml`, `parseCsv`, `zip` | One pair of functions per format, every one behind the same `DocumentFormat` seam |
| **Utilities** | `slugify`, `formatBytes`, `sha256Hash`, `jitter`, `delay` | Pure helpers: text, byte sizes, digests, randomness, time |
| **CLI** | `CliParser`, `Cli`, `Opt` | Flags, options, subcommands, and usage text |
| **Collections** | `sortedBy`, `chunk`, `window`, `distinct`, `groupBy` | Extensions straight onto `Iterable`, `Stream` and `Map` |

---

## Design Philosophy

1. **Idiomatic Dart.** Top-level functions (`readText`, `run`, `get`, `delay`), extensions on the types you already hold (`'x'.toSlug()`, `items.chunk(2)`, `250.ms`), and plain classes (`CliParser`, `Crawler`, `Pool`). No namespace object to go through, and Effective Dart `lowerCamelCase` throughout.
2. **One name per operation.** Every operation has exactly one spelling. Where an operation reads naturally as a property of a value there is also an extension method, and it forwards to the same implementation — `slugify(title)` and `title.toSlug()` are the same call, never two.
3. **Names say what they act on.** A bare `list`, `copy` or `join` at top level says nothing, so it is `listDir`, `copyPath`, `joinPath`.
4. **Real types at every boundary.** URLs are `Uri`, delays are `Duration`, paths are `String`, bodies and hash algorithms are sealed types and enums. Declaring a CLI option hands back a typed `Opt<T>` handle rather than a name to look up later.
5. **Atomic by default.** Every write stages through a `.part` file and is renamed into place only after a successful flush. Interrupted runs never leave truncated files.
6. **Seams the library already has.** A crawl is not a framework: a transport is a function (`Send`), a document is a `DocumentFormat`, and the results are a `Stream<Response>`. Multi-stage routing is a Dart `switch` on the tag a request carried, which the compiler checks.
7. **Native collections.** Everything operates directly on Dart 3 `Iterable`, `List`, `Map` and `Stream` — no wrapper types to convert into or out of.

---

## Installation

Requires Dart 3.10 or newer.

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

One import gives you everything:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```

Type names do not collide with `dart:io` — `Fetcher` is this package's client,
`HttpClient` is still `dart:io`'s:

```dart
import 'dart:io';                                  // HttpClient is dart:io's
import 'package:dart_toolkit/dart_toolkit.dart';   // Fetcher is this one's
```

**Importing `package:http` in the same file needs a `hide`.** This package puts
`get`, `post`, `put`, `patch`, `delete`, `head`, `readBytes` and `Response` at
top level, and `package:http` exports the same eight names:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' hide get, post, put, patch, delete, head, readBytes, Response;
```

The same applies to `package:collection` and `rxdart`, whose `sorted`,
`sortedBy`, `whereNotNull`, `flatMap`, `debounce`, `mergeWith` and `concatWith`
extension members overlap with the ones here.

---

## Quickstart

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  // 1. Arguments
  final parser = CliParser();
  final concurrency = parser.number('concurrency', abbr: 'c', defaultsTo: 4);
  final force = parser.flag('force', abbr: 'f');
  parser.parse(args);

  final log = logger;
  final clock = Stopwatch()..start();

  // 2. Crawler and collect
  log.step(1, 3, 'Crawling headlines...');
  final crawler = crawl([Fetch('https://news.ycombinator.com'.url)])
    ..concurrent(concurrency())
    ..delay(250.ms)
    ..limit(50);

  final titles = await crawler
      .expand((res) => res.parse(DocumentFormat.html).$('.titleline > a').texts)
      .toList();
  log.ok('Found ${titles.length} headlines.');

  // 3. Process concurrently, with a progress bar
  log.step(2, 3, 'Processing...');
  final batch = titles.take(10).toList();
  final bar = Progress(total: batch.length, message: 'Processing');
  final processed = await parallelMap(batch, (title) async {
    bar.tick(1, title);
    return title.toUpperCase();
  }, concurrency: cpuCount);
  bar.done('Done.');

  // 4. Report and save atomically
  log.step(3, 3, 'Saving...');
  consoleWriter.write(
    (Table(headers: ['Metric', 'Value'])..addAll([
      ['Crawled', '${titles.length}'],
      ['Processed', '${processed.length}'],
      ['Elapsed', formatDuration(clock.elapsed)],
    ])).render(),
  );

  final dest = joinPath('output', 'summary.txt');
  if (force() || !pathExists(dest)) {
    await writeText(dest, processed.join('\n'));
    log.ok('Saved to $dest');
  }
}
```

This script exits on its own when it finishes — no manual cleanup call is needed.

**Coming from 7.x or earlier?** 8.x removed the namespace convention the
library was built on: the `io.*`, `net.*`, `system.*`, `concurrent.*`,
`util.*`, `format.*`, `cli.*` and `collection.*` accessor objects, the
`Sequence` / `Dictionary` / `Flow` wrapper types and their
`.through(...)` / `.collect(...)` pipelines, and the static hubs that
briefly replaced them. Every operation is a top-level function or an
extension method now, and there is one spelling of each. The full mapping
is in [CHANGELOG.md](CHANGELOG.md).

---

## Conventions

Two small extensions keep the strongly-typed signatures short at the call site.

**URLs are `Uri`**, matching `package:http`:

```dart
await get('https://example.com'.url);  // .url parses the string
```

**Delays are `Duration`**:

```dart
await delay(250.ms);
crawl([Fetch(url)]).delay(2.s);
```

`.ms`, `.s` and `.m` produce ordinary `Duration` values, usable anywhere one is accepted.

---

## Tour

### Files, atomically

Every write is atomic: staged through a `.part` file and renamed into place,
so a file appears whole or not at all. Each operation is a top-level function
with a `Sync` twin.

```dart
writeTextSync('out/notes.txt', 'hello');            // text
writeBytesSync('out/blob.bin', [1, 2, 3]);          // bytes
writeJsonSync('out/data.json', {'count': 42});      // JSON, atomically
appendTextSync('out/run.log', 'done\n');                     // append
final data = await const JsonFormat().read('out/data.json');  // -> Json cursor

pathExists(path);                       // anything at all, of any kind
fileStat(path);                         // -> FileSystemEntry?, one syscall
fileStat(path)?.isFile;                 // and .isDir, .isLink, .size, .empty
hasContent(path);                       // exists and non-empty
fileHashSync(path, Algo.md5);

readLinesSync(path);                         // List<String>
writeLinesSync('out/hosts.txt', hosts.keys); // one per line, atomically
tempFile('render_');                         // a temporary *file*

joinPath('a', 'b', 'c.txt');
dirname(path);  filename(path);  stemName(path);
cwd;  home;                             // read nothing, so they live here

makeDirSync('out/reports');
listDirSync('out');                     // one level -> List<FileSystemEntry>
walkDirSync('src', match: '**/*.dart'); // the whole tree, a glob
walkDirSync('out', match: '*.mp3');
sweepDirSync('out', match: '*.part');   // and how many went
dirSizeSync('out');                     // the recursive byte total
isDirEmptySync('out');                  // the directory question
createLinkSync('out/latest', 'run-2026-09-11');
```

**The read and write halves are spelled the same.** The name says the shape,
and `.write` is how it goes back: `readText`/`writeText`, `readBytes`/
`writeBytes`, `readLines`/`writeLines`, `readCsvRows`/`writeCsv`.

**One matcher, one depth axis.** Every member that looks at more than one
entry takes the same three filters — `only:` for the kind, `match:` for a
glob, `depth:` for how far down.

Everything that reads or writes a file hands back a `FileSystemEntry` — path,
kind, size, mtime and the name parts — instead of a `dart:io` handle:

```dart
for (final entry in listDirSync('out')) {
  if (entry.isDir) continue;
  if (fileExtension(entry.path) == '.part') removePathSync(entry.path);
}
```

`isFile`, `isDir`, `isLink` and `empty` come off the one stat the entry holds,
so they cost nothing, where `fileExists(path)` costs a syscall for the same
question. `stemName`, `fileExtension` and `dirname` are path arithmetic and
never touch the disk.

The `Sync` variants block. The async ones are what a crawl handler or pool
worker wants — one blocking read stalls every task in flight:

```dart
await writeText('out/notes.txt', 'hello');
final text = await readText('out/notes.txt');
await walkDir('out');
```

Downloading is `download`, because a socket is networking's.

A crawl reaches a spreadsheet without passing through memory:

```dart
await writeCsv(
  'products.csv',
  crawl([Fetch(seed)]).map(
    (res) => <String, Object?>{'name': res.url.path, 'price': '0'},
  ),
  headers: ['name', 'price'],
);
```

See [lib/io/io.dart](lib/io/io.dart), [lib/io/csv.dart](lib/io/csv.dart), [lib/collection/collection.dart](lib/collection/collection.dart).

### HTTP requests, and the codec seam

```dart
final res = await get('https://example.com'.url);

// `Http` fetches bytes; `DocumentFormat` reads them.
final page = res.parse(DocumentFormat.html);
page.$('h1').text;                    // text of first h1
page.$('a').attrs('href');            // all hrefs

res.parse(DocumentFormat.json).at('data.total').number();   // the other format

// Typed extraction: a record, with every field's type intact.
final item = (
  title: page.$('h1.title').text,
  price: page.pick(Field.text('.price').when(extractNumber)),
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

await post(url, body: const Body.json({'id': 1}));
await download(url, 'out/file.zip');
```

**A `Fetcher` does what it was asked to do and nothing more.** Retries,
redirect-following, caching, cookies, rate limiting and a browser
`User-Agent` are all parameters, and a parameter nobody filled in stays
switched off:

```dart
// setup: final url = 'https://example.com'.url;
await get(url);                  // one request, no retry; a 302 comes
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
lambda: `urls.parallelMap((u) => send(.get, u))`.

Retries cover transport errors, 5xx and 429, honouring `Retry-After`; the
count is the whole of the decision, so `retries: 3` retries a `POST` as
readily as a `GET`. `redirects` is the hop budget: `0` hands back the `3xx`,
and a chain longer than a positive limit throws. See
[lib/net/http.dart](lib/net/http.dart).

### Crawling — the frontier, and nothing else

A crawl is **a queue that feeds itself**, plus dedupe, per-host politeness,
robots, depth, limit and resume. That is the whole scope of the type. A
single-stage crawl needs none of it and never did:

```dart
// setup: final urls = <Uri>[];
await parallelMap(urls, (u) => get(u), concurrency: 4);
```

What `crawl` adds over that line is the frontier:

```dart
final crawler = crawl(
  [Fetch('https://music.example.com/album'.url)],
  // The whole router: reply in, next requests out. A `switch` the compiler
  // checks, where `Router`, `route()` and `tag()` were three public members
  // that it did not.
  (res) => switch (res.fetch.tag) {
    null => res.parse(DocumentFormat.html).$('#songlist a').elements.map(
      (a) =>
          res.follow(a.attributes['href']!, tag: 'song', meta: [('name', a.text)]),
    ),
    _ => const <Fetch>[],
  },
)..concurrent(4)..limit(50)..depth(2);

// Extraction is downstream, on the stream.
await for (final res in crawler.where((res) => res.fetch.tag == 'song')) {
  print(
    '${res.fetch.meta['name']} -> '
    '${res.parse(DocumentFormat.html).$('a').attr('href')}',
  );
}
```

`res.follow` **returns** the next request rather than queueing one — it
resolves relative URLs, sets a `Referer` and grows the depth — so `next` is a
pure function, testable with a `Response.text` fixture and no crawl at all.

**Nothing is fetched until something collects**, and nothing about the *client*
is a member here. A crawl owns the knobs a scheduler owns; headers, timeout,
retries, cap, cache and rate belong to the `Fetcher` you hand it:

```dart
// setup: final seed = 'https://example.com'.url;
// setup: Iterable<Fetch> next(Response res) => const <Fetch>[];
final crawler = crawl([Fetch(seed)], next)
  ..using(Fetcher(
    headers: const {'User-Agent': 'ExampleBot/1.0'},
    timeout: 10.s,
    retries: 3,
    cap: 5 * 1024 * 1024,
    cache: HttpCache('.cache'),
    limiter: RateLimiter(10, per: 1.s),
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
typedef Send = Future<Response> Function(Fetch fetch);
```

`Fetcher` is one, so the shared client is the default. Everything else that
used to subclass a downloader base class is a closure:

```dart
// A fixture, and the recorder `MapDownloader` was an exported class for: a
// closure over a map, and a list it captures.
Send fixture(Map<String, String> pages, List<Fetch> sent) => (f) async {
  sent.add(f);
  return Response.text(pages['${f.url}'] ?? '', fetch: f);
};

// Middleware, which had no spelling at all before.
Send logged(Send inner) => (f) async {
  final res = await inner(f);
  print('${res.statusCode} ${f.url}');
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

final home = await res.parse(DocumentFormat.html).form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send(using: session.call);
```

Finding a form and reading its controls is HTML, so `Form` comes out of
`parseHtml`; sending one is a socket, so the networking side keeps the
`Sending` extension and nothing else. `at` tells the form which URL its markup came
from, which a cursor cannot know.

Inside a crawl, `form.fetch()` is the request the form describes, and
returning it from `next` is how it gets submitted. See
[lib/format/form.dart](lib/format/form.dart), [lib/net/form.dart](lib/net/form.dart).

### HTML selectors

```dart
// setup: const markup = '<ul><li class="track" data-id="1">'
// setup:     '<a href="/t/1">Track One</a></li></ul>';
const HtmlFormat().$(markup, '.track a').texts;      // parse and select in one call
parseHtml(markup).$('.track a').texts;  // the same, in two steps
res.parse(DocumentFormat.html).$('.title').at(0).text;

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

### Subprocesses and shutdown

```dart
final res = await run('git', ['status', '--short']);
if (res.ok) print(res.stdout);

which('ffmpeg');
env.get('PORT', 8080);
onExit(() => writeJsonSync('out/state.json', db));    // and track, adopt, signals
await shutdown();      // the one door out — it runs those hooks
```

`dart:io`'s `exit` skips every hook `onExit` exists to guarantee, and there is
deliberately no re-export of it here.

See [lib/system/system.dart](lib/system/system.dart), [lib/system/env.dart](lib/system/env.dart).

### The command line your script presents

```dart
final parser = CliParser();
final force = parser.flag('force', abbr: 'f');
final size = parser.number('concurrency', defaultsTo: 4);
final out = parser.option('out', abbr: 'o', defaultsTo: 'dist');
parser.parse(args);

if (force()) rebuild(out(), size());
```

Declaring returns the handle that reads it, so the type and the default live in
one place and `--concurrency=fast` is a parse error rather than a silent 4.

Or declare commands and `CliParser.run` parses, prints `--help`, validates and
dispatches, returning an exit code:

```dart
final parser = CliParser();
final build = parser.handle('build', _build, help: 'Build the project');
build.option('out', abbr: 'o', defaultsTo: 'dist', help: 'Output directory');

await shutdown(await parser.run(args));
```

See [lib/cli/cli.dart](lib/cli/cli.dart).

### Bounded async work

```dart
final bodies = await parallelMap(
  urls,
  (url) async => (await get(url)).parse(DocumentFormat.json),
  concurrency: 8,
);
```

Results keep input order. The first failure propagates with its own error and stack; register `Pool.on.error` to collect failures and continue instead, or use `settle`, which returns a sealed `Done`/`Broke` per item and never throws:

```dart
for (final result in await settle(urls, (u) => get(u))) {
  switch (result) {
    case Done(:final value): print(value.statusCode);
    case Broke(:final error): print('failed: $error');
  }
}
```

It was reachable only by naming a `Pool` through 6.2.0, while `run` — the half that throws — had a shorthand here.

`Semaphore` is *how many at once* and `RateLimiter` is *how often*; both implement `Waiting`, so a `Fetcher` can be paced by either. See [lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart).

### Formats — one pair of functions per format

Every codec is spelled identically — `parse`, `read`, `write`, `format` — and
every one implements `DocumentFormat`, which is what `res.parse(...)` takes:

```dart
final pubspec = await const YamlFormat().read('pubspec.yaml');
pubspec.text('version');                          // no cast
pubspec.jsonpath(r'$..sdk').map((n) => n.text()).nonNulls;

parseJson(res.body).at('data.items').all((i) => i.text('sku'));
parseHtml(res.body).$('h1').text;
parseCsv(res.body).column('sku');
await const YamlFormat().write('out.yaml', {'name': 'x'});

res.parse(DocumentFormat.robots).allowed(url);
res.parse(DocumentFormat.sitemap);                        // List<Uri>

toCsvString(parseCsv(text).maps);
```

`parseJson`, `parseYaml` and `parseToml` all hand back a `Json` cursor,
because they decode to the same maps, lists and scalars; `parseHtml` hands
back a `Markup` cursor. See [lib/format/json.dart](lib/format/json.dart),
[lib/format/yaml.dart](lib/format/yaml.dart) and [lib/src/markup.dart](lib/src/markup.dart).

**Formats, never binaries.** Wrappers for `git`, `gh` and `docker` were all
tried and all removed: a wrapper only ever has the
handful of subcommands somebody thought to add, where `run` has the
whole executable and already returns a `SysResult` rather than throwing.

```dart
final head = await run('git', ['rev-parse', '--short', 'HEAD']);
if (head.ok) print(head.stdout.trim());
```

### Archives

```dart
await zip('site', 'site.zip');          // or site.tar.gz, .tgz, .tar.bz2
await unzip('site.zip', 'restored');    // skips zip-slip entries
await listArchive('site.zip');     // without unpacking
await extractFromArchive('site.zip', 'index.html'); // one entry, in memory
```

Archives are the one format here that is **not** a codec: an archive is a
container of files, not a document with a shape, so there is no cursor to hand
back.

See [lib/format/zip.dart](lib/format/zip.dart).

### Collections — extensions on the native types

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
await for (final r in readCsvRecords('big.csv')) {
  if (r['live'] == 'yes') {
    print(r['host']);
  }
}

// bounded async work over a stream
await parallelMap(
  await readLines('urls.txt'),
  (line) => get(line.trim().url),
  concurrency: 8,
);
```

See [lib/collection/collection.dart](lib/collection/collection.dart).

### Pure helpers

Nothing here touches the disk or the OS; that is what keeps it small.

```dart
// setup: final clock = Stopwatch()..start();
formatDuration(clock.elapsed);           // '02:15'
formatBytes(5242880);                 // '5.0 MiB'
slugify('Hello, World!');           // 'hello-world'
extractNumber(r'$1,234.50');            // 1234.5
sha256Hash(url).substring(0, 8);     // an 8-character cache key
jitter(1.s);                     // 1.0s..1.25s
```

See [lib/util/util.dart](lib/util/util.dart).

---

## Testing Your Pipelines

A transport is a function, so a fixture is a closure over a map:

```dart
final titles = await (crawl([Fetch('https://site.test'.url)])
      ..using((f) async => Response.text('<h1>Hi</h1>', fetch: f)))
    .map((res) => res.parse(DocumentFormat.html).$('h1').text)
    .toList();
```

`next` is a pure function, so the routing is testable with no crawl at all:

```dart
// setup: Iterable<Fetch> next(Response res) => const <Fetch>[];
final urls = next(Response.text('<a href="/b">b</a>', fetch: Fetch(seed)))
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

A short runnable script per use case lives in [`example/`](example/), with
[example/example.dart](example/example.dart) putting them together as one
pipeline.

---

## License

MIT — see [LICENSE](LICENSE).
