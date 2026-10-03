# Changelog

## Unreleased

### Audit VI

#### Upgrading

| Before | After |
|---|---|
| `Themed(theme, child)` | `child.themed(theme)` (beside `.fixed`, `.flex`, `.percent`) |

#### Added

- `Path.compressTo`: unified container archiving (`.zip`, `.7z`, `.tar.*`) and single-stream compression (`.gz`, `.xz`, `.zst`, `.bz2`).
- `Path.decompressTo`: unified extraction/decompression supporting container archives (`.zip`, `.7z`, `.rar`, `.tar.*`) to directories with `flatten: true`, and single-stream formats (`.gz`, `.xz`, `.zst`, `.bz2`) to files.
- `Path.bundle({String? destination, bool cleanup, bool flatten})`: bundles a folder or file into an archive (default `parent / '$name.zip'`), with optional `flatten: true` and `cleanup: true`.
- `Path.unbundle({bool cleanup, bool flatten})`: unbundles archives in-place into their parent folder, with optional `flatten: true` and `cleanup: true` to remove the archive afterward.
- `Path.packTo` & `Path.unpackTo`: ergonomic aliases for `compressTo` and `decompressTo`.
- `HtmlDocument.links`: document-wide links getter, extracting URLs from `a[href]`, `area[href]`, `link[href]`, `[src]`, and JavaScript `[onclick]`.
- `Element.link` & `Elements.links`: extracts URLs from `href`, `src`, and JavaScript navigation in `onclick` (`location.href`, `window.open`, etc.).
- `Uri.canonical` & `Uri.canonicalize`: URL canonicalization for crawling/deduplication (cleaning empty tokens/values, sorting query keys, removing default ports, and stripping fragments).
- `Path.files` & `Path.dirs`: added `followLinks` parameter, and `extensions` filtering parameter on `Path.files`.
- `Path.move` & `Path.copy`: added `overwrite: false` parameter to safely overwrite existing targets.
- `String` ergonomic helpers: `.after`, `.afterLast`, `.before`, `.beforeLast`, `.between`, `.remove`, `.removeAll`, `.removePrefix`, `.removeSuffix`, `.unquote`, `.collapseWhitespace`, `.lines`, `.words`, `.containsAny`, `.containsAll`.
- `StringIterableExtensions`: `.trimmed`, `.nonEmpty`, `.cleaned`, `.collapsed`, `.matching`, `.without`, `.remove`, `.unquoted` on `Iterable<String>`.
- `Stream.distinctBy([key])`: emits each item once by `==` (or by `key`), keeping the first element seen.
- `Scrape.distinctBy()` and `InitContext.distinct`: drops duplicate emitted items across the crawl.
- `Io.reset()` clears `Io.color` too, so a teardown is `tearDown(Io.reset)`.
- `Uri.name`: the last path segment, as `Path.name` — `dir / u.name`, not `u.pathSegments.last`
  (which throws on a bare host).
- `Doc.html(text, url: …)`: links resolve against a saved page's address from the facade.
- `path.relativeTo()` with no argument is relative to the working directory.
- `Hash.crc32.checksum(bytes)` and `.fileChecksum(path)`: the int checksum from the facade.

#### Removed

- `Sequence`: `Table` operates directly on standard `List<Row>`, and `IterableNumExtensions` provides `sum`, `average`, `min`, `max` on numbers.

#### Fixed

- `FileBridge._openTemp`: catches Windows error code 123 (`ERROR_INVALID_NAME`) when a filename leaves no room for a temporary name.
- `Path.sanitized`: retains forward slashes on Windows when the path contains forward slashes.

### Audit V

#### Upgrading

| Before | After |
|---|---|
| `Hash.sha256.fileBytes(p)` | `Hash.sha256.fileDigest(p)` (raw bytes, beside `digest`) |
| `Hash.sha256.hmacBytes(key, data)` | `Hash.sha256.hmac(key, data)` (hex, like `data.hmac(…)`) |
| `TuiTheme(error: …)`, `theme.error` | `TuiTheme(danger: …)`, `theme.danger` (as `ConsoleTheme` names it) |
| `retry(f, attempts: 3)` (total tries) | `retry(f, retries: 2)` (extra tries, as `Http.scope(retries:)`); the default is still 3 tries |

#### Faster

- `formats` no longer imports `fs` (so not `hash`, `native`, `dart:ffi` or `path` either):
  startup over bare 443 → 239 ms and 366 → 269 ms. `JsonDocument.save` and `Path.writeBytes`
  share one atomic write in `core`; `save` keeps an odd file mode by writing in place.
- `Table.length`/`isEmpty`/`isNotEmpty` after `orderBy` no longer run the sort: 1M rows
  400 → <1 ms.
- A sitemap's `<loc>` is HTML-decoded only when it holds `&` or `<`: 50k plain URLs 9 → 2 ms.
- `glob` no longer keeps every pattern's `RegExp` forever; one compile per call, before the walk.
- `Io.width` returns a printable-ASCII string's length without the ANSI and rune scans (every
  `Table.show` cell, TUI measure, Console redraw): 1M 40-char cells ~110 → ~20 ms.

#### Added

- `Doc.table(path)`: a CSV, TSV, JSON or NDJSON file from the `Doc` facade (forwards to `Table.read`).
- A flag can default to on: `Opt.flag('color').or(true)`, turned off by `--no-color`; help shows
  `--[no-]color` and `[default: true]`, and shell completion offers `--no-color`.

#### Fixed

- `TaskState` was declared in both `cli` and `tui`, so a file importing the barrel and
  `tui.dart` could not name it (ambiguous import). It is now one enum in `core`, re-exported by
  both.
- `ctx.submit` of a GET form dropped repeated keys in the form's `action` (`?tag=a&tag=b` sent
  only `tag=b`); it now merges with `withQuery`.
- An atomic write to a 235–255-byte file name failed with "File name too long": the temporary
  name did not fit. It now writes in place.
- `Io.width` counted a ZWJ emoji sequence (`👨‍👩‍👧`) as each emoji; it is one glyph, and
  `Io.truncate` keeps or cuts it whole.
- `humanBytes` and `humanized` left a negative value unscaled (`-1536 B`, `-90000ms`); they now
  read `-1.5 KB` and `-1m 30s`.
- `sanitized` split a POSIX name on `\`, so `r'a\b'` became folder `a` and file `b`; `\` is a
  separator only on Windows.
- `changes()` on a file in a missing folder waited forever; the stream now fails with
  `PathNotFoundException`.
- `Table.save` replaced a symlink with a plain file and dropped the old file's mode; it now
  writes through the same atomic write as `Path.writeText`.
- `orderBy(…).take(-1)` returned an empty table on 8+ rows but threw on fewer; it always throws
  `RangeError`.
- `toMarkdown` left a `|` or newline in a header unescaped, adding a column.
- TOML accepted `0123`, `1__0`, `_1` and `2024-01-01zzz` (as text), and read `"a\ b"` as `ab`;
  each is now a `FormatException`, as TOML 1.0 says.
- `.markup` of an XML text node holding a carriage return (`&#13;`) wrote it raw, so a re-parse
  read a newline; it now writes `&#13;`.
