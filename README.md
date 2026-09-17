# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A scripting, automation and web-scraping toolkit for Dart.

---

## Modules

**Import the modules you use, not the barrel.** Under `dart run` the front end compiles the whole
transitive closure on every invocation, so `package:dart_toolkit/dart_toolkit.dart` costs about
1.4 s per run against about 0.3 s for a narrow import — measured, and the reason every program in
this repo lists its modules:

```dart
import 'package:dart_toolkit/cli/cli.dart';
import 'package:dart_toolkit/util/util.dart';
```

The barrel re-exports everything and is there for tools you `dart compile` once, where tree
shaking makes it free.

| import | contents | third-party cost |
|---|---|---|
| `collection/collection.dart` | `Iterable`, `List`, `Map` extensions | — |
| `util/util.dart` | `Env`, `Os`, `ConsoleIo`, `TaskProgress`, duration helpers | — |
| `cli/cli.dart` | `Cli`, `Prompt`, `Logger`, `Console`, ANSI | — |
| `core/core.dart` | `Either`, `JsonDocument`, string helpers | — |
| `async/async.dart` | `parallelize`, `retry`, `Mutex`, `CancelToken`, stream operators | — |
| `fs/fs.dart` | `Path` | path |
| `hash/hash.dart` | SHA-256, MD5 | crypto, path |
| `html/html.dart` | `HtmlDocument`, element queries | html |
| `xml/xml.dart` | `XmlDocument` | xml |
| `archive/archive.dart` | zip, unzip | archive, path |
| `process/process.dart` | `run`, pipelines, `which` | path |
| `http/http.dart` | scraping, downloads, response parsing, `Http.session` | http, html, xml, path |

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
if (res.ok) print(res.text);

await 'echo "Hello World"'.run();
await (await which('dart'))?.run(args: ['--version']);

final piped = await ('echo "apple\nbanana"' | 'grep an').run();
print(piped.lines);
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

print(await file.sha256());
await dir.zipTo('${dir.path}.zip');
```

A name that came from outside — a scraped title, a header, user input — becomes one component
with `filename`; `sanitized()` is for a whole path and keeps its separators:

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
final data = await (() => fetchData()).retry().attempts(3).delay(200.ms);

final lock = Mutex();
await lock.run(() async { /* critical section */ });
```

One cancellation idiom composes over any `Stream` or `Future`:

```dart
final token = CancelToken();
onExit(() => token.cancel('interrupted'));

await for (final item in url.scrape<Item>(parse).cancelWith(token)) {
  print(item);
}
```

### Scraping

```dart
final items = url.scrape<Item>((ctx) {
  for (final row in ctx.response.html().$('tr.item')) {
    ctx.emit(Item(row.$('.title').first.text, link: ctx.resolve(row.$('a').first.attr('href')!)));
  }
  ctx.followAll(ctx.response.html().$('a.next').map((a) => a.attr('href')!));
}, concurrency: 8);
```

`ctx.url` is where the response came from, and `ctx.resolve` resolves against it — the same base
`follow` uses.

One session shares a client across every request inside it, and closes it on the way out:

```dart
await Http.session(() async {
  final doc = await url.html();        // throws on a non-2xx status
  final res = await other.get();       // ...or check it yourself
  if (!res.ok) await die('${res.statusCode} from $other');
});
```

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

A progress widget needs none of that — `report` takes the batch update whole:

```dart
final progress = Console.multiProgress(slots: 8, message: 'Downloading');
await for (final p in scraped.downloadAll(concurrency: 8)) progress.report(p);
progress.done('Done.');
```

### Errors

```dart
final outcome = Either.tryCatch(() => int.parse(raw));
final typed = outcome.mapLeft(ParseFailure.from);   // narrow afterwards
print(typed.fold((e) => 'failed: $e', (v) => 'got $v'));
```

### CLI

Option kinds are a sealed type, so a flag cannot also be numeric. A default is declared once —
reads see it — and `required: true` makes absence a parse error.

```dart
final cli = Cli(name: 'deployer')
  ..choice('env', ['dev', 'staging', 'production'], abbr: 'e', defaultTo: 'production')
  ..option('token', abbr: 't', required: true)
  ..number('workers', abbr: 'w', defaultTo: 4)
  ..flag('dry-run', abbr: 'd')
  ..action((ctx) async {
    final stage = Logger.stages(2);
    stage('Checking target');           // [1/2] Checking target
    Logger.info('Deploying to ${ctx.option('env')!} with ${ctx.number('workers')!} workers');
    stage('Rolling out');
    await Console.spin('Deploying...', deploy);
  });

try {
  await cli.run(args);
} on ArgumentError catch (e) {
  await die('${e.message}', exitCode: 64);
}
```

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
