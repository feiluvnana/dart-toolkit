# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.8%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A toolkit for Dart scripts: processes, files, archives, images, documents, HTTP, crawling, a real
browser, torrents, a CLI framework and terminal apps. One way to do each thing, every part plugs
into every other, and a script starts fast.

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

Import the topics you use; each brings `core` and what its own API hands out.

| Import                  | Holds                                                                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `core.dart`             | `Task`, `Batch` and `parallelize`, `Status`, `Work`, `Retry`, `Cancel`, `Clock`, `Store`/`Key`, `Secret`, `Env`, `Io`, `Path` (the type), `60.s` |
| `path.dart`             | `Path`'s parts and files: read, write, list, copy, move, rename plans, watch, lock                                                               |
| `archive.dart`          | zip, 7z, rar, tar.\*; gz, xz, zst, bz2                                                                                                           |
| `hash.dart`             | `Hash` (digests, MACs), `Digest`, `Secure`, hex/base32/base64                                                                                    |
| `async.dart`            | `Worker`, `Pool`, `Job` (pause, resume, detached), stream operators, `Semaphore`                                                                 |
| `process.dart`          | `Shell.run`, `Command` pipelines, `Shell.interact`, `Shell.which`                                                                                |
| `json.dart`             | `Doc`: JSON, YAML, TOML, INI; JSONPath                                                                                                           |
| `html.dart`, `xml.dart` | `Html`, `Xml`, `Selection`, CSS `$` and XPath `$x`                                                                                               |
| `collection.dart`       | `Table`: CSV, TSV, NDJSON, JSON, Markdown                                                                                                        |
| `http.dart`             | `url.get()`, `Http.scope`, `download`, cookies, events, `Client.fake`                                                                            |
| `scrape.dart`           | `url.crawl`, `Crawler`, robots.txt, sitemaps                                                                                                     |
| `chrome.dart`           | `Chrome`, `Page`: a real browser, as a client or by hand                                                                                         |
| `image.dart`            | `Image`, `compress` (the smallest file that looks the same), `similar`                                                                           |
| `torrent.dart`          | `Torrent` (`Metainfo`, `Magnet`), `TorrentClient`                                                                                                |
| `cli.dart`              | `Cli`, typed `Option`/`Arg`, `Console`, `show`                                                                                                   |
| `tui.dart`              | `Tui.run` terminal apps, widgets                                                                                                                 |
| `native.dart`           | `Native.check()`, `Native.install()`                                                                                                             |

The only runtime dependency is `path`. Hashing, archives, images and the torrent engine run in
native libraries: the first call that needs one downloads this platform's build from the release
of the Rust sources it ships with (checked against its SHA-256), else compiles it with `cargo`.

---

## The model, in one screen

Every operation gives one of four shapes: a **value** (instant), a **`Task<T>`** (one result), a
**`Batch<I, T>`** (many), or a **`Stream`** (endless). A `Task` _is_ a `Future` and reports its
`Status`; a `Batch` _is_ a `Future<List<T>>`, made by `parallelize`.

```dart
final file  = await url.download(into: 'out');                          // a Path, or it throws
final files = await urls.parallelize((u) => u.download(into: 'out')).show('Images');
switch (await url.download(into: 'out').settled) {                      // look, never throw
  case Done(:final value, fresh: false): print('already had $value');
  case Done(:final value): print('saved $value');
  case Failed(:final error): print('no: $error');
  case _:
}
```

- **`await` is success or throw;** `.settled` never throws. A batch throws once, at the end, a
  `BatchException` holding every failure and every success.
- **A cancel is `Stopped`,** thrown once as `CancelledException`, never a failure.
- **Cleanup is `work.defer`,** in every body you write; it runs however the work ends.
- **What remembers takes `store:`** (default: memory). **Credentials are `Secret`s.**
- **Defaults are the same everywhere:** 4 at a time, network requests retried twice, 30 s per
  response, a file already there skipped (`Done(fresh: false)`), atomic writes.

---

## Work

**I want to run my own work as a task, with progress and cleanup.**

```dart
final task = Task.run('Render', (work) async {
  final chrome = await Chrome.launch();
  work.defer(chrome.close);                        // always runs, however the task ends
  work.step('rendering');
  return (await chrome.open(url)).screenshot();
});
final png = await task;
```

A task made inside another work's body is part of it: return `url.download(…)` from a body and the
download's progress is the body's. `task.cancel()` stops it.

**I want many items at once, a few at a time.**

