# dart_toolkit

**Write the script you would write in a shell, in Dart, with types.** dart_toolkit is sixteen
small modules for command-line automation: fetch, drive a browser, move files, run
programs, archive, hash, prompt, and draw a terminal UI. Each module is a thin facade over a good pub
engine, and every module speaks the same four interfaces, so the bytes flow between them like a
pipe in a shell.

```dart
final http = Http.client(retries: 3, check: true);
final title = await http.get('https://example.com').html().$('title').text();
final port = await Fs.file('conf.json').json().$('server.port').or(8080);
await (Fs.file('photo.jpg').image().resize(width: 800).encode(.jpg) > Fs.file('thumb.jpg'));

final iso = await http.get(isoUrl), hash = Hash.sha256();
await (iso | Console.bar(iso.size(), label: iso.name()) | hash > Fs.file(iso.name()));
await http.post(api, body: .json({'sha256': hash.hex()}));

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
| 2   | **Values are `final class`es with private constructors and private fields.** Every read is a method (`status()`, `text()`), never a getter or a public field. The exceptions are the unit literals `3.seconds`, `1.5.minutes` (`Durations` on `num`), which spell a constant, and `DateTime.format(…)` / `Duration.human()` (`Times`, `Spans`), which render a value for a person; none reads toolkit state. Each library doc says `Public surface is exactly: …`.                     |
| 3   | **Short names, one meaning each.** One word when it reads one way, dropping a suffix the receiver already says (`status()` not `statusCode()`, `hex()` not `hexDigest()`). The same idea has the same name in every module (§3), and options too (`limit:`, `dir:`, `cache:`, `or:`). One method with an optional argument beats two. No abbreviation a reader must decode (`markdown`, not `md`). The only symbols are `$` (query), `[]` (index), `\|` (pipe through) and `>` (pipe into). |
| 4   | **Chains never need an inner `await`.** Every async value type has a Future mirror: an extension on `Future<T>` that repeats `T`'s members. Mirrors are named `<Type>Future`, because Dart hides unnamed extensions outside their library; nobody writes that name. |
| 5   | **Actions return their receiver** (`page.fill(…).click(…)`). An action that makes something new returns that instead (`copy`, `download`). Readings return data. `close()` and `delete()` return nothing.                                      |
| 6   | **Content leaves as a `Reader` and arrives through a `Writer`.** No method takes an output path: screenshots, PDFs, encoded images, archives and downloads are all `Reader`s, stored with `> Fs.file(…)`.                                         |
| 7   | **Outcomes are values; only failing to reach throws.** A 404 is a `Response`, a non-zero exit is an `Output`, malformed HTML still parses, a missing path is `null`. What throws is the network, the disk, a program that won't start, a wait that runs out. |
| 8   | **Never null for collections, nullable for single lookups.** No match gives an empty `Elements`; a missing attribute, header or option gives `null`.                                                                                     |
| 9   | **In memory is sync, I/O is async.** There are no sync twins.                                                                                                                                                                        |
| 10  | **Inputs are positional, options are named and optional** with defaults. There are no option objects, builders, or flags that change the result type. In-memory data is a `String` (UTF-8) or a `List<int>`.                               |
| 11  | **Types over runtime checks.** Generics carry the value type (`Opt<int>`, `value<T>()`, `Pool.map<T, R>`), sealed types make `switch` exhaustive (`Entry`), and `Object` parameters are kept to data and `body:`.                                     |
| 12  | **`close()` releases a resource and is idempotent.** Whatever holds a process, socket, terminal or isolate cleans up on `close()`, on an error, and on Ctrl-C. Nothing keeps a finished script alive.                                    |
| 13  | **Engines stay private and swappable.** An engine type never appears in a public signature, and engine exceptions are rethrown as Dart's own (§5). Tests use real servers, files, browsers and pseudo-terminals, never the engine, so a swap is proven by the same suite. |
| 14  | **No code generation, no native code.** Dart 3.10+ (dot shorthands: `encode(.jpg)`, `archive(paths, format: .tgz)`).                                                                                                                           |

## 2. Core: Reader, Writer, Pipe, Closeable

`core.dart` is re-exported by every module except `cli` and `tui`, which never use it.

```dart
abstract mixin class Reader {                     // bytes you can read; implement stream()
  Stream<List<int>> stream();
  Future<List<int>> bytes();
  Future<String> text();                          // UTF-8, malformed bytes replaced
  Stream<String> lines();                         // the same, line by line as it arrives
  Reader pipe(Pipe? pipe);       Reader operator |(Pipe? pipe);         // lazy; null = skip
  Future<void> to(Writer? w);    Future<void> operator >(Writer? w);    // run; null = discard
  Origin origin();                                // where the bytes came from (the base for `html()`)
  static Reader of(List<int> bytes);
}
abstract mixin class Writer { Future<void> consume(Stream<List<int>> input);  Origin origin(); }   // origin: a File's path
final class Cookies {                             // the jar chrome produces and http consumes
  Cookies();  static Cookies parse(String text);  String encode();   // JSON lines: name value domain path expiry secure
  String? operator [](String name);  String? header(String url);  Cookies set(String name, String value, {required String url});
}
final class Rate { Rate(int count, Duration per, {Duration pause, void Function(Duration)? onWait});  Future<void> wait(); }
extension Durations on num { Duration get milliseconds, seconds, minutes, hours, days; }   // 3.seconds, 1.5.minutes
abstract mixin class Pipe { Stream<List<int>> transform(Stream<List<int>> input);  void abort(Object error) {} }
abstract interface class Closeable { Future<void> close(); }
final class Origin { const Origin({String? url, int? status, String? name, String? path});  String? url();  int? status();  String? name();  String? path(); }
```

| Type                                     | Reader | Writer | Pipe | Closeable |
| ---------------------------------------- | :----: | :----: | :--: | :-------: |
| `Response` (http)                              |   ✓    |        |      |    ✓     |
| `File` (fs)                              |   ✓    |   ✓    |      |           |
| `Output` (shell), `Download` (chrome)    |   ✓    |        |      |           |
| `page.screenshot()` `pdf()`, `image.encode()`, `Archive.archive()` | ✓ |  |  |   |
| `Archive.unarchive(dir)`                    |        |   ✓    |      |           |
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
- Extending takes one class with one member: `with Reader` + `stream()`, `with Writer` +
  `consume()`, `with Pipe` + `transform()`.
- `Cookies` and `Rate` live in core because two modules share them: chrome produces a jar and
  http consumes it; http and pool both pace with a `Rate`.

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
| release / remove from disk / make      | `close()` / `delete()` / `create()`    | `Closeable` / `Entry` / `Dir`, `Link` |
| final URL / HTTP status / 2xx          | `url()` / `status()` / `ok()`          | `Response` (`Page` has `url()`)       |
| a file name / a size in bytes          | `name()` / `size()`                    | `Entry`, `Download`, `Response` / `File`, `Response` |
| run a program, an app, a CLI / jobs    | `run` / `map`, `settle`                | `Shell`, `Tui`, `Command` / `Pool`            |
| download to a file (skip, resume)      | `get(u) \| … > file` with `resume: true` | `Client`                                     |
| a unit of work: queue more / give back | `add` / `emit`                         | `Visit` (scrape)                              |
| run a body with a resource, then free  | `temp((dir) …)` / `lock(() …)`         | `Fs` / `File`                                 |
| a variant with other settings          | `copy(...)`                            | `Client`                                      |
| a key                                  | `press(key)` sends, a `keys:` binding handles; one key-name set (§4.12) | `Page`, `Screen` |
| draw or store into                     | `write`                                | `File`, `Region`                              |
| dimensions                             | `width()` `height()` / `width:` `height:` | `Image`, `Region` / `open`, `resize`, `popup` |
| the function that does the work        | `handler`                              | `Command(handler:)` |
| a notification / a bound event         | `on…:` / `on(events)`, `keys:`         | `onDone:`, `onWait:` / `Region`, `Screen`     |
| a value when the source is missing     | `or:`                                  | `File.text/bytes`, `json()`, `Opt`, `Json.or` |
| switch the current state               | `go(state)`                            | `App`                                         |

Named parameters, each with one meaning: `headers` `body` `timeout` `base` `headless`
`path` `profile` `proxy` `block` `width` `height` `fullPage` `dir` `env` `recursive`
`json` `pretty` `limit` `retries` `insecure` `check` `onDone` `short` `or` `rate` `cookies` `csrf` `cache` `ttl`
`idle` `connections` `isolates` `match` `dotenv` `sep` `resume`
`required` `parse` `params` `commands` `aliases` `handler` `secret` `label` `quality` `color`
`background` `style` `link` `title` `status` `keys` `accent` `hint` `lines` `suggest`
`empty` `header` `prompt` `onSubmit` `since` `history` `query` `live` `onLine`
`password` `format` `expect` `from`.

## 4. Modules

| Import    | Public surface (core members and Future mirrors not repeated)                                                                                     | Engine                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `core`    | `Reader` `Writer` `Pipe` `Closeable` `Origin` · `Cookies` `parse` `encode` `[]` `header` `set` · `Rate` `wait` · `Durations` (`3.seconds`)      | in-house              |
| `html`    | `Html.parse` · `Reader.html` · `Elements` `$` `[]` `not` `text` `texts` `attr` `attrs` `json` `table` `form` · `Element` `$` `not` `text` `attr` `parent` | in-house HTML5 parser and selectors |
| `http`    | `Http.client` `pool` `serve` · `Client` `copy` `cookies` `get` `head` `delete` `post` `put` `patch` `close` · `Response` `status` `ok` `check` `header` `url` `size` `name` · `Body` `text` `bytes` `form` `json` `stream` | `dart:io`             |
| `chrome`  | `Chrome.launch` `connect` · `Browser` `open` `pages` · `Page` (below) · `Download` `name` · `Capture` `status` `url` `header`                    | `package:puppeteer`   |
| `json`    | `Json.parse` `of` `encode` · `Reader.json` · `Json` `$` `[]` `value` `or` `text` `max` `min` `asList` `asMap`                                     | `dart:convert`        |
| `csv`     | `Csv.parse` `records` `encode` · `Reader.csv`                                                                                                     | in-house              |
| `scrape`  | `Scrape` `run` · `Visit` `item` `add` `emit`                                                                                                     | in-house              |
| `yaml`    | `Yaml.parse` · `Reader.yaml`                                                                                                                       | `package:yaml`        |
| `fs`      | `Fs.entry` `file` `dir` `link` `sanitize` `temp` `home` · `Entry` `path` `name` `parent` `exists` `modified` `delete` `copy` `move` · `File` `write` `append` `size` `lock` `text(or:)` `bytes(or:)` · `Dir` `file` `dir` `list(match:)` `watch` `create` · `Link` `target` `resolve` `create` | `dart:io`, `path` |
| `shell`   | `Shell.run` `filter` `open` · `Output` `code` `ok` `err`                                                                                   | `dart:io`             |
| `archive` | `Archive.archive` `unarchive` `gzip` `gunzip` · `ArchiveFormat`                                                                                         | `dart:io` (in-house zip, tar) |
| `hash`    | `Hash.md5` `sha1` `sha256` `sha512` (`expect:`) · `Hasher` `add` `addBytes` `hex` `of`                                                                                        | `package:crypto`      |
| `pool`    | `Pool.map` `settle` · `Outcome` `Done` `Failed` · `values` `failures`                                                                         | `dart:isolate`      |
| `cli`     | `Flag` `Opt` `Multi` `Arg` (sealed `Param<T>`) · `Command` `run` · `Context` `call` `rest` `usage` · `UsageException`                                  | in-house              |
| `console` | `Console.ask` `confirm` `choose` `key` `spin` `bar` `log` `table` `notify` `copy` `clear` `accent` · `Bar` `tick` `setTotal`                                                                                    | in-house              |
| `tui`     | `Tui.run` · `App` `state` `go` `status` `quit` · `Screen` · `Binding` · `Pick` · `Field` · `Scroll` · `Region` (below) · `Color` · `Style` | in-house              |
| `image`   | `Image.decode` `sniff` · `Reader.image` · `Image` `width` `height` `pixel` `resize` `crop` `encode` · `ImageFormat` · `Region.picture`                            | `package:image`       |

A module imports only core and its engine. The exceptions are `chrome`, which imports `html`
for `Elements` and `json` for the `run<T>` coercion rules, and `html`, which imports `json` for
`Elements.json()` (embedded data). `console` and `tui`
share one private terminal layer: stdin, key decoding, signal handling and restoring the terminal.

### 4.1 html

```dart
abstract final class Html { static Elements parse(String html, {String? base}); }
extension on Reader { Future<Elements> html(); }     // base = the response's final URL or the file's URI
final class Elements extends Iterable<Element> {
  Elements $(String selector);  Element operator [](int i);  Elements not(String selector);
  String text();  List<String> texts();  String? attr(String name);  List<String> attrs(String name);
  Json json();                                      // <script type=application/json|ld+json>, __NEXT_DATA__
  List<Map<String, String>> table();                // the first table: header → cell text
  ({String action, String method, Map<String, String> fields})? form();   // the first form, hidden fields included
}
final class Element {
  Elements $(String selector);  Element not(String selector);
  String text();  String? attr(String name);  Element? parent();
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
- With a base, URL attributes (`href`, `src`, `data-src`, `poster`, `action`) are trimmed and
  made absolute.
- Selectors: type, `*`, `#id`, `.class`, attributes (`= ~= |= ^= $= *=`, `i`), the four
  combinators, `:first-child` … `:only-of-type`, `:nth-child(An+B of S)` and friends, `:not`
  `:is` `:where` `:has`, `:empty` `:root` `:link` `:checked` `:disabled` `:enabled` `:lang`.
  Pseudo-elements never match. A selector it rejects is a `ContentException` naming it.
- `$` returns matches in document order without duplicates. On `Elements`, `text()` and `attr()`
  both read the **first** match (`''`/`null` when there is none); for every match use
  `texts()` or `attrs()`. `attrs()` skips missing values.
- `text()` reads like `innerText`, so scraped text needs no `.trim()`. Runs of spaces collapse to
  one space, and a run that holds a newline becomes one newline. The result is trimmed, and
  `<pre>` keeps its whitespace.
- `not` returns a new tree (one O(n) clone, table parts included); the receiver is
  unchanged.
- `json()` parses every embedded-data script into one `Json` list (invalid ones skipped), so
  `page.json().$('**.user')` searches them all. `table()` keys rows by the first row (`colspan`
  repeats). `form()` gives what a login without a browser posts:
  `client.post(f.action, body: .form({...f.fields, 'user': u}))`.

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
      String? proxy, String? cache, Duration ttl = const Duration(hours: 1), List<String> insecure = const [],
      Duration idle = const Duration(milliseconds: 100), int connections = 6});
  static Client pool(List<Client> members);      // also a Client
}
sealed class Client implements Closeable {
  Client copy({…every setting, null keeps it; headers merge…});   // shares jar, Rate and connections
  Cookies cookies();
  Future<Response> get(String url, {Map<String, Object?>? query, Map<String, String>? headers});   // head, delete: the same
  Future<Response> post(String url, {Body? body, Map<String, Object?>? query, Map<String, String>? headers}); // put, patch
  Future<void> close();                           // cancels this client's requests and waits; idempotent
}
sealed class Body {                              // stream: sent once, never retried
  const factory Body.text(String text);  const factory Body.bytes(List<int> bytes);
  const factory Body.form(Map<String, Object?> fields);  const factory Body.json(Object? value);
  const factory Body.stream(Reader reader);
}
final class Response with Reader implements Closeable {
  int status();  bool ok();  Future<Response> check();  String? header(String name);  String url();
  int? size();                                   // content-length, null when unknown or decoded on the fly
  String name();                                 // content-disposition filename, else the URL's last segment
}
```

- **Settings live on the client**, stated once; a request passes only `query`, `headers` and
  `body`. `Http.client()` with no arguments is a new, isolated client (its own jar and sockets);
  an idle client releases its sockets after `idle`, so a finished script exits. `copy(...)` is a
  variant that stays one session.
- `base:` resolves relative URLs. `query` values may be `String`, `num`, `bool`, null (drops the
  key) or an `Iterable` (repeats the key); `Body.form` takes the same map.
- A verb completes when the headers arrive; the body streams. A non-2xx status is still a
  `Response` unless the client says `check: true`; `res.check()` (and `get(u).check()`) throws
  `HttpStatusException('HTTP 404 GET <url>: <snippet>')`.
- Redirects are followed for every verb, as in browsers: 301/302/303 after a POST become a GET,
  and 307/308 keep the method and resend an in-memory body. `url()` is the final URL. A
  cross-origin hop drops credential headers.
- **Only a 2xx body can be piped.** `res > file` on a 404 throws what `check()` throws, so an
  error page is never saved. The readings (`text()`, `lines()`, `json()`, `html()`) work on any
  status.
- **Cookies** live in the client's `Cookies` jar (core; `page.cookies()` produces one).
  `set-cookie` (redirect hops too) updates it; a malformed one skips only itself; `Domain=` needs
  a dot and is never an IP; cookies go out longest path first. A per-call `cookie` header merges
  by name (the caller wins). `csrf: (cookie: 'csrftoken', header: 'x-csrftoken')` copies a cookie
  into a header on every send.
- **Retries** apply only when the request provably was not processed: any in-memory body on
  connect/DNS failures, 429 and 503; GET/HEAD/PUT/DELETE also on timeouts, network errors and
  502/504; never 500/501/505 or TLS. Backoff doubles from 1 s with ±25% jitter; `Retry-After` is
  honoured (capped at 5 min unless the client has a `Rate`, whose 429 waits the window out).
- `rate: Rate(75, 11.minutes, pause: 3.seconds)` paces every send of the clients that share it.
- **Downloads respect the pipe.** With `resume: true`, a GET piped into a file
  (`cdn.get(u) | Console.bar(null) | Hash.sha256(expect: s) > Fs.file(f)`):
  - skips a complete file (same `content-length`, or any file when the server sends none);
  - resumes a `.part` with `Range` when the server answers 206 (anything else restarts);
  - renames the finished file into place.
  Stored bytes replay through the pipes, so a bar counts the whole file and a hash verifies it.
  A pipe that isn't a pass-through (gzip, a filter) downloads from scratch. A transport failure
  keeps the `.part`; any other failure deletes it. The GET is sent at the end of the current
  synchronous block unless such a pipeline claims it, so awaiting it works as always.
- **`Http.serve(handler)`** answers loopback requests until `close()`: `Request` (`method`
  `path` `query(name)` `header`, a `Reader` of the body) → `Reply.text` `.json` `.stream`
  (content-type from a file's name) `.redirect` `.status`. A handler error is a 500, logged.
  It is meant for a CLI OAuth login, a webhook, or a preview; `switch (r.path())` is the router.
- `cache: '.cache'` answers a GET within `ttl` from disk (no network, no `Rate` slot), keyed by
  URL and the request headers the answer `Vary`s on: for developing a scraper.
- `proxy:` is `http://[user:pass@]host:port`; null reads `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`.
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
await (cdn.get(url) | Console.bar(null, label: name) > Fs.dir('imgs').file(name));   // skip, resume, atomic
final server = await Http.serve((r) => Reply.text('code ${r.query('code')}'));
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
  Future<T?> run<T>(String js);  Future<Cookies> cookies();                            // the current URL's jar
  Future<String> cookie(String name, {Duration? timeout});                              // waits until set
  Stream<Capture> responses(String pattern);                                            // XHR/fetch matching a glob
  Future<Page> click(String selector, {Duration? timeout});                             // auto-wait
  Future<Page> fill(String selector, String value, {Duration? timeout});
  Future<Page> select(String selector, String value, {Duration? timeout});
  Future<Page> upload(String selector, Reader file, {Duration? timeout});
  Future<Page> press(String key);  Future<Page> scroll([String? selector, Duration? timeout]);  // auto-waits too; positional: Dart has no optional + named mix
  Future<Page> wait(String selector, {Duration? timeout});  Future<Page> idle({Duration? timeout});
  Reader screenshot({bool fullPage = false});  Reader pdf();                            // captured when read
  Future<Download> download(String selector, {Duration? timeout});
}
final class Download with Reader { String name(); }
final class Capture with Reader { int status();  String url();  String? header(String name); }
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
- `idle` waits for 500 ms with no request in flight. Downloads share one folder per browser, told apart by their DevTools guid, so
  concurrent downloads don't clash.
