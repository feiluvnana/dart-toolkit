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
| **`net.*`** | `net.http.*`, `net.crawl`, `net.serve` | HTTP requests, streaming downloads, the crawler engine, a server that listens — it fetches bytes and parses none of them |
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
| **`format.*`** | `format.html.*`, `format.json.*`, `format.yaml.*`, `format.toml.*`, `format.zip.*` | File formats — never executables; that is `system.run` |
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

1. **Lowercase, preferably one word.** Every primary action is a single word: `run`, `get`, `post`, `save`, `write`, `dump`, `follow`, `emit`, `stop`, `step`, `ok`, `warn`, `ask`, `pick`, `which`, `clock`, `pack`, `slug`. Where one word genuinely will not do, the name stays lowercase rather than turning camelCase: `perhost`, `samehost`, `httponly`, `topleft`, `bgred`.
2. **One name per operation.** There are no aliases and no flat shortcuts. Each operation lives in the domain that owns it and is reachable exactly one way — so there is never a question of which spelling to use.
3. **Real types at every boundary.** URLs are `Uri`, delays are `Duration`, paths are `String`, bodies and hash algorithms are sealed types and enums. No `Object` or `dynamic` parameters, so the analyzer catches mistakes at the call site.
4. **Atomic by default.** Every write stages through a `.part` file and is renamed into place only after a successful flush. Interrupted runs never leave truncated files, and Ctrl-C cleans up.
5. **Engine-driven pipelines.** Multi-stage crawlers use declarative URL routing, tag-based stages, and automatic relative-URL resolution.
6. **One vocabulary for collections.** Everything this library hands back for you to *shape* is a [`Sequence`](lib/collection/collection.dart), a [`Dictionary`](lib/collection/collection.dart) or a [`Flow`](lib/collection/collection.dart), deliberately not an `Iterable`, a `Map` or a `Stream`, so Dart's names and these are never both in scope at one call site. `collect(.list())`, `.map` and `.stream` are the ways out at the boundary; `.seq`, `.dict` and `.flow` bring an outside collection in. A `Sequence` hands back no `Iterable` of its own — leaving is a call, not a getter, because a getter would put Dart's vocabulary one dot from every sequence in the library. Through 4.0.0 that claim was only half true — 53 public members handed back a `List`, `Map` or `Set` against 30 that handed back a `Sequence` — and 5.0.0 converted them.
7. **A pipeline is a value.** A `Sequence` has two members: `transform` takes a [`Transformer`](lib/collection/collection.dart) and `collect` takes a [`Collector`](lib/collection/collection.dart). A `Flow` has the matching pair, `pipe` and `pour`, over a [`Pipe`](lib/collection/pipe.dart) and a [`Pour`](lib/collection/pipe.dart). Everything else is a static factory on one of those four, which is what lets each operation take its ordinary name back — `map`, `where`, `take.first`, `group.by`, `max.by`. A namespace has no `Map` to collide with and no camelCase to forbid, so a compound operation splits at the capital instead of inventing a word. It also makes a chain storable, passable, supplyable by a caller and testable against a plain list.

   Which half an operation lives on is a rule rather than a list: **a shaping step can emit before its source ends, a terminal needs the end.** That is why `take.first` is a `Pipe` and `sort` is a `Pour`. On a `Sequence` the same law is only bookkeeping — the source has an end, and reading all of it is what the operation *is* — so `sort`, `flip`, `take.last` and `skip.last` are `Transformer`s there and a chain never changes container.

   One pair served both containers through 5.4.0, with the streaming half of every operation an optional field, and both sides paid: a flow-native step could not join the vocabulary at all (`asyncMap` lived in `concurrent` as `flow.run`), and a step a *flow* could not stream was demoted to a terminal on the *sequence* too. The operations keep their spelling across the split, because a dot shorthand resolves against the context type; what tells you which container you are on is the member.

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
  final clock = util.time.clock();

  // 2. Crawl and collect
  log.step(1, 3, 'Crawling headlines...');
  final titles = await net.crawl<String>('https://news.ycombinator.com'.url)
      .concurrent(size())
      .delay(250.ms)
      .limit(50)
      .items((res) {
        res.parse(format.html).find('.titleline > a').texts.collect(.foreach((title) {
          res.emit(title);
        }));
      });
  log.ok('Found ${titles.collect(.count())} headlines.');

  // 3. Process concurrently, with a progress bar
  log.step(2, 3, 'Processing...');
  final batch = titles.transform(.take.first(10)).collect(.list());
  final bar = Progress(total: batch.length, message: 'Processing');
  final processed = await concurrent.run(batch, (title) async {
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: system.os.cpus);
  bar.done('Done.');

  // 4. Report and save atomically
  log.step(3, 3, 'Saving...');
  system.console.writer.table(
    Table(headers: ['Metric', 'Value'])..addAll([
      ['Crawled', titles.collect(.count())],
      ['Processed', processed.collect(.count())],
      ['Elapsed', util.time.format(clock.elapsed)],
    ]),
  );

  final dest = io.path.join('output', 'summary.txt');
  if (force() || !io.has(dest)) {
    io.write(dest, processed.collect(.join('\n')));
    log.ok('Saved to $dest');
  }
}
```

This script exits on its own when it finishes — no manual cleanup call is needed.

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
await net.http.get('https://example.com'.url);   // .url parses the string
```

