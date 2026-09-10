# Pure helpers (`util.*`)

Delays and timestamps (`util.time`), byte sizes (`util.size`), text handling
(`util.text`), hashing (`util.hash`) and randomness (`util.rand`) — plus
[`Sequence`](#6-sequences-sequencet), the sequence API this library returns in
place of Dart's, and [`Json`](json.md), the cursor `format.json`, `format.yaml` and
`Reply.at` all hand back.

Nothing here touches the disk or the operating system — that is the rule that
decides what belongs. Archives are [`format.zip`](zip.md), Git is
[`format.zip`](zip.md), and the terminal is [`system.console`](console.md).

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final clock = util.time.clock();

  await util.time.wait(250.ms);

  system.console.logger.ok('Took ${util.time.format(clock.elapsed)}');
  system.console.logger.info('Slug: ${util.text.slug('Hello World')}');
}
```

---

## 1. Time (`util.time`)

### Delays

Delays are always a `Duration`. The `int` extensions keep that short:

```dart
await util.time.wait(250.ms);
await util.time.wait(2.s);
await util.time.wait(5.m);
await util.time.wait(const Duration(hours: 1));
```

`250.ms`, `2.s` and `5.m` are plain `Duration` values, usable anywhere one is accepted:

```dart
net.crawl<String>(url).delay(500.ms);
Fetcher(timeout: 10.s);
```

### Measuring

```dart
final clock = util.time.clock();   // a started Stopwatch
// ...
clock.stop();
util.time.format(clock.elapsed);   // '02:15' or '01:02:15' past an hour
```

### Timestamps

```dart
util.time.stamp();     // '20260907_181500' — filename-safe
util.time.iso();       // '2026-09-07T18:15:00.000Z'
util.time.epoch();     // milliseconds since the Unix epoch
```

Each takes an optional `DateTime`, defaulting to now:

```dart
final name = 'backup_${util.time.stamp()}.zip';
```

### Relative descriptions

```dart
util.time.ago(publishedAt);              // 'just now', '5m ago', '3d ago'
util.time.ago(publishedAt, referenceAt); // relative to a given instant
```

Future instants report `'in the future'`.

---

### Reading, the other direction

`stamp`, `iso`, `format` and `ago` all go `DateTime` → `String`. These two come
back, and both are nullable, so a bad cell is a `null` to handle rather than a
`try` to write:

```dart
util.time.parse('2024-03-09T10:15:00Z');   // ISO first
util.time.parse('2024-03-09 10:15');       // ISO with a space
util.time.parse('20240309_101500');        // what `stamp` writes
util.time.parse('2024/03/09');             // year first: four digits can only be a year
util.time.parse('09/03/2024');             // day first — see below
util.time.parse('9 Mar 2024');             // English month names, long or short
util.time.parse('whenever');               // null
```

A slashed or dotted date whose first group is two digits is read **day first**:
`09/03/2024` is the ninth of March. Month-first is ambiguous with it and only
one of the two can win, so the reader picks the international order and says so
rather than guessing per value.

`span` reads the units a timeout is written in, as many at once as you like:

```dart
util.time.span('250ms');    // 250.ms
util.time.span('30s');      // 30.s
util.time.span('1h30m');    // 90.m
util.time.span('2d 12h');   // 60.h
util.time.span('1.5h');     // 90.m
util.time.span('30');       // 30.s — a bare number means seconds
util.time.span('soon');     // null
```

`day` truncates to midnight, keeping the UTC or local flag. It is the grouping
primitive a reporting script reaches for, and `dart:core` has no one-liner for
it:

```dart
rows.group((r) => util.time.day(r.at));   // Map<DateTime, Sequence<Row>>
```

The `int` extensions cover the whole ladder: `250.ms`, `30.s`, `5.m`, `2.h`,
`3.d`.

---

## 2. Byte Sizes (`util.size`)

```dart
util.size.format(5242880);            // '5.0 MB'
util.size.format(1024, decimals: 2);  // '1.00 KB'
util.size.parse('2.5 MB');            // 2621440
util.size.parse('10KB');              // 10240
```

`format` renders zero and negative inputs as `'0 B'`. `parse` accepts both `KB` and `K` style units, treats a bare number as bytes, and returns `0` for anything it cannot read — a unit nobody knows is refused rather than read as bytes. Every unit `format` writes, up to `PB`, reads back, so `parse(format(n))` is `n` rounded to the digits it printed.

```dart
system.console.logger.info('Wrote ${util.size.format(io.stat(path).size)}');
```

---

---

## 3. Text (`util.text`)

Slugs, cleaning, truncation, and pulling values out of raw text.

```dart
util.text.slug('Héllo, World!');        // 'hello-world'
util.text.clean('  a   b\n c ');        // 'a b c'
util.text.strip('<p>Hi <b>there</b>');  // 'Hi there'
util.text.clip('a long sentence', 10);  // 'a long se…'
util.text.title('hELLO there');         // 'Hello There'
util.text.upper('hello');               // 'Hello'
util.text.words('one two-three');       // Sequence('one', 'two', 'three')
util.text.blank('  \n ');               // true
util.text.fold('déjà');                 // 'deja'
```

`number` and `numbers` ignore currency symbols and digit grouping, which is
what scraped prices and counts look like:

```dart
util.text.number(r'$1,234.50');   // 1234.5
util.text.numbers('3 of 7');      // Sequence(3, 7)
```

`between` and `betweens` reach values no selector can — a string embedded in a
`<script>` block, for instance:

```dart
util.text.between(res.body, '"videoId":"', '"');
util.text.betweens(res.body, '"id":"', '"');
```

### Producing text

`render` is the only member here that goes the other way. `{key}` substitution
and nothing else — a missing key renders empty, the same contract `Slot.read`,
`Field.text` and `Json.text` keep:

```dart
util.text.render('Hello {name}, {count} new', {'name': 'Ada', 'count': 3});
// 'Hello Ada, 3 new'

