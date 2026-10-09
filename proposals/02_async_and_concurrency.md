# Module Proposal 02: Async & Concurrency (`lib/async.dart`, `lib/core.dart`)

## 1. Overview & Vision

The Async & Concurrency module provides bounded parallel execution over collections and streams (`Batch`, `batch`), single observable units of work (`Task`), persistent isolate worker pools and durable job queues (`Pool`, `Job`, `Store`), ambient scoped cancellation (`Cancel.scope`), and virtual time coordination (`Clock`, `Semaphore`).

### Batch vs Pool: Key Architectural Differences

| Dimension | `Batch<I, T>` (`lib/core.dart`) | `Pool<I, T>` (`lib/async.dart`) |
|---|---|---|
| **Role & Lifespan** | **Ephemeral bounded transformation**. Exists for the duration of processing a collection or stream. | **Persistent worker service**. Stays alive across multiple operations until explicitly closed (`pool.close()`). |
| **Return Type** | Implements `Future<List<T>>` directly (can be awaited or observed via `.progress` / `.values`). | Returns `Job<I, T>` (which implements `Task<T>`) for individual work, or `Batch` from `pool.map()`. |
| **Worker State & Setup** | Stateless work functions per item. | Stateful `Worker` class with one-time `init(Work setup)` per isolate (e.g. launching Chrome, DB connections). |
| **Persistence & Detached Work** | In-memory only. | Supports backing `Store` (e.g. disk folder) for persistent jobs that survive process restarts, plus detached background execution. |

### Core Problems in the Existing API
1. **Discoverability & Method Naming**: `items.parallelize(worker)` uses esoteric terminology; `.batch(worker)` cleanly reflects the `Batch` return type.
2. **Presentation Coupling**: Prior APIs interwove console progress rendering (`show: '...'`, `.show()`) directly into execution primitives instead of letting returned objects expose observable state (`.progress`, `.statuses`).
3. **Parameter Threading vs Ambient Cancellation**: Passing cancellation tokens through method parameters clutters signatures compared to ambient Zone-scoped cancellation (`Cancel.scope`).
4. **Task Simplification**: Tasks should remain simple, standalone units of observable work with deferred cleanups and progress hooks without over-engineered transformation pipelines.

---

## 2. Detailed Before vs After Comparison

### 2.1 Parallel Execution & Batch Progress (`.batch`)

#### Before:
```dart
// Bounded parallel execution over a list with coupled terminal display
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
// 1. Direct .batch extension on Iterable returning Batch<I, T> (implements Future<List<T>>)
final batch = urls.batch(
  (u) => u.download(to: dir / u.name),
  concurrency: 4,
);

// Await directly to get the full List<File> once completed
final files = await batch;

// Or read progress dynamically directly from the returned batch object
batch.progress.listen((p) {
  print('Progress: ${p.completed}/${p.total} (${(p.fraction * 100).toInt()}%)');
});

// Or consume values as each individual item finishes
await for (final file in batch.values) {
  indexFile(file);
}

// 2. Direct .batch extension on Stream
await inputStream
    .batch((chunk) => process(chunk), concurrency: 8)
    .pipe(output);

// 3. Parallel execution offloaded to background isolates
final processed = await heavyItems.batch(
  (item) => computeHeavy(item),
  concurrency: 8,
  isolate: true, // Automatically manages background isolate workers
);
```

---

### 2.2 Task: Observable Unit of Work & Deferred Cleanup

#### Before:
```dart
// Task creation with coupled terminal display
final task = Task.run('Render', (work) async {
  final chrome = await Chrome.launch();
  work.defer(chrome.close);
  work.step('rendering');
  return render(chrome);
});
final result = await task.show('Rendering PDF');
```

