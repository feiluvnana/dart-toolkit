# Dart Script Toolkit (`dart-toolkit`)

A modern, lightweight automation and scripting framework for Dart developed by **feiluvnana**. Designed for writing clean, concise command-line automation scripts with **1-word methods** and **6 intuitive lowercase namespaces**:

- **`console.*`**: Terminal styling, formatted tables, progress bars, spinners, and interactive input (`console.writer.*`, `console.reader.*`).
- **`fs.*`**: Atomic file operations, built-in path helpers (`fs.join`, `fs.base`), and 7-Zip archiving (`fs.archive()`).
- **`crawl.*`**: Web scraping, streaming HTTP downloads, batch asset syncing, and jQuery-like DOM parsing (`$()`).
- **`parallel.*`**: Concurrent task pooling and async iteration.
- **`sys.*`**: Subprocess execution, signals, timers, and graceful shutdown.
- **`cli.*`**: Command-line flag and option parsing.

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

  // 3. Web Crawling & Scraping
  console.step(1, 4, 'Crawling target...');
  final res = await crawl.get('https://example.com/items');
  final links = res.$('a').links('.pdf');

  // 4. Concurrently download assets with progress bar
  console.step(2, 4, 'Downloading documents...');
  final bar = console.bar(links.length, 'Downloads');

  await parallel.run(links, (link) async {
    final dest = fs.join('downloads', fs.base(link));
    if (!force && fs.has(dest)) return;
    await fs.download(Uri.parse(link), dest);
    bar.tick(1, link);
  }, size: poolSize);
  bar.done();

  // 5. Output summary table
  console.step(3, 4, 'Generating summary...');
  console.writer.table(['File', 'Size'], [
    for (final f in fs.find('downloads')) [f.path, fs.size(f.lengthSync())]
  ]);

  // 6. Compress into 7z archive
  console.step(4, 4, 'Creating archive...');
  final arc = fs.archive('bundle.7z');
  await arc.sync('downloads');

  console.ok('Completed in ${fs.time(clock.elapsed)}!');
}
```

---

## Namespace Reference

### 1. `console.*`

- **Status & Logging**:
  - `console.step(n, total, msg)`: Step header `[1/4] Starting workflow...`
  - `console.ok(msg)`: Green check mark `✔ Success`
  - `console.warn(msg)`: Yellow warning `⚠ Warning`
  - `console.fail(msg)` / `console.error(msg)`: Red cross `✖ Failure`
  - `console.info(msg)`: Blue info `ℹ Notice`
  - `console.task(msg, fn)`: Run an async task wrapped in status indicator.
- **Visual Output (`console.writer.*`)**:
  - `console.writer.table(headers, rows)`: Formatted ASCII/Unicode tables.
  - `console.writer.box(text, [title])`: Text wrapped in a bordered callout box.
  - `console.writer.rule([title])`: Horizontal divider rule with centered text.
  - `console.writer.bar(total, [msg])`: Interactive progress bar (`bar.tick()`, `bar.done()`).
  - `console.writer.spin([msg])`: Terminal spinner (`spin.update()`, `spin.ok()`, `spin.fail()`).
- **Interactive Prompts (`console.reader.*`)**:
  - `console.reader.ask(prompt, [default])`: Text input with optional default value.
  - `console.reader.confirm(prompt, [default])`: Yes/No boolean prompt `[Y/n]`.
  - `console.reader.pick(prompt, options)`: Single-choice selection menu.
  - `console.reader.secret(prompt)`: Masked input for sensitive tokens/passwords.
  - `console.reader.line()`: Read raw line from standard input.
- **Terminal Geometry & Cursor**:
  - `console.terminal.width`, `console.terminal.height`, `console.terminal.clear()`
  - `console.cursor.hide()`, `console.cursor.show()`, `console.cursor.up()`, `console.cursor.down()`

---

### 2. `fs.*`

- **Built-in Path Utilities (No `package:path` needed)**:
  - `fs.join(p1, [p2, p3...])`: Safe path join.
  - `fs.base(path)`: Extract filename with extension.
  - `fs.name(path)`: Extract filename without extension.
  - `fs.ext(path)`: Extract extension (`.txt`).
  - `fs.dir(path)`: Extract parent directory path.
- **Atomic File Operations**:
  - `fs.write(file, content)`: Atomic write with `.part` staging and signal cleanup.
  - `fs.read(path)` / `fs.bytes(path)`: Read string or raw bytes.
  - `fs.download(url, dest)`: Direct streaming HTTP download to file with `.part` protection.
  - `fs.mkdir(path)`: Recursive directory creation.
  - `fs.copy(src, dest)` / `fs.move(src, dest)`: Copy or move files, ensuring parent directories.
  - `fs.delete(dir, [pattern])`: Delete files matching glob/regex.
  - `fs.find(dir, [pattern])`: Find matching files recursively.
  - `fs.has(path, [match])`: Check if file exists and has size > 0.
  - `fs.size(bytes)` / `fs.parse(sizeStr)`: Human-readable size formatting (`5.0 MB`) and parsing.
  - `fs.time(duration)`: Human-readable duration (`02:15`).
  - `fs.sanitize(name, [full])`: Sanitize filename for local OS.
  - `fs.temp([prefix])`: Create temporary directory.
- **Archive Management (`fs.archive(path)`)**:
  - `final arc = fs.archive('bundle.7z');`
  - `arc.sync(dir, {force, changed})`: Integrity test and compress into 1-volume archive.
  - `arc.check()`: Test integrity via 7z.
  - `arc.zip(dir)`: Compress directory into archive.
  - `arc.wipe()`: Delete archive and split volumes.

---

### 3. `crawl.*` & `$()`

- **Engine-Powered Crawling**:
  - `crawl.run(startUrls, (res) async { ... }, {concurrency, base, dl})`: Multi-step recursive crawl.
  - `crawl.collect(startUrls, (res) { res.emit(item); })`: Collect emitted items directly into a `List<T>`.
  - `final engine = crawl.engine({concurrency, base, dl});`:
    - `engine.route(pattern, (res) => ...)`: Route requests matching URL pattern.
    - `engine.tag(tagName, (res) => ...)`: Handle requests tagged with specific label.
    - `engine.on.progress((res) => ...)`: Progress callback per completed request.
    - `engine.run(urls)`: Execute crawling workflow.
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

### 4. `parallel.*`

- `parallel.run(items, worker, {size: 4})`: Run async tasks concurrently.
- `parallel.map(items, mapper, {size: 4})`: Map items concurrently preserving order.
- `parallel.each(items, worker, {size: 4})`: Fire-and-forget concurrent iteration.
- `final pool = parallel.pool(8);`: Custom pool with `pool.on.progress()`, `pool.on.done()`, `pool.on.error()`.

---

### 5. `sys.*` / `proc.*`

- `sys.run(binary, args, [cwd, inherit, echo])`: Run external command and return `ProcResult`.
- `sys.which(tool)`: Search executable in PATH.
- `sys.clock()`: Start benchmark stopwatch.
- `sys.listen()`: Catch Ctrl+C signals for cleanup.
- `sys.track(file)` / `sys.untrack(file)`: Track temporary files to delete on abort.
- `sys.on.exit(() => ...)` / `sys.hook(fn)`: Register cleanup hooks.
- `sys.exit([code])` / `sys.now([code])`: Immediate clean exit.
- `sys.env('KEY')`: Read environment variable.

---

### 6. `cli.*`

- `cli.parse(rawArgs)`: Bind arguments to active session.
- `cli.has('force', 'f')`: Check for boolean flags or short aliases (`--force`, `-f`).
- `cli.get('concurrency', 4)`: Get typed option value (`--concurrency=8` or `-c 8`).
- `cli.list()`: Get positional non-option arguments list.

---

## License

MIT License.
