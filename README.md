# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.7%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A cohesive automation and web-scraping toolkit for Dart, developed by **feiluvnana**. Built for writing clean command-line scripts, with **lowercase, preferably one-word methods** and **hierarchical domain namespaces**.

### Domains

| Domain | Sub-namespaces | Focus |
| :--- | :--- | :--- |
| **`io.*`** | `io.csv.*`, `io.store.*`, `io.async.*` | Atomic file writes, paths, CSV tables, JSON key-value store |
| **`net.*`** | `net.http.*`, `net.crawl` | HTTP requests, streaming downloads, the crawler engine |
| **`system.*`** | `system.env.*`, `system.cli.*`, `system.console.*`, `system.on.*` | Subprocesses, environment, CLI args, terminal IO, shutdown |
| **`concurrent.*`** | `concurrent.run(...)` | Bounded async task pools |
| **`git.*`** | — | Repository queries and commands |
| **`zip.*`** | — | Packing, unpacking and inspecting archives |
| **`util.*`** | `util.time.*`, `util.size.*`, `util.text.*`, `util.hash.*`, `util.rand.*` | Pure helpers: delays, byte sizes, text, digests, randomness |
| **`$()`** | — | jQuery-like CSS selectors |

**Where things live.** `util` holds only pure computation — nothing there touches
the disk or the operating system. Anything that reads or writes files is `io`;
anything that talks to the OS or the user is `system`. `git` and `zip` stand on
their own because they are self-contained tools with their own vocabulary, and
their names are distinctive enough not to crowd yours.

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

---

## Quickstart

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  // 1. Arguments
  system.cli.parse(args);
  final size = system.cli.get('concurrency', 4);
  final force = system.cli.has('force', 'f');

  final log = system.console.logger;
  final clock = util.time.clock();

  // 2. Crawl and collect
  log.step(1, 3, 'Crawling headlines...');
  final titles = await net.crawl<String>('https://news.ycombinator.com')
      .concurrent(size)
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
  }, size: size);
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
  if (force || !io.has(dest)) {
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
net.crawl<String>(url).delay(2.seconds);
```

`.ms`, `.seconds` and `.minutes` produce ordinary `Duration` values, usable anywhere one is accepted.

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
io.hash(path, Digest.md5);
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

// Declarative extraction:
final item = res.extract({
  'title': 'h1.title',
  'price': '.price@text',
  'links': ['a.link@href'],
});

// The same, keeping the type:
final String? title = res.pick(Field.text('h1.title'));
final List<String> links = res.pick(Field.attrs('a.link', 'href'));

// Stateful session with cookies:
final session = HttpClient(session: true);

await net.http.post(url, body: const Body.json({'id': 1}));
await net.http.download(url, 'out/file.zip');
```

Retries cover transport errors, 5xx and 429, honouring `Retry-After`. See [docs/http.md](docs/http.md).

### `net.crawl` — multi-stage pipelines

```dart
await net.crawl<String>('https://music.example.com/album')
    .concurrent(4)
    .limit(50)
    .depth(2)
    .tag('song', (res) {
      print('${res.meta['name']} -> ${res.$('a').href}');
    })
    .run((res) {
      for (final a in res.$('#songlist a')) {
        res.follow(
          a.href!,
          tag: 'song',
          meta: {'name': a.text},
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
    .on.error((f) => log.warn('${f.request?.url}: ${f.error}'))
    .run(handler);
```

See [docs/crawl.md](docs/crawl.md).

### `$()` — selectors

```dart
$(markup).find('.track a').texts;
markup.$('.track').attrs('data-id');
res.$('.title').at(0).text;
```

See [docs/selector.md](docs/selector.md).

### `system` — subprocesses and arguments

```dart
final res = await system.run('git', ['status', '--short']);
if (res.ok) print(res.out);

system.which('ffmpeg');
system.cli.get('concurrency', 4);
system.env.get('PORT', 8080);
```

Declare commands and `system.cli.run` parses, prints `--help`, validates and
dispatches, returning an exit code:

```dart
system.cli.handle('build', _build, desc: 'Build the project')
  ..option('out', alias: 'o', def: 'dist', desc: 'Output directory');

await system.shutdown(await system.cli.run(args));
```

See [docs/system.md](docs/system.md), [docs/cli.md](docs/cli.md), [docs/env.md](docs/env.md).

### `concurrent` — bounded async work

```dart
final bodies = await concurrent.run(
  urls,
  (url) async => (await net.http.get(url)).json,
  size: 8,
);
```

Results keep input order. The first failure propagates with its own error and stack; register `Pool.on.error` to collect failures and continue instead. See [docs/concurrent.md](docs/concurrent.md).

### `git` — repository automation

```dart
await git.branch();                // 'master'
if (await git.dirty()) return;     // uncommitted changes
await git.tag('v1.0.0');
```

See [docs/git.md](docs/git.md).

### `zip` — archives

```dart
await zip.pack('site', 'site.zip');          // or site.tar.gz, .tgz, .tar.bz2
await zip.unpack('site.zip', 'restored');    // skips zip-slip entries
await zip.list('site.zip');                  // without unpacking
await zip.read('site.zip', 'index.html');
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

Subclass `Downloader` to serve fixtures instead of reaching the network:

```dart
final titles = await net.crawl<String>('https://site.test')
    .downloader(MockDownloader({'https://site.test': '<h1>Hi</h1>'}))
    .collect((res) => res.emit(res.$('h1').text));
```

To swap the shared HTTP client process-wide, hand `net.use` your own:

```dart
await net.use(HttpClient(headers: {'Authorization': 'Bearer $token'}));
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

A runnable tour lives in [example/example.dart](example/example.dart).

---

## License

MIT — see [LICENSE](LICENSE).
