# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.7%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A cohesive automation and web-scraping toolkit for Dart, developed by **feiluvnana**. Built for writing clean command-line scripts, with **lowercase, preferably one-word methods** and **hierarchical domain namespaces**.

### Domains

Five of them are **axes** — a way of touching the machine:

| Domain | Sub-namespaces | Focus |
| :--- | :--- | :--- |
| **`io.*`** | `io.csv.*`, `io.store.*`, `io.async.*` | Atomic file writes, paths, CSV tables, JSON key-value store |
| **`net.*`** | `net.http.*`, `net.crawl` | HTTP requests, streaming downloads, the crawler engine |
| **`system.*`** | `system.env.*`, `system.console.*`, `system.on.*` | Subprocesses, environment, terminal IO, shutdown |
| **`concurrent.*`** | `concurrent.run(...)` | Bounded async task pools |
| **`util.*`** | `util.time.*`, `util.size.*`, `util.text.*`, `util.hash.*`, `util.rand.*` | Pure helpers: delays, byte sizes, text, digests, randomness |

Two are **subjects** — knowledge that came from outside Dart:

| Domain | Sub-namespaces | Focus |
| :--- | :--- | :--- |
| **`cli.*`** | — | Flags, options, subcommands, usage text |
| **`tool.*`** | `tool.git.*`, `tool.zip.*` | Wrapped executables and file formats |
| **`$()`** | — | jQuery-like CSS selectors |

**Where things live.** `util` holds only pure computation — nothing there touches
the disk or the operating system. Anything that reads or writes files is `io`;
anything that talks to the OS or the user is `system`. Argument parsing is
`cli` and not `system.cli`, because reading a `List<String>` touches nothing at
all. `git` and `zip` share `tool` rather than taking a name each, because a top
level that grows a name per wrapped binary is not a top level.

[NAMESPACE.md](NAMESPACE.md) is the full rule set: which domain something
belongs to, when it earns a top-level name, and how to name it.

---

## Design Philosophy

1. **Lowercase, preferably one word.** Every primary action is a single word: `run`, `get`, `post`, `save`, `write`, `dump`, `follow`, `emit`, `stop`, `step`, `ok`, `warn`, `ask`, `pick`, `which`, `clock`, `pack`, `slug`. Where one word genuinely will not do, the name stays lowercase rather than turning camelCase: `perhost`, `samehost`, `httponly`, `topleft`, `bgred`.
2. **One name per operation.** There are no aliases and no flat shortcuts. Each operation lives in the domain that owns it and is reachable exactly one way — so there is never a question of which spelling to use.
3. **Real types at every boundary.** URLs are `Uri`, delays are `Duration`, paths are `String`, bodies and hash algorithms are sealed types and enums. No `Object` or `dynamic` parameters, so the analyzer catches mistakes at the call site.
4. **Atomic by default.** Every write stages through a `.part` file and is renamed into place only after a successful flush. Interrupted runs never leave truncated files, and Ctrl-C cleans up.
5. **Engine-driven pipelines.** Multi-stage crawlers use declarative URL routing, tag-based stages, and automatic relative-URL resolution.

---

## Installation

Requires Dart 3.7 or newer.

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
  final titles = await net.crawl<String>('https://news.ycombinator.com')
      .concurrent(size())
      .delay(250.ms)
      .limit(50)
      .collect((res) {
        for (final title in res.$('.titleline > a').texts) {
          res.emit(title);
        }
      });
  log.ok('Found ${titles.length} headlines.');

  // 3. Process concurrently, with a progress bar
  log.step(2, 3, 'Processing...');
  final batch = titles.take(10).toList();
  final bar = Progress(total: batch.length, message: 'Processing');
  final processed = await concurrent.run(batch, (title) async {
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: size());
  bar.done('Done.');

  // 4. Report and save atomically
  log.step(3, 3, 'Saving...');
  system.console.writer.table(
    Table(headers: ['Metric', 'Value'])..addAll([
      ['Crawled', titles.length],
      ['Processed', processed.length],
      ['Elapsed', util.time.format(clock.elapsed)],
    ]),
  );

  final dest = io.join('output', 'summary.txt');
  if (force() || !io.has(dest)) {
    io.write(dest, processed.join('\n'));
    log.ok('Saved to $dest');
  }
}
```

This script exits on its own when it finishes — no manual cleanup call is needed.

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

```dart
io.write('out/notes.txt', 'hello');        // text
io.save('out/blob.bin', [1, 2, 3]);        // bytes
io.dump('out/data.json', {'count': 42});   // JSON
final data = io.json<Map<String, Object?>>('out/data.json');

