# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A scripting, automation and web-scraping toolkit for Dart.

---

## Modules

**One import.** `package:dart_toolkit/dart_toolkit.dart` brings every module; since every
parser and the HTTP client are the package's own, it costs about what a scraper's five module
imports cost by hand (measured within 70 ms, on a 0.4 s bare start). A program that wants less
imports modules individually, and an executable run as `dart run dart_toolkit:<name>` pays
nothing after the first run either way.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```


| import | contents | third-party |
|---|---|---|
| `core.dart` | `Either`, `Env`, `Io`, `TaskProgress`, string and duration helpers | — |
| `native.dart` | `Native`: loads `dart_toolkit_native`, the package's Rust library, for `fs` and `hash` | path |
| `collection.dart` | `Sequence` (`.sequence` on any `Iterable` or `Map`): lazy queries, multi-key sort, joins, sets; `Table`: rows of named columns, and the package's one table renderer; CSV, NDJSON, Markdown | — |
| `formats.dart` | `JsonDocument` with JSONPath; YAML, TOML, INI into it; one markup tree for `HtmlDocument` and `XmlDocument`, CSS `$` and XPath `$x` on both; YAML out | — |
| `async.dart` | `parallelize`, `retry`, `Mutex`, `CancelToken`, stream operators | — |
| `cli.dart` | `Cli` with typed options, `Console` (spinners, progress, prompts), `Logger`, ANSI styling | — |
| `fs.dart` | `Path`; zip, 7z, rar, tar and gz/xz/zstd/bz2 archives with passwords, through the native library | path |
| `hash.dart` | 16 digests and 4 checksums behind one `hash(Hash.…)`, HMAC, hex/base64/base32, `Crypto.token`, `uuid`, `equals` | — |
| `process.dart` | `run`, pipelines, `which` | — |
| `http.dart` | `Request`, `Response`, `Client` (`IoClient`, `BrowserClient` over Chrome), `Http.session`, scraping, downloads, `res.html`, `url.json()` | — |

Ten modules. Every parser and the HTTP client are the package's own, checked against the
packages they replaced in the test suite. What Dart cannot do fast — hashing at 2–3 GB/s,
7z and rar — runs in **`dart_toolkit_native`**, one Rust library the package ships
prebuilt and loads through `dart:ffi`; `Native.isAvailable` and `Native.reason` say whether it
loaded, and anything that needs it throws an `UnsupportedError` naming what and why when it
did not. `tool/startup.dart` prints what each module costs to import.



---

## Installation

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

---

## Tour

### Processes

```dart
final res = await run('git status --short');
if (res.isOk) print(res.text);

final prs = (await run('gh pr list --json number', quiet: true).text).json;   // a JsonDocument
await run('cat', input: 'fed to stdin');
await (await which('dart'))?.run(args: ['--version']);

final piped = await ('echo "apple\nbanana"' | 'grep an').run();      // pipefail semantics
print(piped.lines);
```

### HTML and XML

`$` takes a CSS selector and returns `Elements`: a list, whose `text`, `attr()` and `lines`
answer for the first match. `$x` takes XPath, as in the browser console, and returns `Nodes`.

```dart
final doc = await url.html();                       // or res.html, or '<p>…</p>'.html
final title = doc.$('h1').text;
for (final a in doc.$('td.title > a[href]')) print(a.attr('href'));
final tracks = doc.$('#songlist tr').$('td:nth-child(3)').map((td) => td.text);
final flac = doc.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;
final table = doc.$x('//h2[contains(., "Tracks")]/following-sibling::table[1]').elements.$('td');
```

XML is the same tree and the same two queries — `$` is CSS and `$x` is XPath, here as
everywhere — parsed and serialised as XML: names keep their case and their prefixes, and an
empty element closes itself.

```dart
final feed = await url.xml();                        // or res.xml, or '<rss>…</rss>'.xml
for (final item in feed.$('item')) print(item.$('title').text);
final urls = feed.$x('//media:content/@url').texts;  // a prefixed name is not CSS
```

Both parsers are the package's own — tag soup lands where a browser puts it — and each is
checked against the package it replaced on real documents in the test suite.

### Formats

Every data and configuration format decodes to the same `JsonDocument`, so one query language
and one `to<T>()` serve them all. The parsers are the package's own; YAML is checked against
`package:yaml` in the test suite.

```dart
final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
print(pubspec.$(r'$.dependencies.*').length);
final port = configText.toml['server']['port'].to<int>();
final debug = iniText.ini['debug'].to<bool>();
await 'out.yaml'.path.writeText(pubspec.toYaml());

