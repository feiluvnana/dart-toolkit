# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.0%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A modern, highly concise, and cohesive automation scripting toolkit for Dart developed by **feiluvnana**. Designed from the ground up for writing clean, readable, command-line automation and web scraping scripts with **strictly 1-word methods** and **6 intuitive lowercase namespaces**:

| Namespace | Focus Area | Documentation |
| :--- | :--- | :--- |
| **`console.*`** | Terminal formatting, tables, dynamic progress bars, spinners, prompts | [Guide](docs/console.md) |
| **`fs.*`** | Atomic file operations, built-in path helpers, 7-Zip archiving | [Guide](docs/fs.md) |
| **`crawl.*` / `$()`** | Web scraping, crawler engine, pipeline routing, DOM queries | [Guide](docs/crawl.md) |
| **`parallel.*`** | Bounded asynchronous task concurrency, pooling, streams | [Guide](docs/parallel.md) |
| **`sys.*` / `proc.*`** | Subprocess execution, signals, exit hooks, stopwatch benchmarks | [Guide](docs/sys.md) |
| **`cli.*`** | Command-line flag and option parsing, argument lists | [Guide](docs/cli.md) |

---

## Design Philosophy

1. **Strictly 1-Word Methods**: All primary actions are exactly one word (`run`, `get`, `post`, `save`, `follow`, `emit`, `stop`, `step`, `ok`, `warn`, `fail`, `info`, `ask`, `pick`, `which`, `clock`).
2. **Dot-Separated Sub-Namespaces**: Compound actions use intuitive dot namespaces rather than camelCase identifiers (e.g. `console.logger.info`, `console.writer.table`, `console.reader.ask`, `engine.on.progress`, `sys.on.exit`).
3. **Batteries Included**: Zero external utility dependencies required in user scripts. Built-in path manipulation (`fs.join`, `fs.base`), atomic writing (`.part` staging), and ANSI terminal formatting.
4. **Engine-Driven Pipelines**: Multi-stage web crawlers use declarative URL routing, pipeline link following, and automatic relative URL resolution.

---

## Installation

Add `dart_toolkit` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

Then import the single aggregate entrypoint:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```

---

## Quickstart

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> rawArgs) async {
  // 1. Parse CLI arguments
  cli.parse(rawArgs);
  final force = cli.has('force', 'f');
  final poolSize = cli.get('concurrency', 4);

  // 2. Setup graceful shutdown & stopwatch
  sys.listen();
  final clock = sys.clock();

  // 3. Web Crawling & Scraping with Engine
  console.logger.step(1, 4, 'Crawling news headlines...');
  final titles = await crawl('https://news.ycombinator.com')
      .concurrent(poolSize)
      .collect<String>((res) {
        for (final title in res.$('.titleline > a').texts) {
          res.emit(title);
        }
      });
  console.logger.ok('Found ${titles.length} news items.');

  // 4. Concurrently process items with progress bar
  console.logger.step(2, 4, 'Processing documents...');
  final bar = console.bar(titles.take(10).length, 'Processing');

  final processed = await parallel.run(titles.take(10), (title) async {
    await Future.delayed(const Duration(milliseconds: 50));
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: poolSize);
  bar.done('Processing finished!');

  // 5. Output summary table
  console.logger.step(3, 4, 'Generating summary...');
  console.writer.table(['Metric', 'Value'], [
    ['Total Crawled', titles.length],
    ['Total Processed', processed.length],
    ['Elapsed Time', fs.time(clock.elapsed)],
  ]);

  // 6. Save output atomically (.part staging)
  console.logger.step(4, 4, 'Saving output...');
  final dest = fs.join('output', 'summary.txt');
  if (force || !fs.has(dest)) {
    await fs.write(dest, processed.join('\n'));
    console.logger.ok('Saved output to $dest');
  }

  console.logger.ok('Completed in ${fs.time(clock.elapsed)}!');
}
```

---

## Namespace Reference

### 1. `console.*` &mdash; Terminal Formatting & Prompts
[Read Detailed Guide &rarr;](docs/console.md)

- **Loggers (`console.logger.*`)**:
  - `console.logger.step(n, total, msg)`: Step header `[1/4] Starting workflow...`
  - `console.logger.ok(msg)`: Green checkmark `✔ Success`
  - `console.logger.warn(msg)`: Yellow warning `⚠ Warning`
  - `console.logger.fail(msg)` / `console.logger.error(msg)`: Red cross `✖ Failure`
  - `console.logger.info(msg)`: Blue info `ℹ Notice`
  - `console.logger.debug(msg)`: Dimmed debug symbol `⚙ Debug`
  - `console.logger.task(msg, fn)`: Run an async task with spinner indicator.
