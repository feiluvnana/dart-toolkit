# Module Proposal 08: Process & System Shell (`lib/process.dart`)

## 1. Overview & Vision

The Process & Shell module provides robust subprocess execution, atomic piping between commands, live line streaming, graceful SIGTERM/SIGKILL lifecycle control, and scoped environment isolation (`Shell.scope`).

### Core Problems in the Existing API
1. **Verbose Execution Boilerplate**: Running a simple shell command and extracting trimmed stdout requires `final res = await Shell.run('command'); final text = res.text.trim();`.
2. **Missing Pipe Operators**: Connecting stdout of one subprocess to stdin of another currently requires manual stream piping.
3. **Line-Streaming Complexity**: Consuming live output without blocking the event loop requires manual `LineSplitter` transforms and error handling.

---

## 2. Detailed Before vs After Comparison

### 2.1 String Command Runners

#### Before:
```dart
final branchRes = await Shell.run('git rev-parse --abbrev-ref HEAD');
final branch = branchRes.text.trim();

final checkRes = await Shell.run('git diff --quiet');
final isClean = checkRes.isOk;

final logLinesRes = await Shell.run('git log --oneline -n 5');
final lines = logLinesRes.lines;
```

#### After (Proposed):
```dart
// 1. Direct string execution extensions
final branch  = await 'git rev-parse --abbrev-ref HEAD'.runText();
final isClean = await 'git diff --quiet'.runOk();
final lines   = await 'git log --oneline -n 5'.runLines();

// 2. String interpolation with automatic shell escaping
final target = 'My Project Folder';
final size   = await 'du -sh ${target.shellEscape}'.runText();
```

---

### 2.2 Command Piping with Operator `|`

#### Before:
```dart
// Manual multi-process stdin/stdout piping
```

#### After (Proposed):
```dart
// UNIX-style pipe operator composition
final pipeline = cmd('cat access.log') | cmd('grep "404"') | cmd('wc -l');
final count = await pipeline.runText();

// Pipe directly to a file
await (cmd('docker logs app') | cmd('grep ERROR')).save('error.log');
```

---

### 2.3 Live Line Streaming & Real-Time Output

#### Before:
```dart
final run = Shell.run('tail -f /var/log/syslog');
await for (final line in run.output) {
  print('Log: $line');
}
```

#### After (Proposed):
```dart
// Live line iterator directly on Command
await for (final line in cmd('tail -f /var/log/syslog').lines) {
  Console.info('Syslog: $line');
}

// Live command with real-time stderr/stdout echo
await cmd('dart compile exe bin/main.dart -o build/app').echo();
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Quick Scripts** | `Shell.run('...').text` | `'...'.runText()`, `'...'.runOk()` | **-60% lines of code** |
| **Pipeline Composition** | Manual streams | `cmd1 \| cmd2 \| cmd3` | Standard, intuitive UNIX ergonomics |
| **Live Logs** | Low-level `run.output` | `cmd('...').lines` | Clean async generator consumption |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- Running raw strings with `'cmd'.runText()` parses arguments using shell tokenization.
  - *Recommendation*: For inputs with untrusted user strings, use `cmd('executable', [arg1, arg2])` to prevent shell injection.

### Backward Compatibility:
- 100% backward compatible. All existing `Shell.run`, `Command`, `Run`, `ShellResult`, and `Shell.scope` APIs remain unchanged.