- A YAML alias bomb (a few nested anchors) parsed instantly and then expanded to billions of
  nodes in whatever walked it; aliases may now expand to 1 000 000 nodes.
- `base32Bytes` upper-cased with Unicode rules, so `ſ` decoded as `S`, and it accepted lengths
  nothing encodes to (`'A'` gave no bytes); both are now a `FormatException` naming the input.
- `Pool.close` could return while a queued item still ran, never closing that worker (an
  isolate and its port leaked): a worker handed from one item to the next looked idle for a
  moment. It now waits for the handed item.
- `map(…, ordered: true)` kept pulling the source while one slow early item held up the output,
  buffering every later result; a buffered result now holds its place against `size`.
- `Pool.spawn` rethrew a failed `Worker.init` without its stack.
- `run(…).timeout(limit)` threw at the limit but left the command running; it now stops it and
  everything it started, throwing `ShellTimeoutException` with what was printed.
- `kill()` on a command that had already ended still listed every process to signal its dead
  tree, and kept those pids for the exit-time SIGKILL; it now does nothing.
- On Windows a command run through `cmd /d /c` checked its arguments for `&|<>^%"` but not the
  program name (`run('"a&calc"')`); both are checked (unverified on Windows).
- A ^C at `Console.secret` left through the prompt's own signal watch, cutting off the
  `Lifecycle.onExit` listeners (Chrome, children, cleanup) mid-run; it now leaves through
  Lifecycle's handler like any other signal.
- `Console.secret` trimmed the answer, so a password with a leading or trailing space failed.
- A click on a `Menu` or `Grid` whose filter matched nothing threw `RangeError` and ended the
  app.
- A `Grid` with a `0` in `widths` threw on a terminal narrower than its gaps.
- `Gauge(done / total)` with nothing to do (`0 / 0`) drew a full bar.
- A ^C or SIGHUP reaching the shell a launched Chrome runs under ended its wait early: it
  erased the profile and killed the watcher while Chrome kept running, orphaned. It now waits
  until Chrome is gone.
- `ChromeClient.open(url)` and `page(url, …)` leaked the tab when the navigation failed (a bad
  host in a loop piled up tabs); a tab whose set-up failed leaked the same way.
- A pooled tab that crashed or was closed under the client (by its own `window.close()`, or a
  person) went back to the pool and failed every request after; it now leaves the pool.
- A page script that threw reported "Page script failed: Uncaught"; it now carries what was
  thrown. A protocol error names the method that failed.

#### Removed

- `Path.readDoc`/`readJson`/`readYaml`/`readToml`/`readIni`/`readHtml`/`readXml` →
  `Doc.read(p)`, or `(await p.readText()).yaml` and friends.
- `select`, `xpath` (on `Element`, `Elements`, `HtmlDocument`, `XmlDocument`) and
  `JsonDocument.query` → `$` and `$x`.
- `Doc.parseJson`/`parseYaml`/`parseToml`/`parseIni`/`parseHtml`/`parseXml` and `typedef Document`
  → `Doc.json`, `Doc.yaml`, … on `Doc`.
- `xs.parallel(f)` → `xs.parallelize(f).unwrap()`.
- `zip`/`zipTo` on `Path` → `archive('x.zip')`/`archiveTo('x.zip')`.
- `registerHaltedProcessPids`, `unregisterHaltedProcessPids`, `killHaltedProcesses`,
  `killHaltedProcessesSync` → `ProcessBridge.registerHalted`, …
- `TuiTheme`'s `borders`, `barFill`, `barEmpty`, `barHead`, `spinner` (parameters and getters) →
  `border`, `fill`, `empty`, `head`, `frames`, the names `ConsoleTheme` uses.
- `ChromeClient.isOpen`, `ChromePage.isOpen` → `!isClosed`.
- `ChromePage.textOrNull`/`attrOrNull` → `text`/`attr`, which already return `null` on a miss.
- The implicit constructors `Env()`, `Io()`, `Cancel()`, `Shell()`, `Http()`: the five are
  `abstract final` namespaces now, like `Doc`, `Fs` and `Secure`.

### Console themes, a TUI framework, and a second bug hunt

#### Upgrading

| Before | After |
|---|---|
| `sdk: ^3.10.0` | `sdk: ^3.8.0` (checked on Dart 3.8.0) |
| `row.get<int>('price')` on `2.7` gave `2` | `null` from `getOrNull`, a `StateError` from `get`; whole numbers (`3.0`) still read as `int` |
| `doc['t'].to<DateTime>()` read `2024-02-30` and `"12345678"` | needs a `YYYY-MM-DD` start with real field values |
| `doc['x'].or(false)` in an untyped context returned the raw value | converts by the fallback's type |
| `api / 'projects:batchGet'` was a scheme | a path segment |
| XPath `contains("a")` silently used the context | a `FormatException` at parse (arity and unknown names are checked) |
| an indented `[x]` line right after an INI key | a continuation of that key, as in configparser |
| a cancelled `download()` reported only what had started | files never started count as failed, so `show()` reports the true "N of M failed" |
| non-UTF-8 terminals got ASCII spinner frames only | the whole `ConsoleTheme.ascii` (marks, rule, borders, tree) |

#### Added

- `ConsoleTheme` (palette, marks, frames, bar glyphs, `Border`, prompt marks), with
  `Console.theme = …` and `Console.themed(theme, body)`.
- Per-component builders over typed views:
  - `line:` on `Console.progress`/`spinner`/`spin`;
  - `task:` and `header:` on `Console.tasks` and `.show()`;
  - `cell:` on `Table.show`.

  The views are `ProgressView`, `SpinnerView`, `TaskView` and `BatchView`. They carry `index`,
  `count`, `name`, `state`, `bytes`, `speed`, `eta`, `bar(width)` and the active theme.
- The download board shows a smoothed speed and an ETA.
- `Table.show(border:, align:, cell:)`. `Border` (in `core`, shared with `Tui`) has the presets
  `square`, `rounded`, `double`, `heavy`, `ascii`, `markdown` and `none`.
- `num.humanBytes` (was `int`).
- `package:dart_toolkit/tui.dart`, outside the barrel:
  - `Tui.run` (full screen) and `Tui.inline`, both Elm-style; `TuiApp` as the class form.
  - Widgets: `Label`, `VStack`/`HStack` (`.fixed`/`.flex`/`.percent`), `Box`, `Menu`, `Grid`,
    `Tabs`, `Field`, `Gauge`, `Spin`, `Paint`, `Themed`.
  - `Choice` (filter, multi), `TuiTheme`, builder contexts.
  - Typed `Key`/`Char`/`Paste`/`Mouse`/`Resize` events; a diffed cell buffer with colour downgrade.
  - The `Terminal` seam and `FakeTerminal` for tests.
- `tk pick [glob]`: type to filter, print the chosen path.
- `IoBridge.restores`: `Lifecycle.exit` puts a running TUI's terminal back before it exits.

#### Fixed

