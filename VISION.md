# dart_toolkit

**Write the script you would write in a shell, in Dart, with types.** dart_toolkit is fourteen
small modules for command-line automation: fetch, scrape, drive a browser, move files, run
programs, pack, hash, prompt, and draw a terminal UI. Each module is a thin facade over a good pub
engine, and every module speaks the same four interfaces, so the bytes flow between them like a
pipe in a shell.

```dart
final title = await Http.get('https://example.com').html().$('title').text();
final port = await Fs.file('conf.json').json().$('server.port').or(8080);
await (Fs.file('photo.jpg').image().resize(width: 800).encode(.jpg) > Fs.file('thumb.jpg'));

final iso = await Http.get(isoUrl, retries: 2), hash = Hash.sha256();
await (iso | Console.bar(iso.size(), label: iso.name()) | hash > Fs.file(iso.name()));
await Http.post(api, json: {'sha256': hash.hex()});

final page = await Chrome.launch().open('https://example.com/report').click('#accept').idle();
await (page.pdf() > Fs.file('report.pdf'));
```

**Target:** scripts and small tools on macOS, Linux and Windows: scrapers, downloaders,
release scripts, file shufflers, terminal apps. These are not servers or Flutter apps. The bar for
the library is set by real scripts (`projects/`): every workaround a script needs is a gap in the
library.

**Priorities, in order:** correct → fast (startup and throughput) → short at the call site (fewer steps, not clipped names) → small
surface. A member stays only when a real script needs it, and an addition must delete more code
at its call sites than it adds to the surface.

## 1. Style

| #   | Rule                                                                                                                                                                                                                                  |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **One entry class per module, named for it** (`Http`, `Fs`, `Tui`), `abstract final`, statics only, so typing `Http.` lists every way in. When the only value type shares the module's name (`Json`, `Image`), the statics go on that type. |
| 2   | **Values are `final class`es with private constructors and private fields.** Every read is a method (`status()`, `text()`), never a getter or a public field. Each library doc says `Public surface is exactly: …`.                     |
| 3   | **Short names, one meaning each.** One word when it reads one way, dropping a suffix the receiver already says (`status()` not `statusCode()`, `hex()` not `hexDigest()`). The same idea has the same name in every module (§3), and options too (`limit:`, `dir:`, `cache:`, `or:`). One method with an optional argument beats two. No abbreviation a reader must decode (`markdown`, not `md`). The only symbols are `$` (query), `[]` (index), `\|` (pipe through) and `>` (pipe into). |
| 4   | **Chains never need an inner `await`.** Every async value type has a Future mirror: an extension on `Future<T>` that repeats `T`'s members. Mirrors are named `<Type>Future`, because Dart hides unnamed extensions outside their library; nobody writes that name. |
| 5   | **Actions return their receiver** (`page.fill(…).click(…)`). An action that makes something new returns that instead (`copy`, `download`). Readings return data. `close()` and `delete()` return nothing.                                      |
| 6   | **Content leaves as a `Reader` and arrives through a `Writer`.** No method takes an output path: screenshots, PDFs, encoded images, archives and downloads are all `Reader`s, stored with `> Fs.file(…)`.                                         |
| 7   | **Outcomes are values; only failing to reach throws.** A 404 is a `Response`, a non-zero exit is an `Output`, malformed HTML still parses, a missing path is `null`. What throws is the network, the disk, a program that won't start, a wait that runs out. |
| 8   | **Never null for collections, nullable for single lookups.** No match gives an empty `Elements`; a missing attribute, header or option gives `null`.                                                                                     |
| 9   | **In memory is sync, I/O is async.** There are no sync twins.                                                                                                                                                                        |
| 10  | **Inputs are positional, options are named and optional** with defaults. There are no option objects, builders, or flags that change the result type. In-memory data is a `String` (UTF-8) or a `List<int>`.                               |
| 11  | **Types over runtime checks.** Generics carry the value type (`Opt<int>`, `value<T>()`, `Visit<T>`), sealed types make `switch` exhaustive (`Entry`), and `Object` parameters are kept to data and `body:`.                                     |
| 12  | **`close()` releases a resource and is idempotent.** Whatever holds a process, socket, terminal or isolate cleans up on `close()`, on an error, and on Ctrl-C. Nothing keeps a finished script alive.                                    |
| 13  | **Engines stay private and swappable.** An engine type never appears in a public signature, and engine exceptions are rethrown as Dart's own (§5). Tests use real servers, files, browsers and pseudo-terminals, never the engine, so a swap is proven by the same suite. |
| 14  | **No code generation, no native code.** Dart 3.10+ (dot shorthands: `encode(.jpg)`, `pack('site', .zip)`).                                                                                                                           |

## 2. Core: Reader, Writer, Pipe, Closeable

`core.dart` is re-exported by every module.

```dart
abstract mixin class Reader {                     // bytes you can read; implement stream()
  Stream<List<int>> stream();
  Future<List<int>> bytes();
  Future<String> text();                          // UTF-8, malformed bytes replaced
  Reader pipe(Pipe? pipe);       Reader operator |(Pipe? pipe);         // lazy; null = skip
  Future<void> to(Writer? w);    Future<void> operator >(Writer? w);    // run; null = discard
  Origin origin();                                // where the bytes came from (the base for `html()`)
  static Reader of(List<int> bytes);
}
abstract interface class Writer { Future<void> consume(Stream<List<int>> input); }
abstract mixin class Pipe { Stream<List<int>> transform(Stream<List<int>> input);  void abort(Object error) {} }
abstract interface class Closeable { Future<void> close(); }
```

| Type                                     | Reader | Writer | Pipe | Closeable |
| ---------------------------------------- | :----: | :----: | :--: | :-------: |
| `Response` (http), `Visit` (scrape)      |   ✓    |        |      | ✓ (http)  |
| `File` (fs)                              |   ✓    |   ✓    |      |           |
| `Output` (shell), `Download` (chrome)    |   ✓    |        |      |           |
| `page.screenshot()` `pdf()`, `image.encode()`, `Archive.pack()` | ✓ |  |  |   |
| `Archive.unpack(dir)`                    |        |   ✓    |      |           |
| `Hasher`                                 |        |   ✓    |  ✓   |           |
| `Bar` (console)                          |        |        |  ✓   |     ✓     |
| `Archive.gzip()` `gunzip()`, `Shell.filter()` |   |        |  ✓   |           |
| `Browser`, `Page`                        |        |        |      |     ✓     |

