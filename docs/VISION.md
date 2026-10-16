# dart_toolkit

**Write the script you would write in a shell, in Dart, with types.** dart_toolkit is sixteen
small modules (plus `core`) for command-line automation: fetch, drive a browser, move files, run
programs, archive, hash, prompt, and draw a terminal UI. Each module is a thin facade over its
engine (`dart:io`, a pinned native tool, or an in-house parser), and every module speaks the same five interfaces, so the bytes flow between them like a
pipe in a shell, and everything that takes time can be watched the same way.

```dart
final http = Http.client(retries: 3, check: true);
final title = await http.get('https://example.com').html().$('title').text();
final port = await Fs.file('conf.json').json().$('server.port').or(8080);
await (Fs.file('photo.jpg').image().resize(width: 800).encode(.jpg) > Fs.file('thumb.jpg'));

final hash = Hash.sha256();
await (http.get(isoUrl) & Console.bar('ubuntu.iso') | hash > Fs.file('ubuntu.iso'));   // the bar learns the size
await http.post(api, body: .json({'sha256': hash.hex()}));
await (Pool.map(urls, fetch) & Console.bar('pages'));                                // anything long: & a probe

final page = await Chrome.launch().open('https://example.com/report').click('#accept').idle();
await (page.pdf() > Fs.file('report.pdf'));
```

**Target:** scripts and small tools on macOS, Linux and Windows: scrapers, downloaders,
release scripts, file shufflers, terminal apps. These are not servers or Flutter apps. The bar for
the library is set by real scripts (`projects/`): every workaround a script needs is a gap in the
library.

**Four patterns are the whole style.** READ: `source.reading()` (`get(u).json()`). FLOW:
`reader | pipe & probe > writer`: `|` changes bytes, `&` watches, `>` stores. WATCH: `work &
probe` on a `Task` or any future. ACT: `receiver.action(…)` with named options. Every member
below is one of these.

**Priorities, in order:** correct → fast (startup and throughput) → short at the call site (fewer steps, not clipped names) → small
surface. A member stays only when a real script needs it, and an addition must delete more code
at its call sites than it adds to the surface.

## 1. Style

| #   | Rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **One entry class per module, named for it** (`Http`, `Fs`, `Tui`), `abstract final`, statics only, so typing `Http.` lists every way in. When the only value type shares the module's name (`Json`, `Image`), the statics go on that type.                                                                                                                                                                                                                                                 |
| 2   | **Values are `final class`es with private constructors and private fields.** Every read is a method (`status()`, `text()`), never a getter or a public field. The exceptions are the unit literals `3.seconds`, `1.5.minutes` (`Durations` on `num`), which spell a constant, and `DateTime.format(…)` / `Duration.human()` (`Times`, `Spans`), which render a value for a person; none reads toolkit state. Sealed results and exceptions (`Compressed`, `Kept`, `Outcome`, `HttpStatusException`) carry public final fields on purpose: they are matched with patterns (`case Kept(:final reason)`). Each library doc says `Public surface is exactly: …`.                          |
| 3   | **Short names, one meaning each.** One word when it reads one way, dropping a suffix the receiver already says (`status()` not `statusCode()`, `hex()` not `hexDigest()`). The same idea has the same name in every module (§3), and options too (`limit:` is how many at once, `max:` how many bytes, `dir:`, `cache:`, `or:`). One method with an optional argument beats two. No abbreviation a reader must decode (`markdown`, not `md`). The only symbols are `$` (query), `[]` (index), `\|` (pipe through), `&` (watch) and `>` (pipe into). |
| 4   | **Chains never need an inner `await`.** Every async value type has a Future mirror: an extension on `Future<T>` that repeats `T`'s members. Mirrors are named `<Type>Future`, because Dart hides unnamed extensions outside their library; nobody writes that name.                                                                                                                                                                                                                         |
| 5   | **Actions return their receiver** (`page.fill(…).click(…)`). An action that makes something new returns that instead (`copy`, `download`). Readings return data. `close()` and `delete()` return nothing.                                                                                                                                                                                                                                                                                   |
| 6   | **Content leaves as a `Reader` and arrives through a `Writer`.** No method takes an output path: screenshots, PDFs, encoded images, archives and downloads are all `Reader`s, stored with `> Fs.file(…)`.                                                                                                                                                                                                                                                                                   |
| 7   | **Outcomes are values; only failing to reach throws.** A 404 is a `Response`, a non-zero exit is an `Output`, malformed HTML still parses, a missing path is `null`. What throws is the network, the disk, a program that won't start, a wait that runs out.                                                                                                                                                                                                                                |
| 8   | **Never null for collections, nullable for single lookups.** No match gives an empty `Elements`; a missing attribute, header or option gives `null`.                                                                                                                                                                                                                                                                                                                                        |
| 9   | **In memory is sync, I/O is async.** There are no sync twins.                                                                                                                                                                                                                                                                                                                                                                                                                               |
| 10  | **Inputs are positional, options are named and optional** with defaults. There are no option objects, builders, or flags that change the result type. In-memory data is a `String` (UTF-8) or a `List<int>`.                                                                                                                                                                                                                                                                                |
| 11  | **Types over runtime checks.** Generics carry the value type (`Opt<int>`, `value<T>()`, `Pool.map<T, R>`), sealed types make `switch` exhaustive (`Entry`), and `Object` parameters are kept to data and `body:`.                                                                                                                                                                                                                                                                           |
| 12  | **`close()` releases a resource and is idempotent.** Whatever holds a process, socket, terminal or isolate cleans up on `close()`, on an error, and on Ctrl-C. Nothing keeps a finished script alive.                                                                                                                                                                                                                                                                                       |
| 13  | **Engines stay private and swappable.** An engine type never appears in a public signature, and engine exceptions are rethrown as Dart's own (§5). Tests use real servers, files, browsers and pseudo-terminals, never the engine, so a swap is proven by the same suite.                                                                                                                                                                                                                   |
| 14  | **No code generation, no linked native code.** Native tools (ffmpeg) are downloaded on first use, pinned by sha256, and run as processes. Dart 3.10+ (dot shorthands: `encode(.jpg)`, `archive(paths, format: .tgz)`). |
| 15  | **Watching is `&`, never a parameter.** Long work returns a `Task` (`Pool.map`, `Dir.copy`, `Video.compress`, `Shell.run`); a reader is watched as it flows; any other future shows a spinner. A probe shows the whole run it is in, so where it sits never matters. |
| 16  | **Callbacks decide or announce an event; they never observe progress or tee output** (`onItem`, `onError`, `keys:`, `onSubmit:`, `onWait:` stay; there is no `onDone:`, `onProgress:`, `onLine:`). |
| 17  | **Content moves with `>`; in-memory values use a method** (`file.write('text')`, `hash.add('text')`, `Body.json(v)`). Entries move with `copy`/`move` (modes and times kept); content with `>`. |
| 18  | **Text → value is `X.parse(text)`; content → value is `reader.x()`,** one pair per format (`Json`, `Html`, `Csv`, `Yaml`, `Cookies`). Every whole-value reading takes `or:` for a missing source; streaming ones (`lines` `rows` `ndjson`) do not. |
| 19  | **A check is `check()` on the value** (`Response`, `Output`); `check:` is only a client-wide policy. One door in per value: content becomes a value through a reading; a static `open` is only for what has no bytes (an HLS URL). |
| 20  | **The main input is positional, and the text a call shows is a main input** (`ask(question)`, `bar(label)`, `key(prompt)`). A function that renders an item is positional after the items (`choose(q, items, (u) => u.name)`, `Region.list(pick, (u) => u.name)`). Calls of one kind take the same options: every prompt takes `or:` and `timeout:`. |
| 21  | **Failures are `Exception`s; `Error`s are bugs.** No toolkit failure extends an `Error`. |

## 2. Core: Reader, Writer, Pipe, Probe, Closeable

`core.dart` is re-exported by every module except `cli` and `tui`, which use only `ToolkitException` from it.

```dart
abstract mixin class Reader {                     // bytes you can read; implement stream()
  Stream<List<int>> stream();
  Future<List<int>> bytes();
  Future<String> text();                          // UTF-8, malformed bytes replaced
  Stream<String> lines();                         // the same, line by line as it arrives
  Future<Cookies> cookies({Cookies? or});         // a cookies.txt session; or: when missing
  Reader operator |(Pipe? pipe);                   // lazy; null = skip
  Reader operator &(Probe? probe);                 // watched; null = skip
  Future<void> operator >(Writer? w);              // run; null = discard
  Origin origin();                                // where the bytes came from (the base for `html()`)
  static Reader of(List<int> bytes);
}
abstract mixin class Writer { Future<void> consume(Stream<List<int>> input);  Origin origin(); }   // origin: a File's path
final class Cookies {                             // the jar chrome produces and http consumes
  Cookies({String? agent});  static Cookies parse(String text);  String encode();   // Netscape cookies.txt (+ a user-agent: line)
  String? operator [](String name);  String? header(String url);  String? agent();  Cookies set(String name, String value, {required String url});
}
final class Rate { Rate(int count, Duration per, {Duration pause, void Function(Duration)? onWait, bool perHost = false});  Future<void> wait(); }
extension Durations on num { Duration get milliseconds, seconds, minutes, hours, days; }   // 3.seconds, 1.5.minutes
abstract mixin class Pipe { Stream<List<int>> transform(Stream<List<int>> input);  void abort(Object error) {} }
abstract mixin class Probe { void update(int done, int? total); }   // watches; attach with &
final class Task<T> implements Future<T> { Task<T> operator &(Probe? probe); }   // a future that counts
extension Watch<T> on Future<T> { Future<T> operator &(Probe? probe); }       // any future: a spinner
final class Meter with Probe { Meter();  int done();  int? total();  double rate(); }   // a probe to draw by hand
abstract interface class Closeable { Future<void> close(); }
final class Origin { const Origin({String? url, int? status, String? name, String? path, int? size});  String? url();  int? status();  String? name();  String? path();  int? size(); }
```

