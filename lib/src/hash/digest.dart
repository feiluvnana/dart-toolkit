part of '../../hash.dart';

/// A digest or checksum. The order is the native library's code for it.
///
/// The checksums ([crc32] to [xxh3]) are fast and detect corruption, not tampering.
///
/// {@category Hashing}
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

  /// The digest of the file at [path]: on this isolate up to [_inline] bytes, else in a worker.
  Future<Uint8List> _file(String path, {List<int>? key}) async =>
      await File(path).length() <= _inline ? _ofFile(this, key, path) : Isolate.run(() => _ofFile(this, key, path));

  /// The digests of [paths], in order, hashed in parallel by the native library in a worker isolate.
  Future<List<Uint8List>> files(List<String> paths) async =>
      paths.isEmpty ? const [] : await Isolate.run(() => _ofFiles(this, paths));

  /// The digests of [paths], in order, hashed in parallel by the native library synchronously.
  List<Uint8List> filesSync(List<String> paths) => paths.isEmpty ? const [] : _ofFiles(this, paths);

  /// Computes the hex digest of [text]'s UTF-8 bytes.
  String text(String text, {Encoding encoding = utf8}) => _hex(digest(encoding.encode(text)));

  /// Computes the hex digest of [bytes].
  String bytes(List<int> bytes) => _hex(digest(bytes));

  /// Computes the raw byte digest of [bytes] in memory.
  Uint8List digest(List<int> bytes) => _ofBytes(this, null, bytes);

  /// Computes the hex digest of the file at [pathOrFile].
  ///
  /// Accepts a [File], [String] path, or any object whose `toString()` is a path.
  Future<String> file(Object pathOrFile) async => _hex(await fileDigest(pathOrFile));

  /// Computes the raw byte digest of the file at [pathOrFile].
  Future<Uint8List> fileDigest(Object pathOrFile) async {
    final path = pathOrFile is File ? pathOrFile.path : pathOrFile.toString();
    return _file(path);
  }

  /// Computes the HMAC hex digest of [bytes] under [key].
  String hmac(List<int> key, List<int> bytes) => _hex(_ofBytes(this, key, bytes));

  /// Computes the HMAC hex digest of [text] under [key].
  String hmacText(List<int> key, String text, {Encoding encoding = utf8}) => hmac(key, encoding.encode(text));

  /// Computes the HMAC hex digest of the file at [pathOrFile] under [key].
  Future<String> hmacFile(List<int> key, Object pathOrFile) async {
    final path = pathOrFile is File ? pathOrFile.path : pathOrFile.toString();
    return _hex(await _file(path, key: key));
  }
}

/// Digests and MACs of a file: `await file.hash(Hash.sha256)`.
///
/// {@category Hashing}
extension FileHashExtensions on File {
  /// The [algorithm] digest of this file, hex encoded.
  Future<String> hash(Hash algorithm) async => _hex(await hashBytes(algorithm));

  /// The [algorithm] digest of this file.
  Future<Uint8List> hashBytes(Hash algorithm) => algorithm._file(path);

  /// A 32-bit checksum of this file as an integer: `file.checksum(Hash.crc32c)`.
  ///
  /// The 64-bit checksums do not fit a Dart `int` unsigned; read those as hex, with [hash].
  Future<int> checksum(Hash algorithm) async => _int(algorithm, await hashBytes(algorithm));

  /// The HMAC of this file's contents under [key], hex encoded; see [BytesHashExtensions.hmacBytes].
  Future<String> hmac(Hash algorithm, List<int> key) async => _hex(await hmacBytes(algorithm, key));

  /// The HMAC of this file's contents under [key]; see [BytesHashExtensions.hmacBytes].
  Future<Uint8List> hmacBytes(Hash algorithm, List<int> key) => algorithm._file(path, key: key);
}

/// Digests of many files at once: `await files.hash(Hash.xxh3)`.
///
/// {@category Hashing}
extension FilesHashExtensions on Iterable<File> {
  /// Each file's [algorithm] digest, hex encoded, hashed in parallel by the native library.
  Future<Map<File, String>> hash(Hash algorithm) async {
    final files = toList();
    if (files.isEmpty) return {};
    final digests = await algorithm.files([for (final f in files) f.path]);
    return {for (var i = 0; i < files.length; i++) files[i]: _hex(digests[i])};
  }
}

/// Digests and MACs over bytes in memory.
///
/// {@category Hashing}
extension BytesHashExtensions on List<int> {
  /// The [algorithm] digest of these bytes, hex encoded.
  String hash(Hash algorithm) => _hex(hashBytes(algorithm));

  /// The [algorithm] digest of these bytes.
  Uint8List hashBytes(Hash algorithm) => _ofBytes(algorithm, null, this);

  /// A 32-bit checksum as an integer: `bytes.checksum(Hash.crc32c)`.
  ///
  /// The 64-bit checksums do not fit a Dart `int` unsigned; read those as hex, with [hash].
  int checksum(Hash algorithm) => _int(algorithm, hashBytes(algorithm));

  /// The HMAC of these bytes under [key], hex encoded: `body.hmac(Hash.sha256, secret)`.
  String hmac(Hash algorithm, List<int> key) => _hex(hmacBytes(algorithm, key));

  /// The HMAC of these bytes under [key].
  ///
  /// BLAKE2 and BLAKE3 use the keyed mode they are specified with instead of HMAC: BLAKE2s
  /// takes a key of up to 32 bytes, BLAKE2b up to 64, BLAKE3 exactly 32. Any other key, or a
  /// checksum, throws [ArgumentError].
  Uint8List hmacBytes(Hash algorithm, List<int> key) => _ofBytes(algorithm, key, this);
}

/// Digests of a string's UTF-8 bytes: `'hello'.hash(Hash.sha256)`.
///
/// {@category Hashing}
extension StringHashExtensions on String {
  /// The [algorithm] digest of this string's UTF-8 bytes, hex encoded.
  String hash(Hash algorithm) => utf8.encode(this).hash(algorithm);

  /// The [algorithm] digest of this string's UTF-8 bytes.
  Uint8List hashBytes(Hash algorithm) => utf8.encode(this).hashBytes(algorithm);

  /// A 32-bit checksum of this string's UTF-8 bytes as an integer.
  int checksum(Hash algorithm) => utf8.encode(this).checksum(algorithm);

  /// The HMAC of this string under [key], hex encoded; see [BytesHashExtensions.hmacBytes].
  String hmac(Hash algorithm, String key) => utf8.encode(this).hmac(algorithm, utf8.encode(key));

  /// The HMAC of this string under [key]; see [BytesHashExtensions.hmacBytes].
  Uint8List hmacBytes(Hash algorithm, String key) => utf8.encode(this).hmacBytes(algorithm, utf8.encode(key));
}

/// Big-endian bytes as an integer, for the 32-bit checksums. A 64-bit one is refused: as a
/// signed `int` half of all values would be negative, unlike what other tools print.

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
