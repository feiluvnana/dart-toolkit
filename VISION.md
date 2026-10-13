# Vision: dart_toolkit v2

**Minimal surface, short names, chains that read like sentences, and bytes that flow like a
shell, on good pub engines.** Each module is a thin facade: one entry class, a few value types,
an exact list of methods, and the engine hidden behind private fields. Modules plug into each
other through four core interfaces: `Reader`, `Writer`, `Pipe` and `Closeable`. Every async result
can be chained without an inner `await`. If an engine turns out slow or broken, an in-house one
replaces it without changing a single call site.

```dart
final title = await Http.get('https://example.com').html().$('title').text();
final port = await Fs.file('conf.json').json().$('server.port').value<int>() ?? 8080;
await (Fs.file('photo.jpg').image().resize(width: 800).encode(.jpg) > Fs.file('thumb.jpg'));

final res = await Http.get('https://example.com/disc.iso');
final size = int.parse(res.header('content-length') ?? '0');
final hash = Hash.sha256();
await (res | (quiet ? null : Console.bar(size, label: 'disc.iso')) | hash > Fs.file('disc.iso'));
print(hash.hex());                                  // one pass: progress, checksum, atomic file

final browser = await Chrome.launch();
final page = await browser.open('https://example.com/report').click('#accept').waitIdle();
await (page.pdf() > Fs.file('report.pdf'));
await browser.close();
```

---

## 1. Principles

| # | Rule |
|---|---|
| 1 | **Minimal surface.** A member exists only when a real script cannot do without it. Each library's doc comment says `Public surface is exactly: …`, and a test covers every listed member. |
| 2 | **Short names.** A name is one word, or two when the second removes doubt (`exitCode`, `baseUrl`, `fullPage`, `cookieHeader`). The only symbols are `$` (query), `[]` (index), `\|` (pipe through) and `>` (pipe into). Extensions (Future mirrors, readings) are unnamed, so they add no names at all. |
| 3 | **The same idea has the same name, everywhere** (§5). Before adding a member, look for the idea in the table; if it is there, use that name. |
| 4 | **One entry class per module, named for the module** (`Http`, `Html`, `Fs`…). It is `abstract final` and holds only statics, so typing `Http.` lists every way in. A module whose only value type shares its name (`Json`, `Image`) puts the statics on that type instead. |
| 5 | **Values are `final class`es with a private constructor;** only the facade builds them. Every read is a method (`status()`, `text()`), never a getter. The only getters are the ones Dart's `Iterable` already has. |
| 6 | **Chains never need an inner `await`.** Each value type that is produced asynchronously has a `Future<T>` mirror: an unnamed extension on `Future<T>` repeating every member of `T`, each returning a `Future`. Mirrors carry the same names, so they add no surface to learn. |
| 7 | **Actions return their receiver** (inside a `Future` when async), so they chain: `page.fill(…).click(…)`, `file.write(…).size()`, `hash.add(a).add(b)`. An action that makes something new returns that instead (`copy`, `move`, `download`). Entry statics return what they make. Readings return data. `close()` and `delete()` return nothing. |
| 8 | **Content leaves as a `Reader` and arrives through a `Writer`.** No method takes an output path: a screenshot, a PDF, an encoded image, a packed archive and a download are all `Reader`s, stored with `> Fs.file(…)`, hashed with `\| hash`, or uploaded with `body:`. |
| 9 | **Modules compose through core and plain values.** Core types (`Reader`, `Writer`, `Pipe`, `Closeable`), plus `String` (text, paths, URLs, selectors), `List<int>` (bytes) and `Elements` (the DOM, shared by html and chrome). A module that makes a value from bytes adds one reading to `Reader`: `html()`, `json()`, `image()`. |
| 10 | **Never null for collections, nullable for single lookups.** No match gives an empty `Elements`; a missing attribute, header, option or cookie gives `null`. |
| 11 | **Outcomes are values; only failing to reach throws.** A 404 is a `Response`, a non-zero exit is an `Output`, malformed markup still parses, a missing path is `null`. What throws is the network, the disk, a browser that won't start, a program that won't run, or a wait that runs out. |
| 12 | **In memory is sync; I/O is async.** There are no sync twins. |
| 13 | **Options are named parameters, optional, with defaults;** required inputs are positional, and there are no required named parameters. The one optional positional allowed is a trailing parameter that reads as the call's object (`bar.tick(n)`, `page.scroll(selector)`). There are no option objects, builders, or flags that change the result type. |
| 14 | **`close()` releases a resource,** and it is idempotent. Everything that holds one implements `Closeable`. `delete()` removes a thing from disk. |
| 15 | **In-memory content is data: a `String` (UTF-8) or a `List<int>`** (`file.write(data)`, `hash.add(data)`). It is one `Object` parameter, checked at the call; anything else is an `ArgumentError`. A parameter that sends content somewhere that isn't a `Writer` (`body:`) also takes a `Reader`, streamed. |
| 16 | **No code generation,** for users or inside the package. The SDK floor is Dart 3.10, for dot shorthands (`encode(.jpg)`, `pack('site', .zip)`). |

## 2. Core

`core.dart` is re-exported by every module. It is our own code, with no engine behind it.

```dart
/// Bytes you can read. Implement [stream]; everything else comes with it.
abstract mixin class Reader {
  Stream<List<int>> stream();                     // single-subscription chunks; the one member to implement

  Future<List<int>> bytes();                      // read everything into memory
  Future<String> text();                          // UTF-8, malformed bytes replaced; types may refine (charset)
  Reader pipe(Pipe? pipe);                        // lazy: nothing flows yet; null → this reader, unchanged
  Reader operator |(Pipe? pipe);                  // = pipe(pipe)
  Future<void> to(Writer? writer);                // runs the pipeline to the end; null → run and discard
  Future<void> operator >(Writer? writer);        // = to(writer)
}

/// Somewhere bytes end up: a file, a hash, an unpacked folder.
abstract interface class Writer {
  Future<void> consume(Stream<List<int>> input);
}

/// Something bytes pass through: a hash, a progress bar, gzip, a process.
abstract interface class Pipe {
  Stream<List<int>> transform(Stream<List<int>> input);
}

/// Something that holds a resource until closed: a browser, a page, a response, a bar.
abstract interface class Closeable {
  Future<void> close();                           // idempotent
}

extension on Future<Reader> {                     // `Http.get(u).text()`, `Http.get(u) | hash > file`
  Future<List<int>> bytes();
  Future<String> text();
  Reader pipe(Pipe? pipe);
  Reader operator |(Pipe? pipe);
  Future<void> to(Writer? writer);
  Future<void> operator >(Writer? writer);
}

extension on Future<Closeable> {                   // `Chrome.launch().close()`; one mirror for every type
  Future<void> close();
}
```

**Who implements what:**

| Type | `Reader` | `Writer` | `Pipe` | `Closeable` | |
|---|---|---|---|---|---|
| `Response` (http) | ✓ | | | ✓ | the body, streamed from the socket; `close` drops an unread body |
| `File` (fs) | ✓ | ✓ | | | read in 64 KiB chunks; written atomically |
| `Output` (shell) | ✓ | | | | the program's stdout |
| `Download` (chrome) | ✓ | | | | a finished browser download |
| `Visit` (scrape) | ✓ | | | | the body of the page being handled |
| `page.screenshot()` / `page.pdf()` | ✓ | | | | captured when read |
| `image.encode(format)` | ✓ | | | | the encoded image |
| `Archive.pack(dir, format)` | ✓ | | | | the archive's bytes |
| `Archive.unpack(dir)` | | ✓ | | | extracts what it is given into `dir` |
| `Hasher` (hash) | | ✓ | ✓ | | digests what goes in, and passes it through unchanged |
| `Bar` (console) | | | ✓ | ✓ | counts the bytes that pass, and closes at the end |
| `Archive.gzip()` / `gunzip()` | | | ✓ | | compress or decompress on the way |
| `Shell.filter(command)` | | | ✓ | | a process as a filter: stdin in, stdout out |
| `Browser`, `Page` (chrome) | | | | ✓ | the browser process, a tab |

**Readings other modules add to `Reader`,** each on `Reader` and `Future<Reader>`:

| Reading | Module | Returns |
|---|---|---|
| `html()` | html | `Future<Elements>`; relative links resolve against the response's URL |
| `json()` | json | `Future<Json>` |
| `image()` | image | `Future<Image>` |

**How a pipeline reads:**

- `a | p` is a new `Reader`, and nothing flows yet.
- `a > w` runs everything to the end and completes when `w` has stored the last byte.
- Dart's precedence makes `a | p | q > w` group like a shell, `((a | p) | q) > w`. Write
  `await (…)` around an operator chain, because `await` binds tighter than `|`. The methods need no
  parentheses: `await Http.get(u).pipe(hash).to(file)`.