Other modules add readings to `Reader` (and `Future<Reader>`): `html()`, `json()` and `image()`.

**Pipelines:**

- `a | p` builds a new `Reader`; nothing flows yet. `a > w` runs everything and completes when
  `w` has stored the last byte.
- `a | p | q > w` groups like a shell. Wrap an operator chain in `await (…)`; the method forms
  `pipe`/`to` need no parentheses.
- Null stages make optional steps inline: `res | (quiet ? null : bar) | (verify ? hash : null) > (dry ? null : file)`.
- Backpressure is the stream's, so memory stays at a few chunks whatever the size.
- A response can be streamed once. Everything else (`File`, `Output`, `Download`, lazy readers)
  re-reads.
- An error anywhere fails the whole run, *including a writer that fails before it reads*. The
  source is cancelled, a `File` keeps its old content, a `Bar` prints `✗`, a `Hasher` refuses
  `hex()`, and the error is rethrown from `>`/`to`.
- Extending takes one class with one member: `with Reader` + `stream()`, `implements Writer` +
  `consume()`, `implements Pipe` + `transform()`.

## 3. Names

| Idea                                   | Name                                   | Where                                         |
| -------------------------------------- | -------------------------------------- | --------------------------------------------- |
| content as text / bytes                | `text()` / `bytes()`                   | every `Reader`, `Element(s)`, `Page`          |
| bytes → value                          | `html()` `json()` `image()`            | readings on `Reader`                          |
| text → value / value → text or bytes   | `parse` / `encode`                     | `Html`, `Json`, `Command` / `Json`, `Image`   |
| query a tree / typed read, null if not | `$` / `value<T>()`, `run<T>()`        | `Elements`, `Element`, `Json` / `Json`, `Page` |
| an attribute / every match's attribute | `attr` / `attrs`                       | `Element(s)`                                  |
| a tree without some parts              | `not(selector)`                    | `Element(s)`                                  |
| feed data / count progress             | `add(data)` / `tick(n)`                | `Hasher` / `Bar`                              |
| release / remove from disk / make      | `close()` / `delete()` / `create()`    | `Closeable`, `Pool` / `Entry` / `Dir`, `Link` |
| final URL / HTTP status / 2xx          | `url()` / `status()` / `ok()`          | `Response`, `Visit` (`Page` has `url()`)       |
| a file name / a size in bytes          | `name()` / `size()`                    | `Entry`, `Download`, `Response`, `Visit` / `File`, `Response` |
| run a program, a job, an app, a CLI    | `run`                                  | `Shell`, `Pool`, `Tui`, `Command`             |
| a key                                  | `press(key)` sends, a `keys:` binding handles; one key-name set (§4.12) | `Page`, `Screen` |
| draw or store into                     | `write`                                | `File`, `Region`                              |
| dimensions                             | `width()` `height()` / `width:` `height:` | `Image`, `Region` / `open`, `resize`, `popup` |
| the function that does the work        | `handler`                              | `Command(handler:)`, `Scrape.crawl`, `follow` |
| a notification / a bound event         | `on…:` / `on(events)`, `keys:`         | `onResult:`, `onError:` / `Region`, `Screen`  |
| switch the current state               | `go(state)`                            | `App`                                         |

Named parameters, each with one meaning: `headers` `body` `timeout` `base` `headless`
`path` `profile` `proxy` `block` `width` `height` `fullPage` `dir` `env` `recursive`
`json` `pretty` `limit` `delay` `retries` `insecure` `check` `cache` `browser` `onResult` `onError` `short` `or`
`required` `parse` `params` `commands` `aliases` `handler` `secret` `label` `quality` `color`
`background` `style` `link` `title` `status` `keys` `accent` `hint` `lines` `suggest`
`empty` `header` `follow`.

## 4. Modules

| Import    | Public surface (core members and Future mirrors not repeated)                                                                                     | Engine                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `html`    | `Html.parse` · `Reader.html` · `Elements` `$` `[]` `not` `text` `texts` `attr` `attrs` · `Element` `$` `not` `text` `attr` `parent`               | `package:html`        |
| `http`    | `Http.get` `head` `delete` `options` `post` `put` `patch` `hold` · `Response` `status` `ok` `header` `url` `size` `name`                                               | `package:http`        |
| `chrome`  | `Chrome.launch` `connect` · `Browser` `open` `pages` · `Page` (below) · `Download` `name`                                                       | `package:puppeteer`   |
| `json`    | `Json.parse` `of` `encode` · `Reader.json` · `Json` `$` `[]` `value` `or` `asList` `asMap`                                                                                   | `dart:convert`        |
| `fs`      | `Fs.entry` `file` `dir` `link` · `Entry` `path` `name` `parent` `exists` `delete` `copy` `move` · `File` `write` `append` `size` · `Dir` `file` `dir` `list` `create` · `Link` `target` `resolve` `create` | `dart:io`, `path` |
| `shell`   | `Shell.run` `filter` `open` · `Output` `code` `ok` `err`                                                                                   | `dart:io`             |
| `archive` | `Archive.pack` `unpack` `gzip` `gunzip` · `ArchiveFormat`                                                                                         | `package:archive`     |
| `hash`    | `Hash.md5` `sha1` `sha256` `sha512` · `Hasher` `add` `addBytes` `hex`                                                                                        | `package:crypto`      |
| `pool`    | `Pool.run` `runAll` `map` `close`                                                                                                                          | `worker_manager`      |
| `cli`     | `Flag` `Opt` `Multi` `Arg` (sealed `Param<T>`) · `Command` `run` · `Context` `call` `rest` `usage` · `UsageException`                                  | in-house              |
| `console` | `Console.ask` `confirm` `choose` `key` `spin` `bar` `log` `clear` · `Bar` `tick` `setTotal`                                                                                      | in-house              |
| `tui`     | `Tui.run` · `App` `state` `go` `status` `log` `notify` `copy` `quit` · `Screen` · `Binding` · `Pick` · `Field` · `Scroll` · `Region` (below) · `Color` · `Style` | in-house              |
| `image`   | `Image.decode` `sniff` · `Reader.image` · `Image` `width` `height` `resize` `crop` `encode` · `ImageFormat` · `Region.picture`                            | `package:image`       |
| `scrape`  | `Scrape.crawl` · `Visit` `url` `status` `ok` `size` `name` `follow` `emit`                                                                                             | http + html + chrome  |

