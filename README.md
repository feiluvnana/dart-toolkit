# Dart Toolkit (`dart_toolkit`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart](https://img.shields.io/badge/Dart-3.10%2B-blue.svg)](https://dart.dev)
[![GitHub](https://img.shields.io/badge/GitHub-feiluvnana%2Fdart--toolkit-brightgreen.svg)](https://github.com/feiluvnana/dart-toolkit)

A scripting, automation and web-scraping toolkit for Dart.

---

## Modules

**One import.** `package:dart_toolkit/dart_toolkit.dart` brings every module; since every
parser and the HTTP client are the package's own, it costs about what a scraper's five module
imports cost by hand (measured within 70 ms, on a 0.4 s bare start). A program that wants less
imports modules individually, and an executable run as `dart run dart_toolkit:<name>` pays
nothing after the first run either way.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```


| import | contents | third-party |
|---|---|---|
| `core.dart` | `Either`, `Env`, `Io`, `TaskProgress`, string and duration helpers | — |
| `native.dart` | `Native`: loads `dart_toolkit_native`, the package's Rust library, for `fs` and `hash` | path |
| `collection.dart` | `Sequence` (`.sequence` on any `Iterable` or `Map`): lazy queries, multi-key sort, joins, sets; `Table`: rows of named columns, and the package's one table renderer; CSV, NDJSON, Markdown | — |
| `formats.dart` | `JsonDocument` with JSONPath; YAML, TOML, INI into it; one markup tree for `HtmlDocument` and `XmlDocument`, CSS `$` and XPath `$x` on both; YAML out | — |
| `async.dart` | `parallelize`, `retry`, `Mutex`, `Cancel.scope`, stream operators | — |
| `cli.dart` | `Cli` with typed options, `Console` (logging, spinners, progress, boards, prompts), ANSI styling | — |
| `fs.dart` | `Path`; zip, 7z, rar, tar and gz/xz/zstd/bz2 archives with passwords, by magic number, through the native library | path |
| `hash.dart` | 16 digests and 4 checksums behind one `hash(Hash.…)`, HMAC, hex/base64/base32, `Secure.token`, `uuid`, `equals` | path |
| `process.dart` | `run`, pipelines, `which`, `Shell.scope` | path |
| `http.dart` | `Request`, `Response`, `Client` (`IoClient`, `ChromeClient` over Chrome), `Http.scope`, scraping, downloads, `res.html`, `url.json()` | — |

Ten modules. Every parser and the HTTP client are the package's own, checked against the
packages they replaced in the test suite. What Dart cannot do fast — hashing at 2–3 GB/s,
7z and rar — runs in **`dart_toolkit_native`**, one Rust library the package ships
prebuilt and loads through `dart:ffi`; `Native.isAvailable` and `Native.reason` say whether it
loaded, and anything that needs it throws an `UnsupportedError` naming what and why when it
did not. `tool/startup.dart` prints what each module costs to import.



---

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
final res = await run('git status --short');
if (res.isOk) print(res.text);

final prs = (await run('gh pr list --json number', quiet: true).text).json;   // a JsonDocument
await run('cat', input: 'fed to stdin');
await (await which('dart'))?.run(args: ['--version']);

final piped = await ('echo "apple\nbanana"' | 'grep an').run();      // pipefail semantics
print(piped.lines);
```

A working directory, an environment, a timeout or a failure policy that every command would
otherwise repeat belongs to the scope, not the call — the shape `Http.scope` has for a
client. `run`, `path.run(args:)` and a pipeline all read it, and a per-call argument still wins:

```dart
await Shell.scope(() async {
  await run('git fetch --all');
  await run('git status --short');
  final probe = await run('git cat-file -e deadbeef', strict: true);   // this one may throw
}, workdir: repo, env: {'GIT_TERMINAL_PROMPT': '0'}, timeout: 30.s, quiet: true, strict: false);
```

### HTML and XML

`$` takes a CSS selector and returns `Elements`: a list, whose `text`, `attr()` and `lines`
answer for the first match. `$x` takes XPath, as in the browser console, and returns `Nodes`.

```dart
final doc = await url.html();                       // or res.html, or '<p>…</p>'.html
final title = doc.$('h1').text;
for (final a in doc.$('td.title > a[href]')) print(a.attr('href'));
final tracks = doc.$('#songlist tr').$('td:nth-child(3)').map((td) => td.text);
final flac = doc.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;
final table = doc.$x('//h2[contains(., "Tracks")]/following-sibling::table[1]').elements.$('td');
```

XML is the same tree and the same two queries — `$` is CSS and `$x` is XPath, here as
everywhere — parsed and serialised as XML: names keep their case and their prefixes, and an
empty element closes itself.

```dart
final feed = await url.xml();                        // or res.xml, or '<rss>…</rss>'.xml
for (final item in feed.$('item')) print(item.$('title').text);
final urls = feed.$x('//media:content/@url').texts;  // a prefixed name is not CSS
```

Both parsers are the package's own — tag soup lands where a browser puts it — and each is
checked against the package it replaced on real documents in the test suite.

### Formats

Every data and configuration format decodes to the same `JsonDocument`, so one query language
and one `to<T>()` serve them all. The parsers are the package's own; YAML is checked against
`package:yaml` in the test suite.

```dart
final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
print(pubspec.$(r'$.dependencies.*').length);
final port = configText.toml['server']['port'].to<int>();
final debug = iniText.ini['debug'].to<bool>();
await 'out.yaml'.path.writeText(pubspec.toYaml());

Table.csv(text); Table.cells(headers, rows); Table.ndjson(text);   // in
t.toCsv(); t.toNdjson(); t.toMarkdown(); t.show();                 // out
```

### Paths

`Path` is an extension type over `String`, so it goes anywhere a path string does.

```dart
final dir = Path.temp / 'my_project';
await dir.mkdir();

final file = dir / 'config.json';
await file.writeText(jsonEncode({'version': '0.0.1'}));

final config = JsonDocument.parse(await file.readText());
print(config.$(r'$.version').first.raw);

print(await file.hash(Hash.sha256));                        // 2.4 GB/s through the native library
await dir.archiveTo('${dir.path}.7z', password: 'pw');   // also .zip, .tar.gz, .tar.zst, .tar.xz, .tar.bz2
await 'photos.rar'.path.extractTo(dir, password: 'pw');   // rar reads; the format's licence forbids writing
for (final e in await zip.archiveEntries()) print('${e.name} ${e.size}');
await log.compressTo('log.gz');  await big.compressTo('big.zst');
```

**Writing names the format; reading works it out.** `archiveTo` and `compressTo` take it from
the destination's extension, because a file that does not exist yet has nothing else to go on.
`extractTo`, `archiveEntries` and `decompressTo` read the file's magic number, so a download
saved without an extension, or a `.bin` that is really a 7z, still opens:

```dart
await 'downloaded.bin'.path.extractTo(dir);   // zip, 7z, rar, tar or any of the tar codecs
await 'blob'.path.decompressTo('out.txt');     // gzip, xz, zstd or bzip2
Archive.of('x.rar');                           // Archive.rar — named, and read-only
```

A name that came from outside — a scraped title, a header, user input — becomes one component
with `filename`; `sanitized` is for a whole path and keeps its separators:

```dart
dir / 'AIR / Farewell song'.filename;   // .../AIR _ Farewell song
```

`Path` cannot override `==` — normalize at map boundaries:

```dart
final seen = <Path, int>{p.normalized: 1};
```

### Collections

Nothing is added to `Iterable` or `Map`. The way in is a conversion: `.sequence` gives a `Sequence`, a
lazy query with LINQ's and Kotlin's vocabulary that is still an `Iterable` on the way out;
`.table` gives a `Table`, rows of named columns. Both are opt-in; a plain list needs neither.

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc).thenBy((t) => t.number, descending: true)
    .take(10);                                            // still lazy, still an Iterable

tracks.sequence.groupBy((t) => t.disc).mapValues((g) => g.length).toMap();   // {1: 12, 2: 9}
songs.sequence.innerJoin(pages, on: (s) => s.href, to: (p) => p.href, (s, p) => (s, p.size));
[1, 2, 3].sequence.union([3, 4]).scan(0, (a, b) => a + b);    // 1, 3, 6, 10
prices.sequence.sum; names.sequence.sorted.first;             // typed: only on numbers, only on Comparables
for (final (k, v) in map.sequence.sortedByValue(descending: true).take(3)) print('$k $v');
```

A `Table` comes from maps, records, a JSON
array, CSV text or an HTML `<table>`, and goes back out as CSV, JSON or a console table:

```dart
final t = doc.$('table#songs').table;                     // <th> → columns, <tr> → rows
t.where((r) => r.number('size') > 1e6)
    .orderBy('disc').thenBy('n')
    .select(['title', 'size'])
    .show();
t.groupBy('disc').sum('size');                            // Table(disc, size)
t.pivot(rows: 'disc', column: 'format', value: 'size');
await t.join(other, on: 'href').saveCsv('out.csv');
final rows = json.$(r'$.items[*]').table;                 // or Table.csv(text), Table.rows(maps)
```

### Hashing

Digests run in the native library, so they are the same and fast on every platform; the test
suite checks each against its published vectors and against `openssl`. A file streams, so
memory is flat whatever its size.

`hash`, `hashBytes`, `checksum`, `hmac` and `hmacBytes` read the same on all three receivers
— a `String`, a `List<int>` and a `Path` — so none of them has to be guessed at:

```dart
'abc'.hash(Hash.sha256);  bytes.hash(Hash.blake3);  await file.hash(Hash.sha3_256);  await file.checksum(Hash.crc32)
'body'.hmac(Hash.sha256, secret);  await file.hmac(Hash.sha256, key);  bytes.hmacBytes(Hash.sha512, key)
Secure.token();  Secure.uuid();  Secure.bytes();  Secure.equals(a, b)
bytes.hex;  bytes.base64Url;  'JBSWY3DP'.base32Bytes;  '6869'.hexBytes
```

Sixteen digests and four checksums: md5, sha1, the SHA-2 and SHA-3 families, keccak256,
blake2s, blake2b, blake3, ripemd160, and crc32, crc32c, xxh64, xxh3. The 32-bit checksums
read as an `int` (`bytes.checksum(Hash.crc32)`); the 64-bit ones read as hex, because they do not fit one.

**Encryption, password hashing, signatures and JWT are deliberately absent.** This is a
toolkit for automation scripts: it identifies, verifies and encodes data, and has no
business owning the code that protects it. Use a dedicated package when you need that. The
class is `Secure`, not `Crypto`, for the same reason.

### Concurrency

One primitive settles every task; `unwrap` picks the error policy at the use site.

```dart
final settled = await urls.parallelize(fetch, concurrency: 8);  // List<Either<Object, Page>>
print('${settled.rights.length} ok, ${settled.lefts.length} failed');

final pages = (await urls.parallelize(fetch)).unwrap();  // or throw the first failure
```

```dart
final data = await retry(fetchData, attempts: 3, delay: 200.ms);

final lock = Mutex();
await lock.run(() async { /* critical section */ });
```

**A token is not threaded, it is in scope.** `Cancel.scope` holds one for everything inside
it, the way `Http.scope` holds a client: `download`, `parallelize`, `retry` and `cancellable`
all read `Cancel.token`, and none of them takes a `cancelToken:` of its own. `Cli.run` opens
one around the action with `ctx.cancel` as its token, so a signal, `Lifecycle.exit` or the
end of the action stops the lot.

`Cancel.isCancelled`, `Cancel.reason` and `Cancel.throwIfCancelled()` read the ambient state —
all three quiet outside a scope, because nothing has cancelled it there. A loop of its own
cooperates with one line:

```dart
for (final item in items) {
  Cancel.throwIfCancelled();
  await handle(item);
}
```

A stream or future that does not cooperate by itself gets `.cancellable`, which binds it to the
scope. A stream ends; a future fails, having no quiet ending to offer. Either way the use site
decides what an ending means:

```dart
await for (final item in feed.cancellable) print(item);
if (Cancel.isCancelled) return;

final page = await slow.cancellable;   // CancelledException if the scope fires first
```

```dart
Future<void> main(List<String> args) => Cli(name: 'sync', handler: work).run(args);

Future<void> work(CliContext ctx) async {
  await pairs.download(concurrency: 8).show();       // stops on ^C
  await urls.parallelize(fetch, concurrency: 8);     // and so do these
  await retry(fetchIndex, attempts: 5);
}
```

Outside a `Cli`, open the scope yourself. There is no second way in: `.cancellable` takes no
token and throws outside a scope, so a token is named where the scope opens and nowhere else.

```dart
final stop = CancelToken();
await Cancel.scope(() async {
  await for (final item in url.scrape<Item>().onResponse(parse).rights) print(item);
}, token: stop);
```

### Scraping

A crawl is a chain of five hooks, and the stream of what they emit.

```dart
final stories = url.scrape<Story>()
    .onInit((ctx) {
      ctx.concurrency = 8;
      ctx.delay = 200.ms;
      ctx.pages = 50;
    })
    .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      final html = ctx.response.html;
      for (final row in html.$('tr.athing')) {
        final a = row.$('.titleline > a');   // Elements: text and attr() answer for the first match
        if (a.attr('href') case final href?) ctx.emit((title: a.text, link: ctx.resolve(href)));
      }
      for (final a in html.$('a[href]')) ctx.follow(a.attr('href')!);
    })
    .onError((ctx) => Console.warn('${ctx.failure}'))
    .onFinish((summary) => Console.info('$summary'));