Table.csv(text); Table.cells(headers, rows); Table.ndjson(text);   // in
t.toCsv(); t.toNdjson(); t.toMarkdown(); t.show();                 // out
```

### Paths

`Path` is an extension type over `String`, so it goes anywhere a path string does.

```dart
final dir = Path.temp / 'my_project';
await dir.mkdir();

final file = dir / 'config.json';
await file.writeText(jsonEncode({'version': '0.0.1'}));

final config = JsonDocument.parse(await file.readText());
print(config.$(r'$.version').first.raw);

print(await file.hash(Hash.sha256));                        // 2.4 GB/s through the native library
await dir.archiveTo('${dir.path}.7z', password: 'pw');   // also .zip, .tar.gz, .tar.zst, .tar.xz, .tar.bz2
await 'photos.rar'.path.extractTo(dir, password: 'pw');   // rar reads; the format's licence forbids writing
for (final e in await zip.archiveEntries()) print('${e.name} ${e.size}');
await log.compressTo('log.gz');  await big.compressTo('big.zst');
```

A name that came from outside — a scraped title, a header, user input — becomes one component
with `filename`; `sanitized` is for a whole path and keeps its separators:

```dart
dir / 'AIR / Farewell song'.filename;   // .../AIR _ Farewell song
```

`Path` cannot override `==` — normalize at map boundaries:

```dart
final seen = <Path, int>{p.normalized: 1};
```

### Collections

Nothing is added to `Iterable` or `Map`. The way in is a conversion: `.sequence` gives a `Sequence`, a
lazy query with LINQ's and Kotlin's vocabulary that is still an `Iterable` on the way out;
`.table` gives a `Table`, rows of named columns. Both are opt-in; a plain list needs neither.

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc).thenBy((t) => t.number, descending: true)
    .take(10);                                            // still lazy, still an Iterable

tracks.sequence.groupBy((t) => t.disc).mapValues((g) => g.length).toMap();   // {1: 12, 2: 9}
songs.sequence.innerJoin(pages, on: (s) => s.href, to: (p) => p.href, (s, p) => (s, p.size));
[1, 2, 3].sequence.union([3, 4]).scan(0, (a, b) => a + b);    // 1, 3, 6, 10
prices.sequence.sum; names.sequence.sorted.first;             // typed: only on numbers, only on Comparables
for (final (k, v) in map.sequence.sortedByValue(descending: true).take(3)) print('$k $v');
```

[`example/collections.dart`](example/collections.dart) solves six tasks with the SDK's
`Iterable` and again with `Sequence`, side by side. A `Table` comes from maps, records, a JSON
array, CSV text or an HTML `<table>`, and goes back out as CSV, JSON or a console table:

```dart
final t = doc.$('table#songs').table;                     // <th> → columns, <tr> → rows
t.where((r) => r.number('size') > 1e6)
    .orderBy('disc').thenBy('n')
    .select(['title', 'size'])
    .show();
t.groupBy('disc').sum('size');                            // Table(disc, size)
t.pivot(rows: 'disc', column: 'format', value: 'size');
await t.join(other, on: 'href').saveCsv('out.csv');
final rows = json.$(r'$.items[*]').table;                 // or Table.csv(text), Table.rows(list)
```

### Hashing