| Type                                                               | Reader | Writer | Pipe | Closeable |
| ------------------------------------------------------------------ | :----: | :----: | :--: | :-------: |
| `Response` (http)                                                  |   ✓    |        |      |     ✓     |
| `File` (fs)                                                        |   ✓    |   ✓    |      |           |
| `Output` `Shell.read()` (shell), `Download` `Capture` (chrome), `Console.input()` |   ✓    |        |      |           |
| `page.screenshot()` `pdf()`, `image.encode()`, `Archive.archive()` |   ✓    |        |      |           |
| `Archive.unarchive(dir)`, `Console.out()`                           |        |   ✓    |      |           |
| `Hasher`                                                           |        |   ✓    |  ✓   |           |
| `Bar` (console; a `Probe`)                                         |        |        |      |     ✓     |
| `Archive.gzip()` `gunzip()`, `Shell.filter()`                      |        |        |  ✓   |           |
| `Browser`, `Page`                                                  |        |        |      |     ✓     |

Other modules add readings to `Reader` (and `Future<Reader>`): `html()`, `json()` and `image()`.

**Pipelines:**

- `a | p` builds a new `Reader`; nothing flows yet. `a > w` runs everything and completes when
  `w` has stored the last byte.
- `a | p | q > w` groups like a shell; wrap the chain in `await (…)`.
- Null stages make optional steps inline: `res & (quiet ? null : bar) | (verify ? hash : null) > (dry ? null : file)`.
- **Probes (`&`).** A probe shows the run it is in, wherever it sits: the source's bytes against
  the source's length (`Origin.size()`, or a file's stat: learned, never passed), still after a
  transforming pipe (a bar after gzip reaches 100%); the work a source reports before its bytes
  exist (an encode in media time, a 7z built by 7-Zip); then the work a writer reports after its
  input (7-Zip extracting a big 7z). Counting happens once at the root, so probes cost nothing
  per chunk. One probe used by many runs sums them. Units (bytes, items, media time) stay
  private; a hand-written `Probe` hears `(done, total)`.
- **`Task`s.** Long work that is not a flow returns a `Task`: `Pool.map`/`settle` count items,
  `copy`/`move` bytes, `Dir.list` entries, `Video.compress` media time, `Shell.run` nothing (a
  spinner). Probes attached in the same expression are known before the work starts (a watched
  `Dir.copy` streams so it can count; an unwatched one is one `cp`). Any other future takes `&`
  too and shows a spinner; a future of a reader is watched as a flow.
- Backpressure is the stream's, so memory stays at a few chunks whatever the size.
- A response can be streamed once. Everything else (`File`, `Output`, `Download`, lazy readers)
  re-reads.
- An error anywhere fails the whole run, _including a writer that fails before it reads_. The
  source is cancelled, a `File` keeps its old content, a `Bar` prints `✗`, a `Hasher` refuses
  `hex()`, and the error is rethrown from `>`.
- Extending takes one class with one member: `with Reader` + `stream()`, `with Writer` +
  `consume()`, `with Pipe` + `transform()`, `with Probe` + `update()`.
- `Cookies` and `Rate` live in core because two modules share them: chrome produces a jar and
  http consumes it; http and pool both pace with a `Rate`.

## 3. Names

| Idea                                   | Name                                                                    | Where                                                                        |
| -------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| content as text / bytes                | `text()` / `bytes()`                                                    | every `Reader`, `Element(s)`, `Page`                                         |
| bytes → value                          | `html()` `json()` `image()`                                             | readings on `Reader`                                                         |
| text → value / value → text or bytes   | `parse` / `encode`                                                      | `Html`, `Json`, `Csv`, `Yaml`, `Cookies` / `Json`, `Csv`, `Cookies`, `Image` |
| query a tree / typed read, null if not | `$` / `value<T>()`, `run()`                                             | `Elements`, `Element`, `Json` / `Json`, `Page`                               |
| an attribute / every match's attribute | `attr` / `attrs`                                                        | `Element(s)`                                                                 |
| a tree without some parts              | `not(selector)`                                                         | `Element(s)`                                                                 |
| feed data / watch progress / count by hand | `add(data)` / `work & probe` / `tick(n)`, `update(done, total)`     | `Hasher` / every reader, `Task`, future / `Bar`, `Meter`                     |
| release / remove from disk / make      | `close()` / `delete()` / `create()`                                     | `Closeable` / `Entry` / `Dir`, `Link`                                        |
| final URL / HTTP status / 2xx          | `url()` / `status()` / `ok()`                                           | `Response` (`Page` has `url()`)                                              |
| a file name / a size in bytes          | `name()` / `size()`                                                     | `Entry`, `Download`, `Response`, `Capture` / `File`, `Response`, `Origin`    |
| run a program, an app, a CLI / jobs    | `run` / `map`, `settle`                                                 | `Shell`, `Tui`, `Command` / `Pool`                                           |
| download to a file (skip, resume)      | `get(u) & bar > file` with `resume: true`                               | `Client`                                                                     |
| parse / write HTML back out            | `html()` / `markup()`                                                   | `Reader`, `Page` / `Element(s)`                                              |
| check a result                         | `check()`                                                               | `Response`, `Output`                                                         |
| run a body with a resource, then free  | `tempDir((dir) …)` / `lock(() …)`                                        | `Fs` / `File`                                                                |
| a variant with other settings          | `copy(...)`                                                             | `Client`                                                                     |
| a key                                  | `press(key)` sends, a `keys:` binding handles; one key-name set (§4.12) | `Page`, `Screen`                                                             |
| draw or store into                     | `write`                                                                 | `File`, `Region`                                                             |
| dimensions                             | `width()` `height()` / `width:` `height:`                               | `Image`, `Region` / `open`, `resize`, `popup`                                |
| the function that does the work        | `handler`                                                               | `Command(handler:)`                                                          |
| a notification / a bound event         | `on…:` / `on(events)`, `keys:`                                          | `onWait:`, `onSubmit:` / `Region`, `Screen`                                  |
| a value when the source is missing     | `or:`                                                                   | `File.text/bytes`, `json()`, `Opt`, `Json.or`                                |
| switch the current state               | `go(state)`                                                             | `App`                                                                        |

Named parameters, each with one meaning: `headers` `body` `timeout` `base` `headless`
`path` `profile` `proxy` `block` `width` `height` `fullPage` `dir` `env` `recursive`
`json` `pretty` `limit` `max` `retries` `check` `short` `or` `rate` `cookies` `csrf`
`isolates` `match` `dotenv` `sep` `resume`
`required` `parse` `params` `commands` `aliases` `handler` `secret` `label` `quality` `color`
`background` `style` `link` `title` `status` `keys` `accent` `hint` `lines` `suggest`
`empty` `header` `onSubmit` `since` `history` `query` `live` `total` `keep`
`password` `format` `expect` `from`.

## 4. Modules

