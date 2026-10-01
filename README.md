# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A toolkit for Dart scripts: processes, files, formats, HTTP, scraping, a real browser, and a CLI
framework. It is written so that a script needs as few lines as possible and runs fast.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```

This is the tour, with one example per idea. [`GUIDE.md`](GUIDE.md) is the manual.

---

## Modules

One import brings everything. The per-module libraries are for a program that has measured
its startup and wants less.

| Import | What it holds |
|---|---|
| `core.dart` | `Either`, `Env`, `Io`, durations (`60.s`) |
| `async.dart` | `parallelize`, `Worker`/`Pool`, `retry`, `Mutex`, `Cancel.scope`, stream operators |
| `collection.dart` | `Sequence` (lazy queries) and `Table` (rows of named columns: CSV, JSON, Markdown, console) |
| `formats.dart` | `JsonDocument` for JSON, YAML, TOML and INI; one markup tree for HTML and XML, with CSS `$` and XPath `$x` |
| `fs.dart` | `Path`, archives (zip, 7z, rar, tar.*), compression |
| `hash.dart` | 16 digests, 4 checksums, HMAC, encodings, `Secure` |
| `process.dart` | `run`, pipelines, `which`, `Shell.scope` |
| `http.dart` | requests, `Http.scope`, `IoClient`, `ChromeClient`, crawling, downloads |
| `cli.dart` | `Cli`, typed `Opt`/`Arg`, `Console`, `Lifecycle` |
| `native.dart` | `NativeLib`, the loader for the package's Rust library |
| **`ffi.dart`** | `Ffi`, which calls C in one line. It is **not** in the barrel, because its short names (`Ffi`, `C`, `Lib`, `Fn`) are only claimed by a program that imports it |

Nothing third-party runs at runtime except `path`. Every parser and the HTTP client are the
package's own, and each is checked in the tests against the package it replaced.

What Dart cannot do fast — hashing, archives, content decoding, legacy charsets — runs in `dart_toolkit_native`,
a Rust library the package ships prebuilt for macOS (arm64, x64) and Linux (x64, arm64). There
is no Windows build yet. `NativeLib.isAvailable` says whether it loaded; anything that needs it
throws an `UnsupportedError` saying why.

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
final branch = await run('git branch --show-current').text;     // quiet, trimmed
if (await run('git diff --quiet').isOk) print('clean');         // an answer, not a throw
await run(r'ls *.dart | wc -l', shell: true);                   // a real /bin/sh
await run('git commit -m', args: [message]);                   // an argument nothing re-reads
await run('vim notes.txt', inherit: true);                      // interactive child
final piped = await ('echo "apple\nbanana"' | 'grep an').run();
```

`run` returns a `ShellRun`, and the getter you read sets the policy: `.text` and `.lines` imply
`quiet`, and `.isOk` implies `strict: false`. Settings every command would repeat belong to the
scope:

```dart
await Shell.scope(workdir: repo, timeout: 30.s, () async {
  await run('git fetch --all');
  await run('git status --short');
});
```

A cancel or a timeout stops the whole process tree, not just the direct child.

### HTML and XML

`$` is CSS and `$x` is XPath 1.0, on every document.

```dart
final doc = await url.get().html;                               // or '<p>…</p>'.html
final title = doc.$('h1').text;
for (final a in doc.$('td.title > a[href]')) print(a.attr('href'));
final flac = doc.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;
final price = doc.$('th:contains(Price) + td').text;
final lines = doc.$('article').lines;                           // block-aware text, scripts skipped
final table = doc.$('table#songs').table;                       // colspan, duplicate headers kept
print(doc.$('main').first.markup);
```

The parser puts tag soup where a browser does. It decodes `&lang=en` in a URL as the literal
text, because that is how a browser reads it.

### Formats

JSON, YAML, TOML and INI all decode to one `JsonDocument`, so one query language and one
`to<T>()` serve them all.

```dart
final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
final deps = pubspec.$(r'$.dependencies.*').length;
final port = configText.toml['server']['port'].to<int>();       // or StateError naming $.server.port
final debug = iniText.ini['debug'].toOrNull<bool>() ?? false;   // absence expected
final tags = pubspec['topics'].to<List<String>>();
final all = streamText.yaml.documents;                          // `.yaml` is the first document
```