#### After (Proposed):
```dart
// Refined Task API: pure async unit of work with clean progress and status observation
final task = Task.run('Render', (work) async {
  final chrome = await Chrome.launch();
  work.defer(chrome.close); // Guaranteed cleanup regardless of completion, failure, or cancellation
  
  work.step('launching browser');
  work.amount(10, total: 100);
  
  return render(chrome);
});

// 1. Await value directly (implements Future<T>)
final pdf = await task;

// 2. Or observe status events and settled outcomes without throwing
task.statuses.listen((s) => print('Status update: $s'));

switch (await task.settled) {
  case Done(:final value): print('Success: $value');
  case Failed(:final error): print('Error: $error');
  case Stopped(): print('Cancelled');
}
```

---

### 2.3 Task & Job Persistence (`Store`, `Job`, `detached`)

#### Before:
```dart
// Ephemeral in-memory task lost on process termination
final task = Task.run('Heavy Job', (w) => process(data));
```

#### After (Proposed):
```dart
// Persistent Pool backed by a Store for persistent tasks (Job<I, T> implements Task<T>)
final pool = Pool(
  ThumbnailWorker.new,
  concurrency: 4,
  isolate: true,
  store: Store.folder('.toolkit/jobs'), // Jobs persist to disk across restarts
);

// 1. Submit a job — returned Job<I, T> is an observable, controllable Task<T>
final job = pool.add(imagePath);
job.pause();
job.resume();
final thumb = await job; // Await just like any standard Task<T>

// 2. Detached job: runs in a background daemon runner process and outlives this CLI invocation
final detachedJob = pool.add(largeFile, detached: true);

// 3. Automatic recovery: unfinished jobs resume automatically on the next program run
```

---

### 2.4 Ambient Scoped Cancellation (`Cancel.scope`)

#### Before:
```dart
// Manual token passing through every function parameter
final token = CancelToken();
final result = await doWork(token);
```

#### After (Proposed):
```dart
// Cancellation is injected ambiently via Zone scope — zero parameter plumbing in methods
final token = CancelToken();

await Cancel.scope(() async {
  // .batch, Task, and HTTP requests inside automatically cooperate with the ambient scope
  final files = await urls.batch((u) => u.download(to: dir / u.name), concurrency: 4);
  process(files);
}, token: token, timeout: 30.s);

// Trigger cancellation from any caller or event handler
token.cancel('User requested cancellation');
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Parallel Mapping** | `items.parallelize(...)` | `items.batch(...)` | Intuitive naming aligning with `Batch` return type |
| **Progress Inspection** | Coupled UI parameter (`show:`) | Observable `.progress` stream on returned `Batch` | Clean separation; UI or metrics inspect progress without callbacks |
| **Cancellation Model** | Parameter passing through every layer | Ambient `Cancel.scope` | Zero parameter pollution; automatic propagation across async zones |
| **Task Model** | Coupled `.show()` display | Refined `Task.run` with pure `statuses` & `settled` | Simple, predictable unit of work with guaranteed deferred cleanup |
| **Task Persistence** | Ambiguous persistence model | `Pool` + `Store` + `Job` (`Job implements Task`) | Durable job queues with pause/resume and detached daemon execution |
| **Pool vs Batch** | Ambiguous overlap | Clear separation: `Batch` for ephemeral mapping, `Pool` for persistent workers | Proper architectural alignment for memory & isolates |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- **Scoped vs Parameterized Cancellation**: Cancellation is managed via ambient `Cancel.scope` rather than threading a `CancelToken` parameter through every function signature.
  - *Mitigation*: Ambient cancellation cleanly separates control flow from business logic, ensuring all nested async work stops cooperatively on cancellation or timeout.
- **Batch Object Duality**: `.batch` returns a `Batch<I, T>` object which implements `Future<List<T>>`.
  - *Mitigation*: Callers can directly `await` the result as a standard `Future<List<T>>`, or retain the `Batch` reference to listen to `.progress` or stream `.values`.

### Backward Compatibility:
- 100% backward compatible. All existing code using `Task`, `Batch`, `Batch.merge`, `parallelize`, `Pool`, `Worker`, `Job`, `Store`, `CancelToken`, `Cancel.scope`, `Clock`, and `Semaphore` continues to work without changes.
