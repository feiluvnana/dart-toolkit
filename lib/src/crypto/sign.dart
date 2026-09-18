part of '../../crypto.dart';

/// An Ed25519 key pair (RFC 8032).
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

  /// From a PKCS#8 PEM (`openssl genpkey -algorithm ed25519`).
  Ed25519.fromPem(String pem) : this.fromSeed(Key(_fromPem(_N.privateFromPem, 0, pem, 32)));

  /// The public key inside an SPKI PEM, for [verify].
  static Uint8List publicFromPem(String pem) => _fromPem(_N.publicFromPem, 0, pem, 32);

  /// The private key as PKCS#8 PEM.
  String get pem => _pem(0, seed.bytes, public: false);

  /// The public key as SPKI PEM.
  String get publicPem => _pem(0, seed.bytes, public: true);

  /// The 64-byte signature of [message].
  Uint8List sign(List<int> message) =>
      _with2(seed.bytes, message, (s, _, m, ml) => Native.withOut(64, (out) => _N.ed25519Sign(s, m, ml, out)));

  /// Whether [signature] is [publicKey]'s signature of [message].
  static bool verify(List<int> publicKey, List<int> message, List<int> signature) =>
      _with3(publicKey, message, signature, (p, _, m, ml, s, _) => _N.ed25519Verify(p, m, ml, s)) == 1;
}

/// ECDSA over P-256 with SHA-256: `ES256`, what JWTs and cloud APIs ask for.
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

  /// From a PKCS#8 or SEC1 PEM (`openssl ecparam -name prime256v1 -genkey`).
  Ecdsa.fromPem(String pem) : this.p256(Key(_fromPem(_N.privateFromPem, 1, pem, 32)));

  /// The public point inside an SPKI PEM, for [verify].
  static Uint8List publicFromPem(String pem) => _fromPem(_N.publicFromPem, 1, pem, 65);

  String get pem => _pem(1, privateKey.bytes, public: false);
  String get publicPem => _pem(1, privateKey.bytes, public: true);

  /// The 64-byte `r ‖ s` signature of [message].
  Uint8List sign(List<int> message) =>
      _with2(privateKey.bytes, message, (k, _, m, ml) => Native.withOut(64, (out) => _N.p256Sign(k, m, ml, out)));

  /// Whether [signature] is the P-256 [publicKey]'s (SEC1, compressed or not) signature of [message].
  static bool verify(List<int> publicKey, List<int> message, List<int> signature) =>
      _with3(publicKey, message, signature, (p, pl, m, ml, s, _) => _N.p256Verify(p, pl, m, ml, s)) == 1;
}

/// RSA: PKCS#1 v1.5 and PSS signatures, OAEP encryption, keys as PEM.
///
/// ```dart
/// final key = Rsa.generate();
/// final sig = key.sign(bytes);                 // RS256
/// Rsa.verify(key.publicPem, bytes, sig);
/// final secret = key.decrypt(Rsa.encrypt(key.publicPem, small));
/// ```
///
/// {@category Crypto}
final class Rsa {
  /// The private key, PKCS#8 or PKCS#1 PEM.
  final String pem;

  const Rsa.fromPem(this.pem);

  /// A fresh key of [bits]; 2048 takes a moment, 4096 several seconds.
  Rsa.generate([int bits = 2048]) : pem = _takeText((out, len) => _N.rsaGenerate(bits, out, len));

  /// The public key as SPKI PEM.
  String get publicPem =>
      Native.withBytes(utf8.encode(pem), (p, pl) => _takeText((out, len) => _N.rsaPublicPem(p, pl, out, len)));

  /// The signature of [message]: PKCS#1 v1.5 (`RS256`), or PSS with [pss] (`PS256`).
  Uint8List sign(List<int> message, {Hash hash = Hash.sha256, bool pss = false}) => _with2(
    utf8.encode(pem),
    message,
    (p, pl, m, ml) => Native.take((out, len) => _N.rsaSign(p, pl, hash.index, pss ? 1 : 0, m, ml, out, len)),
  );

  /// Whether [signature] over [message] verifies against [publicPem] (SPKI, PKCS#1, or a private key).
  static bool verify(
    String publicPem,
    List<int> message,
    List<int> signature, {
    Hash hash = Hash.sha256,
    bool pss = false,
  }) =>
      _with3(
        utf8.encode(publicPem),
        message,
        signature,
        (p, pl, m, ml, s, sl) => _N.rsaVerify(p, pl, hash.index, pss ? 1 : 0, m, ml, s, sl),
      ) ==
      1;

  /// RSA-OAEP encryption of a short [message] (a key, not a document) to [publicPem].
  static Uint8List encrypt(String publicPem, List<int> message, {Hash hash = Hash.sha256}) => _with2(
    utf8.encode(publicPem),
    message,
    (p, pl, m, ml) => Native.take((out, len) => _N.rsaEncrypt(p, pl, hash.index, m, ml, out, len)),
  );

  /// Decrypts what [encrypt] produced; throws [CipherException] when it does not fit this key.
  Uint8List decrypt(List<int> ciphertext, {Hash hash = Hash.sha256}) {
    try {
      return _with2(
        utf8.encode(pem),
        ciphertext,
        (p, pl, c, cl) => Native.take((out, len) => _N.rsaDecrypt(p, pl, hash.index, c, cl, out, len)),
      );
    } on StateError catch (e) {
      throw CipherException(e.message);
    }
  }
}
