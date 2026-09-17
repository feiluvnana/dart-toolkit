# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A scripting, automation and web-scraping toolkit for Dart.

---

## Modules

Import the whole toolkit, or just the module you need — each is exported separately and pulls
only its own dependencies.

| import | contents | third-party cost |
|---|---|---|
| `collection/collection.dart` | `Iterable`, `List`, `Map` extensions | — |
| `util/util.dart` | `Env`, `Os`, `ConsoleIo`, duration helpers | — |
| `cli/cli.dart` | `Cli`, `Prompt`, `Logger`, `Console`, ANSI | — |
| `core/core.dart` | `Either`, `JsonDocument`, `HtmlDocument`, `XmlDocument` | html, xml, xpath |
| `async/async.dart` | `parallelize`, `retry`, `Mutex`, `CancellationToken` | rxdart |
| `fs/fs.dart` | `Path` | path |
| `hash/hash.dart` | SHA-256, MD5 | crypto |
| `archive/archive.dart` | zip, unzip | archive, path |
| `process/process.dart` | `run`, pipelines, `which` | path |
| `http/http.dart` | scraping, downloads, response parsing | http + core's |

`tool/check_deps.dart` enforces this table in CI.

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
print(config.$jsonpath(r'$.version').first.raw);

print((await file.readBytes()).sha256);
await dir.zipTo('${dir.path}.zip');
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
final data = await (() => fetchData()).retry().maxAttempts(3).delay(200.ms);

final lock = Mutex();
await lock.run(() async { /* critical section */ });
```

One cancellation idiom composes over any `Stream` or `Future`:

```dart
final token = CancellationToken();
onExit(() => token.cancel('interrupted'));

await for (final item in url.scrape<Item>(parse).cancelWith(token)) {
  print(item);
}
```

### Scraping

```dart
final items = url.scrape<Item>((ctx) {
  for (final row in ctx.response.html().$('tr.item')) {
    ctx.emit(Item(row.$('.title').first.text));
  }
  ctx.followAll(ctx.response.html().$('a.next').map((a) => a.attr('href')!));
}, concurrency: 8);

await for (final item in items) print(item);
```

Downloads are atomic — a `.part` file renamed on success, with `Content-Length` verified:

```dart
await for (final p in {url: dest}.downloadAll(concurrency: 4)) {
  print('${p.completed}/${p.total} ${p.current.path.name}');
}
```

### Errors

```dart
final outcome = Either.tryCatch(() => int.parse(raw));
final typed = outcome.mapLeft(ParseFailure.from);   // narrow afterwards
print(typed.fold((e) => 'failed: $e', (v) => 'got $v'));
```

### CLI

Option kinds are a sealed type, so a flag cannot also be numeric.

```dart
final cli = Cli(name: 'deployer')
  ..choice('env', ['dev', 'staging', 'production'], abbr: 'e', defaultTo: 'production')
  ..number('workers', abbr: 'w', defaultTo: 4)
  ..flag('dry-run', abbr: 'd')
  ..action((ctx) async {
    Logger.info('Deploying to ${ctx.option('env')} with ${ctx.number('workers')} workers');
    await Console.spin('Deploying...', deploy);
  });

await cli.run(args);
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
ConsoleIo.stdoutOverride = buffer;
Logger.ok('captured, not printed');
await run('echo also-captured');
ConsoleIo.reset();
```

---

## Examples

See [`example/`](example/) for three runnable programs.

## Conventions

[`CONVENTIONS.md`](CONVENTIONS.md) records the rules this API follows, so additions do
not re-create what [`AUDIT.md`](AUDIT.md) found.

## License

MIT — see [LICENSE](LICENSE).
