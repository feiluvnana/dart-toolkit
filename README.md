# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A lightweight, modern, and concise script automation and web scraping toolkit for Dart.

---

## Features

- **Process & Shell**: Top-level `$()` and `run()`, `'cmd'.run()`, `path.run()`, `which()`, command pipelines with `|`.
- **Filesystem & Path**: Ergonomic `Path` with `/` operator, `readText()`, `writeText()`, `readJson()`, `writeJson()`, `append()`, `replace()`, `sanitized()`, `sha256()`, `md5()`, `zip()`, `unzip()`.
- **Environment**: `Env.get()`, `Env.set()`, `Env.require()`, `Env.has()`, `Env.load()`, `Env.all()`, OS and CI detection.
- **Async Concurrency**: `items.parallelize()`, `(() => ...).retry()`, `Mutex`, `Semaphore`, `computation.isolate()`, `CancellationToken` with a uniform `.cancelWith(token)` on any `Stream`/`Future`, stream operators (`chunk`, `flatmap`, `notnull`, `debounce`, `throttle`).
- **Document Parsing**: `Either<L, R>`, `JsonDocument` (JSONPath), `HtmlDocument` (CSS & XPath), `XmlDocument` (XPath).
- **HTTP & Scraping**: `http.Response` extensions (`.json()`, `.html()`, `.xml()`), scraping pipeline with `url.scrape()`.
- **CLI & Console**: Interactive `Prompt` (`ask`, `askWith` validation, `confirm`, `secret`, generic `select`), level-aware `Logger`, `Console.spin()`, `Console.spinner()`, `Console.progress()`, `Console.multiProgress()`, `Console.table()`, `Console.rule()`, `NO_COLOR`-aware ANSI styles, `Cli` app builder, `onExit()`, `die()`.
- **Testable IO**: every CLI component writes through `ConsoleIo`, so output can be captured, redirected, or silenced without touching call sites.

---

## Installation

Add `dart_toolkit` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

---

## Quick Tour

### 1. Process & Shell Automation

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // Execute system commands
  final res = await $('git status --short');
  if (res.ok) print(res.text);

  // String and Path extensions
  await 'echo "Hello World"'.run();
  await (await which('dart'))?.run(args: ['--version']);

  // Piping processes
  final piped = await ('echo "apple\nbanana"' | 'grep an').run();
  print(piped.lines);
}
```

### 2. Filesystem & Paths

```dart
final dir = Path.temp / 'my_project';
await dir.mkdir();

final file = dir / 'config.json';
await file.writeJson({'version': '0.0.1', 'debug': true});

final json = await file.readJson();
print(json.$jsonpath(r'$.version').firstOrNull?.raw);

print('SHA-256: ${await file.sha256()}');
```

### 3. Environment & `.env`

```dart
// Load .env content
Env.load('PORT=8080\nDB_HOST=localhost');

final port = Env.get('PORT', '3000');
final dbHost = Env.require('DB_HOST');
final allVars = Env.all();
```

### 4. Async & Concurrency

```dart
// Bounded parallel execution
final results = await [1, 2, 3, 4].parallelize((n) async {
  await 100.ms.delay();
  return n * 10;
}, concurrency: 2);

// Retry builder
final data = await (() async => fetchData()).retry().attempts(3).delay(200.ms);

// Critical section protection
final mutex = Mutex();
await mutex.protect(() async {
  // atomic critical section
});
```

### 5. CLI, Prompts & Spinners

```dart
onExit(() => print('Cleaning up...'));

await Console.spin('Deploying...', () async {
  await 500.ms.delay();
});

final answer = Prompt.confirm('Proceed with deployment?', true);
if (!answer) die('Aborted by user');

Console.table(
  headers: ['Name', 'Status'],
  rows: [
    ['API', 'Running'],
    ['DB', 'Connected'],
  ],
);
```

---

### 6. Logging, Validation & Cancellation

```dart
// Logger respects a global level; silence a noisy section inline.
Logger.level = LogLevel.debug;
Logger.debug('resolved 128 candidate URLs');
Logger.silenced(() => runVerboseStep());

// Prompts validate and work with any element type.
final port = Prompt.askWith('Port', defaultTo: '8080',
    validate: (v) => int.tryParse(v) == null ? 'Must be a number' : null);

final target = Prompt.select('Deploy target', servers,
    display: (s) => '${s.name} (${s.region})');

// One cancellation idiom for every async operation.
final token = CancellationToken();
onExit(() => token.cancel('interrupted'));

await for (final item in url.scrape<Item>(parse).cancelWith(token)) {
  print(item);
}

// Capture CLI output in tests without changing call sites.
final buffer = StringBuffer();
ConsoleIo.stdoutOverride = buffer;
Logger.ok('captured, not printed');
ConsoleIo.reset();
```

---

## Full Example

See [`example/example.dart`](example/example.dart) for a runnable demonstration of every API.

---

## License

MIT — see [LICENSE](LICENSE).