- A writer's result is read from the writer itself after the pipeline: `hash.hex()`, or the file
  on disk.
- **Null stages make optional steps inline.** A `null` pipe is skipped. A `null` writer still runs
  everything upstream to the end and throws the bytes away, which is how a pipe-only run (a
  checksum, a dry run, a progress count) is written:

```dart
await (res
    | (quiet ? null : Console.bar(size))
    | (verify ? hash : null)
    > (dry ? null : Fs.file('a.iso')));
```

| I want | Line |
|---|---|
| a download to a file | `await (Http.get(url) > Fs.file('a.zip'))` |
| a download, hashed and saved in one pass | `await (Http.get(url) \| hash > Fs.file('a.zip'))` |
| a checksum only, nothing stored | `await (Http.get(url) \| hash > null)` |
| a file copy with progress | `await (Fs.file('a.iso') \| Console.bar(size) > Fs.file('b.iso'))` |
| a download unpacked | `await (Http.get(url) > Archive.unpack('vendor'))` |
| a folder zipped and uploaded | `await Http.put(url, body: Archive.pack('site', .zip))` |
| a page screenshot | `await (page.screenshot(fullPage: true) > Fs.file('shot.png'))` |
| JSON through `jq` | `await (Http.get(url) \| Shell.filter(['jq', '.items']) > Fs.file('items.json'))` |
| a body as a value | `await Http.get(url).text()` · `.json()` · `.html()` · `.image()` |

**Rules:**

- **Backpressure is the stream's.** A slow writer pauses the reader. Memory stays at a few chunks
  whatever the size of the data.
- **One pass.** `stream()` is called once per run. A one-shot reader (`Response`, `Output`) throws
  a `StateError` when streamed twice. A `File`, a `Download` and the lazy readers re-open or
  re-capture.
- **An error anywhere fails the whole run.** The reader is cancelled, a `File` writer drops its
  temp file (the old content stays), a `Bar` prints `✗`, and the error is rethrown from `>`/`to`.
- **Nothing starts until read.** `Fs.file(p) | hash` opens no file and `page.screenshot()` takes
  no picture until `>` runs.

**Extending.** A new source, store, step or resource is one class with one member, and it then
works with every module:

```dart
final class Crlf implements Pipe {                 // a step: CRLF → LF
  @override
  Stream<List<int>> transform(Stream<List<int>> input) =>
      input.transform(utf8.decoder).map((s) => s.replaceAll('\r\n', '\n')).transform(utf8.encoder);
}

final class Stdout implements Writer {             // a store: the terminal
  @override
  Future<void> consume(Stream<List<int>> input) => stdout.addStream(input);
}

final class Memory with Reader {                   // a source: bytes in memory
  Memory(this._data);
  final List<int> _data;
  @override
  Stream<List<int>> stream() => Stream.value(_data);
}

await (Http.get(url) | Crlf() > Stdout());
```

## 3. The module contract

Every module repeats one shape:

```dart
/// <One-line purpose>. Thin facade over `package:<engine>`.
///
/// ```dart
/// <three to six lines showing the whole surface>
/// ```
///
/// Public surface is exactly: [Module], [Value].
/// - <one line per type: what it supports>
/// Everything else is private.
library;

import 'package:<engine>/<engine>.dart' as e;      // the only engine import
export 'core.dart';

abstract final class Module {                         // statics only: the module's ways in
  static Future<Value> verb(String input) async => Value._(await e.call(input));
}

final class Value with Reader implements Closeable {   // core interfaces where they apply
  Value._(this._inner);                               // only the facade builds values
  final e.Thing _inner;                               // the engine stays private
  String name() => _inner.name;                       // short reads
  @override
  Stream<List<int>> stream() => _inner.body;
  @override
  Future<void> close() => _inner.release();
}

extension on Future<Value> {                          // the Future mirror (rule 6), unnamed
  Future<String> name() async => (await this).name();
}
```

**Engine-swap rules.** These rules make replacing an engine (for example `package:html` with an
in-house parser under `lib/src/html/`) a rewrite of private fields that passes the same tests.

- An engine type never appears in a public signature, a public field, a generic argument, or a
  re-export.
- An engine exception a caller would have to catch is rethrown at the boundary as Dart's own type
  (§8), naming its subject (the URL, the path, the selector).
- Engine behaviour that callers would notice changing (charset defaults, selector syntax, path
  joining) is pinned by the facade's tests.
- The facade's tests use real servers, real files, a real browser and a real terminal, never the
  engine's API, so they keep passing after a swap.
- An engine is replaced when an A/B measurement shows it is the bottleneck, or when it is
  abandoned or wrong, and never just for taste.

## 4. Modules: fourteen, plus core

| Import | Public surface, exactly (core members and Future mirrors not repeated) | Engine |
|---|---|---|
| `core.dart` | `Reader`: `stream` `bytes` `text` `pipe` `\|` `to` `>` · `Writer`: `consume` · `Pipe`: `transform` · `Closeable`: `close` | in-house |
| `html.dart` | `Html.parse` · `Reader.html` · `Elements`: `$` `[]` `without` `text` `attr` `attrs` · `Element`: `$` `without` `text` `attr` `parent` | `package:html` |
| `http.dart` | `Http.get` `head` `delete` `options` `post` `put` `patch` · `Response`: `status` `header` `url` | `package:http` |
| `chrome.dart` | `Chrome.launch` `connect` · `Browser`: `open` `pages` · `Page`: `goto` `back` `reload` `url` `html` `text` `eval` `cookieHeader` `click` `fill` `press` `select` `upload` `scroll` `wait` `waitIdle` `screenshot` `pdf` `download` · `Download`: `name` | `package:puppeteer` |
| `json.dart` | `Json.parse` `encode` · `Reader.json` · `Json`: `$` `[]` `value` | `dart:convert` |
| `fs.dart` | `Fs.entry` `file` `dir` `link` · `Entry`: `path` `name` `parent` `exists` `delete` `copy` `move` · `File`: `write` `append` `size` · `Dir`: `file` `dir` `list` `create` · `Link`: `target` `resolve` `create` | `dart:io`, `package:path` |
| `shell.dart` | `Shell.run` `filter` · `Output`: `exitCode` `errorText` | `dart:io` |
| `archive.dart` | `Archive.pack` `unpack` `gzip` `gunzip` · `ArchiveFormat` | `package:archive`, `dart:io` |
| `hash.dart` | `Hash.md5` `sha1` `sha256` `sha512` · `Hasher`: `add` `hex` | `package:crypto` |
| `pool.dart` | `Pool.run` `map` `close` | `package:worker_manager` |
| `cli.dart` | `Cli.parse` · `Args`: `flag` `option` `multi` `rest` `usage` | in-house |
| `console.dart` | `Console.ask` `confirm` `choose` `spin` `bar` · `Bar`: `tick` | `dart:io` |
| `tui.dart` | `Tui.run` · `Screen`: `frame` `pressed` `typed` `width` `height` · `Region`: `write` `box` `rows` `cols` `button` | in-house on `dart:io` |
| `image.dart` | `Image.decode` · `Reader.image` · `Image`: `width` `height` `resize` `crop` `encode` · `ImageFormat` | `package:image` |
| `scrape.dart` | `Scrape.run` · `Visit` (a `Reader`): `url` `status` `follow` `emit` | `http`, `html`, `chrome` from this package |

That is **37 types and about 137 members.** A module imports only core and its engine, with two
exceptions: `chrome` imports `html` for `Elements`, and `scrape` composes `http`, `html` and `chrome`.

## 5. Names: the same idea, the same name

| Idea | Name | Where |
|---|---|---|
| everything as text / as bytes | `text()` / `bytes()` | every `Reader`; `Element`/`Elements`/`Page.text()` for a tree's or a page's text |
| bytes → a value | `html()` `json()` `image()` | readings on every `Reader` |
| text → a value | `parse` | `Html.parse`, `Json.parse`, `Cli.parse` |
| bytes in memory → a value | `decode` | `Image.decode` |
| a value → text or bytes | `encode` | `Json.encode` (→ `String`), `Image.encode` (→ `Reader`) |
| query a tree | `$` | `Elements`, `Element`, `Json` |
| a typed read, `null` when absent or mistyped | `value<T>()`, `eval<T>()` | `Json`, `Page`; `??` gives the default |
| a copy of a tree without some parts | `without(selector)` | `Elements`, `Element` |
| store bytes | `> writer` | every `Reader`; in-memory data uses `write(data)` |
| attach a step | `pipe` / `\|` | every `Reader` |
| feed data in | `add(data)` | `Hasher` |
| count progress | `tick(n)` | `Bar` |
| release a resource | `close()` | every `Closeable`, `Pool.close` |
| remove from disk | `delete()` | `Entry` |
| make a folder or a link | `create()` | `Dir`, `Link` |
| the final URL | `url()` | `Response`, `Page`, `Visit` |
| an HTTP status | `status()` | `Response`, `Visit` |
| run a program, a job, an app | `run` | `Shell.run`, `Pool.run`, `Tui.run` |
| a key | `press(key)` sends it, `pressed(key)` tests it; the same names: `'enter'` `'tab'` `'escape'` `'backspace'` `'up'` `'down'` `'left'` `'right'` `'ctrl+a'` | `Page`, `Screen` |
| wait for readiness | `wait(selector)`, `waitIdle()` | `Page` |
| draw or store content into something | `write` | `File.write(data)`, `Region.write(text)` |
| pixel or cell dimensions | `width()` / `height()`, `width:` / `height:` | `Image`, `Screen`, `Browser.open` |
| a size in bytes | `size()` | `File` |
| request headers / body | `headers:` / `body:` | `Http`, `Browser.open` (headers) |
| a deadline | `timeout:` | every wait: a response, a browser action |
| a text label | `label:` | `Console.bar`, `Console.spin` |
| a callback | `on…:` | `Pool.map(onResult:)`, `Scrape.run(onError:)` |
| the most jobs in flight | `limit:` | `Pool.map`, `Scrape.run` |
| one element's attribute / every element's | `attr(name)` / `attrs(name)` | `Element`, `Elements` |
| queue more work for a handler | `follow(urls, handler)` | `Visit` |
| a record out of a run | `emit(item)` | `Visit` |
| the base for relative links | `baseUrl:` | `Html.parse` |

**Named parameters**, each with one meaning everywhere: `headers` `body` `timeout` `baseUrl`
`headless` `executable` `profile` `proxy` `block` `width` `height` `fullPage` `workingDir` `env`
`recursive` `pretty` `limit` `onResult` `delay` `retries` `cache` `browser` `onError` `short` `help` `secret` `label` `quality` `color` `bold`.

## 6. Kinds of method

| Kind | Rule | Members |
|---|---|---|
| **Entry point** | a static on the entry class: a verb, or a noun that builds a handle (`Fs.file`, `Hash.sha256`, `Archive.gzip`) | `parse` `decode` `encode` (json) `get` `post` `put` `patch` `delete` `head` `options` `launch` `connect` `run` `filter` (shell) `map` `pack` `unpack` `entry` `file` `dir` `link` `md5` `sha1` `sha256` `sha512` `gzip` `gunzip` `ask` `confirm` `choose` `spin` `bar` |
| **Reading** | a noun named for what it returns: sync on a value, a `Future` when it touches I/O, a `Reader` when it is content | `text` `bytes` `html` `json` `image` `status` `header` `url` `eval` `cookieHeader` `attr` `attrs` `exitCode` `errorText` `value` `size` `name` `path` `target` `hex` `width` `height` `pages` `list` `rest` `typed` `usage` · content: `screenshot` `pdf` `encode` (image) |
| **Stream** | joins pipelines (§2) | `stream` `pipe` `\|` `to` `>` `consume` `transform` |
| **Query** | `$(query)` returns a collection, never null; `[i]` indexes it and throws `RangeError` when out of range | `$` `[]` |
| **Navigation** | from one value to a related one | `parent` `file` `dir` `resolve` `open` `box` `rows` `cols` |
| **Declaration** | reads an input and declares it for `usage()` | `flag` `option` `multi` |
| **Action** | a verb that changes the world; returns its receiver, or the new thing it made (rule 7) | `write` `append` `create` `add` `tick` `goto` `back` `reload` `click` `fill` `press` `select` `upload` `scroll` `wait` `waitIdle` `frame` `follow` `emit` · new thing: `copy` `move` `download` · nothing: `delete` |
| **Transform** | returns a new value; the receiver is unchanged | `resize` `crop` `without` |
| **Predicate** | returns a `bool` | `exists` `pressed` `button` |
| **Lifecycle** | releases a resource; idempotent | `close` |

## 7. The API, module by module

### 7.1 html

```dart
abstract final class Html {
  static Elements parse(String html, {String? baseUrl});
}
extension on Reader { Future<Elements> html(); }
extension on Future<Reader> { Future<Elements> html(); }