- `run<T>` awaits promises and reads the result with the `Json.value<T>()` rules (use
  `List<Object?>`/`Map<String, Object?>` for collections). `press` takes the key names of §4.12;
  an unknown name is an `ArgumentError`.
- `chrome` re-exports `html`, so `page.html().$('a')` needs one import.
- **The session is a value:** `cookies()` is a core `Cookies` jar (domain, path, expiry kept), so
  `Http.client(cookies: await page.cookies())` continues the browser session, and
  `file.write(jar.encode())` / `Cookies.parse(...)` persists it. `cookie(name)` waits for a login
  to set it. Closing the window during `cookie()` or `wait()` throws `BrowserException('browser closed')`.
- **The page's data is a stream:** `responses('*/graphql/query*')` yields every XHR/fetch response
  whose URL matches (`*` crosses `/`), while listened to. A `Capture` is a `Reader` with http's
  reading names; its body is fetched as it arrives.
- `Browser.close()` closes every tab and the process; a crash or error never leaves Chromium
  running.

```dart
final page = await Chrome.launch(profile: '.chrome').open(loginUrl, block: ['image', 'font'])
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
  static Json of(Object? value);                  // wrap a value you already hold
  static String encode(Object? value, {bool pretty = false});
  Json $(String path);  Json operator [](int i);
  T? value<T>();  T or<T>(T fallback);           // typed read, null / the fallback when absent or mistyped
  String? text();                                // any scalar as a String; null for null, a miss, a collection
  Json max(num Function(Json item) by);  Json min(num Function(Json item) by);   // a null Json when empty
  List<T> asList<T>();  Map<String, T> asMap<T>();   // empty when missing or mistyped
}
extension on Reader { Future<Json> json({Json? or}); }   // or: when the source does not exist
```

