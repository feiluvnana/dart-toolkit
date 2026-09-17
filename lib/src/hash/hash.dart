/// # Hashing
///
/// {@category Files}
library;

import 'package:crypto/crypto.dart' as crypto;

import '../fs/path.dart';

/// Cryptographic digests of a file, streamed.
///
/// {@category Files}
extension PathHashExtensions on Path {
  /// The SHA-256 digest of this file, hex encoded.
  ///
  /// Reads the file as a stream: memory is constant in its size.
  Future<String> sha256() async => (await crypto.sha256.bind(asFile.openRead()).first).toString();

  /// The MD5 digest of this file, hex encoded.
  ///
  /// Reads the file as a stream: memory is constant in its size.
  Future<String> md5() async => (await crypto.md5.bind(asFile.openRead()).first).toString();
}

/// Cryptographic digests over bytes already in memory.
///
/// To hash a file use [PathHashExtensions.sha256], which does not load it.
///
/// {@category Files}
extension BytesHashExtensions on List<int> {
  /// The SHA-256 digest of these bytes, hex encoded.
  String get sha256 => crypto.sha256.convert(this).toString();

  /// The MD5 digest of these bytes, hex encoded.
  String get md5 => crypto.md5.convert(this).toString();
}