final class Elements extends Iterable<Element> {
  Elements $(String selector);
  Element operator [](int index);
  Elements without(String selector);
  String text();
  String? attr(String name);
  List<String> attrs(String name);
}
final class Element {
  Elements $(String selector);
  Element without(String selector);
  String text();
  String? attr(String name);
  Element? parent();
}

extension on Future<Elements> {
  Future<Elements> $(String selector);
  Future<Element> operator [](int index);
  Future<Elements> without(String selector);
  Future<String> text();
  Future<String?> attr(String name);
  Future<List<String>> attrs(String name);
}
extension on Future<Element> {
  Future<Elements> $(String selector);
  Future<Element> without(String selector);
  Future<String> text();
  Future<String?> attr(String name);
  Future<Element?> parent();
}
```

- **`parse`** reads the input as a fragment and never throws on malformed markup. Top-level
  elements have no parent.
- **`baseUrl`** is the base for relative links. `reader.html()` passes the response's final URL
  (or the file's URI). With a base, `attr('href')` and `attr('src')` return absolute URLs.
- **`$`:** `Elements.$` returns every match that is one of these elements or a descendant of one,
  in document order and without duplicates. `Element.$` is the same query run on that one element.
- **`without(selector)`** returns a new tree without every match and its subtree. The receiver is
  unchanged, as values are immutable. It copies the tree once (O(size)), so a whole-page
  `without('script, style, noscript')` is cheap next to parsing. In the new tree, `parent()` and `$`
  see only the new tree.
- **`text()`** is the concatenated text of every descendant, untrimmed. On `Elements` it is every
  element's text joined, so `doc.$('title').text()` reads the first title without `[0]`.
- **`attr(name)`** is case-insensitive and `null` when absent. On `Elements` it is the first
  match's attribute, so `doc.$('meta[property="og:image"]').attr('content')` is `null` rather than a
  `RangeError` when nothing matched. **`attrs(name)`** is every match's value in document order,
  with absent ones skipped and links made absolute against the base, so `doc.$('a.item').attrs('href')`
  is the list of links to follow. **`parent()`** is `null` at the top level.
- The CSS selector syntax is the engine's. A selector the engine rejects is a `FormatException`
  naming the selector.

```dart
final doc = await Http.get('https://example.com/article').html();
final body = doc.without('script, style, nav, .ads').$('article').text();
for (final row in doc.$('table.items tr')) {
  final cells = row.$('td');
  if (cells.isEmpty) continue;
  print('${cells[0].text().trim()} → ${cells[1].$('a')[0].attr('href')}');
}
final next = await Http.get(url).html().$('a.next').attr('href');
final links = await Http.get(url).html().$('a.item').attrs('href');
```

### 7.2 http

```dart
abstract final class Http {
  static Future<Response> get(String url, {Map<String, String>? headers, Duration? timeout});
  static Future<Response> head(String url, {Map<String, String>? headers, Duration? timeout});
  static Future<Response> delete(String url, {Map<String, String>? headers, Duration? timeout});
  static Future<Response> options(String url, {Map<String, String>? headers, Duration? timeout});
  static Future<Response> post(String url, {Object? body, Map<String, String>? headers, Duration? timeout});
  static Future<Response> put(String url, {Object? body, Map<String, String>? headers, Duration? timeout});
  static Future<Response> patch(String url, {Object? body, Map<String, String>? headers, Duration? timeout});
}
final class Response with Reader implements Closeable {
  int status();
  String? header(String name);
  String url();
  // Reader: stream bytes text pipe | to >, html json image  ·  Closeable: close
}
extension on Future<Response> {
  Future<int> status();
  Future<String?> header(String name);
  Future<String> url();
}
```

- **A verb completes when the headers arrive.** `status()`, `header()` and `url()` are sync from
  then on, and the body streams as a `Reader`. Redirects are followed, and `url()` is the final
  URL.
- **A non-2xx status is still a `Response`;** only network failures and timeouts throw.
- **`timeout`** (30 s by default) bounds the wait for the headers, and then any stall while the
  body streams. Running out is a `TimeoutException` naming the URL. A slow but moving download
  never times out.
- **`body`** is a `String` (sent as UTF-8), a `List<int>` (sent as is) or a `Reader` (streamed,
  chunked unless a `content-length` header is given). `content-type` is the caller's header.
- **The body is one-shot.** `text()` and `bytes()` read it into memory and cache it, so calling
  either again is free. Piping it (`res > file`) streams it without caching, and reading it again
  afterwards is a `StateError`.
- **`text()` decodes with the charset in `content-type`,** or UTF-8 when the header doesn't name
  one. Malformed bytes are replaced. `header(name)` is case-insensitive and `null` when absent.
- **The connection is released when the body has been read or piped to the end.** `close()`
  drops a body nobody will read, so the socket doesn't keep the script alive. It is idempotent and
  a no-op after the body is consumed, and reading after `close()` is a `StateError`.
- **There is a fresh client per request and no shared state.** Connection pooling is an
  engine-level swap that never touches the surface.

```dart
final user = await Http.get('https://api.example.com/me', headers: {'authorization': token}).json();
final res = await Http.post('https://api.example.com/items', body: Json.encode({'name': 'a'}),
    headers: {'content-type': 'application/json'});
