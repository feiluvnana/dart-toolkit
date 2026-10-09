# Module Proposal 06: Archive & Compression (`lib/archive.dart`)

## 1. Overview & Vision

The Archive & Compression module provides high-performance compression and decompression for `.zip`, `.tar`, `.tar.gz`, and `.tar.zst` files with atomic extraction, conflict strategies, progress tracking, and streamable archives.

### Core Problems in the Existing API
1. **Multi-Step Archive Creation**: Creating an archive requires `box.archive(to: '$box.zip', conflict: Conflict.overwrite).show('Zipping')`.
2. **Missing Shorthand Decompression**: Decompressing a zip or tar.gz file requires manually constructing an `Archive` reader and iterating over entries.
3. **Format Distinctions**: Tar, Tar.gz, and Zip use different parameter signatures.

---

## 2. Detailed Before vs After Comparison

### 2.1 Single-Step Compression & Extraction

#### Before:
```dart
// Creating a zip archive
final folder = Path('build/release');
final zipTask = folder.archive(to: 'release.zip', conflict: Conflict.overwrite);
final zipFile = await zipTask.show('Zipping', done: 'Zipped.');

// Extracting a zip archive
final archive = await Archive.open('release.zip');
await archive.extract(to: 'output_dir');
```

#### After (Proposed):
```dart
final folder = Path('build/release');

// 1. Direct Zip creation and extraction
final zipFile = await folder.zipTo('release.zip', overwrite: true, show: 'Zipping Release');
await Path('release.zip').unzipTo('output_dir', show: 'Extracting Release');

// 2. Direct Tar / Tar.gz / Tar.zst creation and extraction
final tarFile = await folder.tarGzTo('release.tar.gz', overwrite: true, show: 'Creating Tar.gz');
await Path('release.tar.gz').untarTo('output_dir', show: 'Extracting Tar.gz');

final zstFile = await folder.tarZstTo('release.tar.zst', show: 'Creating Zstandard Archive');
await Path('release.tar.zst').untarTo('output_dir', show: 'Extracting Zstandard Archive');
```

##### Visual Look:
```text
⠋ Zipping Release  ━━━━━━━╸───────────────  42%  145/340 files  18.2 MB/s  (4.1s)
✓ Zipping Release: Created release.zip (42.1 MB) (7.2s)
```

---

### 2.2 Streaming Entries & In-Memory Archives

#### Before:
```dart
// Complex manual byte streaming through Archive reader
```

#### After (Proposed):
```dart
// 1. Inspect archive contents without full disk extraction
final entries = await Path('release.zip').listArchiveEntries();
for (final entry in entries) {
  print('${entry.name} - ${entry.size.humanBytes}');
}

// 2. Read single file directly out of archive into memory
final readmeText = await Path('release.zip').readArchiveText('README.md');
```

---

## 3. What is Better vs Old API

| Feature | Old API | Proposed New API | Impact |
|---|---|---|---|
| **Zip Creation** | `folder.archive(to: ...)` | `folder.zipTo('out.zip')` | Direct, memorable method name |
| **Extraction** | Multi-class setup | `path.unzipTo('target')` | 1-line decompression |
| **Tar.gz & Zstd** | Manual codec pipeline | `folder.tarGzTo()`, `folder.tarZstTo()` | Unified, format-agnostic API |
| **Archive Inspection** | Full decompression required | `listArchiveEntries()`, `readArchiveText()` | Instant, memory-efficient inspection |

---

## 4. Trade-Offs & Backward Compatibility

### Trade-Offs:
- Auto-detecting archive formats (Zip vs Tar vs Zstd) from file extensions (`.zip`, `.tar.gz`, `.tar.zst`) relies on standard naming conventions.
  - *Mitigation*: Explicit parameters (`format: ArchiveFormat.tarGz`) are available for files with non-standard extensions.

### Backward Compatibility:
- 100% backward compatible. All existing `folder.archive()`, `Conflict`, `Archive`, and low-level compression bindings continue to function without change.
