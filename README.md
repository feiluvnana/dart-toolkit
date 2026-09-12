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

| Domain | Holds | Focus |
| :--- | :--- | :--- |
| `collection` | `Sequence`, `Dictionary`, `Flow`, `Transformer`, `Collector`, `Slot` | The three collections this library returns in place of Dart's — ordered, keyed, and over time — and the two operation types that shape all three. A library, not an accessor — you reach all of it from the data you already hold |

Two are **subjects** — knowledge that came from outside Dart:

| Domain | Sub-namespaces | Focus |
| :--- | :--- | :--- |
| **`cli.*`** | — | Flags, options, subcommands, usage text |
| **`format.*`** | `format.html.*`, `format.json.*`, `format.yaml.*`, `format.toml.*`, `format.csv.*`, `format.robots.*`, `format.sitemap.*`, `format.zip.*` | File formats — never executables; that is `system.run` |
| **`$()`** | — | The jQuery spelling of `format.html.parse`, opt-in |

**Where things live.** `util` holds only pure computation — nothing there touches
the disk or the operating system. Anything that reads or writes files is `io`;
anything that talks to the OS or the user is `system`. Argument parsing is
`cli` and not `system.cli`, because reading a `List<String>` touches nothing at
all. `zip`, `json`, `yaml`, `toml` and `html` share `format` rather than taking a
name each, because a top level that grows a name per file format is not a top
level.

[NAMESPACE.md](NAMESPACE.md) is the full rule set: which domain something
belongs to, when it earns a top-level name, and how to name it.

---

## Design Philosophy

1. **Idiomatic Dart, preferably one word.** Primary actions are concise and expressive: `run`, `get`, `post`, `save`, `write`, `dump`, `follow`, `using`, `step`, `ok`, `warn`, `ask`, `pick`, `which`, `clock`, `pack`, `slug`. Effective Dart `lowerCamelCase` is embraced throughout (`makeParent`, `httpOnly`, `perHost`, `sameHost`, `firstWhere`, `groupBy`, `brightRed`), while deprecated lowercase aliases are preserved for smooth upgrades.
2. **One name per operation.** Operations live in the domain that owns them, providing intuitive discovery without cognitive overhead or ambiguous duplicate namespaces.
3. **Real types at every boundary.** URLs are `Uri`, delays are `Duration`, paths are `String`, bodies and hash algorithms are sealed types and enums. Universal interoperability ensures methods accept native `Iterable` and `Map`.
4. **Atomic by default.** Every write stages through a `.part` file and is renamed into place only after a successful flush. Interrupted runs never leave truncated files, with robust cross-platform backoff retry and signal guards.
5. **Seams the library already has.** A crawl is not a framework: a transport is a function (`Send`), a document is a `Codec`, and the results are a `Flow<Reply>`. Multi-stage routing is a Dart `switch` on the tag a request carried, which the compiler checks.
6. **DX-First Native Collections.** In v7.0.0, `Sequence<T>` implements Dart's native `Iterable<T>`, bridging seamlessly with core Dart, while `Sequence`, `Dictionary`, and `Flow` remain available as expressive declarative pipeline tools. All APIs accept standard `Iterable` and `Map` directly, and powerful fluent extensions (`IterableExtensions`, `MapExtensions`, `StreamExtensions`) empower native Dart collections.
7. **A pipeline is a value.** A `Sequence` has two members: `transform` takes a [`Transformer`](lib/collection/collection.dart) and `collect` takes a [`Collector`](lib/collection/collection.dart). A `Flow` spells the same two over a [`Pipe`](lib/collection/pipe.dart) and a [`Pour`](lib/collection/pipe.dart), and so does a `Dictionary` — **one rule for three containers**. Everything else is a static factory on one of those four, which is what lets each operation take its ordinary name back — `map`, `where`, `take.first`, `group.by`, `max.by`.

   Which half an operation lives on is a rule rather than a list: **a shaping step can emit before its source ends, a terminal needs the end.** That is why `take.first` is a `Pipe` and `sort` is a `Pour`. On a `Sequence` the same law is only bookkeeping — the source has an end, and reading all of it is what the operation *is* — so `sort`, `flip`, `take.last` and `skip.last` are `Transformer`s there and a chain never changes container.

   One pair of *types* served both containers through 5.4.0, with the streaming half of every operation an optional field, and both sides paid: a flow-native step could not join the vocabulary at all (`asyncMap` lived in `concurrent` as `flow.run`), and a step a *flow* could not stream was demoted to a terminal on the *sequence* too. Splitting them into four fixed that. 5.5.0 also renamed the flow's *members* to `pipe`/`pour` to advertise the split, and 6.0.0 put them back: a rename forced by a spelling is not a rename, the operations already read identically because a dot shorthand resolves against the context type, and the `await` in front of a flow's terminal says which container you are on more reliably than a member name.

