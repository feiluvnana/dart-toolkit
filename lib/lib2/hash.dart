/// # Hashing & Checksums
///
/// `Hash.sha256`, `md5`, `sha512`, `blake3`, `crc32` and `xxh3` — all callable, all with
/// `.mac(key)` for keyed authentication and `.writer()` for streaming. Pure Dart.
library;

export 'src/hash/hash.dart';
