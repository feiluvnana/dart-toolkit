# The dart_toolkit guide

The manual: every module, then a cookbook. [`README.md`](README.md) is the tour,
[`CONVENTIONS.md`](CONVENTIONS.md) the rationale, [`CHANGELOG.md`](CHANGELOG.md) the history.
This guide describes 0.0.6.

**Contents:** [Start here](#start-here) · [`core`](#core) · [`async`](#async) ·
[`collection`](#collection) · [`formats`](#formats) · [`fs`](#fs) · [`hash`](#hash) ·
[`process`](#process) · [`http`](#http) · [`cli`](#cli) · [`native`](#native) ·
[Cookbook](#cookbook) · [Testing](#testing) · [Performance](#performance-notes) ·
[Troubleshooting](#troubleshooting)

---

## Start here

### Installing

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

```dart
import 'package:dart_toolkit/dart_toolkit.dart';   // every module except chrome.dart and tui.dart
```

A single module (`package:dart_toolkit/http.dart`, …) is for a program that measured its
startup. Hashing, archives, br/zstd and legacy charsets need the [native library](#native).

### A first program

```dart
Future<void> main() => Http.scope(() async {
  final doc = await 'https://news.ycombinator.com'.url.get().html;
  for (final row in doc.$('tr.athing')) {
    print(row.$('.titleline > a').text);
  }
});
```

### The six ideas

1. **A conversion is the way in**; the vocabulary lives on the result:
   ```dart
   'https://x.com'.url; '/tmp/a.txt'.path; '{"a":1}'.json; 'a: 1'.yaml;
   '<p>hi</p>'.html; '<a/>'.xml; [1, 2, 3].sequence; 60.s;
   ```
2. **A setting every call would repeat belongs to a scope** — `Http.scope`, `Shell.scope`,
   `Cancel.scope`. A per-call argument still wins.
3. **Where many things happen, a failure is a value.** `parallelize`, `Pool` and crawls settle
   each item into `Either`; pick `.rights`, `.lefts`, `.unwrap()` or a `switch`.
4. **A guaranteed value is not nullable.** `ctx(opt)` with a default, `row.number('size')`,
   `els.text`, `doc.to<int>()` return the value or throw naming what was missing. `…OrNull`
   is for expected absence.
5. **One word per idea.** A default is `or`; a body is `text`/`bytes`/`form`/`json`/`files`;
   one file or a thousand is `download`; serialised markup is `markup`; a sync twin (only in
   `fs`) ends in `Sync`.
6. **The short form is sugar over a class.** `parallelize` → `Pool`/`Worker`;
   `url.scrape<T>()` → `Crawler<T>`.

### The modules

| library | holds | imports |
|---|---|---|
| `core.dart` | `Either`, `Env`, `Io`, `.url`, `60.s`, progress interfaces | — |
| `async.dart` | `Cancel`, `parallelize`, `Worker`, `Pool`, `retry`, `Semaphore`, stream operators | `core` |
| `collection.dart` | `Sequence`, `Group`, `Table`, `Row` | `core` |
| `formats.dart` | `JsonDocument`, `YamlDocument`, TOML, INI, the HTML/XML tree, `$`, `$x` | `core`, `collection` |
| `fs.dart` | `Path`, watching, archives, compression | `core`, `hash`, `native` |
| `hash.dart` | `Hash`, `Secure`, hex/base64/base32 | `native` |
| `process.dart` | `run`, `ShellRun`, `Shell.scope`, pipelines, `which` | `core`, `fs` |
| `http.dart` | `Request`, `Response`, `Client`, `Http.scope`, `Crawler`, downloads | `async`, `core`, `formats`, `fs`, `hash`, `native` |
| `chrome.dart` | `ChromeClient`, `ChromePage`, `Device`, `Resource` — **not in the barrel** | `async`, `formats`, `fs`, `http` |
| `cli.dart` | `Opt`, `Arg`, `CliCommand`, `Cli`, `Lifecycle`, `Console` | `core` |
| `tui.dart` | `Tui`, `TuiApp`, widgets, `Key`/`Char`/`Mouse`, `FakeTerminal` — **not in the barrel** | `core` |
| `native.dart` | `NativeLib` | — |

---

## `core`

### `Either`

`Left` (failure) or `Right` (success), as `parallelize`, `Pool` and `scrape` hand back.

```dart
final [outcome] = await [url].parallelize(fetch).toList();
outcome.rightOrNull ?? fallback;
outcome.unwrap();                       // the value, or throw the Left with its trace
switch (outcome) {
  case Right(:final value): use(value);
  case Left(:final value): Console.warn('$value');
}

settled.rights; settled.lefts; settled.unwrap();   // on a list, a stream, or a future of a list
await urls.parallelize(fetch).rights.toList();
```

### `Env`

The environment with in-memory overrides; an empty variable counts as unset.

```dart
Env.get('API_TOKEN');                         // throws, naming the key, when unset
Env.get('PORT', or: '8080');
Env.getOrNull('HOME'); Env.has('CI'); Env.isCI;
Env.set('TZ', 'UTC');                         // children of `run` inherit it
Env.load();                                   // .env into the overrides
Env.load(path: '.env.local', override: true); // …beating the real environment
Env.parse('URL=http://x/#frag # a comment');  // {URL: http://x/#frag}; `#` after whitespace only
```

### `Io`

Every terminal write goes through `Io`; redirect it and console, logger and subprocess output
follow.

```dart
Io.out = StringBuffer();   // capture; Io.reset() restores
Io.isTerminal; Io.isRedirected; Io.columns;
Io.color;                  // per sink: `app 2>log` gets no escape codes
await Io.readLine();       // on a helper isolate, so ^C is still heard
Io.input = () => 'scripted answer';
Io.width('名前');          // 4 terminal columns
Io.truncate(text, 40);
```

### Small conversions

```dart
'https://x.com/a'.url;                 // Uri
'2024-05-06'.match(RegExp(r'\d{4}'));  // '2024', or null
100.ms; 5.s; 2.m; 1.h; 3.d;
30.s.humanized;                        // '30s'
(20 * 1000 * 1000).humanBytes;         // '20.0 MB'
await 1.s.delay();
```

`TaskProgress` and `BatchProgress` let `fs` and `http` report to `cli` without importing it;
any `Stream<BatchProgress>` draws with `.show()`.

---

## `async`

### Cancellation

A token is never passed as an argument. `Cancel.scope` holds it, and `download`, `retry`,
`run`, `parallelize`, `Pool`, `Semaphore`, `Duration.delay` and `.cancellable` read it.

```dart
await Cancel.scope(timeout: 5.s, () async {    // or token: stop
  await for (final item in feed.cancellable) print(item);
});

final token = CancelToken();
final undo = token.onCancel(() => print('cleaning up'));   // returns its own removal
token.cancel('done');
```

- A nested scope hears the outer one.
- `Cancel.isCancelled`, `Cancel.reason`, `Cancel.throwIfCancelled()` are quiet outside a scope;
  `.cancellable` throws outside one.
- `Cli.run` opens the scope (`ctx.cancel`); ^C cancels it.

### `parallelize`

```dart
final settled = await urls.parallelize((u) => u.get(), concurrency: 8).toList(); // List<Either<Object, Response>>
final streamed = pages.parallelize(parse, concurrency: 4);                      // Stream, as items finish
final digests = await blobs.parallelize(slowDigest, isolate: true).toList();     // long-lived isolates
```

With `isolate: true` each item and result crosses a port; the function crosses once per
isolate.

### `Worker` and `Pool`

The class under `parallelize`, for state built once per worker.

```dart
final class Thumbnail extends Worker<Path, int> {
  late final RegExp image;
  @override
  void init() => image = RegExp(r'\.(png|jpe?g)$');   // once per isolate
  @override
  Future<int> run(Path file) async => image.hasMatch(file) ? await file.size() : 0;
}

final pool = await Pool.spawn(Thumbnail.new, size: 4);
await for (final size in pool.map(files).rights) print(size);
await pool.close();
```

`Pool.spawn(create, size:, isolate:)` takes a sendable factory and waits for every `init`
(`isolate: false` for IO-bound work). `pool.run(item)` throws what `run` threw; `pool.map(items)`
yields in completion order (`ordered: true` for input order), at most `size` in flight; `pool.close()` runs each `close`, idempotently. A failing
item fails only itself, a dead isolate is replaced, and cancel stops the item in flight.

### `retry`, `Semaphore`

```dart
final data = await retry(
  () => api.get().json,
  retries: 2, delay: 200.ms, maxDelay: 5.s,
  when: (e) => e is! FormatException,
  onRetry: (n, e, next) => Console.warn('attempt $n failed; waiting $next'),
);                                              // the backoff ends on cancel

final gate = Semaphore(4);
await gate.run(() => work());                   // Semaphore(1) is a lock
```

### Stream operators

All honour pause and cancel their timers.

```dart
numbers.chunk(100); numbers.chunkEvery(1.s);    // fixed-size lists; whatever arrived per window
numbers.debounce(300.ms); numbers.throttle(1.s); // last of a burst; at most one per window
numbers.flatMap((n) => Stream.value(n * 2)); [numbers, numbers].merge();
```

---

## `collection`

### `Sequence` — a lazy query

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc)
    .thenBy((t) => t.number, descending: true)
    .take(10);

for (final (k, v) in counts.sequence.sortedByValue(descending: true).take(3)) print('$k $v');
```

| | |
|---|---|
| shape | `where`, `map`, `expand`, `take`, `skip`, `takeWhile`, `skipWhile`, `takeLast`, `skipLast` |
| order | `sortedBy`, `sortedWith`, `sorted`, `sortedDescending`, `thenBy`, `reversed` (a sort reruns on every read) |
| windows | `chunk(n)`, `windowed(n, step:)` (holds only its window), `pairwise`, `indexed` |
| sets | `distinct`, `distinctBy`, `union`, `intersect`, `except` |
| pairs, joins | `zip`, `innerJoin`, `leftJoin` |
| grouping | `groupBy`, `countBy`, `indexBy`, `partition` |
| folds | `sum`, `average`, `sumBy`, `averageBy`, `max`, `min`, `maxBy`, `minBy` (`sum`/`max`/`sorted` only on `num`/`Comparable`; `sum` of ints is an `int`) |
| ranges | `Sequence.range(count)`, `Sequence.range(from, to, step)` |

### `Table` — rows of named columns

```dart
final sales = await Table.read('sales.csv');      // .csv .tsv .json .ndjson/.jsonl   (also Doc.table)
await for (final row in Table.readRows('huge.csv')) print(row['id']);   // streamed
Table.rows(maps);
Table.cells(['name', 'size'], [['a', 1], ['b', 2]]);
Table.csv(text);                                  // quotes, CRLF, BOM
doc.$('table#songs').table;                       // an HTML <table>

sales
    .where((r) => r.number('amount') > 100)
    .orderBy('region')
    .thenBy('amount', descending: true)
    .take(20)                                     // straight after orderBy: selects, not a full sort
    .select(['region', 'amount'])
    .derive('k', (r) => r.number('amount') / 1000)
    .show();
sales.groupBy('region').sum('amount');
sales.pivot(rows: 'region', column: 'month', value: 'amount', agg: Agg.sum);
sales.join(regions, on: 'region');
```

- Cells: `row.text('name')`, `row.number('size')`, `row.numberOrNull('size')`,
  `row.get<int>('n')`, `row.get<DateTime>('at')` (ISO 8601). A thousands separator is stripped
  only where it groups thousands (`'1,5'` is not 15). `t.numbers('bytes')` is a `Sequence<num>`.
- Writing: `toCsv()`, `toNdjson()`, `toMarkdown()`, `toJson()`, `await t.save(path)` (by
  extension, incl. `.md`), and `t.show()` for the console.
- CSV: a repeated header reads as `name_2`; a blank line is not a row (`""` is); an unclosed
  quote is a `FormatException` naming its line.

---

## `formats`

Every parser is the package's own, diff-tested against `package:html`, `xml` and `yaml`.

### Data: one document model

JSON, YAML, TOML and INI decode to `JsonDocument`.

```dart
final pubspec = await JsonDocument.read('pubspec.yaml');   // .json .yaml .yml .toml .ini .cfg .conf
final name = pubspec['name'].to<String>();                 // or StateError naming $.name
final port = pubspec['port'].or(8080);                     // absence expected; T from the default
final tags = pubspec['topics'].to<List<String>>();
final deps = pubspec['dependencies'].to<Map<String, Object?>>();
await pubspec.save('pubspec.json');                        // JSON, or YAML for .yaml/.yml

doc.list; doc.map; doc.raw; doc.isNull; doc.toYaml();
```

- `to<T>()` throws `StateError('$.server.port is "x" (String), expected int')`; `to<int>()` on
  `1.7` is a mismatch. `to<DateTime>()` reads ISO 8601. `toOrNull<T>()` for a `null` answer.
- Typed lists and maps work for `String`, `int`, `double`, `num`, `bool`.

**YAML** — `.yaml` is the first document; `.documents` is the stream. Anchors, aliases, merge
keys (`<<: *base`, `<<: [*a, *b]`), block scalars, multi-line quoted scalars, `%` directives and
`!!str` work. Duplicate keys, bad escapes, unterminated collections and nesting past 1000 throw
`FormatException` with the line.

```dart
final stream = '---\na: 1\n---\nb: 2'.yaml;
stream['a'].to<int>();                   // 1
stream.documents.map((d) => d.raw);      // ({a: 1}, {b: 2})
```

**TOML and INI** — `text.toml`, `text.ini`. TOML redefinitions are errors. An INI value becomes
a number only if it reads back exactly (`1.10`, `01234`, `0x10` stay text); a key that cannot
nest stays whole; quoted section parts keep their dots (`[remote "origin"]`).

**JSONPath** — `$` returns a list of documents. Filters (`[?(…)]`) are a `FormatException`;
use `.where`.

```dart
doc.$(r'$.items[*].id');
doc.$(r'$..name');          // recursive descent
doc.$(r'$.items[1:3]');     // slices, incl. [::-1], [-2:]
doc.$(r"$['a','x.y']");     // unions
```

### Markup: one tree

HTML and XML share `Node`, `Element`, `Text`, `Attribute`, `Nodes`, `Elements`. **`$` is CSS
and `$x` is XPath** on every document.

```dart
final page = await url.get().html;                  // or res.html, '<p>…</p>'.html
page.$('h1').text;                                  // the first match
page.$('td.title > a[href]').attr('href');          // or StateError naming the tag
page.$('link[rel=next]').attrOrNull('href');
page.$('a.download').attrs('href');                 // every match, as written
page.$('a.download, img').links;                    // href or src as Uri, resolved
page.$('#songs tr').$('td:nth-child(3)').texts;     // query a result again
page.$('ul.menu').first.$('> li');                  // `> li`, `+ dd`, `~ p` read from the element
page.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;
```

On an `Element`:

```dart
e.name; e.id; e.classes; e.attributes; e.attr('href'); e.attrOrNull('rel');
e.text;          // the string value
e.lines;         // readable: breaks at blocks, tabs between cells, no script/style/head
e.children; e.parent; e.nextElement;
e.markup; e.innerMarkup;
e.table;         // a Table: repeated headers become Price_2, colspan/rowspan fill
```

- On `Elements`, `text`, `lines`, `attr`, `markup` answer for the first match and throw when
  none (`attrOrNull` → `null`, `table` → empty); `texts`, `attrs`, `links` answer for all.
  `$x` returns `Nodes` (it can select attributes and text); `.elements` narrows.
- `links` resolve against `<base href>`, itself resolved against the fetched URL (`res.html`
  knows it; `Doc.html(text, url: …)` takes it).
- **HTML parses as a browser reads it**: `<a>one<a>two` is two links; `/>` counts only in
  SVG/MathML; `<pre>` drops its first newline; legacy entities without `;` never decode inside an
  attribute before `=`/alphanumeric (`?a=1&lang=en` stays); SVG names keep their case. No foster
  parenting: stray content inside `<table>` stays there.
- **CSS**: combinators, attribute operators, `:nth-child(an+b)`, `:nth-of-type`,
  `:nth-last-of-type`, `:only-of-type`, `:not`, `:is`, `:where`, `:contains(text)`, relative
  `:has(> img)`/`:has(+ dd)`/`:has(~ p)`, escapes (`.md\:flex`).
- **XPath 1.0**: all axes (reverse-axis positions count from the context), `+ - * div mod`,
  comparisons, and `contains`, `starts-with`, `normalize-space`, `translate`, `substring`,
  `string-length`, `count`, `sum`, `floor`, `ceiling`, `round`, `position`, `last`, `not`.
  Results are in document order; a number/string expression is a `FormatException`.

```dart
'<ul><li>1<li>2<li>3</ul>'.html.$x('//li[3]/preceding-sibling::li[1]').texts;   // [2]
final feed = await url.get().xml;                     // XML keeps case and prefixes
feed.$x('//media:content/@url').texts;
```

A document nested 100 000 deep parses, queries and serialises without overflowing the stack.

---

## `fs`

`Path` is an extension type over `String`, free at runtime.

### Building and asking

```dart
final dir = Path.temp / 'my_project';     // also Path.home, Path.current
final file = dir / 'config.json';
'AIR / Farewell'.filename;                // one safe component: 'AIR _ Farewell'; '..' → '__'

file.name; file.stem; file.ext; file.parent; file.segments;
file.normalized; file.absolute; file.relativeTo(dir); file.withExt('yaml'); file.sanitized;

await file.exists(); await file.size(); await file.modified();
await file.olderThan(1.h);                // true when missing
(await dir.size()).humanBytes;            // '20.0 MB'

final names = await Path.tempDir((tmp) async {   // a fresh folder, deleted afterwards
  await 'bundle.zip'.path.extractTo(tmp);
  return [for (final f in tmp.filesSync(recursive: true)) f.name];
});
```

`Path` cannot override `==`: normalise before using paths as map keys.

### Reading and writing

Each has a `…Sync` twin (only `fs` has them).

```dart
await file.readText(); await file.readBytes(); await file.readLines();
file.lines();                             // Stream<String>
await file.writeText('x'); await file.append('y');
await file.copy(dir / 'b'); await file.move(dir / 'c');
await (dir / 'run.sh').chmod('+x');       // or '755', 'go-w', 'u=rw,go=r'
await dir.delete(recursive: true);
```

- **`writeText`, `writeBytes` and `writeLines` are atomic** (temp file, then rename): a reader or a
  ^C sees old or new, never half. `append` writes in place.
  Permissions and links are kept; a read-only file still refuses; devices and FIFOs are written
  in place.
- `copy` keeps directory modes. `move` copies-and-deletes only across filesystems, and refuses
  to merge into a non-empty directory.

### Listing and watching

```dart
dir.list(recursive: true);               // Stream<Path>
dir.files(recursive: true);
dir.glob('lib/**/*.dart');               // unreadable directories skipped
dir.glob('{lib,test}/**/*.{dart,md}');
dir.globSync('img/[a-c]?.png');          // [!…] for outside a set
dir.globSync('**/build/');               // trailing / matches directories

await for (final batch in dir.changes(debounce: 200.ms)) print(batch);   // Set<Path> per burst
```

Raw watch events: `dir.asDir.watch()`.

### Archives and compression

Writing takes the format from the extension; reading sniffs the magic number.

```dart
await dir.archiveTo('project.7z', password: 'pw');   // .zip .7z .tar .tar.gz .tar.zst .tar.xz .tar.bz2
await 'photos.rar'.path.extractTo('out');            // rar is read-only
await 'bundle.zip'.path.extractTo('docs', only: '**/*.md');
final readme = await 'bundle.zip'.path.entry('docs/README.md');   // Uint8List
for (final e in await 'bundle.zip'.path.entries()) print('${e.name} ${e.size}');

await 'app.log'.path.compressTo('app.log.zst');      // gzip, xz, zstd, bzip2
await 'blob.gz'.path.decompressTo('blob');
```

**Archives are untrusted by default**: setuid/setgid/sticky bits dropped, links out of the
destination refused, output capped at 200× the archive (min 1 GiB). `trusted: true` lifts
these; a path escaping the destination is always refused. Everything runs off the main isolate
(no `extractToSync`).

---

## `hash`

Native, identical on every platform, checked against published vectors. `hash`, `hashBytes`,
`checksum`, `hmac`, `hmacBytes` exist on `String`, `List<int>` and `Path`.

```dart
'abc'.hash(Hash.sha256);
bytes.hash(Hash.blake3);
await file.hash(Hash.xxh3);                  // the library reads the file
await file.checksum(Hash.crc32);             // an int
'body'.hmac(Hash.sha256, 'secret');
await file.hmac(Hash.sha512, key);           // streamed
'body'.hmac(Hash.blake2b, 'key');            // BLAKE2/BLAKE3 keyed mode

final digests = await files.hash(Hash.xxh3); // Map<Path, String>, parallel
final twins = await dir.duplicates();        // List<List<Path>>: same size, then same xxh3

Secure.token(); Secure.uuid(); Secure.bytes(32);
Secure.equals(a, b);                         // constant time
bytes.hex; bytes.base64; bytes.base64Url; bytes.base32;
'6869'.hexBytes;                             // strict
```

Algorithms: `md5`, `sha1`, SHA-2 (`sha224`…`sha512_256`), SHA-3, `keccak256`, `blake2s`,
`blake2b`, `blake3`, `ripemd160`, and the checksums `crc32`, `crc32c`, `xxh64`, `xxh3`
(`Hash.isChecksum`; a checksum MAC is an `ArgumentError`). No encryption, password hashing,
signatures or JWT.

---

## `process`

### `run`

```dart
final res = await run('git status --short');
res.isOk; res.text; res.lines; res.exitCode; res.stdout; res.stderr;
```

By default `run` echoes output and throws `ShellException` on non-zero exit. The getter you
chain sets the policy: `.text`/`.lines` imply `quiet`, `.isOk` implies `quiet` and
`strict: false`. An explicit argument still wins.

| argument | |
|---|---|
| `input:` | written to stdin (otherwise closed at once) |
| `workdir:`, `env:`, `timeout:`, `encoding:`, `quiet:`, `strict:` | per call, or from `Shell.scope` |
| `args:` | appended verbatim, never re-read; `$1`, `$2`… under `shell: true` |
| `shell: true` | unsplit to `/bin/sh -c` (`cmd /c`): pipes, globs, `&&`, `$VAR` |
| `inherit: true` | the child gets this terminal (`git commit`, `ssh`, `vim`) |

```dart
await run('git commit -m', args: [message]);                     // never interpolate untrusted values
await run(r'grep -c "$1" *.log', shell: true, args: [pattern]);

await for (final line in run('tail -f app.log').stream) {        // leaving the loop stops it
  if (line.contains('ready')) break;
}

final server = run('dart run bin/server.dart');                  // not awaited
await run('dart test');
await server.kill();                                             // the server and its children
```

- The string splits like a shell's simple command: an unclosed quote is a `FormatException`;
  unquoted shell syntax (`| & ; < >`, a backtick, the globs `* ? [`, a leading `~`, `$VAR`, `${`,
  `$(`) is an `ArgumentError` pointing at `shell: true` (or `Path.glob` for a glob).
- Cancel, `timeout` or ^C send SIGTERM to the whole tree, SIGKILL after 2 s. Cancel throws
  `CancelledException`; timeout throws `ShellTimeoutException` (a `TimeoutException` whose
  `.result` holds the output so far).
- Non-UTF-8 output decodes with U+FFFD. Missing executable is exit 127, not runnable 126;
  `which` finds only runnable files.
- A pipeline stage killed by its reader exiting (`yes | head -1`) is not a failure.
- Windows: `PATH` programs run directly; only `.bat`/`.cmd`/built-ins go through `cmd.exe`,
  where an argument holding `& | < > ^ % "` is refused.

### Pipelines and the scope

```dart
final count = await ('git ls-files' | 'wc -l').run().text;      // pipefail

await Shell.scope(workdir: repo, env: {'GIT_TERMINAL_PROMPT': '0'}, timeout: 30.s, () async {
  await run('git fetch --all');
});
```

---

## `http`

### Requests and responses

The verbs are methods on `Uri`.

```dart
await url.get(); await url.head(); await url.delete();
await url.post(json: {'name': 'x'});
await url.put(text: 'body');
await url.patch(form: {'q': 'dart'});
await url.post(form: {'title': 'holiday'}, files: {'photo': 'beach.jpg'.path});  // multipart, streamed
await url.get().json;       // throws unless 2xx: `HttpException: 404 Not Found, uri = …`
await url.get().text; await url.get().html; await url.get().xml; await url.get().bytes;
await Request('POST', url, json: {'n': 1}).send();
url / 'users';
url.withQuery({'page': 2, 'q': null});
```

A body is `text:`, `bytes:`, `form:`, `json:` or `files:`, here, on `Request` and on `follow`.
Awaiting the verb itself gives the `Response` whatever its status:

```dart
final res = await url.post(json: {'n': 1});
res.statusCode; res.isOk; res.isRedirect; res.headers; res.url;   // url: the one that answered
res.text;    // charset: BOM, then content-type, then (HTML) <meta>; else UTF-8
res.bytes; res.json; res.html; res.xml;   // each parsed once
```

Sending consumes a `Request`; `req.copy()` to send it twice.

**Events** — SSE, NDJSON, a log — are `events()`; `json:` makes it a POST; leaving the loop
closes the connection. `text/event-stream` is read as a browser does; anything else is an event
per non-empty line.

```dart
await for (final e in api.events(json: {'stream': true, 'prompt': 'hi'})) {
  stdout.write(e.data.json['text'].to<String>());   // e.event, e.data, e.id
}
```

### The scope

No function takes a `client:`. `Http.scope` names it once, with settings every request would
repeat.

```dart
await Http.scope(timeout: 30.s, retries: 2, delay: 500.ms, headers: {'user-agent': 'me/1.0'}, () async {
  for (final u in urls) print((await u.get()).statusCode);
});
await Http.scope(cache: '.cache'.path, () => home.scrape<String>().onResponse(parse).rights.toList());
```

| argument | |
|---|---|
| `client:` | used by every request inside; closed on exit unless you supplied it |
| `timeout:` | bounds headers **and** each body chunk |
| `headers:` | added where unset; `authorization`/`cookie` only to the first request's origin |
| `cookies: true` | a jar for the scope, walking redirects hop by hop |
| `jar:` | the same, seeded — e.g. `await page.cookies()` after a browser login |
| `retries:` | transport errors (incl. a cut-off body), 5xx, 429/503 honouring `Retry-After` (≤30 s); never TLS; never a second POST/PATCH unless `Retry-After` said when |
| `delay:` | gap between requests to one host, redirects and downloads included, jittered ±25 % |
| `cache:` | a folder keeping GETs with `ETag`/`Last-Modified`; next run asks conditionally, a `304` is served from disk |

Every wait in the scope stops on cancel. Cookies: lenient RFC 6265 dates (PHP's
`Wed, 21-Oct-2026` works), an empty `Domain=` ignored, a `Secure` cookie over http refused.

### Clients

A `Client` is `send` and `close`. Hold one to call it directly, without a scope.

```dart
await Http.scope(client: IoClient(connections: 32, perHost: 6, proxy: proxy), () async {/* … */});
await chrome.get(url).html;                            // a held client, no scope
await chrome.page(url, (p) => p.click('.download'));   // only Chrome has tabs
```

- **`IoClient`**: `dart:io` plus connection limits; `gzip`, and `br`/`zstd` with the native
  library, decoded while streaming; its own redirect walk (303 and non-GET 301/302 become a
  bodiless GET; 307/308 keep method and body; credentials stop at another host, port, or
  `https`→`http`). Small redirect bodies are drained so the connection is reused.
- **`RequestKey<T>`** tells a client something HTTP can't; unknown keys are ignored, so one
  crawl runs on any client. `Request.raw` must be honoured by all: the resource itself, never a
  rendering, with `accept-encoding: identity`. Every download sets it.
- Your own client: implement the two methods and run `test/client_conformance.dart` on it.

### Chrome

`ChromeClient` speaks the DevTools protocol to the installed Chrome. A page comes back as its
DOM **after its own scripts ran**, so `$`, `$x` and crawls work unchanged.

```dart
import 'package:dart_toolkit/chrome.dart';     // beside the barrel
```

| | |
|---|---|
| `ChromeClient.launch()` | a fresh browser, owned and killed by the client |
| `ChromeClient.launch(profile: dir)` | owned, keeps cookies and logins between runs |
| `ChromeClient.connect()` | joins port 9222, else starts one that outlives the run (`~/.dart_toolkit/chrome`); never killed |

```dart
final chrome = await ChromeClient.launch(
  tabs: 4,                    // pages rendering at once
  block: Resource.heavy,      // no images, fonts, media
  device: Device.phone,
  wait: ChromeWait.idle,
  challenge: 20.s,            // how long an interstitial may take to clear
  proxy: 'http://user:pass@host:8080'.url,
);

url.scrape<String>().onRequest((ctx) {        // per request
  ctx[ChromeClient.waitFor] = '.results .item';
  ctx[ChromeClient.script] = 'window.scrollTo(0, document.body.scrollHeight)';
  ctx[ChromeClient.block] = Resource.heavy;
});
```

- Only a GET without `range` is rendered; POSTs, resumable downloads and assets go to the plain
  client underneath, with the browser's cookies and user-agent.
- Nothing lands in your working directory: downloads go to a temp folder and only finished
  files move into `to:`; abandoned ones are cancelled and erased.
- Credentials stay on their origin: scope cookies go to the page's URL only, `authorization`
  never to a CDN or tracker.
- A launched Chrome dies with the program, even on `kill -9` (macOS/Linux; Windows on `close()`
  only), taking its temp profile. Still call `close()` so the program can exit.
- A dead browser sets `isClosed`, and calls fail with `ClientException('The browser disconnected')`.
- A page is never lost: an expired wait or uncleared challenge returns the DOM as it stands;
  only a refused navigation (DNS, connection refused) throws.
- Background downloads (component updates, optimisation guides) are disabled; your
  `--disable-features=` merges with the built-in list (`launch` only; `connect` passes `args` as given).

### Driving a page

A wait takes the action that triggers it, so it is armed first.

```dart
final page = await chrome.open(loginUrl);
await page.fill('#user', 'me');
await page.waitForNavigation(() => page.click('button[type=submit]'));
await page.waitFor('.dashboard');                // false on timeout
print((await page.html()).$('.balance').text);
final file = await page.waitForDownload(() => page.click('.download'), to: 'books'.path);
final api = await page.waitForResponse('/api/items', () => page.click('.more'));
print(api!.json['items']);                       // the JSON behind the page
await page.close();
```

`waitForDownload`'s `timeout` is how long the transfer may go quiet. `waitForResponse`
rethrows from `action`.

| | |
|---|---|
| `goto(url)`, `back()`, `forward()` | navigation; `goto(page.url)` reloads |
| `html()`, `response()`, `url`, `statusCode` | what the tab holds now |
| `waitFor(sel)`, `waitWhile(sel)` | a mutation observer; `false` on timeout |
| `click`, `fill`, `press`, `select`, `hover`, `upload` | real input events, DOM fallback |
| `text(sel)`, `attr(sel, name)`, `has(sel)` | one value off the live page |
| `frame(match)` | an iframe as a page |
| `scroll(times:, settle:)`, `scroll(toEnd: true)` | an infinite feed |
| `eval(js)`, `screenshot()`, `pdf()` | anything else |
| `cookies([restore])`, `headers(map)`, `block(kinds)` | the whole cookie jar, tab headers, filters |
| `onDialog(handler)` | answer `alert`/`confirm`/`prompt`; otherwise dismissed |

### Crawling

The chain of five hooks yields a stream of `Either`s.

```dart
final stories = 'https://news.ycombinator.com'.url
    .scrape<({String title, Uri link})>()
    .onInit((ctx) => ctx..concurrency = 8..delay = 200.ms..pages = 50..robots = true)
    .onRequest((ctx) => ctx.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      for (final a in ctx.html.$('.titleline > a')) {
        ctx.emit((title: a.text, link: ctx.resolve(a)));
      }
      ctx.follow(ctx.html.$('a.morelink'));
    })
    .onError((ctx) => Console.warn('${ctx.failure}'))
    .onFinish((summary) => Console.info('$summary'));

await Http.scope(() => stories.rights.forEach(print));
```

The class form has the same hooks as methods, with state in fields:

```dart
final class Titles extends Crawler<String> {
  final Uri home;
  final seen = <String>{};
  Titles(this.home);

  @override
  void onInit(InitContext<String> ctx) => ctx..seed(home)..sitemaps = true;
  @override
  void onResponse(ResponseContext<String> ctx) {
    for (final h in ctx.html.$('h1, h2')) {
      if (seen.add(h.text)) ctx.emit(h.text);
    }
  }
  @override
  void onError(ErrorContext<String> ctx) => ctx.ignore();
}

Future<List<String>> titles(Uri home) => Http.scope(() => Titles(home).run().rights.toList());
```

Seeds: `url.scrape<T>()`, `urls.scrape<T>()`, `requests.scrape<T>()`, `ctx.seed(url)` in
`onInit`, or `client.scrape<T>(seeds)`.

**`onInit`** runs once (may be async):

| setting | default | |
|---|---|---|
| `concurrency` | 16 | requests in flight overall |
| `perHost` | 8 | in flight to one host |
| `delay` | 0 | gap between requests to one host |
| `timeout` | 30 s | headers, and each body chunk |
| `retries` | 2 | transport errors and 5xx; never TLS |
| `redirects` | 5 | hops before failing |
| `bodyLimit` | 16 MB | bytes read before abandoning |
| `pages` / `depth` | — | stop after N pages / drop beyond N hops |
| `scope` | the seeds' hosts | where `follow` may go |
| `robots` | false | obey each host's robots.txt for the user-agent sent |
| `sitemaps` | false | seed from robots.txt sitemaps or `/sitemap.xml` (indexes, `.gz`); under `pages`, only what the budget uses |
| `canonical` | — | `(Uri u) => …`: what makes two URLs one page (e.g. drop `sid`); the request still goes to the followed URL |

**`onRequest`** runs before each send: edit `ctx.request`, or `ctx.skip()`.

**`onResponse`** runs on each 2xx; `ctx.url` is the URL that answered, after redirects.

```dart
ctx.emit(item);
ctx.follow(href, meta: {'from': 'index'}, onResponse: (child) {/* … */});
ctx.follow(ctx.html.$('a.next'));          // elements: href, else src
ctx.follow(ctx.response.json['next']);     // a JsonDocument: a URL, a list, or null
ctx.resolve(href);                         // String, Uri or element, against <base href> or ctx.url
ctx.stop();
```

`follow` stays on the seeds' hosts (with or without `www.`), strips fragments and an empty `?`,
never fetches a URL twice (a redirect back into its own chain is allowed), takes any `Iterable`
of links, drops `mailto:`/`javascript:`, takes the same body words as `post`, and returns
`false` when it drops something.

**`onError`** runs when the engine gives up on a request:

```dart
url.scrape<String>().onError((ctx) => switch (ctx.failure) {
  StatusFailed(:final response) when response.statusCode == 404 => ctx.ignore(),
  RequestFailed() => ctx.retry(after: 2.s),
  _ => null,                                 // stays a Left
});
```

**`onFinish`** gets a `ScrapeSummary`: pages, failures, requests, retries, drops, bytes, time.
After `stop()`, in-flight failures are not reported (a throwing hook still is). Under `Cli.run`,
^C cancels the crawl.

### Downloads

Atomic (`.part`, renamed after `Content-Length` checks) and resumable (`Range` plus `If-Range`
from the first `ETag`/`Last-Modified`, so a changed file restarts whole).

```dart
await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, '9f86d0…')).show();
await {url: 'a.bin'.path}.download(concurrency: 4).show();
await pairs.download(concurrency: 8).show();   // Iterable<({Uri url, Path path})>
await found.download(concurrency: 8).show();   // a Stream: discovery and transfer overlap

await for (final p in {url: 'a.bin'.path}.download()) {   // progress by hand
  switch (p.current) {
    case Downloading(:final ratio): print(ratio);
    case Downloaded(:final bytes): print('$bytes B');
    case DownloadSkipped(): print('already there');
    case DownloadFailed(:final error): print(error);
  }
}
```

- `checksum:` mismatch deletes the `.part`; `ifModified:` makes a re-run a `304` check.
- Cancel stops downloads, even mid-body on a stalled server; each reports `DownloadFailed`
  with the `CancelledException`.
- `Http.scope(retries:, delay:)` applies; a cut-off transfer resumes from its last byte.
- Two pairs naming one destination are one download and one `DownloadSkipped`.

---

## `cli`

### Options and arguments are values

The name is written once; the type is what `ctx(…)` returns. The second positional is the help
line (on `Opt`, `Arg` and `CliCommand`).

```dart
enum Stage { dev, staging, production }

final stage = Opt.among('stage', Stage.values, 'Where to deploy').or(Stage.production); // Stage
final token = Opt.text('token').env('DEPLOY_TOKEN').required();       // String
final workers = Opt.number('workers').abbr('w').or(4);                // int
final dryRun = Opt.flag('dry-run', 'Print, do not deploy').abbr('d'); // bool
final headers = Opt.text('header').abbr('H').many();                  // List<String>
final since = Opt.by('since', DateTime.parse);                        // DateTime?

final id = Arg.text('id', 'The build').required();                    // String
final count = Arg.number('count').or(1);                              // int
final targets = Arg.text('targets').many().required();                // List<String>, ≥ 1
final files = Arg.by('files', Path.new).many();                       // List<Path>
```

| modifier | |
|---|---|
| `.abbr('n')` | `-n` |
| `.or(v)` | a default; `ctx(…)` becomes non-nullable |
| `.required()` | omitting it is a usage error |
| `.many()` | `-H a -H b` → `['a', 'b']` (else last wins); on an `Arg`, the rest, declared last |
| `.env('NAME')` | environment fallback; satisfies `required()`; `[env: NAME]` in help |

Flags take `--x`, `--no-x`, `--x=true|false|yes|no|1|0`; `Opt.flag('color').or(true)` is on until
`--no-color`, shown as `--[no-]color` in help. Short flags combine (`-dv`), values
attach (`-w8`, `-w=8`), and `-5` is a positional unless an option answers to it.

### Commands

```dart
final cli = Cli(
  version: '1.2.0',                              // name: defaults to the script's
  values: [id, stage, token, workers, dryRun],   // Args bind in listed order
  handler: (ctx) => Console.info('deploying ${ctx(id)} to ${ctx(stage).name}'),
  commands: [
    CliCommand('db', 'Database', commands: [
      CliCommand('migrate', 'Run migrations', handler: (ctx) {}),
    ]),
  ],
);
```

Built-ins, unless the program declares the name itself:

| built-in | |
|---|---|
| `-h, --help` | usage from the tree (`--top <int>`, `--mode <fast\|slow>`); subcommands list "Global options" |
| `--version` | when `version:` is set |
| `-v, --verbose` / `-q, --quiet` | `Console.level` to debug / warn |
| `--completion bash\|zsh\|fish` | a completion script: `source <(app --completion bash)` |

| exit | |
|---|---|
| 0 | the handler returned |
| 1 | the handler threw (`throw 'no such stage'`): one red line, trace under `-v` |
| 64 | usage error, with `Did you mean "build"?`; or subcommands with none given |
| 128+n | a signal; exit hooks ran |

`Cli.run` opens the `Cancel.scope` (`ctx.cancel`), so ^C stops downloads, processes, pools and
crawls.

### Lifecycle

```dart
final release = Lifecycle.onExit(() => print('cleaning up'));   // returns its removal
await Lifecycle.exit('no URL given');                            // hooks, red on stderr, exit 1
```

Hooks run in order on SIGINT, SIGTERM, `Lifecycle.exit` and the end of `Cli.run`; a second ^C
quits at once. Without a `Cli`, end with `Lifecycle.exit()` or `Lifecycle.onExit(null)` — the
signal watch keeps the isolate alive.

### Console

One live region: log lines, `print` inside `Cli.run` and child output scroll above spinners and
bars.

```dart
final spinner = Console.spinner('Connecting');
Console.info('resolved 3 hosts');
spinner.succeed('connected');                    // or fail, warn, stop()
final result = await Console.spin('Building', () => run('make'), done: 'Built');

final name = await Console.ask('Project name', or: 'app', validate: (v) => v.contains(' ') ? 'no spaces' : null);
final go = await Console.confirm('Continue?', or: true);
final password = await Console.secret('Password');
final stage = await Console.select('Stage', Stage.values, or: Stage.dev);
```

| | |
|---|---|
| `debug/info/ok/warn/error(msg)` | `· ℹ ✓ ⚠ ✖`; `warn`/`error` to stderr |
| `Console.level`, `Console.silenced(action)` | the floor; mute one action |
| `Console.stages(n)` | a `[1/n]` banner |
| `Console.spin(msg, action)` | a spinner ended when `action` settles |
| `Console.progress(total)` | one bar: `tick([n])`, `done()` |
| `Console.tasks()` / `stream.show()` | a board, a row per running task; `slots:` fixes the count |
| `Console.rule([title])`, `Console.writeln` | unlevelled; `print` inside `Cli.run` |
| `.bold`, `.red`, `.green`, `.dim`, … | styling on `String` |

Customizing: `ConsoleTheme` holds the tokens every part shares — palette (`accent`, `success`,
`warning`, `danger`, `muted`, `highlight`), marks (`ok`, `info`, `warn`, `error`, `debug`),
`indent`, spinner `frames`/`interval`, bar `fill`/`empty`/`head`, the table `border`, board
`tree` and prompt marks. A part's line is its builder, handed a typed view that carries the
theme (`p.bar(30)` draws in its glyphs):

```dart
Console.theme = ConsoleTheme(ok: '✔', accent: (s) => s.magenta);       // process-wide
await Console.themed(ConsoleTheme.ascii, () => build());               // one piece of work
Console.progress(n, line: (p) => '${p.bar(30)} ${p.percent}% eta ${p.eta?.humanized ?? '…'}');
Console.spinner('Indexing', line: (s) => '${s.frame} ${s.text} ${s.elapsed.humanized}');
await pairs.download().show(
  task: (t) => '${t.index}/${t.count} ${t.name} ${t.speed.humanBytes}/s',   // TaskView: state, bytes, eta…
  header: (b) => '${b.completed}/${b.total} ${b.speed.humanBytes}/s',     // BatchView
);
table.show(border: Border.markdown, align: 'lr', cell: (row, c) => row.text(c)); // also square, rounded, double, heavy, ascii, none
```

`isLive` on a view says whether the line is redrawn in place or is the one a log keeps.

- Under `-q` indicators draw nothing; only a warning's or a failure's final line is written.
- Without a terminal everything degrades to plain lines; a terminal that cannot draw Unicode
  gets `ConsoleTheme.ascii`.
- Prompts are async (^C ends cleanly, echo restored) and write to stderr; `confirm` re-asks on
  anything but yes/no.

---

## `tui`

Terminal apps, full-screen or inline: a state, a `view` of widgets, an `update` that answers events.
Its own import — `import 'package:dart_toolkit/tui.dart';` — beside `Console`, not built on it.
`Border` and `CancelledException` come from `core` (or the barrel), shared with `Console`.

```dart
final n = await Tui.run(0,
  view: (n) => Box(Label('Count: $n'), title: 'Counter'),
  update: (n, e) => switch (e) {
    Key.up => n + 1,
    Char(char: 'q') => Tui.quit(),
    _ => n,
  });
```

`Tui.inline` runs the same app in the rows under the cursor and erases them on the way out —
a picker inside a script. Frames diff a cell buffer, so only changed cells are written; it draws
on `/dev/tty`, never stdout, so `tk pick > path.txt` works.

| | |
|---|---|
| `Label`, `Label.spans`, `VStack`, `HStack`, `Box` | text (wraps, aligns), stacks, borders; size a child with `.fixed(n)`, `.flex([w])`, `.percent(p)` |
| `Menu(items, choice)`, `Grid(rows, columns:, choice:)`, `Tabs(titles, choice)` | lists, tables, tabs; a `Choice` holds the cursor, `filter:` (type to narrow), `multi:` (Space checks) |
| `Field(prompt:, placeholder:, mask:, validate:, history:)` | a readline-style input; hold it across frames |
| `Gauge(0.4)`, `Gauge.of(Progress(…))`, `Spin('Loading')` | progress; a spinner animates itself |
| `Paint((c) => …)`, `child.themed(theme)` | a one-off widget on a `Canvas`; a subtree's theme |
| `Tui.send(future or stream)`, `init:` | background work, fed back to `update` |
| `class App extends TuiApp<S>` | the same engine as a class |

Keys reach the focused `Field`/`Menu`/`Grid`/`Tabs` first; Tab and Shift+Tab move the focus,
`mouse: true` adds clicks and the wheel. Match events as patterns: `Key.up`, `const Key('s', ctrl:
true)`, `Char(:final char)`, `Mouse(kind: MouseKind.press, :final y)`, `Paste(:final text)`,
`Resize()`. `TuiTheme` holds the shared tokens (palette, borders, glyphs); each widget's own look is
its parameters and builders (`item:`, `cell:`, `header:`, `bar:`, `builder:`):

```dart
final pick = Choice(filter: true, multi: true);
Menu(files, pick, item: (c) => Label.spans([Span(c.checked ? '✔ ' : '  '), ...c.highlighted],
    style: c.selected ? c.theme.selected : null));
```

^C, SIGTERM and a cancelled `Cancel.scope` throw `CancelledException`; every way out restores
the terminal. Colour falls back 24-bit → 256 → 16 → attributes only (`NO_COLOR`). POSIX only.
Test with `Tui.terminal = FakeTerminal(width: 40, height: 10)`: `type`, `press`, `mouse`,
`resize`, then read `screen`.

---

## `native`

`dart_toolkit_native` is one Rust `cdylib`: digests, MACs, archives, content decoders, WHATWG
charsets.

```dart
NativeLib.isAvailable; // whether it loaded
NativeLib.reason;      // why not
```

Looked for at `DART_TOOLKIT_NATIVE`, then beside the executable, then
`native/prebuilt/<os>_<arch>/`. Without it, those calls throw `UnsupportedError` and `IoClient`
asks only for gzip; there is no Dart fallback. Prebuilt for macOS arm64/x64 and Linux
x64/arm64 (glibc 2.30+); on Windows build it with `cargo-xwin` or on Windows. `make native` builds for this machine; `make native RUST_TARGET=x86_64-unknown-linux-gnu`
cross-builds with `cargo-zigbuild`. `NativeBridge` is internal.

---

## Cookbook

### Public-domain books

`bin/books.dart` searches Standard Ebooks and downloads over HTTP (or clicks through in Chrome
with `waitForDownload`).

```dart
final site = 'https://standardebooks.org'.url;

Future<({Uri page, String file})> find(String title) async {
  final results = await (site / 'ebooks').withQuery({'query': title}).get().html;
  final about = results.$('li[typeof="schema:Book"]').attrOrNull('about');
  if (about == null) throw 'no book matches "$title"';
  final page = site.resolve('$about/');
  final epub = (await page.get().html).$('a.epub').attr('href').split('/').last;
  return (page: page, file: epub);
}

Future<void> main() => Http.scope(retries: 2, delay: 1.s, () async {
  final found = await ['frankenstein', 'dracula'].parallelize(find).rights.toList();
  await {
    for (final (:page, :file) in found)
      page.resolve('downloads/$file').replace(query: 'source=download'): 'books'.path / file,
  }.download().show(message: 'Downloading');
});

```

### Scrape a paginated listing into a CSV

```dart
Future<void> listing() async {
  final rows = await Http.scope(
    () => 'https://example.com/list'.url
        .scrape<Map<String, Object?>>()
        .onInit((c) => c..concurrency = 8..delay = 200.ms..robots = true)
        .onResponse((c) {
          for (final tr in c.html.$('table tbody tr')) {
            final td = tr.$('td').texts;
            c.emit({'name': td[0], 'size': td[1]});
          }
          c.follow(c.html.$('a.next'));
        })
        .rights
        .toList(),
  );
  await Table.rows(rows).orderBy('name').save('listing.csv');
}
```

### Log in by hand in Chrome, then crawl over plain HTTP

```dart
Future<void> asMe(Uri loginUrl, Uri listUrl) async {
  final chrome = await ChromeClient.launch(profile: Path.home / '.my_tool', headless: false);
  final page = await chrome.open(loginUrl);
  if (!await page.has('.dashboard')) {
    Console.info('Log in in the browser window; waiting…');
    await page.waitFor('.dashboard', timeout: 5.m);
  }
  final jar = await page.cookies();
  await chrome.close();                                  // the profile keeps the login

  await Http.scope(jar: jar, () async {
    await listUrl.scrape<String>().onResponse((c) => c.emit(c.html.$('h1').text)).rights.forEach(print);
  });
}
```

Use `Http.scope(client: chrome, …)` instead when the pages need rendering.

### A rendered crawl that downloads at socket speed

Pages render in Chrome; the images go down a plain socket, because downloads set `Request.raw`.

```dart
Future<void> gallery(Uri url) async {
  final chrome = await ChromeClient.launch(tabs: 4, block: Resource.heavy);
  await Http.scope(client: chrome, () async {
    final images = url
        .scrape<({Uri url, Path path})>()
        .onRequest((c) => c[ChromeClient.waitFor] = '.gallery img')
        .onResponse((c) {
          for (final img in c.html.$('.gallery img[src]')) {
            final src = c.resolve(img);
            c.emit((url: src, path: 'out'.path / src.name.filename));
          }
        })
        .rights;
    await images.download(concurrency: 8).show(message: 'Downloading');
  });
  await chrome.close();
}
```

### Shell commands with one policy

```dart
Future<void> release(Path repo) => Shell.scope(workdir: repo, () async {
  if (!await run('git diff --quiet').isOk) await Lifecycle.exit('working tree is dirty');
  await run('dart analyze');
  await run('dart test');
  final tag = 'v${(await JsonDocument.read('pubspec.yaml'))['version'].to<String>()}';
  await run('git tag', args: [tag]);
});
```

---

## Testing

The seams are `Io`, `Client` and `Tui.terminal` (with `FakeTerminal`, the one fake `lib/` ships).

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

import 'mock_client.dart'; // copy test/mock_client.dart

void main() {
  test('prints and fetches', () async {
    final buffer = StringBuffer();
    Io.out = buffer;
    Console.ok('captured');
    Io.reset();
    expect(buffer.toString(), contains('captured'));

    final client = MockClient((req) async => Response('{"ok": true}', 200));
    final doc = await Http.scope(client: client, () => 'https://x.test'.url.get().json);
    expect(doc['ok'].to<bool>(), isTrue);
  });
}
```

- Script prompts with `Io.input = () => …`.
- Test a crawl by building its `Crawler` subclass; a `Worker` by calling `run` on an instance.
- Check your own client with `clientConformance('MyClient', (base) => MyClient())` from
  `test/client_conformance.dart`.
- `make` runs analyze, format check and tests; `make bench` prints per-module startup cost.

---

## Performance notes

Current figures, Apple M-series:

| | |
|---|---|
| `parallelize(isolate: true)`, 400 × 50k ints | ~70 ms |
| `Pool`, 2000 tiny items | 12 ms |
| `file.hash(xxh3)` / `blake3`, 1 GiB | ~110 ms (blake3 on all cores) |
| `paths.hash`, 49.5k files | 1.0 s |
| `Table.csv`, 45 MB / 1M rows | 0.43–0.63 s |
| `glob('**/*.dart')`, 49.5k files | 1.0–1.9 s |
| XPath `//article[.//img]`, 2 MB page | 4 ms |
| YAML parse, 2.5 MB | 61 ms |
| 96 MiB to `.zst` / `.xz` | 88 ms / 15.7 s |
| Chrome render with `waitFor`, 2.7 MB DOM | ~262 ms |

Tips:
- Startup is compile time under `dart run`; `dart run -r` keeps a resident compiler (a scraper
  went 0.83 → 0.40 s); package executables run from pub's snapshot.
- You pay for what you import: `dart:ffi` costs nothing without `fs`/`hash`/`http`; the native
  library opens lazily (~12 ms).
- Files stream: hashing, downloads, archives and uploads take the file, not its bytes.
- `ChromeClient.launch(block: Resource.heavy)` is the biggest win for a rendered crawl.
- Startup drifts ±80 ms; compare back to back (`make bench` alternates six rounds).

---

## Troubleshooting

| symptom | fix |
|---|---|
| `UnsupportedError: … needs dart_toolkit_native` | see `NativeLib.reason`; on Windows build it (`cargo-xwin`) and set `DART_TOOLKIT_NATIVE`; from a checkout, `make native` |
| A script finishes but does not exit | end with `Lifecycle.exit()` (or use a `Cli`), and `close()` any `ChromeClient` |
| `StateError: cancellable outside a Cancel.scope` | open a `Cancel.scope`, or run under `Cli.run` |
| `StateError: $.x is null, expected int` | use `toOrNull<T>()` or `or(v)` where absence is expected |
| Multi-document YAML reads only the first | use `.yaml.documents` |
| A crawl finds nothing a browser shows | the page builds it with scripts: put a `ChromeClient` in the scope, wait with `ChromeClient.waitFor` |
| A download is HTML instead of the file | an interstitial: request the URL it refreshes to, or click through with `waitForDownload` |
| `extractTo` says the archive is too large | it expands past 200×; `trusted: true` if you trust it |
| Shell completion does nothing | bash: `source <(app --completion bash)`; zsh: the same after `autoload -U bashcompinit && bashcompinit`; fish: `app --completion fish \| source` |
| Tables misalign with non-ASCII | measure with `Io.width` |
