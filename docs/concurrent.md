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
    (url) async => (await net.http.get(url)).json,
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

`settle` executes tasks across items and returns every outcome as a `SettledResult<R>`, whether it succeeded or failed:

```dart
final pool = Pool<int>(size: 2);
final outcomes = await pool.settle([1, 0, 2], (n) async {
  if (n == 0) throw Exception('Division by zero');
  return 10 ~/ n;
});

for (final res in outcomes) {
  if (res.ok) {
    print('Value: ${res.value}');
  } else {
    print('Failed: ${res.error}');
  }
}
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
} on PoolFailure<String> catch (e) {
  log.error('${e.failures.length} of ${urls.length} failed');
  for (final f in e.failures) log.debug('${f.item}: ${f.error}');
  print('Successful results: ${e.results.whereType<String>().length}');
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

Control access to shared resources or rate-limit critical sections:

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

