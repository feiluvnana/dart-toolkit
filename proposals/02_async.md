# 02: Async & Concurrency

Minimalist concurrency: `Task`, `Pool`, and `Chan`.

---

## 1. Concurrency Primitives

### 1.1 `Task`: On-Demand Background Work
Spawns background isolates with automatic error capture and timeouts:

```dart
// Run heavy CPU work in background isolate
final hash = await Task.run(() => calcHash(largeBuffer));

// Run with strict timeout
final res = await Task.run(() => slowTask(), timeout: const Duration(seconds: 5));

// Run multiple tasks concurrently
final results = await Task.all([
  () => fetch(1),
  () => fetch(2),
]);
```

### 1.2 `Pool`: Fixed Worker Pool
Reuses persistent background isolates for high-throughput batch workloads, avoiding the overhead of spawning new isolates per task:

```dart
final pool = Pool(4); // 4 persistent worker isolates

for (final file in files) {
  pool.run(() => compressFile(file));
}

await pool.wait(); // wait for all queued tasks to finish
await pool.close();
```

---

## 2. Why `Chan` (Channels) Are Useful

In Dart, raw streams have significant shortcomings when coordinating background workers:
1. **Backpressure & Bounded Buffering**: Unbounded streams or task queues consume unbounded RAM. If a network worker downloads 1,000 files faster than disk can write, the program crashes with Out-Of-Memory (OOM). A `Chan(cap: 50)` automatically suspends the producer when 50 items are queued until the consumer reads.
2. **Fan-In (Multi-Producer, Single-Consumer)**: Multiple worker isolates can hold references to the same `Chan` sender and stream items into a single consumer isolate (e.g. 8 scraper threads pushing results into 1 database writer).
3. **Deterministic Completion**: Calling `chan.close()` cleanly signals EOF across threads. The consumer's `await for` terminates naturally without manual booleans or leaked subscriptions.

```dart
final chan = Chan<Record>(cap: 100);

// Multiple worker producers send to the same channel
pool.run(() async {
  await chan.send(Record(1));
});
pool.run(() async {
  await chan.send(Record(2));
});

// Single consumer reads cleanly
await for (final rec in chan.recv()) {
  await db.write(rec);
}
```

---

## 3. Advanced Use Cases

### 3.1 Long-Running Background Daemon
Running a persistent background service with heartbeat and graceful shutdown:

```dart
// Start daemon isolate
final daemon = Task.bg((cancel) async {
  while (!cancel.isDone) {
    await syncStateWithServer();
    await Future.delayed(const Duration(seconds: 30));
  }
});

// Graceful shutdown on app exit
await daemon.cancel();
```

### 3.2 End-to-End Web Crawler Pipeline
A production-grade web crawler combining `Pool`, `Chan`, `Http`, `Html`, and `File`:

```dart
void crawl(String seedUrl, {int workers = 6, int maxPages = 50}) async {
  final queue = Chan<String>(cap: 100);
  final out   = Chan<PageData>(cap: 50);
  final pool  = Pool(workers);
  final seen  = <String>{};

  // Seed initial URL
  seen.add(seedUrl);
  await queue.send(seedUrl);

  // Dedicated single-consumer writer (preserves disk I/O order, zero race conditions)
  final writerTask = Task.run(() async {
    final file = File('results.jsonl');
    await for (final page in out.recv()) {
      await file.write('${Json.dump(page)}\n', append: true);
    }
  });

  // Worker loop
  var active = 0;
  await for (final url in queue.recv()) {
    active++;
    pool.run(() async {
      try {
        final doc = await Http.get(url).html();
        final title = doc.find('title')?.text ?? '';
        
        await out.send(PageData(url: url, title: title));

        // Discover and enqueue new links
        for (final a in doc.all('a[href]')) {
          final next = a.attr('href')!;
          if (next.startsWith('https://') && seen.add(next) && seen.length < maxPages) {
            await queue.send(next);
          }
        }
      } finally {
        active--;
        if (active == 0 && queue.isEmpty) {
          await queue.close();
          await out.close();
        }
      }
    });
  }

  await pool.wait();
  await writerTask;
  print('Crawl complete. Scraped ${seen.length} pages.');
}
```
