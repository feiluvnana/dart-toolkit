# 07: Process & Shell

Subprocess execution, output capture, and piping.

---

## 1. Run

```dart
// Run and get output text
final out = await Process.run('git', ['status']).text();

// Check exit code and errors
final res = await Process.run('cargo', ['build']);
if (res.ok) {
  print(res.out);
} else {
  print(res.err);
}
```

---

## 2. Process Pipelines (`pipe`)

Processes implement `Reader` (stdout) and `Writer` (stdin):

```dart
// Pipe stdout of one process to stdin of another
final p1 = Process('cat', ['data.log']);
final p2 = Process('grep', ['ERROR']);

await p1.pipe(p2);
print(await p2.text());
```

---

## 3. Realtime Line Streaming

```dart
final proc = Process('ping', ['8.8.8.8']);

await for (final line in proc.lines()) {
  print(line);
}
```

---

## 4. Advanced Use Cases

### 4.1 Interactive Subprocess (REPL / Shell Communication)
Write dynamically to process stdin and read back results:

```dart
final sh = Process('python', ['-i']);

// Write python commands to stdin
await sh.write('print(2 ** 10)\n');

// Read response
final result = await sh.line(); // '1024'

await sh.write('exit()\n');
await sh.wait();
```

### 4.2 Multi-Stage Shell Pipeline directly to File
Equivalent to `cat input.txt | tr 'a-z' 'A-Z' | sort > output.txt`:

```dart
final p1 = Process('cat', ['input.txt']);
final p2 = Process('tr', ['a-z', 'A-Z']);
final p3 = Process('sort');

await p1.pipe(p2);
await p2.pipe(p3);
await p3.pipe(File('output.txt'));
```

### 4.3 Process Timeout with Process Tree Termination
Kill stuck subprocesses and all their child processes cleanly:

```dart
final proc = Process('sleep', ['60']);

try {
  await proc.wait(timeout: const Duration(seconds: 3));
} on TimeoutException {
  await proc.kill(); // sends SIGTERM, followed by SIGKILL if needed
}
```