await for (final story in stories.rights) print(story);
```

Five hooks, each with the context for its moment:

- `onInit` — once, on listen, with every crawl-wide setting: `concurrency`, `perHost`, `delay`,
  `timeout`, `retries`, `redirects`, `bodyLimit`, `pages`, `depth`, `scope`, `robots`, and
  `seed()` to add starting points. It may be async — fetch a token, read a config.
- `onRequest` — before every send. Anything per request is here: a header, the `user-agent`, a
  signature on `ctx.request`, or `ctx.skip()`.
- `onResponse` — every 2xx. `ctx.emit`, `ctx.follow`, `ctx.stop`; `ctx.url` is the page that
  answered, after redirects, and `ctx.depth` and `ctx.pages` say where the crawl is.
- `onError` — the engine has given up on a request. `switch` on `ctx.failure`
  (`RequestFailed | StatusFailed | HookFailed`), then `ctx.retry(after:)`, `ctx.emit` a
  fallback, `ctx.follow` an alternative, or `ctx.ignore()`. A hook that does none of those
  leaves the failure a `Left`.
- `onFinish` — once, with a `ScrapeSummary` of pages, failures, requests, retries, drops,
  bytes, time.

`follow` stays on the seeds' hosts (`www.` or not), strips fragments, never fetches a page
twice, and drops `mailto:` and `javascript:` by itself — and returns `false` when it dropped
something, so nothing vanishes silently. It names a body with the same four words `Request`
and `post` use — `text:`, `bytes:`, `form:`, `json:`. `ctx.scope` in `onInit` widens the rule for the crawl,
`offsite: true` for one link, `revisit: true` for one refetch. `follow(onResponse:, onError:)`
overrides the hooks for one request, and `meta:` rides along to it.

`ctx.robots = true` fetches each host's `/robots.txt` once and drops what it forbids into
`summary.dropped`; longest match wins, `*` and `$` count, and a `Crawl-delay` raises that
host's gap but never lowers it. A site with no rules, or one that cannot be read, forbids
nothing.

Defaults: 16 in flight, 8 per host, 30 s, 2 retries, 5 hops, 16 MB, `user-agent: dart-toolkit`
unless a request or the scope names one, and a host answering 429 or 503 is paused for its
`Retry-After`.

A failure is an item, not a stream error — the contract `parallelize` has, on a stream:

```dart
stories.rights      // skip failures
stories.lefts       // only the failures
stories.unwrap()    // throw the first
await for (final r in stories) switch (r) { case Right(:final value): ...; case Left(:final value): ... }
```

One scope shares a client across every request inside it, closes it on the way out, and is
where the timeout, default headers and cookie jar live. `get`, `head`, `post`, `put`, `patch` and `delete`
name a body by what it is — at most one of `text:`, `bytes:`, `form:`, `json:` and `files:`, each
typed, each carrying its own `content-type`, and the same words on `Request` and `follow`.
`fetch` is a GET that must be 2xx.

`files:` is `multipart/form-data`, read off disk as it goes out and never held, so the size of
an upload is not the size of the heap. It is the one that pairs: with `form:` it sends the
fields and the files together, which is a browser submitting a form with a file input on it.

```dart
await api.post(form: {'title': 'holiday'}, files: {'photo': '~/beach.jpg'.path});
```

```dart
await Http.scope(() async {
  final doc = await url.html();                         // throws on a non-2xx status
  final res = await other.get();                        // ...or check it yourself
  if (!res.isOk) await Lifecycle.exit('${res.statusCode} from $other');
  final created = await api.withQuery({'v': 2}).post(json: {'name': 'x'});
}, timeout: 30.s, headers: {'user-agent': 'my-tool/1.0'});
```

`cookies: true` keeps what the responses set and sends them back, so a login and the pages
behind it are one crawl and nothing parses `set-cookie` by hand. The jar lasts as long as the
scope and never touches disk; a request that names its own `cookie` still wins.

The jar walks the redirect chain itself, hop by hop, because a login is a POST that answers 302
and sets the session **on that hop** — the response at the end of the chain carries no
`set-cookie` at all, and a client left to follow its own redirects arrives with the session
already thrown away.

```dart
await Http.scope(cookies: true, () async {
  await login.post(form: {'user': user, 'pass': pass});
  await for (final item in dashboard.scrape<Item>().onResponse(parse).rights) print(item);
});
```

`url / 'users'` appends a path segment, treating the base as a directory — the same glyph as
`Path./`, with the same meaning.

### Clients

Every request in the module — a `get`, a download, a crawl — is sent through one `Client`, and
`Http.scope(client:)` is the only place a program names it. There are two, and a test's is a
third:

```dart
await Http.scope(client: IoClient(), () async { … });                  // the default: dart:io
await Http.scope(client: await ChromeClient.launch(), () async { … });  // Chrome renders it
await Http.scope(client: MockClient((r) async => Response('ok', 200)), () async { … });
```

`IoClient` takes the transport's own limits: `perHost:` is how many connections may be open to
one origin, and `connections:` caps the total in flight across every host, which `dart:io` has
no setting for. The permit is held until the body is read to the end, cancelled or thrown, so
the cap counts transfers rather than handshakes. `keepAlive:`, `connectTimeout:`,
`userAgent:`, `proxy:` and `insecure:` are there too — `Http.scope(timeout:)` bounds the wait
for a *response*, which is a different thing and composes with them.

```dart
IoClient(connections: 32, perHost: 6, keepAlive: 30.s)
IoClient(proxy: 'http://user:pass@127.0.0.1:8080'.url)
```

It asks for what a browser asks for. `dart:io` announces `accept-encoding: gzip` and nothing
else, which is both slower and a thing to be recognised by; this announces brotli and zstd as
well and decodes them through the native library — brotli is 15–20% smaller than gzip on
markup, which a page at a time is the difference between a crawl and a shorter one. A program
without the native library asks for neither and nothing about it changes.

It also walks its own redirect chain rather than letting `dart:io` walk it, so the rule about
what a hop carries is one rule: 303, and 301 or 302 on anything but GET and HEAD, become a GET
with no body; 307 and 308 keep both; and credentials do not follow to another host.

A scope is for code with no client to hand — a download deep in a call chain, a crawl
assembled somewhere else. When the client *is* in hand, it takes the same verbs itself, and no
scope is needed:

```dart
final chrome = await ChromeClient.connect();

