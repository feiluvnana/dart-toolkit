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

```dart no-compile
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

The question a script usually asks is a boolean:

```dart
system.windows;   // Windows
system.macos;     // macOS
system.linux;     // Linux
```

`system.os` is the rest of it — one record rather than five loose members,
because it is one struct's worth of facts and reading two of them should not
mean two accessors:

```dart
final machine = system.os;

machine.name;    // 'macos', 'linux', 'windows', 'android', 'ios', 'fuchsia'
machine.cpus;    // the core count
machine.host;    // the hostname, '' when the platform will not say
machine.user;    // $USER / %USERNAME%, '' when unset
```

`cpus` is the honest default for a pool size, where examples otherwise hardcode
four:

```dart
await concurrent.run(urls, fetch, size: system.os.cpus);
```

The paths half — `io.dir.home`, `io.dir.cwd`, `io.expand` — is in
[`io`](io.md#4-paths), because a path is a filesystem fact.

---

## 4. Crash-Safe Shutdown

Every atomic write registers its `.part` staging file, so Ctrl-C removes half-written files instead of leaving them behind. Child processes started through `system.run` are registered too, and are killed.

You rarely need to touch this, but the controls are there:

```dart
system.on.track(file);        // delete this file if interrupted
system.on.untrack(file);
system.on.adopt(process);     // kill this process if interrupted
system.on.disown(process);
system.on.signals();          // start listening for SIGINT/SIGTERM
system.on.stop();             // and stop
system.on.exit(() async => db.dump('out/state.json'));   // run during shutdown

await system.shutdown();      // run cleanup now
await system.shutdown(1);     // run cleanup, then exit with a code
system.exit(1);               // exit immediately, skipping cleanup
```

Six of those seven sat flat on `system` through 4.0.0 — `system.track`,
`system.watch`, and the rest — while `system.on` held only `exit`. Rule 3 says
a sub-namespace is for a cohesive vocabulary with its own nouns, and *what
happens to your resources when the program is interrupted* is that vocabulary;
the structure was inverted. Moving them in also freed the word `watch`, which
[`io.watch`](io.md#6-watching-iowatch) had been going without.

### Why your script exits

Tracking a resource installs a `SIGINT` and `SIGTERM` watcher — Ctrl-C and `kill` both run the cleanup — and a live watcher keeps the Dart isolate alive. The watcher is **released automatically** once nothing is tracked, so a script that finishes its work exits on its own:

```dart
void main() async {
  io.write('out.txt', 'done');
  // exits normally — no manual cleanup needed
}
```

The one exception is `system.on.exit`: a registered hook stays pending, and so keeps the process alive, until `system.shutdown()` runs it. Either call `system.shutdown()` at the end, or use `system.on.stop()` to drop the watcher.

---

## See Also

- [`cli.*`](cli.md) — argument parsing
- [`system.env.*`](env.md) — environment variables
- [`format.*`](json.md) — file formats; an executable is `system.run`, not a wrapper
- [`io.*`](io.md#4-paths) — `io.dir.home`, `io.dir.cwd` and `io.expand`