if (res.status() != 201) throw StateError('create failed: ${res.status()} ${await res.text()}');

final page = await Http.get(url);
if (page.status() == 404) return page.close();
await (page > Fs.file('page.html'));
await Http.put('https://cdn.example.com/disc.iso', body: Fs.file('disc.iso'));   // streamed upload
```

### 7.3 chrome

```dart
abstract final class Chrome {
  static Future<Browser> launch({bool headless = true, String? executable, String? profile, String? proxy});
  static Future<Browser> connect(String url);
}

final class Browser implements Closeable {
  Future<Page> open(String url,
      {Map<String, String>? headers, List<String>? block, int? width, int? height});
  Future<List<Page>> pages();
  // Closeable: close
}

final class Page implements Closeable {
  // navigation: waits for the load event, returns this page
  Future<Page> goto(String url);
  Future<Page> back();
  Future<Page> reload();

  // reading
  Future<String> url();
  Future<Elements> html();
  Future<String> text();
  Future<T?> eval<T>(String js);
  Future<String?> cookieHeader();

  // driving: waits for the selector to be actionable (up to timeout), returns this page
  Future<Page> click(String selector, {Duration? timeout});
  Future<Page> fill(String selector, String value, {Duration? timeout});
  Future<Page> press(String key);
  Future<Page> select(String selector, String value, {Duration? timeout});
  Future<Page> upload(String selector, Reader file, {Duration? timeout});
  Future<Page> scroll([String? selector]);

  // waiting: returns this page
  Future<Page> wait(String selector, {Duration? timeout});
  Future<Page> waitIdle({Duration? timeout});

  // content out: Readers, captured when read
  Reader screenshot({bool fullPage = false});
  Reader pdf();
  Future<Download> download(String selector, {Duration? timeout});

  // Closeable: close
}

final class Download with Reader {
  String name();                                    // the file name the site suggested
}

extension on Future<Browser> {
  Future<Page> open(String url,
      {Map<String, String>? headers, List<String>? block, int? width, int? height});
  Future<List<Page>> pages();
}
extension on Future<Page> {
  Future<Page> goto(String url);
  Future<Page> back();
  Future<Page> reload();
  Future<String> url();
  Future<Elements> html();
  Future<String> text();
  Future<T?> eval<T>(String js);
  Future<String?> cookieHeader();
  Future<Page> click(String selector, {Duration? timeout});
  Future<Page> fill(String selector, String value, {Duration? timeout});
  Future<Page> press(String key);
  Future<Page> select(String selector, String value, {Duration? timeout});
  Future<Page> upload(String selector, Reader file, {Duration? timeout});
  Future<Page> scroll([String? selector]);
  Future<Page> wait(String selector, {Duration? timeout});
  Future<Page> waitIdle({Duration? timeout});
  Reader screenshot({bool fullPage = false});
  Reader pdf();
  Future<Download> download(String selector, {Duration? timeout});
}
extension on Future<Download> {
  Future<String> name();
}
```

**Twenty members on `Page`, grouped by what a script does: go somewhere, read, drive, wait,
take content out.** Setup that used to be methods is now options on `open`, and dialogs are
dismissed by default.

- **`launch`** downloads Chromium into the user cache on first use, unless `executable` names a
  Chrome or Chromium binary.
  - `profile` is a folder that keeps cookies and logins between runs. Without it, every launch
    starts fresh in a temp profile that is deleted on `close`.
  - `proxy` routes every request (`http://host:port`, `socks5://host:port`).
  - Throws when the browser can't start.
- **`connect(url)`** attaches to a running browser (`http://localhost:9222` or a `ws://` URL).
  Its `close()` disconnects and leaves that browser running.
- **`open(url)`** opens a new tab and waits for the load event. The tab's setup goes here, before
  the first request:
  - `headers` are extra request headers for everything the tab loads, `user-agent` included.
  - `block` aborts requests by resource type (`'image'`, `'font'`, `'media'`, `'stylesheet'`),
    for faster scraping.
  - `width`/`height` set the viewport.

  `alert`/`confirm`/`prompt` dialogs are always dismissed, so a script never hangs on one.
- **`pages()`** is every open tab, popups included. **`close()`** on a `Browser` closes every tab
  and the process it launched; on a `Page`, the tab.
- **Navigation** (`goto`, `back`, `reload`) waits for the load event.
- **Reading:**
  - `html()` is the rendered DOM as `Elements`, with the page's URL as the base. Chain into it:
    `page.html().$('a')`.
  - `text()` is the page's `innerText`.
  - `eval<T>(js)` evaluates an expression, awaits it if it is a promise, and JSON-decodes the
    result. Like `Json.value<T>()`, it returns `null` for `null`, `undefined`, or a result that is
    not a `T`, so `??` gives the default.
  - `cookieHeader()` is the `Cookie` header value for the current URL, ready for `Http`:
    `Http.get(u, headers: {'cookie': ?await page.cookieHeader()})`.
- **Driving acts on the first match of `selector`.** Each call waits until the element is
  attached, visible and enabled, and gives up after `timeout` (30 s) with a `TimeoutException`
  naming the selector.
  - `fill` focuses the field, replaces its value keystroke by keystroke, and fires `input` and
    `change`, so sites that listen to keys and sites that read the value both work.
  - `press(key)` sends a key or a chord, with the same key names as the TUI (§5): `'enter'`,
    `'tab'`, `'down'`, `'ctrl+a'`.
  - `select` picks the `<option>` by its value.
  - `upload` sets a file input from a `Reader`. A `File` keeps its name; any other reader is
    staged under the name `upload`.
  - `scroll()` goes to the bottom of the page, which is what infinite lists need.
    `scroll(selector)` brings an element into view.
- **Waiting:** `wait(selector)` waits until the element is visible. `waitIdle()` waits until there
  has been no network traffic for 500 ms. A plain pause is `Future.delayed`.
- **Content out:** each is a `Reader` (rule 8).
  - `screenshot()` is a PNG of the viewport, or of the whole page with `fullPage`.
  - `pdf()` is the page printed.
  - Both are captured when read, so `page.screenshot()` costs nothing until it is piped.
  - `download(selector)` clicks the element and waits for the download it starts to finish. It
    returns a `Download`: a `Reader` of the file plus `name()`, the name the site suggested. The
    browser's copy is removed when the browser closes.
- **Engine:** `package:puppeteer`. Its `Page`, `ElementHandle` and `Browser` never leak. `eval`
  and `html()` are the only bridges from the browser's world into Dart values.

```dart
final browser = await Chrome.launch(profile: '.chrome');
final page = await browser.open('https://example.com/login', block: ['image', 'font'])
    .fill('#user', name).fill('#pass', password).click('button[type=submit]').wait('.dashboard');

final rows = await page.goto('https://example.com/orders').html().$('tr.order');
final invoice = await page.download('a.invoice');
await (invoice > Fs.dir('invoices').file(invoice.name()));
await (page.screenshot(fullPage: true) > Fs.file('orders.png'));
final api = await Http.get('https://example.com/api/orders',
    headers: {'cookie': ?await page.cookieHeader()}).json();
await browser.close();
```

### 7.4 json

```dart
final class Json extends Iterable<Json> {
  static Json parse(String json);
  static String encode(Object? value, {bool pretty = false});
  Json $(String path);
  Json operator [](int index);
  T? value<T>();
}
extension on Reader { Future<Json> json(); }
extension on Future<Reader> { Future<Json> json(); }
extension on Future<Json> {
  Future<Json> $(String path);
  Future<Json> operator [](int index);
  Future<T?> value<T>();
}
```

- `parse` and `json()` throw a `FormatException` on invalid JSON. `encode` accepts what
  `dart:convert` does, and `pretty` indents by two spaces.
- `$(path)` takes dot-separated segments; a numeric segment indexes an array (`users.0.name`). A
  missing path gives a `Json` holding `null`, never a throw. Keys that contain a dot are out of
  reach by design.
- A `Json` iterates an array's items or an object's values; a scalar or `null` iterates nothing.
  `[i]` indexes the iteration.
- `value<T>()` returns the value when it is a `T`, and `null` otherwise, so `??` gives the
  default. Use `num` for numbers that may be integers, and `Object` for the raw value.

