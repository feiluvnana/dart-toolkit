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
| `native.dart` | `Native`: loads `dart_toolkit_native`, the package's Rust library, for `fs` and `crypto` | path |
| `collection.dart` | `Sequence` (`.sequence` on any `Iterable` or `Map`): lazy queries, multi-key sort, joins, sets; `Table`: rows of named columns; CSV, TSV, NDJSON, Markdown | — |
| `formats.dart` | `JsonDocument` with JSONPath; YAML, TOML, INI into it; `HtmlDocument` with CSS `$` and XPath `$x`; `XmlDocument` with XPath `$`; YAML out | — |
| `async.dart` | `parallelize`, `retry`, `Mutex`, `CancelToken`, stream operators | — |
| `cli.dart` | `Cli`, `Console` (tables, spinners, progress, prompts), `Logger`, ANSI | — |
| `fs.dart` | `Path`; zip, 7z, rar, tar and gz/xz/zstd/bz2 archives with passwords, through the native library | path |
| `crypto.dart` | digests (MD5 to BLAKE3), HMAC, PBKDF2, HKDF, Argon2id, `Password`, AES-GCM, ChaCha20-Poly1305, Ed25519, ECDSA, RSA verify | crypto (fallback) |
| `process.dart` | `run`, pipelines, `which` | — |
| `http.dart` | `Request`, `Response`, `Client`, `Http.session`, scraping, downloads, `res.html`, `url.json()` | — |

Ten modules. Every parser and the HTTP client are the package's own, checked against the
packages they replaced in the test suite. What Dart cannot do fast — hashing at 2–3 GB/s,
AES, Argon2, 7z and rar — runs in **`dart_toolkit_native`**, one Rust library the package ships
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

XML gets the same shape with XPath as its `$`:

```dart
final feed = await url.xml();                        // or res.xml, or '<rss>…</rss>'.xml
for (final item in feed.$('//item').elements) print(item.$('title').text);
final urls = feed.$('//media:content/@url').texts;
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

Table.csv(text); Table.tsv(text); Table.ndjson(text);      // in
t.toCsv(); t.toTsv(); t.toNdjson(); t.toMarkdown();         // out
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

print(await file.sha256());                        // 2.4 GB/s through the native library
await dir.archiveTo('${dir.path}.7z', password: 'pw');   // also .zip, .tar.gz, .tar.zst, .tar.xz, .tar.bz2
await 'photos.rar'.path.extractTo(dir, password: 'pw');   // rar reads; the format's licence forbids writing
for (final e in await zip.archiveEntries()) print('${e.name} ${e.size}');
await log.gzipTo('log.gz');  await big.compressTo('big.zst');
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

### Crypto

Digests, MACs, key derivation, authenticated encryption and signatures, the same on every
platform through the native library, with pure Dart for digests, HMAC, HKDF and PBKDF2 when it
is absent. Published vectors and `openssl` agree with every one of them in the test suite.

```dart
'abc'.sha256;  bytes.blake3;  await file.hash(Hash.sha3_256);  'body'.hmac(Hash.sha256, secret)
final key = Key.random();  Crypto.token();  Crypto.equals(a, b)
Pbkdf2(Hash.sha256).derive(pw, salt);  Hkdf().derive(secret, info: ctx, length: 64)
Password.hash('pw');  Password.verify('pw', stored)                 // argon2id, self-describing
final box = Aes.gcm(key);  box.open(box.seal(plain, aad: header))   // nonce ‖ ct ‖ tag
await box.encryptFile(src, dst)
Ed25519.generate().sign(msg);  Ecdsa.p256(priv).sign(msg);  Rsa.verify(pem, msg, sig)
```

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

The client is `dart:io`'s, wrapped in `Request`, `Response` and `Client`; `Http.session(client:)`
takes any `Client`, so a test hands it one that answers from a handler — `test/mock_client.dart`
is forty lines and yours to copy.

`url / 'users'` appends a path segment, treating the base as a directory — the same glyph as
`Path./`, with the same meaning.

### Downloads

Atomic — a `.part` file renamed on success, with `Content-Length` verified — and resumable: a
failed or interrupted transfer keeps its `.part`, and the next download of the same path picks
up with a `Range` request. Take a map, an iterable of `(url:, path:)` records, or a stream of
them, so discovery and transfer overlap:

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

Option kinds are a sealed type, so a flag cannot also be numeric. A default is declared once —
`ctx.option` and `ctx.number` are non-null because of it — and `required: true` makes absence a
usage error. `Cli.run` owns the lifecycle: a usage error (`UsageException`) prints and exits 64,
`ctx.cancel` is cancelled on a signal, and whether the action returns or throws the exit hooks
run and the signal handlers are released so the process ends.

```dart
final cli = Cli(name: 'deployer')
  ..choice('env', ['dev', 'staging', 'production'], abbr: 'e', defaultTo: 'production')
  ..option('token', abbr: 't', required: true)
  ..number('workers', abbr: 'w', defaultTo: 4)
  ..flag('dry-run', abbr: 'd')
  ..action((ctx) async {
    final stage = Logger.stages(2);
    stage('Checking target');           // [1/2] Checking target
    Logger.info('Deploying to ${ctx.option('env')} with ${ctx.number('workers')} workers');
    stage('Rolling out');
    await Console.spin('Deploying...', deploy);
  });

await cli.run(args);   // deployer -dw8 -t abc, deployer --workers=8 fetch, ...
```

Options may precede the subcommand, short flags combine (`-dv`), and a short option may attach
its value (`-w8`).

Every builder method returns the receiver; nesting is explicit:

```dart
cli.command('fetch', build: (fetch) => fetch
  ..flag('verbose', abbr: 'v')
  ..action(run));
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

---

## Examples

See [`example/`](example/) for three runnable programs.

## Conventions

[`CONVENTIONS.md`](CONVENTIONS.md) records the rules this API follows, so additions do
not re-create what the audits behind them found. [`CHANGELOG.md`](CHANGELOG.md) records what
each one changed.

## License

MIT — see [LICENSE](LICENSE).
