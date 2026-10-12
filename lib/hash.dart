/// # Hashing & Checksums
///
/// `Hash.sha256` and friends — all callable, all with an optional `key` for
/// keyed authentication — plus `source.hash(algo)` for files and streams, and
/// `.hex`/`.base64`/`.toInt()` on digests with `Hex`/`Base64.decode`.
/// Digests run natively (`tk_digest_*`); without the library the call is an
/// [UnsupportedError] (rule 42: no Dart fallback).
library;

export 'src/hash/hash.dart';
export 'src/core/errors.dart';
export 'src/core/pipe.dart';
export 'src/core/traits.dart';