Digests run in the native library, so they are the same and fast on every platform; the test
suite checks each against its published vectors and against `openssl`. A file streams, so
memory is flat whatever its size.

```dart
'abc'.hash(Hash.sha256);  bytes.hash(Hash.blake3);  await file.hash(Hash.sha3_256);  await file.checksum(Hash.crc32);  bytes.hash(Hash.xxh3)
'body'.hmac(Hash.sha256, secret);  Crypto.token();  Crypto.uuid();  Crypto.equals(a, b)
bytes.hex;  bytes.base64Url;  'JBSWY3DP'.base32Bytes;  '6869'.hexBytes
```

Sixteen digests and four checksums: md5, sha1, the SHA-2 and SHA-3 families, keccak256,
blake2s, blake2b, blake3, ripemd160, and crc32, crc32c, xxh64, xxh3. The 32-bit checksums
read as an `int` (`bytes.checksum(Hash.crc32)`); the 64-bit ones read as hex, because they do not fit one.

**Encryption, password hashing, signatures and JWT are deliberately absent.** This is a
toolkit for automation scripts: it identifies, verifies and encodes data, and has no
business owning the code that protects it. Use a dedicated package when you need that.

### Concurrency

One primitive settles every task; `unwrap` picks the error policy at the use site.

```dart
final settled = await urls.parallelize(fetch, concurrency: 8);  // List<Either<Object, Page>>
print('${settled.rights.length} ok, ${settled.lefts.length} failed');

final pages = (await urls.parallelize(fetch)).unwrap();  // or throw the first failure
```

```dart
final data = await retry(fetchData, attempts: 3, delay: 200.ms);

final lock = Mutex();
await lock.run(() async { /* critical section */ });
```

One cancellation idiom composes over any `Stream` or `Future`, and a `Cli` action already has a
token — `ctx.cancel` — that a signal, `die` and the end of the action cancel:

```dart
await for (final item in url.scrape<Item>().onResponse(parse).rights.cancelWith(ctx.cancel)) {
  print(item);
}
```

### Scraping

A crawl is a chain of five hooks, and the stream of what they emit.

```dart
final stories = url.scrape<Story>()
    .onInit((ctx) {
      ctx.concurrency = 8;
      ctx.delay = 200.ms;
      ctx.pages = 50;
    })
    .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      final html = ctx.response.html;
      for (final row in html.$('tr.athing')) {
        final a = row.$('.titleline > a');   // Elements: text and attr() answer for the first match
        if (a.attr('href') case final href?) ctx.emit((title: a.text, link: ctx.resolve(href)));
      }
      for (final a in html.$('a[href]')) ctx.follow(a.attr('href')!);
    })
    .onError((ctx) => Logger.warn('${ctx.failure}'))
    .onFinish((summary) => Logger.info('$summary'));

await for (final story in stories.rights) print(story);
```

Five hooks, each with the context for its moment:

- `onInit` — once, on listen, with every crawl-wide setting: `concurrency`, `perHost`, `delay`,
  `timeout`, `retries`, `redirects`, `bodyLimit`, `pages`, `depth`, `scope`, and `seed()`
  to add starting points. It may be async — fetch a token, read a config.
- `onRequest` — before every send. Anything per request is here: a header, the `user-agent`, a
  signature on `ctx.request`, or `ctx.skip()`.
- `onResponse` — every 2xx. `ctx.emit`, `ctx.follow`, `ctx.stop`; `ctx.url` is the page that
  answered, after redirects, and `ctx.depth` and `ctx.pages` say where the crawl is.
- `onError` — the engine has given up on a request. `switch` on `ctx.failure`
  (`RequestFailed | StatusFailed | HookFailed`), then `ctx.retry(after:)`, `ctx.emit` a
  fallback, `ctx.follow` an alternative, or `ctx.ignore()`. A hook that does none of those
  leaves the failure a `Left`.
- `onFinish` — once, with a `ScrapeSummary` of pages, failures, requests, retries, drops,
  bytes, time.

