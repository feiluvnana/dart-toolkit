part of '../../hash.dart';

/// A digest algorithm.
///
/// {@category Files}
enum Hash {
  md5(16, 'CC_MD5', 'EVP_md5'),
  sha1(20, 'CC_SHA1', 'EVP_sha1'),
  sha224(28, 'CC_SHA224', 'EVP_sha224'),
  sha256(32, 'CC_SHA256', 'EVP_sha256'),
  sha384(48, 'CC_SHA384', 'EVP_sha384'),
  sha512(64, 'CC_SHA512', 'EVP_sha512');

  /// Digest length in bytes.
  final int length;
  final String _cc;
  final String _evp;

  const Hash(this.length, this._cc, this._evp);

  crypto.Hash get _crypto => switch (this) {
    md5 => crypto.md5,
    sha1 => crypto.sha1,
    sha224 => crypto.sha224,
    sha256 => crypto.sha256,
    sha384 => crypto.sha384,
    sha512 => crypto.sha512,
  };
}

/// Digests of a file, streamed: memory is constant in its size.
///
/// Native where the platform has a library — CommonCrypto on macOS, libcrypto on Linux, about
/// 2–3 GB/s — and `package:crypto` elsewhere, at about 170 MB/s. Same digest either way.
///
/// {@category Files}
extension PathHashExtensions on Path {
  /// The [algorithm] digest of this file, hex encoded.
  Future<String> hash(Hash algorithm) => _digestFile(this, _digest(algorithm));

  Future<String> md5() => hash(Hash.md5);
  Future<String> sha1() => hash(Hash.sha1);
  Future<String> sha224() => hash(Hash.sha224);
  Future<String> sha256() => hash(Hash.sha256);
  Future<String> sha384() => hash(Hash.sha384);
  Future<String> sha512() => hash(Hash.sha512);

  /// The CRC-32 of this file.
  Future<int> crc32() async {
    final crc = Crc32();
    await for (final chunk in asFile.openRead()) {
      crc.add(chunk);
    }
    return crc.value;
  }
}

Future<String> _digestFile(Path path, _Digest digest) async {
  await for (final chunk in path.asFile.openRead()) {
    digest.add(chunk);
  }
  return _hex(digest.finish());
}

/// Digests over bytes already in memory.
///
/// To hash a file use [PathHashExtensions.hash], which does not load it.
///
/// {@category Files}
extension BytesHashExtensions on List<int> {
  /// The [algorithm] digest of these bytes, hex encoded.
  String hash(Hash algorithm) => _hex((_digest(algorithm)..add(this)).finish());

  String get md5 => hash(Hash.md5);
  String get sha1 => hash(Hash.sha1);
  String get sha224 => hash(Hash.sha224);
  String get sha256 => hash(Hash.sha256);
  String get sha384 => hash(Hash.sha384);
  String get sha512 => hash(Hash.sha512);

  /// The CRC-32 of these bytes.
  int get crc32 => Crc32.of(this);

  /// The HMAC of these bytes under [key] with [algorithm], hex encoded: `body.hmac(Hash.sha256, secret)`.
  String hmac(Hash algorithm, List<int> key) => crypto.Hmac(algorithm._crypto, key).convert(this).toString();
}

/// Digests of a string's UTF-8 bytes: `'hello'.sha256`.
///
/// {@category Files}
extension StringHashExtensions on String {
  String hash(Hash algorithm) => utf8.encode(this).hash(algorithm);
  String get md5 => hash(Hash.md5);
  String get sha1 => hash(Hash.sha1);
  String get sha256 => hash(Hash.sha256);
  String get sha512 => hash(Hash.sha512);
  int get crc32 => utf8.encode(this).crc32;
  String hmac(Hash algorithm, String key) => utf8.encode(this).hmac(algorithm, utf8.encode(key));
}

/// Whether digests run on the platform's native library rather than in Dart.
///
/// {@category Files}
bool get isNativeHashing => _Native.instance != null;
