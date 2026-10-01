# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.8%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A toolkit for Dart scripts — processes, files, formats, HTTP, scraping, a real browser, a CLI
framework — built for short scripts that start fast. This is the tour; [`GUIDE.md`](GUIDE.md)
is the manual.

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

```dart
import 'package:dart_toolkit/dart_toolkit.dart';   // every module but chrome.dart and tui.dart
```

| Import | Holds |
|---|---|
| `core.dart` | `Either`, `Env`, `Io`, durations (`60.s`) |
| `async.dart` | `parallelize`, `Worker`/`Pool`, `retry`, `Semaphore`, `Cancel.scope`, stream operators |
| `collection.dart` | `Sequence` (lazy queries), `Table` (CSV, JSON, Markdown, console) |
| `formats.dart` | `JsonDocument` for JSON/YAML/TOML/INI; one HTML/XML tree with CSS `$` and XPath `$x` |
| `fs.dart` | `Path`, archives (zip, 7z, rar, tar.*), compression |
| `hash.dart` | digests, checksums, HMAC, encodings, `Secure` |
| `process.dart` | `run`, pipelines, `which`, `Shell.scope` |
| `http.dart` | requests, `Http.scope`, `IoClient`, crawling, downloads |
| `chrome.dart` | `ChromeClient`, `ChromePage` — **not in the barrel**; import it by name |
| `cli.dart` | `Cli`, typed `Opt`/`Arg`, `Console`, `Lifecycle` |
| `tui.dart` | `Tui.run`/`Tui.inline` terminal apps, widgets, keys — **not in the barrel** |
| `native.dart` | `NativeLib`, the loader for the bundled Rust library |

The only runtime dependency is `path`. Hashing, archives, content decoding and legacy charsets
run in a Rust library shipped prebuilt for macOS (arm64, x64) and Linux (x64, arm64); no Windows
build yet. Without it, those calls throw `UnsupportedError` (`NativeLib.reason` says why).

---

## Tour

### Processes

```dart
final branch = await run('git branch --show-current').text;     // quiet, trimmed
if (await run('git diff --quiet').isOk) print('clean');         // an answer, not a throw
await run(r'ls *.dart | wc -l', shell: true);                   // a real /bin/sh
await run('git commit -m', args: [message]);                    // never re-parsed
await run('vim notes.txt', inherit: true);                      // interactive child
final piped = await ('git ls-files' | 'wc -l').run().text;

await Shell.scope(workdir: repo, timeout: 30.s, () async {      // settings for every run inside
  await run('git fetch --all');
});
```

The getter sets the policy: `.text`/`.lines` imply `quiet`, `.isOk` implies `strict: false`. A
cancel or timeout stops the whole process tree.

### HTML and XML

```dart
final doc = await url.get().html;                               // or '<p>…</p>'.html
final title = doc.$('h1').text;
final links = doc.$('td.title > a').links;                      // List<Uri>, resolved
final items = doc.$('ul').first.$('> li.x');                    // relative to the element
final flac = doc.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;  // XPath 1.0
final price = doc.$('th:contains(Price) + td').text;
final lines = doc.$('article').lines;                           // block-aware text
final table = doc.$('table#songs').table;                       // a Table
```

### Formats

JSON, YAML, TOML and INI decode to one `JsonDocument`.

```dart
final pubspec = await JsonDocument.read('pubspec.yaml');        // parser by extension
final deps = pubspec.$(r'$.dependencies.*').length;             // JSONPath
final port = configText.toml['server']['port'].to<int>();       // or StateError naming $.server.port
final debug = iniText.ini['debug'].or(false);                   // absence expected
final tags = pubspec['topics'].to<List<String>>();
await pubspec.save('pubspec.json');
```

### Paths and archives

`Path` is an extension type over `String`.

```dart
final dir = Path.temp / 'project';
await dir.archiveTo('${dir.path}.tar.zst');                     // format from the extension
await 'download.bin'.path.extractTo('out', only: '**/*.txt');   // format from the magic number
final readme = await 'release.zip'.path.entry('README.md');     // one entry, no extraction
if (await 'cache.json'.path.olderThan(1.h)) await refresh();    // true when missing
await for (final batch in 'src'.path.changes()) print(batch);   // debounced watch
```

Extraction treats an archive as untrusted (no setuid, no escaping links, a 200× size cap);
`trusted: true` lifts that.

### Collections

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc).thenBy((t) => t.number)
    .take(10);

final t = await Table.read('sales.csv');                        // CSV, TSV, JSON, NDJSON
t.where((r) => r.number('size') > 1e6).orderBy('disc').select(['title', 'size']).show();
```

### Hashing

`hash`, `checksum` and `hmac` work on a `String`, a `List<int>` or a `Path`.

```dart
'abc'.hash(Hash.sha256);
await file.hash(Hash.blake3);                                   // every core
final digests = await files.hash(Hash.xxh3);                    // Map<Path, String>, parallel
final dupes = await 'photos'.path.duplicates();                 // List<List<Path>>
Secure.token(); bytes.hex; '6869'.hexBytes;
```

### Concurrency and cancellation

```dart
final settled = await urls.parallelize(fetch, concurrency: 8);  // List<Either<Object, Page>>
final pages = settled.unwrap();                                 // or .rights, .lefts
final thumbs = await images.parallelize(resize, isolate: true); // long-lived isolates