A module imports only core and its engine. The exceptions are `chrome`, which imports `html`
for `Elements` and `json` for the `run<T>` coercion rules, and `scrape`, which composes `http`, `html` and `chrome`. `console` and `tui`
share one private terminal layer: stdin, key decoding, signal handling and restoring the terminal.

### 4.1 html

```dart
abstract final class Html { static Elements parse(String html, {String? base}); }
extension on Reader { Future<Elements> html(); }     // base = the response's final URL or the file's URI
final class Elements extends Iterable<Element> {
  Elements $(String selector);  Element operator [](int i);  Elements not(String selector);
  String text();  String? attr(String name);  List<String> attrs(String name);
}
final class Element {
  Elements $(String selector);  Element not(String selector);
  String text();  String? attr(String name);  Element? parent();
}
```

- `parse` never throws on bad markup. Input that starts with `<!doctype` or `<html` is a whole
  document (so `$('body')` works); anything else is a fragment.
- With a base, URL attributes (`href`, `src`, `data-src`, `poster`, `action`) are trimmed and
  made absolute.
- `$` returns matches in document order without duplicates. On `Elements`, `text()` and `attr()`
  both read the **first** match (`''`/`null` when there is none); for every match use
  `attrs()` or `.map((e) => e.text())`. `attrs()` skips missing values.
- `text()` reads like `innerText`, so scraped text needs no `.trim()`. Runs of spaces collapse to
  one space, and a run that holds a newline becomes one newline. The result is trimmed, and
  `<pre>` keeps its whitespace.
- `not` returns a new tree (one O(n) clone, table parts included); the receiver is
  unchanged.
- A selector the engine rejects is a `FormatException` naming it.

```dart
final doc = await Http.get(url).html();
final body = doc.not('script, style, nav').$('article').text();
final links = await Http.get(url).html().$('a.item').attrs('href');
```

### 4.2 http

```dart
abstract final class Http {
  static Future<Response> get(String url, {Map<String, String>? headers, Duration? timeout, int retries = 0, bool insecure = false, bool check = false});
  // head, delete, options: the same; post, put, patch add {Body? body}
  static Closeable hold();                       // keep the shared client open (a crawl)
  static void abort();                           // cancel every in-flight request, no retries (quitting a UI)
}
final class Response with Reader implements Closeable {
  int status();  bool ok();  String? header(String name);  String url();
  int? size();                                   // content-length, null when unknown
  String name();                                 // content-disposition filename, else the URL's last segment
}
```

- A verb completes when the headers arrive; the body streams. A non-2xx status is still a
  `Response`, and `ok()` is `status()` in 200–299. `insecure: true` accepts a bad certificate for that call only. `check: true` on any verb throws
  `HttpException('HTTP 404 GET <url>: <snippet>')` instead and closes the body.
- Redirects are followed for every verb, as in browsers: 301/302/303 after a POST become a GET,
  and 307/308 keep the method and resend an in-memory body. `url()` is the final URL.
- `body` is a `Body` (`Body.text`, `Body.bytes`, `Body.json`, `Body.form`, `Body.stream`).
- **Only a 2xx body can be piped.** `res > file` on a 404 throws `HttpException` naming the status
  and URL, so `await (Http.get(u) > Fs.file(f))` never saves an error page. The readings
  (`text()`, `json()`, `html()`) work on any status, and a `json()`/`html()` that fails on an
  error page says the status in its `FormatException`.
- `retries` re-sends GET/HEAD/OPTIONS/PUT/DELETE (never POST or PATCH) on network errors, timeouts, 5xx and 429, with doubling backoff from 1 s
  or the server's `Retry-After`. It applies only when the body is in memory. Scrape uses the same
  logic.
- `timeout` (30 s) bounds the wait for the headers, then any stall in the body. A
  `TimeoutException` names the URL.
- `text()` uses the charset from `content-type`, then `<meta charset>`, then UTF-8. It decodes
  UTF-8, Latin-1/ASCII and the WHATWG legacy CJK encodings (EUC-KR, Shift_JIS, EUC-JP,
  GBK/GB18030, Big5) with an in-house decoder. An unknown charset falls back to UTF-8, and bad
  bytes become ``. `text()`/`bytes()` cache;
  a piped body can't be read again (`StateError`).
- `close()` drops an unread body. A body read or piped to the end releases the connection by
  itself. The `Future<Response>` mirrors close the response after every mirror read (closing
  is right for one-liners like `Http.get(u).status()`). To read metadata and keep the body,
  await the `Response` first.
- Engine errors arrive as `SocketException`/`HttpException`/`TimeoutException`. A failed or
  timed-out upload never hangs.

```dart
final res = await Http.post('$api/items', body: Body.json(item));
if (!res.ok()) throw StateError('create failed: ${res.status()} ${await res.text()}');
final me = await Http.get('$api/me', check: true).json();   // a 404 throws
final form = await Http.post('$base/ajax', body: Body.form({'action': 'decode', 'p': '$id'})).json();
final img = await Http.get(src, retries: 2);
await (img > Fs.dir('imgs').file(img.name()));       // a 404 throws instead of saving junk
```

### 4.3 chrome

```dart
abstract final class Chrome {
  static Future<Browser> launch({bool headless = true, String? path, String? profile, String? proxy});
  static Future<Browser> connect(String url);
}
final class Browser implements Closeable {
  Future<Page> open(String url, {Map<String, String>? headers, List<String>? block, int? width, int? height,
      Duration? timeout});
  Future<List<Page>> pages();
}
final class Page implements Closeable {
  Future<Page> go(String url, {Duration? timeout});                                  // wait for load
  Future<Page> back({Duration? timeout});  Future<Page> reload({Duration? timeout});
  Future<String> url();  Future<Elements> html();  Future<String> text();
  Future<T?> run<T>(String js);  Future<String?> cookies();                            // Cookie header
  Future<Page> click(String selector, {Duration? timeout});                             // auto-wait
  Future<Page> fill(String selector, String value, {Duration? timeout});
  Future<Page> select(String selector, String value, {Duration? timeout});
  Future<Page> upload(String selector, Reader file, {Duration? timeout});
  Future<Page> press(String key);  Future<Page> scroll([String? selector, Duration? timeout]);  // scroll auto-waits too
  Future<Page> wait(String selector, {Duration? timeout});  Future<Page> idle({Duration? timeout});
  Reader screenshot({bool fullPage = false});  Reader pdf();                            // captured when read
  Future<Download> download(String selector, {Duration? timeout});
}
final class Download with Reader { String name(); }
```

