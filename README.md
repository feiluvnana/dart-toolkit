# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A scripting, automation and web-scraping toolkit for Dart.

---

## Modules

**Run an executable through pub's snapshot, and import the modules you use.** `dart run
dart_toolkit:keybox` starts in about 0.4 s and picks up edits; `dart run bin/keybox.dart`
recompiles the whole import closure every time and takes about 1.4 s. For an ad-hoc script the
imports are the lever: `package:dart_toolkit/dart_toolkit.dart` costs about 1.4 s per run against
about 0.3 s for a narrow import — measured, and the reason every program in this repo lists its
modules:

```dart
import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/util/util.dart';
```

The barrel re-exports everything and is there for tools you `dart compile` once, where tree
shaking makes it free.

| import | contents | third-party cost |
|---|---|---|
| `collection/collection.dart` | `Iterable`, `List`, `Map` extensions | — |
| `util/util.dart` | `Env`, `ConsoleIo`, `TaskProgress`, duration helpers | — |
| `cli/cli.dart` | `Cli`, `Prompt`, `Logger`, `Console`, ANSI | — |
| `core/core.dart` | `Either`, `JsonDocument`, string helpers | — |
| `async/async.dart` | `parallelize`, `retry`, `Mutex`, `CancelToken`, stream operators | — |
| `fs/fs.dart` | `Path` | path |
| `hash/hash.dart` | SHA-256, MD5 | crypto, path |
| `html/html.dart` | `HtmlDocument`, `Elements`, CSS selectors, `res.html`, `url.html` | http |
| `xml/xml.dart` | `XmlDocument`, `res.xml`, `url.xml` | xml, http |
| `archive/archive.dart` | zip, unzip | archive, path |
| `process/process.dart` | `run`, pipelines, `which` | path |
| `http/http.dart` | requests, JSON, scraping, downloads, `Http.session` | http, path |

A format bridge lives with its parser: `http` does not compile the HTML and XML parsers for a
program that downloads files or reads JSON. The HTML parser is in-house — `package:html` alone
was 580 ms of every scraper's startup — and is checked against it on real pages in the test
suite. `tool/startup.dart` prints what each module costs to import.

`tool/check_deps.dart` enforces this table in CI, and fails a `bin/` or `example/` file that
imports the barrel.

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

final prs = await run('gh pr list --json number', quiet: true).json;   // a JsonDocument
await run('cat', input: 'fed to stdin');
await (await which('dart'))?.run(args: ['--version']);

final piped = await ('echo "apple\nbanana"' | 'grep an').run();      // pipefail semantics
print(piped.lines);
```

### HTML

`$` takes a CSS selector and returns `Elements`: a list, whose `text`, `attr()` and `lines`
answer for the first match.

```dart
final doc = await url.html();                       // or res.html, or '<p>…</p>'.html
final title = doc.$('h1').text;
for (final a in doc.$('td.title > a[href]')) print(a.attr('href'));
final tracks = doc.$('#songlist tr').$('td:nth-child(3)').map((td) => td.text);
```

The parser is the package's own: tag soup lands where a browser puts it, and it starts in a
fraction of the time `package:html` did.

### Paths

`Path` is an extension type over `String`, so it goes anywhere a path string does.

```dart
final dir = Path.temp / 'my_project';
await dir.mkdir();

final file = dir / 'config.json';
await file.writeText(jsonEncode({'version': '0.0.1'}));

final config = JsonDocument.parse(await file.readText());
print(config.$(r'$.version').first.raw);

print(await file.sha256());
await dir.zipTo('${dir.path}.zip');
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
where the timeout and default headers live:

```dart
await Http.session(() async {
  final doc = await url.html();        // throws on a non-2xx status
  final res = await other.get();       // ...or check it yourself
  if (!res.isOk) await die('${res.statusCode} from $other');
}, timeout: 30.s, headers: {'user-agent': 'my-tool/1.0'});
```

`url / 'users'` appends a path segment, treating the base as a directory — the same glyph as
`Path./`, with the same meaning.

### Downloads

Atomic — a `.part` file renamed on success, with `Content-Length` verified. Take a map, an
iterable of `(url:, path:)` records, or a stream of them, so discovery and transfer overlap:

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

Every console write — including subprocess output — goes through `ConsoleIo`, which also drives
terminal detection, so redirecting the sink redirects what gets rendered.

```dart
final buffer = StringBuffer();
ConsoleIo.out = buffer;
Logger.ok('captured, not printed');
await run('echo also-captured');
ConsoleIo.reset();
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
