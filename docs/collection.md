# Collections (`Sequence`, `Dictionary`, `Transformer`, `Collector`)

The two collections this library **returns**, in place of Dart's, and the two operation types that shape them.

`Sequence<T>` is the ordered collection; `Dictionary<K, V>` is the keyed one. Neither implements its `dart:core` counterpart, so there is exactly one vocabulary in scope at any call site. Neither carries the vocabulary as methods either: `Sequence` has **two** — `transform` takes a `Transformer`, `collect` takes a `Collector` — and every operation is a static factory on one of those.

That indirection is not overhead bolted onto the same names. It is what pays for better ones.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

typedef Row = ({String host, num cost});

Future<void> main() async {
  final rows = await net.crawl<Row>('https://example.com'.url).collect();

  rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)))
      .pairs
      .transform(.sort.by((e) => e.$1))
      .collect(.foreach((e) => print('${e.$1}  ${e.$2}')));
}
```

---

## 1. Why a namespace buys back the words

Through 5.0.0 `Sequence` had fifty-eight methods and roughly a third of them were words invented for an operation every reader already knew: `to` for `map`, `keep` for `where`, `sift` for `mapNotNull`, `only` for `whereType`, `head` for `take`, `sole` for `single`, `best` for `maxBy`, `tally` for `countBy`.

Each rename was defensible on its own and the set was exhausting. Two things forced them:

- **A collision at the top level of a class.** `map` is also the noun for the other collection; `where` is one autocomplete away from `Iterable.where`.
- **Rule 4 forbids camelCase.** Eight of the thirteen renames say exactly that. `takeWhile` could not be a member, so it became `until`. `maxBy` became `best`. `countBy` became `tally`.

Inside a namespace neither problem exists:

```dart
// setup: bool live(Row r) => r.live;
Transformer.map<Row, String>((r) => r.host);   // cannot be confused with Map
Transformer.where<Row>(live);                  // cannot be confused with Iterable.where
Collector.first<Row>();                        // cannot be confused with Iterable.first
Collector.count.by<Row, String>((r) => r.host);
```

And the second word gets somewhere to go. **Where Dart or Kotlin spells an operation as a camelCase compound, split it at the capital:**

| Everyone spells it | Here it is |
| :--- | :--- |
| `takeWhile(t)` / `skipWhile(t)` | `take.when(t)` / `skip.when(t)` |
| `firstWhere(t)` / `lastWhere(t)` | `first.where(t)` / `last.where(t)` |
| `singleWhere(t)` | `single.where(t)` |
| `whereType<R>()` | `where.type<R>()` |
| `flatMap(f)` | `flat.map(f)` |
| `mapNotNull(f)` | `map.nonnull(f)` |
| `groupBy(f)` | `group.by(f)` |
| `countBy(f)` | `count.by(f)` |
| `associateBy(f)` | `associate.by(f)` |
| `distinctBy(f)` | `unique.by(f)` |
| `maxBy(f)` / `minBy(f)` | `max.by(f)` / `min.by(f)` |
| `sortBy(f)` / `sortedWith(c)` | `sort.by(f)` / `sort.using(c)` |
| `indexOf(v)` / `indexWhere(t)` | `index.of(v)` / `index.where(t)` |
| `forEach(f)` | `foreach(f)` |

Nothing is invented. Every name on the right is the name on the left with the capital turned into a dot — a rule you learn once and then never look anything up again. Two words are not available: `while` is reserved, so `takeWhile` is `take.when`; and `for` is reserved, so `forEach` is `foreach` rather than `for.each`.

The pairs that had to invent a word for their second half collapse into namespaces of three:

| Was | Is | |
| :--- | :--- | :--- |
| `head(n)` / `tail(n)` | `take.first(n)` / `take.last(n)` | Dart has no name for the second |
| `skip(n)` / `trim(n)` | `skip.first(n)` / `skip.last(n)` | `trim` also read as `String.trim` |
| `until(t)` / `after(t)` | `take.when(t)` / `skip.when(t)` | |

Six members, four of them invented, become two namespaces that read as opposites — which `head`/`skip` and `tail`/`trim` never did. Nobody has to remember which of the four dropped from which end.

---

## 2. The dot is the point

At a call site the context type resolves the name, so the leading dot is the spelling to write:

```dart
rows.transform(.where((r) => r.live))
    .transform(.sort.by((r) => r.cost))
    .transform(.take.first(10))
    .collect(.list());