- `launch` fetches Chromium into the user cache (once per machine) unless `path` is given. `profile` keeps logins
  between runs; without it, a temp profile is deleted on `close`. `connect` attaches, and its
  `close` only disconnects.
- Tab setup happens at `open`: `headers` (including `user-agent`), `block` by resource type
  (`'image'`, `'font'`, `'media'`, `'stylesheet'`), and the viewport. Dialogs are always
  dismissed.
- Actions wait until the first match is attached, visible and enabled (`upload`: attached only,
  since file inputs are usually hidden). They time out (30 s) with a `TimeoutException` naming the
  selector. `fill` clears the field, types the value, and fires `input`/`change`.
- `idle` waits for 500 ms with no request in flight. Each `download` has its own folder, so
  concurrent downloads don't clash.
- `run<T>` awaits promises and reads the result with the `Json.value<T>()` rules (use
  `List<Object?>`/`Map<String, Object?>` for collections). `press` takes the key names of §4.12;
  an unknown name is an `ArgumentError`.
- `chrome` re-exports `html`, so `page.html().$('a')` needs one import.
- `Browser.close()` closes every tab and the process; a crash or error never leaves Chromium
  running.

```dart
final page = await Chrome.launch(profile: '.chrome').open(loginUrl, block: ['image', 'font'])
    .fill('#user', name).fill('#pass', pass).click('button[type=submit]').wait('.dashboard');
final invoice = await page.download('a.invoice');
await (invoice > Fs.dir('invoices').file(invoice.name()));
final api = await Http.get(apiUrl, headers: {'cookie': ?await page.cookies()}).json();
```

### 4.4 json

```dart
final class Json extends Iterable<Json> {
  static Json parse(String json);
  static String encode(Object? value, {bool pretty = false});
  Json $(String path);  Json operator [](int i);
  T? value<T>();  T or<T>(T fallback);           // typed read, null / the fallback when absent or mistyped
  List<T> asList<T>();  Map<String, T> asMap<T>();   // empty when missing or mistyped
}
extension on Reader { Future<Json> json(); }
```

- `$('a.b.0')` walks dotted paths, and a numeric segment indexes an array. A `*` segment maps
  over every item: `$('data.users.*.name').asList<String>()`. A missing path is a `Json` of
  `null`, never a throw.
- `value<T>()` returns `null` when the value is absent or not a `T`. Integral numbers read as both
  `int` and `double`, so `3`, `3.0`, `value<int>()` and `value<double>()` all agree.
  `$('port').or(8080)` is a non-null `int`. `asList<T>()` and `asMap<T>()` check each element
  and give `[]` / `{}` when missing or mistyped (`p.$('tags').asList<int>()`); `value<List<T>>()`
  asserts and points to them.
- A `Json` iterates an array's items or an object's values. Lazy wrapping keeps `[i]` and
  iteration O(1) per item.
- `encode` accepts what `dart:convert` accepts (string keys) and throws what it throws.
  Invalid JSON is a `FormatException`.

### 4.5 fs

```dart
abstract final class Fs {
  static Future<Entry?> entry(String path);   // what is on disk, links not followed
  static File file(String path);  static Dir dir(String path);  static Link link(String path);  // no I/O
}
sealed class Entry {
  String path();  String name();  Dir parent();
  Future<bool> exists();  Future<void> delete();
  Future<Entry> copy(String to);  Future<Entry> move(String to);   // subtypes narrow the return type
}
final class File extends Entry with Reader implements Writer {
  Future<File> write(String text);  Future<File> append(String text);  Future<int> size();
}
final class Dir extends Entry {
  File file(String name);  Dir dir(String name);
  Future<List<Entry>> list({bool recursive = false});  Future<Dir> create();
}
final class Link extends Entry {
  Future<String> target();  Future<Entry?> resolve();  Future<Link> create(String target);
}
```

- `switch (await Fs.entry(p))` is exhaustive over `File`/`Dir`/`Link`/`null`.
- **Writes are atomic.** Content goes to a temp sibling, which is renamed over the target. Writes
  go through symlinks to their target, keep the old file's mode, and create missing parents. A
  failed run leaves the old content. `append` uses OS append mode (`O_APPEND`) with an exclusive
  file lock, guaranteeing concurrent appends never lose data or replace open inodes.
- Future mirrors (`EntryFuture`, `FileFuture`, `DirFuture`, `LinkFuture`) repeat every member on
  their respective `Future`s per Rule 4.
- **`copy`/`move`:**
  - They keep modes and timestamps (folders too) and create parents.
  - `move` renames, and falls back to copy-then-delete only across devices.
  - A missing source, or a destination inside the source, throws before anything is written.
- `exists()` checks the handle's kind, and `delete()` is a no-op when nothing is there.
- `resolve()` returns a handle at the final target, or `null` when the link is broken.
  `Link.create` replaces a link atomically.
- `list()` is typed and sorted by name, and `recursive` never follows links. A script that also
  imports `dart:io` adds `hide File, Directory, Link`.

### 4.6 shell

```dart
abstract final class Shell {
  static Future<Output> run(List<String> command, {String? dir, Map<String, String>? env});
  static Pipe filter(List<String> command, {String? dir, Map<String, String>? env});
  static Future<void> open(String target);    // URL or path, in the default app
}
final class Output with Reader { int code();  bool ok();  String err(); }   // Reader = stdout
```

- `command[0]` is the program, looked up on `PATH`, and there is no shell, so arguments are safe.
  Use `['sh', '-c', …]` for shell syntax.
- `run` closes stdin and waits for the exit. `text()` drops one trailing newline, as `$(…)` does
  in a shell; `> file` and `bytes()` stay verbatim. A non-zero exit is an `Output`; a program that
  can't start throws `ProcessException`, with the OS error code. An `Output` is in memory, so it
  can be read many times.
