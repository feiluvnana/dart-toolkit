part of '../../hash.dart';

/// A digest or checksum. Every input form gives a [Digest]: [text] and [bytes] at once, [file]
/// and [stream] as a [Task] that reports bytes and honours a cancel. Many files are a `Batch`:
/// `files.parallelize((f) => Hash.sha256.file(f))`.
///
/// ```dart
/// final d = Hash.sha256.text('hello');
/// await Hash.blake3.file(iso).show('Hashing');
/// Hash.sha256.text(body, key: secret);          // a MAC
/// ```
///
/// The checksums ([crc32] to [xxh3]) are fast and detect corruption, not tampering. The order
/// is the native library's code for each.
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

  /// The digest of [text]'s bytes in [encoding], or its MAC under [key].
  Digest text(String text, {Secret? key, Encoding encoding = utf8}) => bytes(encoding.encode(text), key: key);

  /// The digest of [data], or its MAC under [key].
  ///
  /// With a [key], BLAKE2 and BLAKE3 use the keyed mode they are specified with instead of
  /// HMAC: BLAKE2s takes a key of up to 32 bytes, BLAKE2b up to 64, BLAKE3 exactly 32 (its
  /// UTF-8 bytes). Any other key, or a key on a checksum, is an [ArgumentError].
  Digest bytes(List<int> data, {Secret? key}) => Digest._(_ofBytes(this, _keyOf(key), data));

  /// The digest of the file at [path], or its MAC under [key], read by the native library: a
  /// file past 4 MiB on a worker isolate, reporting its bytes, and stopped by a cancel. A
  /// missing file is a [PathNotFoundException].
  Task<Digest> file(String path, {Secret? key}) {
    final k = _keyOf(key);
    return TaskInternals.start(path, FileBridge.label(path), (work) async {
      final stat = await FileStat.stat(path);
      if (stat.type == FileSystemEntityType.notFound) {
        throw FileBridge.notFound(path, 'Cannot hash');
      }
      if (stat.type == FileSystemEntityType.file && stat.size <= _inline) {
        return Digest._(_ofFile(index, k, path, nullptr, nullptr));
      }
      final digest = await NativeBridge.main.run(
        work,
        _fileCall(index, k, path),
        onProgress: (r) => work.amount(r.bytes, total: r.bytesTotal == 0 ? null : r.bytesTotal),
      );
      return Digest._(digest);
    });
  }

  /// The digest of [source], or its MAC under [key], fed to the library as it arrives: a
  /// response body, stdin, a process's output. Reports the bytes so far; a cancel stops it.
  /// A file is faster by its path, with [file].
  ///
  /// ```dart
  /// await Hash.sha256.stream(stdin);
  /// ```
  Task<Digest> stream(Stream<List<int>> source, {Secret? key}) {
    final k = _keyOf(key);
    return TaskInternals.start(source, name, (work) async => Digest._(await _ofStream(this, k, source, work)));
  }
}

/// [key]'s bytes, as a MAC takes them.
Uint8List? _keyOf(Secret? key) => key == null ? null : utf8.encode(key.reveal);

/// What a worker runs to hash [path] with algorithm [alg]: only plain values cross with it.
Uint8List Function(NativeProgress, Pointer<Uint8>) _fileCall(int alg, Uint8List? key, String path) =>
    (progress, stop) => _ofFile(alg, key, path, progress, stop);

/// A digest, a MAC or a checksum: its raw [bytes], and the text forms of them.
///
/// `==` compares in constant time, so a MAC that arrived from outside can be checked with it;
/// so does [matches], against hex.
///
/// {@category Hashing}
final class Digest {
  /// The raw digest. A checksum is big-endian, as its hex reads.
  final Uint8List bytes;

  const Digest._(this.bytes);

  /// Hex, lowercase.
  String get hex => _hex(bytes);

  /// Base64 (RFC 4648), padded.
  String get base64 => base64Encode(bytes);

  /// Base64 with the URL-safe alphabet (`-_`), unpadded, as tokens and JWTs carry it.
  String get base64url => base64UrlEncode(bytes).replaceAll('=', '');

  /// Whether this digest is the one [hex] spells, in either case; in time that depends only on
  /// the lengths. Text that is not hex is a [FormatException].
  bool matches(String hex) => _same(bytes, hex.hexBytes);

  @override
  bool operator ==(Object other) => other is Digest && _same(bytes, other.bytes);

  @override
  int get hashCode => Object.hashAll(bytes.take(8));

  /// [hex].
  @override
  String toString() => hex;
}

/// Whether [a] and [b] are equal, in time that depends only on their lengths.
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