```

Dot shorthands landed in Dart 3.10, which is this package's minimum SDK. The explicit form always works and means the same thing — it is what a named pipeline uses:

```dart
rows.transform(Transformer.take.first(10));
```

A chained shorthand resolves left to right (`.take` against the context type, then `first(3)` against that), and a namespace can be callable, so a bare form and a compound form coexist without a second name: `.count()` and `.count.by(f)` are the same `count`.

### When the result type comes from anywhere but a lambda's return, name it

Inference reads the result type out of the callback you pass. Two places have no callback to read it from — `Collector.fold`, whose type comes from a *value*, and `Collector.then`, which changes it after the fact:

```dart
final int total = rows.collect(.fold(0, (t, r) => t + r.qty.toInt()));  // a context type
rows.collect(.fold<Row, int>(0, (t, r) => t + r.qty.toInt()));          // explicit arguments
```

Annotating the lambda is not a third answer: `(int t, Row r)` pins the lambda's
own type and leaves the collector's result type free just the same.

`sum`, `avg`, `count` and `join` exist so the common folds never reach for `fold` at all, which is exactly why Java ships `summingInt` beside `reducing`.

---

## 3. `Transformer` — the shaping operations

`Transformer<A, B>` turns a sequence of `A` into a sequence of `B`. `Sequence.transform` applies one.

| Factory | Does |
| :--- | :--- |
| `map(f)` | each element replaced by `f` of it |
| `map.nonnull(f)` | `map`, then drop the nulls |
| `where(t)` | the elements a test accepts |
| `where.type<R>()` | only the elements that are an `R` |
| `flat<R>()` / `flat.map(f)` | flatten nested iterables / expand each into many |
| `unique()` / `unique.by(f)` | duplicates removed, first of each kept |
| `sort()` / `sort.by(f)` / `sort.using(c)` | ascending — never in place |
| `flip()` | back to front |
| `take.first(n)` / `take.last(n)` / `take.when(t)` | the leading n / trailing n / while a test holds |
| `skip.first(n)` / `skip.last(n)` / `skip.when(t)` | the exact opposites |
| `enumerate()` | each element with its position, as `(int, T)` |
| `chunk(n)` | consecutive groups of n, the last one short |
| `zip(other)` | paired elementwise, as `(A, B)` records |
| `plus` / `minus` / `common` | concatenate / subtract / intersect |
| `or(fallback)` | this, or the fallback when empty |
| `cast<R>()` | viewed as another element type, throwing on a bad one |
| `fn(run)` | anything the named ones do not cover |

There is no `omit`. `where((r) => !r.live)` is the other side, and Rule 4's `!` test applies to a filter the moment the filter has an ordinary name.

`enumerate()` earns its place by deleting three members. Everything index-aware composes out of it rather than needing one of its own:

```dart
titles.transform(.enumerate()).transform(.map((p) => '${p.$1}. ${p.$2}'));
titles.transform(.enumerate()).transform(.where((p) => p.$1.isEven));
```

A `map.indexed(f)` is deliberately **not** offered: it is `enumerate()` then `map` exactly, and Rule 5 says two entry points to one behaviour is a bug in the API.

### A snapshot, not a view

Every step is eager. A `Sequence` holds a `List<T>` taken when it was built and each `transform` builds the next one, so **a callback runs exactly once per element per step** however often you read the result:

```dart
var n = 0;
final s = [1, 2, 3].seq.transform(.where((x) { n++; return true; }));
s.collect(.count()); s.list; s.collect(.first());
// n == 7 through 4.0.0, and 3 now
```

The trade is stated rather than hidden: `take.first(10)` after a `map` maps the whole source rather than stopping at the eleventh element. Where the source is large enough for that to matter the answer is a `Stream` — `crawl.stream` rather than `crawl.collect`.

---

## 4. `Collector` — the ending operations

`Collector<A, R>` turns a sequence of `A` into a single `R`. `Sequence.collect` applies one. This is the half with Java's precedent — `Collectors` is twenty years old and uncontroversial — and the half where the old surface sprawled worst.

| Factory | Gives |
| :--- | :--- |
| `count()` / `count.where(t)` / `count.by(f)` | `int` / `int` / `Dictionary<K, int>` |
| `empty()` | whether it holds nothing (no complement: `!`) |
| `has(x)` | whether `x` is one of the elements |
| `first()` / `last()` / `single()` | `A?` — nullable, never throwing |
| `first.where(t)` / `last.where(t)` / `single.where(t)` | `A?` |
| `at(i)` | `A?` |
| `index.of(v)` / `index.where(t)` | `int?` — the position |
| `any(t)` / `all(t)` | booleans (no `none`: `!any`) |
| `fold(init, f)` | Dart's word, kept |
| `sum(of)` / `avg(of)` | `num` / `double?` |
| `max.by(f)` / `min.by(f)` | `A?` — largest / smallest by key |
| `group.by(f)` | `Dictionary<K, Sequence<A>>` |
| `group.into(f, down)` | `Dictionary<K, R>` — every bucket reduced in one pass |
| `associate.by(f)` | `Dictionary<K, A>` — the lookup table; last wins |
| `dict()` | on a sequence of `(K, V)`, a `Dictionary<K, V>` |
| `split(t)` | `(Sequence<A>, Sequence<A>)` — a record, not a `Pair` |
| `join(sep, {prefix, suffix, limit, of})` | a summary printer, not just a join |
| `foreach(f)` | the `for`-in replacement |
| `list()` / `set()` / `seq()` | the conversions |
| `fn(run)` | anything the named ones do not cover |

Five readers instead of ten: everything that can come up empty returns `A?`, so there is no `firstOrNull` beside `first` and no `orElse:` to write. `?? x` replaces Kotlin's `getOrElse`, and is shorter.

```dart
rows.collect(.first())?.name ?? 'none';
rows.collect(.max.by((r) => r.score))?.url;
rows.collect(.count.by((r) => r.host));          // Dictionary<String, int>
rows.transform(.chunk(100)).collect(.foreach((batch) => send(batch.list)));
rows.collect(.join(', ', limit: 3, of: (r) => r.name));   // 'Ada, Alan, Grace, …'
```

`sum` and `avg` always take the selector, including on a sequence that is already numbers — `.sum((n) => n)`. Five characters of noise in the rarer case buys exactly one spelling of the operation.

`each` became `foreach` because `each` is what this library calls the *callback* in `fold` and `map`; the operation gets the other half of the name. Rule 4 exempts `dart:core` interface members from the lowercase rule, but `Sequence` does not implement `Iterable`, so it is not declaring one and the exemption does not reach it.

Randomness is not here: `util.rand` owns it, and a sequence gets it by exiting with `util.rand.shuffle(rows.list)`.

### Downstream collectors

The one Java idea that changes what you can express rather than how it reads. `group.into` takes a second collector and reduces every bucket **in the same pass**:

```dart
rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)));   // Dictionary<String, num>
rows.collect(.group.into((r) => r.host, .count()));
rows.collect(.group.into((r) => r.host, .max.by((r) => r.cost)));
```

Nested shorthands infer: the outer `.group` and the inner `.sum` each resolve against their own context type.

`group.by(f)` and `group.into(f, down)` are two members rather than one with an optional argument, because an omitted downstream collector would leave its result type with nothing to be inferred from and every bucket would arrive as `dynamic`.

`count.by(f)` is `group.into(f, .count())` and is defined as it, in one line. That is one implementation and two spellings of a call, which is the case Rule 5's `io.csv.pipe`-beside-`write` note already carves out: `count.by` is what a script writes ten times for every one of the general form, the same way Java ships `counting()` and people still reach for it constantly.

---

## 5. A pipeline is a value

This is the part that is not a rename. Because an operation is a value, a *chain* can be one:

```dart
// setup: bool live(Row r) => r.live; String sku(Row r) => r.sku; num price(Row r) => r.price;
final cleanup = Transformer.where<Row>(live)
    .then(Transformer.unique.by(sku))
    .then(Transformer.sort.by(price));

