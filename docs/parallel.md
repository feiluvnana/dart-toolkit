# Concurrency & Parallelism Subsystem (`parallel.*`)

The `parallel` namespace in **Dart Script Toolkit** provides bounded asynchronous task scheduling, concurrent collection mapping, and progress-tracking task pools.

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
  final results = await parallel.run(urls, (url) async {
    final res = await crawl.get(url);
    return res.json;
  }, size: 2);

  console.logger.ok('Fetched ${results.length} records.');
}
```

---

## 1. Quick Concurrency Helpers

### `parallel.run<T, R>(items, worker, {size = 4})`
Runs an async worker over items with a concurrency pool and returns results in original order:

```dart
final processed = await parallel.run(items, (item) async {
  return await processHeavyTask(item);
}, size: 8);
```

### `parallel.map<T, R>(items, mapper, {size = 4})`
Maps an iterable concurrently:

```dart
final uppercase = await parallel.map(strings, (str) async {
  await Future.delayed(const Duration(milliseconds: 10));
  return str.toUpperCase();
});
```

### `parallel.each<T>(items, worker, {size = 4})`
Fire-and-forget concurrent iteration without collecting return values:

```dart
await parallel.each(files, (file) async {
  await uploadToS3(file);
}, size: 4);
```

---

## 2. Dedicated Task Pool (`parallel.pool()`)

For workflows that require lifecycle events, progress hooks, or dynamic queuing:

```dart
final pool = parallel.pool(4);
final bar = console.bar(tasks.length, 'Executing');

// Register lifecycle hooks
pool.on.start(() => console.logger.info('Worker pool started'));
pool.on.progress((task) => bar.tick(1, task.name));
pool.on.done(() => bar.done('All tasks completed!'));
pool.on.error((err) => console.logger.fail('Task failed: $err'));

await pool.run(tasks, (t) async {
  await executeTask(t);
});
```