- Chrome:
  - A site's 401 was answered with the proxy password.
  - Proxy passwords were sent percent-encoded.
  - `cookies()` threw on cookies like `a=x,y`.
  - `press('.')` acted as Delete.
  - Concurrent `waitForDownload`s lost files.
  - `block:` did not reach cross-origin iframes.
  - `screenshot(selector:)` cut off padding and border.
  - `waitForDownload(() => goto(file))` threw.
  - A frame view used after `close()` spun until its timeout.
  - IPv6 proxies lost their brackets.
  - Stealth sent empty `userAgentData` brands.
- HTTP:
  - A nested scope turned off the outer scope's `retries`.
  - A crawl timeout left the hung request holding its socket.
  - Each scoped request leaked a cancel listener.
  - `cache:` leaked a file when a send failed.
  - robots.txt and sitemaps were asked with the seed's query.
  - One bad `href` failed the whole page.
  - Cancelling during `onInit` did not stop the crawl.
  - A batch outside a scope opened a client per file.
  - `pages: 0` hung.
- Core:
  - A `Pool` whose replacement worker failed to start hung its queue, and `close()` with it.
  - A cancelled `parallelize(isolate: true)` still ran an item.
  - `pivot` lost keys when a value named the rows column.
  - `thenBy` after `select`/`derive` lost the earlier order.
  - `'-0X10'` read as a number.
  - `1048575.humanBytes` gave `1024.0 KB`.
  - `.env`: a stray quote swallowed the lines up to the next quote.
- Formats:
  - XPath `*` matched the document node.
  - A positional step on nested inputs came back out of order.
  - `true() > false()` was false, and `string(1e15)` gave `1e+15`.
  - A rowspan past a short row landed in the wrong row.
  - `</script/>` swallowed the page.
  - `to<int>` clamped huge doubles.
  - YAML: a quoted `"<<"` merged; `a: &x` followed by a same-indent list failed; `!!str` gave
    `null`; a lone `\r` was not a line break.
  - `doc.$('> body')` matched nothing, and `Elements.$('> li')` was out of order.
  - `<base>` outside `<head>` was ignored.
  - `<pre>&#10;` kept the newline.
  - `C:\cfg.d\settings` was given an extension.
- Files and archives:
  - An atomic write on a full disk emptied the original.
  - The temp file was written before its mode was set.
  - A tar holding a read-only folder failed to extract.
  - `archiveTo('x.zip')` from inside the folder archived the old archive.
  - `archiveTo` hung on a FIFO; FIFOs, sockets and devices are now skipped.
  - `changes()` on a file stopped after one write and reported temp files.
  - A cross-device `move` merged into a non-empty folder.
  - Multi-threaded xz had no memory cap.
  - `filename` kept NUL and control characters.
  - Globs `[]]`, `[!]]` and `b{1}` did not match what they mean.
  - `copy` into itself was missed across relative and absolute paths.
  - `chmod('+w')` ignored the umask.
  - `DART_TOOLKIT_NATIVE=` (empty) disabled the library.
- `keybox` stops instead of zipping an incomplete box set. An unknown batch total shows `?`.
  `filename` collapses newlines and tabs.

#### Smaller

About 1,500 fewer library lines with the same API: comments keep only the *why*, and duplicated
logic is merged.

### Audit IV

About 120 bugs found with real sockets, headless Chrome, ptys and differential fuzzing, each fixed
with a regression test. HTTP readings now check the status, `ffi` is gone, and Chrome has its own
import.

#### Upgrading

| Before | After |
|---|---|
| `await url.json()` / `html()` / `xml()` / `fetch()` | `await url.get().json` / `.html` / `.xml` / `.text` / `.bytes`; each throws `HttpException` unless 2xx. `await url.get()` is still the lenient `Response` |
| `final r = await api.post(json: x); if (!r.isOk) throw …; r.json['id']` | `(await api.post(json: x).json)['id']` |
| `client.fetch(u)` / `client.json(u)` / `client.html(u)` / `client.xml(u)` | `client.get(u).text` / `.json` / `.html` / `.xml` |
| `await url.send(Request('POST', url, json: {…}))` | `await Request('POST', url, json: {…}).send()` |
| `IoClient(userAgent: 'me/1')` | `Http.scope(headers: {'user-agent': 'me/1'}, …)` |
| `IoClient(keepAlive: d)`, `request.persistentConnection = false` | `headers: {'connection': 'close'}` |
| `Response(…, isRedirect: true)` | drop it; `isRedirect` is a getter |
| `ChromeClient` from `dart_toolkit.dart` | `import 'package:dart_toolkit/chrome.dart';` |
| `ChromeClient.attach(port: 9222)`, `chrome.isNewBrowser` | `ChromeClient.connect(port: 9222)` |
| `page.reload()` | `page.goto(page.url)` |
| `ctx.response.html.$('a.next')` | `ctx.html.$('a.next')` |
| `ctx.resolve(a.attr('href'))` | `ctx.resolve(a)` (an `Element` or `Elements`) |
| `for (final u in api.json['next'].to<List<String>>()) ctx.follow(u)` | `ctx.follow(api.json['next'])` |
| `Opt.number('top', abbr: 'n', description: 'How many').or(10)` | `Opt.number('top', 'How many').abbr('n').or(10)` |
| `Arg.text('id', description: 'The build')` | `Arg.text('id', 'The build')` |
| `CliCommand('hash', description: 'Digest', values: …)` | `CliCommand('hash', 'Digest', values: …)` (`''` for none) |
| `Cli(name: 'tk', …)` | `Cli(…)`, named after the script |
| `Io.out.writeln(x)` inside `Cli.run` | `print(x)`; it lands above a live spinner |
| `Console.select('Bump', Bump.values, display: (b) => b.name)` | `Console.select('Bump', Bump.values)` |
| `return Lifecycle.exit('nothing found')` in a handler | `throw 'nothing found'` |
| `Console.spinner('x', style: SpinnerStyle.dot)` | `Console.spinner('x')` |
| `spinner.info(…)`, `spinner.isSpinning`, `spinner.elapsed`, `Console.clear()` | `stop()` / `succeed` / `warn` / `fail`; the end line prints the time |
| `Env.require('TOKEN')` | `Env.get('TOKEN')` (throws naming the key when unset or empty) |
| `Env.get('PORT') ?? '8080'` | `Env.get('PORT', or: '8080')`; `Env.getOrNull` is nullable |
| `Env.remove(k)` / `Env.reset()` | `Env.set(k, '')`; an empty variable is unset |
| `(await xs.parallelize(f)).rights` | `await xs.parallelize(f).rights.toList()` (also `.lefts`, `.unwrap()`) |
| `e.isLeft`, `isRight`, `e.fold(…)`, `mapLeft`, `e.mapRight(f)`, `Either.tryCatch(f)` | `e is Left`, a `switch`, `try` |
| `Mutex().run(f)` | `Semaphore(1).run(f)` |
| `stream.delayBy(d)` | `throttle`, or `Http.scope(delay:)` to pace requests |
| `(() => work()).isolate()`, `res.isolate(…)` | `Isolate.run(() => work())` |
| `seq.none(t)`, `seq.whereNot(t)`, `seq.shuffled()` | `!seq.any(t)`, `seq.where((e) => !t(e))`, `seq.toList()..shuffle()` |
| `seq.interleave`, `scan`, `cartesian`, `groupJoin`, `pairs.inverted`, `pairs.unzip`, `thenWith`, `Sequence.empty()` | a loop or literal; `groupBy` + `indexBy`; `thenBy`; `const <T>[].sequence` |
| `t.numbers('bytes').sequence.sum` | `t.numbers('bytes').sum` |
| `ini['debug'].toOrNull<bool>() ?? false` | `ini['debug'].or(false)` |
| `for (final a in doc.$('a[href]')) a.attr('href')` | `doc.$('a[href]').attrs('href')`, or `.links` for resolved `Uri`s |
| `doc.$('main').first.markup` | `doc.$('main').markup` |
| `ul.children.where((e) => e.name == 'li' && …)` | `ul.$('> li.x')` |
| `DateTime.parse(doc['t'].to<String>())` | `doc['t'].to<DateTime>()`; `row.get<DateTime>('t')` |
| `File(p).writeAsString(JsonEncoder.withIndent('  ').convert(doc.raw))` | `doc.save(p)` (`.json`, `.yaml`) |
| `decodeEntities(s)` | `s.html.text` |
| `import 'package:dart_toolkit/ffi.dart'` | a dedicated binding (`package:sqlite3`), or `dart:ffi`'s `lookupFunction` |
| `run('chmod +x $f')` | `await f.chmod('+x')` (octal or symbolic) |
| `archive.archiveEntries()` | `archive.entries()` |
| `Archive.of(name)`, `Archive.isWritable` | gone; `archiveTo` reads the extension and lists the writable ones |
| `archiveTo('x.rar')` or a tar password threw `ArgumentError` | `FormatException`, before anything is created |
| `NativeLib.version` | gone; a library with the wrong ABI (now 3) is refused at load |
| `path.watch()` | `path.changes()`, or `path.asDir.watch()` for raw events |
| `createTemp` + `try`/`finally` + `delete(recursive:)` | `await Path.tempDir((d) async { … })` |
| `'$n bytes'` | `n.humanBytes` (`'20.0 MB'`) |