final top = rows.transform(cleanup).transform(.take.first(10)).collect(.list());
final all = rows.transform(cleanup).collect(.count());
```

One definition, two uses. As a method chain that is a copy-paste, or a helper that has to re-type the whole thing.

`then` on a transformer joins two transformers. `into` gives one an ending, which makes it a collector — Java's `Collectors.mapping(f, downstream)` generalised to *any* transformer with *any* collector:

```dart
final hosts = Transformer.map<Row, String>((r) => r.host).into(Collector.list());
rows.collect(hosts);          // List<String>
```

`then` on a *collector* is Java's `collectingAndThen`. It is for a named collector, not for inline chaining: it changes the result type, which leaves inference nothing to pin the element type to.

```dart
final Collector<Row, String> summary =
    Collector.count<Row>().then((n) => '$n rows');

rows.collect(summary);
```

Three more things fall out of operations being values:

- **A caller can supply one.** A function that takes a `Transformer<Page, Row>` lets the script decide how pages become rows, knowing nothing about it.
- **A custom one is first-class**, composing with the built-ins on equal footing — no extension, no subclass registry, nothing to register.
- **One can be tested on its own**, against a plain list, with no `Sequence` in the test at all: `Transformer.map<int, String>((n) => '$n').run(const [1, 2])`.

### The escape hatch

A closed set of factories is a closed set, so there is a door — the same one `Field.fn` has been in `util/markup.dart` for three releases:

```dart
rows.transform(.fn((xs) => xs.toList()..shuffle()));
rows.collect(.fn((xs) => xs.length * 2));
```

`fn` takes a closure, so it fits an operation used once, in one place, that needs no name. For anything more, write the class:

```dart
/// Rows that cost more than [floor].
final class Dearer extends Transformer<Row, Row> {
  Dearer(num floor) : super((rows) => rows.where((r) => r.cost > floor));
}

