# Dart Script Toolkit (`dart-toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.0%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A modern, highly concise, and cohesive automation scripting toolkit for Dart developed by **feiluvnana**. Designed from the ground up for writing clean, readable, command-line automation and web scraping scripts with **strictly 1-word methods** and **Java-style hierarchical domain namespaces**:

### Hierarchical Domain Namespaces (Java-style)

| Domain | Sub-Namespaces | Focus Area |
| :--- | :--- | :--- |
| **`io.*`** | `io.file.*`, `io.csv.*`, `io.store.*` | File operations, atomic writes, paths, CSV tables, persistent key-value store, 7-Zip archives |
| **`net.*`** | `net.http.*`, `net.crawl.*`, `net.$()` | HTTP requests, streaming downloads, web crawler engine, jQuery-like CSS selectors |
| **`system.*`** | `system.env.*`, `system.cli.*`, `system.on.*` | Subprocess execution, environment variables, CLI args, graceful shutdown signals |
| **`concurrent.*`** | `concurrent.run(...)`, `concurrent.pool(...)` | Bounded asynchronous task pool, ordered worker execution |
| **`util.*`** | `util.time.*`, `util.git.*`, `util.console.*` | Delays, timestamps, Git automation, terminal formatting, tables, prompts |

---

## Design Philosophy