```dart
final port = await Fs.file('conf.json').json().$('server.port').value<int>() ?? 8080;
final names = [for (final u in await Http.get(api).json().$('data.users')) u.$('name').value<String>() ?? '?'];
await Fs.file('names.json').write(Json.encode(names, pretty: true));
```

### 7.5 fs

```dart
abstract final class Fs {
  static Future<Entry?> entry(String path);     // what is on disk now: File, Dir, Link, or null
  static File file(String path);              // handles: no I/O, the target need not exist
  static Dir dir(String path);
  static Link link(String path);
}

sealed class Entry {
  String path();
  String name();
  Dir parent();
  Future<bool> exists();
  Future<void> delete();
  Future<Entry> copy(String to);               // each subtype narrows these to its own type
  Future<Entry> move(String to);
}

final class File extends Entry with Reader implements Writer {
  Future<File> write(Object data);
  Future<File> append(Object data);
  Future<int> size();
  @override Future<File> copy(String to);
  @override Future<File> move(String to);
  // Reader: stream bytes text pipe | to >, html json image  ·  Writer: consume
}

final class Dir extends Entry {
  File file(String name);
  Dir dir(String name);
  Future<List<Entry>> list({bool recursive = false});
  Future<Dir> create();
  @override Future<Dir> copy(String to);
  @override Future<Dir> move(String to);
}

final class Link extends Entry {
  Future<String> target();
  Future<Entry?> resolve();
  Future<Link> create(String target);
  @override Future<Link> copy(String to);
  @override Future<Link> move(String to);
}
```

The mirrors repeat every member, and the sync ones come back as `Future`s:

```dart
extension on Future<File> {
  Future<String> path();
  Future<String> name();
  Future<Dir> parent();
  Future<bool> exists();
  Future<void> delete();
  Future<File> copy(String to);
  Future<File> move(String to);
  Future<File> write(Object data);
  Future<File> append(Object data);
  Future<int> size();
}
extension on Future<Dir> {
  Future<String> path();
  Future<String> name();
  Future<Dir> parent();
  Future<bool> exists();
  Future<void> delete();
  Future<Dir> copy(String to);
  Future<Dir> move(String to);
  Future<File> file(String name);
  Future<Dir> dir(String name);
  Future<List<Entry>> list({bool recursive = false});
  Future<Dir> create();
}
extension on Future<Link> {
  Future<String> path();
  Future<String> name();
  Future<Dir> parent();
  Future<bool> exists();
  Future<void> delete();
  Future<Link> copy(String to);
  Future<Link> move(String to);
  Future<String> target();
  Future<Entry?> resolve();
  Future<Link> create(String target);
}
```

- **`Fs.entry` inspects without following links,** so a symlink is always a `Link`. Nothing at
  the path gives `null`. A `switch` over its result is exhaustive. `Fs.entry`/`file`/`dir`/`link`
  are named for the type they return.
- **Handles do no I/O.** `Fs.file('out/a.txt')` is valid before the file exists, and
  `Fs.dir('a').dir('b').file('c.txt')` builds a path. Two handles with the same `path()` are `==`.
- **`Entry`:**
  - `path()` is the string as given, without trailing separators.
  - `name()` is the last segment. `parent()` is the containing folder, and the root's parent is
    the root.
  - `exists()` is true only when something of this handle's kind is there: a `File` handle on a
    folder answers `false`.
  - `delete()` removes a file, a link (never its target) or a whole folder, and is a no-op when
    nothing is there.
  - `copy(to)` and `move(to)` are filesystem operations: they keep permissions and timestamps,
    return a handle of the same type at `to`, and create missing parent folders. `move` renames,
    and falls back to copy-then-delete across devices, so `to` is complete before the source goes.
    A `Dir` copy is recursive and copies links as links. To transform on the way, pipe instead:
    `file | Archive.gzip() > Fs.file('a.gz')`.
- **`File`:**
  - As a `Reader`, it streams in 64 KiB chunks, and `text()` decodes UTF-8. A missing file throws
    a `PathNotFoundException` when it is read.
  - As a `Writer` (`… > file`), it streams into a temp sibling and renames it over the target when
    the stream ends. A failed run leaves the old content and no temp file. Missing parent folders
    are created.
  - `write(data)` does the same for in-memory data. `append(data)` adds to the end and also
    creates missing parent folders. `size()` is in bytes.
- **`Dir`:**
  - `list()` returns typed children (`File`, `Dir`, `Link`) sorted by name. With
    `recursive: true` it descends into subfolders, but never through links.
  - `create()` is `mkdir -p` and a no-op when the folder exists.
- **`Link`:**
  - `target()` is the stored target string. `resolve()` follows the chain to what is finally
    there, or `null` when the link is broken.
  - `create(target)` makes the link and replaces an existing one atomically.
- **Name clash:** a script that also needs `dart:io` imports it with
  `hide File, Directory, Link`.

```dart
switch (await Fs.entry(args.first)) {
  case File file: print('file, ${await file.size()} bytes');
  case Dir dir: print('folder of ${(await dir.list()).length}');
  case Link link: print('link → ${await link.target()}');
  case null: print('nothing there');
}
final backup = await Fs.file('notes.md').copy('backup/notes.md');
final size = await Fs.file('log.txt').append('done\n').size();
for (final p in await Fs.dir('src').list(recursive: true)) {
  if (p case File f when f.name().endsWith('.md')) await (f > Fs.dir('build').file(f.name()));
}
```

### 7.6 shell

```dart
abstract final class Shell {
  static Future<Output> run(List<String> command, {String? workingDir, Map<String, String>? env});
  static Pipe filter(List<String> command, {String? workingDir, Map<String, String>? env});
}
final class Output with Reader {
  int exitCode();
  String errorText();
  // Reader (stdout): stream bytes text pipe | to >, html json image
}
extension on Future<Output> {
  Future<int> exitCode();
  Future<String> errorText();
}
```

- **`command[0]` is the program,** looked up on `PATH`, and the rest are its arguments. It runs
  directly, with no shell, so interpolated arguments are safe. For pipes and globs inside one
  command, run `['sh', '-c', '…']` (or `['cmd', '/c', '…']` on Windows).
- `workingDir` is the folder the program runs in, and `env` is merged over the current
  environment.
- **`run`** closes stdin, waits for the exit, and returns an `Output`.
  - The `Output` is a `Reader` of stdout, so `text()`, `json()` and `> file` all work:
    `await Shell.run(['gh', 'api', 'user']).json()`.
  - `errorText()` is stderr, decoded as UTF-8. `exitCode()` is the exit code.
  - `text()` is verbatim, so call `.trim()` for one-liners.
  - A program that can't start throws a `ProcessException`. A non-zero exit is an `Output`.
- **`filter`** is a process as a `Pipe`: the stream goes to its stdin, and its stdout comes out.
  - `Http.get(u) | Shell.filter(['jq', '.items']) > Fs.file('items.json')`.
  - stderr is collected, and a non-zero exit fails the run with a `ProcessException` that carries
    the code and stderr. A pipe has no value to return, so failure is the only way to report it.
  - Closing the run kills the process.

```dart
final head = (await Shell.run(['git', 'rev-parse', 'HEAD']).text()).trim();
if (await Shell.run(['git', 'diff', '--quiet']).exitCode() != 0) print('dirty tree');
await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
```

### 7.7 archive

```dart
enum ArchiveFormat { zip, tar, tgz }

abstract final class Archive {
  static Reader pack(String dir, ArchiveFormat format);
  static Writer unpack(String dir);
  static Pipe gzip();
  static Pipe gunzip();
}
```

- **`pack(dir, format)`** is a `Reader` of the archive. It stores the contents of `dir` (not
  `dir` itself), with paths relative to it, and is built when read:
  `await (Archive.pack('site', .zip) > Fs.file('site.zip'))`.
- **`unpack(dir)`** is a `Writer` that extracts what it is given into `dir`, creating it.
  - The format comes from the magic bytes (zip, tar, gzip-compressed tar), so
    `Http.get(u) > Archive.unpack('vendor')` needs no hint.
  - Every member is checked before anything is written. Absolute paths, `..` escapes and links
    are refused with a `FormatException` naming the member, and a corrupt archive is also a
    `FormatException`.
  - Extraction goes into a temp sibling folder that is renamed into place, so a failed run leaves
    no half-unpacked tree.
- **`gzip()` and `gunzip()`** are streaming pipes on `dart:io`'s codec:
  `await (Http.get(u) | Archive.gunzip() > Fs.file('dump.sql'))`. Bad gzip data fails the run with
  a `FormatException`.
- The `pack`/`unpack` engine holds an archive in memory, which is good enough for downloads and
  backups. Streaming members is a later engine swap, not a surface change.

### 7.8 hash: incremental, one-shot, or in a pipe