rows.transform(Dearer(0.05)).transform(.take.first(10)).collect(.list());
```

| | Use it for |
| :--- | :--- |
| `.map(f)`, `.take.first(n)`, … | the operation is one of the named ones |
| `.fn((xs) => …)` | one place, no name needed, no options |
| `class X extends Transformer` | reused, parameterised, or worth a test |

`Transformer` and `Collector` are therefore plain `class`, not `final class`, with a public generative constructor taking the function. The set of operations is deliberately not closed.

---

## 6. `Dictionary<K, V>` — the keyed collection

`Sequence` is the ordered collection. `Dictionary` is the keyed one, and it is what grouping hands back — so a chain never leaves this vocabulary and has to climb back in.

```dart
// setup: final spend = Dictionary<String, num>(const {'a.com': 1});
spend.get('a.com');           // num? — nullable, like every reader here
spend.has('a.com');
spend.count;
spend.empty;

spend.set('b.com', 4);
spend.delete('b.com');
spend.ensure('c.com', () => 0);              // putIfAbsent, named for what it does
spend.update('a.com', (n) => (n ?? 0) + 1);  // null when absent: one callback covers both
spend.merge(Dictionary(const {'d.com': 2}));

spend.keys;                   // Sequence<String>
spend.values;                 // Sequence<num>
spend.pairs;                  // Sequence<(String, num)>
spend.invert();               // Dictionary<num, String>
spend.map;                    // Map<String, num> — the one word at the boundary
```

`transform` and `collect` run over `(K, V)` records, so the whole `Transformer` and `Collector` vocabulary reaches a dictionary without a second set of factories:

```dart
hosts.transform(.where((e) => e.$2.collect(.count()) > 1));
hosts.collect(.count());
```

`transform` keeps you in a dictionary, so its transformer has to hand back records; to leave, go through `pairs`, `keys` or `values`. `.dict` is the way in from a plain `Map`, as `.seq` is for an iterable.

It is not a `Map` for the reason `Sequence` is not an `Iterable`: an extension member never overrides an instance member, so `get` beside `[]` and `count` beside `length` would be two spellings of one operation forever.

### What `Dictionary` replaced

Three copies of one class, which turned out to be the same class:

1. **`group`, `keyed` and `tally` handed back a raw `Map`**, and `extension MapSequenced on Map` existed solely to get back in. Both are gone.
2. **`Meta` and `Store` were the same nine members, written twice** — one in `util/slot.dart`, one in `io/store.dart`, one carried by a crawl and one kept in a JSON file. Neither was about crawling or about files; both were a map with typed keys.
3. **There was no keyed collection to return**, so `Markup.dataset`, `Cli.switches` and `system.env.map` all handed back raw maps too. Those three still do — the type they were missing is the thing that had to exist first.

Typed keys now work on every dictionary in the program rather than only inside the two classes that happened to implement them.

---

## 7. Typed keys (`Slot`)

A `Slot<T>` is a typed key. Declare it `const`, once, beside the code that uses it:

```dart
const token = Slot<String>('token');
const visits = Slot<int>('visits');
const tags = Slot<List<Object?>>('tags');
```

Both ends are then checked. `db.write(visits, 'many')` does not compile, and `db.read(visits)` is an `int?` without a cast in sight. Two parts of a script can no longer disagree about how a key is spelled, because they share the one declaration.

Slots need `K == String` and `V == Object?`, so they live on an extension narrowed to that shape rather than on the generic class — where `NullableSequence` already lives:

```dart
// setup: const token = Slot<String>('token');
final bag = Dictionary<String, Object?>();