- `filter`: the stream goes to stdin and stdout comes out. A non-zero exit fails the run with the
  full stderr. A child that stops reading early (`head`, `grep -m`) is not an error.
- `open` uses `open`/`xdg-open`/`start` and returns once the program has launched.

```dart
final head = await Shell.run(['git', 'rev-parse', 'HEAD']).text();
await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
```

### 4.7 archive

```dart
enum ArchiveFormat { zip, tar, tgz }
abstract final class Archive {
  static Reader pack(String dir, ArchiveFormat format);   // the contents of dir, built when read
  static Writer unpack(String dir);                       // format from the magic bytes
  static Pipe gzip();  static Pipe gunzip();
}
```

- `unpack` checks every member first: absolute paths, `..` escapes and links are a
  `FormatException`. It then extracts into a temp sibling and moves the members into `dir`,
  **merging with what is already there and never deleting it**. File modes are kept, so
  executables still run.
- `pack` refuses links, the same as `unpack`, and an empty folder packs and unpacks in every
  format.
- `gunzip` checks the gzip trailer. Truncated or corrupt data fails the run with a
  `FormatException`.
- `zip` is held in memory (its directory is at the end); tar and tgz stream member by member.

```dart
await (Http.get(releaseUrl) > Archive.unpack('vendor'));
await Http.put(uploadUrl, body: Archive.pack('site', .zip));
```

### 4.8 hash

```dart
abstract final class Hash { static Hasher md5(); static Hasher sha1(); static Hasher sha256(); static Hasher sha512(); }
final class Hasher implements Writer, Pipe { Hasher add(String text);  Hasher addBytes(List<int> data);  String hex(); }
```

- One type has three uses. Incremental: `h.add(a).add(b).hex()`. As a writer: `r > h`. As a
  tee: `r | h > file`, one pass that both stores and checksums.
- `hex()` is final, and an `add` after it is a `StateError`. A hasher that saw part of a failed
  run throws `StateError` from `hex()` instead of returning a wrong digest.

### 4.9 pool

```dart
abstract final class Pool {
  static Future<R> run<R>(FutureOr<R> Function() job);                        // on a worker
  static Future<List<R>> runAll<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, void Function(R result)? onResult});                       // on the workers
  static Future<List<R>> map<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, void Function(R result)? onResult});                       // on this isolate, for I/O
  static Future<void> close();
}
```

- One process-wide pool starts lazily, with `max(1, cores − 1)` workers that are reused. A job is
  a top-level or static function, or a closure that captures only sendable values.
- `runAll` and `map` return results in input order; `runAll` runs the jobs on the workers (CPU-bound,
  sendable), `map` on this isolate, so a job may capture a client or a bar and I/O fans out. `limit` defaults to the worker count. `onResult` runs on
  the caller's isolate (progress goes there). The first error stops new jobs and is rethrown.
- **Idle workers never keep the script alive;** the pool shuts itself down when no job is left.
  `close()` stops the workers now, and jobs still in flight fail with `StateError`.

```dart
final bar = Console.bar(urls.length, label: 'pages');
await Pool.map(urls, fetch, onResult: (_) => bar.tick());
await bar.close();
```

### 4.10 cli

```dart
sealed class Param<T> {}                                   // read back with context(param) as a T
final class Flag extends Param<bool> { Flag(String name, String help, {String? short, bool or = false}); }
final class Opt<T> extends Param<T> { Opt(String name, String help, {String? short, T? or, bool required = false, T Function(String)? parse}); }
final class Multi<T> extends Param<List<T>> { Multi(String name, String help, {String? short, List<T> or = const [], T Function(String)? parse}); }
final class Arg<T> extends Param<T> { Arg(String name, String help, {T? or, bool required = false, T Function(String)? parse}); }
final class Command {
  Command(String name, String help, {List<Param<Object?>> params = const [], List<Command> commands = const [],
      FutureOr<void> Function(Context context)? handler, List<String> aliases = const []});
  Future<int> run(List<String> argv);                     // 0 ok/help, 64 usage, 1 failure
}
final class Context { T call<T>(Param<T> param);  List<String> rest();  String usage(); }
final class UsageException implements Exception { const UsageException(String message); }
```

- **The type comes from the definition.** `Opt<int>('port', …, or: 8080)` reads as `int`, and
  `Opt<String?>('out', …)` reads as `String?`. A non-nullable `T` without `or` or `required` is an
  `ArgumentError`. Built-in `T`s are `String`, `int`, `double`, `num`, `Duration`, `DateTime` and
  `Uri`; anything else needs `parse:`. Yes/no is always a `Flag`. `Multi<T>` reads as `List<T>`.
  The positionals left after the `Arg`s are `context.rest()`.
- **Syntax:**
  - `--x v`, `--x=v`, `-x v`, `-xv`, grouped `-vq`, and `--no-x` for a flag whose `or` is `true`.
  - `--` ends the options. `-5` stays positional when no short answers to it.
- **Subcommands:**
  - Dispatch is by name or alias, to any depth.
  - A parent's options can be given before or after the subcommand. The `Multi` values merge, and
    `required` is checked at every level.
  - A child can't redeclare an ancestor's name or short.
- **Help:**
  - `--help`/`-h` are always reserved; a declared `short: 'h'` takes only `-h`.
  - `help a b` works at any depth.
  - `usage()` lists `-h, --help`.
- **Errors:**
  - Usage errors print one line, plus `Run "<cmd> --help" for usage.` naming the deepest command,
    and exit 64. Unknown names suggest the closest option or command name.
  - A handler's `UsageException` is a 64, and any other `Exception` prints one line and is a 1.
  - An `Error` (a bug) propagates with its stack trace.

```dart
final verbose = Flag('verbose', 'Print every request.', short: 'v');
final out = Opt<String>('out', 'Output folder.', short: 'o', or: 'out');
final url = Arg<String>('url', 'URL to fetch.', required: true);
exitCode = await Command('fetch', 'Fetch pages.', params: [verbose, out], commands: [
  Command('get', 'Fetch one URL.', params: [url], handler: (c) => fetch(c(url), c(out), c(verbose))),
]).run(argv);
```