### Paths and archives

`Path` is an extension type over `String`, so it goes anywhere a path string does.

```dart
final dir = Path.temp / 'project';
await dir.archiveTo('${dir.path}.tar.zst');                     // the extension names the format
await 'download.bin'.path.extractTo('out', only: '**/*.txt');   // the magic number decides
final readme = await 'release.zip'.path.entry('README.md');     // one entry, no extraction
if (await 'cache.json'.path.olderThan(1.h)) await refresh();    // true when missing
await for (final batch in 'src'.path.changes()) print(batch);   // debounced watch
dir / 'AIR / Farewell song'.filename;                           // one safe component
```

Extraction treats an archive as untrusted: setuid bits are dropped, links that escape the
destination are refused, and output is capped at 200× the archive's size (never below 1 GiB).
`trusted: true` lifts all three.

### Collections

Nothing is added to `Iterable` or `Map`. The way in is a conversion: `.sequence` for a lazy
query, and `.table` for rows of named columns.

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc).thenBy((t) => t.number)
    .take(10);

final t = await Table.read('sales.csv');                        // CSV, TSV, JSON, NDJSON
t.where((r) => r.number('size') > 1e6).orderBy('disc').select(['title', 'size']).show();
await for (final row in Table.readRows('huge.csv')) print(row['id']);   // streamed
```

### Hashing

The receiver can be a `String`, a `List<int>` or a `Path`, and each offers the same five
methods: `hash`, `hashBytes`, `checksum`, `hmac` and `hmacBytes`.

```dart
'abc'.hash(Hash.sha256);
await file.hash(Hash.blake3);                                   // every core, ~10 GB/s
final digests = await files.hash(Hash.xxh3);                    // Map<Path, String>, parallel
final dupes = await 'photos'.path.duplicates();                 // List<List<Path>>
'body'.hmac(Hash.blake2b, secret);                              // BLAKE2's own keyed mode
Secure.token(); bytes.hex; '6869'.hexBytes;
```

Encryption, password hashing and signatures are out of scope, on purpose.

### Concurrency

`parallelize` is the quick form. It settles every item into an `Either`, and you choose the
error policy where you use the results.

```dart
final settled = await urls.parallelize(fetch, concurrency: 8);  // List<Either<Object, Page>>
final pages = settled.unwrap();                                 // or .rights, .lefts
final thumbs = await images.parallelize(resize, isolate: true); // long-lived isolates
```

Underneath is a `Pool` of `Worker`s. Subclass `Worker` when each isolate needs state set up
once:

```dart
final class Resize extends Worker<Path, Path> {
  late final RegExp suffix;
  @override
  void init() => suffix = RegExp(r'\.png$');                    // once per isolate
  @override
  Future<Path> run(Path image) async => image;                  // once per item
}

final pool = await Pool.spawn(Resize.new, size: 4);
await for (final done in pool.map(Stream.fromIterable(images))) print(done);
await pool.close();
```

### Cancellation

A cancel token is never passed as an argument. `Cancel.scope` holds it, and `download`, `run`,
`retry`, `Pool` and `.cancellable` read it from there. `Cli.run` opens the scope for you, so ^C
stops everything:

```dart
await Cancel.scope(token: stop, () async {
  for (final item in items) {
    Cancel.throwIfCancelled();
    await handle(item);
  }
  final page = await slow.cancellable;                          // CancelledException on cancel
});
```

### Requests

`Http.scope` holds the client and every setting a request would otherwise repeat.

```dart
await Http.scope(timeout: 30.s, retries: 3, delay: 500.ms, cookies: true, () async {
  await login.post(form: {'user': user, 'pass': pass});         // session kept across the redirect
  final doc = await dashboard.get().html;                       // throws unless 2xx
  final id = (await api.withQuery({'v': 2}).post(json: {'name': 'x'}).json)['id'];
  final res = await api.get();                                  // any status: res.isOk
  await upload.post(form: {'title': 'beach'}, files: {'photo': 'beach.jpg'.path});
});
```

- `retries:` covers transport errors, 5xx responses, and 429/503 with `Retry-After`. A POST is
  not sent twice unless the server said when to ask again.
- A verb's `.json`, `.text`, `.html`, `.xml` and `.bytes` throw `HttpException: 404 Not Found`
  unless 2xx; awaiting the verb itself gives the `Response` whatever its status.
- `delay:` is the gap between two requests to the same host, downloads included, jittered ±25 %.
- `cache:` keeps GETs on disk and asks conditionally the next run.
- `url.events()` streams server-sent events or NDJSON: `api.events(json: {...})` is the POST a
  streaming API asks for.
- A body is one of `text:`, `bytes:`, `form:`, `json:` or `files:`, and the same words are used
  on `Request`, the verbs and `follow`.
- Credentials never leave their origin: not on a redirect, and not to a third-party host a
  Chrome tab loads from.

### Crawling

A crawl is five hooks on a chain, plus the stream of what they emit:

```dart
final stories = url.scrape<Story>()
    .onInit((ctx) => ctx..concurrency = 8..robots = true..sitemaps = true)
    .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      for (final a in ctx.response.html.$('.titleline > a')) {
        ctx.emit((title: a.text, link: ctx.resolve(a.attr('href'))));
      }
      ctx.follow(ctx.response.html.$('a.next'));
    })
    .onError((ctx) => Console.warn('${ctx.failure}'))
    .onFinish((summary) => Console.info('$summary'));