- **Visual Output (`console.writer.*`)**:
  - `console.writer.table(headers, rows, [alignments, style])`: Formatted tables.
  - `console.writer.box(text, [title])`: Text wrapped in a bordered callout box.
  - `console.writer.rule([title])`: Horizontal divider rule with centered text.
  - `console.writer.bar(total, [msg])`: Interactive progress bar (`bar.tick()`, `bar.done()`).
  - `console.writer.spin([msg])`: Terminal spinner (`spin.update()`, `spin.ok()`, `spin.fail()`).
- **Interactive Prompts (`console.reader.*`)**:
  - `console.reader.ask(prompt, [default])`: Text input with default fallback.
  - `console.reader.confirm(prompt, [default])`: Yes/No boolean prompt `[Y/n]`.
  - `console.reader.pick(prompt, options)`: Single-choice selection menu.
  - `console.reader.secret(prompt)`: Masked input for tokens and passwords.
  - `console.reader.line()`: Read raw line from standard input.
- **ANSI String Extensions**:
  - `'text'.bold()`, `'text'.dim()`, `'text'.underline()`
  - `'text'.red()`, `'text'.green()`, `'text'.yellow()`, `'text'.cyan()`, `'text'.brightGreen()`
- **Terminal Geometry & Cursor**:
  - `console.terminal.width`, `console.terminal.height`, `console.terminal.clear()`
  - `console.cursor.hide()`, `console.cursor.show()`, `console.cursor.up()`, `console.cursor.down()`

---

### 2. `fs.*` &mdash; Atomic Storage & Path Utilities
[Read Detailed Guide &rarr;](docs/fs.md)

- **Zero-Dependency Path Manipulation**:
  - `fs.join(p1, [p2, p3...])`: Safe path join with slash normalization.
  - `fs.base(path)`: Filename with extension (`archive.tar.gz`).
  - `fs.name(path)`: Filename without extension (`archive.tar`).
  - `fs.ext(path)`: Extension including dot (`.json`).
  - `fs.dir(path)`: Parent directory path.
- **Atomic Operations & Download**:
  - `fs.write(file, content)`: Atomic write with `.part` staging and signal cleanup.
  - `fs.read(path)` / `fs.bytes(path)`: Read string or raw bytes.
  - `fs.download(url, dest)`: Direct streaming HTTP download to file with `.part` protection.
  - `fs.mkdir(path)`: Recursive directory creation.
  - `fs.copy(src, dest)` / `fs.move(src, dest)`: Copy or move files, ensuring parent directories.
  - `fs.delete(dir, [pattern])`: Delete files matching glob/regex.
  - `fs.find(dir, [pattern])`: Find matching files recursively.
  - `fs.has(path, [match])`: Check if file exists and has size > 0.
- **Formatters & Sanitize**:
  - `fs.size(bytes)` / `fs.parse(sizeStr)`: Human size formatting (`5.0 MB`) and parsing.
  - `fs.time(duration)`: Human duration formatting (`02:15`).
  - `fs.sanitize(name, [full])`: Sanitize filename for local OS.
  - `fs.temp([prefix])`: Create temporary directory.
- **Archive Management (`fs.archive(path)`)**:
  - `final arc = fs.archive('bundle.7z');`
  - `arc.sync(dir, {force, changed})`: Integrity test and compress into 1-volume archive.
  - `arc.check()`: Test integrity via 7z.
  - `arc.zip(dir)`: Compress directory into archive.
  - `arc.wipe()`: Delete archive and split volumes.

---

### 3. `crawl.*` & `$()` &mdash; Web Scraping & Crawler Engine
[Read Detailed Guide &rarr;](docs/crawl.md)

- **Fluent Builder Crawling (`crawl(urls)`)**:
  - `await crawl(urls).concurrent(n).delay(d).base(...).tag(...).run(process)`: Builder pattern with process-only argument.
  - `await crawl(urls).concurrent(n).collect<T>(process)`: Collect emitted items into a typed `List<T>`.
  - `await crawl.run(startUrls, process)` / `await crawl.collect(...)`: Quick functional shortcuts.
  - `final engine = crawl.engine({concurrency, base, dl});`: Direct engine coordinator.