#### Fixed

- Data: `sorted.take(n)` returned everything when `n ≥ length/8`; `orderBy` on a mixed column depended on input order and CSV blanks sorted first; `where` after `orderBy` dropped the order; a `join` name clash overwrote a column; `Table.read('t.md')` returned garbage.
- HTML: a stray end tag closed a whole table; `<td>` in `<thead>` lost the header row; `:scope` inside `Element.$` meant the root; `<optgroup>` nested.
- XML attributes were written with a raw `<`.
- YAML: `toYaml` did not round-trip control characters or `"..."`; block scalars lost trailing spaces.
- INI continuation lines (`setup.cfg`) were misread.
- HTTP: a timed-out request to a silent server kept its pool permit forever; a failed upload left its connection open and the next request hung; a nested `Http.scope` dropped the outer client, cookies and headers; retries re-sent errors that cannot change; an XML `encoding=` declaration was ignored; `withQuery` lost repeated keys; a HEAD that got a 303 downloaded the body.
- Crawling: POSTs were re-sent; sitemap `&amp;` was taken literally and a truncated `.gz` sitemap passed as complete; one blip turned retries off for a host; `http://h` and `/` were crawled twice.
- Chrome: non-UTF-8 pages came back garbled; an empty 404 was retried as a transport error; `waitFor` threw on a JS redirect; `press('Escape')` stuck a key down on macOS; `stealth` still said `HeadlessChrome`; a screenshot below the fold was blank.
- Terminal: spinners, bars and boards drew on stdout (their live frames now go to stderr; the final ok line is a log line on stdout); stderr colour was decided by stdout, and `NO_COLOR` turned off redraw; exit hooks ran twice after ^C and the error line was erased by the next spinner frame; ^C in `Console.secret` outside `Cli` left echo off.
- Processes: a child that trapped SIGTERM outlived ^C; `ls ~` and `echo $HOME` were passed literally (now refused); `.lines` trimmed the leading spaces of `git status --short`; a pipeline hid a failed earlier stage behind exit 0; a failed command printed three lines.
- Downloads: a batch where every download failed reported "all done"; `show()` now ends with "2 of 6 failed".
- Archives: a refused extraction left all but the first escaping link on disk; an out-of-range `level` panicked in Rust and zip `level: 0` threw; 7z ignored `level`, lost the exec bit and never reported encryption; `archiveTo` dropped symlinks; directory modes were not restored on extract or kept on copy.
- Files: `copy` into its own subtree recursed; `filename` did not cap at 255 bytes; `base64Bytes` refused whitespace.
- Core: a `Cancel.scope` timeout cancelled the caller's shared token; cancelling `parallelize(isolate: true)` early could keep the process alive; `Pool.close()` failed queued work; `Env.parse` was quadratic after an unclosed quote; `chunkEvery` let an error overtake its batch.

#### Removed

- `package:dart_toolkit/ffi.dart` and the second spellings in the table above.
- `SpinnerStyle` and its five styles, `Env.hasOverrides`.
- Now private: `Console.isEnabled`, `CliContext.command`, the `CommandPipeline` constructor, `Archive`, `decodeEntities`.

#### Added

- `Fetch`: the `Future<Response>` every verb returns, with checking readings.
- `Http.scope(jar:)`: seeds the cookie jar, e.g. `Http.scope(jar: await page.cookies(), …)` carries a browser login to plain sockets.
- `Http.scope(delay:)` jitters each gap ±25 %.
- `InitContext.canonical`; `<base href>` is honoured; `HtmlDocument.base`.
- `page.scroll(toEnd: true)`.
- `waitForDownload` spaces its starts ~120 ms apart per tab, so Chrome no longer drops downloads in a fast loop.
- A leading `>`/`+`/`~` in `Element.$`.
- `ShellRun.kill()`.
- `writeText`/`writeBytes`/`writeLines` replace atomically, keeping mode and links; `copy` keeps directory modes.
- Multi-threaded zstd and xz from 32 MiB.

#### Faster

| | Before | After |
|---|---|---|
| `import 'package:dart_toolkit/http.dart'` | | −32 ms |
| `JsonDocument` `['id'].to<int>()`, 200k objects / `.map` | 9.4 / 32.0 ms | 3.2 / 15.9 ms |
| XPath `//td/@id \| //tr/@class` / `//*[@class]` | 15.7 / 2.44 ms | 7.4 / 1.59 ms |
| `file.hashBytes(xxh3)`, 1 MiB / `sha256`, 4 MiB | 454 / 2650 µs | 97 / 1435 µs |
| directory `size()`, 10k files | 113 ms | 28 ms |
| 96 MiB to `.zst` / `.xz` / `.tar.zst` | 299 ms / 48.3 s / 285 ms | 88 ms / 15.7 s / 81 ms |
| `Table.select` / `derive`, 200k rows | 72 / 72 ms | 38 / 45 ms |
| Chrome render with `waitFor`, 2.7 MB DOM | 308–336 ms | 261–263 ms |
| `waitForDownload`, small file | ~210 ms | ~8 ms |
| a `Uint8List` request body, 8 MiB | ~520 µs | 0.7 µs |
| atomic rewrite of a 1 KiB file (slower on purpose) | 41 µs | ~170 µs |

