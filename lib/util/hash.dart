/// # Hashing
///
/// SHA-256, MD5 and HMAC-SHA256, each returning lowercase hex. The digest a
/// cache key or a dedupe set is built from, and the signature an API request
/// is signed with.
///
/// ```dart
/// sha256Hash('https://example.com/a');                 // 64 hex characters
/// sha256Hash('https://example.com/a').substring(0, 8); // a cache key
/// ```
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

List<int> _bytes(Object input) => switch (input) {
  String text => utf8.encode(text),
  List<int> bytes => bytes,
  _ => utf8.encode(input.toString()),
};

/// The SHA-256 digest of [input], as 64 lowercase hex characters.
///
/// [input] is a `String` or a `List<int>`; anything else is hashed as its
/// `toString()`.
String sha256Hash(Object input) =>
    crypto.sha256.convert(_bytes(input)).toString();

/// The MD5 digest of [input], as 32 lowercase hex characters.
///
/// MD5 is fine for a cache key or a change check and is **not** fine for
/// anything security-bearing; [sha256Hash] is the one for that.
String md5Hash(Object input) => crypto.md5.convert(_bytes(input)).toString();

/// An HMAC-SHA256 of [input] under [key], as hex — for signing a request.
///
/// The argument order is *payload first, secret second*, matching every other
/// function here in taking the data as its first argument. Both parameters
/// accept a `String` or a `List<int>`, so a swapped pair would still compile
/// and silently produce the wrong signature: there is deliberately only one
/// spelling of this function, rather than the two with opposite orders that
/// `Hash.hmac(key, message)` and `Hash.sign(input, key)` used to offer.
String hmacSha256(Object input, Object key) =>
    crypto.Hmac(crypto.sha256, _bytes(key)).convert(_bytes(input)).toString();

/// Digests of this string.
extension StringHashExtensions on String {
  /// The SHA-256 digest of this string, as 64 lowercase hex characters.
  ///
  /// See [sha256Hash].
  String sha256() => sha256Hash(this);

  /// The MD5 digest of this string, as 32 lowercase hex characters.
  ///
  /// See [md5Hash].
  String md5() => md5Hash(this);

  /// An HMAC-SHA256 of this string under [key], as hex.
  ///
  /// See [hmacSha256].
  String hmac(Object key) => hmacSha256(this, key);
}
