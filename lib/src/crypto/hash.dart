part of '../../crypto.dart';

/// A digest algorithm. The order is the native library's code for it.
///
/// {@category Crypto}
enum Hash {
  md5(16),
  sha1(20),
  sha224(28),
  sha256(32),
  sha384(48),
  sha512(64),
  sha3_256(32),
  sha3_512(64),
  blake2b(64),
  blake3(32);

  /// Digest length in bytes.
  final int length;

  const Hash(this.length);

  /// The pure-Dart implementation, for the algorithms `package:crypto` has.
  crypto.Hash? get _crypto => switch (this) {
    md5 => crypto.md5,
    sha1 => crypto.sha1,
    sha224 => crypto.sha224,
    sha256 => crypto.sha256,
    sha384 => crypto.sha384,
    sha512 => crypto.sha512,
    _ => null,
  };
}

/// Digests of a file, streamed: memory is constant in its size.
///
/// {@category Crypto}
extension PathHashExtensions on Path {
  /// The [algorithm] digest of this file, hex encoded.
  Future<String> hash(Hash algorithm) async {
    final d = _digest(algorithm);
    await for (final chunk in asFile.openRead()) {
      d.add(chunk);
    }
    return _hex(d.finish());
  }

  Future<String> md5() => hash(Hash.md5);
  Future<String> sha1() => hash(Hash.sha1);
  Future<String> sha256() => hash(Hash.sha256);
  Future<String> sha512() => hash(Hash.sha512);
  Future<String> blake3() => hash(Hash.blake3);

  /// The CRC-32 of this file.
  Future<int> crc32() async {
    var crc = 0;
    await for (final chunk in asFile.openRead()) {
      crc = _crc32(crc, chunk);
    }
    return crc;
  }
}

/// Digests and MACs over bytes in memory.
///
/// {@category Crypto}
extension BytesHashExtensions on List<int> {
  /// The [algorithm] digest of these bytes, hex encoded.
  String hash(Hash algorithm) => _hex(hashBytes(algorithm));

  /// The [algorithm] digest of these bytes.
  Uint8List hashBytes(Hash algorithm) => (_digest(algorithm)..add(this)).finish();

  String get md5 => hash(Hash.md5);
  String get sha1 => hash(Hash.sha1);
  String get sha256 => hash(Hash.sha256);
  String get sha512 => hash(Hash.sha512);
  String get blake3 => hash(Hash.blake3);

  /// The CRC-32 of these bytes.
  int get crc32 => _crc32(0, this);

  /// The HMAC of these bytes under [key], hex encoded: `body.hmac(Hash.sha256, secret)`.
  String hmac(Hash algorithm, List<int> key) => _hex(hmacBytes(algorithm, key));

  /// The HMAC of these bytes under [key].
  Uint8List hmacBytes(Hash algorithm, List<int> key) {
    if (Native.isAvailable) {
      return _with2(
        key,
        this,
        (k, kl, d, dl) => Native.withOut(64, (out) => _N.hmac(algorithm.index, k, kl, d, dl, out)),
      );
    }
    final h = algorithm._crypto;
    if (h == null) throw UnsupportedError('hmac ${algorithm.name} needs dart_toolkit_native: ${Native.reason}');
    return Uint8List.fromList(crypto.Hmac(h, key).convert(this).bytes);
  }

  /// Hex, lowercase.
  String get hex => _hex(this is Uint8List ? this as Uint8List : Uint8List.fromList(this));

  /// Standard base64.
  String get base64 => base64Encode(this);

  /// URL-safe base64 without padding, as tokens and JWTs use it.
  String get base64Url => base64UrlEncode(this).replaceAll('=', '');
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
  int get crc32 => utf8.encode(this).crc32;
  String hmac(Hash algorithm, String key) => utf8.encode(this).hmac(algorithm, utf8.encode(key));

  /// This hex string as bytes.
  Uint8List get hexBytes {
    final s = replaceAll(RegExp(r'\s'), '');
    if (s.length.isOdd) throw FormatException('Odd-length hex string');
    return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
  }

  /// This base64 or base64url string as bytes, padding optional.
  Uint8List get base64Bytes => base64Decode(base64.normalize(this));
}