await for (final story in stories.rights) print(story);
```

The chain is sugar over `Crawler<T>`, which has the same hooks as methods. Subclass it when a
crawl needs state or a test:

```dart
final class Titles extends Crawler<String> {
  final Uri home;
  final seen = <String>{};
  Titles(this.home);

  @override
  void onInit(InitContext<String> ctx) => ctx.seed(home);
  @override
  void onResponse(ResponseContext<String> ctx) {
    for (final h in ctx.response.html.$('h2')) {
      if (seen.add(h.text)) ctx.emit(h.text);
    }
  }
}

final titles = await Http.scope(() => Titles(home).run().rights.toList());
```

`follow` stays on the seed's hosts and never fetches a page twice. A failure arrives as a
`Left` item, never as a stream error.

### Clients and Chrome

Every request goes through one `Client`. Name it once, in `Http.scope(client:)`, or hold it and
call the same verbs on it directly.

```dart
IoClient(connections: 32, perHost: 6, proxy: 'http://user:pass@host:8080'.url);

final chrome = await ChromeClient.launch(block: Resource.heavy, profile: 'session'.path);
await Http.scope(client: chrome, () => url.scrape<Item>().onResponse(parse).rights.forEach(print));
await chrome.page(url, (tab) => tab.click('.accept'));          // only a held client has tabs
await chrome.close();
```

`ChromeClient` speaks the DevTools protocol to the Chrome you already have installed. Here is
what it does:

- **Rendering.** A page arrives as its DOM after its own scripts have run, so `$`, `$x` and the
  crawl engine work on it unchanged.
- **Files.** A file, or anything with `Request.raw`, goes through a plain socket, carrying the
  browser's cookies.
- **Lifetime.** A launched Chrome dies with your program, even on `kill -9`, and takes its
  temporary profile with it.

### Driving a page

```dart
final tab = await chrome.open(loginUrl);
await tab.fill('#user', 'me');
await tab.waitForNavigation(() => tab.click('button[type=submit]'));
final file = await tab.waitForDownload(() => tab.click('.statement'), to: 'out'.path);
final api = await tab.waitForResponse('/api/items', () => tab.click('.more'));
await tab.close();
```

Each of the three waits takes the action that triggers it. That way the wait is armed before
the click, so a fast page cannot finish before the wait starts.

### Downloads

A download is atomic (a `.part` file renamed on success) and resumable. One file is a batch of
one, so it uses the same `download` and `show` as a thousand files:

```dart
await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, digest)).show();
await {for (final u in urls) u: 'out'.path / u.pathSegments.last}.download(concurrency: 8).show();
await [Stream.fromIterable(fixed), scraped].merge().download().show();
```

### CLI

An option is a value: its name is written once, and its type is the type `ctx(…)` returns.
Positionals work the same way.

```dart
final env = Opt.among('env', Env.values, abbr: 'e').or(Env.production);
final token = Opt.text('token').env('GITHUB_TOKEN').required();   // [env: GITHUB_TOKEN] in help
final headers = Opt.text('header', abbr: 'H').many();             // List<String>
final id = Arg.text('id').required();