await chrome.get(url);                              // the page, rendered
await chrome.html(url);                             // parsed
await chrome.page(url, (p) => p.click('.download')); // the tab, live
await chrome.scrape<Item>(url).onResponse(parse).rights.forEach(print);
```

This is not sugar. A scope holds a `Client`, and a `Client` is `send` and `close` — so through
a scope, everything a particular client can do *beyond* the seam is invisible, and `page` was
reachable only by keeping the client in a variable. Held, the client is the receiver: `page`
sits beside `get` and the compiler decides whether it exists, so nothing probes, nothing casts,
and nothing throws at runtime for asking a socket to click a button. The scope keeps the cases
with no receiver to hang a client off — `stream.download(concurrency: 4)` over a merged stream
of records.

`ChromeClient` speaks the DevTools protocol over a websocket — no third-party package and no
Chromium download: `launch()` finds the Chrome already installed and runs it headless,
`attach(port:)` joins one already running, and `connect()` does whichever is needed. The page
arrives as the DOM **after its own scripts have run**, in `Response.bytes`, so `res.html`, `$`,
`$x` and the whole scrape engine work over it unchanged:

```dart
final chrome = await ChromeClient.launch(tabs: 4);
await Http.scope(client: chrome, () async {
  await for (final item in url.scrape<Item>()
      .onRequest((ctx) => ctx.request[ChromeClient.waitFor] = '.results .item')
      .onResponse(parse)
      .rights) print(item);
});
await chrome.close();
```

`block:` is the largest single thing a rendered crawl can do for itself — a page whose images,
fonts and media never arrive looks nothing like itself and says exactly the same words, in a
fraction of the bytes and a fraction of the time. `device:` is one argument instead of six, and
`stealth:` (on unless it is turned off) hides the marks an automated Chrome leaves for an
interstitial to find.

```dart
await ChromeClient.launch(block: Resource.heavy, device: Device.phone);
await ChromeClient.launch(device: Device(locale: 'de-DE', timezone: 'Europe/Berlin'));
```

Only a GET without a `range` is rendered. A POST, a resumable download, an image — everything
else goes to the plain HTTP client underneath, carrying the browser's cookies for that host, so
a crawl that renders its pages still fetches its files at the speed of a socket.

What a page needs before it is worth reading is said per request, with a `RequestKey`:

| key | |
|---|---|
| `ChromeClient.waitFor` | wait until a CSS selector matches |
| `ChromeClient.waitUntil` | `ChromeWait.load` or `.idle` — `load`, then half a second of silence |
| `ChromeClient.script` | JavaScript to run before the DOM is read; may return a promise |
| `ChromeClient.challenge` | how long this page may sit on an interstitial |
| `ChromeClient.block` | what this page refuses to load, over the client's `block:` |

`Request.raw` is the one directive that is not Chrome's own: it says *answer with the resource,
never a rendering of it*, and any client that renders must hand it to plain HTTP instead. Every
download sets it, so `path.download(url)` writes the file and not the viewer even inside a
Chrome scope — a PDF put through a tab comes back as the DOM Chrome built to display it,
which is not the PDF. `IoClient` renders nothing and ignores it.

### The browser that outlives the run

`launch()` is a fresh browser every time — temporary profile, no cookies, and the process dies
with the client. That is right for a crawl and wrong for anything that depends on *being
someone*. `connect()` keeps one browser and one profile across runs instead:

```dart
final chrome = await ChromeClient.connect();   // run 1: starts Chrome, you log in by hand
await Http.scope(client: chrome, () async { … });
await chrome.close();                           // the browser stays up
```

It probes the port, attaches if a Chrome is there, and otherwise starts one **detached** on a
persistent profile (`~/.dart_toolkit/chrome`, or `profile:`) that `close()` never kills. The
second run attaches in milliseconds with the cookies and the logged-in session still there. It
is headful by default, because a browser you can see is one you can log into. A Chrome already
on the port is attached to as it is, so `profile:`, `headless:` and `executable:` describe only
how to *start* one.

**A page is never lost.** A wait that expires, a selector that matches nothing, a challenge
that never clears: none of them throw and none of them close the tab. The DOM as it stands
comes back under the status the server gave it, and the tab goes back to the pool still on that
page — closing it would throw away a challenge somebody is in the middle of solving. A page
that answers with an interstitial is given `challenge:` (20 s by default) to become the real
page on its own; with `headless: false` that is also a human's chance to click the box. Only a
navigation Chrome refuses outright — a name that will not resolve, a refused connection — is a
`ClientException`, which is what a crawl retries.

### Driving a page

`send` fetches; `open` hands the tab over. It is outside the pool `send` draws on, so holding
one open — through a login, a captcha, a form — never starves a crawl:

```dart
final page = await chrome.open(loginUrl);
await page.fill('#user', 'me');
await page.click('button[type=submit]');
await page.waitFor('.dashboard');                 // false on time, never a throw
print((await page.html()).$('.balance').text);    // read the DOM whenever you like
await Path('shot.png').writeBytes(await page.screenshot());
await page.close();
```

| | |
|---|---|
| `goto(url, until:, challenge:)` | navigate and wait; answers with the page as it stands |
| `response()`, `html()`, `statusCode`, `url` | what the tab holds right now, at any moment |
| `waitFor(sel)`, `waitWhile(sel)` | a mutation observer; `false` when the time runs out |
| `click(sel)`, `fill(sel, text)`, `press(key)` | real mouse and key events, with a DOM fallback |
| `select(sel, value)`, `hover(sel)` | an option by value or by its text; a menu that opens on hover |
| `text(sel)`, `attr(sel, name)`, `has(sel)` | one value off the live page; `attr` answers what the DOM resolved |
| `navigating(action)` | run the action and wait out the navigation it causes |
| `downloading(action, to:)` | run the action and wait out the download it starts; answers the file |
| `fetching(match, action)` | run the action and answer the XHR it fires, as a `Response` |
| `block(kinds)` | refuse to load `Resource.heavy`, or any set of them, from now on |
| `frame(match)` | the iframe as a page of its own — every word here works inside it |
| `upload(sel, files)` | fill a file input the way a person fills one |
| `back()`, `forward()`, `reload()`, `scroll(times:)` | the history; walk a feed until it stops growing |
| `eval(js, awaitPromise:)`, `screenshot(selector:, full:)`, `pdf()` | run anything; a PNG of one element or the whole page |
| `cookies([restore])` | read the jar, or put a saved session back into the browser |
| `onDialog(handler)` | answer an `alert`, `confirm` or `prompt`; dismissed unless it is handled |

`chrome.page(url, (page) async { … })` is the same thing with the close written for you.

`navigating` takes the action rather than being a bare `waitForNavigation()` you call after a
click, and that is the point: a click is dispatched and returns immediately, so a fast page has
finished loading before the next line runs and a wait armed afterwards has already missed the
event it waits for. Give it the action and it cannot be got wrong:

```dart
await page.navigating(() => page.click('a.next'));
print(page.url);
```

`downloading` and `fetching` are the same shape for the same reason: a click that starts a
download or fires an XHR returns just as fast, and neither wait can be armed after it.

```dart
final file = await page.downloading(() => page.click('.download'), to: 'books'.path);
final more = await page.fetching('/api/items', () => page.click('.next'));
print(more!.json['items']);          // the JSON behind the page, not the DOM it becomes
```

`downloading` and `fetching` are the same shape for the same reason: a click that starts a
download or fires an XHR returns just as fast, and neither wait can be armed after it.

```dart
final file = await page.downloading(() => page.click('.download'), to: 'books'.path);
final more = await page.fetching('/api/items', () => page.click('.next'));
print(more!.json['items']);          // the JSON behind the page, not the DOM it becomes
```

A `RequestKey<T>` is how any client is told something HTTP has no word for, and **a client
ignores every key it does not know** — which is what lets the same crawl run over `IoClient`,
which ignores the wait, and over `ChromeClient`, which honours it. To write a third client,
implement two methods:

```dart
abstract interface class Client {
  Future<StreamedResponse> send(Request request);
  Future<void> close();          // always a future, so no caller branches on which it got
}
```

and point `clientConformance` at it — `test/client_conformance.dart` brings its own server and
checks the promises the rest of the module relies on: a non-2xx is a response and not a throw,
`url` is the URL that answered, a body arrives as a stream, an unknown directive is ignored.
`MockClient` is forty lines and `ChromeClient` nine hundred and fifty; both are yours to read
before writing a third.

### Downloads

Atomic — a `.part` file renamed on success, with `Content-Length` verified — and resumable: a
failed or interrupted transfer keeps its `.part`, and the next download of the same path picks
up with a `Range` request. Take a map, an iterable of `(url:, path:)` records, or a stream of
them, so discovery and transfer overlap:

One file or many, one name and one event stream — `dest.download(url)` is a batch of one, so it
renders with the same `show` and needs no wrapping:

```dart
await for (final p in {url: dest}.download(concurrency: 4)) {
  switch (p.current) {
    case Downloading(:final ratio):   print('${p.current.label} $ratio');
    case Downloaded(:final bytes):    print('${p.current.label} $bytes B');
    case DownloadSkipped():           print('${p.current.label} exists');
    case DownloadFailed(:final error): print(error);
  }
}
```

`checksum:` says what the bytes must hash to — a wrong one is a `DownloadFailed` holding a
`ChecksumMismatch`, and the `.part` goes rather than waiting to be resumed into the same wrong
file. `ifModified:` asks the server whether the file changed instead of skipping because it is
there, and a `304` is a `DownloadSkipped`:

```dart
await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, '9f86d0…')).show();
await feed.path.download(url, ifModified: true).show();   // re-run cheaply
```

A progress widget needs none of that — `show` renders the batch and returns its last event, and
`merge` lets a fixed list and a crawl feed the same downloader at the same time:

```dart
final last = await [Stream.fromIterable(artwork.pairs), scraped]
    .merge()
    .download(concurrency: 8)
    .show(slots: 8, message: 'Downloading', done: 'Done.');
