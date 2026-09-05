# Process, Signals & System Subsystem (`sys.*` / `proc.*`)

The `sys` namespace in **Dart Script Toolkit** manages external process execution, POSIX and Windows signal handling (`SIGINT`, `SIGTERM`), graceful exit hooks, execution benchmarks, and system environment variables.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Listen for Ctrl+C and register automatic cleanup
  sys.listen();
  sys.on.exit(() => console.info('Cleaning up temp resources...'));

  // 2. Track temporary files for deletion if aborted
  sys.track('output/temp.bin');

  // 3. Measure elapsed execution time
  final clock = sys.clock();

  // 4. Run external CLI tools
  final result = await sys.run('git', ['status', '--short']);
  print(result.output);

  clock.stop();
  console.ok('Finished in ${fs.time(clock.elapsed)}');
}
```

---

## 1. Subprocess Execution (`sys.run()`)

Executes an external binary, captures stdout/stderr, and returns a `ProcResult`:

```dart
final res = await sys.run('7z', ['a', 'out.7z', 'data/'], echo: true);

if (res.ok) {
  console.ok('Command succeeded with code ${res.code}');
} else {
  console.fail('Command failed: ${res.err}');
}
```

### Options:
- `cwd`: Specify working directory.
- `echo`: Print command before running.
- `inherit`: Stream output directly to current terminal process.

---

## 2. Signal Handling & Graceful Exit

### `sys.listen()`
Binds signal listeners for `SIGINT` (Ctrl+C) and `SIGTERM`. When received:
1. Executes all registered exit hooks in reverse order.
2. Automatically deletes all files registered via `sys.track(file)`.
3. Restores cursor and exits cleanly.

```dart
sys.listen();

sys.hook(() {
  console.info('Custom cleanup routine executing...');
});
```

### `sys.track(filePath)` & `sys.untrack(filePath)`
Registers files to be automatically deleted if the script aborts mid-execution:

```dart
sys.track('temp/download.part');
// ... perform work ...
sys.untrack('temp/download.part'); // Remove once safely finalized
```

---

## 3. Utilities

- `sys.which(tool)`: Finds executable path in system `PATH` (`dart`, `git`, `7z`).
- `sys.clock()`: Starts a benchmark stopwatch.
- `sys.env(key)`: Retrieves environment variable.
- `sys.exit([code = 0])`: Runs registered hooks and terminates process.
- `sys.now([code = 0])`: Immediate process termination without hooks.
