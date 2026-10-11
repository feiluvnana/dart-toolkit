# 06: Archive & Compression

High-performance native compression and extraction powered by Rust FFI.

---

## 1. Pack & Unpack

Format is auto-detected from extension (`.zip`, `.tar.gz`, `.tar.zst`).

```dart
// Pack directory into archive
await Archive.pack(src: 'build', dst: 'build.zip');

// Unpack archive to directory
await Archive.unpack(src: 'build.zip', dst: 'dist');
```

---

## 2. Inspect Archive

```dart
// List contents without extracting
final entries = await Archive.list('bundle.tar.gz');

for (final entry in entries) {
  print('${entry.name} - ${entry.size} bytes');
}
```

---

## 3. Single-Buffer Compression (Zstd / Gzip)

```dart
final raw = Uint8List(1024 * 1024);
final compressed = await Zstd.pack(raw);
final restored   = await Zstd.unpack(compressed);
```

---

## 4. Advanced Use Cases

### 4.1 Zero-Disk Streaming Unpack over HTTP
Unpack large archives directly from an HTTP network stream without ever writing the compressed archive to disk:

```dart
// Streams incoming network bytes directly into unpack worker
await Http.get('https://example.com/asset-bundle.tar.gz')
  .pipe(Archive.unpack(dst: 'assets'));
```

### 4.2 In-Memory Selective Extraction
Extract a single configuration file out of a massive multi-gigabyte zip archive without extracting the rest:

```dart
final bytes = await Archive.extract(
  src: 'huge_backup.zip',
  target: 'etc/settings.json',
);

final settings = Json.parse(utf8.decode(bytes));
```

### 4.3 Built-in Zip-Slip Vulnerability Protection
Archive extractors automatically validate every destination entry against path traversal escapes:

```dart
// If archive contains '../../etc/passwd', Archive.unpack throws immediately
// before writing any bytes to the filesystem.
try {
  await Archive.unpack(src: 'untrusted.zip', dst: 'sandbox');
} on SecurityException catch (e) {
  print('Blocked malicious zip slip payload: ${e.message}');
}
```