```dart
abstract final class Hash {
  static Hasher md5();
  static Hasher sha1();
  static Hasher sha256();
  static Hasher sha512();
}
final class Hasher implements Writer, Pipe {
  Hasher add(Object data);
  String hex();
}
```

- **Incremental.** Each `add(data)` feeds more, as a `String` (UTF-8) or a `List<int>`, at
  constant memory, and returns the hasher. `hex()` finishes the hash. Calling it again returns the
  same digest, and an `add` after it is a `StateError`.
- **One-shot** is the same chain: `Hash.sha256().add('hello').hex()`.
- **As a `Writer`** (`reader > hash`), it digests the whole stream. Read `hex()` once the run
  completes.
- **As a `Pipe`** (`reader | hash > file`), it digests what passes and forwards every chunk
  unchanged. That is how one pass both saves a download and checksums it.
- A finished hasher can't take another pipeline: that is a `StateError`.
- **Engine:** `package:crypto`'s chunked conversion, which never buffers the input.

```dart
final h = Hash.sha256();
for (final part in parts) h.add(part);
final id = Hash.md5().add(url).hex();

final check = Hash.sha256();
await (Http.get(isoUrl) | check > Fs.file('disc.iso'));
if (check.hex() != expected) await Fs.file('disc.iso').delete();
```

### 7.9 pool

```dart
abstract final class Pool {
  static Future<R> run<R>(FutureOr<R> Function() job);
  static Future<List<R>> map<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, void Function(R result)? onResult});
  static Future<void> close();
}
```

- **One process-wide pool of worker isolates.** Workers start lazily on the first call (one per
  core) and are reused across calls, so a job costs one message round trip, not an isolate spawn.
- **`run(job)`** runs one job on a worker and returns its result. An error in the job is rethrown
  with its stack trace.
- **`map(items, job)`** runs `job` over every item on the workers and returns the results in input
  order.
  - `limit` caps the jobs in flight; it defaults to the number of workers.
  - `onResult` runs on the caller's isolate as each job finishes. That is where progress goes,
    since a job runs on another isolate.
  - The first error stops new jobs from starting, waits for the ones in flight, and is rethrown.
- **Jobs cross isolates.** A job is a top-level or static function, or a closure that captures
  only sendable values (strings, numbers, lists, records, fs handles). A job that captures a `Bar`,
  a socket or a `Page` is an `ArgumentError` at the call.
- **`close()`** stops the workers. It is static, because the pool is process-wide, so `Pool` is not
  a `Closeable`. Idle workers never keep a script alive, and the pool restarts on the next call.
- **Engine: `package:worker_manager`,** which runs closures on reused isolates with no codegen.
  `squadron` was rejected because its workers are generated by `squadron_builder` (rule 16).
  `worker_manager` is now a community fork, so the facade keeps it swappable for an in-house pool
  on `Isolate.spawn` with `SendPort`s.

```dart
final bar = Console.bar(urls.length, label: 'Pages');
await Pool.map(urls, fetch, onResult: (_) => bar.tick());
await bar.close();

/// A top-level job: plain values in and out.
Future<void> fetch(String url) => Http.get(url) > Fs.dir('pages').file(Hash.md5().add(url).hex());
```

### 7.10 cli: argument parsing

```dart
abstract final class Cli {
  static Args parse(List<String> args);
}
final class Args {
  bool flag(String name, {String? short, String? help});
  String? option(String name, {String? short, String? help});
  List<String> multi(String name, {String? short, String? help});
  List<String> rest();
  String usage();
}
```

- **You declare by reading.** Each `flag`/`option`/`multi` call takes its tokens out of the
  argument list and records itself for `usage()`. There is no separate spec, so the declaration
  *is* the read. Calling the same name again returns the same answer.
- **Syntax.**
  - Flags: `--verbose` and `-v`, and grouped short flags such as `-vq`.
  - Options: `--out x`, `--out=x` and `-o x`. The next token is always the value, even when it
    starts with `-`.
  - `--` ends option parsing.
- **Values.**
  - `flag` is `true` when present.
  - `option` is the last value given, or `null`, so `??` gives the default.
  - `multi` collects every value of a repeatable option, in order.
- **`rest()`** ends the declarations and returns the positional arguments. Any leftover `-x` or
  `--x` is a `FormatException` naming the token. Declaring after `rest()` is a `StateError`. An
  option with no value is a `FormatException` (`--out needs a value`).
- **Subcommands are Dart patterns.** `switch (args.rest())` with list patterns replaces a
  subcommand API.
- **`usage()`** lists the declarations in call order, one aligned line each:
  `-o, --out <value>   Output folder.`
- **Engine: in-house,** about 150 lines; `package:args` would need its parser built before
  parsing, which breaks declare-by-reading.

```dart
Future<void> main(List<String> argv) async {
  final args = Cli.parse(argv);
  final verbose = args.flag('verbose', short: 'v', help: 'Print every request.');
  final out = args.option('out', short: 'o', help: 'Output folder.') ?? 'out';
  final headers = args.multi('header', short: 'H', help: 'Extra header, repeatable.');
  if (args.flag('help', short: 'h', help: 'Show this help.')) {
    print('usage: fetch [options] get <url> | list\n${args.usage()}');
    return;
  }
  switch (args.rest()) {
    case ['get', final url]: await fetch(url, out, headers, verbose);
    case ['list']: await list(out);
    default:
      print(args.usage());
      exitCode = 64;
  }
}
```

### 7.11 console: prompts and progress

```dart
abstract final class Console {
  static Future<String> ask(String question, {bool secret = false});
  static Future<bool> confirm(String question);
  static Future<String> choose(String question, List<String> choices);
  static Future<T> spin<T>(String label, Future<T> Function() work);
  static Bar bar(int total, {String? label});
}
final class Bar implements Pipe, Closeable {
  Bar tick([int count = 1]);
  // Pipe: transform  ·  Closeable: close
}
```

- **Everything writes to stderr,** so `app | jq` sees only the data a script prints to stdout.
- `ask` reads one line. `secret` turns off echo for passwords.
- `confirm` accepts `y`/`yes`/`n`/`no` in any case, and Enter means no. It asks again on anything
  else.
- `choose` uses the arrow keys and Enter on a terminal. Piped, it prints a numbered list and reads
  a number. An empty `choices` list is an `ArgumentError`.
- A closed stdin throws a `StdinException`.
- `spin` animates `⠋ label` until `work` completes, then prints `✓ label` and returns the result,
  or prints `✗ label` and rethrows.
- `bar` draws `label  ███████░░░░░  12/40  1.2 MB/s` and redraws at most every 80 ms.
  - `tick(count)` adds `count` (1 by default), stopping at `total`, and returns the bar.
  - A `total` of 0 means unknown, and the bar shows a running count and its rate.
  - `close()` prints the final line. Call it in `finally`.
- **As a `Pipe`,** a bar counts the bytes that pass, and closes itself when the stream ends or
  fails. A pipe sees only the stream, so the total is the caller's:
  `res | Console.bar(int.parse(res.header('content-length') ?? '0')) > file`, or
  `Console.bar(await file.size())`.
- Only one live line (a spinner or a bar) exists at a time. Starting a second while one is live is
  a `StateError`.
- When stderr is not a terminal, or `NO_COLOR` is set, there is no animation. Each spinner and bar
  prints its final line once.

```dart
if (!await Console.confirm('Delete ${files.length} files?')) return;
final token = await Console.ask('Token:', secret: true);
final me = await Console.spin('Signing in', () => Http.get(api, headers: {'authorization': token}).json());
```

### 7.12 tui: immediate-mode terminal apps

```dart
abstract final class Tui {
  static Future<void> run(Future<void> Function(Screen screen) app);
}
final class Screen {
  Future<Screen> frame(void Function(Region region) build);
  bool pressed(String key);
  String typed();
  int width();
  int height();
}
final class Region {
  Region write(String text, {int? color, bool bold = false});
  Region box(String title);
  List<Region> rows(List<int> sizes);
  List<Region> cols(List<int> sizes);
  bool button(String label);
}
extension on Future<Screen> {
  Future<Screen> frame(void Function(Region region) build);
  Future<bool> pressed(String key);
  Future<String> typed();
  Future<int> width();
  Future<int> height();
}
```

The API is ours. The engine applies techniques studied in dascade:

- immediate mode, with the app's state kept in its own variables;
- input polled as per-frame state rather than delivered as events;
- a double-buffered cell grid, diffed so only changed cells are written;
- a full resync on resize.

- **`Tui.run`** enters raw mode, the alternate screen and mouse reporting, and always restores the
  terminal when `app` returns or throws. It throws a `StdoutException` when stdout is not a
  terminal.
- **`frame(build)`** is one tick:
  1. waits for the next frame slot (about 60 fps), which throttles the loop for you;
  2. collects the input that arrived since the last frame;
  3. runs `build` on a `Region` covering the whole screen;
  4. diffs against the last frame and writes only the changed cells.
