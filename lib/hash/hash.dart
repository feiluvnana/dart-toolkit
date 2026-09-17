/// # Hashing
///
/// {@category Files}
library;

import 'package:crypto/crypto.dart' as crypto;

/// Cryptographic digests over raw bytes.
///
/// Compose with a reader to hash a file: `(await p.readBytes()).sha256`.
///
/// {@category Files}
extension BytesHashExtensions on List<int> {
  /// The SHA-256 digest of these bytes, hex encoded.
  String get sha256 => crypto.sha256.convert(this).toString();

  /// The MD5 digest of these bytes, hex encoded.
  String get md5 => crypto.md5.convert(this).toString();
}
