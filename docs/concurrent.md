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

  system.console.logger.ok('Fetched ${bodies.length} records.');
}
```

---

## 1. `concurrent.run` (Preserves Input Order)

```dart
Future<List<R>> concurrent.run<I, R>(
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

## 2. `concurrent.stream` (Completion Order)

When tasks vary in duration and you want to process each result as soon as it is ready, use `concurrent.stream`:

```dart
final stream = concurrent.stream<int, String>(
  [300, 50, 100],
  (ms) async {
    await util.time.wait(ms.ms);
    return 'done-$ms';
  },
  size: 3,
);

await for (final result in stream) {
  print(result); // prints 'done-50', 'done-100', 'done-300'
}
```

---

## 3. `Pool.settle` (Partial Results Without Throwing)

`settle` executes tasks across items and returns one `Settled<R>` per item, in input order, whether it succeeded or failed. It is a sealed type with two cases, so the branch that has a value is the branch where the value is not null:

```dart
final pool = Pool<int>(size: 2);
final outcomes = await pool.settle([1, 0, 2], (n) async {
  if (n == 0) throw Exception('Division by zero');
  return 10 ~/ n;
});

for (final outcome in outcomes) {
  switch (outcome) {
    case Done(:final value):
      print('Value: $value');       // int, not int?
    case Broke(:final error, :final stack):
      print('Failed: $error');
  }
}
```

`Done<R>` carries `value`; `Broke<R>` carries `error` and `stack`. The switch is exhaustive, so a third case cannot be forgotten. For a count or a filter there is also `outcome.ok`, and `outcome.value` reads `null` for a failure:

```dart
final built = outcomes.where((o) => o.ok).length;
```

---

## 4. Error Handling & `PoolFailure`

By default `concurrent.run` is **fail-fast**: the first error stops new tasks from launching and rethrows once the in-flight tasks settle:

```dart
try {
  await concurrent.run(items, (i) => mayThrow(i));
} on StateError catch (e) {
  // your worker's own error, with its original stack trace
}
```

Registering `on.error` switches the pool to **collect-and-continue**: every item is attempted, and `run` throws `PoolFailure` at the end listing what failed, while keeping partial results reachable via `e.results`:

```dart
final pool = Pool<String>(size: 4);
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

## 5. CPU Offloading (`concurrent.compute`)

Dart's async pool interleaves tasks on the main isolate, which is ideal for IO-bound work. For CPU-bound tasks (hashing large files, image processing, complex parsing), offload to a background isolate with `concurrent.compute`:

```dart
final hash = await concurrent.compute((data) {
  // Runs in a background isolate via Isolate.run
  return heavyComputation(data);
}, inputData);
```

---

## 6. Retries (`concurrent.retry`)

Retries an asynchronous operation on failure with exponential backoff:

```dart
final data = await concurrent.retry(
  () => fetchFromFlakyService(),
  retries: 3,
  backoff: 500.ms,
  onretry: (err, attempt) => log.warn('Attempt $attempt failed: $err'),
);
```

---

## 7. Synchronization Primitives (`Semaphore` & `Mutex`)

Control access to shared resources, or serialise a critical section:

```dart
// Mutex: strictly one caller at a time
final mutex = Mutex();
await mutex.protect(() async {
  // critical section
});

// Semaphore: allow up to N simultaneous holders
final sem = Semaphore(3);
await sem.acquire();
try {
  // up to 3 concurrent tasks
} finally {
  sem.release();
}
```

### How often, not how many (`concurrent.rate`)

`Semaphore` and `Mutex` bound **how many at once**. A published API limit bounds
**how often** — *5000 requests per hour*, *10 per second*, *60 per minute* — and
a `Semaphore(4)` satisfies none of them: four instant requests then four more is
eight in a second, so the script works until the day the network is fast.

```dart
final limit = concurrent.rate(10, per: 1.s);       // a Limiter

await limit.take();                                 // waits for a token
await limit.guard(() => net.http.get(url));         // the wrapped form
```

`guard` mirrors `Semaphore.withPermit` and `Mutex.protect` — every limiter here
has a bare pair and a wrapping form, and the wrapping form is the one callers
should use. The reason it lives in this domain is that it composes with the
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

## 8. A Reusable Pool

Construct a `Pool<I>` when you want lifecycle hooks:

```dart
final pool = Pool<String>(size: 4, delay: 100.ms);
final bar = Progress(total: urls.length, message: 'Fetching');

pool.on.start(() => log.info('pool started'));
pool.on.progress((url) => bar.tick(1, url));   // url is typed as String
pool.on.done(() => bar.done('complete'));

final pages = await pool.run(urls, fetch);
```

| Hook | Fires |
| :--- | :--- |
| `on.start` | Once, before the first task |
| `on.progress` | After each task succeeds |
| `on.done` | Once, after every task settles |
| `on.error` | On a task failure (and switches the failure mode) |