- `$('a.b.0')` walks dotted paths, and a numeric segment indexes an array. A `*` segment maps
  over every item: `$('data.users.*.name').asList<String>()`. A `**` segment searches every
  depth: `$('**.pk')` lists each `pk` in the document (misses dropped). A `|` in a segment tries
  alternatives in order with the rest of the path: `$('code|shortcode')`, `$('pk|id')`. `\*`, `\|`
  and `\.` are literal. A missing path is a `Json` of `null`, never a throw.
- `value<T>()` returns `null` when the value is absent or not a `T`. Integral numbers read as both
  `int` and `double`, so `3`, `3.0`, `value<int>()` and `value<double>()` all agree.
  `$('port').or(8080)` is a non-null `int`. `text()` reads `787132` as `'787132'` (not
  `toString`, which renders JSON). `asList<T>()` and `asMap<T>()` check each element and give
  `[]` / `{}` when missing or mistyped; `value<List<T>>()` throws and points to them.
- `max`/`min` return the extreme item (the first on a tie):
  `v.$('display_resources').max((c) => c.$('width|config_width').or(0)).$('url|src').text()`.
- A `Json` iterates an array's items or an object's values; `toString` is the JSON text and `==`
  is deep.
- `encode` accepts what `dart:convert` accepts (string keys) and throws what it throws.
  Invalid JSON is a `ContentException` naming the source.

