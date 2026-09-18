part of '../../crypto.dart';

/// X25519 key agreement (RFC 7748): each side calls `agree` with the other's public key and
/// both get the same 32 bytes. Feed them to [Hkdf] before using them as a cipher key.
///
/// ```dart
/// final mine = X25519.generate();
/// final shared = mine.agree(theirPublicKey);
/// ```
///
/// {@category Crypto}
final class X25519 {
  /// The 32-byte private key.
  final Key privateKey;

  /// The 32-byte public key.
  final Uint8List publicKey;

  X25519.fromKey(this.privateKey)
    : publicKey = Native.withBytes(privateKey.bytes, (k, _) => Native.withOut(32, (out) => _N.x25519Public(k, out)));

  X25519.generate() : this.fromKey(Key.random(32));

  /// The shared secret with [theirPublicKey].
  Uint8List agree(List<int> theirPublicKey) =>
      _with2(privateKey.bytes, theirPublicKey, (k, _, p, _) => Native.withOut(32, (out) => _N.x25519Agree(k, p, out)));
}

/// ECDH over P-256, what WebCrypto and most cloud key services default to. Keys are the
/// same shape as [Ecdsa]'s: a 32-byte scalar and a 65-byte uncompressed point.
///
/// {@category Crypto}
final class Ecdh {
  final Key privateKey;
  final Uint8List publicKey;

  Ecdh.p256(this.privateKey)
    : publicKey = Native.withBytes(privateKey.bytes, (k, _) => Native.withOut(65, (out) => _N.p256Public(k, out)));

  Ecdh.generate() : this.p256(Key.random(32));

  /// The shared secret (the x coordinate, 32 bytes) with [theirPublicKey], compressed or not.
  Uint8List agree(List<int> theirPublicKey) => _with2(
    privateKey.bytes,
    theirPublicKey,
    (k, _, p, pl) => Native.withOut(32, (out) => _N.p256Agree(k, p, pl, out)),
  );
}