print('${last?.written} new files');
```

### Errors

```dart
final outcome = Either.tryCatchSync(() => int.parse(raw));
final typed = outcome.mapLeft(ParseFailure.from);   // narrow afterwards
print(typed.fold((e) => 'failed: $e', (v) => 'got $v'));
```

### CLI

An option is a value, so its name is written once and its type is the type you read back.
`Opt.among` takes the values themselves — an enum, not a list of strings to match again by
hand — and `.or(…)` and `.required()` are what make `ctx(…)` non-nullable. `Cli.run` owns the
lifecycle: a usage error (`UsageException`) prints and exits 64, `ctx.cancel` is cancelled on a
signal, and whether the action returns or throws the exit hooks run and the signal handlers
are released so the process ends.

Every option kind is behind `Opt`, the flag included, and a command is everything it is given:
`options:`, `commands:` and `handler:` are constructor arguments, so there is one way to say
each and nothing is set after the fact.

```dart
enum Env { dev, staging, production }

final env = Opt.among('env', Env.values, abbr: 'e').or(Env.production);  // Env
final token = Opt.text('token', abbr: 't').required();                   // String
final workers = Opt.number('workers', abbr: 'w').or(4);                  // int
final dryRun = Opt.flag('dry-run', abbr: 'd');                           // bool
final since = Opt.by('since', DateTime.parse);                           // DateTime?

