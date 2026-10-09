# Module Proposal 02: Async & Concurrency (`lib/async.dart`, `lib/core.dart`)

## 1. Overview & Vision

The Async & Concurrency module provides bounded parallel execution (`Batch`, `parallelize`), single units of work (`Task`), persistent isolate worker pools (`Pool`, `Worker`), resilient execution (`Retry`), cancellation tokens (`Cancel`), and virtual time coordination (`Clock`, `Semaphore`).

### Core Problems in the Existing API
1. **Discoverability of Parallel Mapping**: `items.parallelize(worker)` is powerful but uses terminology unfamiliar to developers expecting `mapParallel` or `forEachParallel`.
2. **Verbose Retry Setup**: Retrying an async operation requires instantiating a `Retry` policy object and passing a callback (`Retry(3).run(() => ...)`).
3. **Pipeline Chaining**: Chaining transformations on batches (`.progress()`, `.values`, `.settled`) can become convoluted when mixing stream and list semantics.
4. **Isolate Worker Pool Creation**: Setting up a persistent background isolate pool requires extensive multi-class ceremony.

---

## 2. Detailed Before vs After Comparison

### 2.1 Parallel Mapping over Collections & Streams

#### Before:
```dart
// Bounded parallel execution over a list
final batch = urls.parallelize((u) => u.download(to: dir / u.name), concurrency: 4);
final files = await batch.show('Downloading');

// Stream parallel execution
final streamBatch = inputStream.parallelize((chunk) => process(chunk), concurrency: 8);
await for (final item in streamBatch.values) {
  output.add(item);
}
```

#### After (Proposed):
```dart
// 1. Direct mapParallel extension on Iterable
final files = await urls.mapParallel(
  (u) => u.download(to: dir / u.name),
  concurrency: 4,
  show: 'Downloading', // Automatically integrates with live terminal progress
);

// 2. Parallel forEach on Iterable
await urls.forEachParallel((u) => u.download(to: dir / u.name), concurrency: 4);

// 3. Direct mapParallel extension on Stream
await inputStream
    .mapParallel((chunk) => process(chunk), concurrency: 8)
    .pipe(output);

// 4. Parallel execution on worker isolates
final processed = await heavyItems.mapParallel(
  (item) => computeHeavy(item),
  concurrency: 8,
  isolate: true, // Automatically spawns isolate worker pool
  show: 'Processing on 8 Isolates',
);
```

---

### 2.2 Functional Retry with Exponential Backoff

#### Before:
```dart
final retryPolicy = Retry(3, backoff: Duration(seconds: 1));
try {
  final res = await retryPolicy.run(() => fetch());
} catch (e) {
  print('Failed after retries: $e');
}
```

#### After (Proposed):
```dart
// 1. Top-level retry helper with full exponential backoff and filters
final res = await retry(
  () => fetch(),
  attempts: 4,
  delay: 500.ms,
  backoff: 2.0, // 500ms -> 1s -> 2s -> 4s
  maxDelay: 10.s,
  retryIf: (e) => e is TimeoutException || e is SocketException,
  onRetry: (attempt, err) => Console.warn('Attempt $attempt failed: $err. Retrying...'),
);

// 2. Extension method directly on any Future<T>
final data = await fetch().retry(attempts: 3, delay: 1.s);
```

##### Visual Look (Live Output during Retries):
```text
⚠ Attempt 1 failed: SocketException: OS Error 111. Retrying in 500ms...
⚠ Attempt 2 failed: SocketException: OS Error 111. Retrying in 1.0s...
✓ Fetch completed (1.6s)
```

---

### 2.3 Task Transformation Pipeline & Fallbacks

#### Before:
```dart
final task = Task.run('Fetch', (w) => fetch());
final result = await task.settled;
final value = switch (result) {
  Done(:final value) => value,
  _ => 'fallback',
};
```

#### After (Proposed):
```dart
// Fluent chaining on Task<T>
final task = Task.run('Fetch', (w) => fetch())
    .map((data) => parse(data))
    .timeout(5.s)
    .retry(attempts: 3)
    .fallback('default_value');

final finalValue = await task.show('Fetching Configuration');
```

---

### 2.4 Isolate Worker Pool

#### Before:
```dart
// Complex manual worker and pool configuration
final pool = Pool(worker: () => Worker(...), size: 4);
```

#### After (Proposed):
```dart
// Clean, declarative pool creation and execution
final pool = WorkerPool(size: 4);
final result1 = await pool.run(() => heavyMath(100));
final result2 = await pool.run(() => heavyMath(200));
await pool.close();
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Parallel Mapping** | `items.parallelize(...)` | `items.mapParallel(...)`, `forEachParallel(...)` | Immediately recognizable, zero learning curve |
| **Retry Strategy** | Verbose class instantiation | Functional `retry(...)` + `.retry()` extension | Single-expression resilience |
| **Error Handling** | Manual `settled` matching | Fluent `.fallback(...)`, `.recover(...)` | Safe fallback values without `try/catch` |
| **Isolate Dispatch** | Boilerplate worker management | `isolate: true` flag in `mapParallel` | Automatic background isolate scaling |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- **`mapParallel` vs `parallelize` Naming**: `mapParallel` returns a `Batch<I, T>` which implements `Future<List<T>>`. Calling `mapParallel` implies a direct transformation like `map()`.
  - *Mitigation*: Both `parallelize` and `mapParallel` point to the same underlying high-performance `Batch` engine.

### Backward Compatibility:
- 100% backward compatible. All existing code using `Task`, `Batch`, `Batch.merge`, `Tally`, `Retry`, `Cancel`, `Clock`, and `Semaphore` continues to work without changes.