### The second audit

Applied earlier in this release, with real sockets, headless Chrome and about 50 000 fuzzed parser
inputs; each finding has a regression test.

#### Upgrading

| Before | After |
|---|---|
| `a.attr('href')!` | `a.attr('href')` throws a `StateError` naming the tag; `attrOrNull` is nullable |
| `client.crawl<T>(seeds)` | `client.scrape<T>(seeds)` (a `Uri`, `Uri`s or `Request`s) |
| `for (a in html.$('a.next')) ctx.follow(a.attr('href')!)` | `ctx.follow(html.$('a.next'))` (`href`, else `src`) |
| `CliCommand('x', args: [a], options: [b])` | `CliCommand('x', values: [a, b])` |
| `Arg.rest('paths')` | `Arg.text('paths').many()` |
| `Arg.text('file')`, then `ctx(file).path` | `Arg.by('file', Path.new)`, then `ctx(file)` |
| `t.saveCsv('out.csv')` | `t.save('out.csv')` (csv, tsv, json, ndjson, jsonl or md by extension) |
| `.show(slots: 4)` | `.show()` |
| `Console.warn('$e')` | `Console.warn(e)` |
| `glob('**/*')` listed directories | files only; `glob('**/')` for directories |
| `(await which('git'))!.run(args: [tag])` | `run('git tag', args: [tag])` |
| a token and `Future.delayed(5.s, token.cancel)` | `Cancel.scope(timeout: 5.s, …)` |
| `run('a \| b')` passed `\|` as an argument | `ArgumentError` (also for `&&`, `;`, `>`, `$(`); write `('a' \| 'b').run()` or `shell: true`. An unclosed quote is a `FormatException` |
| a POST retried under `Http.scope(retries:)` | sent once, unless a 429/503 gave `Retry-After` |
| a scope's `authorization` went to every host | only to the origin of the scope's first request |
| prompts on stdout | prompts on stderr |
| a CSV header `id,id` read as one `id` | `id`, `id_2` |
| `Cancel`, `CancelToken`, `CancelledException` in `async` | in `core`, unchanged |

#### Fixed

- An archive could write outside its destination through a link whose target did not exist yet; a file now replaces a link at its name.
- `authorization` followed a redirect to another scheme or port of the same host.
- A resumed download of a changed file was two versions spliced (now `If-Range`; a `206` that starts elsewhere is refused).
- A gzip, brotli or zstd body cut off halfway came back as 200 (now a `ClientException` naming the encoding).
- robots.txt and sitemaps were uncapped (now 512 KiB and 50 MB); a corrupt gzip sitemap threw an uncaught error.
- ^C could not stop a crawl, a request mid-body, a retry backoff, a `Retry-After` wait, a `delay:` gap, `Duration.delay` or `Semaphore`; a cancelled download reports `DownloadFailed(CancelledException)` and releases its socket.
- A `Cancel.scope` inside another ignored the outer one, so ^C under `Cli.run` missed library scopes.
- `run()` dropped its timeout and cancel while a background child held stdout open.
- Charsets: a byte-order mark now wins, and `<meta>` is read only for HTML.
- Cookies: an empty `Domain=` was honoured and a `Secure` cookie over http accepted.
- robots.txt compared paths un-normalised and matched partial product tokens (`bot` matched `mybot`).
- Scrape: a sitemap page redirecting off-site widened the scope; a login redirecting to itself with a cookie was lost; robots, `delay` and `perHost` were shared across ports and schemes; `/p?` and `/p` were two pages.
- Downloads: a `416 bytes */N` equal to the part did not complete it; two pairs with one destination were two downloads; `delay:` did not space redirect hops.
- Chrome: a late event from the previous page settled the next navigation with an empty body; `pushState` and `#hash` navigations timed out and `page.url` went stale; `frame()` could not reach cross-origin iframes and `frame.goto` moved the whole tab; two download waits could claim one file; a download from a new tab was missed; a download overwrote a file of the same name (now `name (2).ext`); a 204 was a transport error.
- Native: zip times were not local time; a batch hash with an empty file name gave later files wrong digests.
- TOML/YAML: a bad escape was a `RangeError` (now a `FormatException` with its line); nesting deeper than 1000 is refused.
- TOML accepted a table defined twice, an extended inline table, and `[[a]]` over a plain array.
- YAML accepted a duplicate key and text after a closing quote, and did not put `&a b: c`'s anchor on the key.
- JSONPath `..` now walks any depth.
- INI: a quoted section part lost its dots.
- HTML: SVG lost `viewBox` and `foreignObject`; `</ p>` and `</>` were kept; HTML5 punctuation entities did not decode; `html:first-child` did not match; XPath `number()` was not XPath 1.0's.
- Processes: `yes | head -1` failed; a file that cannot run is now 126 and `which` finds only runnable files; on Windows only `.bat`, `.cmd` and built-ins go through `cmd.exe`, which refuses metacharacter arguments.
- `Pool.close()` left busy workers open (an isolate pool closed mid-item kept the program alive); the queue is now first come, first served.
- A `flatMap` mapper that throws is now the stream's error.
- CLI: a mistyped option gets a did-you-mean; a bad number names its option; a program of subcommands run with none exits 64; `confirm` re-asks on a typo; `select(or:)` rejects a default that is not a choice; the live region never wraps.
- CSV: an unclosed quote is a `FormatException` with its line; a `""` row round-trips.
- Tables: `Table.show()` prints a missing cell blank; `select` with a typo throws; `numbers()` reads decimals only.
- Links are measured, copied and moved as links; completion keeps a choice with a space as one word.

#### Added

- `url.events()`: server-sent events or NDJSON as a `Stream<ServerEvent>`.
- `Http.scope(cache: dir)`: a conditional-GET cache; a 304 is served as its 200.
- Inside `Http.scope(retries:)`, a body cut off halfway resumes where it stopped.
- Shift_JIS, EUC-KR, GBK, Big5, KOI8-R and the other WHATWG labels decode (`encoding_rs`, +170 KB per library).
- `run(args:)` (`$1`… under `shell: true`) and `.stream` for live lines.
- Help shows what an option takes (`--top <int>`, `--mode <fast|slow>`); `-q` silences spinners, bars and boards.
- YAML merge keys (`<<: *base`), CSS `:contains(text)`, `JsonDocument.read(path)` (parser by extension).
- INI reads Java properties files; `.env` values may span lines.
- `glob` supports `{a,b}` and `[…]`.

#### Faster

| | Before | After |
|---|---|---|
| scrape frontier, 1M follows | 435 MB | 257 MB |
| `nextElement` over 40k siblings | 1.1 s | < 1 ms |
| `/>` under deep markup | 2.4 s | 30 ms |
| stray XML end tags | 0.5 s | 2 ms |
| `parallelize` without / with isolates | | ~10× / ~20% |
| `debounce` | | ~50× |
| CSV streaming a huge quoted cell | 1.9 s | 50 ms |
| `orderBy(…).take(10)` / `sortedBy(…).take(10)`, 500k rows | 165 / 132 ms | 25 / 10 ms |
| `collection`-only import (no longer imports `formats`) | | −125 ms |

