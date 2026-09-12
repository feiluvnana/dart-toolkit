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
const HashAccessor _hashInstance = HashAccessor();

/// The SHA-256 digest of [input], as 64 lowercase hex characters.
String sha256Hash(Object input) => _hashInstance.sha(input);

/// The MD5 digest of [input], as 32 lowercase hex characters.
String md5Hash(Object input) => _hashInstance.md5(input);

/// An HMAC-SHA256 of [input] under [key], as hex.
String hmacSha256(Object input, Object key) => _hashInstance.sign(input, key);

// ============================================================================
// STATIC HELPER HUB: Hash
// ============================================================================

/// Static helper hub for SHA-256, MD5, and HMAC hashing.
///
/// Easily discoverable via IDE auto-complete:
/// ```dart
/// final sha = Hash.sha256('hello');
/// final md5 = Hash.md5('hello');
/// final sig = Hash.hmac('secret-key', 'data');
/// ```
abstract final class Hash {
  Hash._();

  /// The SHA-256 digest of [input], as 64 lowercase hex characters.
  static String sha(Object input) => _hashInstance.sha(input);

  /// The SHA-256 digest of [input], as 64 lowercase hex characters.
  static String sha256(Object input) => _hashInstance.sha(input);

  /// The MD5 digest of [input], as 32 lowercase hex characters.
  static String md5(Object input) => _hashInstance.md5(input);

  /// An HMAC-SHA256 of [message] under [key], as hex.
  static String hmac(Object key, Object message) =>
      _hashInstance.sign(message, key);

  /// An HMAC-SHA256 of [input] under [key], as hex. Alias for [hmac].
  static String sign(Object input, Object key) =>
      _hashInstance.sign(input, key);
}

/// Entry point for hashing, reachable via [Hash].
///
/// ```dart
/// Hash.sha256('https://example.com/a');               // 64 hex characters
/// Hash.sha256('https://example.com/a').substring(0, 8); // a cache key
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