`follow` stays on the seeds' hosts (`www.` or not), strips fragments, never fetches a page
twice, and drops `mailto:` and `javascript:` by itself — and returns `false` when it dropped
something, so nothing vanishes silently. `ctx.scope` in `onInit` widens the rule for the crawl,
`offsite: true` for one link, `revisit: true` for one refetch. `follow(onResponse:, onError:)`
overrides the hooks for one request, and `meta:` rides along to it.

Defaults: 16 in flight, 8 per host, 30 s, 2 retries, 5 hops, 16 MB, `user-agent: dart-toolkit`
unless a request or the session names one, and a host answering 429 or 503 is paused for its
`Retry-After`.

A failure is an item, not a stream error — the contract `parallelize` has, on a stream:

```dart
stories.rights      // skip failures
stories.lefts       // only the failures
stories.unwrap()    // throw the first
await for (final r in stories) switch (r) { case Right(:final value): ...; case Left(:final value): ... }
```

One session shares a client across every request inside it, closes it on the way out, and is
where the timeout and default headers live. `get`, `head`, `post`, `put`, `patch` and `delete`
take `body:` (text, bytes or form fields) or `json:`; `fetch` is a GET that must be 2xx.

```dart
await Http.session(() async {
  final doc = await url.html();                         // throws on a non-2xx status
  final res = await other.get();                        // ...or check it yourself
  if (!res.isOk) await die('${res.statusCode} from $other');
  final created = await api.withQuery({'v': 2}).post(json: {'name': 'x'});
}, timeout: 30.s, headers: {'user-agent': 'my-tool/1.0'});
```

`url / 'users'` appends a path segment, treating the base as a directory — the same glyph as
`Path./`, with the same meaning.

### Clients

Every request in the module — a `get`, a download, a crawl — is sent through one `Client`, and
`Http.session(client:)` is the only place a program names it. There are two, and a test's is a
third:

```dart
await Http.session(client: IoClient(), () async { … });                  // the default: dart:io
await Http.session(client: await BrowserClient.launch(), () async { … });  // Chrome renders it
await Http.session(client: MockClient((r) async => Response('ok', 200)), () async { … });
```

`BrowserClient` speaks the DevTools protocol over a websocket — no third-party package and no
Chromium download: `launch()` finds the Chrome already installed and runs it headless,
`attach(port:)` joins one already running. The page arrives as the DOM **after its own scripts
have run**, in `Response.bytes`, so `res.html`, `$`, `$x` and the whole scrape engine work over
it unchanged:

```dart
final browser = await BrowserClient.launch(tabs: 4);
await Http.session(client: browser, () async {
  await for (final item in url.scrape<Item>()
      .onRequest((ctx) => ctx.request[BrowserClient.waitFor] = '.results .item')
      .onResponse(parse)
      .rights) print(item);
});
await browser.close();
```

Only a GET without a `range` is rendered. A POST, a resumable download, an image — everything
else goes to the plain HTTP client underneath, carrying the browser's cookies for that host, so
a crawl that renders its pages still fetches its files at the speed of a socket.

What a page needs before it is worth reading is said per request, with a `RequestKey`:

| key | |
|---|---|
| `BrowserClient.waitFor` | wait until a CSS selector matches |
| `BrowserClient.waitUntil` | `BrowserWait.load` or `.idle` — `load`, then half a second of silence |
| `BrowserClient.script` | JavaScript to run before the DOM is read; may return a promise |
| `BrowserClient.challenge` | how long this page may sit on an interstitial |
| `BrowserClient.direct` | send this one down the plain client instead |

**A page is never lost.** A wait that expires, a selector that matches nothing, a challenge
that never clears: none of them throw and none of them close the tab. The DOM as it stands
comes back under the status the server gave it, and the tab goes back to the pool still on that
page — closing it would throw away a challenge somebody is in the middle of solving. A page
that answers with an interstitial is given `challenge:` (20 s by default) to become the real
page on its own; with `headless: false` that is also a human's chance to click the box. Only a
navigation Chrome refuses outright — a name that will not resolve, a refused connection — is a
`ClientException`, which is what a crawl retries.

