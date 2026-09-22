# The dart_toolkit guide

Everything this package does, what each piece is for, and the shape of the programs it is
meant to be used in. [`README.md`](README.md) is the tour; this is the manual.
[`CONVENTIONS.md`](CONVENTIONS.md) is why the API looks the way it does, and
[`CHANGELOG.md`](CHANGELOG.md) is what each release contains.

## Contents

- [Start here](#start-here)
  - [Installing](#installing)
  - [Three programs, end to end](#three-programs-end-to-end)
  - [The five ideas](#the-five-ideas)
  - [The modules](#the-modules)
- [`core` — values, environment, terminal IO](#core--values-environment-terminal-io)
- [`async` — cancellation, concurrency, streams](#async--cancellation-concurrency-streams)
- [`collection` — `Sequence` and `Table`](#collection--sequence-and-table)
- [`formats` — JSON, YAML, TOML, INI, HTML, XML](#formats--json-yaml-toml-ini-html-xml)
- [`fs` — paths, files, archives](#fs--paths-files-archives)
- [`hash` — digests, MACs, encodings](#hash--digests-macs-encodings)
- [`process` — running commands](#process--running-commands)
- [`http` — requests, clients, scraping, downloads](#http--requests-clients-scraping-downloads)
  - [Requests and responses](#requests-and-responses)
  - [The scope](#the-scope)
  - [Clients](#clients)
  - [Chrome](#chrome)
  - [Driving a page](#driving-a-page)
  - [Crawling](#crawling)
  - [Downloads](#downloads)
- [`cli` — options, commands, lifecycle, console](#cli--options-commands-lifecycle-console)
- [`native` — the Rust library](#native--the-rust-library)
- [Cookbook](#cookbook)
- [Testing](#testing)
- [Performance notes](#performance-notes)
- [Troubleshooting](#troubleshooting)

---

## Start here

### Installing

```yaml
dependencies:
  dart_toolkit:
    git:
      url: https://github.com/feiluvnana/dart-toolkit.git
```

One import gets everything:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```

Import a single module only when you have measured and want less — `package:dart_toolkit/http.dart`,
`.../fs.dart`, and so on. The module list is below.

The hashing and archive features need the native library, which ships prebuilt per platform.
From a checkout, `make native` builds it for this machine; `Native.isAvailable` says whether it
loaded and `Native.reason` says why not.

### Three programs, end to end

**Fetch a page and read it.**

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  await Http.scope(() async {
    final doc = await 'https://news.ycombinator.com'.url.html();
    for (final row in doc.$('tr.athing')) {
      print(row.$('.titleline > a').text);
    }
  });
}
```

**Crawl a site and write what it finds.**

```dart
void main() async {
  final items = 'https://example.com'.url.scrape<(String, String)>()
      .onInit((ctx) => ctx.pages = 50)
      .onResponse((ctx) {
        for (final a in ctx.response.html.$('a[href]')) {
          ctx.emit((a.text, ctx.resolve(a.attr('href')!).toString()));
          ctx.follow(a.attr('href')!);
        }
      });

  final found = await items.rights.toList();
  found.sequence.map((r) => {'title': r.$1, 'href': r.$2}).table.show();
}
```

**A command-line program with options, a spinner and ^C handling.**

```dart
final top = Opt.number('top', abbr: 'n').or(10);
final out = Opt.text('out', abbr: 'o').or('out.csv');

void main(List<String> args) => Cli(
  name: 'report',
  options: [top, out],
  handler: (ctx) async {
    final rows = await Console.spin('Fetching', () => fetch(ctx(top)));
    await rows.table.saveCsv(ctx(out));
    Console.ok('wrote ${ctx(out)}');
  },
).run(args);
```

### The five ideas

Everything in the package follows from these. They are argued in `CONVENTIONS.md`; here is
what they mean when you are writing code.

**1. A conversion is the way in.** Nothing is bolted onto `String`, `Iterable` or `Map` beyond
a handful of entry points. You convert, and the vocabulary lives on what you get:

```dart
'https://x.com'.url      // Uri
'/tmp/a.txt'.path        // Path
'{"a":1}'.json           // JsonDocument
'a: 1'.yaml              // JsonDocument
'<p>hi</p>'.html         // HtmlDocument
'<a/>'.xml               // XmlDocument
items.sequence           // Sequence, a lazy query
rows.table               // Table, rows of named columns
60.s                     // Duration
```

**2. A setting every call would repeat belongs to a scope.** There are three, and they read
alike. A per-call argument still beats the scope.

```dart
await Http.scope(() async { … },  client: …, timeout: …, headers: …, cookies: true);
await Shell.scope(() async { … }, workdir: …, env: …, timeout: …, quiet: …, strict: …);
await Cancel.scope(() async { … }, token: stop);
```

**3. A failure is a value where more than one thing is being done.** `parallelize` and a crawl
settle everything into `Either`, and you pick the policy at the use site: `.rights`, `.lefts`,
`.unwrap()`, or a `switch`.

**4. A guaranteed value is not nullable.** `ctx(option)` with a default, `row.number('size')`
and `Elements.text` return the value or throw naming what was missing. The `*OrNull` form is
for the caller who expects absence.

**5. One word per idea, everywhere.** A default is `or`. A body is `text`/`bytes`/`form`/
`json`/`files`. One file or a thousand is `download`. A read-only boolean is `is*`. The async
form is bare and the synchronous twin ends in `Sync`.

### The modules

| library | holds | needs |
|---|---|---|
| `core.dart` | `Either`, `Env`, `Io`, `.url`, `60.s`, progress interfaces | — |
| `async.dart` | `Cancel`, `retry`, `parallelize`, `isolate`, stream operators, `Semaphore`, `Mutex` | — |
| `collection.dart` | `Sequence`, `Sorted`, `Group`, `Table`, `Row` | `formats` |
| `formats.dart` | `JsonDocument`, YAML/TOML/INI, the HTML/XML tree, `$`, `$x` | `collection` |
| `fs.dart` | `Path`, archives and compression | `native` |
| `hash.dart` | `Hash`, `Secure`, hex/base64/base32 | `native` |
| `process.dart` | `run`, `Shell.scope`, pipelines, `which` | `fs`, `core` |
| `http.dart` | `Request`, `Response`, `Client`, `Http.scope`, scraping, downloads | `fs`, `hash`, `formats`, `native` |
| `cli.dart` | `Opt`, `CliCommand`, `Cli`, `Lifecycle`, `Console` | `core` |
| `native.dart` | `Native`, `NativeBridge` | — |

---

## `core` — values, environment, terminal IO

### `Either`

A value that is one of two things. Nothing here is a stream error where more than one thing is
happening — a failed item is an item.

```dart
final outcome = Either.tryCatchSync(() => int.parse(raw));      // Either<Object, int>
final async = await Either.tryCatch(() => url.json());          // the same, awaited

outcome.isRight;  outcome.rightOrNull;  outcome.leftOrNull;
outcome.fold((e) => 'failed: $e', (v) => 'got $v');
outcome.mapRight((n) => n * 2).mapLeft(ParseFailure.from);
outcome.unwrap();                                                // or throw the Left
```

On a list or a stream of them:

```dart
settled.rights;      // List<R> / Stream<R> — the successes
settled.lefts;       // the failures
settled.unwrap();    // the successes, throwing the first failure
```

`Left` carries an optional `StackTrace`, so a failure that travelled can still be reported
where it happened.

### `Env`

The process environment, with overrides a test can set and reset.

```dart
Env.get('HOME');            Env.require('API_TOKEN');    // throws, naming the key
Env.has('CI');              Env.isCI;
Env.set('TZ', 'UTC');       Env.remove('TZ');            Env.reset();
Env.all();                  Env.hasOverrides;

Env.load();                                   // reads .env into the overrides
Env.load(path: '.env.local', override: true); // ...and lets it win over the real environment
Env.parse(text);                              // just the parse
```

### `Io`

Everything that reaches a terminal goes through `Io`, which also answers every question about
the active sink. Redirect it and you have redirected the console, the logger and subprocess
output at once.

```dart
Io.out;  Io.err;                 // StringSink
Io.out = StringBuffer();         // capture; Io.reset() puts it back
Io.isTerminal;  Io.isRedirected;  Io.columns;  Io.color;
Io.readLine();  Io.input = () => 'scripted answer';   // prompts read through this
Io.stripAnsi(text);  Io.width(text);  Io.truncate(text, 40);
```

`Io.width` counts what a terminal shows — a combining mark is zero columns, a CJK ideograph is
two — which is why tables and progress bars line up with text that is not ASCII.

### Small conversions

```dart
'https://x.com/a'.url                    // Uri
'2024-05-06'.match(RegExp(r'\d{4}'))     // String? — the group, or null

100.ms  5.s  2.m  1.h  3.d               // Duration
30.s.humanized                           // '30s'
200.ms.jittered()                        // ±25%, for a backoff
await 1.s.delay();
```

### Progress interfaces

`TaskProgress` and `BatchProgress` are how `fs`/`http` tell `cli` what is happening without
either module importing the other. Anything that implements `BatchProgress` can be rendered
with `stream.show()`.

---

## `async` — cancellation, concurrency, streams

### Cancellation is ambient

A token is never threaded through a call. `Cancel.scope` holds one, and `download`, `retry`,
`parallelize` and `.cancellable` all read it.

```dart
final stop = CancelToken();
await Cancel.scope(() async {
  await for (final item in feed.cancellable) print(item);
}, token: stop);

stop.cancel('user asked');
```

Inside a scope:

```dart
Cancel.isCancelled;  Cancel.reason;  Cancel.throwIfCancelled();
```

All three are quiet outside a scope, because nothing has cancelled it there. `.cancellable` is
the exception: it throws outside a scope rather than leaving a wrapper that does nothing.

```dart
await for (final item in feed.cancellable) …    // the stream just ends
final page = await slow.cancellable;            // CancelledException — a future has no quiet ending
```

A token directly, when you are holding one:

```dart
final token = CancelToken();
token.isCancelled;  token.reason;  token.throwIfCancelled();
final undo = token.onCancel(() => cleanup());   // registration returns its removal
```

`Cli.run` opens a `Cancel.scope` whose token is `ctx.cancel`, so a program inside a `Cli` gets
^C handling without writing anything.

### Doing many things at once

```dart
final settled = await urls.parallelize(fetch, concurrency: 8);   // List<Either<Object, Page>>
final streamed = pages.parallelize(parse, concurrency: 4);       // Stream<Either<…>>, as they finish

print('${settled.rights.length} ok, ${settled.lefts.length} failed');
final all = settled.unwrap();                                     // or throw the first
```

`isolate: true` runs each worker in a background isolate — for CPU-bound work, where the cost
of copying the argument and the result is smaller than the work itself.

```dart
final hashes = await files.parallelize(digest, concurrency: 4, isolate: true);
final parsed = await (() => JsonDocument.parse(huge)).isolate();   // one function, one isolate
```

### Retrying

```dart
final data = await retry(
  fetchData,
  attempts: 3,
  delay: 200.ms,
  maxDelay: 5.s,
  backoff: 2.0,
  jitter: true,
  when: (e) => e is! FormatException,          // only these are worth retrying
  onRetry: (n, e, next) => Console.warn('attempt $n failed, waiting $next'),
);
```

### Locks and permits

```dart
final gate = Semaphore(4);
await gate.run(() => work());              // held for the action
final permit = await gate.acquire();       // ...or held by hand
permit.release();
gate.permits;  gate.waiting;

final lock = Mutex();
await lock.run(() async { … });
lock.isLocked;
```

### Stream operators

In-house, so nothing third-party is loaded to get them.

```dart
stream.chunk(100);                   // Stream<List<T>> of fixed size
stream.chunkEvery(1.s);              // ...of whatever arrived in the window
stream.debounce(300.ms);             // the last of a burst
stream.throttle(1.s);                // at most one per interval
stream.delayBy(100.ms);
stream.flatMap((x) => inner(x));
[a, b, c].merge();                   // one stream out of many
maybeStream.nonNulls;                // Stream<T?> → Stream<T>
```

---

## `collection` — `Sequence` and `Table`

Nothing is added to `Iterable` or `Map`. `.sequence` and `.table` are the way in, and both are
opt-in: a plain list needs neither.

### `Sequence` — a lazy query

A `Sequence` is an `Iterable`, so it goes anywhere one does, and every operator that returns a
`Sequence` stays lazy until something iterates it.

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc)
    .thenBy((t) => t.number, descending: true)
    .take(10);
```

| | |
|---|---|
| shape | `where`, `whereNot`, `map`, `expand`, `take`, `skip`, `takeWhile`, `skipWhile`, `takeLast`, `skipLast`, `whereType`, `cast`, `followedBy` |
| order | `sortedBy`, `sortedWith`, `sorted`, `sortedDescending`, then `thenBy` / `thenWith`; `reversed`, `shuffled` |
| windows | `chunk(n)`, `windowed(n, step:)`, `pairwise`, `indexed`, `scan(seed, combine)` |
| sets | `distinct`, `distinctBy`, `union`, `intersect`, `except` |
| pairs | `zip`, `cartesian`, `interleave` |
| joins | `innerJoin`, `leftJoin`, `groupJoin` — each `on:`, `to:` and a combiner |
| grouping | `groupBy`, `countBy`, `indexBy`, `partition` |
| folds | `sum`, `average`, `sumBy`, `averageBy`, `max`, `min`, `maxBy`, `minBy`, `minMax`, `none` |
| ranges | `Sequence.range(count)`, `Sequence.range(from, to, step)` |

`sum`, `average`, `max`, `min`, `sorted` and `sortedDescending` exist only where they make
sense — on a `Sequence<num>` and a `Sequence<Comparable>` — so they cannot be reached on a
sequence of something that has no order.

A `Map` converts too, to a sequence of records, with its own vocabulary:

```dart
for (final (k, v) in map.sequence.sortedByValue(descending: true).take(3)) print('$k $v');

map.sequence.keys;  map.sequence.values;  map.sequence.inverted;
map.sequence.mapValues((v) => v * 2).toMap();
map.sequence.unzip;                       // (List<K>, List<V>)
```

`groupBy` gives `Group`s, which are sequences that know their key:

```dart
tracks.sequence.groupBy((t) => t.disc).mapValues((g) => g.length).toMap();   // {1: 12, 2: 9}
tracks.sequence.groupBy((t) => t.disc).toMap();                              // Map<int, List<Track>>
```

### `Table` — rows of named columns

A table keys by column name, because a CSV's columns are not known until it is read.

```dart
Table.rows(maps);                 Table.cells(headers, rows);
Table.csv(text);                  Table.ndjson(text);
doc.$('table#songs').table;       // an HTML <table>: <th> → columns, <tr> → rows
json.$(r'$.items[*]').table;      // a JSON array of objects
```

Querying, all of which give a new `Table`:

```dart
t.where((r) => r.number('size') > 1e6)
    .orderBy('disc').thenBy('n', descending: true)
    .select(['title', 'size'])
    .drop(['internal'])
    .rename({'n': 'track'})
    .derive('mb', (r) => r.number('size') / 1e6)
    .distinct(['title'])
    .take(20);

t.join(other, on: 'href');   t.leftJoin(other, on: 'href');
t.groupBy('disc').sum('size');       // also count, avg, min, max
t.groupBy('disc').agg({'size': Agg.sum, 'title': Agg.count});
t.groupBy('disc').aggWith({'span': (rows) => rows.length});
t.pivot(rows: 'disc', column: 'format', value: 'size', agg: Agg.sum);
```

Reading a row, with the nullable twin where absence is expected:

```dart
row.get<int>('size');   row.getOrNull<int>('size');
row.text('title');      row.number('size');   row.numberOrNull('size');
t['title'];             t.numbers('size');    t.texts('title');
t.length;  t.isEmpty;   t.columns;  t.rows;   t.sequence;
```

Out:

```dart
t.toCsv();  t.toNdjson();  t.toMarkdown();  t.toJson();
await t.saveCsv('out.csv');
t.show();                                   // the console table; the only renderer
```

---

## `formats` — JSON, YAML, TOML, INI, HTML, XML

Every parser here is the package's own, so none of them costs a third-party import at startup.
YAML is checked against `package:yaml`, XML against `package:xml` and HTML against
`package:html` in the test suite, on real documents.

### One document model for data

JSON, YAML, TOML and INI all decode to `JsonDocument`, so one query language and one `to<T>()`
serve them all.

```dart
final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
final config  = text.toml;
final legacy  = text.ini;
final body    = res.json;              // or '{"a":1}'.json, or JsonDocument.parse(text)
```

`$` is JSONPath and returns a list of documents:

```dart
doc.$(r'$.dependencies.*');            // every value under a key
doc.$(r'$.items[*].id');               // a field of every element
doc.$(r'$..name');                     // recursive descent
doc.$(r'$.items[0]');
```

Reading a value:

```dart
doc['server']['port'].to<int>();       // null if it is not an int
doc.list;                              // List<JsonDocument>
doc.map;                               // Map<String, JsonDocument>
doc.raw;                               // the decoded Dart value
doc.isNull;  doc.isNotNull;
```

Writing YAML back out:

```dart
await 'out.yaml'.path.writeText(doc.toYaml());
```

### One tree for markup

HTML and XML share `Node`, `Element`, `Text`, `Attribute`, `Nodes` and `Elements`. They differ
in the parser and in `Element.syntax`, which decides how an element serialises and whether a
CSS name folds case.

**`$` is CSS and `$x` is XPath, on every document**, and both work on HTML and XML alike.

```dart
final doc = await url.html();          // or res.html, or '<p>…</p>'.html
doc.$('h1').text;                      // Elements: text/attr() answer for the first match
doc.$('td.title > a[href]');           // iterate them
doc.$('#songlist tr').$('td:nth-child(3)').texts;    // chain a query onto a result
doc.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;
doc.$x('//h2[contains(., "Tracks")]/following-sibling::table[1]').elements.$('td');
```

XML keeps case and prefixes, and an empty element closes itself:

```dart
final feed = await url.xml();          // or res.xml, or '<rss>…</rss>'.xml
for (final item in feed.$('item')) print(item.$('title').text);
feed.$x('//media:content/@url').texts;  // a prefixed name is not CSS
```

On an `Element`:

```dart
e.name;  e.local;  e.prefix;  e.id;  e.classes;  e.attributes;
e.attr('href');  e.text;  e.lines;  e.children;  e.nodes;  e.parent;
e.nextElement;  e.previousElement;
e.markup;  e.innerMarkup;
e.table;                               // a <table> element as a Table
```

On `Elements` (a `List<Element>` you can query again) the singular readings answer for the
first match and the plural ones for all of them:

```dart
els.text;        // the first match's text — throws if the list is empty
els.attr('href');
els.texts;       // every match's text
els.lines;
els.table;
```

`Nodes` is what `$x` returns, because an XPath may select an attribute or a text node as well
as an element; `nodes.elements` narrows it.

---

## `fs` — paths, files, archives

`Path` is an extension type over `String`, so it goes anywhere a path string does and costs
nothing at runtime.

### Building and asking

```dart
final dir = Path.temp / 'my_project';
final file = dir / 'config.json';

Path.home;  Path.temp;  Path.current;
'a/b.txt'.path;  'AIR / Farewell'.filename;    // one component, separators removed

p.name;  p.stem;  p.ext;  p.parent;  p.segments;
p.normalized;  p.absolute;  p.isAbsolute;  p.relativeTo(root);
p.withExt('json');  p.withName('other.txt');  p.sanitized;
p.asFile;  p.asDir;  p.asLink;

await p.exists();  await p.type();  await p.size();  await p.modified();
```

`Path` cannot override `==`, so normalize at map boundaries: `<Path, int>{p.normalized: 1}`.

### Reading and writing

Every one of these has a `Sync` twin — `fs` is the only module where that is allowed.

```dart
await p.readText();   await p.readBytes();   await p.readLines();
p.lines();                                   // Stream<String>, for a file too big to hold

await p.writeText(s);  await p.writeBytes(b);  await p.writeLines(ls);
await p.append(s);     await p.replaceText(RegExp(r'\d+'), 'n');
await p.touch();       await p.mkdir();       await p.symlink(target);
await p.copy(to);      await p.move(to);      await p.delete(recursive: true);
p.watch(recursive: true);
```

### Listing

```dart
p.list(recursive: true);     // Stream<Path> — everything
p.files(recursive: true);    p.dirs();   p.links();
p.glob('lib/**/*.dart');     p.globSync('*.{png,jpg}');
```

### Archives and compression

**Writing names the format; reading works it out.** `archiveTo` and `compressTo` take the
format from the destination's extension, because a file that does not exist yet has nothing
else to go on. `extractTo`, `archiveEntries` and `decompressTo` read the file's magic number
and fall back to its name, so a download saved without an extension still opens.

```dart
await dir.archiveTo('project.7z', password: 'pw');   // .zip .7z .tar.gz .tar.zst .tar.xz .tar.bz2
await 'photos.rar'.path.extractTo(dir, password: 'pw');
await 'downloaded.bin'.path.extractTo(dir);           // whatever it really is
for (final e in await zip.archiveEntries()) print('${e.name} ${e.size}');

await log.compressTo('log.gz');       // gzip, xz, zstd, bzip2, by extension
await 'blob'.path.decompressTo('out.txt');

Archive.of('x.rar');                  // Archive.rar
Archive.rar.isWritable;               // false — the format's licence forbids writing
```

A file operation streams: hashing, downloading and archiving name the file, not its bytes, so
memory is flat whatever the size.

---

## `hash` — digests, MACs, encodings

Digests run in the native library, so they are the same and fast on every platform. The test
suite checks each against its published vectors and against `openssl`.

The grid is filled: `hash`, `hashBytes`, `checksum`, `hmac` and `hmacBytes` read the same on a
`String`, a `List<int>` and a `Path`, so none of them has to be guessed at.

```dart
'abc'.hash(Hash.sha256);
bytes.hash(Hash.blake3);
await file.hash(Hash.sha3_256);           // streams; memory is flat
await file.checksum(Hash.crc32);          // an int, for the 32-bit ones
'body'.hmac(Hash.sha256, secret);
await file.hmacBytes(Hash.sha512, key);
```

Twenty algorithms: `md5`, `sha1`, the SHA-2 family (`sha224` … `sha512_256`), the SHA-3 family,
`keccak256`, `blake2s`, `blake2b`, `blake3`, `ripemd160`, and the checksums `crc32`, `crc32c`,
`xxh64`, `xxh3`. `Hash.isChecksum` tells them apart; the 32-bit checksums read as an `int` and
the 64-bit ones as hex, because they do not fit one.

```dart
Secure.token();  Secure.token(16);  Secure.uuid();  Secure.bytes(32);
Secure.equals(a, b);                      // constant time, for a digest from outside

bytes.hex;  bytes.base64;  bytes.base64Url;  bytes.base32;
'6869'.hexBytes;  'aGk='.base64Bytes;  'JBSWY3DP'.base32Bytes;
```

**Encryption, password hashing, key agreement, signatures and JWT are deliberately absent.**
This package identifies, verifies and encodes data; it has no business owning the code that
protects it. The class is `Secure` and not `Crypto` for the same reason.

---

## `process` — running commands

```dart
final res = await run('git status --short');
res.isOk;  res.text;  res.lines;  res.exitCode;  res.stdout;  res.stderr;

await run('cat', input: 'fed to stdin');
await run('npm ci', workdir: repo, timeout: 5.m, quiet: true, strict: true);
await (await which('dart'))?.run(args: ['--version']);
```

`strict: true` throws on a non-zero exit instead of returning a result; `quiet: true` stops the
child's output being echoed. `shell: true` runs the command through the system shell, for the
cases that need globbing or `&&`.

A pipeline is the `|` operator, with pipefail semantics — the first non-zero exit is the
result:

```dart
final piped = await ('echo "apple\nbanana"' | 'grep an').run();
print(piped.lines);
```

The awaited result has the readings on it directly, so a one-liner needs no local:

```dart
final branch = await run('git rev-parse --abbrev-ref HEAD', quiet: true).text;
final ok = await run('git diff --quiet').isOk;
```

A working directory, an environment, a timeout, an encoding or a failure policy that every
command would otherwise repeat belongs to the scope:

```dart
await Shell.scope(() async {
  await run('git fetch --all');
  await run('git status --short');
  final probe = await run('git cat-file -e deadbeef', strict: true);   // this one may throw
}, workdir: repo, env: {'GIT_TERMINAL_PROMPT': '0'}, timeout: 30.s, quiet: true, strict: false);
```

Subprocess output is written through `Io`, so a redirected sink captures it along with
everything else.

---

## `http` — requests, clients, scraping, downloads

### Requests and responses

The verbs are on `Uri`, which is what `.url` gives you.

```dart
await url.get();      await url.head();
await url.post(json: {'name': 'x'});
await url.put(text: 'body');   await url.patch(form: {'q': 'dart'});   await url.delete();
await url.fetch();    // a GET that throws unless the status is 2xx
await url.json();     await url.html();   await url.xml();    // fetch, then parse
await url.send(request);
```

`url / 'users'` appends a path segment, treating the base as a directory — the same glyph as
`Path./`, with the same meaning. `url.withQuery({'page': 2, 'q': null})` adds and removes
query parameters.

**A body is named by what it is**, at most one of `text:`, `bytes:`, `form:`, `json:` and
`files:`, each typed and each carrying its own `content-type`. The same words name a body on
`Request` and on a crawl's `follow`.

```dart
await api.post(text: 'plain');                         // text/plain
await api.post(bytes: buffer);                         // whatever you set
await api.post(form: {'q': 'dart'});                   // x-www-form-urlencoded
await api.post(json: {'name': 'x'});                   // application/json
await api.post(files: {'avatar': '~/me.png'.path});    // multipart/form-data
```

`files:` is the one that pairs: `form:` with `files:` is not two bodies but the fields and the
files of one form, which is what a browser sends for a form with a file input on it. It is read
off disk as it goes out and never held, so the size of an upload is not the size of the heap.

```dart
await api.post(form: {'title': 'holiday'}, files: {'photo': '~/beach.jpg'.path});
```

A `Response`:

```dart
res.statusCode;  res.isOk;  res.reasonPhrase;  res.headers;  res.url;  res.request;
res.text;        // decoded by the charset of content-type, or the one the markup declares
res.bytes;       // Uint8List
res.json;        // JsonDocument, parsed once
res.html;        // HtmlDocument, parsed once
res.xml;
await res.isolate((r) => parseHeavily(r));   // the body, in a background isolate
```

A `Request` when you need to build one by hand:

```dart
final req = Request('POST', url, headers: {'x-api-key': k}, json: body)
  ..followRedirects = false
  ..maxRedirects = 3;
req.copy();                 // sending consumes a request; copy it to send it twice
req.open();                 // the body as a stream — what a client sends
req.contentLength;
```

### The scope

**No entry point takes a `client:`.** A scope names one once, for every request, download and
crawl inside it, and holds the settings they would all otherwise repeat.

```dart
await Http.scope(() async {
  final doc = await url.html();
  final res = await other.get();
  if (!res.isOk) await Lifecycle.exit('${res.statusCode} from $other');
}, timeout: 30.s, headers: {'user-agent': 'my-tool/1.0'});
```

| argument | |
|---|---|
| `client:` | the `Client` everything inside uses; closed on the way out unless you supplied it |
| `timeout:` | bounds the wait for headers **and** for each body chunk |
| `headers:` | added to every request that does not set them itself |
| `cookies:` | keeps a jar for the life of the scope |

`cookies: true` keeps what the responses set and sends them back, so a login and the pages
behind it are one scope and nothing parses `set-cookie` by hand. A request that names its own
`cookie` still wins.

```dart
await Http.scope(cookies: true, () async {
  await login.post(form: {'user': user, 'pass': pass});
  await for (final item in dashboard.scrape<Item>().onResponse(parse).rights) print(item);
});
```

The jar walks the redirect chain itself, hop by hop, because a login is a POST that answers a
302 and sets the session **on that hop**: the response at the end of the chain carries no
`set-cookie` at all.

`Http.client` is the enclosing scope's client, or `null` outside one.

### Clients

A `Client` is two methods, and everything in the module reaches the network through one.

```dart
abstract interface class Client {
  Future<StreamedResponse> send(Request request);
  Future<void> close();
}
```

```dart
await Http.scope(client: IoClient(), () async { … });                    // the default
await Http.scope(client: await ChromeClient.launch(), () async { … });   // Chrome renders it
await Http.scope(client: MockClient((r) async => Response('ok', 200)), () async { … });
```

**`IoClient`** is `dart:io` with the transport's own limits, the encodings a browser asks for,
and its own redirect chain.

```dart
IoClient(
  connections: 32,        // total transfers in flight, across every host
  perHost: 6,             // connections open to one origin
  keepAlive: 30.s,
  connectTimeout: 5.s,
  userAgent: 'my-tool/1.0',
  proxy: 'http://user:pass@127.0.0.1:8080'.url,
  insecure: false,        // true accepts a certificate that does not verify
);
```

It asks for `gzip`, and for `br` and `zstd` when the native library is there, and decodes the
answer as it streams — brotli is 15–20% smaller than gzip on markup. It walks its own redirect
chain, so one rule holds everywhere: 303, and 301 or 302 on anything but GET and HEAD, become
a GET with no body; 307 and 308 keep both; and `authorization`, `cookie` and
`proxy-authorization` do not follow to another host.

**A scope is for code with no client to hand.** When the client *is* in hand it takes the same
verbs itself, and no scope is needed:

```dart
final chrome = await ChromeClient.connect();

await chrome.get(url);                                  // the page, rendered
await chrome.html(url);                                 // parsed
await chrome.fire(request);                             // a request you built
await chrome.page(url, (p) => p.click('.download'));    // the tab, live
await chrome.scrape<Item>(url).onResponse(parse).rights.forEach(print);
```

This is not sugar. A scope holds a `Client`, and a `Client` is `send` and `close` — so through
a scope, everything a particular client can do *beyond* the seam is invisible. Held, the client
is the receiver, and the compiler decides whether `page` exists: nothing probes, nothing casts,
and nothing throws at runtime for asking a socket to click a button.

**A `RequestKey<T>` is how any client is told something HTTP has no word for**, and a client
**ignores every key it does not know**. That is what lets one crawl run unchanged over
`IoClient`, which ignores a wait, and over `ChromeClient`, which honours it.

```dart
const waitFor = RequestKey<String>('wait-for');
request[waitFor] = '.item';
waitFor(request);            // read it back with the key itself
```

`Request.raw` is the one key that is not a client's own: *answer with the resource, never a
rendering of it*. Every download sets it, so a file fetched inside a Chrome scope is the file
and not the DOM Chrome built to display it.

To write a third client, implement the two methods and point `clientConformance` at it —
`test/client_conformance.dart` brings its own server and checks the promises the rest of the
module relies on: a non-2xx is a response and not a throw, `url` is the URL that answered, a
body arrives as a stream, a streamed body is sent under a truthful `content-length`, an unknown
directive is ignored, `close` is idempotent.

### Chrome

`ChromeClient` speaks the DevTools protocol over a websocket — no third-party package and no
Chromium download. The page arrives as the DOM **after its own scripts have run**, so `res.html`,
`$`, `$x` and the whole scrape engine work over it unchanged.

Three ways in, for three situations:

```dart
await ChromeClient.launch();           // a fresh headless browser, dead with the client
await ChromeClient.attach(port: 9222); // join one already running; never killed
await ChromeClient.connect();          // attach if there is one, else start one that outlives the run
```

`launch(profile:)` is the fourth shape: a browser this client owns and kills, that still keeps
its cookies and its login between runs. Who owns the process and what the browser remembers
are independent, and both constructors that start one take both. A profile can only be open in
one browser at a time, so two runs at once on the same one is an error that says so.

`connect()` is the one for a script that is run again and again: it keeps one browser and one
profile across runs (`~/.dart_toolkit/chrome` unless another is named), so a site you logged
into by hand once is still logged in next time. It is headful by default, because a browser you
can see is one you can log into, and `close()` never kills it.

```dart
final chrome = await ChromeClient.connect();   // run 1: starts Chrome, you log in by hand
await Http.scope(client: chrome, () async { … });
await chrome.close();                          // the browser stays up
```

What the browser is, and what it will not load, are said once:

```dart
await ChromeClient.launch(
  tabs: 4,                       // pages rendering at once
  block: Resource.heavy,         // images, fonts and media never fetched
  device: Device.phone,          // what the pages think they are running on
  stealth: true,                 // on unless turned off
  wait: ChromeWait.idle,         // the default for every request
  challenge: 20.s,               // how long an interstitial may take to clear
  timeout: 30.s,
  headless: true,
  proxy: 'http://user:pass@host:8080'.url,
  assets: IoClient(),            // answers everything that is not a page render
);
```

`proxy:` routes the browser and the default `assets` client alike, so the pages and the files
of one crawl take the same road. Credentials cannot travel on a command line, so Chrome asks
for them and this answers over the protocol, at the cost of a round trip per request. A
browser already running keeps the route it was started with — `attach`, and `connect` when it
joins one, proxy the downloads and not the pages, and `isNewBrowser` tells you which happened.

`block:` is the largest single thing a rendered crawl can do for itself: a page whose images,
fonts and media never arrive looks nothing like itself and says exactly the same words, in a
fraction of the bytes and a fraction of the time. `Resource.heavy` is those three; the full set
is `image`, `font`, `media`, `stylesheet`, `script` and `xhr`.

`Device` is one argument instead of six. `Device.desktop` is the default, `Device.phone` is a
recent iPhone down to the user-agent, and the fields are `width`, `height`, `scale`, `mobile`,
`userAgent`, `locale` and `timezone`.

```dart
await ChromeClient.launch(device: Device(locale: 'de-DE', timezone: 'Europe/Berlin'));
```

`stealth:` hides what an automated Chrome leaves lying around for an interstitial to find —
`--disable-blink-features=AutomationControlled` on the browsers it starts, and a script before
every document's first line for `navigator.webdriver`, a missing `window.chrome`, an empty
`plugins` and a `permissions.query` that disagrees with `Notification.permission`.

Per request, with the keys:

| key | |
|---|---|
| `ChromeClient.waitFor` | wait until a CSS selector matches |
| `ChromeClient.waitUntil` | `ChromeWait.dom`, `.load` or `.idle` |
| `ChromeClient.script` | JavaScript to run before the DOM is read; may return a promise |
| `ChromeClient.challenge` | how long this page may sit on an interstitial |
| `ChromeClient.block` | what this page refuses to load, over the client's `block:` |

```dart
url.scrape<Item>().onRequest((ctx) {
  ctx.request[ChromeClient.waitFor] = '.results .item';
  ctx.request[ChromeClient.script] = 'window.scrollTo(0, document.body.scrollHeight)';
  ctx.request[ChromeClient.block] = Resource.heavy;
});
```

Only a GET without a `range` is rendered. A POST, a resumable download, an asset — everything
else goes to the plain HTTP client underneath, carrying the browser's cookies and its
user-agent, so a crawl that renders its pages still fetches its files at the speed of a socket.

**A page is never lost.** A wait that expires, an interstitial that never clears, a challenge a
human has to click: none of them throws and none of them closes the tab. The DOM as it stands
comes back with the status the server gave it. Only a navigation Chrome refuses outright — a
name that will not resolve, a refused connection — is a `ClientException`, which is what a
crawl retries.

### Driving a page

`send` fetches; `open` hands the tab over. It is outside the pool `send` draws on, so holding
one open — through a login, a captcha, a form — never starves a crawl.

```dart
final page = await chrome.open(loginUrl);
await page.fill('#user', 'me');
await page.click('button[type=submit]');
await page.waitFor('.dashboard');                 // false on time, never a throw
print((await page.html()).$('.balance').text);    // read the DOM whenever you like
await page.close();
```

`chrome.page(url, (page) async { … })` is the same thing with the close written for you.

| | |
|---|---|
| `goto(url, until:, challenge:)` | navigate and wait; answers the page as it stands |
| `response()`, `html()`, `statusCode`, `url`, `isOpen` | what the tab holds right now, at any moment |
| `waitFor(sel)`, `waitWhile(sel)` | a mutation observer; `false` when the time runs out |
| `click(sel)`, `fill(sel, text)`, `press(key)` | real mouse and key events, with a DOM fallback |
| `select(sel, value)`, `hover(sel)` | an option by value or by its text; a menu that opens on hover |
| `text(sel)`, `attr(sel, name)`, `has(sel)` | one value off the live page, without building a document |
| `upload(sel, files)` | fill a file input the way a person fills one |
| `navigating(action)` | run the action and wait out the navigation it causes |
| `downloading(action, to:)` | run the action and wait out the download it starts; answers the file |
| `fetching(match, action)` | run the action and answer the XHR it fires, as a `Response` |
| `block(kinds)` | refuse to load these from now on; `block({})` allows everything again |
| `frame(match)` | the iframe as a page of its own |
| `back()`, `forward()`, `reload()` | the history |
| `scroll(times:, settle:)` | walk an infinite feed until it stops growing |
| `eval(js, awaitPromise:)` | run anything; the result comes back as JSON-able Dart |
| `screenshot(selector:, full:)` | a PNG of the window, one element, or the whole document |
| `pdf(background:, landscape:, scale:)` | Chrome's own print, headless only |
| `cookies([restore])` | read the jar, or put a saved session back into the browser |
| `onDialog(handler)` | answer an `alert`, `confirm` or `prompt` |
| `headers(map)` | headers sent with every request this tab makes from now on |
| `close()` | close the tab; safe twice |

**A wait is armed before the thing it waits for.** `navigating`, `downloading` and `fetching`
all take the action rather than being a bare `waitForX()` you call afterwards, and that is the
point: a click is dispatched and returns immediately, so a fast page has already finished
before the next line runs, and a wait armed afterwards has missed its event and sits until its
timeout.

```dart
await page.navigating(() => page.click('a.next'));
print(page.url);

final file = await page.downloading(() => page.click('.download'), to: 'books'.path);
final more = await page.fetching('/api/items', () => page.click('.next'));
print(more!.json['items']);          // the JSON behind the page, not the DOM it becomes
```

`frame` gives the iframe back as a `ChromePage`, so every word above works inside it — a
checkout form, a comment widget and a captcha box each live in one, and none of them can be
reached with a selector from the document around it.

```dart
final form = await page.frame('checkout');
await form!.fill('#card', '4242…');
await form.click('button[type=submit]');
```

Closing a frame closes nothing: it is a view of part of a tab. Close the page it came from.

A dialog is answered whatever you do, because Chrome holds the renderer on an open one and a
tab that ignores one will never load anything again. Without a handler it is dismissed, except
`beforeunload`, which is accepted.

```dart
page.onDialog((d) => d.accept(d.type == 'prompt' ? 'yes' : null));
```

A session logged into by hand once, kept for every run after it:

```dart
await 'cookies.json'.path.writeText(jsonEncode([
  for (final c in await page.cookies()) {'name': c.name, 'value': c.value, 'domain': c.domain},
]));

// next run
await page.cookies([for (final c in saved) Cookie(c['name'], c['value'])..domain = c['domain']]);
```

### Crawling

A crawl is a chain of five hooks and the stream of what they emit. The order of the chain is
the lifecycle, which is why it is a builder.

```dart
final stories = url.scrape<Story>()
    .onInit((ctx) {
      ctx.concurrency = 8;
      ctx.delay = 200.ms;
      ctx.pages = 50;
      ctx.robots = true;
    })
    .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      for (final row in ctx.response.html.$('tr.athing')) {
        final a = row.$('.titleline > a');
        if (a.attr('href') case final href?) ctx.emit((title: a.text, link: ctx.resolve(href)));
      }
      for (final a in ctx.response.html.$('a[href]')) ctx.follow(a.attr('href')!);
    })
    .onError((ctx) => Console.warn('${ctx.failure}'))
    .onFinish((summary) => Console.info('$summary'));

await for (final story in stories.rights) print(story);
```

Seeding: `url.scrape<T>()`, `urls.scrape<T>()` over an iterable of `Uri`, or
`requests.crawl<T>()` when the seeds need a method, a body or headers of their own. On a client
you are holding, `client.scrape<T>(url)` and `client.crawl<T>(requests)`.

**`onInit`** — once, on listen, with every crawl-wide setting. It may be async, so it can fetch
a token or read a config first.

| | default | |
|---|---|---|
| `concurrency` | 16 | requests in flight overall |
| `perHost` | 8 | requests in flight to one host |
| `delay` | 0 | minimum gap between two requests to one host |
| `timeout` | 30 s | headers, and each body chunk |
| `retries` | 2 | re-sends after a transport error or a 5xx; never after a TLS failure |
| `maxRetryAfter` | 30 s | the longest a `Retry-After` may hold a host |
| `redirects` | 5 | hops followed before a request fails |
| `bodyLimit` | 16 MB | bytes read before a response is abandoned |
| `pages` | — | stop after this many 2xx responses |
| `depth` | — | drop requests deeper than this many hops from a seed |
| `scope` | seeds' hosts | which URLs `follow` may go to |
| `robots` | false | fetch each host's `/robots.txt` once and obey it |
| `seed(url, meta:)` | | add a starting point |

**`onRequest`** — before every send. `ctx.request` is yours to edit, `ctx.url`, `ctx.depth`,
`ctx.attempt` and `ctx.meta` say where you are, and `ctx.skip()` drops it.

**`onResponse`** — every 2xx. `ctx.response`, `ctx.url` (the page that *answered*, after
redirects), `ctx.depth`, `ctx.pages`, `ctx.meta`, and the three things a hook can do:

```dart
ctx.emit(item);
ctx.follow(href, meta: {…}, offsite: false, revisit: false, onResponse: …, onError: …);
ctx.stop();
ctx.resolve(href);                                  // against the URL that answered
```

`follow` stays on the seeds' hosts (`www.` or not), strips fragments, never fetches a page
twice, drops `mailto:` and `javascript:` by itself, and **returns `false` when it dropped
something**, so nothing vanishes silently. It names a body with the same words `Request` and
`post` use.

**`onError`** — the engine has given up on a request. `switch` on `ctx.failure` and decide:

```dart
.onError((ctx) => switch (ctx.failure) {
  StatusFailed(:final response) when response.statusCode == 404 => ctx.ignore(),
  RequestFailed() => ctx.retry(after: 2.s),
  HookFailed(:final error) => Console.error('$error'),
  _ => null,                                        // leaves it a Left
})
```

**`onFinish`** — once, with a `ScrapeSummary` of pages, failures, requests, retries, drops,
bytes and time.

A failure is an item, not a stream error — the same contract `parallelize` has:

```dart
stories.rights      // skip failures
stories.lefts       // only the failures
stories.unwrap()    // throw the first
await for (final r in stories) switch (r) { case Right(:final value): …; case Left(:final value): … }
```

`ctx.robots = true` fetches each host's `/robots.txt` once and drops what it forbids into
`summary.dropped`; longest match wins, `*` and `$` count, and a `Crawl-delay` raises that
host's gap but never lowers it. A site with no rules, or one that cannot be read, forbids
nothing.

### Downloads

Atomic — a `.part` file renamed on success, with `Content-Length` verified — and resumable: a
failed or interrupted transfer keeps its `.part`, and the next download of the same path picks
up with a `Range` request.

**One shape and one name for one and for many.** `dest.download(url)` is a batch of one, so it
renders with the same `show` and needs nothing wrapped in a map to be displayed.

```dart
await 'sdk.zip'.path.download(url).show();
await {url: dest}.download(concurrency: 4).show();
await pairs.download(concurrency: 8).show();                  // Iterable<({Uri url, Path path})>
await stream.download(concurrency: 8).show();                 // ...or a stream of them
```

A stream source is the one that matters for a crawl: discovery and transfer overlap, so the
downloader starts before the crawl has finished finding things.

```dart
final last = await [Stream.fromIterable(known), scraped]
    .merge()
    .download(concurrency: 8)
    .show(slots: 8, message: 'Downloading', done: 'Done.');
print('${last?.written} new files');
```

Driving it by hand instead of `show`:

```dart
await for (final p in {url: dest}.download(concurrency: 4)) {
  switch (p.current) {
    case Downloading(:final ratio):    print('${p.current.label} $ratio');
    case Downloaded(:final bytes):     print('${p.current.label} $bytes B');
    case DownloadSkipped():            print('${p.current.label} exists');
    case DownloadFailed(:final error): print(error);
  }
}
```

`checksum:` says what the bytes must hash to — a wrong one is a `DownloadFailed` holding a
`ChecksumMismatch`, and the `.part` goes rather than waiting to be resumed into the same wrong
file. It is on the single-file form alone, because one checksum describes one file.
`ifModified:` asks the server whether the file changed instead of skipping because it is there,
and a `304` is a `DownloadSkipped`.

```dart
await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, '9f86d0…')).show();
await feed.path.download(url, ifModified: true).show();       // re-run cheaply
```

Every download sets `Request.raw`, so `path.download(url)` writes the file and not a rendering
of it even inside a Chrome scope, and stops on the enclosing `Cancel.scope`.

---

## `cli` — options, commands, lifecycle, console

### Options and arguments are values

An option is a value, so its name is written once and its type is the type you read back —
and so is a positional. `ctx(…)` is not nullable when it has a default or is required.

```dart
enum Stage { dev, staging, production }

final stage   = Opt.among('stage', Stage.values, abbr: 's').or(Stage.production);  // Stage
final token   = Opt.text('token', abbr: 't').required();                           // String
final workers = Opt.number('workers', abbr: 'w').or(4);                            // int
final dryRun  = Opt.flag('dry-run', abbr: 'd');                                    // bool
final since   = Opt.by('since', DateTime.parse);                                   // DateTime?
```

`Opt.among` takes the values themselves — an enum, not a list of strings to match again by
hand. `Opt.by` takes any parse. `.or(v)` gives a default and `.required()` makes it an error to
omit; both make `ctx(…)` non-nullable.

A positional is the same thing written by position rather than by name:

```dart
final id      = Arg.text('id', description: 'Which one').required();   // String
final count   = Arg.number('count').or(1);                             // int
final level   = Arg.among('level', LogLevel.values).or(LogLevel.info); // LogLevel
final when    = Arg.by('when', DateTime.parse);                        // DateTime?
final targets = Arg.rest('targets').required();                        // List<String>
```

`Arg.rest` takes everything that is left; there is at most one and it comes last, and on it
`.required()` means *at least one*. A command declares them with `args:`, they are bound in
order before the handler runs, and a missing required one, a bad value or an unexpected extra
is a `UsageException`.

They print themselves, which `ctx.rest` never did:

```
Usage: tk hash <paths>... [options]

Arguments:
  <paths>...           Files to digest

Options:
  -a, --algo           Digest algorithm (md5|sha1|…) [default: sha256]
  -h, --help           Print this help message
```

`<name>` is required and `[name]` is not, so the usage line says which is which without a word
of explanation, and `[command]` appears only on a command that has subcommands.

`ctx.rest` is still the raw list of positionals, for a command that declares no `Arg`s at all —
declaring them is what buys the type, the default, the checking and the help line.

### Commands

A command is everything it is given: `options:`, `commands:` and `handler:` are constructor
arguments, so there is one way to say each and nothing is set after the fact.

```dart
final cli = Cli(
  name: 'deployer',
  description: 'Ship it',
  version: '1.2.0',
  args: [id],
  options: [stage, token, workers, dryRun],
  handler: (ctx) async {
    Console.info('Deploying to ${ctx(stage).name} with ${ctx(workers)} workers');
  },
  commands: [
    CliCommand('fetch', description: 'Fetch a thing', options: [verbose], handler: fetch),
    CliCommand('db', description: 'Database', commands: [
      CliCommand('migrate', handler: migrate),
    ]),
  ],
);

await cli.run(args);
```

Options may precede the subcommand, short flags combine (`-dv`), and a short option may attach
its value (`-w8`). `--help` and `--version` are handled for you.

Inside a handler, `CliContext` is what you have:

```dart
ctx(workers);            // the typed value of an option
ctx(id);                 // ...or of an argument
ctx.rest;                // the raw positionals, for a command that declared none
ctx.command;             // the command that ran
ctx.cancel;              // the run's CancelToken
```

`Cli.run` owns the lifecycle: a usage error is a `UsageException`, which prints the usage hint
and exits 64; `ctx.cancel` is cancelled on a signal; and whether the action returns or throws,
the exit hooks run and the signal handlers are released so the process actually ends. It also
opens the `Cancel.scope` whose token is `ctx.cancel`, so a program that wants ^C to stop its
downloads writes nothing at all.

```dart
Future<void> work(CliContext ctx) async {
  await pairs.download(concurrency: 8).show();       // stops on ^C
  await urls.parallelize(fetch, concurrency: 8);     // and so do these
  await retry(fetchIndex, attempts: 5);
}
```

### Lifecycle

Two shapes and no others: `onExit` registers a listener for the exit event, and `exit` is the
event happening.

```dart
Lifecycle.onExit(chrome.close);          // register
Lifecycle.onExit(null);                  // forget every listener, and stop the signal watch

await Lifecycle.exit();                  // run them, leave with 0
await Lifecycle.exit('no URL given');    // say why in red on stderr, leave with 1
await Lifecycle.exit('bad args', 64);    // ...with the code you choose
```

Listeners run on SIGINT, SIGTERM, `Lifecycle.exit`, and when `Cli.run` returns — in
registration order, and one that throws does not stop the rest. `onExit` answers a function
that removes *that* listener:

```dart
final release = Lifecycle.onExit(unlock);
await deploy();
release();                               // it worked; nothing to undo
```

The signal watch keeps the isolate alive, so a script with no `Cli` around it must end with
`Lifecycle.exit`, `dart:io`'s `exit`, or `onExit(null)`.

It is a namespace rather than two top-level functions because a top-level `exit` would
*silently* shadow `dart:io`'s in every file importing this package.

### Console

One namespace for everything that reaches a terminal. The log verbs, the rule, the prompts and
the three indicators share a live region, so they compose: a log line written while a spinner
is running scrolls above it instead of landing on top of it.

```dart
final spinner = Console.spinner('Connecting');
Console.info('resolved 3 hosts');     // scrolls above; the spinner keeps spinning
spinner.text = 'Fetching the index';  // redraws without restarting the animation
spinner.succeed('index ready');
```

Logging is levelled and written through `Io`, so a redirected sink captures it:

| | |
|---|---|
| `Console.debug/info/ok/warn/error(msg)` | `· ℹ ✓ ⚠ ✖`; `warn` and `error` go to stderr |
| `Console.level`, `Console.isEnabled(l)` | the floor, `LogLevel.debug` … `silent` |
| `Console.silenced(action)` | mutes *that* action and what it awaits, not the process |
| `Console.stages(n)` | a self-numbering `[1/n] message` banner |
| `Console.writeln(msg)`, `Console.rule([title])`, `Console.clear()` | unlevelled |

The three indicators, each driven directly or through the sugar:

| | |
|---|---|
| `Console.spinner(msg, style:)` | indeterminate; `text`, `succeed`, `fail`, `warn`, `info`, `stop` |
| `Console.spin(msg, action, done:, failed:)` | the same, ended for you when `action` settles |
| `Console.progress(total, message:)` | one measurable thing; `tick([n, label])`, `done([msg])` |
| `Console.tasks(slots:, total:)` | a board of concurrent rows; `report(batch)`, `done([msg])` |
| `stream.show(slots:, message:, done:)` | any `Stream<BatchProgress>` straight onto a board |

`SpinnerStyle` names the frames and the interval — `braille` (the default), `dot`, `line`,
`ellipsis`, `bar`, `arc` — and takes any others:

```dart
const pulse = SpinnerStyle(['·', 'o', 'O', 'o'], interval: Duration(milliseconds: 120));
Console.spinner('Waiting', style: pulse);
```

Prompts, where `or` is the default as it is everywhere:

```dart
Console.ask('Project name', or: 'app', required: true, validate: (v) => v.contains(' ') ? 'no spaces' : null);
Console.confirm('Continue?', or: true);
Console.secret('Password');                       // no echo
Console.select('Pick one', choices, or: choices.first, display: (c) => c.label);
```

Without a terminal every one of these degrades to durable lines rather than escape codes: the
spinner writes once when it starts and once when it ends, and a progress bar reports each new
tenth. A captured log reads the same without the animation.

Styling is on `String`: `.bold`, `.red`, `.green`, `.cyan` and the rest, and `Io.color`
decides whether they do anything.

---

## `native` — the Rust library

`native/` is one Rust `cdylib`, `dart_toolkit_native`, prebuilt per platform and loaded through
`dart:ffi`. It holds the digests, the MACs, the archive formats and the streaming
`content-encoding` decoders, and nothing else.

```dart
Native.isAvailable;   // whether it loaded
Native.reason;        // why not
Native.version;       // the ABI version it reports
```

It is looked for at `DART_TOOLKIT_NATIVE` (a path), then beside the running executable, then at
`native/prebuilt/<os>_<arch>/` inside the package. `make native` builds it for this machine.

Without it, hashing and the archive formats throw `UnsupportedError` naming what was needed,
and `IoClient` asks for `gzip` alone instead of also brotli and zstd. There is no Dart fallback
for any of them on purpose: two implementations of one primitive is two places for a bug.

`NativeBridge` is the FFI plumbing. It is public only because `fs`, `hash` and `http` are
separate libraries; nothing outside the package should call it, and it is not covered by the
versioning promise.

---

## Cookbook

### Scrape a paginated listing into a CSV

```dart
void main(List<String> args) => Cli(name: 'listing', handler: (ctx) async {
  final rows = <Map<String, Object?>>[];

  await for (final row in 'https://example.com/list'.url.scrape<Map<String, Object?>>()
      .onInit((c) => c..concurrency = 8..delay = 200.ms..robots = true)
      .onResponse((c) {
        for (final tr in c.response.html.$('table tbody tr')) {
          final td = tr.$('td');
          rows.add({'name': td.texts[0], 'size': td.texts[1]});
        }
        if (c.response.html.$('a.next').attr('href') case final next?) c.follow(next);
      })
      .rights) {
    rows.add(row);
  }

  await rows.table.orderBy('name').saveCsv('listing.csv');
  Console.ok('${rows.length} rows');
}).run(args);
```

### Log in once by hand, then crawl as that user

```dart
final chrome = await ChromeClient.connect();       // headful, one profile across runs
Lifecycle.onExit(chrome.close);

final page = await chrome.open(loginUrl);
if (!await page.has('.dashboard')) {
  Console.info('Log in in the browser window; waiting…');
  await page.waitFor('.dashboard', timeout: 5.m);
}
await page.close();

await Http.scope(client: chrome, () async {
  await for (final item in listUrl.scrape<Item>().onResponse(parse).rights) print(item);
});

await Lifecycle.exit();
```

### Click something that downloads a file

```dart
final page = await chrome.open(bookUrl);
if (await page.has('#bookFormat')) await page.select('#bookFormat', 'EPUB');

final file = await page.downloading(() => page.click('.addDownloadedBook'), to: 'books'.path);
Console.ok(file == null ? 'no download started' : 'saved ${file.name}');
await page.close();
```

### Read the API behind a page instead of its DOM

```dart
await chrome.page(searchUrl, (page) async {
  final res = await page.fetching('/api/search', () => page.fill('#q', 'dart').then((_) => page.press('Enter')));
  for (final hit in res!.json['hits'].list) print(hit['title'].to<String>());
});
```

### A crawl that renders, blocks the heavy things, and downloads at socket speed

```dart
final chrome = await ChromeClient.launch(tabs: 4, block: Resource.heavy);
await Http.scope(client: chrome, () async {
  final assets = url.scrape<({Uri url, Path path})>()
      .onRequest((c) => c.request[ChromeClient.waitFor] = '.gallery img')
      .onResponse((c) {
        for (final img in c.response.html.$('.gallery img[src]')) {
          final src = c.resolve(img.attr('src')!);
          c.emit((url: src, path: 'out'.path / src.pathSegments.last.filename));
        }
        for (final a in c.response.html.$('a.next')) c.follow(a.attr('href')!);
      })
      .rights;

  await assets.download(concurrency: 8).show(message: 'Downloading');
});
await chrome.close();
```

The renders go through Chrome and the images go straight down a socket, because every download
sets `Request.raw`.

### Upload a file to an API

```dart
await Http.scope(headers: {'authorization': 'Bearer $token'}, () async {
  final res = await api.post(form: {'title': 'holiday'}, files: {'photo': 'beach.jpg'.path});
  if (!res.isOk) await Lifecycle.exit('upload failed: ${res.statusCode}');
  print(res.json['id'].to<String>());
});
```

### Hash a directory tree in parallel

```dart
final files = await 'assets'.path.files(recursive: true).toList();
final digests = await files.parallelize((f) => f.hash(Hash.blake3), concurrency: 4);
for (final (file, digest) in files.sequence.zip(digests.rights)) print('$digest  $file');
```

### Run a pipeline of shell commands with one policy

```dart
await Shell.scope(() async {
  final dirty = (await ('git status --porcelain' | 'wc -l').run()).text.trim();
  if (dirty != '0') await Lifecycle.exit('working tree is dirty');
  await run('dart analyze');
  await run('dart test');
}, workdir: repo, strict: true, quiet: true);
```

### Watch a directory and act on changes

```dart
await for (final event in 'src'.path.watch(recursive: true)) {
  if (event.path.path.ext != 'dart') continue;
  await Console.spin('Rebuilding', () => run('dart analyze'));
}
```

---

## Testing

**Nothing in `lib/` exists for tests.** The handler-backed client lives in
`test/mock_client.dart`, and the two seams that make a program testable are `Io` and `Client`.

```dart
final buffer = StringBuffer();
Io.out = buffer;
Console.ok('captured, not printed');
await run('echo also-captured');       // subprocess output goes through Io too
Io.reset();

final client = MockClient((req) async => Response('{"ok": true}', 200));
await Http.scope(() => url.json(), client: client);

final streaming = MockClient.streaming((req, body) async => StreamedResponse(chunks, 200));
```

Scripted prompts:

```dart
final answers = ['app', 'y'].iterator;
Io.input = () => answers.moveNext() ? answers.current : null;
```

For a client of your own, the conformance battery is the contract:

```dart
import 'client_conformance.dart';

void main() => clientConformance('MyClient', (base) => MyClient());
```

`make` runs analyze, format and the tests; `make native` builds the Rust library for this
machine; `make startup` prints the per-module startup cost.

---

## Performance notes

- **Nothing third-party at runtime but `path`.** Every parser, the HTTP client and the archive
  formats are the package's own, because `package:html`, `xml`, `archive` and `http` together
  cost about a second of front-end work per `dart run`.
- **Ten modules, one library each**, so a program pays for what it imports. `dart:ffi` costs a
  program that touches none of `fs`, `hash` and `http` nothing.
- **Opening the native library is lazy and costs about 12.5 ms**, most of it resolving the
  package root. `fs` and `hash` pay it on first use; `http` pays it on its first request, in
  exchange for brotli and zstd taking 15–20% off every response body.
- **A file operation streams.** Hashing, downloading and archiving name the file, not its
  bytes, so memory is flat whatever the size — and `files:` makes an upload the same.
- **Block what you do not read.** `ChromeClient(block: Resource.heavy)` is the largest single
  win available to a rendered crawl.
- **Measure back to back or not at all.** Startup drifts ±80 ms between runs, so a claim is two
  numbers from the same minute, never one. `make startup` prints the table.
- **`parallelize(isolate: true)` is for CPU-bound work only** — the argument and the result are
  copied, so it pays off when the work is larger than the copy.
- **An executable runs through pub's snapshot**: `dart run dart_toolkit:tk`.

---

## Troubleshooting

**`UnsupportedError: … needs dart_toolkit_native`** — the library did not load. `Native.reason`
says why. From a checkout, run `make native`; otherwise point `DART_TOOLKIT_NATIVE` at the
file.

**A script that finishes but does not exit** — the signal watch keeps the isolate alive. End
with `Lifecycle.exit()`, or `Lifecycle.onExit(null)`, or put the work inside a `Cli`.

**`StateError: cancellable outside a Cancel.scope`** — `.cancellable` binds to a scope and
refuses to be a wrapper that does nothing. Open one with `Cancel.scope(…, token: …)`, or let
`Cli.run` open it for you.

**A request sent twice carries the first send's cookies** — sending consumes a request. Call
`request.copy()` before the second send; everything in the module that sends a request you own
already does.

**A crawl finds nothing on a page you can see in a browser** — the content is built by the
page's own scripts. Put a `ChromeClient` in the scope, and say what to wait for with
`ChromeClient.waitFor`.

**A download inside a Chrome scope writes HTML instead of the file** — it should not; every
download sets `Request.raw`. If you are sending the request yourself, set it:
`request[Request.raw] = true`.

**A tab stops responding after a page opens a dialog** — this is handled: dialogs are answered
automatically. If you registered an `onDialog` handler that never calls `accept` or `dismiss`,
the default still applies, but a handler that awaits something forever will hold the tab.

**`ChromeClient.attach` says nothing is listening** — start Chrome with
`--remote-debugging-port=9222 --user-data-dir=<dir>`, or use `ChromeClient.connect()`, which
starts one for you and lets it outlive the run.

**A cookie set during a login is missing** — use `Http.scope(cookies: true)`. The jar walks the
redirect chain, which is where a login sets its session.

**Tables or progress bars are misaligned with non-ASCII text** — they use `Io.width`, which
counts terminal columns. If you are formatting by hand, use it too rather than `String.length`.