---

## Installation

Requires Dart 3.10 or newer — the dot-shorthand syntax `rows.transform(.map(f))` leans on is a 3.10 feature.

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
  final size = cli.number('concurrency', def: 4);
  final force = cli.flag('force', alias: 'f');
  cli.parse(args);

  final log = system.console.logger;
  final clock = Stopwatch()..start();

  // 2. Crawl and collect
  log.step(1, 3, 'Crawling headlines...');
  final crawl = net.crawl([Fetch('https://news.ycombinator.com'.url)].seq)
    ..concurrent(size())
    ..delay(250.ms)
    ..limit(50);

  final titles = await crawl.flow
      .through(.flat.map((res) =>
          res.parse(format.html).$('.titleline > a').texts))
      .toList();
  log.ok('Found ${titles.length} headlines.');

  // 3. Process concurrently, with a progress bar
  log.step(2, 3, 'Processing...');
  final batch = titles.transform(.take.first(10));
  final bar = Progress(total: batch.collect(.count()), message: 'Processing');
  final processed = await concurrent.run(batch, (title) async {
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: system.os.cpus);
  bar.done('Done.');

  // 4. Report and save atomically
  log.step(3, 3, 'Saving...');
  system.console.writer.write(
    (Table(headers: ['Metric', 'Value'])..addAll([
      ['Crawled', titles.collect(.count())],
      ['Processed', processed.collect(.count())],
      ['Elapsed', util.time.format(clock.elapsed)],
    ].seq)).render(),
  );

  final dest = io.path.join('output', 'summary.txt');
  if (force() || !io.has(dest)) {
    io.write(dest, processed.collect(.join('\n')));
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
await net.http.send(.get, 'https://example.com'.url);  // .url parses the string
```

**Delays are `Duration`**:

```dart
await util.time.wait(250.ms);
net.crawl([Fetch(url)].seq).delay(2.s);
```

`.ms`, `.s` and `.m` produce ordinary `Duration` values, usable anywhere one is accepted.

---

## Domain Tour

### `io` — files, atomically

`io` itself is about **one file**. Paths are `io.path`, directories are
`io.dir`, and each is a vocabulary of its own rather than a dozen more names on
one accessor.

```dart
io.write('out/notes.txt', 'hello');            // text
io.bytes.write('out/blob.bin', [1, 2, 3]);     // bytes
io.dump('out/data.json', {'count': 42});       // JSON, atomically
io.append('out/run.log', 'done\n');        // the one write that is not atomic
final data = await format.json.read('out/data.json');   // -> Json cursor

io.exists(path);                       // anything at all, of any kind
io.stat(path);                         // -> FileSystemEntry?, one syscall
io.stat(path)?.isfile;                 // and .isdir, .islink, .size, .empty
io.has(path);                          // exists and non-empty
io.hash(path, Algo.md5);

io.lines(path);                            // a lazy Sequence<String>
io.lines.write('out/hosts.txt', hosts.keys);   // one per line, atomically
io.chunks(path, size: 4096);               // Sequence<List<int>>, lazily
io.chunks.write('copy.bin', io.chunks(path));  // and back, without holding it
io.temp('render_');                        // a temporary *file*
final log = io.append.open('out/run.log'); // one descriptor for many appends

io.path.join('a', 'b', 'c.txt');
io.path.dirname(path);  io.path.filename(path);  io.path.stem(path);
io.path.cwd;  io.path.home;                // read nothing, so they live here

io.dir.make('out/reports');
io.dir.list('out');                        // one level -> Sequence<FileSystemEntry>
io.dir.walk('src', match: '**/*.dart');    // the whole tree, a glob
io.dir.walk('out', only: .file, match: '*.mp3');
io.dir.sweep('out', match: '*.part');      // and how many went
io.dir.size('out');                        // the recursive byte total
io.dir.empty('out');                       // the directory question
io.dir.link('out/latest', 'run-2026-09-11');
```

**The read and write halves are spelled the same.** The name says the shape,
and `.write` is how it goes back: `io.read`/`io.write`, `io.bytes`/
`io.bytes.write`, `io.lines`/`io.lines.write`, `io.chunks`/`io.chunks.write`,
`io.csv.rows`/`io.csv.write`. `io.save` was the one exception through 5.5.0 —
bytes, under a name that is the same English word as `write`.

**One matcher, one depth axis.** Every member that looks at more than one
entry takes the same three filters — `only:` for the kind, `match:` for a
glob, `depth:` for how far down. There were three vocabularies for *filter a
tree* through 5.4.0; `io.dir.find` is gone, because its own doc said it was
`walk(only: .file, match: …)`, and a `RegExp` filter is the collection
vocabulary's job one `transform` further on.

Everything that reads or writes a file hands back a `FileSystemEntry` — path,
kind, size, mtime and the name parts — instead of a `dart:io` handle:

```dart
for (final entry in io.dir.list('out').collect(.list())) {
  if (entry.isdir) continue;
  if (io.path.ext(entry.path) == '.part') io.remove(entry.path);
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
await io.async.write('out/notes.txt', 'hello');
final text = await io.async.read('out/notes.txt');
await io.async.dir.walk('out');
```

Downloading is `net.http.download`, because a socket is `net`'s.

Where the shape has to differ it differs by one rule and no exceptions: a
`Sequence` on `io`, a `Flow` on `io.async`. That covers `lines`, `chunks`,
`io.dir`'s listings and the whole of `io.csv`, which needed a carve-out
through 5.4.0 because every member of it was already a future from the
accessor that promises to block. The listings are re-derivable flows, so a
second terminal reads the disk again rather than throwing — which is what
makes the mirror a real one.

A crawl reaches a spreadsheet without passing through memory:

```dart
await io.async.csv.write(
  'products.csv',
  net.crawl([Fetch(seed)].seq).flow.through(
    .map((res) => <String, Object?>{'name': res.url.path, 'price': '0'}),
  ),
  headers: ['name', 'price'],
);
```

See [lib/io/io.dart](lib/io/io.dart), [lib/io/csv.dart](lib/io/csv.dart), [lib/collection/collection.dart](lib/collection/collection.dart).

### `net.http` — requests, and the codec seam

```dart
final res = await net.http.send(.get, 'https://example.com'.url);

// `net` fetches bytes; `format` reads them. One member, and it names no
// format, which is what lets one crawl handle more than one.
final page = res.parse(format.html);
page.$('h1').text;                    // text of first h1
page.$('a').attrs('href');            // all hrefs

res.parse(format.json).at('data.total').number();   // the other format

// Typed extraction: a record, with every field's type intact.
final item = (
  title: page.$('h1.title').text,
  price: page.pick(Field.text('.price').when(util.text.number)),
  variants: page.all('.variant', (row) => (
    name: row.$('.name').text,
    sku: row.attr('data-sku'),
  )),
);
item.variants.collect(.first())?.sku;   // String?, no cast

// The string shorthand, for a first look at an unfamiliar page:
final loose = page.extract({'title': 'h1.title', 'links': ['a.link@href']});

// Stateful session with cookies:
final session = Fetcher(session: true);

await net.http.send(.post, url, body: const Body.json({'id': 1}));
await net.http.download(url, 'out/file.zip');
```

**A `Fetcher` does what it was asked to do and nothing more.** Retries,
redirect-following, caching, cookies, rate limiting and a browser
`User-Agent` are all parameters, and a parameter nobody filled in stays
switched off:

```dart
// setup: final url = 'https://example.com'.url;
await net.http.send(.get, url);       // one request, no retry; a 302 comes
                                      // back as a 302

final api = Fetcher(retries: 3, redirects: 5);
await api.send(.get, url);            // retried, followed
await api.send(.post, url, body: const Body.json({'id': 1}), retries: 0);

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
await urls.flow
    .through(.map.async((u) => net.http.send(.get, u), size: 4))
    .collect(.list());
```

What `net.crawl` adds over that line is the frontier:

```dart
// setup: const name = Slot<String>('name');
final crawl = net.crawl(
  [Fetch('https://music.example.com/album'.url)].seq,
  // The whole router: reply in, next requests out. A `switch` the compiler
  // checks, where `Router`, `route()` and `tag()` were three public members
  // that it did not.
  (res) => switch (res.fetch.tag) {
    null => res.parse(format.html).$('#songlist a').elements.transform(
      .map((a) =>
          res.follow(a.attributes['href']!, tag: 'song', meta: [name(a.text)])),
    ),
    _ => const <Fetch>[],
  },
)..concurrent(4)..limit(50)..depth(2);

// Extraction is downstream, on the flow.
await crawl.flow
    .through(.where((res) => res.fetch.tag == 'song'))
    .collect(.foreach((res) => print(
      '${res.fetch.meta.read(name)} -> '
      '${res.parse(format.html).$('a').attr('href')}',
    )));
```

`res.follow` **returns** the next request rather than queueing one — it
resolves relative URLs, sets a `Referer` and grows the depth — so `next` is a
pure function, testable with a `Reply.text` fixture and no crawl at all.

Three terminals: `flow` for the replies as they arrive, `settle` for the same
with the failures in band as `Done`/`Broke`, and `run()` to drain it and read
`stats`. Everything the 5.5.0 builder offered as a member is a step on the
flow — `on.progress` is `.transform(.tap(…))`, `items()` is `.collect(.list())`,
`gather(map)` is `.transform(.flat.map(map))`, and `res.stop` is cancelling
the flow, which stops the crawl.

**Nothing is fetched until something collects**, and nothing about the *client*
is a member here. A crawl owns the knobs a scheduler owns; headers, timeout,
retries, cap, cache and rate belong to the `Fetcher` you hand it:

```dart
// setup: final seed = 'https://example.com'.url;
// setup: Iterable<Fetch> next(Reply res) => const <Fetch>[];
final crawl = net.crawl([Fetch(seed)].seq, next)
  ..using(Fetcher(
    headers: const {'User-Agent': 'ExampleBot/1.0'},
    timeout: 10.s,
    retries: 3,
    cap: 5 * 1024 * 1024,
    cache: HttpCache('.cache'),
    limiter: concurrent.rate(10, per: 1.s),
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
final res = await session.send(.get, 'https://example.com/login'.url);

final home = await res.parse(format.html).form('#login')!
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
format.html.$(markup, '.track a').texts;      // parse and select in one call
format.html.parse(markup).$('.track a').texts;  // the same, in two steps
res.parse(format.html).$('.title').at(0).text;

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
final res = await system.run('git', ['status', '--short']);
if (res.ok) print(res.out);

system.which('ffmpeg');
system.env.get('PORT', 8080);
system.on.exit(() => db.dump('out/state.json'));    // and track, adopt, signals
await system.shutdown();      // the one door out — it runs those hooks
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

await system.shutdown(await cli.run(args));
```

See [lib/cli/cli.dart](lib/cli/cli.dart).

### `concurrent` — bounded async work

```dart
final bodies = await concurrent.run(
  urls,
  (url) async => (await net.http.send(.get, url)).parse(format.json),
  size: 8,
);
```

`items` is a `Sequence`, so whatever read it — a crawl, a CSV, a directory walk — goes straight in.

Results keep input order. The first failure propagates with its own error and stack; register `Pool.on.error` to collect failures and continue instead, or use `concurrent.settle`, which returns a sealed `Done`/`Broke` per item and never throws — one outcome per item, in input order, so `items.zip(outcomes)` recovers which is which:

```dart
(await concurrent.settle(urls, (u) => net.http.send(.get, u))).collect(
  .foreach((result) => switch (result) {
    Done(:final value) => print(value.status),
    Broke(:final error) => print('failed: $error'),
  }),
);
```

It was reachable only by naming a `Pool` through 6.2.0, while `run` — the half that throws — had a shorthand here.

`Semaphore` is *how many at once* and `Limiter` is *how often*; both implement `Waiting`, so a `Fetcher` can be paced by either. See [lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart).

### `format.*` — one name per format

Every codec is spelled identically — `parse`, `read`, `write`, `format` — and
every one implements `Codec`, which is what `res.parse(...)` takes:

```dart
final pubspec = await format.yaml.read('pubspec.yaml');
pubspec.text('version');                          // no cast
pubspec.jsonpath(r'$..sdk').transform(.map.nonnull((n) => n.text()));

format.json.parse(res.body).at('data.items').all((i) => i.text('sku'));
format.html.parse(res.body).$('h1').text;      // the same three members
format.csv.parse(res.body).column('sku');         // and CSV, since 5.2.0
await format.yaml.write('out.yaml', {'name': 'x'});   // the inverse of read

// A robots.txt and a sitemap are formats too, and they read off a reply
// through the same seam — they were `net.robots` and `net.sitemap` through
// 5.5.0, in the domain whose own doc says it parses nothing.
res.parse(format.robots).allowed(url);
res.parse(format.sitemap);                        // Sequence<Uri>

// Every codec round-trips its own output, which is Rule 7: what a `parse`
// hands back is what the matching `format` takes.
format.csv.format(format.csv.parse(text).maps);
format.sitemap.format(res.parse(format.sitemap));
```

`format.json`, `format.yaml` and `format.toml` all hand back a `Json` cursor,
because they decode to the same maps, lists and scalars; `format.html` hands
back a `Markup` cursor. See [lib/format/json.dart](lib/format/json.dart),
[lib/format/yaml.dart](lib/format/yaml.dart) and [lib/src/markup.dart](lib/src/markup.dart).

**`format` holds formats, never binaries.** `tool.git`, `tool.gh` and
`tool.docker` were all tried and all removed: a wrapper only ever has the
handful of subcommands somebody thought to add, where `system.run` has the
whole executable and already returns a `SysResult` rather than throwing.

```dart
final head = await system.run('git', ['rev-parse', '--short', 'HEAD']);
if (head.ok) print(head.out.trim());
```

### `format.zip` — archives

```dart
await format.zip.pack('site', 'site.zip');          // or site.tar.gz, .tgz, .tar.bz2
await format.zip.unpack('site.zip', 'restored');    // skips zip-slip entries
await format.zip.list('site.zip');                  // without unpacking
await format.zip.extract('site.zip', 'index.html'); // one entry, in memory
```

`format.zip` is the one member of this domain that is **not** a codec: an
archive is a container of files, not a document with a shape, so there is no
cursor to hand back. It has `pack`, `bundle`, `unpack`, `extract` and `list`
instead — `extract` was `read` through 5.5.0, which collided with every other
accessor's *parse the document at this path*.

See [lib/format/zip.dart](lib/format/zip.dart).

### `collection` — `Sequence`, `Dictionary`, `Flow`, and four operation types

```dart
rows.transform(.where((r) => r.live))
    .transform(.take.first(10))
    .transform(.sort.by((r) => r.cost));

rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)));  // one pass
rows.collect(.count.by((r) => r.host));                         // Dictionary<String, int>
rows.collect(.max.by((r) => r.score))?.url;                     // nullable, never throws
```

The same vocabulary, and the same two members, over a source that arrives a piece at a time — a `Flow` is what this library returns in place of a `Stream`. The `await` in front of the terminal is what tells you which container you are on:

```dart
await io.async.csv.records('big.csv')
    .through(.where((r) => r['live'] == 'yes'))
    .through(.take.first(1000))
    .collect(.count.by((r) => r['host']));

// bounded async work over a source too large to hold, which
// `concurrent.run` cannot take
await io.async.lines('urls.txt')
    .through(.map.async((line) => net.http.send(.get, line.trim().url), size: 8))
    .collect(.count());
```

A `Pipe` also carries what only makes sense over time, none of which had a spelling before: `map.async`, `where.async`, `flat.async`, `chunk.time`, `debounce`, `throttle`, `merge`, `timeout`, `handle` — and a binary operand that is itself a `Flow`, so two files zip line by line.

`tap` was on that list until 6.3.0 and did not belong there: watching an element go past is not particular to time, it was simply the half that got written. It is a `Transformer` too now, so a counter or a progress tick sits mid-chain on a sequence:

```dart
// setup: final bar = Progress(total: 3); final rows = <Row>[].seq;
rows.transform(.tap((r) => bar.tick(1, r.sku))).collect(.list());
```

A chain is a value, so it can be named once and used twice:

```dart
// setup: bool live(Row r) => r.live; String sku(Row r) => r.sku;
final cleanup = Transformer.where<Row>(live).then(Transformer.unique.by(sku));

rows.transform(cleanup).transform(.take.first(10));
rows.transform(cleanup).collect(.count());
```

A named pipeline belongs to one container. `Pipe.of(transformer)` crosses it, as a conversion rather than a second spelling — and it says out loud that it buffers, which the old design did silently for every transformer that supplied no streaming half.

See [lib/collection/collection.dart](lib/collection/collection.dart).

### `util` — pure helpers

Nothing here touches the disk or the OS; that is what keeps it small.

```dart
// setup: final clock = Stopwatch()..start();
util.time.format(clock.elapsed);      // '02:15'
util.size.format(5242880);            // '5.0 MiB'
util.text.slug('Hello, World!');      // 'hello-world'
util.text.number(r'$1,234.50');       // 1234.5
util.hash.sha(url).substring(0, 8);   // an 8-character cache key
util.rand.jitter(1.s);                // 1.0s..1.25s
```

See [lib/util/util.dart](lib/util/util.dart).

---

## Testing Your Pipelines

A transport is a function, so a fixture is a closure over a map:

```dart
final titles = await (net.crawl([Fetch('https://site.test'.url)].seq)
      ..using((f) async => Reply.text('<h1>Hi</h1>', fetch: f)))
    .flow
    .through(.map((res) => res.parse(format.html).$('h1').text))
    .collect(.list());
```

`next` is a pure function, so the routing is testable with no crawl at all:

```dart
// setup: Iterable<Fetch> next(Reply res) => const <Fetch>[];
final urls = next(Reply.text('<a href="/b">b</a>', fetch: Fetch(seed)))
    .transform(.map((f) => f.url.toString()))
    .collect(.list());
```

To swap the shared HTTP client process-wide, hand `net.use` your own:

```dart
await net.use(Fetcher(headers: {'Authorization': 'Bearer $token'}));
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