| Import    | Public surface (core members and Future mirrors not repeated)                                                                                                                                                                                                                                                                                                                                                 | Engine                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `core`    | `Reader` `Writer` `Pipe` `Probe` `Task` `Watch` `Meter` `done` `total` `rate` `Closeable` `Origin` · `Reader.cookies` · `Cookies` `parse` `encode` `[]` `header` `agent` `set` · `Rate` `wait` · `Durations` (`3.seconds`) · `Sizes` (`size()`) · `Times` (`format`) `Spans` (`human`) · `ToolkitException` `ContentException` `PasswordException`                                                                                                                                                                                   | in-house                            |
| `html`    | `Html.parse` · `Reader.html` · `Elements` `$` `[]` `not` `text` `texts` `markup` `attr` `attrs` `json` `table` `form` · `Element` `$` `text` `markup` `attr` `parent`                                                                                                                                                                                                                                             | in-house HTML5 parser and selectors |
| `http`    | `Http.client` `pool` · `Client` `copy` `cookies` `sent` `get` `head` `delete` `post` `put` `patch` `close` · `Response` `status` `ok` `check` `header` `url` `size` `name` · `Body` `text` `bytes` `form` `json` `multipart` `stream` · `Feed` `run` · `FeedPage` `items` `add` `stop` · `Browser` · `HttpStatusException` `HttpRequestException` `RequestFailure` `SessionException` | `dart:io`                           |
| `chrome`  | `Chrome.launch` `connect` · `Browser` `open` `pages` · `Page` (below) · `Download` `name` · `Capture` `status` `url` `header` `name`                                                                                                                                                                                                                                                                                 | in-house DevTools client (`dart:io` WebSocket) |
| `json`    | `Json.parse` `of` `encode` · `Reader.json` `ndjson` · `Json` `$` `[]` `value` `or` `text` `texts` `max` `asList` `asMap`                                                                                                                                                                                                                                                                                        | `dart:convert`                      |
| `csv`     | `Csv.parse` `encode` · `Reader.csv(or:)` `rows`                                                                                                                                                                                                                                                                                                                                                          | in-house                            |
| `yaml`    | `Yaml.parse` · `Reader.yaml`                                                                                                                                                                                                                                                                                                                                                                                  | in-house                            |
| `fs`      | `Fs.entry` `file` `dir` `link` `sanitize` `tempDir` `homeDir` `scriptDir` · `Entry` `path` `name` `parent` `exists` `modified` `delete` `copy` `move` · `File` `write` `append` `size` `lock` `text(or:)` `bytes(or:)` · `Dir` `file` `dir` `list(match:)` `watch` `create` · `Link` `target` `resolve` `create`                                                                                                                | `dart:io`, `path`                   |
| `shell`   | `Shell.run` `read` `which` `filter` `open` · `Output` `code` `ok` `err` `check` · `ExitException`                                                                                                                                                                                                                                                                                                                                      | `dart:io`                           |
| `archive` | `Archive.archive` `unarchive` `gzip` `gunzip` · `ArchiveFormat`                                                                                                                                                                                                                                                                                                                                               | `dart:io` (in-house zip, tar)       |
| `hash`    | `Hash.md5` `sha1` `sha256` `sha512` (`expect:`, `key:` for HMAC) · `Hasher` `add` `addBytes` `hex` `bytes`                                                                                                                                                                                                                                                                                      | `package:crypto`                    |
| `pool`    | `Pool.map` `settle` · `Pool(limit:)` `run` (a `Task`) · `Outcome` `Done` `Failed` · `values` `failures`                                                                                                                                                                                                                                                                                                                                         | `dart:isolate`                      |
| `cli`     | `Flag` `Opt` `Multi` `Arg` `Rest` (sealed `Param<T>`) · `Command` `run` · `Context` `call` `usage` · `UsageException`                                                                                                                                                                                                                                                                                         | in-house                            |
| `console` | `Console.ask` `confirm` `choose` `key` `bar` `log` `logged` `table` `notify` `copy` `out` `input` · `Bar` `tick` `update`                                                                                                                                                                                                                                                                         | in-house                            |
| `tui`     | `Tui.run` · `App` `state` `go` `status` `quit` · `Screen` · `Binding` · `Pick` · `Field` · `Scroll` · `Region` (below, + `picture`, `bars`, `log`) · `Color` · `Style` · `Meter` (core's)                                                                                                                                                                                                                                                       | in-house                            |
| `image`   | `Image.sniff` `compress` · `Reader.image` · `Image` `width` `height` `format` `resize` `crop` `encode` `pixels` · `ImageFormat` | ffmpeg (downloaded, pinned) |
| `video`   | `Video.open` `sniff` `compress` · `Reader.video` · `Video` `width` `height` `duration` `fps` `format` `codec` `audioCodec` `bitrate` `encode` `frame` · `VideoFormat` `VideoCodec` | ffmpeg, ffprobe (downloaded, pinned) |

A module imports only core and its engine. The exceptions are `video`, which imports `image` for `frame()`, `chrome`, which imports `html`
for `Elements` and `json` for `run`'s `Json` result, and `html`, which imports `json` for
`Elements.json()` (embedded data) and re-exports it, and `yaml`, which imports and re-exports `json` (its `parse`
returns a `Json`). `console` and `tui`
share one private terminal layer: stdin, key decoding, signal handling and restoring the terminal.

### 4.1 html

```dart
abstract final class Html { static Elements parse(String html, {String? base}); }
extension on Reader { Future<Elements> html(); }     // base = the response's final URL or the file's URI
final class Elements extends Iterable<Element> {
  Elements $(String selector);  Element operator [](int i);  Elements not(String selector);
  String text();  List<String> texts();  String markup();  String? attr(String name);  List<String> attrs(String name);
  Json json();                                      // <script type=application/json|ld+json>, __NEXT_DATA__
  List<Map<String, String>> table();                // the first table: header → cell text
  ({String action, String method, Map<String, List<String>> fields})? form();   // the first form, hidden fields included
}
final class Element {
  Elements $(String selector);  String text();  String markup();  String? attr(String name);  Element? parent();
}
```

- The parser is in-house and follows the WHATWG algorithm (implied `html`/`head`/`body`,
  auto-closed `p`/`li`/cells, implied `tbody`/`tr`, foster parenting, formatting reconstruction
  and the adoption agency, raw text, the full named-entity table, SVG/MathML). Scripting is on:
  `noscript` content is text. A corpus test holds it to package:html's tree on 50 real pages.
- `parse` never throws on bad markup and never recurses (20,000-deep pages are fine). Input that
  starts with `<!doctype` or `<html` is a whole document (so `$('body')` works); anything else is
  a fragment. A fragment with loose text is returned as its root, which holds the text and the
  elements and matches no selector itself.
- With a base, links come back absolute: URL attributes (`href`, `src`, `data-src`, `poster`,
  `action`) are trimmed and resolved, every `srcset`/`data-srcset` candidate is resolved, and a
  `<meta content>` that is a path (`/`, `./`, `../`) is resolved, so
  `$('meta[property="og:image"]').attr('content')` is a URL to fetch.
- Selectors: type, `*`, `#id`, `.class`, attributes (`= ~= |= ^= $= *=`, `i`), the four
  combinators, `:first-child` … `:only-of-type`, `:nth-child(An+B of S)` and friends, `:not`
  `:is` `:where` `:has`, `:empty` `:root` `:link` `:checked` `:disabled` `:enabled` `:lang`
  `:scope`. A leading combinator is relative to the receiver: `ul.$('> li')` is its direct items,
  `h2.$('+ p')` the paragraph after it (`:scope` is the receiver, or each of an `Elements`). Pseudo-elements never match. A selector it
  rejects is a `ContentException` naming it once.
- `$` returns matches in document order without duplicates. On `Elements`, `text()` and `attr()`
  both read the **first** match (`''`/`null` when there is none); for every match use
  `texts()` or `attrs()`. `attrs()` skips missing values.
- `text()` reads like `innerText`, so scraped text needs no `.trim()`. Runs of spaces collapse to
  one space, and a run that holds a newline becomes one newline. The result is trimmed, and
  `<pre>` keeps its whitespace.
- `not` returns a new tree (one O(n) clone, table parts included); the receiver is
  unchanged. `markup()` is the outer markup (`outerHTML`; on `Elements`, the first match's); `html()` always parses.
- `json()` parses every embedded-data script into one `Json` list (invalid ones skipped), so
  `page.json().$('**.user')` searches them all (`; charset=…` types too). `table()` keys rows by
  the first row (`colspan` repeats across, `rowspan` down). `form()` gives what a login without a
  browser posts: `client.post(f.action, body: .form({...f.fields, 'user': u}))`. Each field holds
  every value (repeated names, `select multiple`); an empty `action` is the document URL, not
  `<base href>`.
- `html` re-exports `json`, so `get(u).html().json().$('x')` needs one import.

```dart
final doc = await http.get(url).html();
final body = doc.not('script, style, nav').$('article').text();
final links = await http.get(url).html().$('a.item').attrs('href');
final user = (await ig.get('/$name/').html()).json().$('**.xig_user_by_username');
```

### 4.2 http

```dart
abstract final class Http {
  static Client client({String? base, Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 30),
      int retries = 2, Rate? rate, bool check = false, Cookies? cookies, ({String cookie, String header})? csrf,
      String? proxy, bool resume = false,
      int max = 256 << 20,                        // max: bytes a body read into memory may decode to
      Browser? browser,                           // .page / .api: the headers a desktop browser sends
      List<String> login = const []});            // sign-in paths: landing on one throws SessionException
  static Client pool(List<Client> members);      // also a Client
}
sealed class Client implements Closeable {
  Client copy({Map<String, String>? headers, Duration? timeout, int? retries, Rate? rate, String? proxy});   // null keeps it; headers merge; shares jar, Rate and connections; counts in sent(), closes with this
  Cookies cookies();
  int sent();                                     // requests on the wire (attempts and hops)
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers});   // head, delete: the same
  Future<Response> post(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}); // put, patch
  Future<void> close();                           // cancels this client's requests and waits; idempotent
}
sealed class Body {                              // stream (or multipart with files): sent once, never retried
  const factory Body.text(String text);  const factory Body.bytes(List<int> bytes);
  const factory Body.form(Map<String, Object?> fields);  const factory Body.json(Object? value);
  const factory Body.multipart(Map<String, String> fields, {Map<String, Reader> files});   // files stream
  const factory Body.stream(Reader reader);
}
final class Feed<T> {                            // a newest-first listing, one page at a time
  Feed(Future<({List<T> items, String? next})> Function(String? cursor) page, {String? cursor});   // cursor: a file that survives a run
  Future<bool> run(FutureOr<void> Function(FeedPage<T> page) onPage, {bool all = false});   // true: the end was reached, all work succeeded; a work's throw is rethrown
}
final class FeedPage<T> { List<T> items();  FeedPage<T> add(Future<bool> work);  void stop(); }
final class Response with Reader implements Closeable {
  int status();  bool ok();  Future<Response> check();  String? header(String name);  String url();
  int? size();                                   // content-length, null when unknown or decoded on the fly
  String name();                                 // content-disposition filename, else the URL's last segment
}
```

- `query:` values are `String`, `num`, `bool`, a `Map` (sent as JSON: GraphQL's `variables`), null (dropped) or an `Iterable` (the key repeats).
- **`browser: .page`** sends what a desktop browser sends opening a page (`accept: text/html…`,
  `sec-fetch-mode: navigate`), **`.api`** what its script sends (`accept: */*`, `sec-fetch-mode: cors`);
  `headers:` still wins. **`login:`** names the site's sign-in paths: a response that lands on one
  after redirects throws `SessionException` (its `url`), so a lost session is an error, not a page.
- **Settings live on the client**, stated once; a request passes only `query`, `headers` and
  `body`. `Http.client()` with no arguments is a new, isolated client (its own jar and sockets);
  an idle client releases its sockets after 100 ms (6 per host at most), so a finished script exits. `copy(...)` is a
  variant that stays one session.
- `base:` resolves relative URLs. `query` values may be `String`, `num`, `bool`, null (drops the
  key) or an `Iterable` (repeats the key); `Body.form` takes the same map.
- A verb completes when the headers arrive; the body streams. A non-2xx status is still a
  `Response` unless the client says `check: true`; `res.check()` (and `get(u).check()`) throws
  `HttpStatusException('HTTP 404 GET <url>: <snippet>')`.
- Redirects are followed for every verb, as in browsers: 301/302/303 after a POST become a GET,
  and 307/308 keep the method and resend an in-memory body. `url()` is the final URL. A
  cross-origin hop drops credential headers; an https → http hop warns on stderr.
- **User-Agent**: a current desktop Chrome unless a `user-agent` header is given or the jar has
  an `agent()` (`reader.cookies()` reads it from the session file's `user-agent:` line).
- **`Feed`** walks a listing API newest first with one callback per page (each cursor is visited once a run, so a
  looping feed ends; another start point is a second `Feed`): `page.stop()` ends the walk
  where the rest is known (or older than wanted), `page.add(work)` hands over what the page starts
  while the next page is fetched, and the cursor file moves past a page only once its work (and
  every earlier page's) succeeded, so an interrupted run continues: it lists the top up to what is
  known, then resumes. `all: true` re-lists from the top. `run` is true only when the end was
  reached with every page's work done; a work that throws fails the run (its first error) once all
  work has finished.
- **Only a 2xx body can be piped.** `res > file` on a 404 throws what `check()` throws, so an
  error page is never saved. The readings (`text()`, `lines()`, `json()`, `html()`) work on any
  status.
- **Cookies** live in the client's `Cookies` jar (core; `page.cookies()` produces one).
  `set-cookie` (redirect hops too) updates it, parsed leniently like a browser (spaces, quotes, any
  date form); one without `name=` skips only itself; `Domain=` needs a dot, is never an IP or a
  public suffix (`co.uk`, `github.io`); cookies go out longest path first. A per-call `cookie` header merges
  by name (the caller wins). `csrf: (cookie: 'csrftoken', header: 'x-csrftoken')` copies a cookie
  into a header on every send.
- **Retries** apply only when the request provably was not processed: any in-memory body on
  connect/DNS failures, 429 and 503; GET/HEAD/PUT/DELETE also on timeouts, network errors and
  502/504; never 500/501/505 or TLS. Backoff doubles from 1 s with ±25% jitter; `Retry-After` is
  honoured (capped at 5 min unless the client has a `Rate`, whose 429 waits the window out).
- `rate: Rate(75, 11.minutes, pause: 3.seconds)` paces every send of the clients that share it;
  `Rate(1, 1.seconds, perHost: true)` keeps one window per host.
- **Downloads respect the pipe.** With `resume: true`, a GET piped into a file
  (`cdn.get(u) & Console.bar(name) | Hash.sha256(expect: s) > Fs.file(f)`):
  - skips a complete file (same `content-length`, or any file when the server sends none);
  - resumes a `.part` with `Range` when the server answers 206 (anything else restarts), and
    finishes a complete one on a 416; a changed file reuses the first GET;
  - renames the finished file into place.
    Stored bytes replay through the pipes, so a bar counts the whole file and a hash verifies it.
    A pipe that isn't a pass-through (gzip, a filter) downloads from scratch. A transport failure
    keeps the `.part`; any other failure deletes it. The GET is sent at the end of the current
    synchronous block unless such a pipeline claims it, so awaiting it works as always.
- `proxy:` is `http://` or `socks5://[user:pass@]host[:port]` (port 1080 by default; SOCKS resolves
  names); null reads `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`. A pool's `copy(proxy:)` throws.
- **`Http.pool([a, b])`** sends each request to the member with the fewest in flight whose
  `Rate` is free (ties round-robin); a 429 benches that member and retries on another. For
  several accounts, mirrors or proxies.
- `timeout` (30 s) bounds the connect, the wait for the headers, then any stall in the body.
  Every transport error names `METHOD url` and keeps its stack. `close()` fails this client's
  requests and waits with `HttpRequestException` (`reason: RequestFailure.aborted`); a redirect
  loop or an unsendable redirect is `RequestFailure.redirects` / `.unsendable`.
- `text()` uses the charset from `content-type`, then `<meta charset>` (HTML only), then UTF-8,
  with in-house WHATWG CJK decoders; bad bytes become `�`. `text()`/`bytes()` cache; a piped body
  can't be read again (`StateError`).
- `close()` on a `Response` drops an unread body. The `Future<Response>` mirrors close the
  response after every mirror read; `check()` keeps it open.

```dart
final shop = Http.client(base: 'https://shop.example/', headers: {'accept-language': 'ko-KR'},
    retries: 3, rate: Rate(1, 250.milliseconds));
final page = await shop.get('list.php', query: {'page': p}).html();
final me = await api.get('me').check().json();
final ig = Http.client(base: _ig, cookies: session, csrf: (cookie: 'csrftoken', header: 'x-csrftoken'));
await (cdn.get(url) & Console.bar(name) > Fs.dir('imgs').file(name));   // skip, resume, atomic
final login = await HttpServer.bind('127.0.0.1', 0);   // an OAuth loopback redirect is plain dart:io
final req = await login.first;
final code = req.uri.queryParameters['code'];
await (req.response..write('Signed in; close this tab.')).close();
```

### 4.3 chrome

```dart
abstract final class Chrome {
  static Future<Browser> launch({bool headless = true, String? path, String? profile, String? proxy});
  static Future<Browser> connect(String url);
}
enum Resource { image, font, media, stylesheet }   // what open(block:) stops loading
final class Browser implements Closeable {
  Future<Page> open(String url, {Map<String, String>? headers, Set<Resource> block = const {}, int? width, int? height,
      Duration? timeout});
  Future<List<Page>> pages();
}
final class Page implements Closeable {
  Future<Page> go(String url, {Duration? timeout});                                  // wait for load
  Future<Page> back({Duration? timeout});                                            // a reload is go(await url())
  Future<String> url();  Future<Elements> html();  Future<String> text();
  Future<Json> run(String js);   Future<Cookies> cookies({bool all = false});          // the current URL's jar
  Future<String> cookie(String name, {Duration? timeout});                              // waits until set
  Stream<Capture> responses(String pattern);                                            // XHR/fetch matching a glob
  Future<Page> click(String selector, {Duration? timeout});                             // auto-wait
  Future<Page> fill(String selector, String value, {Duration? timeout});
  Future<Page> select(String selector, String value, {Duration? timeout});
  Future<Page> upload(String selector, Reader file, {Duration? timeout});
  Future<Page> press(String key);  Future<Page> scroll({String? to, Duration? timeout});   // to the bottom, or to a selector
  Future<Page> wait(String selector, {Duration? timeout});  Future<Page> idle({Duration? timeout});
  Reader screenshot({bool fullPage = false});  Reader pdf();                            // captured when read
  Future<Download> download(String selector, {Duration? timeout});
}
final class Download with Reader { String name(); }   // returned when the download begins; reading waits for the file
final class Capture with Reader { int status();  String url();  String? header(String name);  String name(); }
```

- `chrome` speaks the DevTools protocol itself over a `dart:io` WebSocket (no engine package).
  `launch` takes `path`, else Chrome for Testing already in the user cache, else an installed
  Chrome/Chromium, else downloads Chrome for Testing once per machine; a headless run without a
  profile uses `chrome-headless-shell` (starts ~4x faster). `profile` keeps logins (session cookies
  too) between runs, never tabs; without it, a temp profile is deleted on `close`. `connect`
  attaches (`http://host:9222` or `ws://…`), and its `close` closes the tabs it opened, restores
  the download behaviour and disconnects.
- Tab setup happens at `open`: `headers` (including `user-agent`), `block` by resource type
  (`'image'`, `'font'`, `'media'`, `'stylesheet'`), and the viewport. Dialogs are always
  dismissed.
- Actions wait until the first match is attached, visible and enabled (`upload`: attached only,
  since file inputs are usually hidden). They time out (30 s) with a `TimeoutException` naming the
  selector. `fill` clears the field (an input, a textarea or a `contenteditable`), types the value,
  and fires `input`/`change`.
- `idle` waits for 500 ms with no request in flight. `download` credits a download started in the
  tab or any of its frames and returns once the browser names the file; reading the `Download`
  waits for the browser to finish it, and a probe on it (`d & Console.bar(d.name()) >
  Fs.file(d.name())`) shows the browser's own progress. Downloads share one folder per browser,
  told apart by their DevTools guid, so concurrent downloads don't clash. A first-use Chrome for
  Testing download (like ffmpeg's and 7-Zip's) shows a live progress line on stderr, or in the
  status row while a `Tui.run` is active.
- `run` evaluates an expression or statements once (a function result is called once), awaits
  promises, throws `BrowserException` when the script throws, and returns the result as `Json`:
  `await page.run('document.title').or('')`, `.value<int>()`, `.$('a.b')`, `.asList<String>()`. `press` takes the key names of §4.12;
  an unknown name is an `ArgumentError`.
- `chrome` re-exports `html`, so `page.html().$('a')` needs one import.
- **The session is a value:** `cookies()` is a core `Cookies` jar (domain, path, expiry kept;
  `all: true` for every cookie the browser holds), so
  `Http.client(cookies: await page.cookies())` continues the browser session, and
  `file.write(jar.encode())` / `Cookies.parse(...)` persists it. `cookie(name)` waits for a login
  to set it. Closing the window during `cookie()` or `wait()` throws `BrowserException('browser closed')`.
- **The page's data is a stream:** `responses('*/graphql/query*')` yields every XHR/fetch response
  whose URL matches (`*` crosses `/`), while listened to. A `Capture` is a `Reader` with http's
  reading names; its body is fetched as it arrives.
- `Browser.close()` closes every tab and the process; a crash or error never leaves Chromium
  running.

```dart
final page = await Chrome.launch(profile: '.chrome').open(loginUrl, block: {.image, .font})
    .fill('#user', name).fill('#pass', pass).click('button[type=submit]').wait('.dashboard');
final invoice = await page.download('a.invoice');
await (invoice > Fs.dir('invoices').file(invoice.name()));
final api = await Http.client(cookies: await page.cookies()).get(apiUrl).json();
await page.cookie('sessionid', timeout: 5.minutes);           // a hand login finished
```

### 4.4 json

```dart
final class Json extends Iterable<Json> {
  static Json parse(String json);
  static Json of(Object? decoded);                  // wrap a value you already hold
  static String encode(Object? value, {bool pretty = false});
  Json $(String path);  Json operator [](int i);
  T? value<T>();  T or<T>(T fallback);           // typed read, null / the fallback when absent or mistyped
  String? text();                                // any scalar as a String; null for null, a miss, a collection
  List<String> texts();                          // every item's text, misses dropped (as Elements.texts)
  // value<DateTime>() reads ISO text and Unix s, ms, µs or ns (told apart by size)
  Json max(num Function(Json item) by);   // a null Json when empty; the smallest is max((i) => -by(i))
  List<T> asList<T>();  Map<String, T> asMap<T>();   // empty when missing or mistyped
}
extension on Reader { Future<Json> json({Json? or});  Stream<Json> ndjson(); }   // or: when the source does not exist
```

- `$('a.b.0')` walks dotted paths, and a numeric segment indexes an array (`items.-1` is the
  last). A `*` segment maps over every item: `$('data.users.*.name').asList<String>()`. A `**`
  segment searches every depth: `$('**.pk')` lists each `pk` in the document (misses dropped). A
  wildcard after a wildcard flattens: `x.*.a.*.b` is one list. `|` separates whole paths tried in
  order: `$('code|shortcode')`, `$('rest_id|legacy.id_str')`. `\*`, `\|` and `\.` are literal. A
  missing path is a `Json` of `null`, never a throw.
- `value<T>()` returns `null` when the value is absent or not a `T`. Integral numbers read as both
  `int` and `double`, so `3`, `3.0`, `value<int>()` and `value<double>()` all agree.
  `$('port').or(8080)` is a non-null `int`. `text()` reads `787132` as `'787132'` (not
  `toString`, which renders JSON), and so does a `String` fallback: `$('id').or('')`.
  `asList<T>()` and `asMap<T>()` check each element and give `[]` / `{}` when missing or
  mistyped; `asList<Json>()`/`asMap<Json>()` wrap every value; `value<List<T>>()` throws and
  points to them.
- `max` returns the largest item (the first on a tie):
  `v.$('display_resources').max((c) => c.$('width|config_width').or(0)).$('url|src').text()`.
- A `Json` iterates an array's items or an object's values; `toString` is the JSON text and `==`
  is deep.
- `encode` accepts what `dart:convert` accepts (string keys) and throws what it throws.
  Invalid JSON is a `ContentException` naming the source. `json()` decodes the bytes straight
  to a value (no `String` in between); `ndjson()` streams one `Json` per non-blank line and
  names a bad line's number.

### 4.5 fs

```dart
abstract final class Fs {
  static Future<Entry?> entry(String path);   // what is on disk, links not followed
  static File file(String path);  static Dir dir(String path);  static Link link(String path);  // no I/O
  static String sanitize(String name);   // an untrusted title as one portable file name; never leaves its folder
  static Future<T> tempDir<T>(Future<T> Function(Dir dir) body, {String prefix = 'tmp'});   // deleted after body
  static Dir homeDir();  static Dir scriptDir();   // HOME/USERPROFILE; the running script's folder
}
sealed class Entry {
  Future<DateTime> modified();
  String path({Dir? from});  String name();  Dir parent();   // path(from: dir) is relative to dir
  Future<bool> exists();  Future<void> delete();
  Task<Entry> copy(String to);  Task<Entry> move(String to);   // subtypes narrow the return type; a probe counts bytes
}
final class File extends Entry with Reader, Writer {
  Future<File> write(String text);  Future<File> append(String text);  Future<int> size();
  Future<File> touch([DateTime? time]);   // set the mtime (now by default); creates an empty file, as touch does
  Future<T> lock<T>(Future<T> Function() body, {Duration? timeout});   // exclusive OS lock for the body
  Future<String> text({String? or});  Future<List<int>> bytes({List<int>? or});   // or: when it does not exist
}
final class Dir extends Entry {
  File file(String name);  Dir dir(String name);
  Task<List<Entry>> list({bool recursive = false, String? match});  Stream<File> watch();  Future<Dir> create();   // list counts entries
  Future<({int files, int bytes})> size({String? match});   // recursive; skips .part, .part.tag, .x.tmp… ; missing = zeros
}
final class Link extends Entry {
  Future<String> target();  Future<Entry?> resolve();  Future<Link> create(String target);
}
```

- `switch (await Fs.entry(p))` is exhaustive over `File`/`Dir`/`Link`/`null`.
- **Writes are atomic.** Content goes to a temp sibling, fsynced, then renamed over the target
  (the folder is not fsynced: `dart:io` cannot open one). Writes
  go through symlinks to their target, keep the old file's mode, and create missing parents. A
  failed run leaves the old content. `append` uses OS append mode (`O_APPEND`) with an exclusive
  file lock, guaranteeing concurrent appends never lose data or replace open inodes.
- Future mirrors (`EntryFuture`, `FileFuture`, `DirFuture`, `LinkFuture`) repeat every member on
  their respective `Future`s per Rule 4.
- **`copy`/`move`:**
  - They move an entry (`>` moves content). They keep modes and timestamps (folders too) and create parents.
  - They are `Task`s: `Fs.dir('photos').copy(backup) & Console.bar('backup')` counts the bytes
    against the tree's size. Watched, the copy streams in-process; unwatched, a fresh folder is one `cp -pPR`.
  - `move` renames, and falls back to copy-then-delete only across devices.
  - A missing source, or a destination inside the source, throws before anything is written.
- `exists()` checks the handle's kind, following links for `File`/`Dir` (`Link` checks itself).
  `delete()` is a no-op when nothing is there, removes a link (never its target), and throws
  `FileSystemException` on the wrong kind (`Dir.delete()` on a file).
- `resolve()` returns a handle at the final target, or `null` when the link is broken.
  `Link.create` replaces a link atomically.
- `list()` is typed and sorted by relative path (depth-first when `recursive`), and `recursive` never follows links.
  `match: '**/*.{jpg,png}'` keeps the paths (relative to the folder) that match a glob: `*` and
  `?` stay in one folder, `**` crosses folders and implies `recursive`, `{a,b}` and `[abc]` pick.
- `text(or: '')` answers a missing file; any other failure (a folder, permissions) still throws.
  A `File` is a `Writer` whose `origin()` reports its path, which is how a `resume: true` download skips and resumes.
- `Fs.tempDir((dir) async {…})` runs the body with a fresh temp folder and deletes it after (Ctrl-C
  too); `file.lock(() async {…}, timeout:)` holds an exclusive OS lock for the body, so a second
  cron run fails at once with a `LockedException` (`locked by another process`). Both are scopes, not handles: nothing
  to forget, nothing keeps the script alive. `Fs.homeDir()` is `HOME`/`USERPROFILE`;
  `Fs.scriptDir()` is the running script's folder; `modified()` is the mtime and `touch(t)` sets it.
  `dir.size()` is `(files:, bytes:)` of finished files: download partials (`x.part`, `x.part.tag`)
  and atomic-write temps are left out, so a folder mid-download counts what has landed. A script that also
  imports `dart:io` adds `hide File, Directory, Link`.

### 4.6 shell

```dart
abstract final class Shell {
  static Task<Output> run(List<String> command, {String? dir, Map<String, String?>? env, Duration? timeout, Future<void>? cancel});
  static Reader read(List<String> command, {String? dir, Map<String, String?>? env});   // stdout as it prints
  static Future<String?> which(String program);   // where PATH (+ PATHEXT) resolves it, or null; starts nothing
  static Pipe filter(List<String> command, {String? dir, Map<String, String?>? env});
  static Future<void> open(String target);    // URL or path, in the default app
}
final class Output with Reader { int code();  bool ok();  String err();  Output check(); }   // Reader = stdout
```

- `timeout:` kills a run that takes longer, with everything it started, and throws a
  `TimeoutException` naming the command. `cancel:` kills the same tree when its future completes
  and returns the captured `Output` (code `-9`). Ctrl-C, `SIGTERM` and `SIGHUP` end the child
  tree of every `run` and `filter` in flight, and so does cancelling a filter's reader (Windows
  has no `ps`: only the child itself).
- `command[0]` is the program, looked up on `PATH`, and there is no shell, so arguments are safe.
  Use `['sh', '-c', …]` for shell syntax.
- `run` closes stdin and waits for the exit. `text()` drops one trailing newline, as `$(…)` does
  in a shell; `> file` and `bytes()` stay verbatim. A non-zero exit is an `Output`; a program that
  can't start throws `ProcessException`, with the OS error code. An `Output` is in memory, so it
  can be read many times.
- `filter`: the stream goes to stdin and stdout comes out. A non-zero exit fails the run with an
  `ExitException` (a `ProcessException` and a `ToolkitException`: `errorCode`, the last 64 KB of
  stderr in `message`), as `Output.check()` does. A child that stops reading early (`head`, `grep -m`) is not an error.
- Three verbs, three behaviours: `run` to the end (an `Output`, a `Task` a probe shows as a
  spinner), `read` while it prints (a `Reader`: `Shell.read(cmd) > Console.out()` shows it live,
  `.lines()` reads it line by line; its stderr passes through to ours, a non-zero exit fails it
  like a filter), `filter` in the middle of a flow.
- `open` uses `open`/`xdg-open`/`rundll32 url.dll,FileProtocolHandler` (no shell parsing) and returns once the program has launched.

```dart
final head = await Shell.run(['git', 'rev-parse', 'HEAD']).check().text(); // a non-zero exit throws
await (Shell.run(['make', '-j8']) & Console.bar('build'));                   // a spinner
await for (final line in Shell.read(['yt-dlp', url]).lines()) { … }
await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
```

### 4.7 archive

```dart
enum ArchiveFormat { zip, tar, tgz, sevenzip }   // what archive writes; unarchive also reads RAR, .tar.xz/.bz2/.zst/.Z, cab, ar, xar
abstract final class Archive {
  static Reader archive(List<String> paths, {ArchiveFormat format = .zip, String dir = '.', String? password}); // files and folders, named relative to dir
  static Writer unarchive(String dir, {String? password, int? max}); // format from the magic bytes; max: bytes written
  static Pipe gzip();  static Pipe gunzip();
}
```

- `unarchive` checks every member first: absolute paths and `..` escapes are a
  `FormatException`. It then extracts into a temp sibling and moves the members into `dir`,
  **merging with what is already there and never replacing it** (an existing file keeps its
  content and mode; that member is dropped). File modes and mtimes are kept, so executables
  still run. A symlink is kept when it resolves inside `dir` (through the archive's own links);
  a hardlink lands as a copy of its member; any other link fails by name. Damaged archives, bad
  checksums (zip CRC, RAR5 BLAKE2sp, 7z header CRC) and truncated RAR are a `ContentException`
  naming the member, with the engine error as `cause`; a format it cannot read (lz4, lzip) is
  named.
- `archive` takes files and folders like `zip -r` (`['.']` with `dir:` is a folder's contents;
  `dir:` may be a link), stores links that point inside `dir` and refuses others, and an empty
  folder round-trips in every format.
- `gunzip` checks the gzip trailer. Truncated or corrupt data fails the run with a
  `FormatException`; `unarchive` drops zero padding after a `.tar.gz` whose tar is whole.
- Writing streams for zip (zip64 when needed), tar and tgz. **7-Zip** (see [Native tools](#native-tools))
  writes 7z: LZMA2 on every core, into a temp file. Reading streams tar, tgz and `.tar.xz` (x86,
  ARM64 and delta filters included) member by member in Dart; zip, and 7z/RAR up to 32 MiB, decode
  in memory on their own isolate, so Ctrl-C and redraws stay live. A bigger 7z/RAR, one using a
  method Dart lacks (BCJ2, RAR 1.5, VM filters), `.tar.bz2`/`.zst`/`.Z`/`.lzma`, cab, ar and xar
  go to 7-Zip; its output is sandbox-checked and merged exactly as Dart's (Windows' 7zr reads 7z
  only, so RAR and the rest stay Dart-only or unsupported there). RAR is read-only.
- `password:` encrypts zip as WinZip AES-256 and 7z as AES-256 with the names hidden; unarchive
  opens zip AES and ZipCrypto, 7z AES and RAR4/RAR5 encryption. A missing or wrong password is a
  `PasswordException` (a `ContentException`) before anything lands in `dir`; tar with a password is an `ArgumentError`.

```dart
await (http.get(releaseUrl) > Archive.unarchive('vendor'));
await http.put(uploadUrl, body: .stream(Archive.archive(['.'], dir: 'site', format: .zip)));
```

### 4.8 hash

```dart
abstract final class Hash { static Hasher md5({String? expect, List<int>? key}); /* sha1, sha256, sha512 alike */ }   // key: = HMAC
final class Hasher with Writer implements Pipe { Hasher add(String text);  Hasher addBytes(List<int> data);  String hex();  List<int> bytes(); }
// expect: (hex) fails the run at its end, before the writer commits: http.get(u) | Hash.sha256(expect: sum) > Archive.unarchive('opt')
```

- One type has three uses. Incremental: `h.add(a).add(b).hex()`. As a writer: `r > h`. As a
  tee: `r | h > file`, one pass that both stores and checksums.
- `hex()` and `bytes()` finish the hash (`base64Encode(h.bytes())` for base64) (each re-reads the same digest), and an `add`
  after them is a `StateError`. A hasher that saw part of a failed run throws `StateError`
  instead of returning a wrong digest.
- `key:` makes an HMAC: `Hash.sha256(key: utf8.encode(secret)).add(body).hex()` checks a webhook
  signature, and `bytes()` keys the next step of a signing chain.

### 4.9 pool

```dart
final class Pool {
  Pool({int limit = 4});   // held lanes, shared by every run() on this pool
  Task<R> run<R>(FutureOr<R> Function() job);     // waits for a free lane, first come first served; & probe watches it
  static Task<List<R>> map<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, int retries = 0, bool isolates = false});   // fail fast
  static Task<List<Outcome<T, R>>> settle<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, int retries = 0, bool isolates = false});   // never throws
}
sealed class Outcome<T, R> { T get item; }
final class Done<T, R> extends Outcome<T, R> { R get value; }
final class Failed<T, R> extends Outcome<T, R> { Object get error; StackTrace get stack; }
extension Outcomes<T, R> on List<Outcome<T, R>> { List<R> values(); List<Failed<T, R>> failures(); }
```

- Results come in input order. `map` rethrows the first error with its type and stack after the
  jobs in flight finish; `settle` returns one `Outcome` per item, carrying the item, so one failed
  download never kills the other 300 and no try/catch is needed to see which one failed.
- Lanes run on this isolate (I/O; `limit` defaults to 4, and the job may capture a client or a
  bar). `isolates: true` runs `limit` long-lived worker isolates (the core count by default) that
  pull items: the job and items must be sendable; an unsendable one is an `ArgumentError` naming
  the item, while an `ArgumentError` from the job itself stays as it is.
- `retries:` re-runs a failing job with the shared jittered backoff; a job paces itself with
  `await rate.wait()` (or the client's `rate:`).
  A shell's exit, a 5xx, a browser or network failure is retried; a bug (`Error`), bad data
  (`ContentException`), TLS, an HTTP 4xx (but 408/429), a logged-out session or a refused proxy
  login fails at once. An exception says whose fault: data → `ContentException`, the network or
  the disk → an `IOException`.
  Together they replace hand-written retry loops around shells, browsers and flaky I/O.
- Both are `Task`s counting the jobs done, success or failure: `Pool.map(urls, fetch) &
  Console.bar('pages')`. Probes nest: a bar per file inside the job, one over the pool outside.
- A held `Pool(limit: 8)` is one limit across calls that start at different times (a download
  queue fed by several crawlers): `lanes.run(() => save(f))` waits for a lane and frees it on
  success or failure. Inside `Pool.settle(files, (f) => lanes.run(…), limit: files.length)` the
  outcomes still come per item.
- Nothing stays running between calls, and an idle pool holds nothing, so there is nothing to close.

```dart
final done = await (Pool.settle(files, (f) => cdn.get(f.url) > f.to) & Console.bar('files'));
for (final Failed(:item, :error) in done.failures()) Console.log('✗ ${item.to.name()}: $error');
final thumbs = await Pool.map(paths, makeThumb, isolates: true);
```

### 4.10 cli

```dart
sealed class Param<T> {}                                   // read back with context(param) as a T
final class Flag extends Param<bool> { Flag(String name, String help, {String? short, bool or = false}); }
final class Opt<T> extends Param<T> { Opt(String name, String help, {String? short, T? or, bool required = false, String? env, T Function(String)? parse, List<T>? values, T? min, T? max}); } // env: the variable read when the flag is absent
final class Multi<T> extends Param<List<T>> { Multi(String name, String help, {String? short, List<T> or = const [], T Function(String)? parse, List<T>? values}); }
final class Arg<T> extends Param<T> { Arg(String name, String help, {T? or, bool required = false, T Function(String)? parse, List<T>? values}); }
final class Rest<T> extends Param<List<T>> { Rest(String name, String help, {bool required = false, T Function(String)? parse, List<T>? values}); } // the positionals after the Args, declared last
final class Command {
  Command(String name, String help, {List<Param<Object?>> params = const [], List<Command> commands = const [],
      FutureOr<void> Function(Context context)? handler, List<String> aliases = const [], String? dotenv, String? version});
  Future<int> run(List<String> argv);                     // sets exitCode: 64 usage, 1 failure (also returned)
}
final class Context { T call<T>(Param<T> param);  String usage(); }
final class UsageException extends ToolkitException { const UsageException(String message); }
```

- **The type comes from the definition.** `Opt<int>('port', …, or: 8080)` reads as `int`, and
  `Opt<String?>('out', …)` reads as `String?`. A non-nullable `T` without `or` or `required` is an
  `ArgumentError`. Built-in `T`s are `String`, `int`, `double`, `num`, `Duration`, `DateTime` and
  `Uri`; anything else needs `parse:`. `values: Section.values` takes one of a fixed set, by
  (enum) name, case-insensitive; usage shows `<photos|reels>` and a typo suggests the closest.
  `min:`/`max:` bound a value that orders (`Opt<int?>('quality', …, min: 1, max: 100)`; usage shows
  `[1-100]`, `150` is a usage error). Yes/no is always a `Flag`. `Multi<T>` reads as `List<T>`; with `values:` one occurrence may list several, comma-separated.
  The positionals after the `Arg`s go to a `Rest<T>` (`<file>...` in usage, `List<T>`); one that
  nothing takes is an error.
- `version: '1.2.3'` makes `--version` print `name 1.2.3` and exit 0, in every subcommand too.
- `dotenv: '.env'` loads `KEY=VALUE` lines (`#` comments, `export `, quotes) before parsing, so an
  `Opt(env:)` sees them; the real environment always wins, and a missing file is skipped.
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
  - A handler's `UsageException` is a 64, and any other `Exception` prints its message (every line) and is a 1:
    a toolkit error prints its `message`, a plain `Exception('…')` prints without the prefix, so
    `throw Exception('User not found')` is how a script fails.
  - An `Error` (a bug) propagates with its stack trace.

```dart
final verbose = Flag('verbose', 'Print every request.', short: 'v');
final out = Opt<String>('out', 'Output folder.', short: 'o', or: 'out');
final url = Arg<String>('url', 'URL to fetch.', required: true);
await Command('fetch', 'Fetch pages.', params: [verbose, out], commands: [
  Command('get', 'Fetch one URL.', params: [url], handler: (c) => fetch(c(url), c(out), c(verbose))),
]).run(argv);
```

### 4.11 console

```dart
abstract final class Console {
  static Future<String> ask(String question, {bool secret = false, String or = '', Duration? timeout}); // empty, EOF, timeout: or
  static Future<bool> confirm(String question, {bool or = false, Duration? timeout});
  static Future<T?> choose<T>(String question, List<T> items, String Function(T item) label, {T? or, Map<String, T>? keys, Duration? timeout});
  static Future<String> key(String prompt, {String? or, Duration? timeout});   // '' = no prompt
  static Bar bar(String label, {int? total, bool keep = true});   // a probe: work & Console.bar('build'); keep: false vanishes when done
  static Writer out();  static Reader input();                    // our stdout and stdin, so a script can be a filter
  static void log(String line, {bool failed = false});   // prints above a live bar; ✗ when failed; kept for logged()
  static Reader logged();                          // the run's log, timed: Console.logged() > Fs.file('run.log')
  static void table(List<List<Object?>> rows, {List<String>? header});   // aligned columns on stdout
  static void notify(String message);              // OSC 9/777 + bell; through the app inside Tui.run (silent while focused)
  static void copy(String text);                   // OSC 52; through the app inside Tui.run
}
final class Bar with Probe implements Closeable { Bar tick([int count = 1]);  Bar update(int done, int? total); }
```

- Everything goes to stderr, so stdout stays clean for data.
- Prompts are asynchronous: timers, downloads and bars keep running while one waits. Ctrl-C at a
  prompt restores the terminal and exits with 130.
- **A closed stdin is not an error.** `ask` gives its `or` (`''` by default) and `choose` its `or` (null without one), and so
  does an `ask` whose `timeout:` passes (its reader is stopped, so the script can still exit; an
  outer `.timeout()` would leave it waiting);
  `confirm` gives its `or` (false by default); the same goes for Escape in a Tui popup. An empty
  line also gives `ask` its `or`. The hint shows it: `Name? [Ada]`, `Sure? [y/N]`.
- `confirm` takes y/yes/n/no, and Enter gives `or`. On a terminal, `choose` uses the arrow keys,
  scrolling when the choices outnumber the rows. Piped, it reads a number.
- **Every prompt takes `or:` and `timeout:`**: no answer in time gives `or`, and the reader stops,
  so an unattended script never hangs on a `confirm`.
- **Live lines** (any number of bars at once, stacked one row each; a finished one
  prints its final `✓`/`✗` line above the rest):
  - It always fits the terminal width, which is re-read on resize. The label is cut with `…`, the
    bar shrinks, and every redraw clears to the end of the line.
  - It redraws at most every 80 ms.
- A prompt or `table` erases the live lines while it writes, and they come back after it.
- **A bar is a probe.** `work & Console.bar('label')` shows the run: a flow in sizes and a rate
  (`12.1/40 MB  1.2 MB/s`, the total learned from the source), an encode in media time
  (`1:12/4:30  3.4×`), a `Task` in items (`12/40  3.1/s`), and a plain future as a spinner until it
  completes (`✓ label`). Bytes a resumed download replays from its `.part` fill the bar but not the
  rate. The rate is the speed now: 100 ms steps smoothed over about a second, not a long average.
  Used by hand, `tick()`/`update()` count items towards `total:`. The bar renders as a clean line
  track (`━━╸──`), matching the `tui` aesthetic. It closes itself when the runs it watches end (✗
  when one failed) or a hand count reaches its total; `close()` prints the final line early.
- A bar takes the live line when made and gives it back when it closes, or when its run fails at
  any point.
- Without a terminal, or with `NO_COLOR` set, there is no animation: each bar or spinner prints
  one final line.
- **`Console.out()` and `Console.input()`** are stdout as a `Writer` and stdin as a `Reader`:
  `await (Console.input() | Shell.filter(['sort']) > Console.out())`. Live bars step aside while
  `out()` writes to the same terminal.
- Progress drawn by hand (a Tui) uses core's `Meter`: `get(u) & meter > file`, then
  `r.bar(meter)`.

### 4.12 tui

```dart
abstract final class Tui {
  static Future<S> run<S>(S state, Screen Function(S state, App<S> app) screen,
      {Color? accent});   // null = monochrome (bold/dim/reverse only); an accent adds colour
}
final class App<S> {
  void go(S state);  void status(String message);
  void quit();                                     // run() returns the state; never exit() (raw tty under ssh -t)
}
final class Screen {
  Screen(void Function(Region r) draw, {String? title, String? status, Map<String, Binding> keys = const {}});
}
typedef Binding = (String label, FutureOr<void> Function() action);
final class Pick<T> {                       // a list's items and selection; O(1) amortised append
  Pick([List<T> items = const []]);
  List<T> items();  int index();  T? selected();  Pick<T> set(List<T> items);  Pick<T> select(int index);
  Pick<T> add(T item);   // filter or remove with set([...])
}
final class Field {                          // an editor's text, cursor and history
  Field({String text = '', List<String> history = const []});
  String text();  List<String> history();  Field set(String text);  String submit();
}
final class Scroll { Scroll({bool follow = true}); }
// Every drawing method also takes write's {Color? color, Color? background, Set<Style> style}, and
// the ones without their own mouse handling (write markdown diff box bar spin) take
// {Map<String, Binding>? on}, bound to what they drew (a box: its header row).
final class Region {
  int width();  int height();  bool hovered();
  Region write(String text, {String? link, bool inline = false});   // inline: the next write continues the row
  Region markdown(String source);  Region diff(String before, String after, {Color? removed, Color? added});
  Region box(String title);  List<Region> rows(List<int> sizes);  List<Region> cols(List<int> sizes);
  Region lines(int count, void Function(Region row, int i) line);  // in a scroll: only the lines in view draw
  Region tabs<T>(Pick<T> tabs, String Function(T tab) label, {Color? highlight});  Region scroll(Scroll scroll);
  Region popup(String title, {int width = 40, int height = 10});
  Region on(Map<String, Binding> events);                      // the rest of the region
  Region list<T>(Pick<T> selection, String Function(T item) label, {String empty = '', Color? highlight});
  Region table<T>(Pick<T> selection, List<String> Function(T item) cells, {List<String>? header, String empty = '', Color? highlight});
  Region input(Field field, {String hint = '', int lines = 1, FutureOr<List<String>> Function(String word)? suggest, FutureOr<void> Function()? onSubmit});
  Region button(String label, FutureOr<void> Function() action);
  Region bar(Meter meter, {String? label});   // its count, total and rate in its unit; Meter()..update(done, total) for a count
  Region spin(String label, {DateTime? since});
  Region bars();                                // every live Console.bar a row (✓/✗ for 2 s once ended)
  Region log({bool Function(({DateTime at, String text, bool failed}) line)? only, Color? color, Color? failures});
}
final class Color {                            // black red green yellow blue magenta cyan white gray orange
  factory Color.index(int index);  factory Color.rgb(int r, int g, int b);   // 0–255, else ArgumentError
}
enum Style { bold, dim, italic, underline, strike, reverse }
```

`r.picture(await image.pixels(width: 80))` draws an image in half-block cells; `tui` and `image` never load each other (they share a private pixel interface).

- **Events on what was drawn.** `on:` on `write`, `markdown`, `diff`, `bar`, `spin` and `box` (its
  header row) binds a `Binding` map, as `Region.on` does for the rest of a region; interactive
  widgets (`list`, `table`, `tabs`, `input`, `button`) handle the mouse themselves.
- **Colour everywhere.** Every drawing method takes the same `color`, `background` and `style` as
  `write` (a box or popup paints its border and title; markdown and diff take them as the base,
  diff's `removed`/`added` replace red and green). `highlight` backs the selection of `list`,
  `table` and `tabs`; it defaults to `accent`, which also colours the title row. Without any, the
  look is monochrome and shared with `Console`:
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
  - `scroll`: the wheel, and when focused the page keys; a scrollbar when it overflows, which a click jumps and a drag moves. With
    `follow`, it stays at the end as content grows; scrolling up unpins, `end` re-pins.
  - `input`: text and bracketed paste; `backspace`/`delete` by grapheme, `ctrl+w`/`alt+backspace`
    by word, `ctrl+u`/`ctrl+k` to the line's start/end; `left` `right` `home` `end` `ctrl+a`
    `ctrl+e`, `alt+`/`ctrl+left`/`right` by word. `lines > 1` grows to that many rows (`0` = no
    cap); `shift+enter`, `alt+enter` or `\` + `enter` insert a newline; `up`/`down` at the first or
    last line walk the history. `onSubmit` handles form submissions; when omitted, unconsumed
    `enter` bubbles to `keys`. `suggest` opens a popup of matches for the word at the cursor.
  - `on`: a region binding a keyboard key is focusable; `hovered()` draws its state.
- **Focus** is object identity (the `Pick`/`Field`/`Scroll`, the `on` key set, a button's label),
  so it survives redraws and state switches. When the focused thing isn't drawn, the first
  focusable one is. A focused list uses the accent, unfocused dim reversed; a focused input shows
  the hardware cursor.
- **Handlers** may be sync or async, and every event runs one, even while an earlier run is
  pending. An `Exception` from a handler, or from work it started, shows as `✗ <message>` in
  the status row (no SDK prefix) and the app keeps running; its stack prints to stderr after the
  terminal is restored. An `Error` ends `run` and is rethrown.
- **Rows.** `title` is the top row, in the accent. The bottom status row shows, on the left, the
  error, the `app.status` message, running spinners and bars, or else the screen's `status`; on the right, the key
  help from `keys:` (`enter send · esc interrupt`), with empty labels and mouse/lifecycle bindings
  hidden. A narrow row cuts the help first.
- **Console inside the Tui.** While `run` is active, `Console.bar` (and a probe on any work) draws in the screen's
  `bars()` region, a row each, and `Console.log` in its `log()` region; a screen that draws neither
  keeps them in the status row (several bars at once). A script watches work the same way with and
  without a Tui, and without a terminal both print. `Console.ask`/`confirm`/`choose` open a modal popup, where
  `escape` answers like a closed stdin.
- **Drawing.**
  - `write` wraps at the edge, `\n` breaks, `\t` expands, controls show as `�`, and text past the
    last row ends with `…`. Widths follow grapheme clusters: CJK and emoji take 2 cells, combining
    marks and ZWJ 0. `link` makes an OSC 8 hyperlink. `inline: true` leaves the row open, so the
    next `write`/`bar`/`spin` continues after its last cell (spans in different styles, no column
    maths); any other drawing starts below.
  - `markdown`: headings, nested and numbered lists, quotes, box-drawn tables, `---`; bold,
    italic, strike, `code`, links; fenced code plain, in the accent (dim without one). Safe to stream: an unclosed fence or emphasis
    renders as closed. Layout is cached by `(source, width)`.
  - `diff`: a Myers line diff in unified hunks with 3 context lines, gutter line numbers, and
    `-`/`+` rows on red/green with the changed words of paired lines brighter.
  - `rows`/`cols`: a size above 0 is fixed, 0 shares what is left. `box(title)` borders the rest
    and returns the inside. `popup` is drawn last, centered. `bar` lays out like `Console.bar`.
    `bar` keeps to one row (the bar shrinks, then the label is cut) and with `rate:` shows it;
    `spin(since:)` says the time as `Duration.human()` does.
    `scroll` lays out its content once per redraw and paints only the viewport.
  - Colours are downgraded to the terminal's level (truecolor → 256 → 16). `NO_COLOR` drops them
    and keeps styles. `LANG=C`/no UTF-8 switches boxes, bars and spinners to ASCII.
- **Key names**, shared with `Page.press`:
  - printable characters as themselves, plus `'space'`;
  - `'enter'` `'tab'` `'shift+tab'` `'backspace'` `'escape'` `'insert'` `'delete'`;
  - `'up'` `'down'` `'left'` `'right'` `'home'` `'end'` `'pageup'` `'pagedown'`, `'f1'`…`'f12'`;
  - `ctrl+`/`alt+`/`shift+` prefixes (`'ctrl+c'`, `'alt+x'`, `'ctrl+up'`).
  - Unknown sequences are ignored, never reported as `escape`; a lone ESC is `escape` after 50 ms, and a
    split sequence or character (a UTF-8 lead byte over SSH) is held up to 1 s, never `escape`.
    `Console.key`/`choose` read keys by the same rule.
- **Terminal life:**
  - `run` enters raw mode, the alternate screen and mouse reporting, turns
    autowrap, bracketed paste and focus reports on and off, and restores the terminal when the
    app quits or throws, on Ctrl-C, on SIGTERM/SIGHUP, and on an uncaught error in work the app
    started (rethrown from `run`). On macOS and Linux, Ctrl-Z suspends and resumes with a full repaint; on Windows only Ctrl-C ends the app.
  - A resize repaints every cell. Frames use synchronized output, so nothing tears. A left drag
    selects text (within the scroll it starts in, else whole rows), drawn reversed until the
    next click, and letting go copies it (OSC 52, `copied N characters`); a drag on a scrollbar
    scrolls instead. Shift-drag still selects natively.
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
      'enter': ('search', () async => s.hits.set(await (search(s.query.text()) & Console.bar('searching')))),
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
enum ImageFormat { png, jpg, gif, bmp, tiff, ico, webp, avif, heic }
final class Image {
  static ImageFormat? sniff(List<int> bytes);     // header only; .name is the extension
  static Future<Compression> compress(String path, {int quality = 80});   // Compressed(before, after) | Kept(reason)
  int width();  int height();  ImageFormat format();
  Image resize({int? width, int? height});  Image crop(int x, int y, int width, int height);
  Reader encode(ImageFormat format, {int quality = 90});
  Future<Pixels> pixels({int? width, int? height});
}
extension on Reader { Future<Image> image(); }   // bytes: Reader.of(bytes).image()
```

- Engine: ffmpeg (see [Native tools](#native-tools)). `image()` on a file reads it in place; any
  other reader is written to a temp file once. Nothing is held in memory.
- `image()` reads the header only (Dart for JPEG/PNG/GIF/WebP/BMP, ffprobe for the rest, HEIC
  tile grids included), with the EXIF orientation applied. Unknown bytes, or a declared size over
  16384², are a `ContentException`.
- `resize`/`crop` record a step; `encode` (a lazy `Reader`) runs them all in one ffmpeg call. `resize`
  keeps the aspect ratio when one side is given; a missing or non-positive size is an `ArgumentError`,
  `crop` outside the image a `RangeError`. `quality` (1–100) applies to JPEG, WebP and AVIF. `.heic`
  (read only) and `.ico` above 256 px are an `ArgumentError`.
- `compress` re-encodes a file in its own format and replaces it atomically only when ≥ 5% smaller,
  returning `Compressed(before, after)`; `Kept(reason)` leaves it alone and says why (`KeptReason.unknown`
  not an image, `.lossy` animated/CMYK/HEIC, `.notSmaller` no gain; `text()` in words, on the result and on `reason`). JPEG
  EXIF and ICC survive (orientation reset), a lossless WebP stays lossless.
- `pixels` decodes RGB for `Region.picture`: `r.picture(await img.pixels(width: 80))`.

### 4.14 video

```dart
enum VideoFormat { mp4, webm, mkv, mov, avi, m4a, mp3, opus }   // avi read only; m4a/mp3/opus audio only
enum VideoCodec { h264, h265, av1, vp9 }
final class Video {
  static Future<Video> open(String source, {String? audio, Map<String, String>? headers});   // a URL (HLS/DASH); a file is file.video()
  static VideoFormat? sniff(List<int> bytes);     // HEIC/AVIF photos are not video
  static Task<Compression> compress(String path, {int quality = 70});   // a probe sees media time
  int? width();  int? height();  Duration duration();  double fps();
  VideoFormat? format();  String? codec();  String? audioCodec();  int? bitrate();
  Reader encode(VideoFormat format, {int? quality, int? width, int? height, VideoCodec? codec,
      Duration? start, Duration? end});   // a probe on it sees the encode in media time
  Future<Image> frame({Duration at = Duration.zero});
}
extension on Reader { Future<Video> video(); }
```

- Probing is ffprobe's JSON: size as displayed (rotation applied), codecs, bitrate. A file is read in
  place; other readers go to a temp file once.
- `encode` with no `quality`/`width`/`height`/`codec` **copies** the streams into the new container
  when it holds them (seconds, lossless; `start`/`end` cut at keyframes); otherwise it encodes (default
  h264, VP9 for WebM; `quality` 1–100 maps to the codec's CRF). Audio is copied when the container takes
  it, else AAC (Opus for WebM). `encode(…) & Console.bar('encode') > file` shows the encode itself
  (`1:12/4:30  3.4×`), not the copy that follows it.
- `compress` follows `Image.compress`: own container, audio copied, replaced only when ≥ 5% smaller.
- `open(url, audio:, headers:)` reads HLS/DASH manifests and joins a separate audio source; a path
  is an `ArgumentError` (read a file with `Fs.file(path).video()`). `format()` is the container
  read (null for a live stream).

### Native tools

`image` and `video` run ffmpeg/ffprobe 9.0.2, `archive` runs 7-Zip 26.04, all through `shell`
(Ctrl-C ends them). A copy on PATH is used when it has the encoders a call needs; otherwise a static
build pinned by sha256 is downloaded once into the user cache (ffmpeg: Martin Riedl's builds for macOS
and Linux, Gyan's for Windows; 7-Zip: its own release, `7zr.exe` on Windows), one process at a time.
At most half the cores' worth of encodes run at once.

### 4.15 csv

```dart
abstract final class Csv {
  static List<List<String>> parse(String text, {String sep = ','});
  static String encode(List<List<Object?>> rows, {String sep = ','});
}
extension on Reader { Future<List<List<String>>> csv({String sep = ',', List<List<String>>? or});  Stream<List<String>> rows({String sep = ','}); }
```

- RFC 4180: quoted fields, `""` escapes, CRLF or LF, embedded newlines, a leading BOM; a blank
  line is no row. An unterminated quote is a `ContentException`. `encode` writes CRLF and quotes
  only what needs it. `rows()` streams the rows as the bytes arrive, in constant memory. Rows
  keyed by the header are `final [keys, ...rows] = Csv.parse(t)` and a map per row.

### 4.16 yaml

```dart
abstract final class Yaml { static Json parse(String text); }
extension on Reader { Future<Json> yaml({Json? or}); }
```

- The reader is in-house: block and flow collections, plain, quoted and block scalars, anchors
  and aliases, scalar tags (`!!str`, `!!int`, …) and the YAML 1.2 core schema (`~`/`null`,
  `true`/`false`, `0x`/`0o` ints, `.inf`/`.nan`). The first document of a stream becomes the
  same `Json` value (`$`, `or`, `text`), with aliases shared; `<<` merge keys are not YAML 1.2.
- A parse error is a `ContentException` naming the source (a URL redacted) and line. Read only:
  edits to `pubspec.yaml` are text replacements that keep comments.

## 5. Errors

Failures the toolkit itself detects are one family rooted at `ToolkitException`
(`message` plus the engine error as `cause`, null when detected alone), so
scripts match the specific type — or the base for all of them — instead of
parsing message strings. Each custom type extends the SDK exception it replaces,
so an existing `on HttpException` / `on FormatException` / `on ProcessException`
keeps catching it. None is an `Error`: an `Error` is a bug.

| Thrown                      | When                                                                                                                                                                                                                                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HttpStatusException`       | a non-2xx status surfaced by `check` or by piping its body (`status` `method` `url` `snippet`); extends `HttpException`                                                                                                                                                                               |
| `HttpRequestException`      | a request aborted by `close()` or a redirect that cannot be followed (`method` `url` `reason`); extends `HttpException`                                                                                                                                                                               |
| `ContentException`          | invalid content the toolkit rejects (JSON, selectors, archives, images, checksums); extends `FormatException`                                                                                                                                                                                         |
| `PasswordException`         | an encrypted archive with no or the wrong password; extends `ContentException`                                                                                                                                                                                                                        |
| `ExitException` (shell), `LockedException` (fs) | a program that exited non-zero under `check()`, as a read or as a filter; a lock another holder keeps |
| `BrowserException`          | a tab action the page itself fails (click, PDF, download); a `ToolkitException`                                                                                                                                                                                                                       |
| `UsageException` (cli)      | a handler rejects its input, giving exit 64                                                                                                                                                                                                                                                           |
| `ToolkitException`          | the base of the ones above                                                                                                                                                                                                                                                                             |
| SDK types (kept on purpose) | engine failures pass through (`SocketException`, `TlsException`, `ProcessException`, `FileSystemException`, `StdinException`/`StdoutException`); Dart-idiom guards stay (`ArgumentError`/`RangeError` for bad arguments, `StateError` for protocol misuse, `TimeoutException` for waits that run out) |

Engine exceptions are rethrown as one of these, naming the subject. An error inside a pipeline
surfaces from its `>`, after cleanup. An error in a chain surfaces at its single `await`.

## 6. Performance and testing

- Pipelines stream 64 KiB chunks with backpressure, so a 10 GB download, hash and save runs at
  constant memory in one pass. `text()`/`bytes()`/`html()`/`json()`/`image()` load everything into
  memory, and are meant for documents.
- Lazy content (`screenshot` `pdf` `encode` `archive`) does no work until it is read. A Future mirror
  costs one `await`.
- An engine stays until an A/B measurement (alternating rounds, medians, from one sitting) shows it
  is the bottleneck. A module compiles only its own engine.
- Each module has one test file, with a test per listed member and per mirror. Tests use real
  resources: a loopback server, temp folders, Chromium, a pseudo-terminal for `console`/`tui`, and
  real `sh`/`grep`.
- Every fixed bug keeps a regression test.

## 7. Not included

Native code and codegen; test seams in the public API; sync twins and aliases; fan-out to several
writers; an option-object for http settings (named parameters plus `copy()`); string commands for
`Shell.run`; auto-sanitising `Dir.file`; stealth/anti-bot evasion, HTTP/2, brotli, a crawler,
scheduler or job queue; browser interception beyond `block` and `responses`, frames
and `hover`; colours outside the TUI; a TUI widget tree (widget state lives in
`Pick`/`Field`/`Scroll`); terminal images beyond half-blocks (Sixel, kitty), `ctrl+r` history search
and vim mode in `input`; torrents. Each comes back only when a real script needs it.