```dart
final sizes = await files.parallelize((f) => f.size(), concurrency: 8);
final pages = await urls.parallelize((u) => u.get().html, retry: Retry(3), timeout: 1.m).show('Fetching');
await for (final page in urls.parallelize((u) => u.get().html).values) { print(page.$('title').texts); }
```

Values come back in input order; `.values` streams them as they finish. A timeout cancels the item
and frees its slot. `isolate: true` runs the work on other isolates.

**I want to try again, cancel, or time things.**

```dart
final data = await Retry(3, backoff: 1.s).run(() => api.get().json);
await Cancel.scope(() => work(), timeout: 5.m);
final clock = Clock.fake();                        // tests: retries and timeouts in no time
final done = Clock.scope(() => Retry(3, backoff: 1.m).run(() => api.get().text), clock: clock);
await clock.advance(10.m);
```

Every retry is a `Warned(RetryWarning(…))`. An error an inner retry gave up on is never retried by
an outer one.

**I want state that survives a rerun.**

```dart
final app = Store.app('books');                    // the OS's app-data folder
const seen = Key<List<String>>('seen', or: []);
final ids = await app.read(seen);
await app.update(seen, (ids) => [...ids, 'b-42']);  // under the store's lock
await (app / 'crawl').clear();                     // start over
```

Writes are atomic and the lock holds across processes. A type JSON can't carry names its
`Serializer`. `DART_TOOLKIT_STORE` moves every `Store.app` (tests, portable installs).

**I want a pool of workers with setup, or jobs I can pause.**

```dart
final thumbnails = Pool(Thumbnail.new, concurrency: 4);
await thumbnails.map(images).show('Thumbnails');
final job = thumbnails.add(cover);                 // a Job: a Task you can control
job.pause(); job.resume();
await thumbnails.close();
```

`Worker` has two methods, `init(Work setup)` and `run(item, work)`; cleanup is `defer`. Adding an
equal unfinished item returns the existing job.

**I want jobs to outlive the program.**

```dart
final downloads = Pool(FetchBook.new, store: Store.app('books') / 'downloads');

Future<void> run(List<String> args) => Cli('Books.', pools: [downloads], handler: (ctx) async {
  downloads.add(book, detached: true);             // runs in a runner process
}).run(args);
```

The runner is this program started again; it serves the pools in `pools:` and ends when nothing is
left. Without `Cli`, `await Pool.serve([downloads])` is the first line of `main`.

**I want to shape a stream.**

```dart
events.chunk(size: 100, every: 1.s);   clicks.debounce(300.ms);   users.unique((u) => u.id);
[a, b, c].merge(concurrency: 2);
final gate = Semaphore(4);
await gate.run(() => api.get().text);
```

---

## Files and archives

**I want to read and write files.**

```dart
await Path('conf.json').writeText(text);           // atomic: a sibling renamed over it
final head = await Path('big.bin').readBytes(end: 4096);
await for (final line in Path('huge.log').lines()) { print(line); }
await Path('app.log').appendText('started\n');
```

**I want to find files.**

```dart
await for (final f in dir.files(only: '**/*.mp3', ignore: ['node_modules/'], hidden: false)) { print(f); }
final newest = await dir.files(only: '*.log', order: Order.newest).first;
```

`**` is recursive. Links are listed, never followed. A missing folder is a `PathNotFoundException`.

**I want to copy or move.**

```dart
await Path('report.pdf').copy(into: 'backup');            // backup/report.pdf
await Path('photos').copy(to: '/Volumes/usb/photos').show('Copying');
await Path('done.txt').move(into: 'archive', conflict: Conflict.rename);
```

Exactly one of `to:` (the new path) or `into:` (a folder). A rerun skips what is there; folders
merge, and `conflict:` settles each file. A stopped copy leaves no half file; an overwrite renames
over the old file, never deletes it first.

**I want to rename many files.**

```dart
final plan = await dir.files(only: '*.JPG').plan((f) => f.withExt('jpg').name);
print(plan);                                       // what would happen
await plan.apply().show('Renaming');
await plan.undo();
```

**I want to follow a log, watch a folder, or hold a lock.**

```dart
await for (final line in Path('app.log').tail()) { print(line); }   // follows rotation
await for (final change in Path('lib').changes(debounce: 200.ms)) { print(change.all); }
await Path('job.lock').lock(() async => print('mine'), wait: false);
```

**I want to zip a folder or unpack an archive.**

