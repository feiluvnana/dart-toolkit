# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A cohesive automation and web-scraping toolkit for Dart, developed by **feiluvnana**.

**Every operation hangs off the value it acts on. Every argument is a leading dot.**

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

final out = Path.cwd / 'output';
await (out / 'products.json').writeJson(rows);      // atomic
final settings = await Path('config.yaml').read(.yaml);

final res = await Http.get('https://example.com'.url);
final titles = res.$$('h1').map((h) => h.text);

await for (final page in crawl(seeds, next: _next, politeness: .perHost(250.ms))) {
  print(page.url);
}
```

### What is in it

| Reach for | On | For |
| :--- | :--- | :--- |
| `Path` | `Path.cwd / 'out' / 'q3.json'` | Reading, writing **atomically**, listing, watching, locking, hashing, zipping — one type, ~45 members, no `Sync` suffixes |
| `Http` | `Http.get`, `Http.post`, `Http.download` | One-off requests through a shared pooled client |
| `Fetcher` | `Fetcher(session: true)` | A session: cookies, base headers, retries, cache, rate limit |
| `crawl` | `crawl(seeds, next: …)` | A `Stream<Response>` from a self-feeding frontier |
| `String` | `'x'.toSlug()`, `'5MiB'.bytes`, `body.parse(.html)` | Text, sizes, durations, hashes, every document format |
| `Iterable` | `items.chunk(2)`, `urls.parallelMap(Http.get)` | Native collections, plus bounded async work |
| `Console` / `logger` | `logger.ok(…)`, `Console.confirm(…)` | Terminal output and input |
| `CliParser` | `parser.flag('force', abbr: 'f')` | Flags, options, subcommands, usage text |

---

## Design

**1. Verbs live on their receiver.** A path operation is a member of `Path`, a
response operation a member of `Response`, a string operation an extension on
`String`. An editor cannot help with a list of global functions, because there
is nothing to type before the dot. It can help perfectly with `path.`.

**2. Arguments are typed values, reached with a leading dot.** Dart 3.10's dot
shorthands mean a typed argument costs nothing at the call site:

```dart
res.parse(.yaml);
page.pick(.text('h1'));
await Http.post(url, body: .json({'q': 'widgets'}));
crawl(seeds, politeness: .perHost(250.ms), scope: .sameHost);
await Path('dist/app.zip').hash(.sha256);
```

**3. Top level is for what has no receiver** — and there are fourteen:
`crawl`, `serve`, `serveOnce`, `run`, `runStream`, `which`, `env`, `loadEnv`,
`onExit`, `shutdown`, `cpuCount`, `logger`, `delay`, `retry`.

**4. One name per operation.** Not one name plus an extension plus a `Sync`
twin. Blocking calls are under `path.sync`, not behind a suffix on every name.

**5. Real types at every boundary.** URLs are `Uri`, delays are `Duration`,
paths are `Path`, bodies and algorithms are sealed types and enums.

**6. Atomic by default.** Every write stages through a `.part` file and is
renamed into place only after a successful flush. Interrupted runs never leave
truncated files.

**7. Native collections.** Everything operates directly on Dart 3 `Iterable`,
`List`, `Map` and `Stream`. No wrapper types.

---

## Installation

Requires Dart 3.10 or newer.

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

One import gives you everything, and it does not fight your other imports:

```dart no-compile
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:http/http.dart' hide Response;
import 'package:collection/collection.dart';
```

Through 8.1.0 this package put `get`, `post`, `put`, `patch`, `delete`, `head`
and `readBytes` in global scope and the README had to tell you to hide all
seven. They are `Http.get`, `Http.post` and `path.readBytes()` now, so
**`Response` is the only name left to hide** — and only if you want
`package:http`'s.

`package:collection` shares a few *extension member* names with this package
(`sorted`, `sortedBy`, `firstWhereOrNull`). Those are not an import problem:
Dart only asks you to disambiguate at a call site that uses one, and
`IterableExtensions(items).sorted()` names the one you meant.

---

## Quickstart

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  final cli = CliParser(description: 'Headline scraper.');
  final concurrency = cli.number('concurrency', abbr: 'c', defaultsTo: 4);
  final force = cli.flag('force', abbr: 'f');
  cli.parse(args, autoHelp: true);

  final clock = Stopwatch()..start();
  logger.step(1, 3, 'Crawling headlines...');

  final titles = await crawl(
    ['https://news.ycombinator.com'],
    concurrency: concurrency(),
    politeness: .every(250.ms),
    limit: 50,
  ).expand((res) => res.$$('.titleline > a').map((el) => el.text)).toList();

  logger.ok('Found ${titles.length} headlines.');

  logger.step(2, 3, 'Processing...');
  final processed = await titles.take(10).parallelMap(
    (title) async => title.toUpperCase(),
    concurrency: cpuCount,
    progress: 'Processing',
  );

  logger.step(3, 3, 'Saving...');
  Console.write(
    (Table(headers: ['Metric', 'Value'])..addAll([
      ['Crawled', '${titles.length}'],
      ['Processed', '${processed.length}'],
      ['Elapsed', clock.elapsed.format()],
    ])).render(),
  );

  final dest = Path('output') / 'summary.txt';
  if (force() || !dest.exists) {
    await dest.parent.makeDir();
    await dest.writeText(processed.join('\n'));
    logger.ok('Saved to $dest');
  }
}
```