- **Pipeline Response Controls (`res.*`)**:
  - `res.follow(url, {tag, meta, priority})`: Schedule URL to crawl next (auto-resolves relative URLs).
  - `res.save(filePath, [sourceUrl])`: Save response body or stream remote asset to disk atomically.
  - `res.emit(item)`: Emit structured scraped record to stream or collector.
  - `res.tag`, `res.meta`, `res.url`, `res.status`, `res.ok`, `res.stop()`
- **Quick Requests & Asset Syncing**:
  - `final res = await crawl.get(url);`
  - `final res = await crawl.post(url, body);`
  - `final dl = crawl.dl(base: 'downloads');`
  - `await crawl.sync(assetMap, base: 'assets', prefix: baseUrl);`
- **DOM Queries & Traversal (`$()`)**:
  - `res.$(selector)` or `$(html)`:
    - Traversal: `find()`, `filter()`, `not()`, `children()`, `parent()`, `closest()`, `eq()`.
    - Content: `text`, `texts`, `lines`, `html`, `attr(name)`, `attrs(name)`.
    - Assets: `link()`, `links()`, `src()`, `srcs()`.

---

### 4. `parallel.*` &mdash; Concurrency & Task Pooling
[Read Detailed Guide &rarr;](docs/parallel.md)

- `parallel.run(items, worker, {size: 4})`: Run async tasks concurrently preserving order.
- `parallel.map(items, mapper, {size: 4})`: Map items concurrently.
- `parallel.each(items, worker, {size: 4})`: Fire-and-forget concurrent iteration.
- `final pool = parallel.pool(8);`: Custom pool with `pool.on.progress()`, `pool.on.done()`, `pool.on.error()`.

---

### 5. `sys.*` / `proc.*` &mdash; Process, Signals & Benchmark
[Read Detailed Guide &rarr;](docs/sys.md)

- `sys.run(binary, args, [cwd, inherit, echo])`: Run external command and return `ProcResult`.
- `sys.which(tool)`: Search executable in PATH.
- `sys.clock()`: Start benchmark stopwatch.
- `sys.listen()`: Catch Ctrl+C signals for cleanup.
- `sys.track(file)` / `sys.untrack(file)`: Track temporary files to delete on abort.
- `sys.on.exit(() => ...)` / `sys.hook(fn)`: Register cleanup hooks.
- `sys.exit([code])` / `sys.now([code])`: Clean or immediate process exit.
- `sys.env('KEY')`: Read environment variable.

---

### 6. `cli.*` &mdash; Command-Line Interface
[Read Detailed Guide &rarr;](docs/cli.md)

- `cli.parse(rawArgs)`: Bind arguments to active session.
- `cli.has('force', 'f')`: Check for boolean flags or short aliases (`--force`, `-f`).
- `cli.get('concurrency', 4)`: Get typed option value (`--concurrency=8` or `-c 8`).
- `cli.list()`: Get positional non-option arguments list.

---

## Real-World Recipes

### Recipe: Multi-Stage Web Scraper with File Downloads
```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final app = crawl.engine(concurrency: 4, base: 'library');

  app.tag('book', (res) async {
    final title = fs.sanitize(res.$('h1').text, full: true);
    final cover = res.src('.cover img');
    if (cover != null) {
      await res.save('covers/$title.jpg', cover);
    }
  });

  app.route(RegExp(r'/catalogue/'), (res) {
    for (final a in res.$('.product_pod h3 a')) {
      res.follow(a.attr('href')!, tag: 'book');
    }
  });

  await app.run(['https://books.toscrape.com/catalogue/page-1.html']);
  console.logger.ok('All books crawled and covers saved.');
}
```

### Recipe: Interactive Deployment Script
```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  cli.parse(args);
  sys.listen();

  console.writer.rule('Deployment Tool');
  final env = console.reader.pick('Select target environment:', ['staging', 'production']);
  final proceed = console.reader.confirm('Deploy to $env?', false);
  if (!proceed) sys.exit(0);

  final spinner = console.spin('Building artifacts...');
  final res = await sys.run('dart', ['compile', 'exe', 'bin/server.dart', '-o', 'dist/server']);
  if (!res.ok) {
    spinner.fail('Build failed!');
    sys.exit(1);
  }
  spinner.ok('Build complete.');

  console.logger.ok('Deployed successfully to $env!');
}
```

---

## Running Tests

```bash
dart test
```

## Running Code Analysis

```bash
dart analyze
```

---

## License

MIT License &copy; 2026 feiluvnana