**Delays are `Duration`**:

```dart
await util.time.wait(250.ms);
net.crawl<String>(url).delay(2.s);
```

`.ms`, `.s` and `.m` produce ordinary `Duration` values, usable anywhere one is accepted.

---

## Domain Tour

### `io` — files, atomically

`io` itself is about **one file**. Paths are `io.path`, directories are
`io.dir`, and each is a vocabulary of its own rather than a dozen more names on
one accessor.

```dart
io.write('out/notes.txt', 'hello');        // text
io.save('out/blob.bin', [1, 2, 3]);        // bytes
io.dump('out/data.json', {'count': 42});   // JSON, atomically
io.append('out/run.log', 'done\n');        // the one write that is not atomic
final data = await format.json.read('out/data.json');   // -> Json cursor

io.exists(path);  io.isfile(path);  io.isdir(path);  io.islink(path);
io.size(path);    io.empty(path);   io.stat(path);   // -> FileSystemEntry?
io.has(path);                                        // exists and non-empty
io.hash(path, Algo.md5);

io.lines(path);                            // a lazy Sequence<String>
io.lines.write('out/hosts.txt', hosts.keys);   // one per line, atomically
io.chunks(path, size: 4096);               // Sequence<List<int>>, lazily
io.temp('render_');                        // a temporary *file*
final log = io.append.open('out/run.log'); // one descriptor for many appends

io.path.join('a', 'b', 'c.txt');
io.path.dirname(path);  io.path.filename(path);  io.path.stem(path);

io.dir.make('out/reports');
io.dir.list('out');                        // one level -> Sequence<FileSystemEntry>
io.dir.walk('src', match: '**/*.dart');    // the whole tree, a glob
io.dir.walk('out', only: .file, match: '*.mp3');
io.dir.sweep('out', match: '*.part');      // and how many went
io.dir.size('out');                        // the recursive byte total
io.dir.empty('out');                       // the directory question
io.dir.link('out/latest', 'run-2026-09-11');
```

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
  if (entry.ext == '.part') io.remove(entry.path);
}
```

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
  net.crawl<Map<String, Object?>>(seed).flow(),
  headers: ['name', 'price'],
);
```

See [lib/io/io.dart](lib/io/io.dart), [lib/io/csv.dart](lib/io/csv.dart), [lib/collection/collection.dart](lib/collection/collection.dart).

### `net.http` — requests, and the codec seam

```dart
final res = await net.http.get('https://example.com'.url);

// `net` fetches bytes; `format` reads them. One member, and it names no
// format, which is what lets one crawl handle more than one.
final page = res.parse(format.html);
page.find('h1').text;                    // text of first h1
page.find('a').attrs('href');                    // all hrefs

res.parse(format.json).at('data.total').number();   // the other format

// Typed extraction: a record, with every field's type intact.
final item = (
  title: page.find('h1.title').text,
  price: page.pick(Field.text('.price').when(util.text.number)),
  variants: page.all('.variant', (row) => (
    name: row.find('.name').text,
    sku: row.attr('data-sku'),
  )),
);
item.variants.collect(.first())?.sku;   // String?, no cast

// The string shorthand, for a first look at an unfamiliar page:
final loose = page.extract({'title': 'h1.title', 'links': ['a.link@href']});

// Stateful session with cookies:
final session = Fetcher(session: true);

await net.http.post(url, body: const Body.json({'id': 1}));
await net.http.download(url, 'out/file.zip');
```

Retries cover transport errors, 5xx and 429, honouring `Retry-After`. See [lib/net/http.dart](lib/net/http.dart).

### `net.crawl` — multi-stage pipelines

```dart
const name = Slot<String>('name');

await net.crawl<String>('https://music.example.com/album'.url)
    .concurrent(4)
    .limit(50)
    .depth(2)
    .tag('song', (res) {
      print('${res.meta.read(name)} -> ${res.parse(format.html).find('a').attr('href')}');
    })
    .run((res) {
      res.parse(format.html).find('#songlist a').elements.collect(.foreach((a) {
        res.follow(
          a.attr('href')!,
          tag: 'song',
          meta: [name(a.text)],
        );
      }));
    });
```

`follow` resolves relative URLs, sets a `Referer`, and de-duplicates — and takes a `method` and `body`, so a form is followed the way a link is. Finish with `run` (stats), `collect` (a list), `stream` (items as they arrive) or `save` (straight to a file).

A crawl that has to survive the real world adds four things:

```dart
await net.crawl<String>(seed)
    .resume('crawl.state')      // carry on where an interrupted run stopped
    .cache('.cache')            // reuse pages that have not changed
    .accept(['text/html'])      // never hand a PDF to the HTML parser
    .on.error((f) => log.warn('${f.fetch?.url}: ${f.error}'))
    .run(handler);
```

See [lib/net/crawl.dart](lib/net/crawl.dart).

### `Form` — the forms a page carries

Reading a page is half of it. `Markup.form(...)` collects a form's controls the
way a browser would submit them — the hidden inputs, the CSRF token, the
options already selected — so a script overrides the two fields it knows about
and sends the rest back untouched:

```dart
final session = Fetcher(session: true);
final res = await session.get('https://example.com/login'.url);

final home = await res.parse(format.html).form('#login')!
    .at(res.url)
    .fill({'user': user, 'pass': pass})
    .send(client: session);
```

Finding a form is reading a page, so it hangs off the cursor; sending it is a
socket, so that stays in `net`. `at` tells the form which URL its markup came
from, which a cursor cannot know — inside a crawl, `res.submit(form)` does it
for you.

Inside a crawl, `res.submit(form)` schedules it on the engine instead, so the
answer reaches a tagged handler like any other page. See
[lib/net/form.dart](lib/net/form.dart).

### `format.html` — selectors

```dart
// setup: const markup = '<ul><li class="track" data-id="1">'
// setup:     '<a href="/t/1">Track One</a></li></ul>';
format.html.parse(markup).find('.track a').texts;
res.parse(format.html).find('.title').at(0).text;

// The jQuery spelling, opt-in via package:dart_toolkit/html.dart:
$(markup).find('.track a').texts;
markup.$('.track').attrs('data-id');
```

See [lib/src/markup.dart](lib/src/markup.dart).

### `system` — subprocesses and shutdown

```dart
final res = await system.run('git', ['status', '--short']);
if (res.ok) print(res.out);

system.which('ffmpeg');
system.env.get('PORT', 8080);
system.on.exit(() => db.dump('out/state.json'));    // and track, adopt, signals
await system.shutdown();
```

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
  (url) async => (await net.http.get(url)).parse(format.json),
  size: 8,
);
```

Results keep input order. The first failure propagates with its own error and stack; register `Pool.on.error` to collect failures and continue instead, or use `Pool.settle`, which returns a sealed `Done`/`Broke` per item and never throws. See [lib/concurrent/concurrent.dart](lib/concurrent/concurrent.dart).

### `format.*` — one name per format

Every codec is spelled identically — `parse`, `read`, `format` — and every one
implements `Codec`, which is what `res.parse(...)` takes:

```dart
final pubspec = await format.yaml.read('pubspec.yaml');
pubspec.text('version');                          // no cast
pubspec.jsonpath(r'$..sdk').transform(.map.nonnull((n) => n.text()));

format.json.parse(res.body).at('data.items').all((i) => i.text('sku'));
format.html.parse(res.body).find('h1').text;      // the same three members
format.csv.parse(res.body).column('sku');         // and CSV, since 5.2.0
io.write('out.yaml', format.yaml.format({'name': 'x'}));
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
await format.zip.read('site.zip', 'index.html');
```

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

The same vocabulary over a source that arrives a piece at a time — a `Flow` is what this library returns in place of a `Stream`. Its two members are named after what they take, so the container is visible at every step:

```dart
await io.async.csv.records('big.csv')
    .pipe(.where((r) => r['live'] == 'yes'))
    .pipe(.take.first(1000))
    .pour(.count.by((r) => r['host']));

// bounded async work over a source too large to hold, which
// `concurrent.run` cannot take
await io.async.lines('urls.txt')
    .pipe(.map.async((line) => net.http.get(line.trim().url), size: 8))
    .pour(.count());
```

A `Pipe` also carries what only makes sense over time, none of which had a spelling before: `map.async`, `where.async`, `flat.async`, `chunk.time`, `debounce`, `throttle`, `merge`, `timeout`, `handle`, `tap` — and a binary operand that is itself a `Flow`, so two files zip line by line.

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
// setup: final clock = util.time.clock();
util.time.format(clock.elapsed);      // '02:15'
util.size.format(5242880);            // '5.0 MiB'
util.text.slug('Hello, World!');      // 'hello-world'
util.text.number(r'$1,234.50');       // 1234.5
util.hash.short(url);                 // an 8-character cache key
util.rand.jitter(1.s);                // 1.0s..1.25s
```

See [lib/util/util.dart](lib/util/util.dart).

---

## Testing Your Pipelines

Hand the crawl a `MapDownloader` of fixtures instead of reaching the network:

```dart
final titles = await net.crawl<String>('https://site.test'.url)
    .downloader(MapDownloader({'https://site.test': '<h1>Hi</h1>'}))
    .items((res) => res.emit(res.parse(format.html).find('h1').text));
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
| Crawler engine | [lib/net/crawl.dart](lib/net/crawl.dart) |
| Forms | [lib/net/form.dart](lib/net/form.dart) |
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
