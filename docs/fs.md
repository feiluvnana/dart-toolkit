# File System & Storage Subsystem (`io.*` / `io.file.*`)

The `io` namespace in **Dart Script Toolkit** provides atomic file writes, zero-dependency path manipulation (no `package:path` imports required), streaming downloads, recursive searches, and integrated 7-Zip archiving.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Zero-dependency path operations
  final filePath = io.join('data', 'reports', '2026.json');
  util.console.logger.info('Base: ${io.base(filePath)}'); // 2026.json
  util.console.logger.info('Name: ${io.name(filePath)}'); // 2026
  util.console.logger.info('Ext:  ${io.ext(filePath)}');  // .json
  util.console.logger.info('Dir:  ${io.dir(filePath)}');  // data/reports

  // 2. Atomic file write (.part staging + rename)
  await io.write(filePath, '{"status": "ok"}');

  // 3. Direct streaming download
  await io.download(
    Uri.parse('https://example.com/asset.zip'),
    io.join('downloads', 'asset.zip'),
  );

  // 4. Archive into 7z
  final arc = io.archive('bundle.7z');
  await arc.sync('downloads');
}
```

---

## 1. Built-in Path Manipulation

Eliminates the need for `package:path` imports in automation scripts:

- `io.join(p1, [p2, p3, p4...])`: Platform-agnostic safe path joining with slash normalization.
- `io.base(path)`: Filename with extension (`archive.tar.gz` -> `archive.tar.gz`).
- `io.name(path)`: Filename without extension (`archive.tar.gz` -> `archive.tar`).
- `io.ext(path)`: File extension including dot (`config.json` -> `.json`).
- `io.dir(path)`: Parent directory path (`a/b/c.txt` -> `a/b`).

---

## 2. Atomic File Operations

Guarantees data integrity by writing to a temporary `.part` file first and renaming atomically upon completion. If a script is cancelled or fails mid-write, partial corrupted files are never left in place.

### `io.write(file, content, {part})`
Accepts `String`, `List<int>`, or raw bytes. Automatically creates parent directories:

```dart
await io.write('output/config.yaml', 'version: 1\nenabled: true');
```

### `io.read(path)` & `io.bytes(path)`
Convenient helpers to read file contents:

```dart
final text = await io.read('output/config.yaml');
final raw = await io.bytes('images/logo.png');
```

### `io.download(url, destination, {part, headers, onProgress})`
Streams an HTTP download directly to disk with atomic `.part` protection:

```dart
await io.download(
  Uri.parse('https://example.com/huge-file.iso'),
  'downloads/file.iso',
  onProgress: (received, total) {
    print('Downloaded ${io.size(received)} of ${io.size(total)}');
  },
);
```

### Directory Creation & Moving
```dart
// Ensure directory exists
await io.mkdir('deeply/nested/output/folder');

// Safe copy and move (auto-creates destination directories)
await io.copy('source.txt', 'backup/source.txt');
await io.move('old.txt', 'archive/old.txt');
```

---

## 3. Search & Inspection

### `io.has(path, {match: true})`
Checks if a file exists and is not empty (`length > 0`):

```dart
if (io.has('output/cache.bin')) {
  util.console.logger.ok('Cache exists and has valid data.');
}
```

### `io.find(directory, [pattern])`
Recursively finds files matching regex or substring:

```dart
// Find all audio files
final audioFiles = io.find('media', RegExp(r'\.(mp3|flac|wav)$'));
for (final f in audioFiles) {
  util.console.logger.info('Found: ${f.path} (${io.size(f.lengthSync())})');
}
```

### `io.delete(directory, [pattern])`
Removes files matching criteria or deletes directory:

```dart
// Clean up all .tmp files
await io.delete('temp', RegExp(r'\.tmp$'));
```

---

## 4. Formatters & Helpers

### `io.size(bytes)` & `io.parse(sizeStr)`
Formats raw bytes into human-readable strings (`KB`, `MB`, `GB`, `TB`) and parses them:

```dart
print(io.size(1048576));   // "1.0 MB"
print(io.size(5368709120)); // "5.0 GB"

final bytes = io.parse('2.5 GB'); // 2684354560
```

### `io.time(duration)`
Formats duration into clean `MM:SS` or `HH:MM:SS`:

```dart
print(io.time(Duration(seconds: 145))); // "02:25"
```

### `io.sanitize(name, {full: false})`
Sanitizes filenames to remove illegal operating system characters (`/ \ : * ? " < > |`):

```dart
final clean = io.sanitize('Song Title / (2026)? [Special Edition]');
// "Song Title _ (2026)_ [Special Edition]"
```

---

## 5. 7-Zip Archive Management (`io.archive()`)

Integrated wrapper around 7-Zip with integrity checks and automatic volume management:

```dart
final arc = io.archive('backups/2026.7z');

// Check integrity via 7z 't'
final isHealthy = await arc.check();

// Synchronize directory into archive with force/changed checks
final result = await arc.sync(
  'storage/data',
  force: false,
  changed: true,
);

util.console.logger.ok('Archive result: $result'); // "Created", "Verified", or "Updated"
```