- **Input is state.**
  - `pressed(key)` is true when that key was pressed since the last frame. Key names are shared
    with `Page.press` (§5): `'a'`, `'A'`, `'enter'`, `'tab'`, `'backspace'`, `'escape'`, `'up'`,
    `'down'`, `'left'`, `'right'`, `'home'`, `'end'`, `'pageup'`, `'pagedown'`, `'delete'`,
    `'f1'`…`'f12'`, `'ctrl+c'`, `'alt+x'`.
  - `typed()` is the printable text typed since the last frame, for text fields kept in your own
    `String`.
  - `^C` is just `pressed('ctrl+c')`: the app decides whether it quits.
- **`Region`** is a rectangle with a cursor at its top-left.
  - `write(text)` draws at the cursor, moves the cursor to the next line, clips at the edge and
    returns the region, so `r.write('a').write('b')` stacks lines. Wide characters count two cells.
    `color` is a 256-colour index.
  - `box(title)` draws a border with the title and returns the inner region.
  - `rows(sizes)` and `cols(sizes)` split what is below the cursor. A size above 0 is fixed cells,
    and 0 shares what is left equally. Destructure the result: `final [head, body] = r.rows([3, 0]);`
  - `button(label)` draws a button at the cursor and returns true in the frame it is clicked, or
    when it has focus and Enter is pressed. Tab moves focus between buttons in drawing order.
- **Engine: in-house** on `dart:io` (ANSI output, raw stdin, `SIGWINCH`), about 600 lines.

```dart
await Tui.run((screen) async {
  var count = 0;
  var name = '';
  while (!screen.pressed('escape')) {
    if (screen.pressed('backspace') && name.isNotEmpty) name = name.substring(0, name.length - 1);
    name += screen.typed();
    await screen.frame((r) {
      final [head, body, foot] = r.rows([3, 0, 3]);
      head.box('Counter').write('count = $count', bold: true);
      body.box('Name').write(name.isEmpty ? 'type something…' : name, color: name.isEmpty ? 244 : null)
          .write('${name.length} characters', color: 244);
      final [plus, reset] = foot.cols([0, 0]);
      if (plus.button('+1')) count++;
      if (reset.button('Reset')) count = 0;
    });
  }
});
```

### 7.13 image

```dart
enum ImageFormat { png, jpg, gif, bmp, tiff, ico }

final class Image {
  static Image decode(List<int> bytes);
  int width();
  int height();
  Image resize({int? width, int? height});
  Image crop(int x, int y, int width, int height);
  Reader encode(ImageFormat format, {int quality = 90});
}
extension on Reader { Future<Image> image(); }
extension on Future<Reader> { Future<Image> image(); }
extension on Future<Image> {
  Future<int> width();
  Future<int> height();
  Future<Image> resize({int? width, int? height});
  Future<Image> crop(int x, int y, int width, int height);
  Reader encode(ImageFormat format, {int quality = 90});
}
```

- `decode` and `image()` detect PNG, JPEG, GIF (the first frame), BMP, WebP, TIFF and ICO. They
  apply the EXIF orientation, so `width()` and `height()` are the size as displayed. An unknown
  format is a `FormatException`.
- `resize` keeps the aspect ratio when only one side is given, sets the exact size when both are,
  and is an `ArgumentError` when neither is.
- `crop` cuts a region and is a `RangeError` when that region leaves the image.
- `encode(format)` is a `Reader` of the encoded image (rule 8), encoded when read. Store it with
  `> Fs.file(…)`, hash it, or upload it with `body:`. `quality` applies to JPEG. WebP can be
  decoded but not encoded by the engine, so it is not an `ImageFormat`.
- The engine is pure Dart and CPU-bound, so batches go through `Pool.map`.

```dart
final avatar = await Http.get(avatarUrl).image().crop(0, 0, 256, 256);
await (avatar.encode(.png) > Fs.file('avatar.png'));
await (avatar.resize(width: 64).encode(.png) > Fs.file('icon.png'));
await Pool.map(await Fs.dir('photos').list(), (p) async {
  if (p is File) await (p.image().resize(width: 800).encode(.jpg, quality: 80) > Fs.file('thumbs/${p.name()}'));
});
```

### 7.14 scrape: crawling

```dart
abstract final class Scrape {
  static Stream<T> run<T>(Iterable<String> urls, Future<void> Function(Visit<T> visit) handler, {
    int limit = 4,
    Duration? delay,
    int retries = 2,
    String? cache,
    Map<String, String>? headers,
    Duration? timeout,
    Browser? browser,
    void Function(String url, Object error)? onError,
  });
}

final class Visit<T> with Reader {
  String url();
  int status();
  Visit<T> follow(Iterable<String> urls, Future<void> Function(Visit<T> visit) handler);
  Visit<T> emit(T item);
  // Reader: stream bytes text pipe | to >, html json image
}
```

`Http.get(u).html()` already scrapes one page. This module is the crawl around it, and nothing
more:

- a queue, with every URL visited once;
- a concurrency limit and a polite gap per host;
- retries;
- a cache, so a rerun resumes;
- typed records out.

- **`run(urls, handler)`** visits the start URLs with `handler` and returns a `Stream<T>` of every
  emitted record. The stream completes when the queue is empty and every handler has returned.
  Cancelling the subscription stops the crawl: nothing new starts, and visits in flight are
  dropped. `await Scrape.run(…).toList()` collects a small crawl; `await for` streams a big one.
- **Routing is by function.** `visit.follow(urls, handler)` queues `urls` to be handled by
  `handler`, so each kind of page is one function, and the type checker catches a wrong route.
- **Each URL is visited once.** URLs are made absolute and their fragment is dropped, and one
  already queued in this run is skipped, whichever handler queued it.
- **`emit(item)`** adds a record to the output stream. Records arrive in the order they are
  emitted, which is completion order when visits run in parallel.
- **A `Visit` is a `Reader` of the page's body,** so `html()` (with the final URL as the base),
  `json()`, `text()` and `> file` mean what they mean everywhere. Asset downloads are a handler
  like any other: `v.follow(imgs, (img) => img > Fs.file(…))`. `url()` is the final URL after
  redirects, and `status()` is the HTTP status.
- **Outcomes are values.** A 404 reaches its handler, and `v.status()` tells it apart.
- **Failures end the run** by default, rethrown from the stream: a request still failing after its
  retries, or a handler that throws. With `onError`, the failure is reported with its URL and the
  crawl goes on without that page.
- **Options:**

  | Option | Meaning |
  |---|---|
  | `limit` | visits in flight at once (4), the same meaning as `Pool.map(limit:)` |
  | `delay` | the minimum gap between two requests to one host; none by default |
  | `retries` | extra attempts on network errors, timeouts, 5xx and 429 (2), with doubling backoff from 1 s, or the server's `Retry-After` |
  | `cache` | a folder where each body is stored by URL; a later run reads from it instead of the network, so developing a scraper is fast and polite. Cache hits skip `delay`. Delete the folder to refresh. |
  | `headers` / `timeout` | as in `Http`, for every request of the crawl |
  | `browser` | visits open as tabs of this `Browser` (one tab per visit in flight), and `html()` is the rendered DOM. The handlers don't change. |
  | `onError` | report and continue instead of failing the run |

- **Engine:** `http`, `html` and `chrome` from this package, plus an in-house queue (about 200
  lines). `scrape` is the one module that composes others. Importing it compiles the browser
  client too; if an A/B shows that costs startup, the Chrome path moves behind a deferred import.

```dart
typedef Album = ({String title, String? image, String url});

Future<void> main() async {
  final albums = await Scrape.run<Album>(
    [for (var p = 1; p <= 3; p++) '${shop}m_mall_list.php?ps_page=$p'], listing,
    headers: {'accept-language': 'ko-KR'}, delay: Duration(milliseconds: 250), cache: '.cache/shop',
  ).toList();
  await Fs.file('albums.json').write(Json.encode([for (final a in albums) {'title': a.title, 'url': a.url}]));
}

Future<void> listing(Visit<Album> v) async {
  final doc = await v.html();
  v.follow(doc.$('a[href*="m_mall_detail"]').attrs('href'), album)
   .follow(doc.$('a.next').attrs('href'), listing);
}

Future<void> album(Visit<Album> v) async {
  final doc = await v.html();
  final image = doc.$('meta[property="og:image"]').attr('content');
  v.emit((title: doc.$('meta[property="og:title"]').attr('content') ?? doc.$('.goodsName').text(),
      image: image, url: v.url()));
  if (image != null) v.follow([image], (img) => img > Fs.dir('imgs').file(Fs.file(img.url()).name()));
}
```

## 8. Errors