### Driving a page

`send` fetches; `open` hands the tab over. It is outside the pool `send` draws on, so holding
one open — through a login, a captcha, a form — never starves a crawl:

```dart
final page = await browser.open(loginUrl);
await page.fill('#user', 'me');
await page.click('button[type=submit]');
await page.waitFor('.dashboard');                 // false on time, never a throw
print((await page.html()).$('.balance').text);    // read the DOM whenever you like
await Path('shot.png').writeBytes(await page.screenshot());
await page.close();
```

| | |
|---|---|
| `goto(url, until:, challenge:)` | navigate and wait; answers with the page as it stands |
| `response()`, `html()`, `statusCode`, `url` | what the tab holds right now, at any moment |
| `waitFor(sel)`, `waitWhile(sel)` | a mutation observer; `false` when the time runs out |
| `click(sel)`, `fill(sel, text)`, `press(key)` | real mouse and key events, with a DOM fallback |
| `scroll(times:)` | walk an infinite feed until it stops growing |
| `eval(js, awaitPromise:)`, `screenshot()` | run anything; a PNG of what the window shows |

`browser.page(url, (page) async { … })` is the same thing with the close written for you.

A `RequestKey<T>` is how any client is told something HTTP has no word for, and **a client
ignores every key it does not know** — which is what lets the same crawl run over `IoClient`,
which ignores the wait, and over `BrowserClient`, which honours it. To write a third client,
implement two methods:

```dart
abstract interface class Client {
  Future<StreamedResponse> send(Request request);
  FutureOr<void> close();        // awaited by Http.session, so a socket teardown is safe
}
```

and point `clientConformance` at it — `test/client_conformance.dart` brings its own server and
checks the promises the rest of the module relies on: a non-2xx is a response and not a throw,
`url` is the URL that answered, a body arrives as a stream, an unknown directive is ignored.
`MockClient` is forty lines and `BrowserClient` five hundred and twenty; both are yours to read
before writing a third.

### Downloads

Atomic — a `.part` file renamed on success, with `Content-Length` verified — and resumable: a
failed or interrupted transfer keeps its `.part`, and the next download of the same path picks
up with a `Range` request. Take a map, an iterable of `(url:, path:)` records, or a stream of
them, so discovery and transfer overlap:

One file or many, the events are the same — `dest.download(url)` is a batch of one, so it
renders with the same `show` and needs no wrapping:

```dart
await for (final p in {url: dest}.downloadAll(concurrency: 4)) {
  switch (p.current) {
    case Downloading(:final ratio):   print('${p.current.label} $ratio');
    case Downloaded(:final bytes):    print('${p.current.label} $bytes B');
    case DownloadSkipped():           print('${p.current.label} exists');
    case DownloadFailed(:final error): print(error);
  }
}
```

A progress widget needs none of that — `show` renders the batch and returns its last event, and
`merge` lets a fixed list and a crawl feed the same downloader at the same time:

```dart
final last = await [Stream.fromIterable(artwork.pairs), scraped]
    .merge()
    .downloadAll(concurrency: 8, cancelToken: ctx.cancel)
    .show(slots: 8, message: 'Downloading', done: 'Done.');
print('${last?.written} new files');
```

### Errors

```dart
final outcome = Either.tryCatchSync(() => int.parse(raw));
final typed = outcome.mapLeft(ParseFailure.from);   // narrow afterwards
print(typed.fold((e) => 'failed: $e', (v) => 'got $v'));
```

### CLI

An option is a value, so its name is written once and its type is the type you read back.
`Opt.among` takes the values themselves — an enum, not a list of strings to match again by
hand — and `.or(…)` and `.required()` are what make `ctx(…)` non-nullable. `Cli.run` owns the
lifecycle: a usage error (`UsageException`) prints and exits 64, `ctx.cancel` is cancelled on a
signal, and whether the action returns or throws the exit hooks run and the signal handlers
are released so the process ends.

