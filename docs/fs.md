# File System & Storage Subsystem (`fs.*`)

The `fs` namespace in **Dart Script Toolkit** provides atomic file writes, zero-dependency path manipulation (no `package:path` imports required), streaming downloads, recursive searches, and integrated 7-Zip archiving.

---

## Quick Overview

```dart
import 'package:dart_toolkit/dart_toolkit.dart';

void main() async {
  // 1. Zero-dependency path operations
  final filePath = fs.join('data', 'reports', '2026.json');
  console.logger.info('Base: ${fs.base(filePath)}'); // 2026.json
  console.logger.info('Name: ${fs.name(filePath)}'); // 2026
  console.logger.info('Ext:  ${fs.ext(filePath)}');  // .json
  console.logger.info('Dir:  ${fs.dir(filePath)}');  // data/reports

  // 2. Atomic file write (.part staging + rename)
  await fs.write(filePath, '{"status": "ok"}');

  // 3. Direct streaming download
  await fs.download(
    Uri.parse('https://example.com/asset.zip'),
    fs.join('downloads', 'asset.zip'),
  );

  // 4. Archive into 7z
  final arc = fs.archive('bundle.7z');
  await arc.sync('downloads');
}
```

---

## 1. Built-in Path Manipulation

Eliminates the need for `package:path` imports in automation scripts:

- `fs.join(p1, [p2, p3, p4...])`: Platform-agnostic safe path joining with slash normalization.
- `fs.base(path)`: Filename with extension (`archive.tar.gz` -> `archive.tar.gz`).
- `fs.name(path)`: Filename without extension (`archive.tar.gz` -> `archive.tar`).
- `fs.ext(path)`: File extension including dot (`config.json` -> `.json`).
- `fs.dir(path)`: Parent directory path (`a/b/c.txt` -> `a/b`).

---

## 2. Atomic File Operations

Guarantees data integrity by writing to a temporary `.part` file first and renaming atomically upon completion. If a script is cancelled or fails mid-write, partial corrupted files are never left in place.

### `fs.write(file, content, {part})`
Accepts `String`, `List<int>`, or raw bytes. Automatically creates parent directories:

```dart
await fs.write('output/config.yaml', 'version: 1\nenabled: true');
```

### `fs.read(path)` & `fs.bytes(path)`
Convenient helpers to read file contents:

```dart
final text = await fs.read('output/config.yaml');
final raw = await fs.bytes('images/logo.png');
```

### `fs.download(url, destination, {part, headers, onProgress})`
Streams an HTTP download directly to disk with atomic `.part` protection:

```dart
await fs.download(
  Uri.parse('https://example.com/huge-file.iso'),
  'downloads/file.iso',
  onProgress: (received, total) {
    print('Downloaded ${fs.size(received)} of ${fs.size(total)}');
  },
);
```

### Directory Creation & Moving
```dart
// Ensure directory exists
await fs.mkdir('deeply/nested/output/folder');

// Safe copy and move (auto-creates destination directories)
await fs.copy('source.txt', 'backup/source.txt');
await fs.move('old.txt', 'archive/old.txt');
```

---

## 3. Search & Inspection

### `fs.has(path, {match: true})`
Checks if a file exists and is not empty (`length > 0`):

```dart
if (fs.has('output/cache.bin')) {
  console.logger.ok('Cache exists and has valid data.');
}
```

### `fs.find(directory, [pattern])`
Recursively finds files matching regex or substring:

```dart
// Find all audio files
final audioFiles = fs.find('media', RegExp(r'\.(mp3|flac|wav)$'));
for (final f in audioFiles) {
  console.logger.info('Found: ${f.path} (${fs.size(f.lengthSync())})');
}
```

### `fs.delete(directory, [pattern])`
Removes files matching criteria or deletes directory:

```dart
// Clean up all .tmp files
await fs.delete('temp', RegExp(r'\.tmp$'));
```

---

## 4. Formatters & Helpers

### `fs.size(bytes)` & `fs.parse(sizeStr)`
Formats raw bytes into human-readable strings (`KB`, `MB`, `GB`, `TB`) and parses them:

```dart
print(fs.size(1048576));   // "1.0 MB"
print(fs.size(5368709120)); // "5.0 GB"

final bytes = fs.parse('2.5 GB'); // 2684354560
```

### `fs.time(duration)`
Formats duration into clean `MM:SS` or `HH:MM:SS`:

```dart
print(fs.time(Duration(seconds: 145))); // "02:25"
```

### `fs.sanitize(name, {full: false})`
Sanitizes filenames to remove illegal operating system characters (`/ \ : * ? " < > |`):

```dart
final clean = fs.sanitize('Song Title / (2026)? [Special Edition]');
// "Song Title _ (2026)_ [Special Edition]"
```

---

## 5. 7-Zip Archive Management (`fs.archive()`)

Integrated wrapper around 7-Zip with integrity checks and automatic volume management:

```dart
final arc = fs.archive('backups/2026.7z');

// Check integrity via 7z 't'
final isHealthy = await arc.check();

// Synchronize directory into archive with force/changed checks
final result = await arc.sync(
  'storage/data',
  force: false,
  changed: true,
);

console.logger.ok('Archive result: $result'); // "Created", "Verified", or "Updated"
```