Future<void> main(List<String> args) => Cli(
  name: 'deploy',
  values: [id, env, token, headers],
  handler: (ctx) async {
    if (!await Console.confirm('Ship ${ctx(id)} to ${ctx(env).name}?', or: true)) return;
    await Console.spin('Deploying', () => ship(ctx(id)));
  },
).run(args);
```

Every `Cli` answers `-v/--verbose`, `-q/--quiet`, `-h/--help` and
`--completion bash|zsh|fish`, unless it declares those names itself. Failures behave like this:

| Failure | Result |
|---|---|
| A usage error | exit 64, with a "did you mean" |
| Any other exception | one red line, exit 1; the stack trace only with `-v` |
| A signal | exit 128+n |

Prompts are async, so ^C at a prompt ends the program cleanly.

### Lifecycle and console

```dart
final release = Lifecycle.onExit(unlock);     // register; call `release()` to undo
await Lifecycle.exit('no URL given');         // run the hooks, red message, exit 1

final spinner = Console.spinner('Connecting');
Console.info('resolved 3 hosts');             // scrolls above the spinner
spinner.succeed('ready');
```

Every write goes through one live region. Log lines, a child process's output and prompts all
land above a spinner or progress board instead of on top of it. Without a terminal, each one
becomes plain durable lines.

### FFI

`package:dart_toolkit/ffi.dart` calls C in one line, with no codegen:

```dart
import 'package:dart_toolkit/ffi.dart';

final libc = Ffi.open('c');
libc.fn('strlen', C.i64)('hello');                              // 5
libc.call('getenv', C.str, 'HOME');                             // String?
final name = Uint8List(256);
libc.call('gethostname', C.i32, name, name.length);             // filled in place
libc.call('ldexp', C.f64, 1.0, 10);                             // 1024.0: ints and doubles mix
libc.call('sqrtf', C.f32, C.f32(2.0));                          // a float
libc.fn('snprintf', C.i32, fixed: 3)(name, 256, '%d', 42);      // variadic
if (libc.call('chdir', C.i32, '/nope') < 0) print(Ffi.errno);   // 2
await libc.fn('usleep', C.i32).async(300000);                   // on another isolate
```

The rules for arguments and return values:

- A `String` is passed as a scoped `char*`.
- A typed list is copied in, then copied back out.
- A key names a C type. As a return (`C.i32`, `C.str`, `C.f64`, `C.f32`) it narrows the
  result; called (`C.f32(x)`, `C.i8(255)`) it makes a value that type holds.
- `s.out(C.i32)` is an out-parameter, `C.u8.list(ptr, n)` views an array, and
  `C.struct([sec, nsec])` lays out a struct whose members are `C.i64.field`s.
- Structs by value and more than eight arguments need `dart:ffi` directly. On Windows, so
  does a call that mixes integers and doubles.

### Testing

`Io` is the only sink, and `Client` is the only way to the network, so a test replaces both.
`MockClient` is forty lines in [`test/mock_client.dart`](test/mock_client.dart); copy it.

```dart
final buffer = StringBuffer();
Io.out = buffer;
Console.ok('captured');
Io.reset();

await Http.scope(client: MockClient((r) async => Response('{"ok":true}', 200)), () => url.get().json);
```

---

## Executables

`bin/` holds three programs, which also serve as the benchmarks for the package's brevity:

| Program | What it does |
|---|---|
| [`tk`](bin/tk.dart) | the toolkit as a tool: `hash`, `find`, `read`, `fetch`, `pack`, `peek` |
| [`keybox`](bin/keybox.dart) | scrapes a box set's artwork and tracks, downloads them all, and zips the result |
| [`books`](bin/books.dart) | public-domain ebooks from Standard Ebooks, over plain HTTP or by clicking in Chrome |

```sh
dart run dart_toolkit:tk find 'lib/**/*.dart' --top 5
dart run dart_toolkit:books "pride and prejudice" frankenstein -f kepub
```

## More

- [`GUIDE.md`](GUIDE.md): every module in full, a cookbook, and notes on testing, performance
  and troubleshooting.
- [`CONVENTIONS.md`](CONVENTIONS.md): the rules this API follows, and why.
- [`CHANGELOG.md`](CHANGELOG.md): what each release contains.

## License

MIT — see [LICENSE](LICENSE).
