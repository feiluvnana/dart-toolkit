# Bounded Concurrency (`concurrent.*`)

Tools for managing asynchronous work: task pools with bounded concurrency, ordered and streamed results, isolate offloading, retry with backoff, and synchronization primitives.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final urls = ['/1', '/2', '/3'].map((p) => 'https://api.example.com$p'.url);

  final bodies = await concurrent.run(
    urls,
    (url) async => (await net.http.get(url)).parse(format.json).raw,
    size: 2,
  );

  system.console.logger.ok('Fetched ${bodies.collect(.count())} records.');
}
```

---

## 1. `concurrent.run` (Preserves Input Order)

```dart no-compile
Future<Sequence<R>> concurrent.run<I, R>(
  Iterable<I> items,
  FutureOr<R> Function(I item) worker, {
  int size = 4,
  Duration delay = Duration.zero,
})
```

Results come back **in the order of `items`**, regardless of which worker finishes first:

```dart
final results = await concurrent.run([30, 10, 20], (n) async {
  await util.time.wait(n.ms);
  return 'item-$n';
}, size: 3);
// ['item-30', 'item-10', 'item-20']
```

`delay` paces task launches, for politeness against a server.

---

## 2. `flow.run` (A Source You Do Not Hold)

Every member above takes an `Iterable`, so the whole input has to exist before the first task launches. `flow.run` is the same bounded pool over a [`Flow`](collection.md) — a crawl, a CSV too large for memory, a piped stdin — and it is the only way to write *four at a time, over a stream*:

```dart no-compile
Flow<R> Flow<T>.run<R>(
  FutureOr<R> Function(T item) worker, {
  int size = 1,
  bool ordered = true,
})
```

`size: 1` is `Stream.asyncMap`. `ordered: true` — the default — yields in the order elements arrived however the work finishes; `ordered: false` yields each result as soon as it is ready, for work whose output should not wait on the slowest item:

```dart
await [300, 50, 100].flow
    .run((int ms) async {
      await util.time.wait(ms.ms);
      return 'done-$ms';
    }, size: 3, ordered: false)
    .collect(.foreach(print));   // prints 'done-50', 'done-100', 'done-300'
```

The argument for it is the shape that was not expressible at all before — a piped stdin, fetched four at a time:

```dart
// setup: Future<String> fetch(Uri u) async => '$u'; void save(String s) {}
await system.console.reader.lines
    .transform(.map((line) => line.trim()))
    .transform(.where((line) => line.isNotEmpty))
    .run((line) => fetch(line.url), size: 4)
    .collect(.foreach(save));
```

It honours its subscription the way `Pool.flow` does: pausing stops new tasks launching, and cancelling stops the run — so `collect(.first())` over a crawl fetches one page.

`concurrent.stream` was a second spelling of this over items you already hold, and 5.4.0 deleted it. `concurrent.run` stays: it carries `delay` and `Pool`'s error semantics, which `flow.run` does not, so the two are not spellings of each other.

Draining a flow for its side effects alone is `collect(.count())`. There is deliberately no `drain`: Dart already owns that word and it means *discard*, and `count()` already drains and hands back something worth having.

---

## 3. `Pool.settle` (Partial Results Without Throwing)

`settle` executes tasks across items and returns one `Settled<R>` per item, in input order, whether it succeeded or failed. It is a sealed type with two cases, so the branch that has a value is the branch where the value is not null:

```dart
final pool = Pool<int>(size: 2);
final outcomes = await pool.settle([1, 0, 2], (n) async {
  if (n == 0) throw Exception('Division by zero');
  return 10 ~/ n;
});

outcomes.collect(.foreach((outcome) {
  switch (outcome) {
    case Done(:final value):
      print('Value: $value');       // int, not int?
    case Broke(:final error, :final stack):
      print('Failed: $error');
  }
}));
```

`Done<R>` carries `value`; `Broke<R>` carries `error` and `stack`. The switch is exhaustive, so a third case cannot be forgotten. For a count or a filter there is also `outcome.ok`, and `outcome.value` reads `null` for a failure:

```dart
// setup: final outcomes = await Pool<int>().settle<int>([1], (n) async => n);
final built = outcomes.transform(.where((o) => o.ok)).collect(.count());
```

---

## 4. Error Handling & `PoolFailure`

By default `concurrent.run` is **fail-fast**: the first error stops new tasks from launching and rethrows once the in-flight tasks settle:

```dart
try {
  await concurrent.run(items.collect(.list()), (i) => mayThrow());
} on StateError catch (e) {
  // your worker's own error, with its original stack trace
}
```

Registering `on.error` switches the pool to **collect-and-continue**: every item is attempted, and `run` throws `PoolFailure` at the end listing what failed, while keeping partial results reachable via `e.results`:

```dart
final pool = Pool<Uri>(size: 4);
pool.on.error((error, stack, item) => log.warn('$item failed: $error'));