| Thrown | When |
|---|---|
| `SocketException`, `HttpException`, `TlsException` (`IOException`s) | the network failed (an HTTP status never throws) |
| `FileSystemException`, `PathNotFoundException` | a disk operation failed, or a file to read is missing |
| `ProcessException` | a program can't start, or a `Shell.filter` process exits non-zero (a `Shell.run` exit code never throws) |
| `StdinException`, `StdoutException` | stdin is closed, or there is no terminal for the TUI |
| `TimeoutException` | a response's headers or a stalled body (naming the URL), or a browser wait or action (naming the selector), ran out of `timeout` |
| `FormatException` | invalid content: JSON, gzip data, an archive or one of its members, an image, a selector, a command line |
| `ArgumentError`, `RangeError`, `StateError` | the caller's mistake: a wrong data type, an index, a non-sendable job, a body read twice or after `close()`, an `add` after `hex()`, a declaration after `rest()` |

A crawl rethrows the first failure from its stream, unless `onError` takes it (§7.14).

There are no exception types of our own. A wrapped engine exception keeps the original as its
message's cause, and every message names its subject. An error inside a pipeline is rethrown from
its `>`/`to`, after the run has been cleaned up (§2). An error in a chain surfaces at its single
`await`.

## 9. Borrowed ideas

| Idea | From | Here |
|---|---|---|
| `\|` through and `>` into | Unix shells | `res \| hash > Fs.file('a')` |
| Tiny reader, writer and closer interfaces, and tees | Go `io.Reader`/`io.Writer`/`io.Closer`/`io.TeeReader` | `Reader.stream`, `Writer.consume`, `Closeable.close`; a `Hasher` pipe is a tee |
| Output as a stream, never a path argument | Go `png.Encode(w, img)`, Node streams | `page.pdf() > file`, `img.encode(.png) > file` |
| A hash as a writer you feed | Go `hash.Hash`, Python `hashlib.update` | `Hash.sha256().add(a).add(b).hex()` |
| A process as a filter | Unix pipes, zx | `Shell.filter(['jq', '.'])` |
| Fluent chains across awaits | Playwright and Puppeteer chaining, JS promise chains | `Future<T>` mirrors: `Chrome.launch().open(u).click(s).html()` |
| Auto-waiting actions, setup at open | Playwright (`newPage` options) | `page.click(s)` waits for `s`; `open(u, block:)` |
| `$(selector)` plus short reads; a copy without parts | jQuery, BeautifulSoup `decompose` | `doc.without('script').$('a')[0].attr('href')` |
| A status is a value, not an error | Python `requests` | `Response.status()` |
| A body that is a stream with readings | `fetch` (`res.body`, `res.json()`) | `Response` and `Output` are `Reader`s; `.json()` `.html()` `.image()` |
| A typed path that tells file, folder and link apart | Rust `std::fs::FileType`, Python `pathlib` | `switch (await Fs.entry(p))` over the sealed `Entry` |
| Atomic replace on write | the `rename(2)` idiom, Go `renameio` | `File` as a writer, `write`, `unpack` |
| A command as a list, no shell | Python `subprocess.run([...])` | `Shell.run(['git', 'status'])` |
| Dotted path into JSON, a missing path is null | Go gjson, JS `?.` | `json.$('a.b').value<int>() ?? 0` |
| A reused isolate pool running closures | `worker_manager`, Python `ProcessPoolExecutor.map` | `Pool.map(items, job)` |
| Declare a flag by reading it | Go `flag`, Python `argparse` (auto help) | `args.flag('verbose', short: 'v')` |
| Subcommands as pattern matching | Rust `match` | `switch (args.rest()) { case ['get', final url]: … }` |
| Immediate mode, input as state, a cell diff | dascade's engine, Dear ImGui, ratatui | `screen.frame`, `if (r.button('OK'))` |
| Resize with only one side given | Node `sharp` | `img.resize(width: 800)` |
| `follow` with a callback, retries, an HTTP cache | Scrapy (`response.follow`, `HTTPCACHE`) | `v.follow(links, album)`, `cache:` |
| One handler per kind of page, a deduplicated request queue | Crawlee | handlers routed by `follow` |
| A per-host delay and parallelism limit | Colly `Limit` | `delay:`, `limit:` |
| Records yielded as a stream | Python generators, Scrapy items | `v.emit(item)` → `Stream<T>` |

## 10. Performance: good enough, swappable

| Rule | How |
|---|---|
| Streams by default | Pipelines move 64 KiB chunks with the stream's backpressure. Downloading, hashing, gzipping, uploading and copying a 10 GB file all run at constant memory, in one pass. |
| Buffer only when asked | `text()`, `bytes()`, `html()`, `json()` and `image()` load into memory; they are for documents, not discs. |
| Lazy content | `screenshot()`, `pdf()`, `encode()` and `pack()` do their work only when read, so building a pipeline is free. |
| Chains cost nothing | A `Future` mirror is one `await` and one call. No mirror buffers or re-parses. |
| Engines first | A pub engine is used until an A/B measurement shows it is the bottleneck, then an in-house one replaces it behind the same private fields (§3). `html` (parser speed) is the likely first swap. |
| The facade costs O(1) | A call is the engine call plus one wrapper allocation, and a pipe stage is one stream transform. The exceptions are `Elements.$` (matches × depth: the engine's document query filtered by ancestry) and `without` (one tree copy), both cheap next to parsing. |
| A crawl is polite and resumable | `delay:` spaces requests per host, `limit:` bounds them, and `cache:` replays a rerun from disk, so iterating on a scraper costs no traffic. |
| The browser does less | `open(u, block: ['image', 'font'])` cuts most of a scrape's traffic. `html()` pulls the DOM in one call instead of one call per element. |
| CPU work leaves the main isolate | Image decoding and big parses go to `Pool`. Workers are reused, so a job is a message round trip, not an isolate spawn. |
| Bounded by default | `Pool.map` keeps at most `limit` jobs in flight, so memory stays flat on a 10 000-item job. |
| Measured back to back | A claim is the median of alternating A/B rounds from one sitting, never a standalone number. |
| Lean imports | A module compiles only core and its engine, and a script imports only what it uses. |
| Swaps that never touch the surface | connection pooling in `Http`, a faster HTML parser, streaming archives, an in-house worker pool |

## 11. Testing

- One test file per module (`test/<module>_test.dart`), plus `test/core_test.dart` for
  pipelines: ordering, backpressure, error cleanup, null stages, and a reader used twice.
- Each test file has a group per type, a test per listed member, and a test that each Future
  mirror matches its member.
- Real resources only: a loopback `HttpServer`, temp folders, a launched Chromium, a pseudo-terminal
  for `tui` and `console`, and real `git`/`sh`/`grep` for `shell`.
- Every fixed bug keeps a regression test that fails before the fix.
- A test never calls the engine, so swapping one is proven by the same suite passing.

## 12. Not in v2

- Native FFI libraries, prebuilt binaries, Rust, and code generation.
- Test fakes or seams in the public API, and exception types of our own.
- Sync twins, aliases, and deprecated names.
- Fan-out to several writers (use a pass-through `Pipe`), download resume, a streaming process
  handle beyond `Shell.filter`, file watching, and globbing.
- Browser request interception beyond `block`, frames, `hover`, and keystroke-only `type`.
- Terminal colours outside the TUI, retained TUI widgets, HMAC, and torrents.

Each of these comes back only when a real script needs it, and as the fewest members that do the
job.

## 13. Gap from the branch today

| Module | To do |
|---|---|
| core | new: `Reader`, `Writer`, `Pipe` with nullable stages, `Closeable`, the `Future<Reader>` and `Future<Closeable>` mirrors |
| html | `baseUrl:`, `Reader.html()`, `Element.$`, `without` on both types, `Elements.text()`/`attr()`/`attrs()`, the Future mirrors; a rejected selector rethrown as `FormatException` |
| http | `Response` becomes a streaming `Reader` and a `Closeable`: the verb completes at the headers, `text()` becomes async and charset-aware (UTF-8 when none is named), plus `url()`, `timeout:`, a data-or-`Reader` `body:` and the Future mirror |
| chrome | `connect`, `pages`, `executable:`/`profile:`/`proxy:`; tab setup moves to `open(headers:, block:, width:, height:)` and dialogs are dismissed by default (`dismiss()` goes); actions return `Future<Page>` and auto-wait; `wait(selector)` and `waitIdle()` replace `wait(Duration)`; `fill` replaces `type`; `screenshot()`/`pdf()` become `Reader`s; `download` returns a `Download`; `back` `reload` `url` `cookieHeader` `press` `select` `upload` `scroll`; `eval<T>`; the mirrors |
| json, fs, shell, archive, hash, pool, cli, console, tui, image, scrape | new, as above |
| pubspec | SDK `^3.10.0` (dot shorthands); add `path`, `archive`, `crypto`, `worker_manager`, `image` |