## 0.0.6

The first full audit: about ninety findings, each fixed with a regression test. Short spellings now
sit on classes you can hold (`Pool`, `Crawler`), and the native library is prebuilt for four
platforms.

### Upgrading

| Before | After |
|---|---|
| `Console.ask(…)`, `confirm`, `secret`, `select` | `await Console.ask(…)`; prompts are async and ^C interrupts them |
| `await run('…', quiet: true).text` | `await run('…').text` |
| `await run('…', strict: false, quiet: true).isOk` | `await run('…').isOk` |
| `el.outerHtml`, `doc.outerXml` | `el.markup`, `doc.markup` |
| `doc['x'].to<bool>() ?? false` | `doc['x'].toOrNull<bool>() ?? false`; `to<T>()` throws when missing |
| `doc.isNotNull` | `!doc.isNull` |
| `'---\na: 1\n---\nb: 2'.yaml` was a list | `.yaml` is the first document; `.yaml.documents` is all of them |
| `doc['tags'].list.map((d) => d.to<String>()!)` | `doc['tags'].to<List<String>>()` |
| `Native.isAvailable` | `NativeLib.isAvailable` |
| `zip.path.extractToSync(d)` | `await zip.path.extractTo(d)` |
| `Spinner.run(…)`, `Stages(n)` | `Console.spin(…)`, `Console.stages(n)` |
| `ChromePage.navigating` / `downloading` / `fetching` | `waitForNavigation` / `waitForDownload` / `waitForResponse` |
| `waitForDownload(timeout:)` was a deadline | it is how long the transfer may stay quiet |
| `bin/zlib.dart` | deleted; see `bin/books.dart` |

### Fixed

- HTML entities without `;` corrupted URLs (`&copy=2` decoded); only HTML5 legacy names decode without `;`, and never inside an attribute before `=` or an alphanumeric.
- Under Chrome, a scope's `authorization` and cookies reached third-party hosts.
- A resumed download of a gzip-served file was corrupt but reported `Downloaded`.
- Chrome's downloads (its own component downloads included) landed in the working directory; a given-up download left its partial file.
- A launched Chrome outlived the program; on macOS and Linux an `sh` watchdog now stops it and erases its profile, even after `kill -9`.
- Extraction kept setuid/setgid/sticky bits, followed links out of the destination and had no output cap; now refused, or capped at 200× (min 1 GiB), unless `trusted: true`.
- A 16 KiB zstd body decoded to one 512 MiB allocation; a decoder now returns at most 256 KiB per call.
- `run` children outlived a cancel, a timeout or the program; the whole tree gets SIGTERM, then SIGKILL after 2 s.
- Cookie `expires` and `Retry-After` dates in PHP's dashed format threw.
- A scope timeout never returned its connection, so `IoClient(connections: N)` deadlocked after N timeouts.
- A dead browser went unnoticed for 30 s per call.
- Under Chrome, a crawl used the URL from before the redirect.
- Two `files:` uploads to one URL were deduplicated as one.
- robots.txt was matched as `dart-toolkit` whatever user-agent was sent; `/*.php$` did not disallow `/a.php/b.php`.
- `waitForResponse` swallowed the action's own exception.
- `IoClient(proxy:)` with credentials never authenticated.
- A fresh Chrome profile downloaded about 40 MB of components in its first minute.
- `<noscript>` or `<template>` in `<head>` moved the rest of head into body.
- Tag soup: `<a>one<a>two` and `<h1>a<h2>b` nested; `<div/>text` left the text outside; `<pre>` and `<textarea>` kept their first newline; `<!-->` was not a comment.
- A document nested 100 000 deep overflowed the stack.
- XPath: positions on reverse axes counted from the wrong end; `//x/*` could come back out of document order.
- CSS: a deep descendant chain backtracked exponentially; `[attr^=""]` matched every element with the attribute.
- `to<int>()` on 1.7 returned 1.
- YAML: `[a: 1]` hung; `--- foo\n--- bar` was one string and `%YAML` directives became data; `"x \" # y"` was cut at the `#`; multi-line quoted scalars threw; `-   a: 1` lost its siblings; a `[` inside quotes swallowed the next key; aliases inside `[…]` were unresolved; block scalars had three off-by-ones; `\U`, `\e`, `\N` and `\_` decoded wrong; `!!str 123` was an int; `toYaml()` wrote values that read back differently; `'a: .nan'.yaml` did not serialise.
- XML with many bare `&`, and HTML with many stray `<`, were quadratic.
- A TOML integer past 64 bits was not a `FormatException`; an INI value became a number even when it did not read back as written; `[s] ; comment` was not a section.
- ^C at a prompt returned empty and the program carried on; a second ^C while an exit hook hangs now quits.
- `Cli.run` printed stack traces (now one `✖ error` line and exit 1; the trace under `--verbose`); a mistyped subcommand printed usage and exited 0.
- `--dry=false` set the flag; `--dry=maybe` was accepted; in `-vj=4 7` the 7 went to `--jobs`; `-5` was an unknown option; a subcommand's `--help` omitted inherited options; `-h` took `--help` away when another option owned `h`.
- `run(shell: true)` gave no shell; `run` ignored `Cancel.scope`; non-UTF-8 output failed the command; a missing executable was not exit 127; a timeout lost its partial output (now `ShellTimeoutException.result`).
- `2>log` wrote colour escapes; child output garbled a live spinner; `TaskBoard` printed nothing under `NO_COLOR`; `Env.parse` treated every `#` as a comment and cut values at `\"`.
- `parallelize(isolate: true)` never worked on a stream and copied the whole input into every isolate.
- `retry` slept through a cancelled scope; `merge` and `flatMap` ignored backpressure; cancelled stream operators kept the process alive; `throttle` could emit twice in one window.
- `move` onto a non-empty directory merged into it and deleted the source; a `.7z` written inside the folder it archived contained a truncated copy of itself.
- CSV: a stray `"` mid-field swallowed the rest of the file; a BOM stuck to the first header.
- `glob` returned nothing for an absolute pattern and stopped at the first unreadable directory.
- Zip lost the mtime of read-only files and turned symlinks into regular files.
- `'..'.filename` returned `..`; `hexBytes('-1')` returned `[255]`; `'1,5'` was read as 15.
- A sorted `Sequence` kept returning its first result; `windowed` held its whole source in memory.
- A missing native library was reported as `no NativeBridge.fileName at …`.
- `.pubignore` did not repeat `.gitignore`, so the 0.0.5 dry run was 65 MB.

### Removed

- `isNotNull`, `extractToSync`, `Spinner.run`, the public `Stages` constructor, `ProgressBar.formatLine`, `TaskBoard.formatLines`, `bin/zlib.dart`.

### Added