**Coming from 8.x?** The 168 public top-level names are 14. Everything else
moved onto the value it acts on. The full mapping is in
[CHANGELOG.md](CHANGELOG.md); the short version is `readText(p)` →
`Path(p).readText()`, `get(u)` → `Http.get(u)`, `slugify(t)` → `t.toSlug()`,
and the crawler's eleven cascade methods are named arguments.

---

## Conventions

**This string, read as something.** One family of getters on `String`:

```dart
'https://example.com'.url;   // Uri
'output/q3.json'.path;       // Path
'5 MiB'.bytes;               // int?     — 5242880
'1h30m'.duration;            // Duration?
'2024-03-09'.date;           // DateTime?
```

**Delays are `Duration`:**

```dart
await delay(250.ms);
crawl(seeds, politeness: .every(2.s));
```

`.ms`, `.s`, `.m` and `.hours` produce ordinary `Duration` values.

---

## Tour

### Files — one type, and every write atomic

```dart
final out = Path.cwd / 'output' / 'reports';
await out.makeDir();
await (out / 'q3.json').writeJson(rows);
final report = await (out / 'notes.md').readText();
```

`Path` is an **extension type over `String`**, so it is erased at run time —
there is no wrapper to allocate and no conversion to pay for — and it
`implements String`, so every `String` member comes along and a `Path` flows
straight into `dart:io`:

```dart
final settings = Path.home / '.tool' / 'config.yaml';
settings.endsWith('.yaml');   // String members, free
File(settings);               // dart:io, no conversion
```

The members group so that `path.` reads like a table of contents:

```dart
// place
path.parent;  path.name;  path.stem;  path.ext;  path.parts;
path.absolute;  path.normalized;  path.expanded;  path.relativeTo();

// ask — one stat each, no syscall for questions a value already answers
path.exists;  path.isFile;  path.isDir;  path.isLink;
path.hasContent;  path.size;  path.stat;

// read
await path.readText();   await path.readLines();   await path.readBytes();
await path.readJson();   await path.read(.yaml);   path.csvRecords();

// write — every one atomic
await path.writeText(text);    await path.writeLines(titles);
await path.writeJson(data);    await path.write(data, as: .csv);
await path.appendText('done\n');

// move
await path.copyTo(dest);  await path.moveTo(dest);  await path.delete();
await path.makeDir();     await path.touch();       await path.linkTo(dest);

// walk
await dir.list();                    // one level -> List<FileSystemEntry>
await dir.walk(match: '*.dart');     // the whole tree
await dir.sweep(match: '*.part');    // delete, and how many went
await dir.dirSize;                   // the recursive byte total
dir.watch((changed) => print(changed));

// hold
await path.lock(() async => rebuild());
await path.hash(.sha256);
await dir.zipTo('site.zip');
```

**Blocking calls are one member, not a suffix on twenty-eight names:**

```dart
await settings.readText();   // Future<String>
settings.sync.readText();    // String
```

Listing hands back `FileSystemEntry` — a snapshot of one stat, with nothing to
close:

```dart
for (final entry in Path('out').sync.list()) {
  if (entry.isDir) continue;
  if (Path(entry.path).ext == '.part') Path(entry.path).sync.delete();
}
```

A crawl reaches a spreadsheet without passing through memory:

```dart
await Path('products.csv').writeCsv(
  crawl(seeds).map((res) => {'url': '${res.url}', 'size': res.bytes.length}),
  headers: ['url', 'size'],
);
```

See [lib/io/path.dart](lib/io/path.dart).

### HTTP requests, and the codec seam

```dart
final res = await Http.get('https://example.com'.url);

// `Http` fetches bytes; `DocumentFormat` reads them.
res.$('h1').text;                     // text of the first h1
res.$$('a').map((a) => a.attr('href'));
res.parse(.json).at('data.total').number();

await Http.post(url, body: .json({'id': 1}));
await Http.download(url, into: Path('out') / 'file.zip');
```

`body` is a sealed `Body`, so the shape is named rather than guessed:
`.json(…)`, `.form(…)`, `.text(…)`, `.bytes(…)`. Through 8.1.0 it was
`Object?` and a `Map<String, String>` silently became a form while a
`Map<String, int>` became JSON.

**A `Fetcher` does what it was asked to do and nothing more.** Retries,
redirect-following, caching, cookies, rate limiting and a browser `User-Agent`
are all parameters, and a parameter nobody filled in stays switched off:

```dart
await Http.get(url);                  // one request, no retry; a 302 comes
                                      // back as a 302

final api = Fetcher(retries: 3, redirects: 5);
await api.send(.get, url);            // retried, followed
await api.send(.post, url, body: .json({'id': 1}), retries: 0);

final scraper = Fetcher.browser();    // the Chrome UA and HTML Accept header
final session = Fetcher(session: true);   // cookies
```

Retries cover transport errors, 5xx and 429, honouring `Retry-After`;
`redirects` is the hop budget, where `0` hands back the `3xx`. See
[lib/net/http.dart](lib/net/http.dart).

### Crawling — the frontier, and nothing else

A crawl is **a queue that feeds itself**, plus dedupe, per-host politeness,
robots, depth, limit and resume. A single-stage fan-out needs none of it:

```dart
await urls.parallelMap(Http.get, concurrency: 4);
```

What `crawl` adds over that line is the frontier — and every knob it has is a
named argument, so an editor shows all of them with their types and defaults:

```dart
final songs = crawl(
  ['https://music.example.com/album'],
  // The whole router: reply in, next requests out. A `switch` the compiler
  // checks, where `Router`, `route()` and `tag()` were three public members
  // that it did not.
  next: (res) => switch (res.fetch.tag) {
    null => res.$$('#songlist a').map(
      (a) => res.follow(a.attr('href')!, tag: 'song', meta: [('name', a.text)]),
    ),
    _ => const <Fetch>[],
  },
  concurrency: 4,
  politeness: .perHost(250.ms),
  scope: .sameHost,
  robots: .obey('ExampleBot/1.0'),
  accept: const ['text/html'],
  depth: 2,
  limit: 50,
  resume: 'crawl.state',
  send: Fetcher(
    headers: const {'User-Agent': 'ExampleBot/1.0'},
    timeout: 10.s,
    retries: 3,
    cache: HttpCache('.cache'),
    limiter: RateLimiter(10, per: 1.s),
  ).call,
);

// Extraction is downstream, on the stream.
await for (final res in songs.where((res) => res.fetch.tag == 'song')) {
  print('${res.fetch.meta['name']} -> ${res.$('a').attr('href')}');
}
```

**The crawl is the stream.** `Crawler extends Stream<Response>`, so every
`Stream` member works on it directly; `.flow` and `.stream` were two more
spellings of the same thing and are gone. `.settle` puts the failures in band,
`.run()` drains to `stats`.

`res.follow` **returns** the next request rather than queueing one — it
resolves relative URLs, sets a `Referer` and grows the depth — so `next` is a
pure function, testable with a `Response.text` fixture and no crawl at all.

**Nothing is fetched until something listens**, and nothing about the *client*
is configured here: headers, timeout, retries, cap, cache and rate belong to
the `Fetcher` you hand it. See [lib/net/crawl.dart](lib/net/crawl.dart).

### `Send` — a transport is a function

```dart
typedef Send = Future<Response> Function(Fetch fetch);
```

`Fetcher` is one, so the shared client is the default. Everything else that
used to subclass a downloader base class is a closure:

