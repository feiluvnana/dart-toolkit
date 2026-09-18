part of '../../hash.dart';

/// Cryptographic digests of a file, streamed.
///
/// Native where the platform has a library — CommonCrypto on macOS, libcrypto on Linux, about
/// 2–3 GB/s — and `package:crypto` elsewhere, at about 170 MB/s. Same digest either way.
///
/// {@category Files}
extension PathHashExtensions on Path {
  /// The SHA-256 digest of this file, hex encoded.
  ///
  /// Reads the file as a stream: memory is constant in its size.
  Future<String> sha256() => _digestFile(this, _sha256());

  /// The MD5 digest of this file, hex encoded.
  ///
  /// Reads the file as a stream: memory is constant in its size.
  Future<String> md5() => _digestFile(this, _md5());
}

Future<String> _digestFile(Path path, _Digest digest) async {
  await for (final chunk in path.asFile.openRead()) {
    digest.add(chunk);
  }
  return _hex(digest.finish());
}

/// Cryptographic digests over bytes already in memory.
///
/// To hash a file use [PathHashExtensions.sha256], which does not load it.
///
/// {@category Files}
extension BytesHashExtensions on List<int> {
  /// The SHA-256 digest of these bytes, hex encoded.
  String get sha256 => _hex((_sha256()..add(this)).finish());

  /// The MD5 digest of these bytes, hex encoded.
  String get md5 => _hex((_md5()..add(this)).finish());
}

/// Whether digests run on the platform's native library rather than in Dart.
///
/// {@category Files}
bool get isNativeHashing => _Native.instance != null;
