part of '../../crypto.dart';

/// An Ed25519 key pair (RFC 8032). Needs the native library.
///
/// ```dart
/// final pair = Ed25519.generate();
/// final sig = pair.sign(bytes);
/// Ed25519.verify(pair.publicKey, bytes, sig);
/// ```
///
/// {@category Crypto}
final class Ed25519 {
  /// The 32-byte seed; keep it secret.
  final Key seed;

  /// The 32-byte public key.
  final Uint8List publicKey;

  Ed25519.fromSeed(this.seed)
    : publicKey = Native.withBytes(seed.bytes, (s, _) => Native.withOut(32, (out) => _N.ed25519Public(s, out)));

  Ed25519.generate() : this.fromSeed(Key.random(32));

  /// The 64-byte signature of [message].
  Uint8List sign(List<int> message) =>
      _with2(seed.bytes, message, (s, _, m, ml) => Native.withOut(64, (out) => _N.ed25519Sign(s, m, ml, out)));

  /// Whether [signature] is [publicKey]'s signature of [message].
  static bool verify(List<int> publicKey, List<int> message, List<int> signature) {
    Native.require('Ed25519');
    return _with3(publicKey, message, signature, (p, _, m, ml, s, _) => _N.ed25519Verify(p, m, ml, s)) == 1;
  }
}

/// ECDSA over P-256 with SHA-256 — `ES256`, what JWTs and cloud APIs ask for.
///
/// {@category Crypto}
final class Ecdsa {
  /// The 32-byte private scalar.
  final Key privateKey;

  /// The 65-byte uncompressed public point.
  final Uint8List publicKey;

  Ecdsa.p256(this.privateKey)
    : publicKey = Native.withBytes(privateKey.bytes, (s, _) => Native.withOut(65, (out) => _N.p256Public(s, out)));

  Ecdsa.generate() : this.p256(Key.random(32));

  /// The 64-byte `r ‖ s` signature of [message].
  Uint8List sign(List<int> message) =>
      _with2(privateKey.bytes, message, (k, _, m, ml) => Native.withOut(64, (out) => _N.p256Sign(k, m, ml, out)));

  /// Whether [signature] is the P-256 [publicKey]'s (SEC1, compressed or not) signature of [message].
  static bool verify(List<int> publicKey, List<int> message, List<int> signature) {
    Native.require('ECDSA');
    return _with3(publicKey, message, signature, (p, pl, m, ml, s, _) => _N.p256Verify(p, pl, m, ml, s)) == 1;
  }
}

/// RSA signature verification (PKCS#1 v1.5), for release artifacts and webhooks.
///
/// {@category Crypto}
abstract final class Rsa {
  /// Whether [signature] over [message] with [hash] verifies against [publicKeyPem] (SPKI or PKCS#1).
  static bool verify(String publicKeyPem, List<int> message, List<int> signature, {Hash hash = Hash.sha256}) {
    Native.require('RSA');
    return _with3(
          utf8.encode(publicKeyPem),
          message,
          signature,
          (p, pl, m, ml, s, sl) => _N.rsaVerify(p, pl, hash.index, m, ml, s, sl),
        ) ==
        1;
  }
}