### 4.5 fs

```dart
abstract final class Fs {
  static Future<Entry?> entry(String path);   // what is on disk, links not followed
  static File file(String path);  static Dir dir(String path);  static Link link(String path);  // no I/O
  static String sanitize(String name);   // an untrusted title as one portable file name; never leaves its folder
  static Future<T> temp<T>(Future<T> Function(Dir dir) body, {String prefix = 'tmp'});   // deleted after body
  static Dir home();
}
sealed class Entry {
  Future<DateTime> modified();
  String path({Dir? from});  String name();  Dir parent();   // path(from: dir) is relative to dir
  Future<bool> exists();  Future<void> delete();
  Future<Entry> copy(String to);  Future<Entry> move(String to);   // subtypes narrow the return type
}
final class File extends Entry with Reader, Writer {
  Future<File> write(String text);  Future<File> append(String text);  Future<int> size();
  Future<T> lock<T>(Future<T> Function() body, {Duration? wait});   // exclusive OS lock for the body
  Future<String> text({String? or});  Future<List<int>> bytes({List<int>? or});   // or: when it does not exist
}
final class Dir extends Entry {
  File file(String name);  Dir dir(String name);
  Future<List<Entry>> list({bool recursive = false, String? match});  Stream<File> watch();  Future<Dir> create();
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
- `Fs.temp((dir) async {…})` runs the body with a fresh temp folder and deletes it after (Ctrl-C
  too); `file.lock(() async {…}, wait:)` holds an exclusive OS lock for the body, so a second
  cron run fails at once with `locked by another process`. Both are scopes, not handles: nothing
  to forget, nothing keeps the script alive. `Fs.home()` is `HOME`/`USERPROFILE`;
  `modified()` is the mtime. A script that also
  imports `dart:io` adds `hide File, Directory, Link`.

### 4.6 shell

```dart
abstract final class Shell {
  static Future<Output> run(List<String> command, {String? dir, Map<String, String?>? env, bool live = false, bool check = false, Duration? timeout, void Function(String line)? onLine}); // onLine: stdout and stderr lines as they arrive
  static Future<String?> which(String program);   // where PATH (+ PATHEXT) resolves it, or null; starts nothing
  static Pipe filter(List<String> command, {String? dir, Map<String, String?>? env});
  static Future<void> open(String target);    // URL or path, in the default app
}
final class Output with Reader { int code();  bool ok();  String err(); }   // Reader = stdout
```

- `timeout:` kills a run that takes longer (only the child it started) and throws a
  `TimeoutException` naming the command.
- `command[0]` is the program, looked up on `PATH`, and there is no shell, so arguments are safe.
  Use `['sh', '-c', …]` for shell syntax.
- `run` closes stdin and waits for the exit. `text()` drops one trailing newline, as `$(…)` does
  in a shell; `> file` and `bytes()` stay verbatim. A non-zero exit is an `Output`; a program that
  can't start throws `ProcessException`, with the OS error code. An `Output` is in memory, so it
  can be read many times.
- `filter`: the stream goes to stdin and stdout comes out. A non-zero exit fails the run with the
  full stderr. A child that stops reading early (`head`, `grep -m`) is not an error.
- `open` uses `open`/`xdg-open`/`rundll32 url.dll,FileProtocolHandler` (no shell parsing) and returns once the program has launched.

```dart
final head = await Shell.run(['git', 'rev-parse', 'HEAD'], check: true).text(); // a non-zero exit throws
await (Fs.file('big.log') | Shell.filter(['grep', 'ERROR']) > Fs.file('errors.log'));
```

### 4.7 archive

```dart
enum ArchiveFormat { zip, tar, tgz, sevenZip }   // what archive writes; unarchive also reads RAR4/RAR5 and .tar.xz
abstract final class Archive {
  static Reader archive(List<String> paths, {ArchiveFormat format = .zip, String dir = '.', String? password}); // files and folders, named relative to dir
  static Writer unarchive(String dir, {String? password}); // format from the magic bytes
  static Pipe gzip();  static Pipe gunzip();
}
```

- `unarchive` checks every member first: absolute paths, `..` escapes and links are a
  `FormatException`. It then extracts into a temp sibling and moves the members into `dir`,
  **merging with what is already there and never replacing it** (an existing file keeps its
  content and mode; that member is dropped). File modes are kept, so executables still run.
  Damaged archives, bad checksums (zip CRC, RAR5 BLAKE2sp, 7z header CRC) and truncated RAR
  are a `ContentException` naming the member, with the engine error as `cause`.
- `archive` takes files and folders like `zip -r` (`['.']` with `dir:` is a folder's contents),
  refuses links the same as `unarchive`, and an empty folder round-trips in every format.
- `gunzip` checks the gzip trailer. Truncated or corrupt data fails the run with a
  `FormatException`.
- `zip`, 7z and RAR are held in memory (their directory or solid stream needs it all); tar and
  tgz stream member by member. Everything is pure Dart: zip/7z/RAR, LZMA/LZMA2, PPMd and AES are
  in-house; RAR is read-only (its compressor is proprietary).
- `password:` encrypts zip as WinZip AES-256 and 7z as AES-256 with the names hidden; unarchive
  opens zip AES and ZipCrypto, 7z AES and RAR4/RAR5 encryption. A missing or wrong password is a
  `FormatException` before anything lands in `dir`; tar with a password is an `ArgumentError`.

```dart
await (http.get(releaseUrl) > Archive.unarchive('vendor'));
await http.put(uploadUrl, body: .stream(Archive.archive(['.'], dir: 'site', format: .zip)));
```

### 4.8 hash

```dart
abstract final class Hash { static Hasher md5({String? expect}); static Hasher sha1({String? expect}); static Hasher sha256({String? expect}); static Hasher sha512({String? expect}); }
final class Hasher with Writer implements Pipe { Hasher add(String text);  Hasher addBytes(List<int> data);  String hex();  Future<String> of(Reader source); }
// expect: (hex) fails the run at its end, before the writer commits: http.get(u) | Hash.sha256(expect: sum) > Archive.unarchive('opt')
```

- One type has three uses. Incremental: `h.add(a).add(b).hex()`. As a writer: `r > h`. As a
  tee: `r | h > file`, one pass that both stores and checksums.
- `hex()` is final, and an `add` after it is a `StateError`. A hasher that saw part of a failed
  run throws `StateError` from `hex()` instead of returning a wrong digest.

### 4.9 pool

```dart
abstract final class Pool {
  static Future<List<R>> map<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, int retries = 0, Rate? rate, bool isolates = false, void Function()? onDone});   // fail fast
  static Future<List<Outcome<T, R>>> settle<T, R>(Iterable<T> items, FutureOr<R> Function(T item) job,
      {int? limit, int retries = 0, Rate? rate, bool isolates = false, void Function()? onDone});   // never throws
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
- `retries:` re-runs a failing job with the shared jittered backoff; `rate:` paces job starts.
  Together they replace hand-written retry loops around shells, browsers and flaky I/O.
