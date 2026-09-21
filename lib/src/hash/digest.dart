part of '../../hash.dart';

/// A digest or checksum. The order is the native library's code for it.
///
/// The checksums ([crc32] to [xxh3]) are fast and detect corruption, not tampering.
///
/// {@category Crypto}
enum Hash {
  md5(16),
  sha1(20),
  sha224(28),
  sha256(32),
  sha384(48),
  sha512(64),
  sha512_256(32),
  sha3_224(28),
  sha3_256(32),
  sha3_384(48),
  sha3_512(64),

  /// Ethereum's Keccak-256: the pre-standard padding, not SHA3-256.
  keccak256(32),
  blake2s(32),
  blake2b(64),
  blake3(32),
  ripemd160(20),
  crc32(4),
  crc32c(4),
  xxh64(8),
  xxh3(8);

  /// Digest length in bytes.
  final int length;

  const Hash(this.length);

  /// Whether this is a checksum rather than a cryptographic hash.
  bool get isChecksum => index >= crc32.index;
}

/// Digests of a file, streamed: memory is constant in its size.
///
/// {@category Crypto}
extension PathHashExtensions on Path {
  /// The [algorithm] digest of this file, hex encoded.
  Future<String> hash(Hash algorithm) async => _hex(await hashBytes(algorithm));

  /// The [algorithm] digest of this file.
  Future<Uint8List> hashBytes(Hash algorithm) async {
    final d = _Digest(algorithm);
    try {
      await for (final chunk in asFile.openRead()) {
        d.add(chunk);
      }
      return d.finish();
    } finally {
      d.dispose();
    }
  }

  Future<String> md5() => hash(Hash.md5);
  Future<String> sha1() => hash(Hash.sha1);
  Future<String> sha256() => hash(Hash.sha256);
  Future<String> sha512() => hash(Hash.sha512);
  Future<String> blake3() => hash(Hash.blake3);

  /// A 32-bit checksum of this file as an integer: `file.checksum(Hash.crc32c)`.
  ///
  /// The 64-bit checksums do not fit a Dart `int` unsigned; read those as hex, with
  /// [hash] or [xxh3].
  Future<int> checksum(Hash algorithm) async => _int(algorithm, await hashBytes(algorithm));
  Future<int> crc32() => checksum(Hash.crc32);

  /// xxh3 of this file, hex encoded — 64 bits, so not an `int`.
  Future<String> xxh3() => hash(Hash.xxh3);
}

/// Digests and MACs over bytes in memory.
///
/// {@category Crypto}
extension BytesHashExtensions on List<int> {
  /// The [algorithm] digest of these bytes, hex encoded.
  String hash(Hash algorithm) => _hex(hashBytes(algorithm));

  /// The [algorithm] digest of these bytes.
  Uint8List hashBytes(Hash algorithm) => Native.withBytes(
    this,
    (p, n) => Native.withOut(_maxDigest, (out) => _N.digest(algorithm.index, p, n, out, _maxDigest)),
  );

  String get md5 => hash(Hash.md5);
  String get sha1 => hash(Hash.sha1);
  String get sha256 => hash(Hash.sha256);
  String get sha512 => hash(Hash.sha512);
  String get blake3 => hash(Hash.blake3);

  /// A 32-bit checksum as an integer: `bytes.checksum(Hash.crc32c)`.
  ///
  /// The 64-bit checksums do not fit a Dart `int` unsigned; read those as hex, with
  /// [hash] or [xxh3].
  int checksum(Hash algorithm) => _int(algorithm, hashBytes(algorithm));
  int get crc32 => checksum(Hash.crc32);

  /// xxh3 of these bytes, hex encoded — 64 bits, so not an `int`.
  String get xxh3 => hash(Hash.xxh3);

  /// The HMAC of these bytes under [key], hex encoded: `body.hmac(Hash.sha256, secret)`.
  String hmac(Hash algorithm, List<int> key) => _hex(hmacBytes(algorithm, key));

  /// The HMAC of these bytes under [key].
  Uint8List hmacBytes(Hash algorithm, List<int> key) => _with2(
    key,
    this,
    (k, kl, d, dl) => Native.withOut(_maxDigest, (out) => _N.hmac(algorithm.index, k, kl, d, dl, out, _maxDigest)),
  );
}

/// Digests of a string's UTF-8 bytes: `'hello'.sha256`.
///
/// {@category Crypto}
extension StringHashExtensions on String {
  String hash(Hash algorithm) => utf8.encode(this).hash(algorithm);
  String get md5 => hash(Hash.md5);
  String get sha1 => hash(Hash.sha1);
  String get sha256 => hash(Hash.sha256);
  String get sha512 => hash(Hash.sha512);
  String get blake3 => hash(Hash.blake3);
  int checksum(Hash algorithm) => utf8.encode(this).checksum(algorithm);
  int get crc32 => checksum(Hash.crc32);
  String get xxh3 => hash(Hash.xxh3);
  String hmac(Hash algorithm, String key) => utf8.encode(this).hmac(algorithm, utf8.encode(key));
}

/// Big-endian bytes as an integer, for the 32-bit checksums.
///
/// A 64-bit checksum is refused rather than returned wrapped: shifting eight bytes into a
/// signed Dart `int` makes half of all inputs negative, which does not match what other
/// tools print and silently breaks anything comparing the two.
int _int(Hash algorithm, Uint8List bytes) {
  if (bytes.length > 4) {
    throw ArgumentError.value(
      algorithm,
      'algorithm',
      '${algorithm.name} is ${bytes.length * 8} bits and does not fit an int; read it as hex',
    );
  }
  var n = 0;
  for (final b in bytes) {
    n = (n << 8) | b;
  }
  return n;
}
