# Pure helpers (`util.*`)

Delays and timestamps (`util.time`), byte sizes (`util.size`), text handling
(`util.text`), hashing (`util.hash`) and randomness (`util.rand`) — plus
[`Json`](json.md), the cursor `format.json`, `format.yaml` and `Reply.at` all
hand back.

Nothing here touches the disk or the operating system — that is the rule that
decides what belongs. Archives are [`format.zip`](zip.md), the collections are
[`collection.md`](collection.md), and the terminal is
[`system.console`](console.md).

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
rows.collect(.group.by((r) => util.time.day(r.seen)));   // Map<DateTime, Sequence<Row>>
```

The `int` extensions cover the whole ladder: `250.ms`, `30.s`, `5.m`, `2.h`,
`3.d`.

---

## 2. Byte Sizes (`util.size`)

```dart
util.size.format(5242880);            // '5.0 MiB'
util.size.format(1023);               // '1023 B'
util.size.format(1024, decimals: 2);  // '1.00 KiB'
util.size.format(-2048);              // '-2.0 KiB'
util.size.parse('2.5 MiB');           // 2621440
util.size.parse('2.5 MB');            // 2500000
util.size.parse('10K');               // 10240
util.size.parse('10 XB');             // null
```

**Binary units, spelled as binary units.** The arithmetic here has always been 1024-based and the labels said `KB`, `MB`, `GB` — so a terabyte of disk printed as `'931.3 GB'` and `parse('5MB')` answered 5,242,880, which is five *mebibytes* under a name that means five million. 5.0.0 keeps the arithmetic and fixes the labels: `format` writes `KiB`/`MiB`/`GiB`, and `parse` accepts both families and gives each the scale its name carries — `KiB` and the bare `K` are 1024, `KB` is 1000.

`format` shows a plain byte count with no fraction, and carries a negative through rather than clamping it to `'0 B'`. `parse` returns **`int?`**: `null` for text that is not a size, for a unit nobody knows, and for a unit with no number. It used to return `0` for all three, which is a value a caller cannot tell apart from an empty file. Every unit `format` writes, up to `PiB`, reads back, so `parse(format(n))` is `n` rounded to the digits it printed.

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
util.text.upper('hello');            // 'Hello'
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
util.hash.decode(util.hash.encode('hello'));   // List<int>
```

---

## 5. Randomness (`util.rand`)

The small random choices a crawler makes to look less like a machine.

```dart
util.rand.pick(agents.list);         // one item
util.rand.some(agents.list, 3);      // three distinct items
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

  assert(first.collect(.join('-')) == again.collect(.join('-')));

  util.rand.seed();   // back to unpredictable
}
```

It is process-wide, and it is not for anything that has to be unguessable: a
seeded generator is reproducible by design.

---

## 6. Collections

`Sequence` and `Dictionary` used to live here. They are their own domain now —
they grew two operation types and a dozen namespaces, and Rule 3's test for a
sub-namespace (*a cohesive vocabulary with its own nouns*) describes them
exactly. `util` holds functions you call; a collection is a type you receive.

See [collection.md](collection.md) for the whole vocabulary. The short version:

```dart
rows.transform(.where((r) => r.live))         // a Transformer
    .transform(.sort.by((r) => r.cost))
    .collect(.group.into((r) => r.host, .sum((r) => r.cost)));   // a Collector
```

Randomness stays here rather than on a sequence, so a sequence gets it by
exiting: `util.rand.shuffle(rows.list)`. `util.text.words`, `util.text.numbers`
and `util.text.betweens` all hand one back.

---

## See Also

- [`Sequence` and `Dictionary`](collection.md) — the collections and their vocabulary
- [`Json`](json.md) — the read cursor, and `format.json`
- [`format.yaml`](yaml.md) — the same cursor over YAML and TOML
- [`format.zip`](zip.md) — archives
- [`system.console.*`](console.md) — terminal output and prompts
- [`io.*`](io.md) — files, and `io.hash` for a file's digest