```dart
// A fixture: a closure over a map, and a list it captures.
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

### `Form` — the forms a page carries

`Markup.form(...)` collects a form's controls the way a browser would submit
them — the hidden inputs, the CSRF token, the options already selected — so a
script overrides the two fields it knows about and sends the rest back
untouched:

```dart
final session = Fetcher(session: true);
final res = await session.send(.get, 'https://example.com/login'.url);

final home = await res.parse(.html).form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send(using: session.call);
```

Inside a crawl, `form.fetch()` is the request the form describes, and returning
it from `next` is how it gets submitted. See
[lib/format/form.dart](lib/format/form.dart).

### HTML selectors and typed extraction

```dart
res.$('.title').text;                 // the first match
res.$$('.track a').map((a) => a.text);
res.parse(.html).$xpath('//h1');

// Typed extraction: a record, with every field's type intact.
final item = (
  title: page.$('h1.title').text,
  price: page.pick(.number('.price')),
  variants: page.all('.variant', (row) => (
    name: row.$('.name').text,
    sku: row.attr('data-sku'),
  )),
);
item.variants.firstOrNull?.sku;       // String?, no cast
```

`$` is the selector on a cursor and `$xpath` its XPath twin. The two top-level
functions of the same name stay behind an opt-in import, because a method named
`$` puts nothing in a script's global scope and a function does:

```dart
import 'package:dart_toolkit/html.dart';
```

See [lib/src/markup.dart](lib/src/markup.dart).

### Subprocesses and shutdown

```dart
final res = await run('git', ['status', '--short']);
if (res.ok) print(res.stdout);

which('ffmpeg');
env.get('PORT', 8080);
onExit(() => Path('out/state.json').sync.writeJson(db));
await shutdown();      // the one door out — it runs those hooks
```

A scratch file or a child process is cleaned up by asking it to be:

```dart
final scratch = await Path.tempFile();
scratch.deleteOnExit();
```

`dart:io`'s `exit` skips every hook `onExit` exists to guarantee, and there is
deliberately no re-export of it here. See
[lib/system/system.dart](lib/system/system.dart).

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

Or declare commands and let `CliParser.run` parse, print `--help`, validate and
dispatch, returning an exit code:

```dart
final parser = CliParser();
final build = parser.handle('build', _build, help: 'Build the project');
build.option('out', abbr: 'o', defaultsTo: 'dist', help: 'Output directory');

await shutdown(await parser.run(args));
```

See [lib/cli/cli.dart](lib/cli/cli.dart).

### Bounded async work

```dart
final bodies = await urls.parallelMap(
  (url) async => (await Http.get(url)).parse(.json),
  concurrency: 8,
);
```

Results keep input order, and the first failure propagates with its own error
and stack. `settle` is the version that never throws — a sealed `Done`/`Broke`
per item:

```dart
for (final result in await urls.settle(Http.get)) {
  switch (result) {
    case Done(:final value): print(value.statusCode);
    case Broke(:final error): print('failed: $error');
  }
}
```

`Semaphore` is *how many at once* and `RateLimiter` is *how often*; both
implement `Waiting`, so a `Fetcher` can be paced by either. See
[lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart).

### Formats — one codec, two directions, a leading dot

Every format implements `DocumentFormat` — `parse` in, `format` out — which is
what `String.parse`, `Response.parse`, `Path.read` and `Path.write` all take:

```dart
final pubspec = await Path('pubspec.yaml').read(.yaml);
pubspec.text('version');                          // no cast
pubspec.jsonpath(r'$..sdk').map((n) => n.text()).nonNulls;

res.body.parse(.json).at('data.items').all((i) => i.text('sku'));
res.body.parse(.html).$('h1').text;
res.body.parse(.csv).column('sku');
res.parse(.robots).allowed(url);
res.parse(.sitemap);                              // List<Uri>

