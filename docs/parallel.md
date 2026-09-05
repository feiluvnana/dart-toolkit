# Concurrency & Parallelism Subsystem (`concurrent.*`)

The `concurrent` namespace in **Dart Script Toolkit** provides bounded asynchronous task scheduling, concurrent collection mapping, and progress-tracking task pools.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final urls = [
    'https://api.example.com/v1/user/1',
    'https://api.example.com/v1/user/2',
    'https://api.example.com/v1/user/3',
  ];

  // 1. Concurrently process tasks with concurrency limit
  final results = await concurrent.run(urls, (url) async {
    final res = await net.get(url);
    return res.json;
  }, size: 2);

  util.console.logger.ok('Fetched ${results.length} records.');
}
```

---

## 1. Quick Concurrency Helpers

### `concurrent.run<T, R>(items, worker, {size = 4, delay = Duration.zero})`
Runs an async worker over items with a concurrency pool and returns results in original order:

```dart
final processed = await concurrent.run(items, (item) async {
  return await processHeavyTask(item);
}, size: 8);
```

---

## 2. Dedicated Task Pool (`concurrent.pool()`)

For workflows that require lifecycle events, progress hooks, or dynamic rate-limiting delay:

```dart
final pool = concurrent.pool(4);
final bar = util.console.bar(tasks.length, 'Executing');

// Register lifecycle hooks
pool.on.start(() => util.console.logger.info('Worker pool started'));
pool.on.progress((task) => bar.tick(1, task.toString()));
pool.on.done(() => bar.done('All tasks completed!'));
pool.on.error((err, task) => util.console.logger.fail('Task failed: $err'));

await pool.run(tasks, (t) async {
  await executeTask(t);
});
```