- `Http.scope(retries:)`: transport errors, 5xx, and 429/503 honouring `Retry-After`, for every `url.get()` and download.
- `Http.scope(delay:)`: the minimum gap between two requests to one host.
- `ctx.sitemaps = true`: seeds a crawl from robots.txt's sitemaps or `/sitemap.xml`, indexes and gzip included.
- `Crawler<T>`: the class `url.scrape<T>()` is sugar for, with the five hooks as methods and `run()`.
- `ChromeClient.launch(profile:)`: a kept user-data directory.
- `ChromeClient(proxy:)` on all three constructors, also carrying the plain client; `isNewBrowser`.
- XPath 1.0: `*`, `div`, `mod`, subtraction, `translate`, `substring`, `sum`, `floor`, `ceiling`, `round`, `following` and `preceding` axes.
- CSS: escapes (`.md\:flex`), `:is`, `:where`, `:only-of-type`, `:nth-last-of-type`, relative `:has(> img)`, `:has(+ dd)`, `:has(~ p)`.
- `Element.lines` breaks at blocks, tabs between cells, and skips `head`, `script`, `style`, `template`, `noscript`.
- `.table` keeps every column (`Price_2`) and fills `colspan`/`rowspan`.
- `to<T>()` errors say where (`$.server.port is "x" (String), expected int`); `toOrNull<T>()`; `to<List<String>>()` and `to<Map<String, int>>()` convert every element.
- JSONPath slices (`[1:3]`, `[::-1]`) and unions (`[0,2]`, `['a','x.y']`); a filter is a `FormatException` pointing to `.where`.
- `test/formats_diff_test.dart` checks the parsers against package:html, xml and yaml.
- Every `Cli` has `-v/--verbose`, `-q/--quiet` and `--completion bash|zsh|fish`.
- `Opt….many()`, `Opt….env('NAME')`, and `Arg` for positionals; `--no-dry`.
- `run(…)` returns a `ShellRun`; `.text` and `.lines` imply `quiet`, `.isOk` also `strict: false`.
- `run(inherit: true)`, for `git commit`, `ssh` and `vim`.
- `Worker<T, R>` and `Pool`: the class under `parallelize`; `Pool.spawn(Resize.new, size: 4)`.
- `extractTo(dest, only: '**/*.txt')`, `archive.entry('a/b.txt')`, `paths.hash(Hash.xxh3)`, `dir.duplicates()`, `olderThan(age)`, `changes(debounce:)`.
- `Table.read(path)` and `Table.readRows(path)`: CSV, TSV, JSON and NDJSON by extension.
- `hmac` of a file streams; `hmac(Hash.blake2b)` uses BLAKE2's keyed mode.
- `package:dart_toolkit/ffi.dart` (deleted in Unreleased).
- Prebuilt for `macos_arm64`, `macos_x64`, `linux_x64` and `linux_arm64`; `make native RUST_TARGET=…` cross-builds.
- `bin/books.dart`, against Standard Ebooks.

### Faster

| | Before | After |
|---|---|---|
| five GETs over a three-hop redirect chain | 11 TCP connections | 1 |
| serialising a 2 MB page | 46 ms | 21 ms |
| XPath `//article[.//img]` / `(//a)[1]` | 95 / 53 ms | 4 / 3 ms |
| CSS deep descendant chain | 370 ms | < 1 ms |
| `parallelize(isolate: true)`, 400 × 50k ints | 20.9 s | ~70 ms |
| `paths.hash`, 49.5k files | 9.3 s | 1.0 s |
| xxh3 / BLAKE3 over 1 GiB | ~530 ms / ~1 s | 110 / 110 ms |
| XML with many bare `&`, 240 KB | 12 s | < 2 ms |
| `Table.csv` | | 3–4× |
| YAML parsing | | ~2× |

## 0.0.5

### Upgrading

| Before | After |
|---|---|
| `onExit(f)`, `clearExitHooks()` | `Lifecycle.onExit(f)`, `Lifecycle.onExit(null)` |
| `die(message)` | `Lifecycle.exit(message)` |
| `runExitHooks()` | private |
| `userAgent:` on `ChromeClient` | a `Device` (`Device.desktop`, `Device.phone`) |
| `example/` | deleted; `bin/tk.dart` and `bin/keybox.dart` are the demonstration |
| `make bench` | `make startup` |

### Fixed

- A login that redirects lost its session: cookies set on intermediate hops were dropped.
- An `alert()` held the tab and its pool slot; every dialog is now answered (dismissed, `beforeunload` accepted).
- A subframe finishing loading settled the page's wait.
- `dart:io` copied credential headers onto every redirect hop; `IoClient` now walks its own redirects and `authorization`, `cookie` and `proxy-authorization` stop at another host.
- `Request.copy()` duplicated the body.

### Added

- `GUIDE.md`, the manual.
- `ChromePage.onDialog` and `Dialog` (`accept([text])`, `dismiss()`).
- `files:`, a streamed `multipart/form-data` body; pairs with `form:`.
- `Request.open()` and `Request.contentLength`.
- brotli and zstd response decoding (with the native library).
- `IoClient(proxy:, insecure:)`.
- `ChromePage.block` and `Resource` (`page.block(Resource.heavy)`, `ChromeClient.launch(block:)`, `request[ChromeClient.block]`).
- `ChromePage.downloading`, `fetching` and `frame`.
- `Device`, and `stealth:` (on by default).
- `ChromePage.upload`, `reload`, `forward`, `screenshot(selector:, full:)`, `cookies(restore)`, `ChromeWait.dom`.
- `Lifecycle`.

## 0.0.4

### Upgrading

| Before | After |
|---|---|
| `Http.session`, `Shell.session`, `Cancel.session` | `Http.scope`, `Shell.scope`, `Cancel.scope` |
| `BrowserClient`, `BrowserPage`, `BrowserWait` | `ChromeClient`, `ChromePage`, `ChromeWait` |
| directive `browser.wait-for` | `chrome.wait-for` |
| `Logger.info(…)` (and `debug`, `ok`, `warn`, `error`, `stages`, `level`, `silenced`) | `Console.info(…)` |
| `Console.multiProgress()` | `Console.tasks()` |
| `ConsoleProgress`, `ConsoleMultiProgress` | `ProgressBar`, `TaskBoard` |
| `ChromeClient.direct` | `Request.raw` |
| `Client.close()` returning `FutureOr<void>` | `Future<void>` |

### Fixed

- `path.download(url)` inside a Chrome scope wrote the rendered DOM, not the file.
- Sending a request wrote the scope's headers and cookie onto the caller's `Request`.
- A raw request through `ChromeClient` sent no user-agent; it now sends Chrome's own.
- `back()` hung for its whole timeout on a back/forward-cache restore.
- Log lines and live indicators wrote over each other.

### Added

- `ClientExtensions`: `client.get/head/post/put/patch/delete/fetch/json/html/xml`, `client.fire(request)`, `client.scrape<T>(url)` / `client.crawl<T>(requests)`.
- `ChromePage.text`, `attr`, `has`, `select`, `hover`, `navigating(action)`, `back`, `cookies`, `pdf`.
- `IoClient(connections:, perHost:, keepAlive:, connectTimeout:, userAgent:)`.
- `Request.raw`.
- `ChromeClient.connect()`: attaches to the Chrome on the port, or starts one that outlives the program.
- A live region: log lines scroll above spinners, bars and boards; `Console.writeln`.
- `Console.spinner(message)`, a handle; `SpinnerStyle`.