1. **Strictly 1-Word Methods**: All primary actions are exactly one word (`run`, `get`, `post`, `save`, `follow`, `emit`, `stop`, `step`, `ok`, `warn`, `fail`, `info`, `ask`, `pick`, `which`, `clock`).
2. **Java-Style Domain Namespaces**: Organized into 5 cohesive root domains (`io`, `net`, `system`, `concurrent`, `util`) without loose flat aliases.
3. **Batteries Included**: Zero external utility dependencies required in user scripts. Built-in path manipulation (`io.join`, `io.base`), atomic writing (`.part` staging), and ANSI terminal formatting.
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
  // 1. Parse CLI arguments via system domain
  system.cli.parse(rawArgs);
  final force = system.cli.has('force', 'f');
  final poolSize = system.cli.get('concurrency', 4);

  // 2. Setup graceful shutdown & stopwatch
  system.listen();
  final clock = system.clock();

  // 3. Web Crawling & Scraping with Engine
  util.console.logger.step(1, 4, 'Crawling news headlines...');
  final titles = await net.crawl('https://news.ycombinator.com')
      .concurrent(poolSize)
      .collect<String>((res) {
        for (final title in res.$('.titleline > a').texts) {
          res.emit(title);
        }
      });
  util.console.logger.ok('Found ${titles.length} news items.');

  // 4. Concurrently process items with progress bar
  util.console.logger.step(2, 4, 'Processing documents...');
  final bar = util.console.bar(titles.take(10).length, 'Processing');

  final processed = await concurrent.run(titles.take(10), (title) async {
    await util.time.wait(50);
    bar.tick(1, title);
    return title.toUpperCase();
  }, size: poolSize);
  bar.done('Processing finished!');

  // 5. Output summary table
  util.console.logger.step(3, 4, 'Generating summary...');
  util.console.writer.table(['Metric', 'Value'], [
    ['Total Crawled', titles.length],
    ['Total Processed', processed.length],
    ['Elapsed Time', io.time(clock.elapsed)],
  ]);

  // 6. Save output atomically (.part staging)
  util.console.logger.step(4, 4, 'Saving output...');
  final dest = io.join('output', 'summary.txt');
  if (force || !io.has(dest)) {
    await io.write(dest, processed.join('\n'));
    util.console.logger.ok('Saved output to $dest');
  }

  util.console.logger.ok('Completed in ${io.time(clock.elapsed)}!');
  system.unlisten();
}
```

---

## Domain Reference

### 1. `io.*` &mdash; File Operations, Paths, CSV & Key-Value Storage
[File Guide &rarr;](docs/fs.md) | [CSV Guide &rarr;](docs/csv.md) | [Store Guide &rarr;](docs/store.md)

- **Zero-Dependency Path Manipulation (`io.*` / `io.file.*`)**:
  - `io.join(p1, [p2, p3...])`: Safe path join with slash normalization.
  - `io.base(path)`: Filename with extension (`archive.tar.gz`).
  - `io.name(path)`: Filename without extension (`archive.tar`).
  - `io.ext(path)`: Extension including dot (`.json`).
  - `io.dir(path)`: Parent directory path.
- **Atomic Operations & Downloads**:
  - `io.write(file, content)`: Atomic write with `.part` staging and signal cleanup.
  - `io.json(path, [data, pretty])`: Read or atomically write parsed JSON data.
  - `io.lines(path)`: Stream lines from large files asynchronously without loading all into RAM.
  - `io.hash(path, [algo])`: Compute SHA-256 or MD5 cryptographic file checksums.
  - `io.stat(path)`: Get file/directory metadata and modification timestamps.
  - `io.read(path)` / `io.bytes(path)`: Read string or raw bytes.
  - `io.download(url, dest)`: Direct streaming HTTP download to file with `.part` protection.
  - `io.mkdir(path)`: Recursive directory creation.
  - `io.copy(src, dest)` / `io.move(src, dest)`: Copy or move files, ensuring parent directories.
  - `io.delete(dir, [pattern])`: Delete files matching glob/regex.
  - `io.find(dir, [pattern])`: Find matching files recursively.
  - `io.has(path, [match])`: Check if file exists and has size > 0.
- **Formatters & Sanitize**:
  - `io.size(bytes)` / `io.parse(sizeStr)`: Human size formatting (`5.0 MB`) and parsing.
  - `io.time(duration)`: Human duration formatting (`02:15`).
  - `io.sanitize(name, [full])`: Sanitize filename for local OS.
  - `io.temp([prefix])`: Create temporary directory.
- **Archive Management (`io.archive(path)`)**:
  - `final arc = io.archive('bundle.7z');`
  - `arc.sync(dir, {force, changed})`: Integrity test and compress into 1-volume archive.
  - `arc.check()`: Test integrity via 7z.
  - `arc.zip(dir)`: Compress directory into archive.
  - `arc.wipe()`: Delete archive and split volumes.
- **CSV Serialization & Parsing (`io.csv.*`)**:
  - `io.csv.parse(text, {delimiter})`: Parse RFC-4180 CSV text into a matrix `List<List<String>>`.
  - `io.csv.format(data, {headers, delimiter})`: Convert maps or matrix into RFC-4180 CSV string.
  - `await io.csv.read(file, {header})`: Read CSV file as `List<Map<String, String>>` or matrix.
  - `await io.csv.write(file, data, {headers})`: Atomically write maps or matrix to CSV with `.part` staging.
- **Key-Value Storage (`io.store.*`)**:
  - `final db = io.store.open(filePath)`: Open or create persistent JSON key-value store file.
  - `db.get<T>(key, [fallback])` / `db.set(key, val)`: Get typed value or set value.
  - `db.has(key)` / `db.delete(key)` / `db.clear()`: Inspect and mutate keys.
  - `await db.save([path])`: Atomically write store data to JSON file with `.part` staging.
  - `db.load([path])`: Reload data from backing file.
  - `db.map()`: Snapshot map of store contents (`Map<String, Object?>`).

---

### 2. `net.*` &mdash; HTTP Networking, Web Crawling & DOM Selectors
[HTTP Guide &rarr;](docs/http.md) | [Crawler Guide &rarr;](docs/crawl.md)

- **Quick Requests (1-word, `net.*` / `net.http.*`)**:
  - `final res = await net.get(url);`
  - `final res = await net.post(url, body: data);`
  - `await net.put(url, body: data);`
  - `await net.delete(url);`
  - `await net.patch(url, body: data);`
  - `await net.head(url);`
- **`HttpResponse` Methods & Properties**:
  - `res.ok`, `res.status`, `res.body`, `res.json`, `res.lines`
  - `res.$(selector)`: Query HTML DOM using jQuery-like CSS selector.
  - `res.link()` / `res.links()`: Extract resolved absolute links.
  - `res.src()` / `res.srcs()`: Extract resolved absolute media/script source URLs.
  - `await res.save(filePath, [sourceUrl])`: Save response bytes or download linked asset atomically.
- **Streaming & Syncing**:
  - `await net.download(url, destPath, {onProgress})`: Stream download directly with `.part` protection.
  - `await net.sync(mapOrList, {concurrency, match, prefix})`: Concurrently download and synchronize assets.
  - `final client = net.http.client({headers, retries, backoff, base, timeout})`: Configured session.
- **Fluent Web Crawling (`net.crawl.*`)**:
  - `await net.crawl(urls).concurrent(n).delay(d).retry(r).base(...).tag(...).run(process)`: Builder pattern.
  - `await net.crawl(urls).concurrent(n).collect<T>(process)`: Collect emitted items into a typed `List<T>`.
  - `final engine = net.crawl.engine({concurrency, delay, base, downloader, deduplicator});`: Direct engine coordinator.
  - `res.follow(url, {tag, meta, priority})`: Schedule URL to crawl next with relative resolution.
  - `res.emit(item)`: Emit structured scraped record to stream or collector.
  - `res.save(filePath, [sourceUrl])`: Save response body or stream remote asset to disk atomically.
- **DOM Queries & Traversal (`net.$()` / `net.query()`)**:
  - Traversal: `find()`, `filter()`, `not()`, `children()`, `parent()`, `closest()`, `siblings()`, `prev()`, `next()`, `eq()`.
  - Content: `text`, `texts`, `lines`, `html`, `val()`, `data()`, `attr(name)`, `attrs(name)`.
  - Assets: `link()`, `links()`, `src()`, `srcs()`.

---

### 3. `system.*` &mdash; Process, Signals, CLI & Environment
[Process Guide &rarr;](docs/sys.md) | [CLI Guide &rarr;](docs/cli.md) | [Environment Guide &rarr;](docs/env.md)

- **Subprocess & OS Execution (`system.*`)**:
  - `system.run(binary, args, [cwd, inherit, echo, timeout])`: Run external command with execution timeout and return `SysResult`.
  - `system.which(tool)`: Search executable in PATH.
  - `system.clock()`: Start benchmark stopwatch.
  - `system.win`, `system.mac`, `system.nix`: Platform detection shortcuts.
  - `system.listen()` / `system.unlisten()`: Catch or unregister Ctrl+C signals for graceful shutdown.
  - `system.track(file)` / `system.untrack(file)`: Track temporary files to delete on abort.
  - `system.on.exit(() => ...)` / `system.hook(fn)`: Register cleanup hooks.
  - `system.exit([code])` / `system.now([code])`: Clean or immediate process exit.
- **Command-Line Interface (`system.cli.*`)**:
  - `system.cli.parse(rawArgs)`: Bind arguments to active session.
  - `system.cli.has('force', 'f')`: Check for boolean flags, negative flags, or short aliases (`--force`, `-f`, `--no-force`).
  - `system.cli.no('compress')`: Check whether negative flag `--no-compress` was passed.
  - `system.cli.all('tag')`: Get all occurrences of an option list (e.g. `--tag a --tag b`).
  - `system.cli.get('concurrency', 4)`: Get typed option value (`--concurrency=8` or `-c 8`).
  - `system.cli.list()`: Get positional non-option arguments list.
  - `system.cli.help(usage: '...', flags: {...}, options: {...})`: Render formatted CLI usage help screen.
- **Environment & `.env` Loader (`system.env.*`)**:
  - `system.env.load([path, overwrite])`: Load `.env` file into session with comments, quotes, and multiline escapes.
  - `system.env.get('HOST', 'localhost')`: Get environment string with default fallback.
  - `system.env.int('PORT', 8080)`: Read and parse integer environment variable.
  - `system.env.double('RATE', 1.0)`: Read and parse double environment variable.
  - `system.env.bool('DEBUG', false)`: Read and parse boolean (`true`, `1`, `yes`, `on`).
  - `system.env.has('KEY')`: Check if variable exists and is non-empty.
  - `system.env.set('KEY', val)` / `system.env.delete('KEY')` / `system.env.clear()`: Manage session overrides.
  - `system.env.map()`: Merged map of system environment and session overrides.

---

### 4. `concurrent.*` &mdash; Concurrency & Task Pooling
[Concurrency Guide &rarr;](docs/parallel.md)

- `concurrent.run(items, worker, {size: 4, delay})`: Run async tasks concurrently strictly preserving input order.
- `final pool = concurrent.pool(8, Duration(milliseconds: 100));`: Custom pool with rate-limiting delay, `pool.on.start()`, `pool.on.progress()`, `pool.on.done()`, `pool.on.error()`.

---

### 5. `util.*` &mdash; Time, Git Automation & Console Formatting
[Console Guide &rarr;](docs/console.md) | [Git Guide &rarr;](docs/git.md) | [Time Guide &rarr;](docs/time.md)

- **Terminal Formatting & Prompts (`util.console.*`)**:
  - **Loggers (`util.console.logger.*`)**: `step()`, `ok()`, `warn()`, `fail()`, `error()`, `info()`, `debug()`, `level`, `task()`.
  - **Visual Output (`util.console.writer.*`)**: `table()`, `box()`, `rule()`, `bar()`, `spin()`.
  - **Interactive Prompts (`util.console.reader.*`)**: `ask()`, `confirm()`, `pick()`, `picks()`, `secret()`, `line()`.
  - **ANSI Extensions**: `'text'.bold()`, `'text'.dim()`, `'text'.green()`, `'text'.red()`, `'text'.yellow()`, `'text'.cyan()`, etc.
  - **Terminal Geometry**: `util.console.terminal.width`, `util.console.terminal.height`, `util.console.terminal.clear()`.
- **Git Automation (`util.git.*`)**:
  - `await util.git.branch()`: Current branch name (`master`, `main`).
  - `await util.git.hash([short])`: Current commit SHA hash.
  - `await util.git.dirty()`: Check whether working tree has uncommitted modifications.
  - `await util.git.status()`: Short porcelain status.
  - `await util.git.tag([name])`: Get current tag or create a new tag.
  - `await util.git.add([pattern])`: Stage files matching pattern (default `.`).
  - `await util.git.commit(msg, {all})`: Create a commit.
  - `await util.git.push([remote, branch])` / `await util.git.pull()`: Synchronize with remote.
  - `await util.git.clone(repo, [dest])`: Clone remote repository.
  - `await util.git.run(args)`: Execute arbitrary git command returning `SysResult`.
- **Time, Delays & Timestamps (`util.time.*`)**:
  - `await util.time.wait(durationOrMs)`: Asynchronously wait for milliseconds or `Duration`.
  - `util.time.stamp([date])`: Filename-safe timestamp string (`20260905_205012`).
  - `util.time.iso([date])`: UTC ISO-8601 formatted timestamp string.
  - `util.time.ago(past, [relativeTo])`: Human relative elapsed time string (`"2m ago"`).
  - `util.time.now()` / `util.time.epoch([date])`: Current `DateTime` and unix epoch milliseconds.
  - `util.time.clock()`: Start benchmark `Stopwatch`.
  - `util.time.sleep(ms)`: Synchronous thread sleep.

---

## Real-World Recipes

### Recipe: Multi-Stage Web Scraper with File Downloads
```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final app = net.crawl.engine(concurrency: 4, base: 'library');

  app.tag('book', (res) async {
    final title = io.sanitize(res.$('h1').text, full: true);
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
  util.console.logger.ok('All books crawled and covers saved.');
}
```

### Recipe: Interactive Deployment Script
```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main(List<String> args) async {
  system.cli.parse(args);
  system.listen();

  util.console.writer.rule('Deployment Tool');
  final env = util.console.reader.pick('Select target environment:', ['staging', 'production']);
  final proceed = util.console.reader.confirm('Deploy to $env?', false);
  if (!proceed) system.exit(0);

  final spinner = util.console.spin('Building artifacts...');
  final res = await system.run('dart', ['compile', 'exe', 'bin/server.dart', '-o', 'dist/server']);
  if (!res.ok) {
    spinner.fail('Build failed!');
    system.exit(1);
  }
  spinner.ok('Build complete.');

  util.console.logger.ok('Deployed successfully to $env!');
  system.unlisten();
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