### 4.11 console

```dart
abstract final class Console {
  static Color? accent;  // null (default) = no colour; e.g. Color.orange for live lines and the choose row
  static Future<String?> ask(String question, {bool secret = false, String? or});
  static Future<bool> confirm(String question, {bool or = false});
  static Future<T?> choose<T>(String question, List<T> items, {String Function(T)? label, T? or, Map<String, T>? keys});
  static Future<String> key({String? prompt});
  static Future<T> spin<T>(String label, Future<T> work);
  static Bar bar(int? total, {String? label});   // null = unknown
  static void log(String line);                    // prints above a live spinner or bar
  static void clear();
}
final class Bar implements Pipe, Closeable { Bar tick([int count = 1]);  Bar setTotal(int? total); }
```

- Everything goes to stderr, so stdout stays clean for data.
- Prompts are asynchronous: timers, downloads and bars keep running while one waits. Ctrl-C at a
  prompt restores the terminal and exits with 130.
- **A closed stdin is not an error.** `ask` and `choose` give their `or` (null without one),
  `confirm` gives its `or` (false by default); the same goes for Escape in a Tui popup. An empty
  line also gives `ask` its `or`. The hint shows it: `Name? [Ada]`, `Sure? [y/N]`.
- `confirm` takes y/yes/n/no, and Enter gives `or`. On a terminal, `choose` uses the arrow keys,
  scrolling when the choices outnumber the rows. Piped, it reads a number.
- **The live line** (one `spin` or `bar` at a time; a second is a `StateError` before anything is
  drawn):
  - It always fits the terminal width, which is re-read on resize. The label is cut with `…`, the
    bar shrinks, and every redraw clears to the end of the line.
  - It redraws at most every 80 ms.
- **A bar as a `Pipe`** counts bytes and shows sizes and a rate (`12.1/40 MB  1.2 MB/s`). Used with
  `tick()`, it counts items (`12/40  3.1/s`). A `null` total shows a count and a rate, with no
  bar, so `Console.bar(res.size())` just works. The bar renders as a clean line track (`━━╸──`),
  matching the `tui` aesthetic. `close()` prints the final line.
- A bar takes the live line on first use and gives it back when it closes, or when its pipeline
  fails at any point.
- Without a terminal, or with `NO_COLOR` set, there is no animation: each bar or spinner prints
  one final line.

### 4.12 tui

```dart
abstract final class Tui {
  static Future<S> run<S>(S state, Screen Function(S state, App<S> app) screen,
      {Color? accent});   // null = monochrome (bold/dim/reverse only); an accent adds colour
}
final class App<S> {
  S state();  void go(S state);  void status(String message);
  void notify(String message);                     // OSC 9/777, bell fallback; no-op while focused
  void copy(String text);               // OSC 52
  void quit();                                     // run() returns state()
}
final class Screen {
  Screen(void Function(Region r) draw, {String? title, String? status, Map<String, Binding> keys = const {}});
}
typedef Binding = (String label, FutureOr<void> Function() action);
final class Pick<T> {                       // a list's items and selection; O(1) amortised append
  Pick([List<T> items = const []]);
  List<T> items();  int index();  T? selected();  Pick<T> set(List<T> items);  Pick<T> select(int index);
  Pick<T> add(T item);  Pick<T> addAll(Iterable<T> items);  Pick<T> remove(T item);  Pick<T> removeWhere(bool Function(T item) test);
}
final class Field {                          // an editor's text, cursor and history
  Field({String text = '', List<String> history = const []});
  String text();  List<String> history();  Field set(String text);  String submit();
}
final class Scroll { Scroll({bool follow = true}); }
final class Region {
  int width();  int height();  bool hovered();  bool focused();
  Region write(String text, {Color? color, Color? background, Set<Style> style = const {}, String? link});
  Region markdown(String source);  Region diff(String before, String after);
  Region box([String title = '']);  List<Region> rows(List<int> sizes);  List<Region> cols(List<int> sizes);
  Region tabs<T>(Pick<T> tabs, String Function(T tab) label);  Region scroll(Scroll scroll);
  Region popup(String title, {int width = 40, int height = 10});
  Region on(Map<String, Binding> events);
  Region list<T>(Pick<T> selection, String Function(T item) label, {String empty = ''});
  Region table<T>(Pick<T> selection, List<String> Function(T item) cells, {List<String>? header, String empty = ''});
  Region input(Field field, {String hint = '', int lines = 1, FutureOr<List<String>> Function(String word)? suggest, FutureOr<void> Function()? onSubmit});
  Region button(String label, FutureOr<void> Function() action);
  Region bar(int done, int? total, {String? label});  Region spin(String label, {DateTime? since});
}
final class Color {                            // black red green yellow blue magenta cyan white gray orange
  const factory Color.index(int index);  const factory Color.rgb(int r, int g, int b);
}
enum Style { bold, dim, italic, underline, strike, reverse }
```

`Region.picture(image)` draws any `Image` (half-block cells); `tui` and `image` never load each other (Image implements a private pixel interface).

- **One look for `Console` and `Tui`**, not customizable:
  - `Region.box` draws `┌ ┐ └ ┘` lines with the title after the top edge. `Console.choose` marks the
    row with `❯`; `Region.list`/`table` show the selection in reverse video (accent colour if set, else bold; dim
    when not focused).
  - Bars (`Console.bar`, `Region.bar`) are `━━╸──`; spinners are Braille `⠋…⠏` and end with
    `✓` / `✗`. The status row's key help reads `key action · key action`.
- **State-driven.** The state is the app's own value, usually a sealed class with one subclass per
  view, so `screen` is an exhaustive `switch`. `screen` runs on every redraw, only describes the
  screen and never blocks. Widget state lives in `Pick`/`Field`/`Scroll` objects held by the
  state, so `app.go(previous)` brings back the query, selection, scroll and focus.
- **Redraws are event-driven**, coalesced to 60 fps, writing only changed cells: after each input
  event, on `go`/`status`, on resize, and whenever work started by a handler (timer, future,
  stream event) delivers, since handlers run in a zone. Spinners animate at 80 ms while visible.
  An idle app uses no CPU.