try {
  await pool.run(urls, fetch);
} on PoolFailure<String, String> catch (e) {
  log.error('${e.failures.length} of ${urls.length} failed');
  for (final f in e.failures) log.debug('${f.item}: ${f.error}');
  print('Successful results: ${e.results.nonNulls.length}');
}
```

---

## 5. Retries (`concurrent.retry`)

Retries an asynchronous operation on failure with exponential backoff.
`retries` is the number of **extra** attempts after the first, which is what
`Fetcher.retries` already means — so `retries: 3` runs the body up to four
times. A `times:` stood beside it through 4.0.0, documented as *pass one or the
other*; passing both took the smaller silently, and it went in 5.0.0.

```dart
final data = await concurrent.retry(
  () => fetchFromFlakyService(),
  retries: 3,
  backoff: 500.ms,
  onretry: (err, attempt) => log.warn('Attempt $attempt failed: $err'),
);
```

---

## 6. Bounding access (`Semaphore`)

Control access to shared resources, or serialise a critical section:

```dart
// Up to N simultaneous holders
final sem = concurrent.semaphore(3);
await sem.guard(() async {
  // up to 3 concurrent tasks
});

// Or take and release by hand
await sem.take();
try {
  // ...
} finally {
  sem.release();
}

// A mutex is one permit. `Mutex` and `concurrent.mutex()` were a whole
// exported type for `Semaphore(1)` and went in 5.0.0.
final lock = concurrent.semaphore(1);
await lock.guard(() async {
  // critical section
});
```

`Semaphore` and `Limiter` are spelled the same — `take` and `guard` — because
they are the same shape with different bounds. Through 4.0.0 the semaphore said
`acquire`/`withPermit`, which was two dialects for one idea and the library's
one camelCase member.

### How often, not how many (`concurrent.rate`)

`Semaphore` bounds **how many at once**. A published API limit bounds
**how often** — *5000 requests per hour*, *10 per second*, *60 per minute* — and
a `Semaphore(4)` satisfies none of them: four instant requests then four more is
eight in a second, so the script works until the day the network is fast.

```dart
final limit = concurrent.rate(10, per: 1.s);       // a Limiter

await limit.take();                                 // waits for a token
await limit.guard(() => net.http.get(url));         // the wrapped form
```

`guard` is spelled the same on `Semaphore` — every limiter here has a bare
`take`/`release` pair and a wrapping `guard`, and the wrapping form is the one
callers should use. The reason it lives in this domain is that it composes with the
bound that was already here:

```dart
await concurrent.run(urls, (u) => limit.guard(() => net.http.get(u)), size: 8);
// 8 in flight, never more than 10 per second — two limits, one line
```

The bucket **refills smoothly**, one token every `per / count`, rather than in a
lump at the end of each window. Smooth is what servers actually measure, and it
means a burst of ten at second zero does not lock out second one entirely. A
limiter starts full, so the first `count` calls do not wait, and waiters are
served in the order they arrived.

| Member | Gives |
| :--- | :--- |
| `take()` | waits for one token and takes it |
| `guard(action)` | takes a token, then runs the action |
| `available` | how many tokens there are, fractionally |
| `waiting` | how many callers are queued |
| `close()` | stops the refill timer and releases anyone queued |

A `Fetcher` can carry one, which is where a rate belongs when it is the server's
rather than the script's:

```dart
final api = Fetcher(limiter: concurrent.rate(10, per: 1.s));
await concurrent.run(urls, api.get, size: 8);
```

Every attempt takes a token, retries included, because the server counts those
too. The dependency points that way round on purpose: `concurrent` knows nothing
about responses, so a limiter that read `Retry-After` off one would tangle the
two domains — retry pacing already honours that header.

---

## 7. A Reusable Pool

Construct a `Pool<I>` when you want lifecycle hooks:

```dart
final pool = Pool<Uri>(size: 4, delay: 100.ms);
final bar = Progress(total: urls.length, message: 'Fetching');

pool.on.start(() => log.info('pool started'));
pool.on.progress((url) => bar.tick(1, '$url'));   // url is typed as Uri
pool.on.done(() => bar.done('complete'));

final pages = await pool.run(urls, fetch);
```

| Hook | Fires |
| :--- | :--- |
| `on.start` | Once, before the first task |
| `on.progress` | After each task succeeds |
| `on.done` | Once, after every task settles |
| `on.error` | On a task failure (and switches the failure mode) |