```dart
enum Env { dev, staging, production }

final env = Opt.among('env', Env.values, abbr: 'e').or(Env.production);  // Env
final token = Opt.text('token', abbr: 't').required();                   // String
final workers = Opt.number('workers', abbr: 'w').or(4);                  // int
final dryRun = Flag('dry-run', abbr: 'd');                               // bool
final since = Opt.by('since', DateTime.parse);                           // DateTime?

final cli = Cli(name: 'deployer', options: [env, token, workers, dryRun])
  ..action((ctx) async {
    final stage = Logger.stages(2);
    stage('Checking target');           // [1/2] Checking target
    Logger.info('Deploying to ${ctx(env).name} with ${ctx(workers)} workers');
    stage('Rolling out');
    await Console.spin('Deploying...', deploy);
  });

await cli.run(args);   // deployer -dw8 -t abc, deployer --workers=8 fetch, ...
```

Options may precede the subcommand, short flags combine (`-dv`), and a short option may attach
its value (`-w8`).

A subcommand takes its options the same way; `build:` is for one that nests further:

```dart
cli.command('fetch', description: 'Fetch a thing', options: [verbose], handler: run);
```

### Testable IO

Every console write — including subprocess output — goes through `Io`, which also drives
terminal detection, so redirecting the sink redirects what gets rendered. Every request goes
through a `Client`, so a handler-backed one stands in for the network. `make` runs analyze,
format and the tests; `make native` builds the Rust library for this machine.

```dart
final buffer = StringBuffer();
Io.out = buffer;
Logger.ok('captured, not printed');
await run('echo also-captured');
Io.reset();

final client = MockClient((req) async => Response('{"ok": true}', 200));
await Http.session(() => url.json(), client: client);
```

No request method takes a `client:` of its own: the session is where a program says which
client to use, once, and everything inside it — requests, downloads, a whole crawl — uses it.

---

## Examples

See [`example/`](example/) for seven runnable programs — one per area, each a task rather
than a tour:

| file | shows |
|---|---|
| [`cli_app.dart`](example/cli_app.dart) | subcommands, typed options, stages, progress, `ctx.cancel`, exit hooks |
| [`concurrent_work.dart`](example/concurrent_work.dart) | `parallelize` settling into `Either`, `retry`, `CancelToken`, `Mutex`, isolates, stream operators |
| [`config_formats.dart`](example/config_formats.dart) | YAML, TOML, INI, JSON and XML through one document type, JSONPath, `toYaml` |
| [`files_and_digests.dart`](example/files_and_digests.dart) | `Path`, `glob`, digests for de-duplication, archives, verification |
| [`shell_pipeline.dart`](example/shell_pipeline.dart) | `run`, pipelines, `which`, failure policy, `Env` |
| [`web_crawler.dart`](example/web_crawler.dart) | one-shot requests, the five-hook crawl, downloads with progress |
| [`collections.dart`](example/collections.dart) | six tasks with the SDK's `Iterable`, then with `Sequence` and `Table`, side by side |

`bin/` holds the executables: [`tk.dart`](bin/tk.dart) is the toolkit as a command-line tool
(`hash`, `find`, `read`, `fetch`, `pack`, `peek`), and [`keybox.dart`](bin/keybox.dart) is the
program the brevity rules in `CONVENTIONS.md` are measured against.

```sh
dart run bin/tk.dart find 'lib/**/*.dart' --top 5
dart run bin/tk.dart read pubspec.yaml --query '$.dependencies.*'
dart run example/config_formats.dart
```

## Conventions

[`CONVENTIONS.md`](CONVENTIONS.md) records the rules this API follows, so additions do
not re-create what the audits behind them found. [`CHANGELOG.md`](CHANGELOG.md) records what each
release contains.

## License

MIT — see [LICENSE](LICENSE).