```dart
await Path('site').archive(to: 'site.tar.zst', only: '**/*.html', level: 19);
await Path('x.zip').unarchive(into: 'out', password: await Console.secret('Password'));
final archive = await Archive.read('x.zip');
final readme = await archive.entry('docs/readme.md');     // MissingException if absent
```

The format is the extension. Archives are built beside the destination and renamed over it;
extraction is staged and moved in, so a failure leaves both as they were. No entry escapes the
folder unless `unsafe: true`.

**I want a checksum or a MAC.**

```dart
final d = await Hash.sha256.file('disc.iso').show('Hashing');
if (!d.matches(published)) throw const FormatException('Invalid checksum for disc.iso');
final mac = Hash.sha256.text(body, key: Env.get<Secret>('HOOK_SECRET'));
```

---

## Documents

**I want typed values from a config file.**

```dart
final cfg = await Doc.read('config.yaml');                // .json .yaml .toml .ini
final port = cfg['server']['port'].to(or: 8080);
final merged = cfg.merge(await Doc.read('local.toml'));
```

A missing key is `Missing $.server.port in config.yaml`; a wrong value is a `FormatException`,
which `or:` does not answer.

**I want to edit a document and save it in another format.**

```dart
final doc = await Doc.read('settings.json');
doc['theme'] = 'dark';
await doc.save('settings.toml');
print(doc.encode(DocFormat.yaml));
```

**I want to scrape a page.**

```dart
final page = await url.get().html;
final titles = page.$('h2 a').texts;
final links = page.$('h2 a').links;                       // resolved against the page
final row = page.$x('//tr[td[1]="FLAC"]').first;          // XPath comes with html.dart
await url.get().html.save('copy.html');
```

`text` is what a reader sees; `rawText` is the markup's text. Plurals have one entry per match.

**I want to query a CSV.**

```dart
final t = await Table.read('sales.csv');
final top = t.where((r) => r.get<num>('price') > 10).orderBy('price', descending: true).take(10);
await top.show();
await t.groupBy(['region']).agg({'total': Agg.sum('price')}).save('totals.md');
await Table.lines('big.csv').where((r) => r.get<num>('price') > 10).pipe(Table.writer('out.csv'));
```

**I want text checked where I write it.**

```dart
final songs = '**/*.{mp3,flac}'.glob;                     // a FormatException here if malformed
await Path('run.sh').chmod('755'.mode);
final ids = r'$.items[*].id'.jsonPath;
```

`Mode`, `Glob`, `Css`, `XPath`, `JsonPath`, `Hex` and `Mime` are `String`s: plain text works
wherever they go, and these check it early.

---

## The network

**I want to fetch a page or an API.**

```dart
final page = await url.get().html;                        // throws StatusException unless 2xx
final data = await api.post(json: {'q': 'dart'}).json;
if (!await url.head().isOk) print('gone');
```

**I want settings for a block of requests.**

```dart
await Http.scope(() => urls.parallelize((u) => u.get().text),
    headers: {'user-agent': 'me/1'}, credentials: {'https://api.x': Secret('Bearer x')},
    retry: Retry(5), perHost: 4, delay: 250.ms, store: Store.app('me') / 'http', cache: 1.d);
```

The same defaults apply without a scope. A scope holds until its body's result has finished.
Credentials never leave their origin.

**I want to download files.**

```dart
await url.download(into: 'out');
await url.download(to: 'sdk.zip', checksum: Checksum(Hash.sha256, digest), segments: 4);
await urls.parallelize((u) => u.download(into: 'out'), concurrency: 8).show('Files');
```

A file already there is `Done(fresh: false)`. A stopped download keeps its `.part` and a rerun
resumes it; an HTML error page is never saved as `report.pdf`.

**I want to crawl a site.**

```dart
final crawl = url.crawl<String>(depth: 3, robots: true, store: Store.app('me') / 'crawl', onResponse: (ctx) {
  for (final a in ctx.html.$('h2 a')) { ctx.emit(a.text); }
  ctx.follow(ctx.html.$('.next').firstOrNull?.link);
});
await crawl.show('Crawling');
final titles = await crawl.items.toList();
```

A page is `Done(page, items)`, `Skipped(page, 'robots' | 'outside')` or `Failed`. A rerun with the
same `store:` carries on.

**I want pages a browser renders.**

```dart
final chrome = await Chrome.launch(render: Render(wait: Wait.dom), block: Resource.heavy);
await Http.scope(client: chrome, () => url.get().html);
final tab = await chrome.open(login);
await tab.fill('#user', 'me');
await tab.expectNavigation(() => tab.click('button[type=submit]'));
await chrome.close();
```