- `onDone` runs after every job, success or failure: `onDone: bar.tick`.
- Nothing stays running between calls, so there is nothing to close.

```dart
final done = await Pool.settle(files, (f) => cdn.get(f.url) > f.to, onDone: bar.tick);
for (final Failed(:item, :error) in done.failures()) Console.log('✗ ${item.to.name()}: $error');
final thumbs = await Pool.map(paths, makeThumb, isolates: true);
```

### 4.10 cli

```dart
sealed class Param<T> {}                                   // read back with context(param) as a T
final class Flag extends Param<bool> { Flag(String name, String help, {String? short, bool or = false}); }
final class Opt<T> extends Param<T> { Opt(String name, String help, {String? short, T? or, bool required = false, String? env, T Function(String)? parse, List<T>? values}); } // env: the variable read when the flag is absent
final class Multi<T> extends Param<List<T>> { Multi(String name, String help, {String? short, List<T> or = const [], T Function(String)? parse, List<T>? values}); }
final class Arg<T> extends Param<T> { Arg(String name, String help, {T? or, bool required = false, T Function(String)? parse, List<T>? values}); }
final class Command {
  Command(String name, String help, {List<Param<Object?>> params = const [], List<Command> commands = const [],
      FutureOr<void> Function(Context context)? handler, List<String> aliases = const [], String? dotenv});
  Future<int> run(List<String> argv);                     // sets exitCode: 64 usage, 1 failure (also returned)
}
final class Context { T call<T>(Param<T> param);  List<String> rest();  String usage(); }
final class UsageException implements Exception { const UsageException(String message); }
```

