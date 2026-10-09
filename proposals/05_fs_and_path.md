# Module Proposal 05: Filesystem & Paths (`lib/path.dart`)

## 1. Overview & Vision

The Filesystem & Path module provides pure path operations, cross-platform normalization, atomic file reading and writing, directory listings, recursive globbing, file system watching, duplicate detection, and disk space queries.

### Core Problems in the Existing API
1. **Serialization Ceremony**: Writing JSON or structured data to a file requires manual `jsonEncode()` before calling `path.writeText()`, and `jsonDecode()` after `path.readText()`.
2. **Missing Shorthand Read Lines**: Reading lines from a file as a list requires manual stream consumption.
3. **Directory Lifecycle Management**: Creating temporary directories and cleaning directories requires custom `Directory` helpers.
4. **Duplicate Finding Verbosity**: Locating duplicate files across directories requires multi-step hash comparison scripts.

---

## 2. Detailed Before vs After Comparison

### 2.1 Atomic File I/O (JSON, Text, Lines, Bytes)

#### Before:
```dart
final path = Path.cwd / 'config.json';

// Writing JSON
final encoded = const JsonEncoder.withIndent('  ').convert({'port': 8080});
await path.writeText(encoded);

// Reading JSON
final raw = await path.readText();
final json = jsonDecode(raw) as Map<String, dynamic>;

// Reading all lines into a List<String>
final lines = await path.lines().toList();
```

#### After (Proposed):
```dart
final path = Path.cwd / 'config.json';

// 1. Direct atomic JSON write and read
await path.writeJson({'port': 8080}, pretty: true);
final json = await path.readJson<Map<String, dynamic>>();

// 2. Direct text and lines
await path.writeText('Hello World');
final lines = await path.readLines(); // List<String>

// 3. Direct bytes
await path.writeBytes(byteData);
final bytes = await path.readBytes();
```

---

### 2.2 Globbing & Directory Tree Operations

#### Before:
```dart
final dartFiles = <Path>[];
await for (final file in Path.cwd.files(only: '**/*.dart')) {
  dartFiles.add(file);
}

// Creating a unique temp dir
final sysTemp = Directory.systemTemp;
final myTemp = await Directory('${sysTemp.path}/test_${DateTime.now().millisecondsSinceEpoch}').create();
final tempPath = Path(myTemp.path);
```

#### After (Proposed):
```dart
// 1. Direct glob list
final dartFiles = await Path.cwd.glob('**/*.dart');

// 2. Immediate Temp File & Directory creation
final tempDir  = await Path.tempDir(prefix: 'build_');
final tempFile = await Path.tempFile(suffix: '.log');

// 3. Directory Lifecycle Helpers
await (Path.cwd / 'out').ensureDir();  // Creates recursively if missing
await (Path.cwd / 'out').emptyDir();   // Deletes all contents but keeps the folder
```

---

### 2.3 Duplicate Detection & Disk Space

#### Before:
```dart
// Required manual hash calculation and map grouping
```

#### After (Proposed):
```dart
// Find duplicate files by content hash
final duplicates = await Path('photos/').findDuplicates();
for (final group in duplicates) {
  print('Original: ${group.first}, Duplicates: ${group.sublist(1)}');
}

// Check available disk space
final freeBytes = await Path.cwd.freeSpace(); // int
print('Free space: ${freeBytes.humanBytes}');
```

---

### 2.4 File System Watching

#### Before:
```dart
final subscription = path.watch().listen((event) {
  print('Changed: ${event.path}');
});
```

#### After (Proposed):
```dart
// Filtered file watcher with debounce
final watcher = path.watch(
  only: '**/*.dart',
  debounce: 200.ms,
  onChange: (event) {
    Console.info('Reloading: ${event.path.name}');
  },
);
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **JSON Files** | Manual encode/decode | `readJson<T>()`, `writeJson()` | **-70% boilerplate**, atomic |
| **Globbing** | Manual stream `await for` loop | `path.glob('**/*.ext')` -> `List<Path>` | Instant discovery |
| **Temp Management** | Dart `dart:io` boilerplate | `Path.tempDir()`, `Path.tempFile()` | Safe, automatic scratch paths |
| **Directory Helpers** | Manual `create(recursive: true)` | `ensureDir()`, `emptyDir()` | Robust directory management |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- `path.glob()` buffers matching paths into a `List<Path>`. For directories with hundreds of thousands of files, `path.files(only: ...)` (which returns a `Stream<Path>`) remains the recommended memory-efficient choice.

### Backward Compatibility:
- 100% backward compatible. All existing path operators (`/`, `name`, `stem`, `ext`, `parent`, `readText`, `writeText`, `copy`, `move`, `delete`, `trash`) remain completely supported.