final cli = Cli(
  name: 'deployer',
  options: [env, token, workers, dryRun],
  handler: (ctx) async {
    final stage = Console.stages(2);
    stage('Checking target');           // [1/2] Checking target
    Console.info('Deploying to ${ctx(env).name} with ${ctx(workers)} workers');
    stage('Rolling out');
    await Console.spin('Deploying...', deploy);
  },
  commands: [
    CliCommand('fetch', description: 'Fetch a thing', options: [verbose], handler: fetch),
  ],
);

await cli.run(args);   // deployer -dw8 -t abc, deployer --workers=8 fetch, ...
```

Options may precede the subcommand, short flags combine (`-dv`), and a short option may attach
its value (`-w8`). A subcommand nests by taking `commands:` of its own.

`or` is the one word for a default, wherever one is given: `Opt.…or(value)`, and
`Console.ask(or:)`, `confirm(or:)`, `select(or:)`.

### Lifecycle

Two shapes and no others: `onExit` registers a listener for the exit event, and `exit` is the
event happening.

```dart
Lifecycle.onExit(chrome.close);          // register
Lifecycle.onExit(null);                  // forget every listener

await Lifecycle.exit();                  // run them, leave with 0
await Lifecycle.exit('no URL given');    // say why in red on stderr, leave with 1
await Lifecycle.exit('bad args', 64);    // ...with the code you choose
```

Listeners run on SIGINT, SIGTERM, `Lifecycle.exit`, and when `Cli.run` returns — in
registration order, and one that throws does not stop the rest, so a cleanup that fails cannot
strand the ones behind it. `onExit` answers a function that removes *that* listener, for a
cleanup that stops being necessary once the work it guarded has succeeded:

```dart
final release = Lifecycle.onExit(unlock);
await deploy();
release();                               // it worked; nothing to undo
```

The signal watch keeps the isolate alive, so a script with no `Cli` around it must end with
`Lifecycle.exit`, `dart:io`'s `exit`, or `onExit(null)`.

It is a namespace rather than two top-level functions for one reason: a top-level `exit` would
**silently** shadow `dart:io`'s in every file importing this package — Dart resolves a name to
a non-platform library without calling it ambiguous, so `exit(0)` would quietly stop meaning
what it says. Namespaced, `dart:io`'s `exit` is untouched and does not run the listeners, which
is exactly what someone who typed it expects.

### Console

One namespace for everything that reaches a terminal: log lines, rules, prompts, and the three
indicators. They share a live region, so they compose — a log line written while a spinner is
running scrolls above it instead of landing on top of it.

```dart
final spinner = Console.spinner('Connecting');
Console.info('resolved 3 hosts');     // scrolls above; the spinner keeps spinning
spinner.text = 'Fetching the index';  // redraws without restarting the animation
spinner.succeed('index ready');
```

```
  i resolved 3 hosts
  ! one host was slow