## 0.0.3

### Upgrading

| Before | After |
|---|---|
| `cancelToken:` on `download`, `retry`, `parallelize` | `Cancel.session(…)`; read `Cancel.token` |
| `stream.cancelWith(token, true)` / `future.cancelWith(token)` | `stream.cancellable` / `future.cancellable` |
| `throwOnCancel:` | `Cancel.isCancelled` after the loop |
| `throwOnError:` | `strict:` |
| `downloadAll` | `download` |
| `post(body:, json:)`, `follow(body:, fields:)`, `Request.fields` | `text:`, `bytes:`, `form:`, `json:` (one); `Request.form` |
| a positional default on `Console.ask`, `confirm`, `select` | `or:` |
| `declare()`, `action()`, `command(…, build:)`, the `handler` field | `CliCommand(options:, commands:, handler:)` |
| `String.stripped` | `Io.stripAnsi` |
| `Sequence.count` | `length`, or `where(…).length` |
| `Group.counts` | `countBy` |
| `Table.records` | `Table.rows(items.map(toRow))` |
| `Console.spinner`, `ConsoleSpinner` | `Console.spin(message, action, done:, failed:)` |
| `Flag('x')` | `Opt.flag('x')` |
| `Crypto`, `Crypto.randomBytes` | `Secure`, `Secure.bytes` |
| `Native.require`, `alloc`, `free`, `withBytes`, `withOut`, `withText`, `take`, `lastError`, `fileName`, `target` | on `NativeBridge` |
| `XPath`, `XPathKind`, `JsonPath`; `CliOption`/`CliCommand` parser internals | private; `$` and `$x` run queries |

### Fixed

- `:not()` and `:has()` parsed their argument as HTML on XML documents.
- `orderBy(descending: true)` sorted `null` first.
- Error messages and docs named private symbols (`_XPath`, `_entities`).
- `Response.text` ignored `<meta charset>` and did not decode windows-1252.
- A repeated `set-cookie` was joined with a comma.
- The CSS selector cache grew forever (now capped at 256).

### Added

- `Cancel.session`, `Cancel.token`, `Cancel.isCancelled`, `Cancel.reason`, `Cancel.throwIfCancelled()`.
- `Shell.session`: `workdir`, `env`, `timeout`, `encoding`, `quiet`, `strict` for a scope.
- `Http.session(cookies: true)`: a cookie jar for the session.
- `ctx.robots = true`: obeys `robots.txt`, including `Crawl-delay`.
- `download(checksum: (Hash.sha256, '…'))`, failing with `ChecksumMismatch`.
- `download(ifModified: true)`; a `304` is `DownloadSkipped`.
- `Request.json`.
- Archives are sniffed by magic number; `Archive.rar`.
- `Path.hmac`, `Path.hmacBytes`, `String.hashBytes`, `String.hmacBytes`.
- `BrowserClient`, `BrowserPage`, `BrowserWait`: rendering through Chrome over DevTools, with `tabs:` and `challenge:`.
- `RequestKey<T>`, `Request.operator []=`; `BrowserClient.waitFor`, `.waitUntil`, `.script`, `.direct`.
- `test/client_conformance.dart`.

### Faster

| | Before | After |
|---|---|---|
| `glob` `lib/**/*.dart` on this repo | 143 ms | 3.7 ms |
| `//li/following-sibling::li[1]`, 3 000 siblings | 72.5 ms | 2.0 ms |
| `//span`, 8 000 elements | 4.0 ms | 1.2 ms |
| `sortedBy`, 20 000 elements | 12.7 ms | 5.6 ms |
| `:has()` with an early match | 16.3 ms | 7.6 ms |
| `Element.table`, 3 000 rows | 2.1 ms | 1.3 ms |
| download progress events | per socket chunk | at most every 50 ms |

## 0.0.2

### Upgrading

| Before | After |
|---|---|
| `CliContext.flag`, `.option`, `.number`, `.optionOrNull`, `.numberOrNull`, `.values`; `CliCommand.option`, `.flag`, `.choice`, `.number`; `CliFlag`, `CliValue`, `CliNumber`, `CliChoice` | `Flag`, `Opt.text`, `Opt.number`, `Opt.among`, `Opt.by`, `.or(v)`, `.required()`, read with `ctx(option)` |
| `client:` on `get`, `post`, `fetch`, `json`, `html`, `xml`, `send`, `download`, `downloadAll` | `Http.session(client:)` |
| `Path.download` progress | `BatchDownloadProgress`; per-file state is `progress.current` |
| `XmlNode`, `XmlElement`, `XmlText`, `XmlAttribute`, `XmlNodes` | `Node`, `Element`, `Text`, `Attribute`, `Nodes` |
| `XmlDocument.$` (XPath) | `$x`; `$` is CSS |
| `XPathTree` | gone |
| `outerHtml`/`outerXml`, `innerHtml`/`innerXml` on nodes | `markup`, `innerMarkup` |
| `.md5`, `.sha1`, `.sha256`, `.sha512`, `.blake3`, `.crc32`, `.xxh3` | `hash(Hash.x)`, `hashBytes`, `checksum`, `hmac`, `hmacBytes` |
| `Io.table`, `Console.table` | `Table.cells(headers, rows).show()` |
| `Ansi.enabled`, `Ansi.strip` | `Io.color`, `Io.stripAnsi` |
| `Path.gzipTo`, `Path.gunzipTo` | `compressTo`, `decompressTo` |
| `Table.tsv`, `Table.toTsv` | `csv`/`toCsv` with `separator: '\t'` |

### Added

- `Flag`, `Opt`, `OptionalOpt.or`, `OptionalOpt.required`, `CliContext.call`, `CliContext.given`; `options:` on `Cli`, `CliCommand` and `command()`.
- `Element.syntax`, `Elements.texts`, `Nodes.$`; `Element.local` and `Element.prefix` for HTML.

## 0.0.1

First release: a scripting, automation and web-scraping toolkit in ten modules behind one import.

- Added: `core` (`Either`, `Env`, `Io`, `TaskProgress`, `60.s`), `async` (`parallelize`, `retry`, `CancelToken`, `Mutex`, `Semaphore`, stream operators), `collection` (`Sequence`, `Table`), `formats` (JSON, YAML, TOML, INI as `JsonDocument`; HTML and XML with `$`/`$x`), `fs` (`Path`, globbing, archives), `hash` (digests, HMAC, encodings, tokens), `http` (`Request`, `Response`, `Client`, `Http.session`, downloads, `url.scrape<T>()`), `cli` (`Cli`, `Console`, `Logger`, ANSI, exit hooks), `process` (`run`, pipelines, `which`), `native` (`Native.isAvailable`, `Native.reason`).
- Only `macos_arm64` was prebuilt; there was no cookie store and no `<meta charset>` decoding.