- **Alternate screen only.** `Tui` owns the whole terminal and captures the mouse; for scrollback output use `Console`.
- **One `Binding` map for every event**, in `Screen(keys:)` and `Region.on`: key names (below, plus
  `shift+enter`/`ctrl+enter` where the terminal reports them), `click` `doubleclick` `rightclick`
  `middleclick` `wheelup` `wheeldown`, and `show` `resize` `focus` `blur`. A name may list
  alternatives (`'b escape'`). Hover is a reading: `if (r.hovered()) …`. `keys:` is rebuilt with
  the screen, so collection `if` makes bindings and help depend on the state.
- **Routing.** A key goes to the first taker: an open popup (a `Console` prompt, a `suggest` list);
  the focused widget or `on` region; `tab`/`shift+tab` moving the focus unless bound; the `Screen`
  keys; any other drawn widget that uses it, in drawn order; unbound `ctrl+c`, which quits. Mouse
  events go to the innermost region under the pointer, then outwards, then to `keys`.
- **Widgets:**
  - `list`/`table`: `up` `down` `pageup` `pagedown` `home` `end`, the wheel, and a click (selects
    and focuses). `tabs`: `left` `right` and a click. `button`: `enter`/`space` and a click.
  - `scroll`: the wheel, and when focused the page keys; a scrollbar when it overflows. With
    `follow`, it stays at the end as content grows; scrolling up unpins, `end` re-pins.
  - `input`: text and bracketed paste; `backspace`/`delete` by grapheme, `ctrl+w`/`alt+backspace`
    by word, `ctrl+u`/`ctrl+k` to the line's start/end; `left` `right` `home` `end` `ctrl+a`
    `ctrl+e`, `alt+`/`ctrl+left`/`right` by word. `lines > 1` grows to that many rows (`0` = no
    cap); `shift+enter`, `alt+enter` or `\` + `enter` insert a newline; `up`/`down` at the first or
    last line walk the history. `onSubmit` handles form submissions; when omitted, unconsumed
    `enter` bubbles to `keys`. `suggest` opens a popup of matches for the word at the cursor.
  - `on`: a region binding a keyboard key is focusable; `focused()`/`hovered()` draw its state.
- **Focus** is object identity (the `Pick`/`Field`/`Scroll`, the `on` key set, a button's label),
  so it survives redraws and state switches. When the focused thing isn't drawn, the first
  focusable one is. A focused list uses the accent, unfocused dim reversed; a focused input shows
  the hardware cursor.
- **Handlers** may be sync or async, and every event runs one, even while an earlier run is
  pending. An `Exception` from a handler, or from work it started, shows as `✗ <first line>` in
  the status row and the app keeps running. An `Error` ends `run` and is rethrown.
- **Rows.** `title` is the top row, in the accent. The bottom status row shows, on the left, the
  error, the `app.status` message, running spinners and bars, or else the screen's `status`; on the right, the key
  help from `keys:` (`enter send · esc interrupt`), with empty labels and mouse/lifecycle bindings
  hidden. A narrow row cuts the help first.
- **Console inside the Tui.** While `run` is active, `Console.spin`/`bar` draw in the status row
  (several at once), `Console.log` goes to the status row, and
  `Console.ask`/`confirm`/`choose` open a modal popup, where `escape` answers like a closed stdin.
- **Drawing.**
  - `write` wraps at the edge, `\n` breaks, `\t` expands, controls show as `�`, and text past the
    last row ends with `…`. Widths follow grapheme clusters: CJK and emoji take 2 cells, combining
    marks and ZWJ 0. `link` makes an OSC 8 hyperlink.
  - `markdown`: headings, nested and numbered lists, quotes, box-drawn tables, `---`; bold,
    italic, strike, `code`, links; fenced code highlighted by one in-house lexer (Dart, JS/TS,
    Python, shell, JSON, YAML, Rust, Go, C-likes). Safe to stream: an unclosed fence or emphasis
    renders as closed. Layout is cached by `(source, width)`.
  - `diff`: a Myers line diff in unified hunks with 3 context lines, gutter line numbers, and
    `-`/`+` rows on red/green with the changed words of paired lines brighter.
  - `rows`/`cols`: a size above 0 is fixed, 0 shares what is left. `box(title)` borders the rest
    and returns the inside. `popup` is drawn last, centered. `bar` lays out like `Console.bar`.
    `scroll` lays out its content once per redraw and paints only the viewport.
  - Colours are downgraded to the terminal's level (truecolor → 256 → 16). `NO_COLOR` drops them
    and keeps styles. `LANG=C`/no UTF-8 switches boxes, bars and spinners to ASCII.
- **Key names**, shared with `Page.press`:
  - printable characters as themselves, plus `'space'`;
  - `'enter'` `'tab'` `'shift+tab'` `'backspace'` `'escape'` `'insert'` `'delete'`;
  - `'up'` `'down'` `'left'` `'right'` `'home'` `'end'` `'pageup'` `'pagedown'`, `'f1'`…`'f12'`;
  - `ctrl+`/`alt+`/`shift+` prefixes (`'ctrl+c'`, `'alt+x'`, `'ctrl+up'`).
  - Unknown sequences are ignored, never reported as `escape`; a split sequence is held up to 1 s.
- **Terminal life:**
  - `run` enters raw mode (and in full screen the alternate screen and mouse reporting), turns
    autowrap, bracketed paste and focus reports on and off, and restores the terminal when the
    app quits or throws, on Ctrl-C, on SIGTERM/SIGHUP, and on an uncaught error in work the app
    started (rethrown from `run`). On macOS and Linux, Ctrl-Z suspends and resumes with a full repaint; on Windows only Ctrl-C ends the app.
  - A resize repaints every cell. Frames use synchronized output, so nothing tears. Shift-drag
    still selects text natively while the mouse is captured.
  - `run` can be called again, and prompts work before and after it; a second `run` while one
    is active throws `StateError`. After `quit`, `run` returns without waiting for pending
    handlers. Nothing is left listening to the terminal, so the script exits when `main` ends.
    On POSIX, input is read through a restartable child `cat /dev/tty`.
  - It throws `StdoutException` when stdout is not a terminal.

```dart
typedef Hit = ({String title, String url});
sealed class Page {}
final class Search extends Page { final query = Field(); final hits = Pick<Hit>(); }
final class Series extends Page { Series(this.back, this.hit); final Search back; final Hit hit; final chapters = Pick<String>(); }