| Fetching the index (255ms)     <- the live row, redrawn in place
```

Logging is levelled and written through `Io`, so a redirected sink captures it:

| | |
|---|---|
| `Console.debug/info/ok/warn/error(msg)` | `· ℹ ✓ ⚠ ✖`; `warn` and `error` go to stderr |
| `Console.level`, `Console.isEnabled(l)` | the floor, `LogLevel.debug` … `silent` |
| `Console.silenced(action)` | mutes *that* action and what it awaits, not the process |
| `Console.stages(n)` | a self-numbering `[1/n] message` banner |
| `Console.writeln(msg)` | unlevelled, still above the live region |

The three indicators, each driven directly or through the sugar:

| | |
|---|---|
| `Console.spinner(msg, style:)` | indeterminate; `text`, `succeed`, `fail`, `warn`, `info`, `stop` |
| `Console.spin(msg, action)` | the same, ended for you when `action` settles |
| `Console.progress(total)` | one measurable thing; `tick([n, label])`, `done([msg])` |
| `Console.tasks(slots:)` | a board of concurrent rows; `report(batch)`, `done([msg])` |
| `stream.show(slots:)` | any `Stream<BatchProgress>` straight onto a board |

`SpinnerStyle` names the frames and the interval — `braille` (the default), `dot`, `line`,
`ellipsis`, `bar`, `arc` — and takes any others, so a program with its own is not stuck
choosing from the list:

```dart
const pulse = SpinnerStyle(['·', 'o', 'O', 'o'], interval: Duration(milliseconds: 120));
Console.spinner('Waiting', style: pulse);
```

Without a terminal every one of these degrades to durable lines rather than escape codes: the
spinner writes once when it starts and once when it ends, and a progress bar reports each new
tenth. A captured log reads the same without the animation.

### Testable IO

Every console write — including subprocess output — goes through `Io`, which also drives
terminal detection, so redirecting the sink redirects what gets rendered. Every request goes
through a `Client`, so a handler-backed one stands in for the network. `make` runs analyze,
format and the tests; `make native` builds the Rust library for this machine.

```dart
final buffer = StringBuffer();
Io.out = buffer;
Console.ok('captured, not printed');
await run('echo also-captured');
Io.reset();

final client = MockClient((req) async => Response('{"ok": true}', 200));
await Http.scope(() => url.json(), client: client);
```

No request method takes a `client:` of its own: the scope is where a program says which
client to use, once, and everything inside it — requests, downloads, a whole crawl — uses it.

---

## Executables

`bin/` holds the two programs this package ships. [`tk.dart`](bin/tk.dart) is the toolkit as a
command-line tool (`hash`, `find`, `read`, `fetch`, `pack`, `peek`), each command a few lines
over the library; [`keybox.dart`](bin/keybox.dart) is the program the brevity rules in
`CONVENTIONS.md` are measured against.

```sh
dart run bin/tk.dart find 'lib/**/*.dart' --top 5
dart run bin/tk.dart read pubspec.yaml --query '$.dependencies.*'
```

## Guide

[`GUIDE.md`](GUIDE.md) is the manual to this one's tour: every module in full, a cookbook of
whole programs, and the testing, performance and troubleshooting notes.

## Conventions

[`CONVENTIONS.md`](CONVENTIONS.md) records the rules this API follows, so additions do
not re-create what the audits behind them found. [`CHANGELOG.md`](CHANGELOG.md) records what each
release contains.

## License

MIT — see [LICENSE](LICENSE).