- **The type comes from the definition.** `Opt<int>('port', …, or: 8080)` reads as `int`, and
  `Opt<String?>('out', …)` reads as `String?`. A non-nullable `T` without `or` or `required` is an
  `ArgumentError`. Built-in `T`s are `String`, `int`, `double`, `num`, `Duration`, `DateTime` and
  `Uri`; anything else needs `parse:`. `values: Section.values` takes one of a fixed set, by
  (enum) name, case-insensitive; usage shows `<photos|reels>` and a typo suggests the closest.
  Yes/no is always a `Flag`. `Multi<T>` reads as `List<T>`.
  The positionals left after the `Arg`s are `context.rest()`.
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
  - A handler's `UsageException` is a 64, and any other `Exception` prints one line and is a 1:
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
  static Color? accent;  // null (default) = no colour; e.g. Color.orange for live lines and the choose row
  static Future<String?> ask(String question, {bool secret = false, String? or});
  static Future<bool> confirm(String question, {bool or = false});
  static Future<T?> choose<T>(String question, List<T> items, {String Function(T)? label, T? or, Map<String, T>? keys});
  static Future<String> key({String? prompt});
  static Future<T> spin<T>(String label, Future<T> work);
  static Bar bar(int? total, {String? label});   // null = unknown
  static void log(String line);                    // prints above a live spinner or bar
  static void table(List<List<Object?>> rows, {List<String>? header});   // aligned columns on stdout
  static void notify(String message);              // OSC 9/777 + bell; through the app inside Tui.run (silent while focused)
  static void copy(String text);                   // OSC 52; through the app inside Tui.run
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
- **Live lines** (any number of `spin`s and `bar`s at once, stacked one row each; a finished one
  prints its final `✓`/`✗` line above the rest):
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
  factory Color.index(int index);  factory Color.rgb(int r, int g, int b);   // 0–255, else ArgumentError
}
enum Style { bold, dim, italic, underline, strike, reverse }
```

`Region.picture(image)` draws any `Image` (half-block cells); `tui` and `image` never load each other (Image implements a private pixel interface).

- **One look for `Console` and `Tui`**; only `accent` is customizable:
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
  pending. An `Exception` from a handler, or from work it started, shows as `✗ <message>` in
  the status row (no SDK prefix) and the app keeps running; its stack prints to stderr after the
  terminal is restored. An `Error` ends `run` and is rethrown.
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
  - `run` enters raw mode, the alternate screen and mouse reporting, turns
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
enum ImageFormat { png, jpg, gif, bmp, tiff, ico, webp }
final class Image {
  static Image decode(List<int> bytes);
  static ImageFormat? sniff(List<int> bytes);     // header only; .name is the extension; webp decodes, never encodes
  int width();  int height();  (int, int, int) pixel(int x, int y);
  Image resize({int? width, int? height});  Image crop(int x, int y, int width, int height);
  Reader encode(ImageFormat format, {int quality = 90});
}
extension on Reader { Future<Image> image(); }
```