io.has(path);                                    // exists and non-empty
io.join('a', 'b', 'c.txt');
io.hash(path, Algo.md5);
io.find('out', pattern: RegExp(r'\.mp3$'));
```

`io.*` blocks. `io.async.*` carries the same names as futures, which is what a
crawl handler or pool worker wants — one blocking read stalls every task in
flight:

```dart
await io.async.write('out/notes.txt', 'hello');
final text = await io.async.read('out/notes.txt');
await io.async.download(url, 'out/file.zip');
```

A crawl reaches a spreadsheet without passing through memory:

```dart
await io.csv.pipe('products.csv', crawl.stream(handler), headers: ['name', 'price']);
```

See [docs/io.md](docs/io.md), [docs/csv.md](docs/csv.md), [docs/store.md](docs/store.md).

### `net.http` — requests that scrape themselves

```dart
final res = await net.http.get('https://example.com'.url);

res.$('h1').text;      // text of first h1
res.$('a').hrefs;      // all hrefs
res.json;              // decoded and cached

// Typed extraction: a record, with every field's type intact.
final item = (
  title: res.$('h1.title').text,
  price: res.pick(Field.text('.price').when(util.text.number)),
  variants: res.$.all('.variant', (row) => (
    name: row('.name').text,
    sku: row.attr('data-sku'),
  )),
);
item.variants.first.sku;   // String?, no cast

// The string shorthand, for a first look at an unfamiliar page:
final loose = res.extract({'title': 'h1.title', 'links': ['a.link@href']});

// Stateful session with cookies:
final session = Fetcher(session: true);

await net.http.post(url, body: const Body.json({'id': 1}));
await net.http.download(url, 'out/file.zip');
```

Retries cover transport errors, 5xx and 429, honouring `Retry-After`. See [docs/http.md](docs/http.md).

### `net.crawl` — multi-stage pipelines

```dart
const name = Slot<String>('name');

