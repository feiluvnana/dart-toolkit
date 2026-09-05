# Process, Signals & System Subsystem (`system.*`)

The `system` namespace in **Dart Script Toolkit** manages external process execution, POSIX and Windows signal handling (`SIGINT`, `SIGTERM`), graceful exit hooks, execution benchmarks, and system environment variables.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Listen for Ctrl+C and register automatic cleanup
  system.listen();
  system.on.exit(() => util.console.logger.info('Cleaning up temp resources...'));

  // 2. Track temporary files for deletion if aborted
  system.track('output/temp.bin');

  // 3. Measure elapsed execution time
  final clock = system.clock();

  // 4. Run external CLI tools
  final result = await system.run('git', ['status', '--short']);
  print(result.output);

  clock.stop();
  util.console.logger.ok('Finished in ${io.time(clock.elapsed)}');
  system.unlisten();
}
```

---

## 1. Subprocess Execution (`system.run()`)

Executes an external binary, captures stdout/stderr, and returns a `SysResult`:

```dart
final res = await system.run('7z', ['a', 'out.7z', 'data/'], echo: true);

if (res.ok) {
  util.console.logger.ok('Command succeeded with code ${res.code}');
} else {
  util.console.logger.error('Command failed: ${res.err}');
}
```

### Options:
- `cwd`: Specify working directory.
- `echo`: Print command before running.
- `inherit`: Stream output directly to current terminal process.
- `timeout`: Execution timeout duration (`Duration`).

---

## 2. Signal Handling & Graceful Exit

### `system.listen()` & `system.unlisten()`
Binds signal listeners for `SIGINT` (Ctrl+C) and `SIGTERM`. When received:
1. Executes all registered exit hooks in reverse order.
2. Automatically deletes all files registered via `system.track(file)`.
3. Restores cursor and exits cleanly.

Call `system.unlisten()` when your automation workflow finishes cleanly to release background signal watchers and let the process terminate normally.

```dart
system.listen();

system.hook(() {
  util.console.logger.info('Custom cleanup routine executing...');
});
```

### `system.track(filePath)` & `system.untrack(filePath)`
Registers files to be automatically deleted if the script aborts mid-execution:

```dart
system.track('temp/download.part');
// ... perform work ...
system.untrack('temp/download.part'); // Remove once safely finalized
```

---

## 3. Utilities

- `system.which(tool)`: Finds executable path in system `PATH` (`dart`, `git`, `7z`).
- `system.clock()`: Starts a benchmark stopwatch.
- `system.env(key)`: Retrieves environment variable (or use `system.env.get()`).
- `system.exit([code = 0])`: Runs registered hooks and terminates process.
- `system.now([code = 0])`: Immediate process termination without hooks.
- `system.win`, `system.mac`, `system.nix`: Platform detection boolean predicates.