- `decode` reads PNG, JPEG, GIF (first frame only), BMP, WebP, TIFF and ICO, with the EXIF
  orientation applied. An unknown format is a `FormatException`.
- `resize` keeps the aspect ratio when one side is given. A missing or non-positive size is an
  `ArgumentError`. `crop` outside the image is a `RangeError`.
- `encode` is a lazy `Reader`. `quality` (1–100) applies to JPEG; `.webp` and `.ico` above 256 px are an
  `ArgumentError`. The work is CPU-bound, so batches go through `Pool.map(isolates: true)`.

### 4.14 csv

```dart
abstract final class Csv {
  static List<List<String>> parse(String text, {String sep = ','});
  static List<Map<String, String>> records(String text, {String sep = ','});   // header row → keys
  static String encode(List<List<Object?>> rows, {String sep = ','});
}
extension on Reader { Future<List<List<String>>> csv({String sep = ','}); }
```

- RFC 4180: quoted fields, `""` escapes, CRLF or LF, embedded newlines, a leading BOM. An
  unterminated quote is a `ContentException`. `encode` writes CRLF and quotes only what needs it.

### 4.15 scrape

```dart
final class Scrape<T, R> {
  Scrape({int limit = 4, int retries = 0, Rate? rate, Object? Function(T item)? key,
      void Function(int done, int total)? onProgress});
  Stream<R> run(Iterable<T> seeds, {required FutureOr<void> Function(Visit<T, R> visit) onItem,
      FutureOr<void> Function(Visit<T, R> visit, Object error)? onError});
}
final class Visit<T, R> { T get item;  bool add(T item);  void emit(R value); }
```

