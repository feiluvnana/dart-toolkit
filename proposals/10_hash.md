# 10: Hash & Encoding

Native-accelerated cryptographic digests, checksums, and binary encodings powered by Rust FFI.

---

## 1. Quick Digests

Supported algorithms: `sha256`, `sha512`, `md5`, `blake3`, `crc32`, `xxh3`.

```dart
// Hash text
final d1 = Hash.sha256('hello world');
print(d1.hex); // 'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'

// Hash raw bytes
final d2 = Hash.blake3(Uint8List.fromList([1, 2, 3]));

// Fast checksum for integrity checks
final crc = Hash.crc32('data');
print(crc.intVal); // 3465132541
```

---

## 2. File & Stream Hashing

Zero-copy, streaming file hashing without loading files entirely into memory:

```dart
// Hash file directly
final digest = await Hash.sha256(File('ubuntu.iso'));
print(digest.hex);

// Stream hashing via pipe
final hasher = Hash.sha256.writer();
await Http.get('https://example.com/file.bin').pipe(hasher);
print(hasher.sum.hex);
```

---

## 3. Encodings (Hex & Base64)

```dart
// Hex
final hexStr = Hex.encode([0xDE, 0xAD, 0xBE, 0xEF]); // 'deadbeef'
final bytes  = Hex.decode('deadbeef');

// Base64
final b64 = Base64.encode('hello'); // 'aGVsbG8='
final raw = Base64.decode('aGVsbG8=');
```

---

## 4. Advanced Use Cases

### 4.1 HMAC Authentication
Generate keyed message authentication codes for API signatures:

```dart
final mac = Hash.sha256.mac(
  data: 'POST /api/transfer {"amount": 100}',
  key: 'my-secret-key',
);

print(mac.hex);
```

### 4.2 Deduplication by Content Hash
Find duplicate files across directories at native speed:

```dart
final seen = <String, Path>{};

for (final file in await Dir('downloads').find('*.*')) {
  final hash = (await Hash.xxh3(file)).hex;
  if (seen.containsKey(hash)) {
    print('Duplicate found: ${file.str} matches ${seen[hash]!.str}');
  } else {
    seen[hash] = file.path;
  }
}
```