**I want to test code that uses the network.**

```dart
await Http.scope(client: Client.fake((r) => Response('{"ok":true}', 200)), () => api.get().json);
```

---

## Processes

**I want a command's output, or to know whether it worked.**

```dart
final branch = await Shell.run('git rev-parse --abbrev-ref HEAD').text;   // or throws ShellException
if (await Shell.run('git diff --quiet').isOk) print('clean');
await Shell.run('make').show('Building');
await Shell.run('git commit -m', args: [message]);                       // never interpolate
```

**I want to stream output, pipe, or hand over the terminal.**

```dart
await for (final line in Shell.run('tail -f app.log').output) { print(line); }
await Shell.run('pg_dump db').save('db.sql');
await (Command('ls', ['-1']) | Command('wc', ['-l'])).run().text;
await Shell.sh(r'grep -c "$1" *.log | sort', args: [word]);
await Shell.interact('git commit');                                      // ^C is the child's
```

---

## Media

**I want to shrink photos without visible loss.**

```dart
await photos.parallelize((p) => p.compress()).show('Compressing');
await Path('big.jpg').compress(quality: Quality.under(500 << 10), format: ImageFormat.webp);
```

`Quality.visual(85)` by default: the smallest file whose SSIMULACRA2 score reaches 85. The result is
in place before the original goes to the trash.

**I want to edit an image.**

```dart
final img = await Image.read('photo.jpg', maxSide: 2048);     // upright
await img.resize(width: 800).cropSmart(16 / 9).save('out.webp', quality: Quality.visual(90));
await img.close();
```

**I want to download or make a torrent.**

```dart
final t = await Torrent.read('ubuntu.torrent');
await t.download(into: 'iso').show('Ubuntu');
final made = await Torrent.create('dist').show('Hashing');
```

A long-running `TorrentClient.start(into:, store:)` gives `TorrentJob`s you can pause, resume and
read while they download.

---

## The terminal

**I want a command-line program.**

```dart
final top = Option.of<int>('top', 'How many to show', short: 'n').or(10);
final inputs = Arg.of<Path>('files', 'Inputs').many().required();

Future<void> program(List<String> args) => Cli('Shows the files.', version: '1.0.0', values: [top, inputs],
    handler: (ctx) async {
      for (final f in ctx(inputs).take(ctx(top))) { Console.line(f); }
    }).run(args);
```

`-h`, `-v`, `-q`, `--version`, `--completion` are built in and yield to your names. Throw
`UsageException` for exit 64; anything else exits 1 with one line. `ctx.defer` runs when the run
ends; `ctx.store` is the program's `Store.app`. Test with `await cli.test([...])`.

**I want to show progress, log, and ask.**

```dart
final bar = Console.bar('Crawling', count: links.length);
for (final l in links) { bar.tick(label: l.path); }
await bar.close();
Console.info('found 3'); Console.warn('slow');
final name = await Console.ask<String>('Name');
final pw = await Console.secret('Password');
```

Everything drawn goes to stderr, so `app --json | jq` gets only data. Without a terminal each item
writes one line.

**I want a terminal app.**

```dart
final n = await Tui.run<int, String>(0,
    view: (n) => VStack([Label('Count: $n'), Button('Add', message: 'add')]),
    update: (n, e) => switch (e) { Sent() => n + 1, KeyPress.esc => Tui.quit(n), _ => n },
    mouse: true);
```

Widgets include `Field` (multi-line, suggestions), `Button`, `Clickable`, `Popup`, `Tooltip`,
`Board(tally)`, `Markdown` and `Picture`. Test on `Io.scope(…, terminal: FakeTerminal())`.

---

## Examples

- [`example/puremedia`](example/puremedia): albums mirrored one at a time: parts found through
  Chrome, downloaded, extracted and compressed in parallel; a rerun picks up where it stopped.
- [`example/annasarchive`](example/annasarchive): a terminal app that finds books by name, with
  downloads as detached jobs.
- [`example/keybox`](example/keybox): crawl, download what's new, zip.

Plain `dart run` recompiles what a script imports on every start. `dart run -r script.dart` keeps
the compiler resident, and a script in a package's `bin/` run as `dart run :script` starts from
pub's snapshot.

[`CONVENTIONS.md`](CONVENTIONS.md) has the rules; [`CHANGELOG.md`](CHANGELOG.md) the releases and
the upgrade tables. MIT — see [LICENSE](LICENSE).