- Items are the script's own sealed type (or records); `onItem` switches on `visit.item`.
  `add` queues more work and returns whether it was new; `emit` streams a result. Pagination is
  "queue the next page", fan-out is "queue every link".
- `key:` is the deduplicator (default: the item's `==`). An item already queued is dropped, so
  link cycles end, and `if (fresh.isNotEmpty) v.add(Listing(page + 1))` stops at a page with
  nothing new.
- `limit` handlers at once, `rate` paces starts, and `retries` re-runs with the jittered backoff.
  Then `onError(visit, error)` gets the same `Visit`, so it can queue a replacement or emit a
  placeholder. Without `onError`, the first failure stops the run and is rethrown from the stream.
- `onProgress(done, total)` (the total grows): `Console.bar(null).update`. The run starts on
  listen; pausing stops new items; cancelling ends it. `scrape` imports no http: a handler uses a
  `Client`, a `Page` or `Shell` as it likes.

```dart
final albums = await Scrape<Job, Album>(key: jobKey, onProgress: bar.update).run([Listing(1)], onItem: (v) async {
  switch (v.item) {
    case Listing(:final page):
      final fresh = [for (final l in await links(page)) if (v.add(Detail(l))) l];
      if (fresh.isNotEmpty) v.add(Listing(page + 1));
    case Detail(:final url):
      v.emit(readAlbum(await shop.get(url).html(), url));
  }
}, onError: (v, e) => Console.log('✗ ${v.item}: $e')).toList();
```

### 4.16 yaml

```dart
abstract final class Yaml { static Json parse(String text, {String? from}); }
extension on Reader { Future<Json> yaml({Json? or}); }
```

- The first document becomes the same `Json` value (`$`, `or`, `text`), with anchors and aliases
  resolved; `<<` merge keys are not YAML 1.2. A parse error is a `ContentException` naming the
  source and line. Read only: edits to `pubspec.yaml` are text replacements that keep comments.

## 5. Errors

Failures the toolkit itself detects are one family rooted at `ToolkitException`
(`message` plus the engine error as `cause`, null when detected alone), so
scripts match the specific type — or the base for all of them — instead of
parsing message strings. Each custom type extends the SDK type it replaces,
so an existing `on HttpException` / `on FormatException` / `on StateError`
keeps catching it.

| Thrown                                         | When                                                                                     |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `HttpStatusException`                          | a non-2xx status surfaced by `check` or by piping its body (`status` `method` `url` `snippet`); extends `HttpException` |
| `HttpRequestException`                         | a request aborted by `close()` or a redirect that cannot be followed (`method` `url` `reason`); extends `HttpException` |
| `ContentException`                             | invalid content the toolkit rejects (JSON, selectors, archives, images, checksums); extends `FormatException` |
| `BrowserException`                             | a tab action the page itself fails (click, PDF, download); extends `StateError`          |
| `UsageException` (cli)                         | a handler rejects its input, giving exit 64                                              |
| `ToolkitException`                             | the base of the five above                                                               |
| SDK types (kept on purpose)                    | engine failures pass through (`SocketException`, `TlsException`, `ProcessException`, `FileSystemException`, `StdinException`/`StdoutException`); Dart-idiom guards stay (`ArgumentError`/`RangeError` for bad arguments, `StateError` for protocol misuse, `TimeoutException` for waits that run out) |

Engine exceptions are rethrown as one of these, naming the subject. An error inside a pipeline
surfaces from its `>`/`to`, after cleanup. An error in a chain surfaces at its single `await`.

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
scheduler or job queue; file watching; browser interception beyond `block` and `responses`, frames
and `hover`; colours outside the TUI; a TUI widget tree (widget state lives in
`Pick`/`Field`/`Scroll`); terminal images beyond half-blocks (Sixel, kitty), `ctrl+r` history search
and vim mode in `input`; HMAC; torrents. Each comes back only when a real script needs it.