await Path('out.yaml').write({'name': 'x'}, as: .yaml);
DocumentFormat.json.format(data);                 // to a string
```

`json`, `yaml` and `toml` all hand back a `Json` cursor, because they decode to
the same maps, lists and scalars; `html` hands back a `Markup` cursor.

**Formats, never binaries.** Wrappers for `git`, `gh` and `docker` were all
tried and all removed: a wrapper only ever has the handful of subcommands
somebody thought to add, where `run` has the whole executable.

### Archives

```dart
await Path('site').zipTo('site.zip');        // or site.tar.gz, .tgz, .tar.bz2
await Path('site.zip').unzipInto('restored');  // skips zip-slip entries
await Path('site.zip').entries();            // without unpacking
await Path('site.zip').extract('index.html');  // one entry, in memory
bytes.gzip();
```

Archives are the one format here that is **not** a codec: an archive is a
container of files, not a document with a shape, so there is no cursor to hand
back. See [lib/format/zip.dart](lib/format/zip.dart).

### Collections — extensions on the native types

```dart
rows.where((r) => r.live).take(10).sortedBy((r) => r.cost);
rows.groupBy((r) => r.host);
rows.countBy((r) => r.host);
rows.maxBy((r) => r.score)?.url;
items.chunk(2);  items.window(3);  items.distinct();
```

Async stream processing over files and network feeds:

```dart
await for (final r in Path('big.csv').csvRecords()) {
  if (r['live'] == 'yes') print(r['host']);
}
```

See [lib/collection/collection.dart](lib/collection/collection.dart).

### Pure helpers

Nothing here touches the disk or the OS; that is what keeps it small.

```dart
clock.elapsed.format();            // '02:15'
5242880.formatBytes();             // '5.0 MiB'
'5 MiB'.bytes;                     // 5242880
'Hello, World!'.toSlug();          // 'hello-world'
r'$1,234.50'.extractNumber();      // 1234.5
'$url'.hash().substring(0, 8);     // an 8-character cache key
1.s.jittered();                    // 1.0s..1.25s
Rand.id();                         // 'x7Fk2mQp9Lda'
```

See [lib/util/util.dart](lib/util/util.dart).

---

## Testing your pipelines

A transport is a function, so a fixture is a closure over a map:

```dart
final titles = await crawl(
  ['https://site.test'],
  send: (f) async => Response.text('<h1>Hi</h1>', fetch: f),
).map((res) => res.$('h1').text).toList();
```

`next` is a pure function, so the routing is testable with no crawl at all:

```dart
final found = next(Response.text('<a href="/b">b</a>', fetch: Fetch(seed)))
    .map((f) => f.url.toString())
    .toList();
```

And a client can be swapped for one async scope:

```dart
await Http.using(client, () async {
  await Http.get(url);
});
```

---

## Documentation

The documentation is the `///` comments under `lib/`, read through dartdoc or
on hover in an editor. Each file opens with a library-level comment that is the
narrative for its domain — what the vocabulary is, why it is shaped that way,
and what it cost. Every snippet in them is compiled by the test suite, so none
of it can drift.

| Domain | Reference |
| :--- | :--- |
| Paths, files, atomic writes | [lib/io/path.dart](lib/io/path.dart) |
| Filesystem entries | [lib/io/entry.dart](lib/io/entry.dart) |
| HTTP & downloads | [lib/net/http.dart](lib/net/http.dart) |
| Crawling | [lib/net/crawl.dart](lib/net/crawl.dart) |
| Requests & the transport seam | [lib/net/fetch.dart](lib/net/fetch.dart) |
| Forms | [lib/format/form.dart](lib/format/form.dart) |
| robots.txt & sitemaps | [lib/format/robots.dart](lib/format/robots.dart) |
| HTML & selectors | [lib/src/markup.dart](lib/src/markup.dart) |
| The codec seam | [lib/src/format.dart](lib/src/format.dart) |
| JSON & JSONPath | [lib/format/json.dart](lib/format/json.dart) |
| YAML & TOML | [lib/format/yaml.dart](lib/format/yaml.dart) |
| Archives | [lib/format/zip.dart](lib/format/zip.dart) |
| Subprocesses & shutdown | [lib/system/system.dart](lib/system/system.dart) |
| Environment & `.env` | [lib/system/env.dart](lib/system/env.dart) |
| Terminal IO | [lib/system/console/console.dart](lib/system/console/console.dart) |
| CLI arguments | [lib/cli/cli.dart](lib/cli/cli.dart) |
| Concurrency | [lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart) |
| Collections | [lib/collection/collection.dart](lib/collection/collection.dart) |
| Time, sizes, text, hashing, randomness | [lib/util/util.dart](lib/util/util.dart) |
| Serving | [lib/net/serve.dart](lib/net/serve.dart) |

[example/example.dart](example/example.dart) puts them together as one
pipeline.

---

## License

MIT — see [LICENSE](LICENSE).