await Tui.run<Page>(Search(), (page, app) => switch (page) {
  Search s => Screen(title: 'search', (r) {
      final [body, foot] = r.rows([0, 3]);
      body.list(s.hits, (h) => h.title, empty: 'type a title, press enter');
      foot.box('query').input(s.query);
    }, keys: {
      'enter': ('search', () async => s.hits.set(await Console.spin('searching', search(s.query.text())))),
      'ctrl+o': ('open', () => app.go(Series(s, s.hits.selected()!))),
      'escape': ('quit', app.quit),
    }),
  Series c => Screen(title: c.hit.title, (r) => r.list(c.chapters, (t) => t), keys: {
      'b escape': ('back', () => app.go(c.back)),
    }),
});
```

### 4.13 image

```dart
enum ImageFormat { png, jpg, gif, bmp, tiff, ico }
final class Image {
  static Image decode(List<int> bytes);
  static String? sniff(List<int> bytes);          // "jpg" "png" "gif" "webp" "bmp" "tiff" "ico" or null, header only
  int width();  int height();
  Image resize({int? width, int? height});  Image crop(int x, int y, int width, int height);
  Reader encode(ImageFormat format, {int quality = 90});
}
extension on Reader { Future<Image> image(); }
```

- `decode` reads PNG, JPEG, GIF (first frame only), BMP, WebP, TIFF and ICO, with the EXIF
  orientation applied. An unknown format is a `FormatException`.
- `resize` keeps the aspect ratio when one side is given. A missing or non-positive size is an
  `ArgumentError`. `crop` outside the image is a `RangeError`.
- `encode` is a lazy `Reader`. `quality` applies to JPEG, and `.ico` above 256 px is an
  `ArgumentError`. The work is CPU-bound, so batches go through `Pool.map`.

### 4.14 scrape

```dart
abstract final class Scrape {
  static Stream<T> crawl<T>(Iterable<String> urls, Future<void> Function(Visit<T> visit) handler, {
    int limit = 4, Duration? delay, int retries = 2, String? cache,
    Map<String, String>? headers, Duration? timeout, Browser? browser,
    void Function(String url, Object error)? onError});
}
final class Visit<T> with Reader {
  String url();  int status();  bool ok();  int size();  String name();   // name() via shared origin()
  Visit<T> follow(Iterable<String> urls, Future<void> Function(Visit<T> visit) handler);
  Visit<T> emit(T item);
}
```

- This module is the crawl around `Http.get(u).html()`: a deduplicated queue, `limit` in flight,
  a per-host `delay`, and `retries`. Retries cover network errors, timeouts, 5xx and 429, with
  backoff or `Retry-After`.
- `cache` is a folder of bodies by URL, so a rerun is offline.
- Routing is by function: `follow(urls, handler)`. URLs are made absolute and their fragments
  dropped, non-http(s) links (`mailto:`, `javascript:`…) are skipped, and each URL is visited once.
- `crawl` returns a stream of the emitted records. It completes when the queue is drained.
  Cancelling it stops the crawl.
- A `Visit` is a `Reader` of the body, decoded like `Response.text()`: `html()` uses the final URL
  as its base, and `json()` and `> file` work too. A 404 reaches its handler.
- A failure ends the run (the queue is dropped, visits in flight finish, and the stream errors)
  unless `onError` is set. Every tab is closed whatever happens. `scrape` re-exports `html`.
- With `browser`, visits are tabs, `html()` is the rendered DOM, and the handlers are unchanged.

```dart
final albums = await Scrape.crawl<Album>([listUrl], listing, delay: Duration(milliseconds: 250), cache: '.cache').toList();
Future<void> listing(Visit<Album> v) async {
  final doc = await v.html();
  v.follow(doc.$('a.album').attrs('href'), album).follow(doc.$('a.next').attrs('href'), listing);
}
Future<void> album(Visit<Album> v) async =>
    v.emit((title: (await v.html()).$('h1').text(), url: v.url()));
```

## 5. Errors

| Thrown                                         | When                                                                                     |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `IOException`s (`SocketException`, `HttpException`, `TlsException`, `FileSystemException`) | the network or the disk failed; an HTTP status never throws |
| `ProcessException`                             | a program can't start, or a `Shell.filter` exits non-zero                                |
| `StdinException`, `StdoutException`            | `Console.key` on a closed stdin; no terminal for the TUI                                 |
| `TimeoutException`                             | a response, a stalled body or a browser wait ran out (names the URL or selector)         |
| `FormatException`                              | invalid content: JSON, gzip, an archive or a member, an image, a selector                |
| `ArgumentError`, `RangeError`, `StateError`    | the caller's mistake: wrong data type, bad size, index, non-sendable job, double read    |
| `UsageException` (cli)                         | the only exception type of our own: a handler rejects its input, giving exit 64          |

Engine exceptions are rethrown as one of these, naming the subject. An error inside a pipeline
surfaces from its `>`/`to`, after cleanup. An error in a chain surfaces at its single `await`.

## 6. Performance and testing

- Pipelines stream 64 KiB chunks with backpressure, so a 10 GB download, hash and save runs at
  constant memory in one pass. `text()`/`bytes()`/`html()`/`json()`/`image()` load everything into
  memory, and are meant for documents.
- Lazy content (`screenshot` `pdf` `encode` `pack`) does no work until it is read. A Future mirror
  costs one `await`.
- An engine stays until an A/B measurement (alternating rounds, medians, from one sitting) shows it
  is the bottleneck. A module compiles only its own engine.
- Each module has one test file, with a test per listed member and per mirror. Tests use real
  resources: a loopback server, temp folders, Chromium, a pseudo-terminal for `console`/`tui`, and
  real `sh`/`grep`.
- Every fixed bug keeps a regression test.

## 7. Not included

Native code and codegen; test seams in the public API; sync twins and aliases; fan-out to several
writers; download resume; file watching and globbing; browser interception beyond `block`, frames
and `hover`; colours outside the TUI; a TUI widget tree (widget state lives in
`Pick`/`Field`/`Scroll`); terminal images beyond half-blocks (Sixel, kitty), `ctrl+r` history search
and vim mode in `input`; HMAC; torrents. Each comes back only when a real script needs it.
