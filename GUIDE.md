# The dart_toolkit guide

The manual: every module, what each piece is for, and whole programs built with them.
[`README.md`](README.md) is the tour. [`CONVENTIONS.md`](CONVENTIONS.md) is why the API looks
the way it does, and [`CHANGELOG.md`](CHANGELOG.md) is what each release changed. This guide
describes 0.0.6.

## Contents

- [Start here](#start-here) — installing, three programs, the six ideas, the modules
- [`core`](#core) — `Either`, `Env`, `Io`, small conversions
- [`async`](#async) — cancellation, `parallelize`, `Worker` and `Pool`, retry, locks, streams
- [`collection`](#collection) — `Sequence`, `Table`
- [`formats`](#formats) — JSON, YAML, TOML, INI; HTML and XML
- [`fs`](#fs) — paths, files, watching, archives
- [`hash`](#hash) — digests, MACs, encodings
- [`process`](#process) — running commands
- [`http`](#http) — requests, the scope, clients, Chrome, crawling, downloads
- [`cli`](#cli) — options, commands, built-ins, lifecycle, console
- [`native`](#native) — the Rust library
- [`ffi`](#ffi) — calling C, in its own namespace
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

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
```

That one import is every module except `ffi.dart`, which you import by name (see [`ffi`](#ffi)).
Import a single module (`package:dart_toolkit/http.dart`, …) only when you have measured and
want less.

Hashing, archives, gzip/brotli/zstd decoding and charsets past UTF-8 and windows-1252 (Shift_JIS,
EUC-KR, GBK, Big5, …) need the native library. It ships prebuilt for
`macos_arm64`, `macos_x64`, `linux_x64` and `linux_arm64`. `NativeLib.isAvailable` says
whether it loaded and `NativeLib.reason` says why not.

### Three programs

**Fetch a page and read it.**

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

Future<void> main() => Http.scope(() async {
  final doc = await 'https://news.ycombinator.com'.url.html();
  for (final row in doc.$('tr.athing')) {
    print(row.$('.titleline > a').text);
  }
});
```

**Crawl a site into a table.**

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

Future<void> main() async {
  final links = 'https://example.com'.url
      .scrape<Map<String, Object?>>()
      .onInit((ctx) => ctx.pages = 50)
      .onResponse((ctx) {
        final links = ctx.response.html.$('a[href]');
        for (final a in links) {
          ctx.emit({'title': a.text, 'href': '${ctx.resolve(a.attr('href'))}'});
        }
        ctx.follow(links);
      });
  Table.rows(await Http.scope(() => links.rights.toList())).show();
}
```

**A command-line program**, with typed options, a spinner and ^C handled.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

final top = Opt.number('top', abbr: 'n').or(10);
final out = Opt.text('out', abbr: 'o').or('out.csv');

void main(List<String> args) => Cli(
  name: 'report',
  values: [top, out],
  handler: (ctx) async {
    final rows = await Console.spin('Fetching', () => fetch(ctx(top)));
    await Table.rows(rows).save(ctx(out));
    Console.ok('wrote ${ctx(out)}');
  },
).run(args);

Future<List<Map<String, Object?>>> fetch(int n) async => [
  for (var i = 0; i < n; i++) {'n': i},
];
```

It already has `--help`, `-v`, `-q` and `--completion`. ^C stops it through its exit hooks, and
an exception prints one red line and exits 1.

### The six ideas

**1. A conversion is the way in.** You convert, and the vocabulary lives on the result:

```dart
'https://x.com'.url;     // Uri
'/tmp/a.txt'.path;       // Path
'{"a":1}'.json;          // JsonDocument
'a: 1'.yaml;             // YamlDocument, a JsonDocument
'<p>hi</p>'.html;        // HtmlDocument
'<a/>'.xml;              // XmlDocument
[1, 2, 3].sequence;      // Sequence, a lazy query
60.s;                    // Duration
```

**2. A setting every call would repeat belongs to a scope.** There are three, and they read
alike. A per-call argument still wins.

```dart
await Http.scope(timeout: 30.s, retries: 2, cookies: true, () async {/* … */});
await Shell.scope(workdir: repo, timeout: 5.m, () async {/* … */});
await Cancel.scope(token: stop, () async {/* … */});
```

**3. Where many things happen, a failure is a value.** `parallelize`, `Pool` and a crawl settle
each item into `Either`. You pick the policy where you use it: `.rights`, `.lefts`,
`.unwrap()`, or a `switch`.

**4. A guaranteed value is not nullable.** `ctx(option)` with a default, `row.number('size')`,
`els.text` and `doc.to<int>()` return the value or throw an error that names what was missing.
The `…OrNull` form is for the caller who expects absence.

**5. One word per idea.** A default is `or`. A body is `text` / `bytes` / `form` / `json` /
`files`. One file or a thousand is `download`. Serialised markup is `markup`. An async
operation is bare, and its sync twin (only in `fs`) ends in `Sync`.

**6. The short form is sugar over a class.** `parallelize` runs on a `Pool` of `Worker`s, and
`url.scrape<T>()` runs on a `Crawler<T>`. Reach for the class when you need state, reuse or a
test.

### The modules

| library | holds | imports |
|---|---|---|
| `core.dart` | `Either`, `Env`, `Io`, `.url`, `60.s`, progress interfaces | — |
| `async.dart` | `Cancel`, `parallelize`, `Worker`, `Pool`, `retry`, `Semaphore`, stream operators | `core` |
| `collection.dart` | `Sequence`, `Group`, `Table`, `Row` | `formats` |
| `formats.dart` | `JsonDocument`, `YamlDocument`, TOML, INI, the HTML/XML tree, `$`, `$x` | `collection` |
| `fs.dart` | `Path`, watching, archives, compression | `native` |
| `hash.dart` | `Hash`, `Secure`, hex/base64/base32 | `native` |
| `process.dart` | `run`, `ShellRun`, `Shell.scope`, pipelines, `which` | `fs` |
| `http.dart` | `Request`, `Response`, `Client`, `Http.scope`, `ChromeClient`, `Crawler`, downloads | `fs`, `hash`, `formats` |
| `cli.dart` | `Opt`, `Arg`, `CliCommand`, `Cli`, `Lifecycle`, `Console` | `core` |
| `native.dart` | `NativeLib` | — |
| `ffi.dart` | `Ffi`, `Lib`, `Fn`, `C` — **not in the barrel** | — |

---

## `core`

### `Either`

A settled outcome, `Left` (a failure) or `Right` (a success): what `parallelize`, `Pool`
and `scrape` hand back. A script reads one; it does not build its own (`try` is shorter).

```dart
final [outcome] = await [url].parallelize(fetch);
outcome.rightOrNull ?? fallback;
outcome.unwrap(); // the value, or throw the Left with its trace
switch (outcome) {
  Right(:final value) => use(value),
  Left(:final value) => Console.warn('$value'),
}
```

On a list or a stream of outcomes, and on the future of a list, so no parentheses:

```dart
settled.rights;   // the successes
settled.lefts;    // the failures
settled.unwrap(); // the successes, or throw the first failure
await urls.parallelize(fetch).rights;
```

### `Env`

The process environment, with in-memory overrides. An empty variable counts as unset.

```dart
Env.get('API_TOKEN');            // throws, naming the key, when unset
Env.get('PORT', or: '8080');
Env.getOrNull('HOME');
Env.has('CI');
Env.isCI;
Env.set('TZ', 'UTC');            // children of `run` inherit it

Env.load();                                   // .env into the overrides
Env.load(path: '.env.local', override: true); // …and let it beat the real environment
Env.parse('URL=http://x/#frag # a comment');  // {URL: http://x/#frag}
```

`#` starts a comment only after whitespace. Double-quoted values unescape `\"`, `\\` and `\n`.

### `Io`

Everything written to a terminal goes through `Io`, which also answers every question about
where it goes. Redirect it, and the console, the logger and subprocess output are all redirected
at once.

```dart
Io.out;                    // StringSink
Io.out = StringBuffer();   // capture; Io.reset() restores it
Io.isTerminal;
Io.isRedirected;
Io.columns;
Io.color;                  // per sink: `app 2>log` gets no escape codes
await Io.readLine();       // on a helper isolate, so ^C is still heard
Io.input = () => 'scripted answer';
Io.width('名前');          // 4 — terminal columns, not code units
Io.truncate(text, 40);
```

### Small conversions

```dart
'https://x.com/a'.url;               // Uri
'2024-05-06'.match(RegExp(r'\d{4}')); // '2024', or null
100.ms;
5.s;
2.m;
1.h;
3.d;
30.s.humanized;                      // '30s'
await 1.s.delay();
```

`TaskProgress` and `BatchProgress` are how `fs` and `http` tell `cli` what is happening without
importing it. Anything that streams a `BatchProgress` can be drawn with `.show()`.

---

## `async`

### Cancellation is ambient

A token is never passed through a call. `Cancel.scope` holds one, and `download`, `retry`,
`run`, `parallelize`, `Pool`, `Semaphore`, `Duration.delay` and `.cancellable` all
read it. `timeout:` cancels the scope after that long:

```dart
await Cancel.scope(timeout: 5.s, () async {
  await for (final item in feed.cancellable) {
    print(item);
  }
});
```

A scope inside another hears the outer one: cancelling the outer token cancels the inner scope
too, so a helper that opens its own scope still stops on ^C.

Inside a scope, `Cancel.isCancelled`, `Cancel.reason` and `Cancel.throwIfCancelled()` read the
scope's token. Outside a scope all three are quiet, because nothing has cancelled. `.cancellable`
throws outside a scope, because otherwise it would be a wrapper that does nothing.

```dart
final token = CancelToken();
final undo = token.onCancel(() => print('cleaning up')); // returns its own removal
token.cancel('done');
undo();
```

`Cli.run` opens the scope for you: its token is `ctx.cancel`, and ^C cancels it.

### `parallelize`

The short form: many items, bounded concurrency, and one outcome per item.

```dart
final settled = await urls.parallelize((u) => u.get(), concurrency: 8); // List<Either<Object, Response>>
print('${settled.rights.length} ok, ${settled.lefts.length} failed');

final streamed = pages.parallelize(parse, concurrency: 4); // Stream<Either<…>>, as items finish
```

`isolate: true` runs the work on long-lived background isolates, for CPU-bound jobs. Each item
and its result cross a port; the worker function crosses once per isolate.

```dart
final digests = await blobs.parallelize(slowDigest, concurrency: 4, isolate: true);
```

### `Worker` and `Pool`

The class `parallelize` runs on. Use it directly when each worker needs state built once, such
as a database handle, a model or a compiled regex table.

```dart
final class Thumbnail extends Worker<Path, int> {
  late final RegExp image;

  @override
  void init() => image = RegExp(r'\.(png|jpe?g)$'); // once per isolate

  @override
  Future<int> run(Path file) async => image.hasMatch(file) ? await file.size() : 0;
}

Future<void> sizes(Stream<Path> files) async {
  final pool = await Pool.spawn(Thumbnail.new, size: 4);
  await for (final size in pool.map(files).rights) {
    print(size);
  }
  await pool.close();
}
```

| | |
|---|---|
| `Pool.spawn(create, size:, isolate:)` | starts `size` workers from a sendable factory (a tear-off like `Thumbnail.new`) and waits for every `init` |
| `pool.run(item)` | one item; throws what `run` threw |
| `pool.map(stream)` | `Stream<Either<Object, R>>`, unordered, with at most `size` items in flight |
| `pool.close()` | runs every worker's `close`; idempotent |

A failing item fails only itself. A dead isolate is replaced. The enclosing `Cancel.scope`
stops the item in flight. `isolate: false` keeps the workers on this isolate, for IO-bound
work.

### `retry`

```dart
final data = await retry(
  () => api.json(),
  attempts: 3,
  delay: 200.ms,
  maxDelay: 5.s,
  when: (e) => e is! FormatException,
  onRetry: (n, e, next) => Console.warn('attempt $n failed; waiting $next'),
);
```

The backoff wait ends as soon as the scope is cancelled.

### Locks and permits

```dart
final gate = Semaphore(4);
await gate.run(() => work()); // held for the action; Semaphore(1) is a lock
```

### Stream operators

In-house, so nothing third-party loads to get them. All of them honour pause and cancel their
timers.

```dart
numbers.chunk(100);          // fixed-size lists
numbers.chunkEvery(1.s);     // whatever arrived in each window
numbers.debounce(300.ms);    // the last of a burst
numbers.throttle(1.s);       // at most one per window
numbers.flatMap((n) => Stream.value(n * 2));
[numbers, numbers].merge();  // one stream out of many
```

---

## `collection`

### `Sequence` — a lazy query

`.sequence` turns any `Iterable` into a query that stays lazy until something iterates it.

```dart
final top = tracks.sequence
    .where((t) => t.format == 'flac')
    .sortedBy((t) => t.disc)
    .thenBy((t) => t.number, descending: true)
    .take(10);
```

| | |
|---|---|
| shape | `where`, `map`, `expand`, `take`, `skip`, `takeWhile`, `skipWhile`, `takeLast`, `skipLast` |
| order | `sortedBy`, `sortedWith`, `sorted`, `sortedDescending`, `thenBy`, `reversed` |
| windows | `chunk(n)`, `windowed(n, step:)`, `pairwise`, `indexed` |
| sets | `distinct`, `distinctBy`, `union`, `intersect`, `except` |
| pairs | `zip` |
| joins | `innerJoin`, `leftJoin` |
| grouping | `groupBy`, `countBy`, `indexBy`, `partition` |
| folds | `sum`, `average`, `sumBy`, `averageBy`, `max`, `min`, `maxBy`, `minBy` |
| ranges | `Sequence.range(count)`, `Sequence.range(from, to, step)` |

- A sort runs again on every read.
- `windowed` holds only its window, so it works on an endless source.
- `sum` of ints is an `int`.
- `sum`, `max` and `sorted` exist only where they make sense: on a sequence of `num` or of
  `Comparable`.

A `Map` converts too, to records:

```dart
for (final (k, v) in counts.sequence.sortedByValue(descending: true).take(3)) {
  print('$k $v');
}
```

### `Table` — rows of named columns

A table keys by column name, because a CSV's columns are not known until it is read.

```dart
final sales = await Table.read('sales.csv'); // by extension: .csv .tsv .json .ndjson/.jsonl
await for (final row in Table.readRows('huge.csv')) {
  print(row['id']); // one row at a time, for files larger than memory
}

Table.rows(maps);
Table.cells(['name', 'size'], [['a', 1], ['b', 2]]);
Table.csv(text); // quotes, CRLF and a BOM handled; 3–4× faster than 0.0.5
doc.$('table#songs').table; // an HTML <table>
```

Querying returns a new `Table`:

```dart
sales
    .where((r) => r.number('amount') > 100)
    .orderBy('region')
    .thenBy('amount', descending: true)
    .select(['region', 'amount'])
    .derive('k', (r) => r.number('amount') / 1000)
    .take(20)
    .show();

sales.groupBy('region').sum('amount');
sales.pivot(rows: 'region', column: 'month', value: 'amount', agg: Agg.sum);
sales.join(regions, on: 'region');
```

Reading a cell: `row.text('name')`, `row.number('size')`, `row.numberOrNull('size')`,
`row.get<int>('n')`, `row.get<DateTime>('at')` (ISO 8601 text). A thousands separator is
stripped only where it groups thousands, so `'1,5'` is not 15. `t.numbers('bytes')` is a
`Sequence<num>`, so `.sum`, `.max` and `.average` follow directly.

Writing: `t.toCsv()`, `t.toNdjson()`, `t.toMarkdown()`, `t.toJson()`, `await t.save(path)` — in
the format the extension names, `.csv`, `.tsv`, `.json`, `.ndjson`/`.jsonl` or `.md`, the same
ones `Table.read` reads — and `t.show()`, which is the only console table renderer.

`t.orderBy('size', descending: true).take(10)` sorts ten rows, not the whole table: the order
runs when the rows are read, and a `take` straight after it selects rather than sorts.

A CSV with a repeated header reads the second as `name_2`, a blank line is not a row (`""` is
one, with an empty cell), and a quote that is never closed is a `FormatException` naming its
line.

---

## `formats`

Every parser here is the package's own. `test/formats_diff_test.dart` checks each one against
`package:html`, `xml` and `yaml`.

### Data: one document model

JSON, YAML, TOML and INI all decode to `JsonDocument`, so one query language and one `to<T>()`
serve all four.

```dart
final pubspec = (await 'pubspec.yaml'.path.readText()).yaml;
final name = pubspec['name'].to<String>();            // or StateError naming $.name
final port = pubspec['port'].toOrNull<int>() ?? 8080; // absence expected
final tags = pubspec['topics'].to<List<String>>();     // every element converted
final deps = pubspec['dependencies'].to<Map<String, Object?>>();
```

- `to<T>()` returns `T` or throws `StateError('$.server.port is "x" (String), expected int')`.
- `to<int>()` on `1.7` is a mismatch, not `1`.
- Typed lists and maps work for `String`, `int`, `double`, `num` and `bool`.

```dart
doc.list;    // List<JsonDocument>
doc.map;     // Map<String, JsonDocument>
doc.raw;     // the decoded Dart value
doc.isNull;
doc.toYaml(); // round-trips through this parser and package:yaml
```

**YAML** — `.yaml` is the first document. A multi-document stream is on `.documents`:

```dart
final stream = '---\na: 1\n---\nb: 2'.yaml;
stream['a'].to<int>();                     // 1
stream.documents.map((d) => d.raw);         // ({a: 1}, {b: 2})
```

Anchors, aliases (in flow collections too), merge keys (`<<: *base`, `<<: [*a, *b]`), block
scalars with indicators, multi-line quoted scalars, `%` directives and `!!str` are all
supported. A duplicate key, a bad escape, an unterminated collection or string, and nesting
deeper than 1000 each throw a `FormatException` with the line number; nothing hangs or
overflows the stack.

**TOML and INI** — `text.toml` and `text.ini`. A TOML table defined twice, an inline table
extended afterwards and `[[a]]` over a plain array are errors. An INI value becomes a number
only when it reads back exactly as written, so `1.10`, `01234` and `0x10` stay text; a key that
cannot nest — `a.b.c` after `a.b` is a value, as properties files write them — stays whole, and
a quoted part of a section name keeps its dots: `["www.example.com"]`, `[remote "origin"]`.

**From a file** — `JsonDocument.read(path)` picks the parser by extension (`.json`, `.yaml`,
`.yml`, `.toml`, `.ini`, `.cfg`, `.conf`), as `Table.read` does for tables:

```dart
final config = await JsonDocument.read('config.toml');
```

**JSONPath** — `$` returns a list of documents:

```dart
doc.$(r'$.dependencies.*');
doc.$(r'$.items[*].id');
doc.$(r'$..name');          // recursive descent
doc.$(r'$.items[1:3]');     // slices, including [::-1] and [-2:]
doc.$(r"$['a','x.y']");     // unions
```

A filter (`[?(@.v > 1)]`) is a `FormatException`; use `.where` on the result, which is
shorter.

### Markup: one tree

HTML and XML share `Node`, `Element`, `Text`, `Attribute`, `Nodes` and `Elements`. On every
document, **`$` is CSS and `$x` is XPath**.

```dart
final page = await url.html(); // or res.html, or '<p>…</p>'.html
page.$('h1').text;                                  // the first match
page.$('td.title > a[href]').attr('href');         // or StateError naming the tag
page.$('link[rel=next]').attrOrNull('href');        // absence expected
page.$('#songs tr').$('td:nth-child(3)').texts;     // query a result again
page.$x('//tr[td[2]="FLAC"]/td[1]/a/@href').texts;
```

**HTML is parsed the way a browser reads it:**
- `<noscript>` and `<template>` in `<head>` keep the rest of the head in the head.
- `<a>one<a>two` is two links, and `<h1>a<h2>b` is two headings.
- `/>` counts only in SVG and MathML.
- `<pre>` and `<textarea>` drop their first newline.
- Entities without `;` decode only for the HTML5 legacy names, and never inside an attribute
  before `=` or an alphanumeric. So `?a=1&lang=en` stays as written.
- SVG names keep their case: `viewBox`, `foreignObject`. A selector folds and still finds them.
- `</ p>` and `</>` are dropped.

One thing it does not do is foster parenting: a `<div>` or stray text directly inside a
`<table>` stays in it, where a browser moves it before the table. `.table` reads the same;
`$('table').text` includes the stray text.

**CSS** covers:
- combinators and attribute operators;
- `:nth-child(an+b)`, `:nth-of-type`, `:nth-last-of-type`, `:only-of-type`;
- `:not`, `:is`, `:where`, and jQuery's `:contains(text)` — `th:contains(Price) + td`;
- relative `:has(> img)`, `:has(+ dd)` and `:has(~ p)`;
- escapes such as `.md\:flex` and `#\31 23`.

**XPath 1.0:**
- all axes, including `following` and `preceding`; positions on reverse axes count from the
  context, so `preceding-sibling::li[1]` is the nearest sibling;
- the `+ - * div mod` operators and comparisons;
- the functions `contains`, `starts-with`, `normalize-space`, `translate`, `substring`,
  `string-length`, `count`, `sum`, `floor`, `ceiling`, `round`, `position`, `last`, `not`.

Results come back in document order. `$x` selects nodes; an expression that evaluates to a
number or string (`count(//li)`) is a `FormatException` — read `.length` instead.

```dart
final list = '<ul><li>1<li>2<li>3<li>4</ul>'.html;
list.$x('//li[position() mod 2 = 0]').texts;          // [2, 4]
list.$x('//li[3]/preceding-sibling::li[1]').texts;    // [2]
```

On an `Element`:

```dart
e.name; e.id; e.classes; e.attributes; e.attr('href'); e.attrOrNull('rel');
e.text;          // the faithful string value
e.lines;         // readable text: breaks at blocks, tabs between cells, no script/style/head
e.children; e.parent; e.nextElement;
e.markup;        // serialised; e.innerMarkup for the content
e.table;         // a <table> as a Table: repeated headers become Price_2, colspan/rowspan fill
```

On `Elements`, the singular readings answer for the first match: `text` and `attr` throw when nothing
matched (`attrOrNull` returns `null`). The plurals (`texts`, `lines`) answer for all matches. `Nodes` is what `$x`
returns, since XPath can select attributes and text nodes; `.elements` narrows it.

XML keeps case and prefixes:

```dart
final feed = await url.xml();
for (final item in feed.$('item')) {
  print(item.$('title').text);
}
feed.$x('//media:content/@url').texts;
```

A document nested 100 000 deep parses, queries and serialises without overflowing the stack.

---

## `fs`

`Path` is an extension type over `String`: it goes anywhere a path string goes and costs nothing
at runtime.

### Building and asking

```dart
final dir = Path.temp / 'my_project';
final file = dir / 'config.json';
'AIR / Farewell'.filename;   // one safe component: 'AIR _ Farewell'; '..' becomes '__'

file.name; file.stem; file.ext; file.parent; file.segments;
file.normalized; file.absolute; file.relativeTo(dir);
file.withExt('yaml'); file.sanitized;

await file.exists(); await file.size(); await file.modified();
if (await file.olderThan(1.h)) print('refresh'); // true when missing
```

`Path` cannot override `==`, so normalise paths before using them as map keys.

### Reading and writing

Every one of these has a `…Sync` twin. `fs` is the only module that has them.

```dart
await file.readText(); await file.readBytes(); await file.readLines();
file.lines();              // Stream<String>, for a file too big to hold
await file.writeText('x'); await file.append('y');
await file.copy(dir / 'b'); await file.move(dir / 'c');
await dir.delete(recursive: true);
```

`move` falls back to copy-and-delete only across filesystems. Moving onto a directory that is not
empty throws instead of merging into it.

### Listing and watching

```dart
dir.list(recursive: true);   // Stream<Path>
dir.files(recursive: true);
dir.glob('lib/**/*.dart');           // files; absolute patterns work; unreadable directories are skipped
dir.glob('{lib,test}/**/*.{dart,md}'); // either spelling
dir.globSync('img/[a-c]?.png');      // one of a set, and `[!…]` one outside it
dir.globSync('**/build/');           // a trailing `/` matches directories instead of files

await for (final batch in dir.changes(debounce: 200.ms)) {
  print('changed: $batch'); // a Set<Path> per burst
}
```

`dir.watch()` is the raw event stream, and `changes` batches it.

### Archives and compression

**Writing names the format; reading works it out.** `archiveTo` and `compressTo` take the format
from the destination's extension. `extractTo`, `archiveEntries`, `entry` and `decompressTo` sniff
the file's magic number, so a download without an extension still opens.

```dart
await dir.archiveTo('project.7z', password: 'pw'); // .zip .7z .tar .tar.gz .tar.zst .tar.xz .tar.bz2
await 'photos.rar'.path.extractTo('out');
await 'bundle.zip'.path.extractTo('docs', only: '**/*.md'); // just what matches
final readme = await 'bundle.zip'.path.entry('docs/README.md'); // Uint8List, nothing extracted

for (final e in await 'bundle.zip'.path.archiveEntries()) {
  print('${e.name} ${e.size}');
}

await 'app.log'.path.compressTo('app.log.zst'); // gzip, xz, zstd, bzip2 by extension
await 'blob.gz'.path.decompressTo('blob');
```

**An archive is untrusted by default.** Extraction:
- drops setuid, setgid and sticky bits;
- refuses a link that leads out of the destination;
- stops at 200× the archive's size, and never less than 1 GiB, before writing the excess.

`trusted: true` lifts all three for an archive you made yourself. A path that escapes the
destination is always refused. `rar` is read-only (`Archive.rar.isWritable` is false).
Everything runs off the main isolate, so there is no `extractToSync`.

---

## `hash`

Digests run in the native library, so they are fast and identical on every platform. The tests
check each algorithm against its published vectors.

`hash`, `hashBytes`, `checksum`, `hmac` and `hmacBytes` exist on `String`, `List<int>` and `Path`
alike:

```dart
'abc'.hash(Hash.sha256);
bytes.hash(Hash.blake3);
await file.hash(Hash.xxh3);                // the library reads the file: ~12 GB/s
await file.checksum(Hash.crc32);           // an int, for the 32-bit checksums
'body'.hmac(Hash.sha256, 'secret');
await file.hmac(Hash.sha512, key);         // streamed, whatever the size
'body'.hmac(Hash.blake2b, 'key');          // BLAKE2/BLAKE3 use their own keyed mode

final digests = await files.hash(Hash.xxh3); // Map<Path, String>, hashed in parallel in Rust
final twins = await dir.duplicates();        // List<List<Path>>: same size, then same xxh3
```

There are twenty algorithms:
- `md5` and `sha1`;
- SHA-2, from `sha224` to `sha512_256`;
- SHA-3 and `keccak256`;
- `blake2s`, `blake2b` and `blake3`;
- `ripemd160`;
- the checksums `crc32`, `crc32c`, `xxh64` and `xxh3`.

`Hash.isChecksum` tells the checksums apart. Asking a checksum for a MAC is an `ArgumentError`.

```dart
Secure.token(); Secure.uuid(); Secure.bytes(32);
Secure.equals(a, b);           // constant time
bytes.hex; bytes.base64; bytes.base64Url; bytes.base32;
'6869'.hexBytes;               // strict: '-1' is an error, not [255]
```

Encryption, password hashing, key agreement, signatures and JWT are deliberately absent. The
package identifies and verifies data; it does not protect it.

---

## `process`

### `run`

```dart
final res = await run('git status --short');
res.isOk; res.text; res.lines; res.exitCode; res.stdout; res.stderr;
```

By default, `run` echoes the child's output and throws `ShellException` on a non-zero exit.
**The getter you read decides otherwise.** `run(...)` is a `ShellRun`, which starts one
microtask later, so a getter chained onto it can still set the policy:

| you write | it runs with |
|---|---|
| `await run('…')` | echo, and throw on failure |
| `await run('…').text` / `.lines` | `quiet` — you wanted the output, not to watch it |
| `await run('…').isOk` | `quiet` and `strict: false` — you wanted an answer, not an exception |

```dart
final branch = await run('git rev-parse --abbrev-ref HEAD').text;
final clean = await run('git diff --quiet').isOk;
```

An explicit argument still wins.

| argument | |
|---|---|
| `input:` | written to stdin (otherwise stdin is closed at once) |
| `workdir:`, `env:`, `timeout:`, `encoding:`, `quiet:`, `strict:` | per call, or from `Shell.scope` |
| `args:` | appended as they are, never re-read; `$1`, `$2`… under `shell: true` |
| `shell: true` | the string goes unsplit to `/bin/sh -c` (`cmd /c`): pipes, globs, `&&`, `$VAR` |
| `inherit: true` | the child gets this terminal, for `git commit`, `ssh` or `vim` |

```dart
await run(r'echo $HOME | tr a-z A-Z', shell: true);
await run('git commit', inherit: true);
```

**Never interpolate an untrusted value into the command string.** Pass it in `args:`, where
nothing reads it again:

```dart
await run('git commit -m', args: [message]);
await run(r'grep -c "$1" *.log', shell: true, args: [pattern]);   // $1 under a shell
```

The string is split the way a shell reads a simple command, and nothing else: a quote that
never closes is a `FormatException`, and `|`, `&&`, `;`, `>` or `$(` outside quotes is an
`ArgumentError` naming `shell: true`, rather than a `|` handed to the program as an argument.

`.stream` is the output as it is printed, a line at a time. Leaving the loop stops the command:

```dart
await for (final line in run('tail -f app.log').stream) {
  if (line.contains('ready')) break;
}
```

**Stopping a command stops its whole tree.** A cancelled `Cancel.scope`, a `timeout` or a ^C
under `Cli.run` sends SIGTERM to the child and everything it started, then SIGKILL after 2 s. A
cancel throws `CancelledException`. A timeout throws `ShellTimeoutException`, which is a
`TimeoutException` whose `.result` holds what the command printed before it was stopped.

- Output that is not UTF-8 decodes with U+FFFD rather than failing.
- A missing executable is exit 127 and one that cannot be run is 126, as in a shell. `which`
  finds only files it could run.
- A stage of a pipeline that fails because the stage it feeds has already exited (`yes | head
  -1`) is not a failure; `shell: true` pipes are the shell's to judge.
- On Windows a program on the `PATH` runs directly; only a `.bat`, a `.cmd` or a `cmd` built-in
  goes through `cmd.exe`, and there an argument holding `& | < > ^ % "` is refused.
- Echoed output scrolls above a live spinner instead of garbling it.

### Pipelines and the scope

`|` builds a pipeline, with pipefail semantics:

```dart
final count = await ('git ls-files' | 'wc -l').run().text;
```

```dart
await Shell.scope(workdir: repo, env: {'GIT_TERMINAL_PROMPT': '0'}, timeout: 30.s, () async {
  await run('git fetch --all');
  await run('git status --short');
});
```

---

## `http`

### Requests and responses

The verbs are methods on `Uri`, which is what `.url` gives you.

```dart
await url.get(); await url.head(); await url.delete();
await url.post(json: {'name': 'x'});
await url.put(text: 'body');
await url.patch(form: {'q': 'dart'});
await url.fetch();          // a GET that throws unless 2xx: `HttpException: 404 Not Found, uri = …`
await url.json(); await url.html(); await url.xml();
url / 'users';              // append a path segment
url.withQuery({'page': 2, 'q': null});
```

A body is named for what it is: `text:`, `bytes:`, `form:`, `json:` or `files:`. `form:` together
with `files:` makes one multipart form, and the files stream off disk rather than being held in
memory.

```dart
await api.post(form: {'title': 'holiday'}, files: {'photo': 'beach.jpg'.path});
```

A `Response`:

```dart
res.statusCode; res.isOk; res.headers; res.url;   // url: the one that answered
res.text;    // BOM, then content-type's charset, then (HTML only) the <meta>; UTF-8 otherwise
res.bytes; res.json; res.html; res.xml;           // each parsed once
```

Sending consumes a `Request`. Call `req.copy()` to send the same request twice.

**A stream of events** — server-sent events, NDJSON, a log — is `events()`. `json:` makes it the
POST a streaming API asks for; breaking out of the loop closes the connection.

```dart
await for (final e in api.events(json: {'stream': true, 'prompt': 'hi'})) {
  stdout.write(e.data.json['text'].to<String>());   // e.event, e.data, e.id
}
```

A `text/event-stream` is read as a browser reads one: `data:` lines joined, `event:` defaulting
to `message`, `id:` kept until the next. Any other body is an event per non-empty line.

### The scope

No function in the module takes a `client:`. `Http.scope` names the client once, along with the
settings every request would otherwise repeat.

```dart
await Http.scope(timeout: 30.s, retries: 2, delay: 500.ms, headers: {'user-agent': 'me/1.0'}, () async {
  for (final u in urls) {
    print((await u.get()).statusCode);
  }
});
```

| argument | |
|---|---|
| `client:` | what every request inside uses; closed on the way out unless you supplied it |
| `timeout:` | bounds the wait for headers **and** for each body chunk; a late response is drained, never leaked |
| `headers:` | added to each request that does not set them; `authorization` and `cookie` only to the first request's origin |
| `cookies: true` | a jar for the life of the scope; it walks redirects hop by hop, where logins set their session |
| `retries:` | transport errors (a body cut off half-way included), 5xx, and 429/503 honouring `Retry-After` (up to 30 s); never TLS failures, and never a second POST or PATCH unless a 429/503 said when to ask again |
| `delay:` | the minimum gap between two requests to one host, redirect hops and downloads included |
| `cache:` | a folder that keeps every GET answered with an `ETag` or `Last-Modified`; the next run asks conditionally and a `304` is served from disk |

Everything the scope waits on — a backoff, a `Retry-After`, a `delay:` gap, a request in flight —
stops when the enclosing `Cancel.scope` is cancelled.

```dart
// Re-running a scraper while writing it: pages that did not change are not fetched again.
await Http.scope(cache: '.cache'.path, () => home.scrape<Row>().onResponse(parse).rights.toList());
```

Cookie dates are parsed the lenient RFC 6265 way, so PHP's `Wed, 21-Oct-2026` form works and
a `01-Jan-1970` logout cookie deletes. An empty `Domain=` is ignored rather than obeyed, and a
`Secure` cookie set over plain http is refused.

### Clients

A `Client` is two methods: `send` and `close`.

```dart
await Http.scope(client: IoClient(connections: 32, perHost: 6, proxy: proxy), () async {/* … */});
await Http.scope(client: await ChromeClient.launch(), () async {/* … */});
```

**`IoClient`** is `dart:io` with:
- the transport's own limits;
- `gzip`, plus `br` and `zstd` when the native library is loaded, decoded as the body streams;
- its own redirect walk. 303, and a non-GET 301 or 302, become a bodiless GET. 307 and 308 keep
  both method and body. Credentials stop at another origin: another host, another port, or
  `http` after `https`.

A small redirect body (up to 64 KB) is read to the end, so the connection is kept alive.

**Holding a client, you call it directly**, with no scope. This is also how you reach what only
one client can do:

```dart
final chrome = await ChromeClient.launch();
await chrome.get(url);
await chrome.html(url);
await chrome.page(url, (p) => p.click('.download')); // only Chrome has a tab
await chrome.close();
```

**`RequestKey<T>`** tells a client something HTTP has no word for. A client ignores keys it
doesn't know, which is why one crawl runs unchanged over `IoClient` and `ChromeClient`.
`Request.raw` is the one key every client must honour: *the resource, never a rendering of it*.
It also means `accept-encoding: identity`, so the stored bytes are what arrives. Every download
sets it.

To write a client of your own, implement the two methods and run `test/client_conformance.dart`
against it.

### Chrome

`ChromeClient` speaks the DevTools protocol over a websocket, with no third-party package and no
Chromium download. The page you get back is the DOM **after its own scripts have run**, so `$`,
`$x` and the crawl engine work on it unchanged.

| | |
|---|---|
| `ChromeClient.launch()` | a fresh browser, owned and killed by the client |
| `ChromeClient.launch(profile: dir)` | owned, but keeps its cookies and login between runs |
| `ChromeClient.attach(port: 9222)` | join a browser already running; never killed |
| `ChromeClient.connect()` | attach if one is up, else start one that outlives the run (`~/.dart_toolkit/chrome`) |

```dart
final chrome = await ChromeClient.launch(
  tabs: 4,                    // pages rendering at once
  block: Resource.heavy,      // images, fonts and media never fetched
  device: Device.phone,
  wait: ChromeWait.idle,
  challenge: 20.s,            // how long an interstitial may take to clear
  proxy: 'http://user:pass@host:8080'.url, // the plain client underneath too
);
```

What the client guarantees:
- **Nothing lands in your working directory.**
  - A launched browser downloads into its own temp folder.
  - A browser you attached to is pointed there only while a wait is open, then handed back.
  - Only a finished file is moved into `to:`. A download that is given up is cancelled and its
    partial file erased.
- **Credentials stay on their origin.** A scope's cookie is given to the browser for the page's
  URL only. `authorization` is added only to requests to the page's own origin, never to a CDN
  or a tracker.
- **The browser dies with the program.** On macOS and Linux, a launched Chrome runs under a
  small watchdog that stops it and erases its profile when the program ends by any means,
  including `kill -9`. You still call `close()` so the program can exit; you no longer need a
  `finally` for crash safety. Windows cleans up on `close()` only.
- **A dead browser is noticed.** `isClosed` turns true, and every call fails at once with
  `ClientException('The browser disconnected')`.
- **A page is never lost.** An expired wait, an interstitial that never clears, or a challenge
  a human must click returns the DOM as it stands. Only a navigation Chrome refuses outright
  (DNS, connection refused) throws.
- **Fewer background bytes.** A launched browser disables component updates and the
  optimisation-guide downloads, so a fresh profile no longer fetches about 40 MB in its first
  minute. Your own `--disable-features=` is merged with the built-in list.

`isNewBrowser` says whether this run started the browser, i.e. whether `proxy:`, `headless:`
and `args:` applied at all.

Per request, with keys:

```dart
url.scrape<String>().onRequest((ctx) {
  ctx.request[ChromeClient.waitFor] = '.results .item';
  ctx.request[ChromeClient.script] = 'window.scrollTo(0, document.body.scrollHeight)';
  ctx.request[ChromeClient.block] = Resource.heavy;
});
```

Only a GET without a `range` is rendered. POSTs, resumable downloads and assets go to the plain
client underneath, with the browser's cookies and user-agent.

### Driving a page

```dart
final page = await chrome.open(loginUrl);
await page.fill('#user', 'me');
await page.waitForNavigation(() => page.click('button[type=submit]'));
await page.waitFor('.dashboard');                 // false on timeout, never a throw
print((await page.html()).$('.balance').text);
await page.close();
```

**A wait takes the action it waits for**, because a fast page finishes before the next line
runs:

```dart
await page.waitForNavigation(() => page.click('a.next'));
final file = await page.waitForDownload(() => page.click('.download'), to: 'books'.path);
final api = await page.waitForResponse('/api/items', () => page.click('.more'));
print(api!.json['items']); // the JSON behind the page, not the DOM
```

`waitForDownload`'s `timeout` is how long the transfer may go *quiet*. A slow download is
waited out; one that has stopped reporting progress is given up. `waitForResponse` rethrows an
exception from `action`.

| | |
|---|---|
| `goto(url)`, `back()`, `forward()`, `reload()` | navigation |
| `html()`, `response()`, `url`, `statusCode` | what the tab holds right now |
| `waitFor(sel)`, `waitWhile(sel)` | a mutation observer; `false` on timeout |
| `click`, `fill`, `press`, `select`, `hover`, `upload` | real input events, with a DOM fallback |
| `text(sel)`, `attr(sel, name)`, `has(sel)` | one value off the live page |
| `frame(match)` | an iframe as a page of its own |
| `scroll(times:, settle:)` | an infinite feed until it stops growing |
| `eval(js)`, `screenshot()`, `pdf()` | anything else |
| `cookies([restore])`, `headers(map)`, `block(kinds)` | the tab's session and filters |
| `onDialog(handler)` | answer `alert`/`confirm`/`prompt`; unanswered ones are dismissed |

### Crawling

The short form is a chain of five hooks, and the result is a stream of `Either`s:

```dart
final stories = 'https://news.ycombinator.com'.url
    .scrape<({String title, Uri link})>()
    .onInit((ctx) => ctx..concurrency = 8..delay = 200.ms..pages = 50..robots = true)
    .onRequest((ctx) => ctx.request.headers['accept-language'] = 'en')
    .onResponse((ctx) {
      for (final a in ctx.response.html.$('.titleline > a')) {
        ctx.emit((title: a.text, link: ctx.resolve(a.attr('href'))));
      }
      ctx.follow(ctx.response.html.$('a.morelink'));
    })
    .onError((ctx) => Console.warn('${ctx.failure}'))
    .onFinish((summary) => Console.info('$summary'));

await Http.scope(() => stories.rights.forEach(print));
```

**The full form is a class** with the same five hooks as methods. Its state lives in fields, and
it can be built in a test:

```dart
final class Titles extends Crawler<String> {
  final Uri home;
  final seen = <String>{};
  Titles(this.home);

  @override
  void onInit(InitContext<String> ctx) => ctx..seed(home)..sitemaps = true..robots = true;

  @override
  void onResponse(ResponseContext<String> ctx) {
    for (final h in ctx.response.html.$('h1, h2')) {
      if (seen.add(h.text)) ctx.emit(h.text);
    }
  }

  @override
  void onError(ErrorContext<String> ctx) => ctx.ignore();
}

Future<List<String>> titles(Uri home) => Http.scope(() => Titles(home).run().rights.toList());
```

Seeds: `url.scrape<T>()`, `urls.scrape<T>()`, `requests.scrape<T>()`, `ctx.seed(url)` in
`onInit`, or `client.scrape<T>(seeds)` on a client you hold — a `Uri`, `Uri`s or `Request`s.

**`onInit`** runs once, and may be async.

| setting | default | |
|---|---|---|
| `concurrency` | 16 | requests in flight overall |
| `perHost` | 8 | requests in flight to one host |
| `delay` | 0 | minimum gap between two requests to one host |
| `timeout` | 30 s | headers, and each body chunk |
| `retries` | 2 | transport errors and 5xx; never TLS |
| `redirects` | 5 | hops before a request fails |
| `bodyLimit` | 16 MB | bytes read before a response is abandoned |
| `pages` / `depth` | — | stop after N pages / drop requests deeper than N hops |
| `scope` | the seeds' hosts | where `follow` may go |
| `robots` | false | fetch each host's robots.txt once and obey it, for the user-agent actually sent |
| `sitemaps` | false | seed from the sitemaps robots.txt lists, or `/sitemap.xml`; indexes and `.gz` followed |

**`onRequest`** runs before every send. `ctx.request` is yours to edit, and `ctx.skip()` drops
the request.

**`onResponse`** runs on every 2xx. `ctx.url` is the URL that *answered*, after redirects,
Chrome's included. From here you can:

```dart
ctx.emit(item);
ctx.follow(href, meta: {'from': 'index'}, onResponse: (child) {/* … */});
ctx.follow(ctx.response.html.$('a.next')); // elements: each one's href, else its src
ctx.resolve(href); // against the URL that answered
ctx.stop();
```

What `follow` does:
- It stays on the seeds' hosts, with or without `www.`.
- It strips fragments and an empty `?`, and never fetches a URL twice (a multipart body counts
  its files). A redirect back into its own chain — a login setting a cookie — is followed.
- It takes elements too: each one's `href`, else its `src`; one with neither is a drop.
- It drops `mailto:` and `javascript:` links.
- It returns `false` when it drops something, so nothing vanishes silently.
- It takes the same body words as `post`.

**`onError`** runs when the engine has given up on a request:

```dart
url.scrape<String>().onError((ctx) => switch (ctx.failure) {
  StatusFailed(:final response) when response.statusCode == 404 => ctx.ignore(),
  RequestFailed() => ctx.retry(after: 2.s),
  _ => null, // stays a Left
});
```

**`onFinish`** runs once, with a `ScrapeSummary`: pages, failures, requests, retries, drops,
bytes and time.

After `stop()`, a request that fails in flight is not reported, but a hook that throws still is.
Under `Cli.run`, ^C cancels the crawl through `ctx.cancel`.

### Downloads

Downloads are atomic: bytes go to a `.part` file, which is renamed on success after
`Content-Length` is checked. They are resumable: the next download of the same path continues
with a `Range` request — and an `If-Range` carrying the first answer's `ETag` or `Last-Modified`
(kept beside the part as `.part.if-range`), so a file that changed in between comes back whole
rather than as the old head and the new tail. One file and many use the same word and render
the same way:

```dart
await 'sdk.zip'.path.download(url).show();
await {url: 'a.bin'.path}.download(concurrency: 4).show();
await pairs.download(concurrency: 8).show();   // Iterable<({Uri url, Path path})>
await found.download(concurrency: 8).show();   // Stream<…>: discovery and transfer overlap
```

`checksum:` verifies the bytes, and a mismatch deletes the `.part`. `ifModified:` turns a re-run
into a `304` check. Downloads stop on the enclosing `Cancel.scope` — even mid-body on a server
that has stalled — and each one in flight reports a `DownloadFailed` holding the
`CancelledException`. `Http.scope(retries:, delay:)` applies to them; a transfer cut off
half-way carries on from the byte it stopped at. Two pairs naming one destination are one
download and one `DownloadSkipped`.

```dart
await 'sdk.zip'.path.download(url, checksum: (Hash.sha256, '9f86d0…')).show();
```

Consuming the progress by hand:

```dart
await for (final p in {url: 'a.bin'.path}.download()) {
  switch (p.current) {
    case Downloading(:final ratio): print(ratio);
    case Downloaded(:final bytes): print('$bytes B');
    case DownloadSkipped(): print('already there');
    case DownloadFailed(:final error): print(error);
  }
}
```

---

## `cli`

### Options and arguments are values

An option's name is written once, and its type is the type you read back.

```dart
enum Stage { dev, staging, production }

final stage = Opt.among('stage', Stage.values, abbr: 's').or(Stage.production); // Stage
final token = Opt.text('token').env('DEPLOY_TOKEN').required();              // String
final workers = Opt.number('workers', abbr: 'w').or(4);                      // int
final dryRun = Opt.flag('dry-run', abbr: 'd');                               // bool
final headers = Opt.text('header', abbr: 'H').many();                        // List<String>
final since = Opt.by('since', DateTime.parse);                               // DateTime?

final id = Arg.text('id').required();          // String
final count = Arg.number('count').or(1);       // int
final targets = Arg.text('targets').many().required(); // List<String>, at least one
final files = Arg.by('files', Path.new).many();          // List<Path>, parsed one by one
```

| modifier | |
|---|---|
| `.or(v)` | a default; `ctx(…)` is then non-nullable |
| `.required()` | omitting it is a usage error |
| `.many()` | `-H a -H b` gives `['a', 'b']`; without it the last occurrence wins. On an `Arg`, everything left, declared last |
| `.env('NAME')` | falls back to the environment, satisfies `required()`, and shows `[env: NAME]` in help |

Flags accept `--dry-run`, `--no-dry-run` and `--dry-run=true|false|yes|no|1|0`. Short flags
combine (`-dv`), and a value can attach (`-w8`, `-w=8`). `-5` is a positional unless an option
answers to `-5`.

### Commands

```dart
final cli = Cli(
  name: 'deployer',
  version: '1.2.0',
  values: [id, stage, token, workers, dryRun], // Args bind in the order they are listed
  handler: (ctx) => Console.info('deploying ${ctx(id)} to ${ctx(stage).name}'),
  commands: [
    CliCommand('db', description: 'Database', commands: [
      CliCommand('migrate', description: 'Run migrations', handler: (ctx) {}),
    ]),
  ],
);
```

Every `Cli` also answers these, unless it declares the name itself:

| built-in | |
|---|---|
| `-h, --help` | usage built from what the command holds — `--top <int>`, `--mode <fast\|slow>` say what each option takes — and a subcommand lists its "Global options" |
| `--version` | when `version:` is set |
| `-v, --verbose` / `-q, --quiet` | `Console.level` to debug / warn, before the handler runs |
| `--completion bash\|zsh\|fish` | a completion script from the declared tree |

```sh
source <(dart run dart_toolkit:tk --completion bash)   # or add it to ~/.bashrc
```

**How a run ends:**

| exit code | |
|---|---|
| 0 | the handler returned |
| 1 | the handler threw: one red `✖ error` line, with the trace under `--verbose` |
| 64 | a usage error, including an unknown subcommand or option, which says `Did you mean "build"?`; and a program of subcommands run with none, whose usage goes to stderr |
| 128+n | a signal; the exit hooks ran |

`Cli.run` opens the `Cancel.scope` whose token is `ctx.cancel`. So ^C stops downloads,
processes, pools and crawls with no code of yours.

### Lifecycle

Two names: `onExit` registers a listener, and `exit` fires it.

```dart
final release = Lifecycle.onExit(() => print('cleaning up')); // returns its removal
release();
await Lifecycle.exit('no URL given'); // red on stderr, exit 1
```

Listeners run on SIGINT, SIGTERM, `Lifecycle.exit` and the end of `Cli.run`, in order. A
second ^C while a listener hangs quits at once. A script without a `Cli` must end with
`Lifecycle.exit()` or `Lifecycle.onExit(null)`, because the signal watch keeps the isolate
alive.

### Console

One namespace for everything written to the terminal, over one live region. A log line written
during a spinner scrolls above it instead of landing on top of it.

```dart
final spinner = Console.spinner('Connecting');
Console.info('resolved 3 hosts');
spinner.succeed('connected');

final result = await Console.spin('Building', () => run('make'), done: 'Built');
```

| | |
|---|---|
| `debug/info/ok/warn/error(msg)` | `· ℹ ✓ ⚠ ✖`; `warn` and `error` go to stderr; any object, written as its `toString()` |
| `Console.level`, `Console.silenced(action)` | the floor; mute one action |
| `Console.stages(n)` | a `[1/n]` banner |
| `Console.spin(msg, action)` | a spinner ended for you when `action` settles |
| `Console.progress(total)` | one bar: `tick([n])`, `done()` |
| `Console.tasks()` / `stream.show()` | a board with a row per task running at once; `slots:` fixes the count |
| `Console.rule([title])`, `Console.writeln`, `Console.clear()` | unlevelled |

Under `-q` a spinner, a bar and a board draw nothing, and only a failure's final line is
written.

**Prompts are async**, so ^C at a prompt ends the program cleanly and turns echo back on. They
write to stderr, so `app > out.txt` captures the output and none of the questions; `confirm`
asks again on anything that is not a yes or a no:

```dart
final name = await Console.ask('Project name', or: 'app', validate: (v) => v.contains(' ') ? 'no spaces' : null);
final go = await Console.confirm('Continue?', or: true);
final password = await Console.secret('Password');
final stage = await Console.select('Stage', Stage.values, or: Stage.dev, display: (s) => s.name);
```

Without a terminal every indicator degrades to plain lines. Styling is on `String`: `.bold`,
`.red`, `.green`, `.dim`, and so on.

---

## `native`

`native/` is one Rust `cdylib`, `dart_toolkit_native`. It holds digests, MACs, archive formats,
content-encoding decoders and the WHATWG charsets, and nothing else.

```dart
NativeLib.isAvailable; // whether it loaded
NativeLib.reason;      // why not
NativeLib.version;     // the ABI version (2)
```

It is looked for at `DART_TOOLKIT_NATIVE` (a path), then beside the executable, then at
`native/prebuilt/<os>_<arch>/`. Without it, those calls throw `UnsupportedError` naming what
they needed, and `IoClient` asks only for gzip. There is deliberately no Dart fallback.

| platform | prebuilt |
|---|---|
| macOS arm64, macOS x64 | yes (`@rpath` install name) |
| Linux x64, Linux arm64 | yes (glibc 2.30+) |
| Windows | no: unrar needs an MSVC toolchain. Build it with `cargo-xwin` or on Windows |

`make native` builds for this machine. `make native RUST_TARGET=x86_64-unknown-linux-gnu`
cross-builds with `cargo-zigbuild`. `NativeBridge` is internal plumbing and not covered by the
versioning promise.

---

## `ffi`

Call a C function in one line, with no codegen and no hand-written `lookupFunction<N, D>`.

```dart
import 'dart:typed_data';

import 'package:dart_toolkit/ffi.dart';

Future<void> main() async {
  final libc = Ffi.open('c');                 // libc.dylib / libc.so.6 / ucrtbase.dll
  final strlen = libc.fn('strlen', C.i64);    // looked up once
  print(strlen('hello'));                     // 5
  print(libc.call('getenv', C.str, 'HOME'));  // String?
  print(libc.call('pow', C.f64, 2.0, 10.0));  // 1024.0
  print(libc.call('ldexp', C.f64, 1.0, 10));  // 1024.0: integers and doubles mix
  print(libc.call('atof', C.f64, '2.5'));     // 2.5
  print(libc.call('sqrtf', C.f32, C.f32(2.0))); // 1.414…: a float is written as one

  final name = Uint8List(256);                // a typed list is copied in and back out
  libc.call('gethostname', C.i32, name, name.length);
  libc.fn('snprintf', C.i32, fixed: 3)(name, 256, '%d %s %.1f', 42, 'hi', 0.5); // variadic

  if (libc.call('chdir', C.i32, '/nope') < 0) print(Ffi.errno); // 2, ENOENT

  final data = Int32List.fromList([5, -3, 9]);
  Ffi.scope((s) => libc.call('qsort', C.none, data, data.length, 4,
      s.callback((int a, int b) => C.i32.at(a) - C.i32.at(b))));
  print(data); // [-3, 5, 9]

  final buf = libc.own(libc.call('malloc', C.ptr, 1024), 'free', size: 1024); // freed on GC, or:
  buf.close();

  await libc.fn('usleep', C.i32).async(300000); // on another isolate; this one keeps running
}
```

**It lives in its own namespace.** `package:dart_toolkit/ffi.dart` is not exported from the
barrel. Its names are short on purpose, and short names belong only to programs that asked for
them. None of them is a `dart:ffi` name, so it imports beside `dart:ffi` with no `hide`.

| | |
|---|---|
| `Ffi.open(name)` | `'c'`, `'m'`, `'sqlite3'`, `'z'`, a file name or a path. It searches the script's directory, the system, and Homebrew's paths, finds `lib<name>.so.N` on Linux, and names every candidate when nothing is found |
| `lib.fn(name, C.x)` | a `Fn<T>`; a missing symbol fails here, not at the call. `fixed: n` for a variadic function |
| `lib.call(name, C.x, …)` | a one-off call; the lookup is cached |
| `lib.has(name)`, `lib.path` | |
| `lib.own(ptr, 'free', size: n)` | an `Owned`, freed by a `NativeFinalizer` or `close()`; `size` tells the GC how much it holds |
| `fn(…)`, `fn.async(…)` | up to 8 arguments; `async` runs on a helper isolate, kept for the next call |
| `Ffi.scope((s) => …)` | an arena: `s.alloc(n)`, `s.text(str)`, `s.bytes(list)`, `s.out(C.x)`, `s.callback(f)`; async bodies free when the future completes |
| `Ffi.callback(f)` | a `Callback` of 0–4 int arguments you `close()` yourself |
| `Ffi.errno` | this thread's `errno`, as the last call left it |

**Keys.** `C.none`, `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `bool`, `ptr`, `str`, `f64`
and `f32` each name a C type. `size_t`, `uint64_t` and `intptr_t` are all `C.i64`. A key does
four things:

| | |
|---|---|
| `libc.fn('abs', C.i32)` | as a return, it narrows what the register held |
| `C.i32(a)`, `C.f32(1.5)` | called, it is a value as that type holds it: `C.i8(255)` is `-1`, a callback's zero-extended `int` reads `C.i32(a)`, and `C.f32(x)` is a `float` argument |
| `C.i32.at(address)` | reads one out of memory |
| `C.u8.list(ptr, n)` | views `n` of them where they lie, as a typed list |

**Out-parameters and structs:**

```dart
Ffi.scope((s) {
  final end = s.out(C.ptr);                              // char **endptr
  libc.call('strtol', C.i64, s.text('42 rest'), end, 10); // 42
  print(String.fromCharCodes(C.u8.list(end.value, 5)));  // " rest"

  final sec = C.i64.field, nsec = C.i64.field;           // each member named once
  final timespec = C.struct([sec, nsec]);                // offsets and padding as C lays them out
  final ts = s.alloc(timespec.size);
  libc.call('clock_gettime', C.i32, 0, ts);
  print('${sec[ts]}.${nsec[ts]}');
});
```

A per-call `String` is freed when the call returns, so a pointer C keeps into it — `strtol`'s
`endptr` — needs `s.text` instead.

**Arguments:**
- `int`, `bool`, `null` (a null pointer), `Pointer`, `Out`, `Owned` and `Callback`.
- A `String` becomes a UTF-8 `char*` for the duration of the call.
- Any typed list is copied in and copied back out; an unmodifiable one goes in only.
- A `double` is a `double` and `C.f32(x)` a `float`. An `int` is always an integer, so
  `pow(2, 10)` is wrong: write `pow(2.0, 10.0)`.

**How it works:** on the 64-bit ABIs Dart runs on, arguments travel in slots the caller owns,
and a callee ignores the slots it doesn't declare; Go's `syscall.Syscall6` uses the same trick.
SysV x64 and AAPCS64 fill the integer and floating-point registers independently, so one
signature, `(Int64 × 8, Double × 8)`, calls any mix of up to eight. Win64 assigns registers by
position, so there a call is all integers or all doubles, up to six. A `float` is the low half
of a `double` register. A variadic function goes through a `VarArgs` signature for its fixed
count, so the caller does what the platform's `...` expects: the stack on Apple arm64, `al` on
SysV x64. The return is the one thing the callee leaves partly undefined, which is why it is
named by a typed key.

**Not supported:** structs by value, more than eight arguments, a variadic function returning
a `double`, callbacks taking doubles or called from a thread C started, a mix of integers and
doubles on Windows, and 32-bit platforms. These are refused with an `ArgumentError` rather than
passed wrongly. The one mistake it cannot catch is a variadic function called without `fixed:`,
which reads garbage. Use plain `lookupFunction` for the rest; it works alongside `ffi.dart`.

**Cost** (AOT, Apple M-series), against about 8 ns for a typed `lookupFunction`:

| call | ns |
|---|---|
| `abs(int)` | 12 |
| `sqrt(double)` | 15 |
| `strlen(String)`, including the allocation | 66 |
| `ldexp(double, int)`, through the mixed shape | 49 |
| `memset(Uint8List)`, copied in and out | 230 |
| `fn.async(…)`, after the first | 4 000 |

---

## Cookbook

### Public-domain books, two ways

This is `bin/books.dart`: search Standard Ebooks, then download either with plain HTTP (all at
once) or by clicking in Chrome. Only the browser follows the site's meta-refresh download page.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

final site = 'https://standardebooks.org'.url;

Future<({Uri page, String file})> find(String title) async {
  final results = await (site / 'ebooks').replace(queryParameters: {'query': title}).html();
  final about = results.$('li[typeof="schema:Book"]').attrOrNull('about');
  if (about == null) throw 'no book matches "$title"';
  final page = site.resolve('$about/');
  final epub = (await page.html()).$('a.epub').attr('href').split('/').last;
  return (page: page, file: epub);
}

Future<void> main() => Http.scope(retries: 2, delay: 1.s, () async {
  final found = await ['frankenstein', 'dracula'].parallelize(find).rights;
  await {
    for (final (:page, :file) in found)
      page.resolve('downloads/$file').replace(query: 'source=download'): 'books'.path / file,
  }.download().show(message: 'Downloading');
});
```

The browser route, for one book:

```dart
Future<void> click(({Uri page, String file}) book) async {
  final chrome = await ChromeClient.launch();
  try {
    final tab = await chrome.open(book.page);
    final saved = await tab.waitForDownload(() => tab.click('a[href\$="${book.file}"]'), to: 'books'.path);
    Console.ok(saved == null ? 'never started' : 'saved ${saved.name}');
  } finally {
    await chrome.close();
  }
}
```

### Scrape a paginated listing into a CSV

```dart
Future<void> listing() async {
  final rows = await Http.scope(
    () => 'https://example.com/list'.url
        .scrape<Map<String, Object?>>()
        .onInit((c) => c..concurrency = 8..delay = 200.ms..robots = true)
        .onResponse((c) {
          for (final tr in c.response.html.$('table tbody tr')) {
            final td = tr.$('td').texts;
            c.emit({'name': td[0], 'size': td[1]});
          }
          c.follow(c.response.html.$('a.next'));
        })
        .rights
        .toList(),
  );
  await Table.rows(rows).orderBy('name').save('listing.csv');
}
```

### A whole site, from its sitemap

```dart
Future<void> site() async {
  final pages = 'https://example.com'.url
      .scrape<String>()
      .onInit((ctx) => ctx..sitemaps = true..robots = true..concurrency = 4)
      .onResponse((ctx) => ctx.emit('${ctx.url} ${ctx.response.html.$('title').text}'));
  await Http.scope(() => pages.rights.forEach(print));
}
```

### Log in once by hand, then crawl as that user

```dart
Future<void> asMe(Uri loginUrl, Uri listUrl) async {
  final chrome = await ChromeClient.launch(profile: Path.home / '.my_tool', headless: false);
  final page = await chrome.open(loginUrl);
  if (!await page.has('.dashboard')) {
    Console.info('Log in in the browser window; waiting…');
    await page.waitFor('.dashboard', timeout: 5.m);
  }
  await page.close();

  await Http.scope(client: chrome, () async {
    await listUrl.scrape<String>().onResponse((c) => c.emit(c.response.html.$('h1').text)).rights.forEach(print);
  });
  await chrome.close(); // the profile keeps the login for next time
}
```

### Read the API behind a page instead of its DOM

```dart
Future<void> search(ChromeClient chrome, Uri searchUrl) => chrome.page(searchUrl, (page) async {
  final res = await page.waitForResponse('/api/search', () async {
    await page.fill('#q', 'dart');
    await page.press('Enter');
  });
  for (final hit in res!.json['hits'].list) {
    print(hit['title'].to<String>());
  }
});
```

### A rendered crawl that downloads at socket speed

```dart
Future<void> gallery(Uri url) async {
  final chrome = await ChromeClient.launch(tabs: 4, block: Resource.heavy);
  await Http.scope(client: chrome, () async {
    final images = url
        .scrape<({Uri url, Path path})>()
        .onRequest((c) => c.request[ChromeClient.waitFor] = '.gallery img')
        .onResponse((c) {
          for (final img in c.response.html.$('.gallery img[src]')) {
            final src = c.resolve(img.attr('src'));
            c.emit((url: src, path: 'out'.path / src.pathSegments.last.filename));
          }
        })
        .rights;
    await images.download(concurrency: 8).show(message: 'Downloading');
  });
  await chrome.close();
}
```

The pages render in Chrome, while the images go straight down a socket, because every download
sets `Request.raw`.

### Hash a tree, find duplicates

```dart
Future<void> audit(Path dir) async {
  final files = await dir.files(recursive: true).toList();
  (await files.hash(Hash.blake3)).forEach((file, digest) => print('$digest  $file'));
  for (final group in await dir.duplicates()) {
    Console.warn('same bytes: ${group.join(', ')}');
  }
}
```

### A stateful worker pool

```dart
final class LineCount extends Worker<Path, (Path, int)> {
  @override
  Future<(Path, int)> run(Path file) async => (file, (await file.readLines()).length);
}

Future<void> count(Stream<Path> files) async {
  final pool = await Pool.spawn(LineCount.new, size: 4);
  await for (final (file, n) in pool.map(files).rights) {
    print('$n\t$file');
  }
  await pool.close();
}
```

### Shell commands with one policy

```dart
Future<void> release(Path repo) => Shell.scope(workdir: repo, () async {
  if (!await run('git diff --quiet').isOk) await Lifecycle.exit('working tree is dirty');
  await run('dart analyze');
  await run('dart test');
  final tag = 'v${(await 'pubspec.yaml'.path.readText()).yaml['version'].to<String>()}';
  await run('git tag', args: [tag]);
});
```

### Rebuild on change

```dart
Future<void> watchSrc() async {
  await for (final changed in 'lib'.path.changes(debounce: 300.ms)) {
    if (changed.any((p) => p.ext == 'dart')) {
      await Console.spin('Analyzing', () => run('dart analyze').isOk);
    }
  }
}
```

### Call SQLite directly

```dart
import 'package:dart_toolkit/ffi.dart';

void main() {
  final sqlite = Ffi.open('sqlite3');
  print(sqlite.call('sqlite3_libversion', C.str)); // e.g. 3.43.2
}
```

---

## Testing

Nothing in `lib/` exists for tests. The two seams that make a program testable are `Io` and
`Client`.

```dart
import 'package:dart_toolkit/dart_toolkit.dart';
import 'package:test/test.dart';

import 'mock_client.dart'; // test/mock_client.dart in this repository

void main() {
  test('prints and fetches', () async {
    final buffer = StringBuffer();
    Io.out = buffer;
    Console.ok('captured');
    Io.reset();
    expect(buffer.toString(), contains('captured'));

    final client = MockClient((req) async => Response('{"ok": true}', 200));
    final doc = await Http.scope(client: client, () => 'https://x.test'.url.json());
    expect(doc['ok'].to<bool>(), isTrue);
  });

  test('answers prompts', () async {
    final answers = ['app', 'y'].iterator;
    Io.input = () => answers.moveNext() ? answers.current : null;
    expect(await Console.ask('Name'), 'app');
    expect(await Console.confirm('Go?'), isTrue);
  });
}
```

- A crawl is testable by building its `Crawler` subclass directly.
- A `Worker` is testable by calling `run` on an instance, no pool needed.
- A client of your own is checked with `clientConformance('MyClient', (base) => MyClient())`
  from `test/client_conformance.dart`.

`make` runs analyze, the format check and the tests. `make bench` prints the per-module startup
cost.

---

## Performance notes

All numbers were measured back to back on an Apple M-series machine, alternating old and new
code.

| | 0.0.5 | 0.0.6 |
|---|---|---|
| `parallelize(isolate: true)`, 400 × 50k ints | 20.9 s | ~70 ms |
| `Pool`, 2000 tiny items | 33 ms per-item isolates | 12 ms |
| `file.hash(xxh3)`, 1 GiB | ~530 ms | ~110 ms |
| `file.hash(blake3)`, 1 GiB | ~1 s | ~110 ms (all cores) |
| `paths.hash`, 49.5k files | 9.3 s one at a time | 1.0 s |
| `Table.csv`, 45 MB / 1M rows | 1.3–2.5 s | 0.43–0.63 s |
| `glob('**/*.dart')`, 49.5k files | 3.3–4.1 s | 1.0–1.9 s |
| `Secure.bytes(1 MiB)` | 112 ms | 25 ms |
| XPath `//article[.//img]`, 2 MB page | 95 ms | 4 ms |
| XPath `(//a)[1]` | 53 ms | 3 ms |
| HTML `markup`, 2 MB page | 46 ms | 21 ms |
| YAML parse, 2.5 MB | 131 ms | 61 ms |
| XML with 40k bare `&` | 12.3 s | 1.3 ms |
| redirect chain, 5 GETs × 3 hops | 11 TCP connections | 1 |

The rules behind the numbers:
- **Nothing third-party at runtime but `path`.** `package:html`, `xml`, `archive` and `http`
  together would cost about a second of compile time on every `dart run`.
- **You pay for what you import.** `dart:ffi` costs nothing to a program that touches none of
  `fs`, `hash` and `http`. Opening the native library is lazy and costs about 12 ms.
- **Files stream.** Hashing, downloading, archiving and uploads name the file, not its bytes.
- **Block what you don't read.** `ChromeClient.launch(block: Resource.heavy)` is the biggest win
  available to a rendered crawl.
- **Native assets were measured and rejected:** +50–65 ms on every `dart run`.
- **Measure back to back.** Startup drifts ±80 ms between runs, so `make bench` alternates.

---

## Troubleshooting

**`UnsupportedError: … needs dart_toolkit_native`.** The library did not load, and
`NativeLib.reason` says why. On Windows there is no prebuilt: build it with `cargo-xwin` or on a
Windows machine, then set `DART_TOOLKIT_NATIVE` to the file. From a checkout, `make native`.

**`@Native` says "abstract class" under the barrel import.** That was 0.0.5's `Native` class. It
is `NativeLib` now; upgrade.

**A script finishes but does not exit.** Either the signal watch is keeping the isolate alive
(end with `Lifecycle.exit()`, or put the work in a `Cli`), or a `ChromeClient` is still open
(call `close()`).

**`StateError: cancellable outside a Cancel.scope`.** `.cancellable` refuses to be a wrapper that
does nothing. Open a `Cancel.scope`, or let `Cli.run` open one.

**`StateError: $.x is null, expected int`.** `to<T>()` no longer returns null. Use
`toOrNull<T>()` where absence is expected.

**A multi-document YAML file reads as only its first document.** It does now, by design. Use
`.yaml.documents` for the whole stream.

**A crawl finds nothing on a page you can see in a browser.** The content is built by the page's
own scripts. Put a `ChromeClient` in the scope, and wait with `ChromeClient.waitFor`.

**A downloaded file is HTML instead of the file.** The site answers with an interstitial page,
which Standard Ebooks does with a meta refresh. Either request the URL it refreshes to, or click
through in Chrome with `waitForDownload`.

**`extractTo` refuses an archive, saying it is too large.** It would expand beyond 200× its size.
If you trust it, pass `trusted: true`.

**Shell completion does nothing.** Load the script in your shell's startup file:
- bash: `source <(app --completion bash)`
- zsh: the same line, after `autoload -U bashcompinit && bashcompinit`
- fish: `app --completion fish | source`

**Tables or progress bars misalign with non-ASCII text.** They measure with `Io.width`, which
counts terminal columns. Do the same if you format by hand.