util.text.render(io.read('template.md'), {'version': '3.2.0'});
```

Deliberately dumb: no conditionals, no loops, no filters, no partials. Each of
those is one step towards a template engine, and a script that needs a template
engine should have one rather than this.

---

## 4. Hashing (`util.hash`)

Digests of strings and bytes. For a file, use `io.hash`, which streams it.

```dart
util.hash.sha('abc');            // 64 hex characters
util.hash.md5('abc');            // 32 hex characters
util.hash.short(url);            // the first 8 — a cache key
util.hash.sign(body, secret);    // HMAC-SHA256, hex
util.hash.encode('hello');       // base64
util.hash.decode(encoded);       // List<int>
```

---

## 5. Randomness (`util.rand`)

The small random choices a crawler makes to look less like a machine.

```dart
util.rand.pick(agents);              // one item
util.rand.some(proxies, 3);          // three distinct items
util.rand.shuffle(urls);             // a shuffled copy
util.rand.between(1, 10);            // 1..9
util.rand.id();                      // 12 URL-safe characters
util.rand.jitter(2.s);               // 2.0s..2.5s
util.rand.chance(0.1);               // true one time in ten
util.rand.seed(42);                  // make all of the above repeat
```

Pairing `jitter` with a crawl delay stops a pool of workers from
resynchronising onto the same instant:

```dart
net.crawl<String>(seed).delay(util.rand.jitter(1.s));
```

### Reproducibility

Everything here runs off one generator, and `seed` fixes it. That is what makes
a test of anything random — the order a crawl picks its user agents in, the
jitter on an HTTP retry — repeat exactly:

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() {
  util.rand.seed(42);
  final first = util.rand.shuffle(['a', 'b', 'c']);

  util.rand.seed(42);
  final again = util.rand.shuffle(['a', 'b', 'c']);

  assert(first.join('-') == again.join('-'));

  util.rand.seed();   // back to unpredictable
}
```

It is process-wide, and it is not for anything that has to be unguessable: a
seeded generator is reproducible by design.

---

## 6. Sequences (`Sequence<T>`)

The sequence API this library **returns**, in place of Dart's. Grouping,
chunking, deduplicating, summing and taking the best of each group are what a
script does between fetching and writing, and Dart's `Iterable` needs
`package:collection` for most of them:

```dart
final rows = await net.crawl<Row>(seed).collect();     // Sequence<Row>

rows.group((r) => r.host)
    .seq.to((e) => (host: e.$1, spend: e.$2.sum((r) => r.cost)))
    .sort((e) => e.host)
    .each((e) => print('${e.host}  ${e.spend}'));
```

### Why it is not an `Iterable`

An extension member never overrides an instance member, so extending
`Iterable` could only *add* names beside Dart's — `keep` next to `where`, two
spellings for one operation, which Rule 5 forbids. Replacing the vocabulary
therefore means replacing the static type: if the receiver is not an
`Iterable`, `Iterable`'s members are not in scope, and this library's
vocabulary is the only one there.

What that costs, measured rather than guessed:

| Lost | Replacement |
| :--- | :--- |
| `for (final x in seq)` | `seq.each((x) { ... })` |
| `[...seq]`, `seq.toList()` | `seq.list` |
| passing to a `List<T>` or `Iterable<T>` parameter | `seq.list` |
| passing to this library's own APIs | nothing — they take a `Sequence` |

One word at the boundary; inside the boundary, a vocabulary with no duplicates
in it. `.seq` is the way in from the other side — a literal, a `dart:io` call,
another package:

```dart
[1, 2, 3].seq.sum((n) => n);           // 6
{'a': 1}.seq.to((e) => e.$1).list;     // ['a'] — records, not MapEntry
```

### Shaping — lazy, returns a `Sequence`

