/// # Hashing (`util.hash.*`)
///
/// Digests of strings and bytes. For a file's digest use `io.hash`, which
/// streams it rather than holding it in memory.
///
/// Five members, all of them one-way. Base64 was here through 5.5.0 as
/// `encode`/`decode`; it is reversible, so it was the one thing in a hashing
/// namespace that was not a hash, and it is `util.text.base64` now.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

// ============================================================================
// HASHING (util.hash.*)
// ============================================================================

/// Entry point for hashing, reachable as `util.hash`.
///
/// ```dart
/// util.hash.sha('https://example.com/a');               // 64 hex characters
/// util.hash.sha('https://example.com/a').substring(0, 8); // a cache key
/// ```
///
/// `short` was that second line as a member through 6.1.0.
class HashAccessor {
  /// Creates the accessor. Prefer the shared `util.hash` instance.
  const HashAccessor();

  /// The SHA-256 digest of [input], as 64 lowercase hex characters.
  ///
  /// [input] is a `String` or a `List<int>`.
  String sha(Object input) => crypto.sha256.convert(_bytes(input)).toString();

  /// The MD5 digest of [input], as 32 lowercase hex characters.
  String md5(Object input) => crypto.md5.convert(_bytes(input)).toString();

  /// An HMAC-SHA256 of [input] under [key], as hex — for signing a request.
  String sign(Object input, Object key) =>
      crypto.Hmac(crypto.sha256, _bytes(key)).convert(_bytes(input)).toString();

  static List<int> _bytes(Object input) => switch (input) {
    String text => utf8.encode(text),
    List<int> bytes => bytes,
    _ => utf8.encode(input.toString()),
  };
}
