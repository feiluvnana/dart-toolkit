# Pure helpers (`util.*`)

Delays and timestamps (`util.time`), byte sizes (`util.size`), text handling
(`util.text`), hashing (`util.hash`) and randomness (`util.rand`).

Nothing here touches the disk or the operating system — that is the rule that
decides what belongs. Archives are [`zip`](zip.md), Git is [`git`](git.md), and
the terminal is [`system.console`](console.md).

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
await util.time.wait(2.seconds);
await util.time.wait(5.minutes);
await util.time.wait(const Duration(hours: 1));
```

`250.ms`, `2.seconds` and `5.minutes` are plain `Duration` values, usable anywhere one is accepted:

```dart
net.crawl<String>(url).delay(500.ms);
HttpClient(timeout: 10.seconds);
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

## 2. Byte Sizes (`util.size`)

```dart
util.size.format(5242880);            // '5.0 MB'
util.size.format(1024, decimals: 2);  // '1.00 KB'
util.size.parse('2.5 MB');            // 2621440
util.size.parse('10KB');              // 10240
```

`format` renders zero and negative inputs as `'0 B'`. `parse` accepts both `KB` and `K` style units, treats a bare number as bytes, and returns `0` for anything it cannot read.

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
util.text.words('one two-three');       // ['one', 'two', 'three']
util.text.blank('  \n ');               // true
util.text.fold('déjà');                 // 'deja'
```

`number` and `numbers` ignore currency symbols and digit grouping, which is
what scraped prices and counts look like:

```dart
util.text.number(r'$1,234.50');   // 1234.5
util.text.numbers('3 of 7');      // [3, 7]
```

`between` and `betweens` reach values no selector can — a string embedded in a
`<script>` block, for instance:

```dart
util.text.between(res.body, '"videoId":"', '"');
util.text.betweens(res.body, '"id":"', '"');
```

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

  assert(first.join() == again.join());

  util.rand.seed();   // back to unpredictable
}
```

It is process-wide, and it is not for anything that has to be unguessable: a
seeded generator is reproducible by design.

---

## See Also

- [`git`](git.md) — repository automation
- [`zip`](zip.md) — archives
- [`system.console.*`](console.md) — terminal output and prompts
- [`io.*`](io.md) — files, and `io.hash` for a file's digest
