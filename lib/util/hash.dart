/// # Hashing (`util.hash.*`)
///
/// Digests of strings and bytes. For a file's digest use `io.hash`, which
/// streams it rather than holding it in memory.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

// ============================================================================
// HASHING (util.hash.*)
// ============================================================================

/// Entry point for hashing, reachable as `util.hash`.
///
/// ```dart
/// util.hash.sha('https://example.com/a');   // 64 hex characters
/// util.hash.short('https://example.com/a'); // the first 8 of them
/// ```
class HashAccessor {
  /// Creates the accessor. Prefer the shared `util.hash` instance.
  const HashAccessor();

  /// The SHA-256 digest of [input], as 64 lowercase hex characters.
  ///
  /// [input] is a `String` or a `List<int>`.
  String sha(Object input) => crypto.sha256.convert(_bytes(input)).toString();

  /// The MD5 digest of [input], as 32 lowercase hex characters.
  String md5(Object input) => crypto.md5.convert(_bytes(input)).toString();

  /// The first [length] characters of [sha], for cache keys and filenames.
  String short(Object input, [int length = 8]) =>
      sha(input).substring(0, length.clamp(1, 64));

  /// An HMAC-SHA256 of [input] under [key], as hex — for signing a request.
  String sign(Object input, Object key) =>
      crypto.Hmac(crypto.sha256, _bytes(key)).convert(_bytes(input)).toString();

  /// [input] encoded as base64.
  String encode(Object input) => base64.encode(_bytes(input));

  /// Reverses [encode], returning the decoded bytes.
  List<int> decode(String input) => base64.decode(input);

  static List<int> _bytes(Object input) => switch (input) {
    String text => utf8.encode(text),
    List<int> bytes => bytes,
    _ => utf8.encode(input.toString()),
  };
}
