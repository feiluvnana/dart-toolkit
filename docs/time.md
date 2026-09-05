# Time & Delays Subsystem (`util.time.*`)

The `util.time` sub-namespace in **Dart Script Toolkit** provides ergonomic duration delays, filename-safe timestamp generation, ISO formatting, relative time calculation, epoch timestamps, and benchmark stopwatches.

All methods strictly adhere to the **1-word method naming convention**.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Ergonomic async delay with number of milliseconds or Duration
  await util.time.wait(500); // 500 ms
  await util.time.wait(const Duration(seconds: 1));

  // 2. Safe timestamp for filenames (YYYYMMDD_HHMMSS)
  final logFile = 'logs/backup_${util.time.stamp()}.log';

  // 3. Human-readable relative time ("2m ago", "15s ago")
  final start = DateTime.now().subtract(const Duration(minutes: 5));
  print('Created: ${util.time.ago(start)}'); // "5m ago"

  // 4. Benchmark execution stopwatch
  final clock = util.time.clock();
  await util.time.wait(100);
  print('Elapsed: ${clock.elapsedMilliseconds} ms');
}
```

---

## 1. Ergonomic Delays (`util.time.wait` / `util.time.sleep`)

### `util.time.wait(durationOrMs)`
Asynchronously pauses execution without blocking the event loop. Accepts either a `Duration` or an integer number of milliseconds:
```dart
await util.time.wait(250); // wait 250 milliseconds
await util.time.wait(const Duration(seconds: 2));
```

### `util.time.sleep(milliseconds)`
Synchronously blocks the current thread for the specified duration (backed by `dart:io sleep`). Useful in standalone non-async CLI scripts or synchronous worker loops:
```dart
util.time.sleep(100);
```

---

## 2. Timestamps & Formatting

### `util.time.stamp([date])`
Formats a `DateTime` (defaults to `DateTime.now()`) into a safe, sortable timestamp string format `YYYYMMDD_HHMMSS`, ideal for log files, archives, and database snapshots:
```dart
final name = 'dump_${util.time.stamp()}.json'; // e.g. "dump_20260905_205012.json"
```

### `util.time.iso([date])`
Returns a UTC ISO-8601 representation:
```dart
final isoStr = util.time.iso(); // "2026-09-05T13:50:12.000Z"
```

### `util.time.ago(past, [relativeTo])`
Calculates a human-friendly relative time string from `past` relative to `now`:
- `< 5s` &rarr; `"just now"`
- `< 60s` &rarr; `"15s ago"`
- `< 60m` &rarr; `"4m ago"`
- `< 24h` &rarr; `"3h ago"`
- `< 30d` &rarr; `"5d ago"`
- `< 365d` &rarr; `"2mo ago"`
- `> 365d` &rarr; `"1y ago"`

```dart
final published = DateTime.parse('2026-09-05T12:00:00Z');
print('Published: ${util.time.ago(published)}');
```

---

## 3. Clock & Epoch

| Method | Return Type | Description |
| :--- | :--- | :--- |
| `util.time.now()` | `DateTime` | Shortcut for `DateTime.now()`. |
| `util.time.epoch([date])` | `int` | Returns unix epoch milliseconds since 1970 (`millisecondsSinceEpoch`). |
| `util.time.clock()` | `Stopwatch` | Instantiates and immediately starts a new `Stopwatch` benchmark timer. |

### Example
```dart
final clock = util.time.clock();
// Perform heavy task...
print('Finished in ${clock.elapsedMilliseconds}ms');
```