await Cancel.scope(timeout: 5.m, () async {                     // download, run, retry, Pool… read it
  for (final item in items) {
    Cancel.throwIfCancelled();
    await handle(item);
  }
});
```

`parallelize` is sugar over a `Pool` of `Worker`s; subclass `Worker` for per-isolate state.
`Cli.run` opens the cancel scope, so ^C stops everything.

### Requests

```dart
await Http.scope(timeout: 30.s, retries: 3, delay: 500.ms, cookies: true, () async {
  await login.post(form: {'user': user, 'pass': pass});
  final doc = await dashboard.get().html;                       // throws unless 2xx
  final id = (await api.post(json: {'name': 'x'}).json)['id'];
  final res = await api.get();                                  // any status: res.isOk
  await upload.post(form: {'title': 'beach'}, files: {'photo': 'beach.jpg'.path});
});
```

`retries:` covers transport errors, 5xx and 429/503 (never a second POST unless `Retry-After`
said so); `delay:` spaces requests per host; `cache:` keeps GETs on disk. `url.events()` streams
SSE or NDJSON.

### Crawling

```dart
final stories = url.scrape<Story>()
    .onInit((ctx) => ctx..concurrency = 8..robots = true..sitemaps = true)
    .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      for (final a in ctx.html.$('.titleline > a')) {
        ctx.emit((title: a.text, link: ctx.resolve(a)));
      }
      ctx.follow(ctx.html.$('a.next'));                         // same hosts, never twice
    })
    .onError((ctx) => Console.warn('${ctx.failure}'))
    .onFinish((summary) => Console.info('$summary'));

await Http.scope(() => stories.rights.forEach(print));          // failures are Left items
```

The chain is sugar over `Crawler<T>`; subclass it when a crawl needs state or a test.

### Chrome

```dart
import 'package:dart_toolkit/chrome.dart';

final chrome = await ChromeClient.launch(block: Resource.heavy);
await Http.scope(client: chrome, () => url.scrape<Item>().onResponse(parse).rights.forEach(print));

final tab = await chrome.open(loginUrl);
await tab.fill('#user', 'me');
await tab.waitForNavigation(() => tab.click('button[type=submit]'));   // armed before the click
final file = await tab.waitForDownload(() => tab.click('.statement'), to: 'out'.path);
await Http.scope(jar: await tab.cookies(), () => api.get().json);      // the browser's session
await chrome.close();
```

Pages arrive as their DOM after their scripts ran, so `$`, `$x` and crawls work unchanged. A
launched Chrome dies with your program, even on `kill -9`.

### Downloads

Atomic (`.part`, renamed on success) and resumable. One file is a batch of one.

```dart
await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, digest)).show();
await {for (final u in urls) u: 'out'.path / u.pathSegments.last}.download(concurrency: 8).show();
```

### CLI

```dart
enum Stage { dev, production }

final stage = Opt.among('stage', Stage.values, 'Where to ship').abbr('s').or(Stage.production);
final token = Opt.text('token').env('GITHUB_TOKEN').required();  // [env: GITHUB_TOKEN] in help
final id = Arg.text('id', 'The build to ship').required();

Future<void> main(List<String> args) => Cli(                     // named after the script
  values: [id, stage, token],
  handler: (ctx) async {
    if (!await Console.confirm('Ship ${ctx(id)} to ${ctx(stage).name}?', or: true)) return;
    await Console.spin('Deploying', () => ship(ctx(id)));
  },
).run(args);
```

Every `Cli` has `--help`, `-v`, `-q` and `--completion bash|zsh|fish`. A usage error exits 64
with a "did you mean"; a thrown exception prints one red line and exits 1; a signal exits 128+n
after the `Lifecycle.onExit` hooks. Log lines, `print` and child output scroll above a live
spinner instead of garbling it.

What the console draws is a theme of tokens plus a builder per part:

```dart
Console.theme = ConsoleTheme(ok: '✔', fill: '█', empty: '░');   // marks, glyphs, palette
await pairs.download().show(task: (t) => '${t.index}/${t.count} ${t.name} ${t.bar(20)} ${t.speed.humanBytes}/s');
```

### Terminal apps

```dart
import 'package:dart_toolkit/tui.dart';

final pick = Choice(filter: true);                        // type to narrow, arrows to move
final file = await Tui.inline<String?>(null,
  view: (_) => VStack([Label('Open: ${pick.query}'), Menu(files, pick).fixed(8)]),
  update: (s, e) => e == Key.enter ? Tui.quit(files[pick.index]) : s);
```

`Tui.run` is the same app full-screen. Widgets: `Label`, `VStack`/`HStack`, `Box`, `Menu`, `Grid`,
`Tabs`, `Field`, `Gauge`, `Spin`, `Paint`.

### Testing

`Io` is the only sink and `Client` the only way to the network. Copy
[`test/mock_client.dart`](test/mock_client.dart).

```dart
Io.out = StringBuffer();
await Http.scope(client: MockClient((r) async => Response('{"ok":true}', 200)), () => url.get().json);
Io.reset();
```

---

## Executables

| Program | What it does |
|---|---|
| [`tk`](bin/tk.dart) | `hash`, `find`, `read`, `fetch`, `pack`, `peek`, `pick` |
| [`keybox`](bin/keybox.dart) | scrapes a box set's artwork and tracks, downloads them, zips the result |
| [`books`](bin/books.dart) | public-domain ebooks from Standard Ebooks, over HTTP or by clicking in Chrome |

```sh
dart run dart_toolkit:tk find 'lib/**/*.dart' --top 5
```

`dart run -r script.dart` keeps the compiler resident and roughly halves the next start.

## More

[`GUIDE.md`](GUIDE.md) (the manual and cookbook) · [`CONVENTIONS.md`](CONVENTIONS.md) (the
rules, and why) · [`CHANGELOG.md`](CHANGELOG.md) (releases)

## License

MIT — see [LICENSE](LICENSE).