await net.crawl<String>('https://music.example.com/album')
    .concurrent(4)
    .limit(50)
    .depth(2)
    .tag('song', (res) {
      print('${res.meta.get(name)} -> ${res.$('a').href}');
    })
    .run((res) {
      for (final a in res.$('#songlist a')) {
        res.follow(
          a.href!,
          tag: 'song',
          meta: [name(a.text)],
        );
      }
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

See [docs/crawl.md](docs/crawl.md).

### `Form` — the forms a page carries

Reading a page is half of it. `res.form(...)` collects a form's controls the
way a browser would submit them — the hidden inputs, the CSRF token, the
options already selected — so a script overrides the two fields it knows about
and sends the rest back untouched:

```dart
final session = Fetcher(session: true);
final page = await session.get('https://example.com/login'.url);

final home = await page.form('#login')!
    .fill({'user': user, 'pass': pass})
    .send(client: session);
```

Inside a crawl, `res.submit(form)` schedules it on the engine instead, so the
answer reaches a tagged handler like any other page. See
[docs/form.md](docs/form.md).

### `$()` — selectors

```dart
$(markup).find('.track a').texts;
markup.$('.track').attrs('data-id');
res.$('.title').at(0).text;
```

See [docs/selector.md](docs/selector.md).

### `system` — subprocesses and shutdown

```dart
final res = await system.run('git', ['status', '--short']);
if (res.ok) print(res.out);

system.which('ffmpeg');
system.env.get('PORT', 8080);
await system.shutdown();
```

See [docs/system.md](docs/system.md), [docs/env.md](docs/env.md).

### `cli` — the command line your script presents

```dart
final force = cli.flag('force', alias: 'f');
final size = cli.number('concurrency', def: 4);
cli.parse(args);

if (force()) rebuild(concurrency: size());
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

See [docs/cli.md](docs/cli.md).

### `concurrent` — bounded async work

```dart
final bodies = await concurrent.run(
  urls,
  (url) async => (await net.http.get(url)).json,
  size: 8,
);
```

Results keep input order. The first failure propagates with its own error and stack; register `Pool.on.error` to collect failures and continue instead, or use `Pool.settle`, which returns a sealed `Done`/`Broke` per item and never throws. See [docs/concurrent.md](docs/concurrent.md).

### `tool.git` — repository automation

```dart
await tool.git.branch();                // 'master'
if (await tool.git.dirty()) return;     // uncommitted changes
await tool.git.mark('v1.0.0');          // creates a tag; `tag()` reads one
```

See [docs/git.md](docs/git.md).

### `tool.zip` — archives

```dart
await tool.zip.pack('site', 'site.zip');          // or site.tar.gz, .tgz, .tar.bz2
await tool.zip.unpack('site.zip', 'restored');    // skips zip-slip entries
await tool.zip.list('site.zip');                  // without unpacking
await tool.zip.read('site.zip', 'index.html');
```

See [docs/zip.md](docs/zip.md).

### `util` — pure helpers

Nothing here touches the disk or the OS; that is what keeps it small.

```dart
util.time.format(clock.elapsed);      // '02:15'
util.size.format(5242880);            // '5.0 MB'
util.text.slug('Hello, World!');      // 'hello-world'
util.text.number(r'$1,234.50');       // 1234.5
util.hash.short(url);                 // an 8-character cache key
util.rand.jitter(1.s);                // 1.0s..1.25s
```

See [docs/util.md](docs/util.md).

---

## Testing Your Pipelines

Hand the crawl a `MapDownloader` of fixtures instead of reaching the network:

```dart
final titles = await net.crawl<String>('https://site.test')
    .downloader(MapDownloader({'https://site.test': '<h1>Hi</h1>'}))
    .collect((res) => res.emit(res.$('h1').text));
```

To swap the shared HTTP client process-wide, hand `net.use` your own:

```dart
await net.use(Fetcher(headers: {'Authorization': 'Bearer $token'}));
```

See [docs/crawl.md](docs/crawl.md#8-testing-a-pipeline).

---

## Documentation

| Domain | Reference |
| :--- | :--- |
| Files & paths | [docs/io.md](docs/io.md) |
| CSV tables | [docs/csv.md](docs/csv.md) |
| Key-value store | [docs/store.md](docs/store.md) |
| HTTP & downloads | [docs/http.md](docs/http.md) |
| Crawler engine | [docs/crawl.md](docs/crawl.md) |
| Forms | [docs/form.md](docs/form.md) |
| Selectors | [docs/selector.md](docs/selector.md) |
| Subprocesses & shutdown | [docs/system.md](docs/system.md) |
| CLI arguments | [docs/cli.md](docs/cli.md) |
| Environment & `.env` | [docs/env.md](docs/env.md) |
| Concurrency | [docs/concurrent.md](docs/concurrent.md) |
| Terminal IO | [docs/console.md](docs/console.md) |
| Time, sizes, text, hashing, randomness | [docs/util.md](docs/util.md) |
| Git automation | [docs/git.md](docs/git.md) |
| Archives | [docs/zip.md](docs/zip.md) |
| Namespace & naming rules | [NAMESPACE.md](NAMESPACE.md) |

A short runnable script per use case lives in [`example/`](example/), with
[example/example.dart](example/example.dart) putting them together as one
pipeline.

---

## License

MIT — see [LICENSE](LICENSE).