bag.write(token, 'abc');
bag.read(token);              // String?, null when absent or the wrong shape
bag.holds(token);
bag.drop(token);
```

They are `read` and `write` rather than `get` and `set` so they do not collide with the untyped members on the class — and because that pair says the value is going through a codec, which is exactly what a `Slot` is.

`T` must be something `jsonEncode` accepts: a string, number, bool, list or map. For anything else, `Slot.coded` says how it converts:

```dart
const since = Slot<DateTime>.coded('since', read: _readTime, write: _writeTime);

DateTime? _readTime(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;
Object? _writeTime(DateTime value) => value.toIso8601String();
```

`read` and `write` have to be top-level or static functions for the slot to stay `const`.

A read whose stored value is not the shape the slot names comes back `null` rather than throwing. That is what keeps a schema change from taking down the next run:

```dart
// setup: const token = Slot<String>('token');
final bag = Dictionary<String, Object?>()..write(token, 'dark');
bag.read(const Slot<int>('token'));   // null
```

Calling a slot gives the `(key, value)` pair it writes, which is how a value reaches a crawl's `meta` — see [crawl.md](crawl.md#5-carrying-context-between-stages).

---

## 8. On disk

A collection can write itself, and a dictionary can be read back:

```dart
rows.dump('out/rows.json');              // a JSON array
spend.dump('out/by-host.json');          // a JSON object
final db = io.dictionary('out/cache.json');
```

`dump` is an extension declared in `lib/io/`, not a member of `Sequence` or `Dictionary`. The direction is the point: Rule 1 says anything that writes a file is `io`, and Rule 2 forbids `collection` needing `io` back. `io` already depends on `collection` — `io.find` returns a `Sequence` — so this adds no new edge, and a collection still knows nothing about the disk. The package has one export, so a script sees `rows.dump(path)` with no extra import.

The state a script keeps between runs is then two explicit calls:

```dart
// setup: const cursor = Slot<int>('cursor');
final state = io.dictionary('out/cache.json');
state.write(cursor, (state.read(cursor) ?? 0) + 1);
state.dump('out/cache.json');
```

The path is named twice rather than held. That is the trade for a collection that does not secretly own a file, and it is the same trade `format.json.read(path)` already makes. `Store` held it — and held a process-wide mutable singleton with it, plus a `load` that swallowed a missing file, unparseable JSON and a non-map document into the same silent empty.

`io.dictionary` splits those apart: an **absent** file is an empty dictionary, because a first run has nothing to read; a file that is there and is not a JSON object throws `FormatException`, because that is a broken file rather than a missing one, and silence is how a half-written snapshot becomes a silent data loss.

### Resuming work

Combined with a crawl, a dictionary makes an interrupted run resumable:

```dart
// setup: const done = Slot<List<Object?>>('done');
final db = io.dictionary('.cache/crawl.json');
final seen = (db.read(done) ?? const []).cast<String>().toSet();

await net.crawl<String>('https://example.com/index'.url)
    .run((res) {
      for (final link in res.parse(format.html).find('a').attrs('href').list) {
        if (seen.contains(link)) continue;
        res.follow(link);
      }
      seen.add(res.url.toString());
    });

db.write(done, seen.toList());
db.dump('.cache/crawl.json');
```

For a crawl that has to survive being interrupted mid-run rather than between runs, `net.crawl(...).resume(path)` carries the frontier as well as the visited set — see [crawl.md](crawl.md).

---

## 9. What returns one

Anything this library hands back for you to *shape*:

```dart no-compile
await net.crawl<T>(seed).collect();     await net.crawl<Never>(seed).gather(f);
await io.csv.maps(path);                await io.csv.matrix(path);
io.find(dir);                           net.sitemap(text);
util.text.words(t);                     util.text.numbers(t);
util.text.betweens(t, a, b);            util.rand.shuffle(list);
util.rand.some(list, n);                robots.agents;
jar.cookies;                            await format.zip.list(archive);
page.parse(format.html).find('sel').elements;                 doc.at(path).all(build);
doc.jsonpath(expr);                     io.dictionary(path);
res.meta;                               rows.collect(.group.by(f));
```

Bytes stay `List<int>` — a buffer is not a sequence.

---

## 10. What it cost

Honestly, measured on this library's own showcase pipeline. Before:

```dart no-compile
rows.group((r) => r.host)
    .seq.to((e) => (host: e.$1, spend: e.$2.sum((r) => r.cost)))
    .sort((e) => e.host)
    .each(print);
```

After:

```dart
rows.collect(.group.into((r) => r.host, .sum((r) => r.cost)))
    .pairs
    .transform(.sort.by((e) => e.$1))
    .collect(.foreach(print));
```

Four lines either way, and the grouping line now reduces in one pass where the old one built sequences and mapped over them. The cost lands on the *intermediate* operations, where a chain of three pays `.transform(` three times. It does not land on the terminals, which are once per pipeline and where the wrapper reads as punctuation — `titles.collect(.count())` against `titles.count()`.

`take.first(10)` is eight characters longer than `head(10)`. The defence is that nobody has to remember which of `head`/`tail`/`skip`/`trim` dropped from which end, which was the actual complaint.

---

## See Also

- [`util.*`](util.md) — time, sizes, text, hashing, randomness
- [`Json`](json.md) — the read cursor, and `format.json`
- [`io.*`](io.md) — files, and `io.dump` for a document
- [`net.crawl`](crawl.md) — where most sequences in a script come from
