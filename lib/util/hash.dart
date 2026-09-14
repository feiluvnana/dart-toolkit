/// # Hashing
///
/// One verb on the value being hashed, and the algorithm as a leading dot.
/// Lowercase hex out — the digest a cache key or a dedupe set is built from,
/// and the signature an API request is signed with.
///
/// ```dart
/// 'https://example.com/a'.hash();                 // 64 hex characters, SHA-256
/// 'https://example.com/a'.hash(.md5);             // 32
/// 'https://example.com/a'.hash().substring(0, 8); // a cache key
/// 'payload'.hmac('secret');                       // HMAC-SHA256
/// ```
///
/// The same verb reads a file: `await Path('dist/app.zip').hash(.sha256)`,
/// which streams rather than loading it.
/// {@category Utilities}
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../src/fs.dart';

List<int> _bytes(Object input) => switch (input) {
  String text => utf8.encode(text),
  List<int> bytes => bytes,
  _ => utf8.encode(input.toString()),
};

String _hash(Object input, Algo algo) => switch (algo) {
  Algo.sha256 => crypto.sha256.convert(_bytes(input)).toString(),
  Algo.md5 => crypto.md5.convert(_bytes(input)).toString(),
}.toString();

String _hmac(Object input, Object key) =>
    crypto.Hmac(crypto.sha256, _bytes(key)).convert(_bytes(input)).toString();

/// Digests of this string.
extension StringHashExtensions on String {
  /// The digest of this string under [algo], as lowercase hex.
  ///
  /// ```dart
  /// '\$url'.hash();       // SHA-256, 64 hex characters
  /// '\$url'.hash(.md5);   // MD5, 32
  /// ```
  ///
  /// MD5 is fine for a cache key or a change check and is **not** fine for
  /// anything security-bearing.
  String hash([Algo algo = Algo.sha256]) => _hash(this, algo);

  /// An HMAC-SHA256 of this string under [key], as hex — for signing a request.
  ///
  /// The argument order is *payload first, secret second*, matching every
  /// other member here in acting on the receiver. Both sides accept a `String`
  /// or a `List<int>`, so a swapped pair would still compile and silently
  /// produce the wrong signature: there is deliberately only one spelling of
  /// this, rather than the two with opposite orders that `Hash.hmac(key,
  /// message)` and `Hash.sign(input, key)` used to offer.
  String hmac(Object key) => _hmac(this, key);
}

/// Digests of these bytes.
extension BytesHashExtensions on List<int> {
  /// The digest of these bytes under [algo], as lowercase hex.
  String hash([Algo algo = Algo.sha256]) => _hash(this, algo);

  /// An HMAC-SHA256 of these bytes under [key], as hex.
  String hmac(Object key) => _hmac(this, key);
}
