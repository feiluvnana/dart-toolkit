# Subprocesses & Shutdown (`system.*`)

Subprocess execution, executable lookup, platform predicates, and crash-safe cleanup of partial files and child processes.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  final ffmpeg = system.which('ffmpeg');
  if (ffmpeg == null) {
    system.console.logger.error('ffmpeg not found on PATH');
    return;
  }

  final res = await system.run(ffmpeg, ['-i', 'in.mp4', 'out.mp3'], echo: true);
  if (!res.ok) system.console.logger.error('exit ${res.code}: ${res.err}');
}
```

---

## 1. Running Commands

```dart
Future<SysResult> system.run(
  String executable,
  List<String> arguments, {
  String? cwd,
  bool inherit = false,
  bool echo = false,
  Duration? timeout,
  void Function(String line)? out,
  void Function(String line)? err,
})
```

`SysResult` carries `code`, `out`, `err` and `ok` (`code == 0`).

```dart
final res = await system.run('git', ['status', '--short']);
if (res.ok) print(res.out);
```

| Option | Effect |
| :--- | :--- |
| `cwd` | Working directory |
| `inherit` | Stream output straight to the terminal; `out`/`err` come back empty |
| `echo` | Print the command line before running it |
| `timeout` | Kill the process; the result carries code `-1` |
| `out` / `err` | Receive each captured line as it arrives |

Use `inherit` for tools that render their own progress, and `out`/`err` when you want both capture and live feedback:

```dart
await system.run('npm', ['install'], out: (line) => log.debug(line));
```

---

## 2. Finding Executables

```dart
system.which('dart');                                    // searches PATH
system.which('7z', paths: [r'C:\Program Files\7-Zip\7z.exe']);
```

`paths` is checked first, then an absolute name as given, then every `PATH` entry. On Windows the `.exe`, `.cmd` and `.bat` extensions are tried for each candidate. Returns `null` when nothing matches.

---

## 3. Platform

```dart
system.windows;   // Windows
system.macos;   // macOS
system.linux;   // Linux
```

---

## 4. Crash-Safe Shutdown

Every atomic write registers its `.part` staging file, so Ctrl-C removes half-written files instead of leaving them behind. Child processes started through `system.run` are registered too, and are killed.

You rarely need to touch this, but the controls are there:

```dart
system.track(file);      // delete this file if interrupted
system.untrack(file);
system.adopt(process);    // kill this process if interrupted
system.disown(process);

system.on.exit(() async => await db.save()); // run during shutdown

await system.shutdown();      // run cleanup now
await system.shutdown(1);     // run cleanup, then exit with a code
system.exit(1);          // exit immediately, skipping cleanup
```

### Why your script exits

Tracking a resource installs a `SIGINT` and `SIGTERM` watcher — Ctrl-C and `kill` both run the cleanup — and a live watcher keeps the Dart isolate alive. The watcher is **released automatically** once nothing is tracked, so a script that finishes its work exits on its own:

```dart
void main() async {
  io.write('out.txt', 'done');
  // exits normally — no manual cleanup needed
}
```

The one exception is `system.on.exit`: a registered hook stays pending, and so keeps the process alive, until `system.shutdown()` runs it. Either call `system.shutdown()` at the end, or use `system.unwatch()` to drop the watcher.

---

## See Also

- [`system.cli.*`](cli.md) — argument parsing
- [`system.env.*`](env.md) — environment variables
- [`git.*`](git.md) — git commands, built on `system.run`