| Member | Does |
| :--- | :--- |
| `to(f)` | each element replaced by `f` of it (`map`) |
| `sift(f)` | `to` then drop the nulls (`mapNotNull`) |
| `nonnull` | on a `Sequence<T?>`, the non-null elements |
| `keep(t)` / `omit(t)` | the elements a test accepts / rejects |
| `only<R>()` | only the elements that are an `R` |
| `flat(f)` / `flat<R>()` | expand each into many / flatten nested iterables |
| `unique([by])` | duplicates removed, first of each kept |
| `sort([by])` / `order(cmp)` | ascending by key / by comparator — never in place |
| `flip` | back to front |
| `head(n)` / `tail(n)` | the first n / the last n |
| `skip(n)` / `trim(n)` | all but the first n / all but the last n |
| `until(t)` / `after(t)` | leading elements a test accepts / from the first it rejects |
| `chunks(n)` | consecutive groups of n, the last one short |
| `windows(n, {step, partial})` | sliding windows; `windows(2)` is `zipWithNext` |
| `zip(other)` | paired elementwise, as `(A, B)` records |
| `pairs` | each element with its index, as `(int, T)` |
| `scan(init, f)` | the running results of a fold |
| `also(f)` | a peek that stays in the chain |
| `plus` / `minus` / `union` / `common` | concatenate / subtract / merge / intersect |
| `or(fallback)` | this, or the fallback when empty |
| `cast<R>()` | viewed as another element type |

Laziness is the contract, not an optimisation: `rows.to(parse).keep(live).head(10)`
parses eleven rows, not all of them.

```dart
final top = rows.to(parse).keep((r) => r.live).sort((r) => r.score).flip.head(10);
```

Everything that needs the whole sequence by definition — `sort`, `order`,
`unique`, `flip`, `tail`, `trim` and every reducing member — is eager, and says
so in its doc comment.

### Reducing — eager, leaves the `Sequence`

| Member | Gives |
| :--- | :--- |
| `count([t])` | how many, or how many pass a test |
| `empty` | whether it holds nothing (no complement: `!empty`) |
| `has(x)` | whether `x` is one of the elements |
| `first` / `last` / `sole` | `T?` — nullable, never throwing |
| `at(i)` / `find(t)` / `findlast(t)` | `T?` |
| `index(t)` | `int?` |
| `any(t)` / `all(t)` | booleans (no `none`: `!any`) |
| `fold(init, f)` | Dart's word, kept |
| `sum(of)` / `avg(of)` | `num` / `double?` |
| `best(by)` / `worst(by)` | `T?` — largest / smallest by key |
| `group(by)` | `Map<K, Sequence<T>>` |
| `keyed(by, [value])` | `Map<K, V>` — the lookup table; last wins |
| `tally(by)` | `Map<K, int>` — a counted report in one call |
| `split(t)` | `(Sequence<T>, Sequence<T>)` — a record, not a `Pair` |
| `unzip` | on a `Sequence<(A, B)>`, two sequences |
| `join(sep, {prefix, suffix, limit, of})` | a summary printer, not just a join |
| `each(f)` | the `for`-in replacement |
| `list` / `set` | the conversions, as getters |

Five readers instead of ten: everything that can come up empty returns `T?`, so
there is no `firstOrNull` beside `first` and no `orElse:` to write. `?? x`
replaces Kotlin's `getOrElse`, and is shorter.

```dart
rows.first?.name ?? 'none';
rows.best((r) => r.score)?.url;
rows.tally((r) => r.host);              // {'a.com': 12, 'b.com': 3}
rows.chunks(100).each((batch) => send(batch.list));
rows.join(', ', limit: 3, of: (r) => r.name);   // 'Ada, Alan, Grace, …'
```

`sum` and `avg` always take the selector, including on a sequence that is
already numbers — `prices.sum((n) => n)`. Five characters of noise in the rarer
case buys exactly one spelling of the operation.

Randomness is not here: `util.rand` owns it, and a sequence gets it by exiting
with `util.rand.shuffle(rows.list)`.

### What returns one

Anything this library hands back for you to *shape*:

```dart
await net.crawl<T>(seed).collect();     await net.crawl<Never>(seed).gather(f);
await io.csv.maps(path);                await io.csv.matrix(path);
io.find(dir);                           net.sitemap(text);
util.text.words(t);                     util.text.numbers(t);
util.text.betweens(t, a, b);            util.rand.shuffle(list);
util.rand.some(list, n);                robots.agents;
jar.cookies;                            await format.zip.list(archive);
page.parse(format.html)('sel').elements;                 doc.at(path).all(build);
doc.jsonpath(expr);
```

Bytes stay `List<int>` — a buffer is not a sequence — and `Map` returns stay
maps, with `.seq` a call away.

---

## See Also

- [`Json`](json.md) — the read cursor, and `format.json`
- [`format.yaml`](yaml.md) — the same cursor over YAML and TOML
- [`format.zip`](zip.md) — archives
- [`format.zip`](zip.md) — archives
- [`system.console.*`](console.md) — terminal output and prompts
- [`io.*`](io.md) — files, and `io.hash` for a file's digest
